import Carbon
import Foundation

final class HotkeyManager {
    static let defaultShortcutDisplay = "Cmd+Shift+Space"

    enum ListenerStatus: Equatable {
        case inactive
        case installed
        case failedToRegister

        var isInstalled: Bool {
            if case .installed = self {
                return true
            }

            return false
        }

        var logDescription: String {
            switch self {
            case .inactive:
                return "inactive"
            case .installed:
                return "installed"
            case .failedToRegister:
                return "failed-to-register"
            }
        }
    }

    private static let eventHotKeySignature: OSType = {
        Array("SpkH".utf8).reduce(0) { ($0 << 8) | OSType($1) }
    }()

    private var carbonEventHandler: EventHandlerRef?
    private var carbonEventHotKey: EventHotKeyRef?
    private var onTrigger: (() -> Void)?
    private(set) var listenerStatus: ListenerStatus = .inactive

    deinit {
        tearDownHotKey()
    }

    @discardableResult
    func installDefault(onTrigger: @escaping () -> Void) -> ListenerStatus {
        self.onTrigger = onTrigger
        return installHotKeyIfNeeded()
    }

    @discardableResult
    func resetDefault() -> ListenerStatus {
        tearDownHotKey()
        onTrigger = nil
        return updateListenerStatus(.inactive)
    }

    private func installHotKeyIfNeeded() -> ListenerStatus {
        guard carbonEventHotKey == nil else {
            return updateListenerStatus(.installed)
        }

        guard installEventHandlerIfNeeded() else {
            tearDownHotKey()
            return updateListenerStatus(.failedToRegister)
        }

        var carbonEventHotKey: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.eventHotKeySignature, id: 1)
        let registerError = RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(cmdKey) | UInt32(shiftKey),
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &carbonEventHotKey
        )

        guard registerError == noErr, let carbonEventHotKey else {
            DebugLog.log(
                "Could not register the \(Self.defaultShortcutDisplay) shortcut via Carbon. error=\(registerError)",
                category: "hotkey"
            )
            tearDownHotKey()
            return updateListenerStatus(.failedToRegister)
        }

        self.carbonEventHotKey = carbonEventHotKey
        DebugLog.log("Installed \(Self.defaultShortcutDisplay) shortcut using Carbon hot key registration.", category: "hotkey")
        return updateListenerStatus(.installed)
    }

    private func installEventHandlerIfNeeded() -> Bool {
        guard carbonEventHandler == nil else {
            return true
        }

        let callback: EventHandlerUPP = { _, event, userInfo in
            guard let userInfo else {
                return OSStatus(eventNotHandledErr)
            }

            let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
            return manager.handleCarbonEvent(event)
        }

        let eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]

        let installStatus = eventTypes.withUnsafeBufferPointer { buffer -> OSStatus in
            InstallEventHandler(
                GetEventDispatcherTarget(),
                callback,
                buffer.count,
                buffer.baseAddress,
                Unmanaged.passUnretained(self).toOpaque(),
                &carbonEventHandler
            )
        }

        guard installStatus == noErr else {
            DebugLog.log("Could not install a Carbon event handler for the \(Self.defaultShortcutDisplay) shortcut. error=\(installStatus)", category: "hotkey")
            return false
        }

        return true
    }

    private func tearDownHotKey() {
        if let carbonEventHotKey {
            UnregisterEventHotKey(carbonEventHotKey)
            self.carbonEventHotKey = nil
        }

        if let carbonEventHandler {
            RemoveEventHandler(carbonEventHandler)
            self.carbonEventHandler = nil
        }
    }

    private func handleCarbonEvent(_ event: EventRef?) -> OSStatus {
        guard let event else {
            return OSStatus(eventNotHandledErr)
        }

        var hotKeyID = EventHotKeyID()
        let getParameterError = GetEventParameter(
            event,
            UInt32(kEventParamDirectObject),
            UInt32(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )

        guard getParameterError == noErr else {
            return getParameterError
        }

        guard hotKeyID.signature == Self.eventHotKeySignature, hotKeyID.id == 1 else {
            return OSStatus(eventNotHandledErr)
        }

        if GetEventKind(event) == UInt32(kEventHotKeyPressed) {
            DebugLog.log("Detected \(Self.defaultShortcutDisplay) press.", category: "hotkey")
            onTrigger?()
            return noErr
        }

        return OSStatus(eventNotHandledErr)
    }

    private func updateListenerStatus(_ status: ListenerStatus) -> ListenerStatus {
        listenerStatus = status
        return status
    }
}
