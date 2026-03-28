import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation

struct HoldHotkeyDefinition: Equatable {
    let modifiers: NSEvent.ModifierFlags
    let triggerKeyCode: CGKeyCode
}

enum HotkeyValidationError: LocalizedError {
    case invalidFormat
    case unsupportedModifier(String)
    case unsupportedTrigger(String)

    var errorDescription: String? {
        switch self {
        case .invalidFormat:
            return "热键至少要包含一个修饰键和一个触发键，例如 cmd+shift+space。"
        case let .unsupportedModifier(modifier):
            return "不支持的修饰键：\(modifier)"
        case let .unsupportedTrigger(trigger):
            return "不支持的触发键：\(trigger)"
        }
    }
}

final class HotkeyMonitor: @unchecked Sendable {
    var onHoldStart: (() -> Void)?
    var onHoldEnd: (() -> Void)?
    var onToggleTap: (() -> Void)?

    private var holdDefinition: HoldHotkeyDefinition?
    private var holdHotkeyActsAsToggle = false
    private var toggleModifierKeyCodes: Set<CGKeyCode> = []
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private var holdActive = false
    private var toggleModifierDown = false
    private var toggleChordDetected = false

    static func requiresInputMonitoring(for settings: AppSettings) -> Bool {
        !keyCodes(forModifier: settings.toggleModifierKey).isEmpty
    }

    func start(settings: AppSettings) throws {
        stop()
        holdDefinition = try Self.parseHoldHotkey(settings.holdHotkey)
        holdHotkeyActsAsToggle = holdDefinition?.triggerKeyCode != 49
        toggleModifierKeyCodes = Self.keyCodes(forModifier: settings.toggleModifierKey)

        try registerHotkey()

        guard !toggleModifierKeyCodes.isEmpty else {
            return
        }

        let thread = Thread { [weak self] in
            self?.installTap()
        }
        thread.name = "VoiceCodingNative.Hotkeys"
        thread.start()
        self.thread = thread

        Thread.sleep(forTimeInterval: 0.15)
        if eventTap == nil {
            throw NSError(domain: "VoiceCodingNative", code: 6, userInfo: [NSLocalizedDescriptionKey: "无法创建全局键盘监听，请检查输入监控权限。"])
        }
    }

    func stop() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let hotKeyHandler {
            RemoveEventHandler(hotKeyHandler)
            self.hotKeyHandler = nil
        }

        if let runLoop, let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
            if let runLoopSource {
                CFRunLoopRemoveSource(runLoop, runLoopSource, .commonModes)
            }
            CFRunLoopStop(runLoop)
        }

        eventTap = nil
        runLoopSource = nil
        self.runLoop = nil
        thread = nil
        holdActive = false
        holdHotkeyActsAsToggle = false
        toggleModifierDown = false
        toggleChordDetected = false
    }

    static func parseHoldHotkey(_ expression: String) throws -> HoldHotkeyDefinition {
        let parts = expression
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }

        guard parts.count >= 2 else {
            throw HotkeyValidationError.invalidFormat
        }

        var modifiers: NSEvent.ModifierFlags = []
        for modifier in parts.dropLast() {
            switch modifier {
            case "cmd", "command", "super", "win", "windows":
                modifiers.insert(.command)
            case "shift":
                modifiers.insert(.shift)
            case "ctrl", "control":
                modifiers.insert(.control)
            case "alt", "option":
                modifiers.insert(.option)
            default:
                throw HotkeyValidationError.unsupportedModifier(String(modifier))
            }
        }

        guard let triggerKeyCode = keyCode(forTrigger: parts.last ?? "") else {
            throw HotkeyValidationError.unsupportedTrigger(parts.last ?? "")
        }

        return HoldHotkeyDefinition(modifiers: modifiers, triggerKeyCode: triggerKeyCode)
    }

    static func keyCodes(forModifier token: String) -> Set<CGKeyCode> {
        switch token.lowercased() {
        case "cmd", "command":
            return [54, 55]
        case "shift":
            return [56, 60]
        case "ctrl", "control":
            return [59, 62]
        case "alt", "option":
            return [58, 61]
        default:
            return []
        }
    }

    private static func keyCode(forTrigger token: String) -> CGKeyCode? {
        switch token.lowercased() {
        case "space":
            return 49
        case "return", "enter":
            return 36
        case "tab":
            return 48
        case "escape", "esc":
            return 53
        default:
            break
        }

        let keyCodes: [String: CGKeyCode] = [
            "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5, "h": 4, "i": 34,
            "j": 38, "k": 40, "l": 37, "m": 46, "n": 45, "o": 31, "p": 35, "q": 12, "r": 15,
            "s": 1, "t": 17, "u": 32, "v": 9, "w": 13, "x": 7, "y": 16, "z": 6,
            "0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26,
            "8": 28, "9": 25,
        ]
        return keyCodes[token.lowercased()]
    }

    private static func carbonModifiers(from modifiers: NSEvent.ModifierFlags) -> UInt32 {
        var carbonFlags: UInt32 = 0
        if modifiers.contains(.command) {
            carbonFlags |= UInt32(cmdKey)
        }
        if modifiers.contains(.shift) {
            carbonFlags |= UInt32(shiftKey)
        }
        if modifiers.contains(.control) {
            carbonFlags |= UInt32(controlKey)
        }
        if modifiers.contains(.option) {
            carbonFlags |= UInt32(optionKey)
        }
        return carbonFlags
    }

    private func registerHotkey() throws {
        guard let holdDefinition else {
            return
        }

        let eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard
                    let event,
                    let userData
                else {
                    return noErr
                }

                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userData).takeUnretainedValue()
                return monitor.handleHotkeyEvent(event)
            },
            eventTypes.count,
            eventTypes,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            &hotKeyHandler
        )
        guard installStatus == noErr else {
            throw NSError(domain: "VoiceCodingNative", code: 10, userInfo: [NSLocalizedDescriptionKey: "无法注册全局快捷键事件处理器。"])
        }

        let hotKeyID = EventHotKeyID(signature: OSType(0x56434458), id: 1)
        let registerStatus = RegisterEventHotKey(
            UInt32(holdDefinition.triggerKeyCode),
            Self.carbonModifiers(from: holdDefinition.modifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard registerStatus == noErr else {
            if let hotKeyHandler {
                RemoveEventHandler(hotKeyHandler)
                self.hotKeyHandler = nil
            }
            throw NSError(domain: "VoiceCodingNative", code: 11, userInfo: [NSLocalizedDescriptionKey: "无法注册全局快捷键，请检查设置是否冲突。"])
        }
    }

    private func handleHotkeyEvent(_ event: EventRef) -> OSStatus {
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        guard status == noErr, hotKeyID.signature == OSType(0x56434458), hotKeyID.id == 1 else {
            return noErr
        }

        switch GetEventKind(event) {
        case UInt32(kEventHotKeyPressed):
            handleHotkeyPressed()
        case UInt32(kEventHotKeyReleased):
            handleHotkeyReleased()
        default:
            break
        }
        return noErr
    }

    private func handleHotkeyPressed() {
        guard !holdActive else {
            return
        }

        holdActive = true
        if holdHotkeyActsAsToggle {
            let callback = onToggleTap
            DispatchQueue.main.async {
                callback?()
            }
            return
        }

        let callback = onHoldStart
        DispatchQueue.main.async {
            callback?()
        }
    }

    private func handleHotkeyReleased() {
        guard holdActive else {
            return
        }

        if holdHotkeyActsAsToggle {
            holdActive = false
            return
        }

        holdActive = false
        let callback = onHoldEnd
        DispatchQueue.main.async {
            callback?()
        }
    }

    private func installTap() {
        let mask = CGEventMask((1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue))

        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, eventType, event, userInfo in
                guard let userInfo else {
                    return Unmanaged.passUnretained(event)
                }

                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
                monitor.handle(eventType: eventType, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )

        guard let tap else {
            return
        }

        eventTap = tap
        runLoop = CFRunLoopGetCurrent()
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        CFRunLoopRun()
    }

    private func handle(eventType: CGEventType, event: CGEvent) {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return
        }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = NSEvent.ModifierFlags(cgEventFlags: event.flags)

        switch eventType {
        case .keyDown:
            if toggleModifierDown {
                toggleChordDetected = true
            }
        case .flagsChanged:
            handleFlagsChanged(keyCode: keyCode, flags: flags)
        default:
            break
        }
    }

    private func handleFlagsChanged(keyCode: CGKeyCode, flags: NSEvent.ModifierFlags) {
        if toggleModifierKeyCodes.contains(keyCode) {
            let isDown = Self.toggleModifierIsDown(flags: flags, matching: toggleModifierKeyCodes)
            if isDown {
                if !toggleModifierDown {
                    toggleModifierDown = true
                    toggleChordDetected = false
                }
            } else {
                let shouldFire = toggleModifierDown && !toggleChordDetected
                toggleModifierDown = false
                toggleChordDetected = false
                if shouldFire {
                    let callback = onToggleTap
                    DispatchQueue.main.async {
                        callback?()
                    }
                }
            }
            return
        }

        if toggleModifierDown, !flags.isDisjoint(with: [.command, .shift, .control, .option]) {
            toggleChordDetected = true
        }
    }

    private static func toggleModifierIsDown(flags: NSEvent.ModifierFlags, matching keyCodes: Set<CGKeyCode>) -> Bool {
        if keyCodes == [58, 61] {
            return flags.contains(.option)
        }
        if keyCodes == [54, 55] {
            return flags.contains(.command)
        }
        if keyCodes == [56, 60] {
            return flags.contains(.shift)
        }
        if keyCodes == [59, 62] {
            return flags.contains(.control)
        }
        return false
    }
}

private extension NSEvent.ModifierFlags {
    init(cgEventFlags: CGEventFlags) {
        var flags: NSEvent.ModifierFlags = []
        if cgEventFlags.contains(.maskCommand) { flags.insert(.command) }
        if cgEventFlags.contains(.maskShift) { flags.insert(.shift) }
        if cgEventFlags.contains(.maskControl) { flags.insert(.control) }
        if cgEventFlags.contains(.maskAlternate) { flags.insert(.option) }
        self = flags
    }

    func contains(_ other: NSEvent.ModifierFlags) -> Bool {
        intersection(other) == other
    }
}
