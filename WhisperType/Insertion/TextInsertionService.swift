import AppKit
import ApplicationServices
import Foundation

final class TextInsertionService {
    enum InsertionError: LocalizedError {
        case accessibilityPermissionMissing
        case noFocusedElement
        case couldNotPasteIntoFocusedApp

        var errorDescription: String? {
            switch self {
            case .accessibilityPermissionMissing:
                return "Accessibility access is required before spk can type into other apps."
            case .noFocusedElement:
                return "spk could not find a focused text field in the current app."
            case .couldNotPasteIntoFocusedApp:
                return "spk could not insert the transcription into the focused app."
            }
        }
    }

    func insert(_ text: String) throws {
        guard AXIsProcessTrusted() else {
            throw InsertionError.accessibilityPermissionMissing
        }

        guard !text.isEmpty else {
            return
        }

        if try insertUsingAccessibility(text) {
            return
        }

        try insertUsingPasteboard(text)
    }

    private func insertUsingAccessibility(_ text: String) throws -> Bool {
        let element = try focusedElement()

        var valueRef: CFTypeRef?
        let valueResult = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef)

        var rangeRef: CFTypeRef?
        let rangeResult = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef)

        guard valueResult == .success,
              let currentValue = valueRef as? String,
              rangeResult == .success,
              let rangeRef,
              let selection = extractRange(from: rangeRef) else {
            return false
        }

        let currentNSString = currentValue as NSString
        let safeRange = NSRange(location: selection.location, length: selection.length)

        guard NSMaxRange(safeRange) <= currentNSString.length else {
            return false
        }

        let replacement = currentNSString.replacingCharacters(in: safeRange, with: text)
        let setValueResult = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, replacement as CFTypeRef)

        guard setValueResult == .success else {
            return false
        }

        var newSelection = CFRange(location: safeRange.location + (text as NSString).length, length: 0)
        guard let newSelectionValue = AXValueCreate(.cfRange, &newSelection) else {
            return true
        }

        _ = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, newSelectionValue)
        return true
    }

    private func insertUsingPasteboard(_ text: String) throws {
        let pasteboard = NSPasteboard.general
        let previousItems = pasteboard.pasteboardItems?.compactMap { $0.copy() as? NSPasteboardItem }

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            throw InsertionError.couldNotPasteIntoFocusedApp
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        keyUp.post(tap: .cgAnnotatedSessionEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            pasteboard.clearContents()
            if let previousItems, !previousItems.isEmpty {
                pasteboard.writeObjects(previousItems)
            }
        }
    }

    private func focusedElement() throws -> AXUIElement {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(systemWideElement, kAXFocusedUIElementAttribute as CFString, &focusedRef)

        guard result == .success, let focusedRef else {
            throw InsertionError.noFocusedElement
        }

        return unsafeBitCast(focusedRef, to: AXUIElement.self)
    }

    private func extractRange(from value: CFTypeRef) -> CFRange? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = unsafeBitCast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else {
            return nil
        }

        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else {
            return nil
        }

        return range
    }
}
