import AppKit
import ApplicationServices
import Foundation

final class TextInsertionService {
    struct Target: Equatable {
        let applicationPID: pid_t
        let applicationName: String
        let bundleIdentifier: String?
    }

    enum InsertionOutcome: Equatable {
        case skippedEmptyTranscript
        case insertedAccessibility
        case insertedTyping
        case insertedPaste
        case secureFieldBlocked
        case permissionMissing
        case failedToInsert
        case copiedToClipboardAfterFailure

        func statusMessage(autoCopied: Bool) -> String {
            switch self {
            case .skippedEmptyTranscript:
                return "Transcription ready."
            case .insertedAccessibility:
                return autoCopied
                    ? "Inserted transcription into the focused app and copied it to the clipboard."
                    : "Inserted transcription into the focused app."
            case .insertedTyping:
                return autoCopied
                    ? "Typed transcription into the focused app and copied it to the clipboard."
                    : "Typed transcription into the focused app."
            case .insertedPaste:
                return autoCopied
                    ? "Pasted transcription into the focused app and copied it to the clipboard."
                    : "Pasted transcription into the focused app."
            case .secureFieldBlocked:
                return autoCopied
                    ? "Blocked insertion because the focused field appears to be secure. Copied the transcript to the clipboard."
                    : "Blocked insertion because the focused field appears to be secure."
            case .permissionMissing:
                return autoCopied
                    ? "Accessibility permission is required before spk can type into other apps. Copied the transcript to the clipboard."
                    : "Accessibility permission is required before spk can type into other apps."
            case .failedToInsert:
                return "Couldn't insert into the focused app. Use the transcript card in spk to copy it."
            case .copiedToClipboardAfterFailure:
                return "Couldn't insert into the focused app. Copied the transcript to the clipboard instead."
            }
        }

        var logDescription: String {
            switch self {
            case .skippedEmptyTranscript:
                return "skipped-empty"
            case .insertedAccessibility:
                return "inserted-accessibility"
            case .insertedTyping:
                return "inserted-typing"
            case .insertedPaste:
                return "inserted-paste"
            case .secureFieldBlocked:
                return "blocked-secure-field"
            case .permissionMissing:
                return "missing-permission"
            case .failedToInsert:
                return "failed"
            case .copiedToClipboardAfterFailure:
                return "copied-after-failure"
            }
        }
    }

    struct InsertionOptions {
        let restoreClipboardAfterPaste: Bool
        let copyToClipboardOnFailure: Bool

        static let `default` = InsertionOptions(
            restoreClipboardAfterPaste: true,
            copyToClipboardOnFailure: true
        )
    }

    struct VerificationSnapshot: Equatable {
        let text: String
        let selectedRange: NSRange?
    }

    struct FocusContext {
        enum Source: String {
            case targetApplication = "target-app"
            case systemWide = "system-wide"
        }

        let element: AXUIElement?
        let source: Source
        let applicationPID: pid_t
        let applicationName: String?
        let bundleIdentifier: String?
        let snapshot: VerificationSnapshot?
        let isSecure: Bool
        let role: String?
        let subrole: String?
        let canSetSelectedText: Bool
        let canSetValue: Bool

        init(
            element: AXUIElement?,
            source: Source,
            applicationPID: pid_t,
            applicationName: String?,
            bundleIdentifier: String?,
            snapshot: VerificationSnapshot?,
            isSecure: Bool,
            role: String?,
            subrole: String?,
            canSetSelectedText: Bool = false,
            canSetValue: Bool = false
        ) {
            self.element = element
            self.source = source
            self.applicationPID = applicationPID
            self.applicationName = applicationName
            self.bundleIdentifier = bundleIdentifier
            self.snapshot = snapshot
            self.isSecure = isSecure
            self.role = role
            self.subrole = subrole
            self.canSetSelectedText = canSetSelectedText
            self.canSetValue = canSetValue
        }

        var isDirectlyWritable: Bool {
            canSetSelectedText || canSetValue
        }
    }

    struct Environment {
        let isProcessTrusted: () -> Bool
        let currentFocusedTarget: () -> Target?
        let activateTarget: (Target?) -> Void
        let resolveFocusContext: (Target?) -> FocusContext?
        let attemptAccessibilityInsert: (String, FocusContext) -> Bool
        let attemptTypingInsert: (String, Target?) -> Bool
        let attemptPasteInsert: (String, Target?, InsertionOptions) -> Bool
        let currentSnapshot: (FocusContext) -> VerificationSnapshot?
        let copyTextToClipboard: (String) -> Void
    }

    private enum VerificationOutcome {
        case verified
        case failed
        case unverifiable
    }

    private enum TargetFamily: String {
        case nativeTextControl = "native-text-control"
        case browserOrElectron = "browser-or-electron"
        case codeEditor = "code-editor"
        case terminalOrConsole = "terminal-or-console"
        case other = "other"
    }

    private enum StrategyKind: String {
        case accessibility = "accessibility"
        case typing = "typing"
        case paste = "paste"

        var outcome: InsertionOutcome {
            switch self {
            case .accessibility:
                return .insertedAccessibility
            case .typing:
                return .insertedTyping
            case .paste:
                return .insertedPaste
            }
        }
    }

    private struct InsertionPolicy {
        let targetFamily: TargetFamily
        let strategyOrder: [StrategyKind]
    }

    private let workspace: NSWorkspace
    private let environment: Environment
    private let ownBundleIdentifier = Bundle.main.bundleIdentifier
    private var workspaceObserver: NSObjectProtocol?
    private var lastExternalTarget: Target?

    private static let browserBundlePrefixes = [
        "com.apple.safari",
        "com.google.chrome",
        "com.microsoft.edgemac",
        "org.mozilla.firefox",
        "com.brave.browser",
        "com.operasoftware.opera",
        "com.vivaldi.vivaldi"
    ]
    private static let codeEditorBundlePrefixes = [
        "com.microsoft.vscode",
        "com.todesktop.cursor",
        "com.jetbrains."
    ]
    private static let terminalBundlePrefixes = [
        "com.apple.terminal",
        "com.googlecode.iterm2",
        "dev.warp.warp",
        "dev.warp.warp-stable",
        "net.kovidgoyal.kitty",
        "org.alacritty",
        "com.github.wez.wezterm",
        "co.zeit.hyper"
    ]
    private static let nativeTextRoles = Set([
        "AXComboBox",
        "AXSearchField",
        "AXTextArea",
        "AXTextField",
        "AXTextView"
    ])

    init(workspace: NSWorkspace = .shared, environment: Environment? = nil) {
        self.workspace = workspace
        self.environment = environment ?? Self.liveEnvironment(workspace: workspace)

        if let frontmostApplication = workspace.frontmostApplication,
           let target = target(from: frontmostApplication) {
            lastExternalTarget = target
        }

        workspaceObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: workspace,
            queue: nil
        ) { [weak self] notification in
            guard
                let self,
                let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                let target = self.target(from: application)
            else {
                return
            }

            self.lastExternalTarget = target
        }
    }

    deinit {
        if let workspaceObserver {
            NotificationCenter.default.removeObserver(workspaceObserver)
        }
    }

    func captureInsertionTarget() -> Target? {
        if let focusedTarget = environment.currentFocusedTarget() {
            lastExternalTarget = focusedTarget
            DebugLog.log("Captured insertion target from the focused app: \(describe(focusedTarget))", category: "insertion")
            return focusedTarget
        }

        if let frontmostApplication = workspace.frontmostApplication,
           let target = target(from: frontmostApplication) {
            lastExternalTarget = target
            DebugLog.log("Captured insertion target: \(describe(target))", category: "insertion")
            return target
        }

        if let lastExternalTarget {
            DebugLog.log("Falling back to last external insertion target: \(describe(lastExternalTarget))", category: "insertion")
            return lastExternalTarget
        }

        DebugLog.log("No external insertion target could be captured.", category: "insertion")
        return nil
    }

    @discardableResult
    func insert(
        _ text: String,
        target preferredTarget: Target? = nil,
        options: InsertionOptions = .default
    ) -> InsertionOutcome {
        guard environment.isProcessTrusted() else {
            DebugLog.log("Insertion blocked because accessibility permission is missing.", category: "insertion")
            return .permissionMissing
        }

        guard !text.isEmpty else {
            DebugLog.log("Insertion skipped because transcript was empty.", category: "insertion")
            return .skippedEmptyTranscript
        }

        let target = resolvedInsertionTarget(preferredTarget)
        DebugLog.log("Attempting insertion. target=\(describe(target))", category: "insertion")

        environment.activateTarget(target)

        var focus = resolveFocusContextAndLog(for: target)
        if focus?.isSecure == true {
            DebugLog.log("Blocking insertion because the focused element appears to be secure.", category: "insertion")
            return .secureFieldBlocked
        }

        let policy = insertionPolicy(for: target, focus: focus)
        DebugLog.log(
            "Using insertion policy family=\(policy.targetFamily.rawValue) strategies=\(policy.strategyOrder.map(\.rawValue).joined(separator: ","))",
            category: "insertion"
        )

        for strategy in policy.strategyOrder {
            if let outcome = attemptStrategy(
                strategy,
                text: text,
                target: target,
                focus: &focus,
                options: options
            ) {
                DebugLog.log(
                    "Inserted transcript using \(strategy.rawValue). Length: \(text.count) target=\(describe(target)) family=\(policy.targetFamily.rawValue)",
                    category: "insertion"
                )
                return outcome
            }

            if focus?.isSecure == true {
                DebugLog.log("Blocking insertion because the refreshed focus appears to be secure.", category: "insertion")
                return .secureFieldBlocked
            }
        }

        guard options.copyToClipboardOnFailure else {
            DebugLog.log("Insertion failed and clipboard fallback is disabled. target=\(describe(target))", category: "insertion")
            return .failedToInsert
        }

        environment.copyTextToClipboard(text)
        DebugLog.log("Copied transcript to clipboard after insertion failed. target=\(describe(target))", category: "insertion")
        return .copiedToClipboardAfterFailure
    }

    func copyToClipboard(_ text: String) {
        guard !text.isEmpty else { return }
        environment.copyTextToClipboard(text)
        DebugLog.log("Copied transcript to clipboard explicitly. Length: \(text.count)", category: "insertion")
    }

    private func resolvedInsertionTarget(_ preferredTarget: Target?) -> Target? {
        if let focusedTarget = environment.currentFocusedTarget() {
            lastExternalTarget = focusedTarget
            DebugLog.log("Using focused app as insertion target: \(describe(focusedTarget))", category: "insertion")
            return focusedTarget
        }

        if let preferredTarget {
            lastExternalTarget = preferredTarget
            DebugLog.log("Using previously captured insertion target: \(describe(preferredTarget))", category: "insertion")
            return preferredTarget
        }

        return captureInsertionTarget()
    }

    private func insertionPolicy(for target: Target?, focus: FocusContext?) -> InsertionPolicy {
        let targetFamily = classifyTargetFamily(target: target, focus: focus)
        let prefersPasteBeforeTyping: Bool
        if focus?.snapshot == nil {
            prefersPasteBeforeTyping = true
        } else {
            switch targetFamily {
            case .browserOrElectron, .codeEditor, .terminalOrConsole:
                prefersPasteBeforeTyping = true
            case .nativeTextControl, .other:
                prefersPasteBeforeTyping = false
            }
        }

        return InsertionPolicy(
            targetFamily: targetFamily,
            strategyOrder: prefersPasteBeforeTyping
                ? [.accessibility, .paste, .typing]
                : [.accessibility, .typing, .paste]
        )
    }

    private func classifyTargetFamily(target: Target?, focus: FocusContext?) -> TargetFamily {
        let bundleIdentifier = (target?.bundleIdentifier ?? focus?.bundleIdentifier ?? "").lowercased()
        if Self.matchesBundle(bundleIdentifier, prefixes: Self.terminalBundlePrefixes) {
            return .terminalOrConsole
        }

        if Self.matchesBundle(bundleIdentifier, prefixes: Self.codeEditorBundlePrefixes) {
            return .codeEditor
        }

        if Self.matchesBundle(bundleIdentifier, prefixes: Self.browserBundlePrefixes) {
            return .browserOrElectron
        }

        if let focus, Self.isNativeTextControlFocus(focus) {
            return .nativeTextControl
        }

        return .other
    }

    private func attemptStrategy(
        _ strategy: StrategyKind,
        text: String,
        target: Target?,
        focus: inout FocusContext?,
        options: InsertionOptions
    ) -> InsertionOutcome? {
        for attempt in 0..<2 {
            if runStrategy(strategy, text: text, target: target, focus: focus, options: options) {
                return strategy.outcome
            }

            guard attempt == 0 else { break }

            DebugLog.log(
                "\(strategy.rawValue) insertion attempt failed. Reactivating target and refreshing focus before retry.",
                category: "insertion"
            )
            focus = refreshFocusAfterFailure(target: target, failedStrategy: strategy)
        }

        return nil
    }

    private func runStrategy(
        _ strategy: StrategyKind,
        text: String,
        target: Target?,
        focus: FocusContext?,
        options: InsertionOptions
    ) -> Bool {
        switch strategy {
        case .accessibility:
            guard let focus else {
                DebugLog.log("No AX focus context available for Accessibility insertion.", category: "insertion")
                return false
            }

            guard focus.isDirectlyWritable else {
                DebugLog.log("Skipping Accessibility insertion because the focused element does not report a writable text attribute.", category: "insertion")
                return false
            }

            return environment.attemptAccessibilityInsert(text, focus)
        case .typing:
            environment.activateTarget(target)
            guard environment.attemptTypingInsert(text, target) else {
                DebugLog.log("Synthetic typing was unavailable.", category: "insertion")
                return false
            }
            return verifyStrategyResult(for: focus, strategy: strategy)
        case .paste:
            environment.activateTarget(target)
            guard environment.attemptPasteInsert(text, target, options) else {
                DebugLog.log("Paste fallback was unavailable.", category: "insertion")
                return false
            }
            return verifyStrategyResult(for: focus, strategy: strategy)
        }
    }

    private func verifyStrategyResult(for focus: FocusContext?, strategy: StrategyKind) -> Bool {
        let strategyDescription: String
        switch strategy {
        case .accessibility:
            strategyDescription = "accessibility"
        case .typing:
            strategyDescription = "typed"
        case .paste:
            strategyDescription = "paste"
        }

        switch verifyInsertionResult(for: focus, strategy: strategyDescription) {
        case .verified, .unverifiable:
            return true
        case .failed:
            switch strategy {
            case .typing:
                DebugLog.log("Synthetic typing did not produce a verifiable change.", category: "insertion")
            case .paste:
                DebugLog.log("Paste fallback did not produce a verifiable change.", category: "insertion")
            case .accessibility:
                break
            }
            return false
        }
    }

    private func refreshFocusAfterFailure(target: Target?, failedStrategy: StrategyKind) -> FocusContext? {
        environment.activateTarget(target)
        let refreshedFocus = resolveFocusContextAndLog(for: target)
        if refreshedFocus?.isSecure == true {
            DebugLog.log(
                "Recovered focus after \(failedStrategy.rawValue) attempt appears to be secure.",
                category: "insertion"
            )
        }
        return refreshedFocus
    }

    private func resolveFocusContextAndLog(for target: Target?) -> FocusContext? {
        let focus = environment.resolveFocusContext(target)
        if let focus {
            DebugLog.log(
                "Resolved focus source=\(focus.source.rawValue) owner=\(focus.applicationName ?? "unknown") pid=\(focus.applicationPID) bundle=\(focus.bundleIdentifier ?? "unknown") role=\(focus.role ?? "unknown") subrole=\(focus.subrole ?? "none") secure=\(focus.isSecure) verifiable=\(focus.snapshot != nil) writableSelected=\(focus.canSetSelectedText) writableValue=\(focus.canSetValue)",
                category: "insertion"
            )
        } else {
            DebugLog.log("Proceeding without an AX focus context; non-AX fallbacks will be best-effort.", category: "insertion")
        }

        return focus
    }

    private func verifyInsertionResult(for focus: FocusContext?, strategy: String) -> VerificationOutcome {
        guard let focus,
              let baseline = focus.snapshot else {
            DebugLog.log("No AX snapshot available to verify \(strategy) insertion.", category: "insertion")
            return .unverifiable
        }

        for _ in 0..<3 {
            Thread.sleep(forTimeInterval: 0.08)

            guard let current = environment.currentSnapshot(focus) else {
                DebugLog.log("AX snapshot became unavailable while verifying \(strategy) insertion.", category: "insertion")
                return .unverifiable
            }

            if current != baseline {
                DebugLog.log("Verified \(strategy) insertion by observing an AX-readable change.", category: "insertion")
                return .verified
            }
        }

        return .failed
    }

    private func target(from application: NSRunningApplication) -> Target? {
        if let ownBundleIdentifier,
           application.bundleIdentifier == ownBundleIdentifier {
            return nil
        }

        return Target(
            applicationPID: application.processIdentifier,
            applicationName: application.localizedName ?? "pid:\(application.processIdentifier)",
            bundleIdentifier: application.bundleIdentifier
        )
    }

    private func describe(_ target: Target?) -> String {
        guard let target else { return "current-focus" }
        return "\(target.applicationName) pid=\(target.applicationPID) bundle=\(target.bundleIdentifier ?? "unknown")"
    }

    private static func matchesBundle(_ bundleIdentifier: String, prefixes: [String]) -> Bool {
        !bundleIdentifier.isEmpty && prefixes.contains { bundleIdentifier.hasPrefix($0) }
    }

    private static func isNativeTextControlFocus(_ focus: FocusContext) -> Bool {
        guard focus.snapshot != nil, focus.isDirectlyWritable else {
            return false
        }

        if let role = focus.role, nativeTextRoles.contains(role) {
            return true
        }

        return focus.canSetValue && focus.snapshot?.selectedRange != nil
    }
}

private extension TextInsertionService {
    static func liveEnvironment(workspace: NSWorkspace) -> Environment {
        Environment(
            isProcessTrusted: { AXIsProcessTrusted() },
            currentFocusedTarget: {
                Self.currentFocusedTarget(excludingBundleIdentifier: Bundle.main.bundleIdentifier)
            },
            activateTarget: { target in
                activateTargetApplicationIfNeeded(target, workspace: workspace)
            },
            resolveFocusContext: { target in
                resolveFocusContext(for: target)
            },
            attemptAccessibilityInsert: { text, focus in
                insertUsingAccessibility(text, focus: focus)
            },
            attemptTypingInsert: { text, target in
                insertUsingTyping(text, target: target)
            },
            attemptPasteInsert: { text, target, options in
                insertUsingPasteboard(
                    text,
                    target: target,
                    restoreClipboardAfterPaste: options.restoreClipboardAfterPaste
                )
            },
            currentSnapshot: { focus in
                guard let element = focus.element else { return nil }
                return verificationSnapshot(for: element)
            },
            copyTextToClipboard: { text in
                copyTextToClipboard(text)
            }
        )
    }

    static func currentFocusedTarget(excludingBundleIdentifier: String?) -> TextInsertionService.Target? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )

        guard result == .success, let focusedRef else {
            return nil
        }

        let element = unsafeBitCast(focusedRef, to: AXUIElement.self)
        guard let application = runningApplication(for: element) else {
            return nil
        }

        if let excludingBundleIdentifier,
           application.bundleIdentifier == excludingBundleIdentifier {
            return nil
        }

        return TextInsertionService.Target(
            applicationPID: application.processIdentifier,
            applicationName: application.localizedName ?? "pid:\(application.processIdentifier)",
            bundleIdentifier: application.bundleIdentifier
        )
    }

    static func resolveFocusContext(for target: Target?) -> FocusContext? {
        let deadline = Date().addingTimeInterval(0.6)
        var fallbackContext: FocusContext?

        repeat {
            if let target,
               let context = focusContextForTargetApplication(target) {
                fallbackContext = preferredFallbackContext(
                    current: fallbackContext,
                    candidate: context,
                    target: target
                )

                if isUsableFocusContext(context, target: target) {
                    return context
                }
            }

            if let systemContext = focusContextForSystemWideElement() {
                fallbackContext = preferredFallbackContext(
                    current: fallbackContext,
                    candidate: systemContext,
                    target: target
                )

                if isUsableFocusContext(systemContext, target: target) {
                    return systemContext
                }
            }

            if Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
        } while Date() < deadline

        if let fallbackContext {
            DebugLog.log(
                "Timed out waiting for a focused editable element. Falling back to source=\(fallbackContext.source.rawValue) owner=\(fallbackContext.applicationName ?? "unknown") pid=\(fallbackContext.applicationPID) bundle=\(fallbackContext.bundleIdentifier ?? "unknown") role=\(fallbackContext.role ?? "unknown") subrole=\(fallbackContext.subrole ?? "none")",
                category: "insertion"
            )
        }

        return fallbackContext
    }

    static func focusContextForTargetApplication(_ target: Target) -> FocusContext? {
        let applicationElement = AXUIElementCreateApplication(target.applicationPID)
        var focusedRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            applicationElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )

        guard result == .success, let focusedRef else {
            DebugLog.log(
                "Could not resolve focused UI element for target app \(target.applicationName) pid=\(target.applicationPID). Falling back to system-wide focus. Result: \(result.rawValue) (\(axErrorDescription(result)))",
                category: "insertion"
            )
            return nil
        }

        let element = unsafeBitCast(focusedRef, to: AXUIElement.self)
        return makeFocusContext(element: element, source: .targetApplication)
    }

    static func focusContextForSystemWideElement() -> FocusContext? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )

        guard result == .success, let focusedRef else {
            DebugLog.log(
                "Could not resolve focused UI element. Result: \(result.rawValue) (\(axErrorDescription(result)))",
                category: "insertion"
            )
            return nil
        }

        let element = unsafeBitCast(focusedRef, to: AXUIElement.self)
        return makeFocusContext(element: element, source: .systemWide)
    }

    static func makeFocusContext(element: AXUIElement, source: TextInsertionService.FocusContext.Source) -> TextInsertionService.FocusContext {
        let application = runningApplication(for: element)
        let role = stringAttribute(kAXRoleAttribute as CFString, from: element)
        let subrole = stringAttribute(kAXSubroleAttribute as CFString, from: element)
        let snapshot = verificationSnapshot(for: element)
        let isSecure = isSecureElement(element, role: role, subrole: subrole)
        let canSetSelectedText = isAttributeSettable(kAXSelectedTextAttribute as CFString, on: element)
        let canSetValue = isAttributeSettable(kAXValueAttribute as CFString, on: element)

        return TextInsertionService.FocusContext(
            element: element,
            source: source,
            applicationPID: application?.processIdentifier ?? 0,
            applicationName: application?.localizedName,
            bundleIdentifier: application?.bundleIdentifier,
            snapshot: snapshot,
            isSecure: isSecure,
            role: role,
            subrole: subrole,
            canSetSelectedText: canSetSelectedText,
            canSetValue: canSetValue
        )
    }

    static func preferredFallbackContext(
        current: TextInsertionService.FocusContext?,
        candidate: TextInsertionService.FocusContext,
        target: TextInsertionService.Target?
    ) -> TextInsertionService.FocusContext {
        guard let current else { return candidate }
        return focusPriority(for: candidate, target: target) >= focusPriority(for: current, target: target)
            ? candidate
            : current
    }

    static func focusPriority(
        for context: TextInsertionService.FocusContext,
        target: TextInsertionService.Target?
    ) -> Int {
        var priority = 0

        if context.source == .targetApplication {
            priority += 3
        }

        if let target,
           context.applicationPID == target.applicationPID {
            priority += 4
        }

        if context.snapshot != nil {
            priority += 3
        }

        if context.role != "AXWindow" {
            priority += 1
        }

        if context.subrole != "AXSystemDialog" {
            priority += 1
        }

        return priority
    }

    static func isUsableFocusContext(
        _ context: TextInsertionService.FocusContext,
        target: TextInsertionService.Target?
    ) -> Bool {
        if let ownBundleIdentifier = Bundle.main.bundleIdentifier,
           context.bundleIdentifier == ownBundleIdentifier {
            return false
        }

        if let target,
           context.applicationPID != 0,
           context.applicationPID != target.applicationPID {
            return false
        }

        if context.role == "AXWindow",
           context.subrole == "AXSystemDialog" {
            return false
        }

        return true
    }

    static func runningApplication(for element: AXUIElement) -> NSRunningApplication? {
        guard let applicationPID = pid(for: element),
              applicationPID != 0 else {
            return nil
        }

        return NSRunningApplication(processIdentifier: applicationPID)
    }

    static func pid(for element: AXUIElement) -> pid_t? {
        var applicationPID: pid_t = 0
        let pidResult = AXUIElementGetPid(element, &applicationPID)
        guard pidResult == .success else {
            return nil
        }

        return applicationPID
    }

    static func axErrorDescription(_ error: AXError) -> String {
        switch error {
        case .success:
            return "success"
        case .failure:
            return "failure"
        case .illegalArgument:
            return "illegal-argument"
        case .invalidUIElement:
            return "invalid-ui-element"
        case .invalidUIElementObserver:
            return "invalid-ui-element-observer"
        case .cannotComplete:
            return "cannot-complete"
        case .attributeUnsupported:
            return "attribute-unsupported"
        case .actionUnsupported:
            return "action-unsupported"
        case .notificationUnsupported:
            return "notification-unsupported"
        case .notImplemented:
            return "not-implemented"
        case .notificationAlreadyRegistered:
            return "notification-already-registered"
        case .notificationNotRegistered:
            return "notification-not-registered"
        case .apiDisabled:
            return "api-disabled"
        case .noValue:
            return "no-value"
        case .parameterizedAttributeUnsupported:
            return "parameterized-attribute-unsupported"
        case .notEnoughPrecision:
            return "not-enough-precision"
        @unknown default:
            return "unknown"
        }
    }

    static func insertUsingAccessibility(_ text: String, focus: TextInsertionService.FocusContext) -> Bool {
        guard let element = focus.element else { return false }

        if focus.canSetSelectedText {
            let selectedTextResult = AXUIElementSetAttributeValue(
                element,
                kAXSelectedTextAttribute as CFString,
                text as CFTypeRef
            )
            if selectedTextResult == .success {
                DebugLog.log("Inserted transcript by replacing the selected text attribute.", category: "insertion")
                return true
            }

            DebugLog.log(
                "Selected text attribute write was unavailable. Result: \(selectedTextResult.rawValue) (\(axErrorDescription(selectedTextResult))) role=\(focus.role ?? "unknown") subrole=\(focus.subrole ?? "none")",
                category: "insertion"
            )
        } else {
            DebugLog.log("Selected text attribute is not settable on the focused element.", category: "insertion")
        }

        guard focus.canSetValue,
              let snapshot = focus.snapshot,
              let selection = snapshot.selectedRange else {
            DebugLog.log("Focused element does not expose a writable value/selection.", category: "insertion")
            return false
        }

        return replaceValueInFocusedElement(text, focus: focus, snapshot: snapshot, range: selection)
    }

    static func replaceValueInFocusedElement(
        _ text: String,
        focus: TextInsertionService.FocusContext,
        snapshot: TextInsertionService.VerificationSnapshot,
        range: NSRange
    ) -> Bool {
        guard let element = focus.element else {
            DebugLog.log("Focused element replacement failed because no AX element was available.", category: "insertion")
            return false
        }

        let currentNSString = snapshot.text as NSString
        guard range.location >= 0, NSMaxRange(range) <= currentNSString.length else {
            DebugLog.log("Focused element selection was out of bounds for the current value.", category: "insertion")
            return false
        }

        let replacement = currentNSString.replacingCharacters(in: range, with: text)
        let setValueResult = AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            replacement as CFTypeRef
        )

        guard setValueResult == .success else {
            DebugLog.log(
                "Failed to set focused element value via Accessibility. Result: \(setValueResult.rawValue) (\(axErrorDescription(setValueResult)))",
                category: "insertion"
            )
            return false
        }

        var newSelection = CFRange(location: range.location + (text as NSString).length, length: 0)
        if let newSelectionValue = AXValueCreate(.cfRange, &newSelection) {
            _ = AXUIElementSetAttributeValue(
                element,
                kAXSelectedTextRangeAttribute as CFString,
                newSelectionValue
            )
        }

        return true
    }

    static func insertUsingTyping(_ text: String, target: TextInsertionService.Target?) -> Bool {
        DebugLog.log(
            "Attempting synthetic typing fallback. Length: \(text.count) target=\(describe(target)) frontmost=\(describeCurrentFrontmostApplication())",
            category: "insertion"
        )

        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            DebugLog.log("Could not create a CGEvent source for typing fallback.", category: "insertion")
            return false
        }

        for character in text {
            if character == "\n" || character == "\r" {
                guard postVirtualKey(36, flags: [], source: source) else {
                    DebugLog.log("Failed to post Return key during synthetic typing.", category: "insertion")
                    return false
                }
                continue
            }

            let unicodeScalars = Array(String(character).utf16)
            guard !unicodeScalars.isEmpty,
                  let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                DebugLog.log("Could not create Unicode keyboard events for typing fallback.", category: "insertion")
                return false
            }

            unicodeScalars.withUnsafeBufferPointer { buffer in
                guard let baseAddress = buffer.baseAddress else { return }
                keyDown.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: baseAddress)
                keyUp.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: baseAddress)
            }

            keyDown.post(tap: .cgAnnotatedSessionEventTap)
            keyUp.post(tap: .cgAnnotatedSessionEventTap)
        }

        DebugLog.log("Posted Unicode typing events for target=\(describe(target))", category: "insertion")
        return true
    }

    static func insertUsingPasteboard(
        _ text: String,
        target: TextInsertionService.Target?,
        restoreClipboardAfterPaste: Bool
    ) -> Bool {
        DebugLog.log(
            "Attempting paste fallback. Length: \(text.count) target=\(describe(target)) frontmost=\(describeCurrentFrontmostApplication()) restoreClipboard=\(restoreClipboardAfterPaste)",
            category: "insertion"
        )

        let pasteboard = NSPasteboard.general
        let previousItems: [NSPasteboardItem]?
        if restoreClipboardAfterPaste {
            DebugLog.log("Capturing current clipboard contents before paste fallback.", category: "insertion")
            previousItems = pasteboard.pasteboardItems?.compactMap { $0.copy() as? NSPasteboardItem }
            DebugLog.log(
                "Captured \(previousItems?.count ?? 0) clipboard item(s) for later restore.",
                category: "insertion"
            )
        } else {
            previousItems = nil
            DebugLog.log("Skipping clipboard snapshot because restoreClipboardAfterPaste is false.", category: "insertion")
        }

        DebugLog.log("Clearing pasteboard before writing transcript.", category: "insertion")
        pasteboard.clearContents()
        let wroteString = pasteboard.setString(text, forType: .string)
        DebugLog.log(
            "Prepared pasteboard with transcript. wroteString=\(wroteString) changeCount=\(pasteboard.changeCount)",
            category: "insertion"
        )

        guard let source = CGEventSource(stateID: .combinedSessionState),
              postVirtualKey(9, flags: .maskCommand, source: source) else {
            DebugLog.log("Could not create pasteboard insertion events.", category: "insertion")
            return false
        }

        DebugLog.log("Posted paste shortcut to the current session focus. target=\(describe(target))", category: "insertion")

        if restoreClipboardAfterPaste {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                DebugLog.log("Restoring clipboard contents after paste fallback.", category: "insertion")
                pasteboard.clearContents()
                if let previousItems, !previousItems.isEmpty {
                    pasteboard.writeObjects(previousItems)
                }
            }
        }

        return true
    }

    static func copyTextToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    static func verificationSnapshot(for element: AXUIElement) -> TextInsertionService.VerificationSnapshot? {
        guard let textValue = textValue(for: element) else {
            return nil
        }

        let range = selectedRange(for: element).map { NSRange(location: $0.location, length: $0.length) }
        return TextInsertionService.VerificationSnapshot(text: textValue, selectedRange: range)
    }

    static func textValue(for element: AXUIElement) -> String? {
        var valueRef: CFTypeRef?
        let valueResult = AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &valueRef
        )

        guard valueResult == .success else {
            return nil
        }

        if let stringValue = valueRef as? String {
            return stringValue
        }

        if let attributedValue = valueRef as? NSAttributedString {
            return attributedValue.string
        }

        return nil
    }

    static func stringAttribute(_ attribute: CFString, from element: AXUIElement) -> String? {
        var valueRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &valueRef)
        guard result == .success else {
            return nil
        }

        return valueRef as? String
    }

    static func isAttributeSettable(_ attribute: CFString, on element: AXUIElement) -> Bool {
        var isSettable = DarwinBoolean(false)
        let result = AXUIElementIsAttributeSettable(element, attribute, &isSettable)
        guard result == .success else {
            return false
        }

        return isSettable.boolValue
    }

    static func isSecureElement(_ element: AXUIElement, role: String?, subrole: String?) -> Bool {
        let secureNames = ["AXSecureTextField", "SecureTextField"]
        if secureNames.contains(where: { role == $0 || subrole == $0 }) {
            return true
        }

        if let roleDescription = stringAttribute(kAXRoleDescriptionAttribute as CFString, from: element)?
            .lowercased(),
           roleDescription.contains("secure") || roleDescription.contains("password") {
            return true
        }

        return false
    }

    static func selectedRange(for element: AXUIElement) -> CFRange? {
        var rangeRef: CFTypeRef?
        let singularResult = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeRef
        )

        if singularResult == .success,
           let rangeRef,
           let selection = extractRange(from: rangeRef) {
            return selection
        }

        var rangesRef: CFTypeRef?
        let pluralResult = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangesAttribute as CFString,
            &rangesRef
        )

        if pluralResult == .success,
           let ranges = rangesRef as? [Any],
           let firstRange = ranges.first {
            return extractRange(from: firstRange as CFTypeRef)
        }

        return nil
    }

    static func extractRange(from value: CFTypeRef) -> CFRange? {
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

    static func activateTargetApplicationIfNeeded(_ target: TextInsertionService.Target?, workspace: NSWorkspace) {
        guard let target else { return }
        guard let application = NSRunningApplication(processIdentifier: target.applicationPID) else {
            DebugLog.log("Could not reactivate target app because it is no longer running: \(describe(target))", category: "insertion")
            return
        }

        let activated = application.activate(options: [.activateIgnoringOtherApps])
        DebugLog.log("Reactivated target app=\(describe(target)) success=\(activated)", category: "insertion")

        let deadline = Date().addingTimeInterval(0.35)
        while Date() < deadline {
            if workspace.frontmostApplication?.processIdentifier == target.applicationPID {
                break
            }

            Thread.sleep(forTimeInterval: 0.02)
        }

        Thread.sleep(forTimeInterval: 0.08)
        DebugLog.log(
            "Frontmost app after activation wait: \(describeCurrentFrontmostApplication())",
            category: "insertion"
        )
    }

    static func postVirtualKey(_ keyCode: CGKeyCode, flags: CGEventFlags, source: CGEventSource) -> Bool {
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            DebugLog.log(
                "Could not create keyboard events for virtual key \(keyCode) flags=\(flags.rawValue).",
                category: "insertion"
            )
            return false
        }

        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        keyUp.post(tap: .cgAnnotatedSessionEventTap)
        DebugLog.log(
            "Posted virtual key \(keyCode) flags=\(flags.rawValue) via annotated session tap.",
            category: "insertion"
        )
        return true
    }

    static func describe(_ target: TextInsertionService.Target?) -> String {
        guard let target else { return "current-focus" }
        return "\(target.applicationName) pid=\(target.applicationPID) bundle=\(target.bundleIdentifier ?? "unknown")"
    }

    static func describeCurrentFrontmostApplication() -> String {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication else {
            return "unknown-frontmost"
        }

        return "\(frontmostApplication.localizedName ?? "pid:\(frontmostApplication.processIdentifier)") pid=\(frontmostApplication.processIdentifier) bundle=\(frontmostApplication.bundleIdentifier ?? "unknown")"
    }
}
