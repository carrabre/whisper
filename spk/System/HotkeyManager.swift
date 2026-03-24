import Foundation
import HotKey

final class HotkeyManager {
    static let defaultShortcutDisplay = "Command+Option+Space"

    private var hotKey: HotKey?

    func installDefault(onTrigger: @escaping () -> Void) {
        let hotKey = HotKey(key: .space, modifiers: [.command, .option])
        hotKey.keyDownHandler = onTrigger
        self.hotKey = hotKey
    }
}
