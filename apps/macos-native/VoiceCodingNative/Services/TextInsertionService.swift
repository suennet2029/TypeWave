import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

@MainActor
final class TextInsertionService {
    final class LiveInsertionSession {
        fileprivate let focusedElement: AXUIElement
        fileprivate let originalValue: String
        fileprivate let originalRange: CFRange
        fileprivate var renderedText = ""

        fileprivate init(focusedElement: AXUIElement, originalValue: String, originalRange: CFRange) {
            self.focusedElement = focusedElement
            self.originalValue = originalValue
            self.originalRange = originalRange
        }
    }

    func insertText(_ text: String, targetApp: TargetApp?, settings: AppSettings) async throws {
        guard !text.isEmpty else {
            return
        }

        if let targetApp {
            _ = TargetAppTracker.activate(targetApp)
        }

        let delay = UInt64(max(settings.pasteDelayMs, 0)) * 1_000_000
        try await Task.sleep(nanoseconds: delay)

        if settings.pasteMode == .clipboard {
            copyToClipboard(text)
        }

        if try insertViaAccessibility(text) {
            return
        }

        switch settings.pasteMode {
        case .clipboard:
            try await insertViaClipboard(text)
        case .type:
            try insertViaTyping(text)
        }
    }

    func beginLiveInsertionSession() -> LiveInsertionSession? {
        guard AXIsProcessTrusted(),
              let focusedElement = copyFocusedElement()
        else {
            return nil
        }

        var isSettable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(focusedElement, kAXValueAttribute as CFString, &isSettable) == .success,
              isSettable.boolValue
        else {
            return nil
        }

        let currentValue = copyStringAttribute(kAXValueAttribute, from: focusedElement) ?? ""
        let currentRange = copySelectedRange(from: focusedElement) ?? CFRange(location: (currentValue as NSString).length, length: 0)
        return LiveInsertionSession(focusedElement: focusedElement, originalValue: currentValue, originalRange: currentRange)
    }

    func updateLiveInsertion(_ text: String, session: LiveInsertionSession) -> Bool {
        guard !text.isEmpty else {
            return true
        }
        guard applyLiveText(text, session: session) else {
            return false
        }
        session.renderedText = text
        return true
    }

    func commitLiveInsertion(_ text: String, session: LiveInsertionSession) -> Bool {
        guard !text.isEmpty else {
            return true
        }
        guard applyLiveText(text, session: session) else {
            return false
        }
        session.renderedText = text
        return true
    }

    func cancelLiveInsertion(_ session: LiveInsertionSession) {
        guard !session.renderedText.isEmpty else {
            return
        }

        _ = AXUIElementSetAttributeValue(
            session.focusedElement,
            kAXValueAttribute as CFString,
            session.originalValue as CFTypeRef
        )

        var originalRange = session.originalRange
        if let rangeValue = AXValueCreate(.cfRange, &originalRange) {
            _ = AXUIElementSetAttributeValue(
                session.focusedElement,
                kAXSelectedTextRangeAttribute as CFString,
                rangeValue
            )
        }
        session.renderedText = ""
    }

    private func insertViaAccessibility(_ text: String) throws -> Bool {
        guard AXIsProcessTrusted() else {
            return false
        }

        guard let focusedElement = copyFocusedElement() else {
            return false
        }

        var isSettable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(focusedElement, kAXValueAttribute as CFString, &isSettable) == .success, isSettable.boolValue else {
            return false
        }

        let currentValue = copyStringAttribute(kAXValueAttribute, from: focusedElement) ?? ""
        let currentRange = copySelectedRange(from: focusedElement) ?? CFRange(location: (currentValue as NSString).length, length: 0)
        let nsValue = currentValue as NSString
        let safeLocation = max(0, min(currentRange.location, nsValue.length))
        let safeLength = max(0, min(currentRange.length, nsValue.length - safeLocation))
        let updated = nsValue.replacingCharacters(in: NSRange(location: safeLocation, length: safeLength), with: text)

        guard AXUIElementSetAttributeValue(focusedElement, kAXValueAttribute as CFString, updated as CFTypeRef) == .success else {
            return false
        }

        var nextRange = CFRange(location: safeLocation + (text as NSString).length, length: 0)
        if let rangeValue = AXValueCreate(.cfRange, &nextRange) {
            _ = AXUIElementSetAttributeValue(focusedElement, kAXSelectedTextRangeAttribute as CFString, rangeValue)
        }

        return true
    }

    private func applyLiveText(_ text: String, session: LiveInsertionSession) -> Bool {
        let originalValue = session.originalValue as NSString
        let safeLocation = max(0, min(session.originalRange.location, originalValue.length))
        let safeLength = max(0, min(session.originalRange.length, originalValue.length - safeLocation))
        let updated = originalValue.replacingCharacters(
            in: NSRange(location: safeLocation, length: safeLength),
            with: text
        )

        guard AXUIElementSetAttributeValue(
            session.focusedElement,
            kAXValueAttribute as CFString,
            updated as CFTypeRef
        ) == .success else {
            return false
        }

        var nextRange = CFRange(location: safeLocation + (text as NSString).length, length: 0)
        if let rangeValue = AXValueCreate(.cfRange, &nextRange) {
            _ = AXUIElementSetAttributeValue(
                session.focusedElement,
                kAXSelectedTextRangeAttribute as CFString,
                rangeValue
            )
        }

        return true
    }

    private func copyFocusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedElementRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedElementRef) == .success,
              let focusedElementRef,
              CFGetTypeID(focusedElementRef) == AXUIElementGetTypeID()
        else {
            return nil
        }
        return unsafeDowncast(focusedElementRef, to: AXUIElement.self)
    }

    private func insertViaClipboard(_ text: String) async throws {
        copyToClipboard(text)
        try sendPasteShortcut()
    }

    private func insertViaTyping(_ text: String) throws {
        let source = CGEventSource(stateID: .combinedSessionState)
        for character in text {
            var utf16 = Array(String(character).utf16)
            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else {
                throw NSError(domain: "VoiceCodingNative", code: 7, userInfo: [NSLocalizedDescriptionKey: "无法构造键盘输入事件。"])
            }

            keyDown.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            keyUp.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
        }
    }

    private func sendPasteShortcut() throws {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        else {
            throw NSError(domain: "VoiceCodingNative", code: 8, userInfo: [NSLocalizedDescriptionKey: "无法构造粘贴快捷键事件。"])
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func copyStringAttribute(_ key: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func copySelectedRange(from element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let rangeValue = value,
              CFGetTypeID(rangeValue) == AXValueGetTypeID()
        else {
            return nil
        }

        let axValue = unsafeDowncast(rangeValue, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else {
            return nil
        }

        var range = CFRange()
        return AXValueGetValue(axValue, .cfRange, &range) ? range : nil
    }
}
