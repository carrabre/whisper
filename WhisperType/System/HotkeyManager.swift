import Foundation
import HotKey

final class HotkeyManager {
    static let defaultShortcutDisplay = "Command+Shift+Space"

    private var hotKey: HotKey?

    func installDefault(onKeyDown: @escaping () -> Void, onKeyUp: @escaping () -> Void) {
        let hotKey = HotKey(key: .space, modifiers: [.command, .shift])
        hotKey.keyDownHandler = onKeyDown
        hotKey.keyUpHandler = onKeyUp
        self.hotKey = hotKey
    }
}
