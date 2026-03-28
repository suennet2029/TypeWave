import AppKit
import ApplicationServices
import Foundation

enum FocusedInputAnchorResolver {
    static func resolveAnchorRect() -> CGRect? {
        guard AXIsProcessTrusted() else {
            return nil
        }

        let systemWide = AXUIElementCreateSystemWide()
        guard let focusedElement = focusedElement(from: systemWide) else {
            return nil
        }

        if let caretRect = selectedTextBounds(from: focusedElement) {
            return normalizeToScreenCoordinates(caretRect)
        }

        if let frame = frame(of: focusedElement) {
            return normalizeToScreenCoordinates(frame)
        }

        return nil
    }

    private static func focusedElement(from systemWide: AXUIElement) -> AXUIElement? {
        var focusedElementRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedElementRef) == .success,
              let focusedElementRef,
              CFGetTypeID(focusedElementRef) == AXUIElementGetTypeID()
        else {
            return nil
        }

        return unsafeDowncast(focusedElementRef, to: AXUIElement.self)
    }

    private static func selectedTextBounds(from element: AXUIElement) -> CGRect? {
        guard let selectedRange = selectedRange(from: element) else {
            return nil
        }

        if let directBounds = bounds(for: selectedRange, in: element), !directBounds.isEmpty {
            return directBounds
        }

        guard selectedRange.length == 0, selectedRange.location > 0 else {
            return nil
        }

        let previousCharacterRange = CFRange(location: selectedRange.location - 1, length: 1)
        guard var previousBounds = bounds(for: previousCharacterRange, in: element), !previousBounds.isEmpty else {
            return nil
        }
        previousBounds.origin.x = previousBounds.maxX - 2
        previousBounds.size.width = 2
        return previousBounds
    }

    private static func selectedRange(from element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID()
        else {
            return nil
        }

        let axValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else {
            return nil
        }

        var range = CFRange()
        return AXValueGetValue(axValue, .cfRange, &range) ? range : nil
    }

    private static func bounds(for range: CFRange, in element: AXUIElement) -> CGRect? {
        var mutableRange = range
        guard let rangeValue = AXValueCreate(.cfRange, &mutableRange) else {
            return nil
        }

        var boundsRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue,
            &boundsRef
        ) == .success,
        let boundsRef,
        CFGetTypeID(boundsRef) == AXValueGetTypeID()
        else {
            return nil
        }

        let axValue = unsafeDowncast(boundsRef, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgRect else {
            return nil
        }

        var rect = CGRect.zero
        return AXValueGetValue(axValue, .cgRect, &rect) ? rect : nil
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let position = pointAttribute(kAXPositionAttribute as CFString, from: element),
              let size = sizeAttribute(kAXSizeAttribute as CFString, from: element)
        else {
            return nil
        }

        return CGRect(origin: position, size: size)
    }

    private static func pointAttribute(_ key: CFString, from element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID()
        else {
            return nil
        }

        let axValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgPoint else {
            return nil
        }

        var point = CGPoint.zero
        return AXValueGetValue(axValue, .cgPoint, &point) ? point : nil
    }

    private static func sizeAttribute(_ key: CFString, from element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID()
        else {
            return nil
        }

        let axValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgSize else {
            return nil
        }

        var size = CGSize.zero
        return AXValueGetValue(axValue, .cgSize, &size) ? size : nil
    }

    private static func normalizeToScreenCoordinates(_ rect: CGRect) -> CGRect {
        if NSScreen.screens.contains(where: { $0.frame.intersects(rect) }) {
            return rect
        }

        for screen in NSScreen.screens {
            let flippedRect = CGRect(
                x: rect.origin.x,
                y: screen.frame.maxY - rect.origin.y - rect.height,
                width: rect.width,
                height: rect.height
            )
            if screen.frame.intersects(flippedRect) {
                return flippedRect
            }
        }

        return rect
    }
}
