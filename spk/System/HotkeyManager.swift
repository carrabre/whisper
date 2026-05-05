import Carbon
import Foundation

final class HotkeyManager {
    struct Shortcut: Equatable {
        let keyCode: UInt32
        let modifiers: UInt32
        let displayString: String
    }

    struct CarbonHooks {
        let installEventHandler: (
            _ callback: @escaping EventHandlerUPP,
            _ userInfo: UnsafeMutableRawPointer?
        ) -> (OSStatus, EventHandlerRef?)
        let registerHotKey: (
            _ shortcut: Shortcut,
            _ hotKeyID: EventHotKeyID
        ) -> (OSStatus, EventHotKeyRef?)
        let unregisterHotKey: (_ hotKey: EventHotKeyRef) -> Void
        let removeEventHandler: (_ handler: EventHandlerRef) -> Void

        static let live = CarbonHooks(
            installEventHandler: { callback, userInfo in
                var carbonEventHandler: EventHandlerRef?
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
                        userInfo,
                        &carbonEventHandler
                    )
                }
                return (installStatus, carbonEventHandler)
            },
            registerHotKey: { shortcut, hotKeyID in
                var carbonEventHotKey: EventHotKeyRef?
                let registerStatus = RegisterEventHotKey(
                    shortcut.keyCode,
                    shortcut.modifiers,
                    hotKeyID,
                    GetEventDispatcherTarget(),
                    0,
                    &carbonEventHotKey
                )
                return (registerStatus, carbonEventHotKey)
            },
            unregisterHotKey: { carbonEventHotKey in
                UnregisterEventHotKey(carbonEventHotKey)
            },
            removeEventHandler: { carbonEventHandler in
                RemoveEventHandler(carbonEventHandler)
            }
        )
    }

    static let defaultShortcut = Shortcut(
        keyCode: UInt32(kVK_Space),
        modifiers: UInt32(cmdKey) | UInt32(shiftKey),
        displayString: "Cmd+Shift+Space"
    )
    static let defaultShortcutDisplay = defaultShortcut.displayString

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

    private let carbonHooks: CarbonHooks
    private var carbonEventHandler: EventHandlerRef?
    private var carbonEventHotKey: EventHotKeyRef?
    private var isEventHandlerInstalled = false
    private var isHotKeyRegistered = false
    private var onTrigger: (() -> Void)?
    private(set) var listenerStatus: ListenerStatus = .inactive

    init(carbonHooks: CarbonHooks = .live) {
        self.carbonHooks = carbonHooks
    }

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
        guard !isHotKeyRegistered else {
            return updateListenerStatus(.installed)
        }

        guard installEventHandlerIfNeeded() else {
            tearDownHotKey()
            return updateListenerStatus(.failedToRegister)
        }

        let hotKeyID = EventHotKeyID(signature: Self.eventHotKeySignature, id: 1)
        let (registerError, carbonEventHotKey) = carbonHooks.registerHotKey(Self.defaultShortcut, hotKeyID)

        guard registerError == noErr else {
            DebugLog.log(
                "Could not register the \(Self.defaultShortcutDisplay) shortcut via Carbon. error=\(registerError)",
                category: "hotkey"
            )
            tearDownHotKey()
            return updateListenerStatus(.failedToRegister)
        }

        self.carbonEventHotKey = carbonEventHotKey
        isHotKeyRegistered = true
        DebugLog.log("Installed \(Self.defaultShortcutDisplay) shortcut using Carbon hot key registration.", category: "hotkey")
        return updateListenerStatus(.installed)
    }

    private func installEventHandlerIfNeeded() -> Bool {
        guard !isEventHandlerInstalled else {
            return true
        }

        let callback: EventHandlerUPP = { _, event, userInfo in
            guard let userInfo else {
                return OSStatus(eventNotHandledErr)
            }

            let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
            return manager.handleCarbonEvent(event)
        }

        let (installStatus, carbonEventHandler) = carbonHooks.installEventHandler(
            callback,
            Unmanaged.passUnretained(self).toOpaque()
        )

        guard installStatus == noErr else {
            DebugLog.log("Could not install a Carbon event handler for the \(Self.defaultShortcutDisplay) shortcut. error=\(installStatus)", category: "hotkey")
            return false
        }

        self.carbonEventHandler = carbonEventHandler
        isEventHandlerInstalled = true
        return true
    }

    private func tearDownHotKey() {
        if let carbonEventHotKey {
            carbonHooks.unregisterHotKey(carbonEventHotKey)
            self.carbonEventHotKey = nil
        }
        isHotKeyRegistered = false

        if let carbonEventHandler {
            carbonHooks.removeEventHandler(carbonEventHandler)
            self.carbonEventHandler = nil
        }
        isEventHandlerInstalled = false
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
