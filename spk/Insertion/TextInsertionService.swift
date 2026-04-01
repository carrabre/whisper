import AppKit
import ApplicationServices
import Foundation

final class TextInsertionService {
    struct Target: Equatable {
        let applicationPID: pid_t
        let applicationName: String
        let bundleIdentifier: String?
    }

    struct TargetMetadata: Equatable {
        let isLikelyElectron: Bool
        let isCodeEditor: Bool
    }

    struct CapturedInsertionContext {
        struct ProbeMetadata {
            let source: FocusContext.Source
            let matchedTarget: Bool
            let role: String?
            let subrole: String?
            let securityState: FocusContext.SecurityState?
            let hasSnapshot: Bool
            let canSetSelectedText: Bool
            let canSetValue: Bool
            let axErrorCode: Int32?
            let axErrorDescription: String?
            let applicationPID: pid_t?
            let applicationName: String?
            let bundleIdentifier: String?
            let usable: Bool
        }

        let target: Target
        let focusContext: FocusContext?
        let captureMethod: String
        let targetFamily: TargetFamily
        let targetApplicationProbe: ProbeMetadata
        let systemWideProbe: ProbeMetadata

        static func testing(
            target: Target,
            focusContext: FocusContext? = nil,
            captureMethod: String = "testing",
            targetFamily: TargetFamily? = nil,
            targetApplicationProbe: ProbeMetadata? = nil,
            systemWideProbe: ProbeMetadata? = nil
        ) -> CapturedInsertionContext {
            let resolvedTargetFamily = targetFamily ?? inferredTestingTargetFamily(for: target, focusContext: focusContext)
            let defaultProbe = probeMetadata(
                source: .targetApplication,
                focusContext: focusContext,
                matchedTarget: focusContext.map { $0.applicationPID == target.applicationPID } ?? false,
                error: nil,
                usable: focusContext.map {
                    $0.applicationPID == target.applicationPID &&
                    $0.securityState == .notSecure
                } ?? false
            )
            let defaultSystemProbe = probeMetadata(
                source: .systemWide,
                focusContext: focusContext,
                matchedTarget: focusContext.map { $0.applicationPID == target.applicationPID } ?? false,
                error: nil,
                usable: false
            )

            return CapturedInsertionContext(
                target: target,
                focusContext: focusContext,
                captureMethod: captureMethod,
                targetFamily: resolvedTargetFamily,
                targetApplicationProbe: targetApplicationProbe ?? defaultProbe,
                systemWideProbe: systemWideProbe ?? defaultSystemProbe
            )
        }

        private static func inferredTestingTargetFamily(
            for target: Target,
            focusContext: FocusContext?
        ) -> TargetFamily {
            let bundleIdentifier = (target.bundleIdentifier ?? focusContext?.bundleIdentifier ?? "").lowercased()
            if TextInsertionService.matchesBundle(bundleIdentifier, prefixes: TextInsertionService.terminalBundlePrefixes) {
                return .terminalOrConsole
            }
            if TextInsertionService.matchesBundle(bundleIdentifier, prefixes: TextInsertionService.codeEditorBundlePrefixes) {
                return .codeEditor
            }
            if TextInsertionService.matchesBundle(bundleIdentifier, prefixes: TextInsertionService.browserBundlePrefixes) {
                return .browserOrElectron
            }
            if focusContext?.role == "AXWebArea" {
                return .browserOrElectron
            }
            if let focusContext, TextInsertionService.isNativeTextControlFocus(focusContext) {
                return .nativeTextControl
            }
            return .other
        }

        private static func probeMetadata(
            source: FocusContext.Source,
            focusContext: FocusContext?,
            matchedTarget: Bool,
            error: AXError?,
            usable: Bool
        ) -> ProbeMetadata {
            ProbeMetadata(
                source: source,
                matchedTarget: matchedTarget,
                role: focusContext?.role,
                subrole: focusContext?.subrole,
                securityState: focusContext?.securityState,
                hasSnapshot: focusContext?.snapshot != nil,
                canSetSelectedText: focusContext?.canSetSelectedText ?? false,
                canSetValue: focusContext?.canSetValue ?? false,
                axErrorCode: error.map { Int32($0.rawValue) },
                axErrorDescription: error.map { TextInsertionService.axErrorDescription($0) },
                applicationPID: focusContext?.applicationPID,
                applicationName: focusContext?.applicationName,
                bundleIdentifier: focusContext?.bundleIdentifier,
                usable: usable
            )
        }
    }

    final class StreamingSession {
        enum Mode {
            case accessibility(anchorLocation: Int)
            case typingVerified
            case typingBlind
        }

        fileprivate let target: Target?
        fileprivate let capturedContext: CapturedInsertionContext?
        fileprivate let mode: Mode
        fileprivate var currentText = ""
        private(set) var isHealthy = true

        init(target: Target?, capturedContext: CapturedInsertionContext?, mode: Mode) {
            self.target = target
            self.capturedContext = capturedContext
            self.mode = mode
        }

        func markDegraded() {
            isHealthy = false
        }

        func markHealthy() {
            isHealthy = true
        }

        static func testing(
            target: Target? = nil,
            capturedContext: CapturedInsertionContext? = nil,
            mode: Mode = .typingVerified
        ) -> StreamingSession {
            StreamingSession(target: target, capturedContext: capturedContext, mode: mode)
        }
    }

    enum InsertionOutcome: Equatable {
        case skippedEmptyTranscript
        case insertedAccessibility
        case insertedTyping
        case insertedPaste
        case secureFieldBlocked
        case privacyGuardBlocked
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
            case .privacyGuardBlocked:
                return autoCopied
                    ? "Couldn't safely insert into the focused app. Copied the transcript to the clipboard."
                    : "Couldn't safely insert into the focused app. Use Copy."
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
            case .privacyGuardBlocked:
                return "blocked-privacy-guard"
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
        let allowPasteFallback: Bool

        static let `default` = InsertionOptions(
            restoreClipboardAfterPaste: true,
            copyToClipboardOnFailure: true,
            allowPasteFallback: true
        )
    }

    struct VerificationSnapshot: Equatable {
        let text: String
        let selectedRange: NSRange?
    }

    struct FocusContext {
        enum SecurityState: String {
            case secure = "secure"
            case notSecure = "not-secure"
            case unknown = "unknown"
        }

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
        let securityState: SecurityState
        let role: String?
        let subrole: String?
        let roleDescription: String?
        let isEditable: Bool
        let canSetSelectedText: Bool
        let canSetValue: Bool

        init(
            element: AXUIElement?,
            source: Source,
            applicationPID: pid_t,
            applicationName: String?,
            bundleIdentifier: String?,
            snapshot: VerificationSnapshot?,
            securityState: SecurityState,
            role: String?,
            subrole: String?,
            roleDescription: String? = nil,
            isEditable: Bool = false,
            canSetSelectedText: Bool = false,
            canSetValue: Bool = false
        ) {
            self.element = element
            self.source = source
            self.applicationPID = applicationPID
            self.applicationName = applicationName
            self.bundleIdentifier = bundleIdentifier
            self.snapshot = snapshot
            self.securityState = securityState
            self.role = role
            self.subrole = subrole
            self.roleDescription = roleDescription
            self.isEditable = isEditable
            self.canSetSelectedText = canSetSelectedText
            self.canSetValue = canSetValue
        }

        var isDirectlyWritable: Bool {
            canSetSelectedText || canSetValue
        }

        var isSecure: Bool {
            securityState == .secure
        }

        var isKnownNonSecure: Bool {
            securityState == .notSecure
        }
    }

    struct Environment {
        let isProcessTrusted: () -> Bool
        let currentFocusedTarget: () -> Target?
        let targetMetadata: (Target?) -> TargetMetadata?
        let prepareTargetForFocusProbing: (Target?) -> Void
        let activateTarget: (Target?) -> Void
        let resolveFocusContext: (Target?) -> FocusContext?
        let resolveImmediateFocusContext: (Target?) -> FocusContext?
        let attemptAccessibilityInsert: (String, FocusContext) -> Bool
        let attemptTypingInsert: (String, Target?) -> Bool
        let attemptPasteInsert: (String, Target?, InsertionOptions) -> Bool
        let updateStreamingAccessibilityText: (String, Target?, Int, String) -> Bool
        let updateStreamingTypingText: (Target?, Int, String) -> Bool
        let currentSnapshot: (FocusContext) -> VerificationSnapshot?
        let copyTextToClipboard: (String) -> Void
    }

    private enum VerificationOutcome {
        case verified
        case failed
        case unverifiable
    }

    enum TargetFamily: String {
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

    private enum StreamingFocusPhase: String {
        case immediate
        case waited
        case captured
    }

    private struct StreamingFocusResolution {
        let focus: FocusContext?
        let phase: StreamingFocusPhase
    }

    private struct FocusProbeResult {
        let source: FocusContext.Source
        let focusContext: FocusContext?
        let error: AXError?
        let usable: Bool
    }

    private let workspace: NSWorkspace
    private let environment: Environment
    private let ownBundleIdentifier = Bundle.main.bundleIdentifier
    private var workspaceObserver: NSObjectProtocol?
    private var lastExternalTarget: Target?
    private var preparedFocusProbeTargetPIDs = Set<pid_t>()

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
    private static let manualAccessibilityAttribute = "AXManualAccessibility" as CFString
    private static let developerToolsCategory = "public.app-category.developer-tools"
    private static let targetMetadataCacheLock = NSLock()
    private static var targetMetadataCache = [pid_t: TargetMetadata]()
    private static let preparedElectronTargetCacheLock = NSLock()
    private static var preparedElectronTargetResults = [pid_t: Bool]()

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
        captureInsertionContext()?.target
    }

    func captureInsertionContext() -> CapturedInsertionContext? {
        let captureSelection: (target: Target, method: String)?
        if let focusedTarget = environment.currentFocusedTarget() {
            captureSelection = (focusedTarget, "focused-app")
        } else if let frontmostApplication = workspace.frontmostApplication,
                  let target = target(from: frontmostApplication) {
            captureSelection = (target, "frontmost-app")
        } else if let lastExternalTarget {
            captureSelection = (lastExternalTarget, "last-external-target")
        } else {
            captureSelection = nil
        }

        guard let captureSelection else {
            DebugLog.log("No external insertion context could be captured.", category: "insertion")
            return nil
        }

        let target = captureSelection.target
        lastExternalTarget = target

        prepareTargetForFocusProbingIfNeeded(target)
        let targetProbe = Self.focusProbeForTargetApplication(target)
        let systemProbe = Self.focusProbeForSystemWideElement(target: target)
        let capturedFocus = bestCapturedFocusContext(
            targetProbe: targetProbe,
            systemProbe: systemProbe,
            target: target
        )
        let targetFamily = classifyTargetFamily(target: target, focus: capturedFocus)
        let capturedContext = CapturedInsertionContext(
            target: target,
            focusContext: capturedFocus,
            captureMethod: captureSelection.method,
            targetFamily: targetFamily,
            targetApplicationProbe: Self.probeMetadata(from: targetProbe, target: target),
            systemWideProbe: Self.probeMetadata(from: systemProbe, target: target)
        )

        DebugLog.log(
            "Captured insertion context method=\(captureSelection.method) target=\(describe(target)) family=\(targetFamily.rawValue) captureFocus=\(describeCapturedFocus(capturedFocus, target: target)) targetProbe=\(describeProbeMetadata(capturedContext.targetApplicationProbe)) systemProbe=\(describeProbeMetadata(capturedContext.systemWideProbe))",
            category: "insertion"
        )

        return capturedContext
    }

    @discardableResult
    func insert(
        _ text: String,
        target preferredTarget: Target? = nil,
        capturedContext: CapturedInsertionContext? = nil,
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

        let target = resolvedInsertionTarget(capturedContext?.target ?? preferredTarget)
        DebugLog.log("Attempting insertion. target=\(describe(target))", category: "insertion")

        var focus = resolveFocusContextAndLog(for: target)
        if focus?.isSecure == true {
            DebugLog.log("Blocking insertion because the focused element appears to be secure.", category: "insertion")
            return .secureFieldBlocked
        }

        let policy = insertionPolicy(for: target, focus: focus, options: options)
        var nonAXFocus = nonAXFallbackFocus(
            liveFocus: focus,
            capturedContext: capturedContext,
            target: target,
            targetFamily: policy.targetFamily
        )
        let focusBasedNonAXFallbacksAllowed = canUseBlindNonAXFallbacks(
            nonAXFocus,
            target: target,
            targetFamily: policy.targetFamily
        )
        let targetOnlyBlindFallbackAllowed = !focusBasedNonAXFallbacksAllowed &&
            canUseTargetOnlyBlindNonAXFallback(
                focus: nonAXFocus ?? focus,
                capturedContext: capturedContext,
                target: target,
                targetFamily: policy.targetFamily
            )
        let nonAXFallbacksAllowed = focusBasedNonAXFallbacksAllowed || targetOnlyBlindFallbackAllowed
        if targetOnlyBlindFallbackAllowed {
            DebugLog.log(
                "Allowing target-only non-AX fallback because the focused element could not be resolved in the target app. target=\(describe(target)) family=\(policy.targetFamily.rawValue)",
                category: "insertion"
            )
        }
        DebugLog.log(
            "Using insertion policy family=\(policy.targetFamily.rawValue) strategies=\(policy.strategyOrder.map(\.rawValue).joined(separator: ","))",
            category: "insertion"
        )

        for strategy in policy.strategyOrder {
            if let outcome = attemptStrategy(
                strategy,
                text: text,
                target: target,
                accessibilityFocus: &focus,
                nonAXFocus: &nonAXFocus,
                capturedContext: capturedContext,
                targetFamily: policy.targetFamily,
                allowTargetOnlyBlindFallback: targetOnlyBlindFallbackAllowed,
                options: options,
                retryImmediatelyAfterFailure: shouldRetryImmediatelyAfterFailure(
                    strategy: strategy,
                    policy: policy
                )
            ) {
                DebugLog.log(
                    "Inserted transcript using \(strategy.rawValue). Length: \(text.count) target=\(describe(target)) family=\(policy.targetFamily.rawValue)",
                    category: "insertion"
                )
                return outcome
            }

            if focus?.isSecure == true || nonAXFocus?.isSecure == true {
                DebugLog.log("Blocking insertion because the refreshed focus appears to be secure.", category: "insertion")
                return .secureFieldBlocked
            }
        }

        if !nonAXFallbacksAllowed {
            DebugLog.log("Privacy guard blocked non-AX insertion because the focused element could not be proven safe for typing or paste fallbacks.", category: "insertion")
            return .privacyGuardBlocked
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

    func beginStreamingSession(target preferredTarget: Target? = nil) -> StreamingSession? {
        beginStreamingSession(
            capturedContext: preferredTarget.map { target in
                CapturedInsertionContext.testing(
                    target: target,
                    targetFamily: classifyTargetFamily(target: target, focus: nil)
                )
            }
        )
    }

    func beginStreamingSession(capturedContext: CapturedInsertionContext?) -> StreamingSession? {
        guard environment.isProcessTrusted() else {
            DebugLog.log("Live insertion session blocked because accessibility permission is missing.", category: "insertion")
            return nil
        }

        let target = resolvedInsertionTarget(capturedContext?.target)
        environment.activateTarget(target)
        let focusResolution = resolveStreamingFocus(for: target)
        let classificationFocus: FocusContext?
        if let resolvedFocus = focusResolution.focus,
           focusBelongsToTargetApplication(resolvedFocus, target: target) {
            classificationFocus = resolvedFocus
        } else {
            classificationFocus = capturedContext?.focusContext ?? focusResolution.focus
        }
        let targetFamily = classifyTargetFamily(
            target: target,
            focus: classificationFocus
        )
        logStreamingCompatibilitySummary(
            target: target,
            capturedContext: capturedContext,
            focusResolution: focusResolution,
            targetFamily: targetFamily
        )

        let focus: FocusContext
        if let resolvedFocus = focusResolution.focus {
            if !focusBelongsToTargetApplication(resolvedFocus, target: target) {
                DebugLog.log(
                    "Live insertion rejected current focus because it belongs to a non-target app. target=\(describe(target)) phase=\(focusResolution.phase.rawValue) owner=\(DebugLog.displayApplicationName(resolvedFocus.applicationName)) pid=\(DebugLog.displayProcessIdentifier(resolvedFocus.applicationPID)) bundle=\(DebugLog.displayBundleIdentifier(resolvedFocus.bundleIdentifier)) source=\(resolvedFocus.source.rawValue)",
                    category: "insertion"
                )

                if let capturedSafeFocus = fallbackStreamingFocusFromCapturedContext(
                    capturedContext,
                    target: target,
                    targetFamily: targetFamily
                ) {
                    DebugLog.log(
                        "Live insertion recovering from captured focus context after rejecting non-target current focus. target=\(describe(target)) family=\(targetFamily.rawValue)",
                        category: "insertion"
                    )
                    return startStreamingSession(
                        target: target,
                        capturedContext: capturedContext,
                        focus: capturedSafeFocus,
                        phase: .captured,
                        targetFamily: targetFamily
                    )
                }

                if canUseTargetOnlyBlindNonAXFallback(
                    focus: resolvedFocus,
                    capturedContext: capturedContext,
                    target: target,
                    targetFamily: targetFamily
                ) {
                    DebugLog.log(
                        "Live insertion recovering with a target-only typing fallback because no target-owned AX focus could be resolved. target=\(describe(target)) family=\(targetFamily.rawValue)",
                        category: "insertion"
                    )
                    return startTargetOnlyStreamingSession(
                        target: target,
                        capturedContext: capturedContext,
                        phase: focusResolution.phase,
                        targetFamily: targetFamily
                    )
                }

                DebugLog.log(
                    "Live insertion session unavailable. target=\(describe(target)) phase=\(focusResolution.phase.rawValue) reason=captured-fallback-unavailable matchedTarget=false security=\(resolvedFocus.securityState.rawValue) editable=\(resolvedFocus.isEditable) snapshot=\(resolvedFocus.snapshot != nil) writableSelected=\(resolvedFocus.canSetSelectedText) writableValue=\(resolvedFocus.canSetValue)",
                    category: "insertion"
                )
                return nil
            }
            focus = resolvedFocus
        } else if let capturedSafeFocus = fallbackStreamingFocusFromCapturedContext(capturedContext, target: target, targetFamily: targetFamily) {
            DebugLog.log(
                "Live insertion recovering from captured focus context because current AX focus was unavailable. target=\(describe(target)) family=\(targetFamily.rawValue)",
                category: "insertion"
            )
            return startStreamingSession(
                target: target,
                capturedContext: capturedContext,
                focus: capturedSafeFocus,
                phase: .captured,
                targetFamily: targetFamily
            )
        } else if canUseTargetOnlyBlindNonAXFallback(
            focus: nil,
            capturedContext: capturedContext,
            target: target,
            targetFamily: targetFamily
        ) {
            DebugLog.log(
                "Live insertion recovering with a target-only typing fallback because current AX focus was unavailable. target=\(describe(target)) family=\(targetFamily.rawValue)",
                category: "insertion"
            )
            return startTargetOnlyStreamingSession(
                target: target,
                capturedContext: capturedContext,
                phase: focusResolution.phase,
                targetFamily: targetFamily
            )
        } else {
            DebugLog.log(
                "Live insertion session unavailable. target=\(describe(target)) phase=\(focusResolution.phase.rawValue) reason=no-focus",
                category: "insertion"
            )
            return nil
        }

        guard !focus.isSecure else {
            DebugLog.log(
                "Live insertion session unavailable. target=\(describe(target)) phase=\(focusResolution.phase.rawValue) reason=secure-field matchedTarget=\(focusBelongsToTargetApplication(focus, target: target)) security=\(focus.securityState.rawValue) snapshot=\(focus.snapshot != nil)",
                category: "insertion"
            )
            return nil
        }

        return startStreamingSession(
            target: target,
            capturedContext: capturedContext,
            focus: focus,
            phase: focusResolution.phase,
            targetFamily: targetFamily
        )
    }

    @discardableResult
    func updateStreamingSession(_ session: StreamingSession, text: String) -> Bool {
        guard environment.isProcessTrusted() else {
            session.markDegraded()
            return false
        }

        guard session.isHealthy else {
            return false
        }

        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedText != session.currentText else {
            return true
        }

        let updateSucceeded: Bool
        switch session.mode {
        case .accessibility(let anchorLocation):
            updateSucceeded = updateStreamingSessionUsingAccessibility(
                session,
                text: normalizedText,
                anchorLocation: anchorLocation
            )
        case .typingVerified, .typingBlind:
            updateSucceeded = updateStreamingSessionUsingTyping(
                session,
                text: normalizedText
            )
        }

        if updateSucceeded {
            session.currentText = normalizedText
            session.markHealthy()
        } else {
            session.markDegraded()
            DebugLog.log(
                "Live insertion update failed mode=\(streamingModeDescription(session.mode)) target=\(describe(session.target)) currentLength=\(session.currentText.count) nextLength=\(normalizedText.count)",
                category: "insertion"
            )
        }

        return updateSucceeded
    }

    @discardableResult
    func commitStreamingSession(
        _ session: StreamingSession,
        finalText: String,
        options: InsertionOptions = .default
    ) -> InsertionOutcome {
        let normalizedFinalText = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        if session.isHealthy, updateStreamingSession(session, text: normalizedFinalText) {
            return streamingOutcome(for: session.mode)
        }

        _ = clearStreamingSessionText(session)
        return insert(
            normalizedFinalText,
            target: session.target,
            capturedContext: session.capturedContext,
            options: options
        )
    }

    func cancelStreamingSession(_ session: StreamingSession) {
        _ = clearStreamingSessionText(session)
        DebugLog.log("Cancelled live insertion session target=\(describe(session.target))", category: "insertion")
    }

    private func resolvedInsertionTarget(_ preferredTarget: Target?) -> Target? {
        if let preferredTarget {
            lastExternalTarget = preferredTarget
            DebugLog.log("Using frozen insertion target: \(describe(preferredTarget))", category: "insertion")
            return preferredTarget
        }

        if let focusedTarget = environment.currentFocusedTarget() {
            lastExternalTarget = focusedTarget
            DebugLog.log("Using focused app as insertion target: \(describe(focusedTarget))", category: "insertion")
            return focusedTarget
        }

        return captureInsertionTarget()
    }

    private func insertionPolicy(for target: Target?, focus: FocusContext?, options: InsertionOptions) -> InsertionPolicy {
        let targetFamily = classifyTargetFamily(target: target, focus: focus)
        var strategies: [StrategyKind] = [.accessibility]
        strategies.append(.typing)
        if options.allowPasteFallback {
            strategies.append(.paste)
        }

        return InsertionPolicy(
            targetFamily: targetFamily,
            strategyOrder: strategies
        )
    }

    private func shouldRetryImmediatelyAfterFailure(
        strategy: StrategyKind,
        policy: InsertionPolicy
    ) -> Bool {
        guard strategy == .accessibility else {
            return true
        }

        guard policy.strategyOrder.count > 1 else {
            return true
        }

        return policy.targetFamily == .nativeTextControl
    }

    private func targetMetadata(target: Target?, focus: FocusContext?) -> TargetMetadata? {
        if let target {
            return environment.targetMetadata(target)
        }

        guard let focus, focus.applicationPID != 0 else {
            return nil
        }

        let focusTarget = Target(
            applicationPID: focus.applicationPID,
            applicationName: focus.applicationName ?? "pid:\(focus.applicationPID)",
            bundleIdentifier: focus.bundleIdentifier
        )
        return environment.targetMetadata(focusTarget)
    }

    private func prepareTargetForFocusProbingIfNeeded(_ target: Target?) {
        guard let target else { return }
        guard !preparedFocusProbeTargetPIDs.contains(target.applicationPID) else { return }
        guard environment.targetMetadata(target)?.isLikelyElectron == true else { return }

        preparedFocusProbeTargetPIDs.insert(target.applicationPID)
        environment.prepareTargetForFocusProbing(target)
    }

    private func classifyTargetFamily(target: Target?, focus: FocusContext?) -> TargetFamily {
        let bundleIdentifier = (target?.bundleIdentifier ?? focus?.bundleIdentifier ?? "").lowercased()
        let metadata = targetMetadata(target: target, focus: focus)
        if Self.matchesBundle(bundleIdentifier, prefixes: Self.terminalBundlePrefixes) {
            return .terminalOrConsole
        }

        if Self.matchesBundle(bundleIdentifier, prefixes: Self.codeEditorBundlePrefixes) ||
            metadata?.isCodeEditor == true {
            return .codeEditor
        }

        if Self.matchesBundle(bundleIdentifier, prefixes: Self.browserBundlePrefixes) ||
            metadata?.isLikelyElectron == true {
            return .browserOrElectron
        }

        if focus?.role == "AXWebArea" {
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
        accessibilityFocus: inout FocusContext?,
        nonAXFocus: inout FocusContext?,
        capturedContext: CapturedInsertionContext?,
        targetFamily: TargetFamily,
        allowTargetOnlyBlindFallback: Bool,
        options: InsertionOptions,
        retryImmediatelyAfterFailure: Bool
    ) -> InsertionOutcome? {
        for attempt in 0..<2 {
            let targetOnlyBlindFallbackAllowed = allowTargetOnlyBlindFallback &&
                !canUseBlindNonAXFallbacks(
                    nonAXFocus,
                    target: target,
                    targetFamily: targetFamily
                ) &&
                canUseTargetOnlyBlindNonAXFallback(
                    focus: nonAXFocus ?? accessibilityFocus,
                    capturedContext: capturedContext,
                    target: target,
                    targetFamily: targetFamily
                )
            if runStrategy(
                strategy,
                text: text,
                target: target,
                accessibilityFocus: accessibilityFocus,
                nonAXFocus: nonAXFocus,
                targetFamily: targetFamily,
                allowTargetOnlyBlindFallback: targetOnlyBlindFallbackAllowed,
                options: options
            ) {
                return strategy.outcome
            }

            guard attempt == 0, retryImmediatelyAfterFailure else { break }

            DebugLog.log(
                "\(strategy.rawValue) insertion attempt failed. Reactivating target and refreshing focus before retry.",
                category: "insertion"
            )
            accessibilityFocus = refreshFocusAfterFailure(target: target, failedStrategy: strategy)
            nonAXFocus = nonAXFallbackFocus(
                liveFocus: accessibilityFocus,
                capturedContext: capturedContext,
                target: target,
                targetFamily: targetFamily
            )
        }

        return nil
    }

    private func runStrategy(
        _ strategy: StrategyKind,
        text: String,
        target: Target?,
        accessibilityFocus: FocusContext?,
        nonAXFocus: FocusContext?,
        targetFamily: TargetFamily,
        allowTargetOnlyBlindFallback: Bool,
        options: InsertionOptions
    ) -> Bool {
        switch strategy {
        case .accessibility:
            guard let accessibilityFocus else {
                DebugLog.log("No AX focus context available for Accessibility insertion.", category: "insertion")
                return false
            }

            guard accessibilityFocus.isKnownNonSecure else {
                DebugLog.log("Skipping Accessibility insertion because the focused element could not be proven non-secure.", category: "insertion")
                return false
            }

            guard accessibilityFocus.isDirectlyWritable else {
                DebugLog.log("Skipping Accessibility insertion because the focused element does not report a writable text attribute.", category: "insertion")
                return false
            }

            return environment.attemptAccessibilityInsert(text, accessibilityFocus)
        case .typing:
            let canUseFocusBasedBlindFallback = canUseBlindNonAXFallbacks(
                nonAXFocus,
                target: target,
                targetFamily: targetFamily
            )
            guard canUseFocusBasedBlindFallback || allowTargetOnlyBlindFallback else {
                DebugLog.log("Synthetic typing was blocked because the focused element could not be proven safe for blind non-AX fallback.", category: "insertion")
                return false
            }
            if allowTargetOnlyBlindFallback, !canUseFocusBasedBlindFallback {
                DebugLog.log(
                    "Synthetic typing is proceeding with only the frozen target app because no target-owned AX focus could be resolved.",
                    category: "insertion"
                )
            }
            guard environment.attemptTypingInsert(text, target) else {
                DebugLog.log("Synthetic typing was unavailable.", category: "insertion")
                return false
            }
            return verifyStrategyResult(for: nonAXFocus, strategy: strategy)
        case .paste:
            guard options.allowPasteFallback else {
                DebugLog.log("Paste fallback is disabled by settings.", category: "insertion")
                return false
            }
            let canUseFocusBasedBlindFallback = canUseBlindNonAXFallbacks(
                nonAXFocus,
                target: target,
                targetFamily: targetFamily
            )
            guard canUseFocusBasedBlindFallback || allowTargetOnlyBlindFallback else {
                DebugLog.log("Paste fallback was blocked because the focused element could not be proven safe for blind non-AX fallback.", category: "insertion")
                return false
            }
            if allowTargetOnlyBlindFallback, !canUseFocusBasedBlindFallback {
                DebugLog.log(
                    "Paste fallback is proceeding with only the frozen target app because no target-owned AX focus could be resolved.",
                    category: "insertion"
                )
            }
            guard environment.attemptPasteInsert(text, target, options) else {
                DebugLog.log("Paste fallback was unavailable.", category: "insertion")
                return false
            }
            return verifyStrategyResult(for: nonAXFocus, strategy: strategy)
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
        prepareTargetForFocusProbingIfNeeded(target)
        let focus = environment.resolveFocusContext(target)
        if let focus {
            DebugLog.log(
                "Resolved focus source=\(focus.source.rawValue) owner=\(DebugLog.displayApplicationName(focus.applicationName)) pid=\(DebugLog.displayProcessIdentifier(focus.applicationPID)) bundle=\(DebugLog.displayBundleIdentifier(focus.bundleIdentifier)) role=\(focus.role ?? "unknown") subrole=\(focus.subrole ?? "none") security=\(focus.securityState.rawValue) editable=\(focus.isEditable) verifiable=\(focus.snapshot != nil) writableSelected=\(focus.canSetSelectedText) writableValue=\(focus.canSetValue)",
                category: "insertion"
            )
        } else {
            DebugLog.log("Proceeding without an AX focus context; blind fallback may still use a captured target context.", category: "insertion")
        }

        return focus
    }

    private func canUseVerifiedNonAXFallbacks(_ focus: FocusContext?, target: Target?) -> Bool {
        guard let focus else { return false }
        return focusBelongsToTargetApplication(focus, target: target) &&
            focus.isKnownNonSecure &&
            focus.isDirectlyWritable &&
            focus.snapshot != nil
    }

    private func canUseBlindNonAXFallbacks(
        _ focus: FocusContext?,
        target: Target?,
        targetFamily: TargetFamily
    ) -> Bool {
        guard let focus else { return false }
        guard focusBelongsToTargetApplication(focus, target: target) else { return false }
        guard !focus.isSecure else { return false }
        return focusLooksEditableForBlindFallback(focus, targetFamily: targetFamily)
    }

    private func focusLooksEditableForBlindFallback(
        _ focus: FocusContext,
        targetFamily: TargetFamily
    ) -> Bool {
        if focus.isDirectlyWritable || focus.snapshot != nil || focus.isEditable {
            return true
        }

        if let role = focus.role, Self.nativeTextRoles.contains(role) {
            return true
        }

        let lowercasedRoleDescription = focus.roleDescription?.lowercased() ?? ""
        if lowercasedRoleDescription.contains("text") ||
            lowercasedRoleDescription.contains("editor") ||
            lowercasedRoleDescription.contains("document") ||
            lowercasedRoleDescription.contains("search") ||
            lowercasedRoleDescription.contains("console") {
            return true
        }

        guard let role = focus.role else { return false }
        switch targetFamily {
        case .browserOrElectron, .codeEditor, .terminalOrConsole:
            return ["AXDocument", "AXGroup", "AXScrollArea", "AXTextArea", "AXTextField", "AXTextView", "AXWebArea"].contains(role)
        case .nativeTextControl:
            return false
        case .other:
            return ["AXDocument", "AXTextArea", "AXTextField", "AXTextView"].contains(role)
        }
    }

    private func nonAXFallbackFocus(
        liveFocus: FocusContext?,
        capturedContext: CapturedInsertionContext?,
        target: Target?,
        targetFamily: TargetFamily
    ) -> FocusContext? {
        if canUseBlindNonAXFallbacks(liveFocus, target: target, targetFamily: targetFamily) {
            return liveFocus
        }

        guard let capturedContext,
              let capturedFocus = capturedContext.focusContext,
              canUseBlindNonAXFallbacks(capturedFocus, target: target, targetFamily: targetFamily)
        else {
            return liveFocus
        }

        DebugLog.log(
            "Using captured focus context to allow blind non-AX fallback target=\(describe(target)) family=\(targetFamily.rawValue)",
            category: "insertion"
        )
        return capturedFocus
    }

    private func canUseTargetOnlyBlindNonAXFallback(
        focus: FocusContext?,
        capturedContext: CapturedInsertionContext?,
        target: Target?,
        targetFamily: TargetFamily
    ) -> Bool {
        guard let target else { return false }
        switch targetFamily {
        case .browserOrElectron, .codeEditor, .terminalOrConsole:
            break
        case .nativeTextControl, .other:
            return false
        }

        if let capturedFocus = capturedContext?.focusContext,
           capturedFocus.isSecure {
            return false
        }

        guard let focus else {
            return true
        }

        return !focusBelongsToTargetApplication(focus, target: target)
    }

    private func clearStreamingSessionText(_ session: StreamingSession) -> Bool {
        guard !session.currentText.isEmpty else {
            session.markHealthy()
            return true
        }

        let cleared: Bool
        switch session.mode {
        case .accessibility(let anchorLocation):
            cleared = environment.updateStreamingAccessibilityText(
                "",
                session.target,
                anchorLocation,
                session.currentText
            )
        case .typingVerified, .typingBlind:
            cleared = environment.updateStreamingTypingText(
                session.target,
                session.currentText.count,
                ""
            )
        }

        if cleared {
            session.currentText = ""
            session.markHealthy()
        }

        return cleared
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

    private func updateStreamingSessionUsingAccessibility(
        _ session: StreamingSession,
        text: String,
        anchorLocation: Int
    ) -> Bool {
        environment.updateStreamingAccessibilityText(
            text,
            session.target,
            anchorLocation,
            session.currentText
        )
    }

    private func updateStreamingSessionUsingTyping(
        _ session: StreamingSession,
        text: String
    ) -> Bool {
        let currentCharacters = Array(session.currentText)
        let nextCharacters = Array(text)
        var prefixLength = 0

        while prefixLength < currentCharacters.count,
              prefixLength < nextCharacters.count,
              currentCharacters[prefixLength] == nextCharacters[prefixLength] {
            prefixLength += 1
        }

        let deleteCount = currentCharacters.count - prefixLength
        let suffix = String(nextCharacters.dropFirst(prefixLength))

        return environment.updateStreamingTypingText(
            session.target,
            deleteCount,
            suffix
        )
    }

    private func streamingOutcome(for mode: StreamingSession.Mode) -> InsertionOutcome {
        switch mode {
        case .accessibility:
            return .insertedAccessibility
        case .typingVerified, .typingBlind:
            return .insertedTyping
        }
    }

    private func streamingModeDescription(_ mode: StreamingSession.Mode) -> String {
        switch mode {
        case .accessibility:
            return "accessibility"
        case .typingVerified:
            return "typing-verified"
        case .typingBlind:
            return "typing-blind"
        }
    }

    private func resolveStreamingFocus(for target: Target?) -> StreamingFocusResolution {
        prepareTargetForFocusProbingIfNeeded(target)
        let immediateFocus = environment.resolveImmediateFocusContext(target)
        if let immediateFocus {
            DebugLog.log(
                "Live insertion immediate focus matchedTarget=\(focusBelongsToTargetApplication(immediateFocus, target: target)) security=\(immediateFocus.securityState.rawValue) editable=\(immediateFocus.isEditable) snapshot=\(immediateFocus.snapshot != nil) writableSelected=\(immediateFocus.canSetSelectedText) writableValue=\(immediateFocus.canSetValue)",
                category: "insertion"
            )
        } else {
            DebugLog.log("Live insertion immediate focus unavailable.", category: "insertion")
        }

        if let immediateFocus,
           focusBelongsToTargetApplication(immediateFocus, target: target) {
            return StreamingFocusResolution(focus: immediateFocus, phase: .immediate)
        }

        DebugLog.log(
            "Retrying live insertion focus lookup after activation because the immediate focus was missing or mismatched.",
            category: "insertion"
        )
        let waitedFocus = resolveFocusContextAndLog(for: target)
        if let waitedFocus {
            DebugLog.log(
                "Live insertion waited focus matchedTarget=\(focusBelongsToTargetApplication(waitedFocus, target: target)) security=\(waitedFocus.securityState.rawValue) editable=\(waitedFocus.isEditable) snapshot=\(waitedFocus.snapshot != nil) writableSelected=\(waitedFocus.canSetSelectedText) writableValue=\(waitedFocus.canSetValue)",
                category: "insertion"
            )
        } else {
            DebugLog.log("Live insertion waited focus unavailable.", category: "insertion")
        }

        return StreamingFocusResolution(focus: waitedFocus, phase: .waited)
    }

    private func startStreamingSession(
        target: Target?,
        capturedContext: CapturedInsertionContext?,
        focus: FocusContext,
        phase: StreamingFocusPhase,
        targetFamily: TargetFamily
    ) -> StreamingSession? {
        let modeSelection = selectStreamingMode(for: focus, target: target, targetFamily: targetFamily)
        guard let mode = modeSelection.mode else {
            DebugLog.log(
                "Live insertion session unavailable. target=\(describe(target)) phase=\(phase.rawValue) reason=\(modeSelection.reason) matchedTarget=\(focusBelongsToTargetApplication(focus, target: target)) security=\(focus.securityState.rawValue) editable=\(focus.isEditable) snapshot=\(focus.snapshot != nil) writableSelected=\(focus.canSetSelectedText) writableValue=\(focus.canSetValue)",
                category: "insertion"
            )
            return nil
        }

        DebugLog.log(
            "Started live insertion session mode=\(streamingModeDescription(mode)) target=\(describe(target)) family=\(targetFamily.rawValue) phase=\(phase.rawValue) matchedTarget=\(focusBelongsToTargetApplication(focus, target: target)) security=\(focus.securityState.rawValue) editable=\(focus.isEditable) snapshot=\(focus.snapshot != nil) reason=\(modeSelection.reason)",
            category: "insertion"
        )

        return StreamingSession(target: target, capturedContext: capturedContext, mode: mode)
    }

    private func startTargetOnlyStreamingSession(
        target: Target?,
        capturedContext: CapturedInsertionContext?,
        phase: StreamingFocusPhase,
        targetFamily: TargetFamily
    ) -> StreamingSession? {
        guard targetFamily != .nativeTextControl else {
            return nil
        }

        guard target != nil else {
            return nil
        }

        DebugLog.log(
            "Started live insertion session mode=typing-blind target=\(describe(target)) family=\(targetFamily.rawValue) phase=\(phase.rawValue) matchedTarget=false security=unknown editable=false snapshot=false reason=target-only-typing-blind",
            category: "insertion"
        )

        return StreamingSession(target: target, capturedContext: capturedContext, mode: .typingBlind)
    }

    private func focusBelongsToTargetApplication(_ focus: FocusContext, target: Target?) -> Bool {
        guard let target else {
            guard let ownBundleIdentifier else { return focus.applicationPID != 0 }
            return focus.applicationPID != 0 && focus.bundleIdentifier != ownBundleIdentifier
        }

        return focus.applicationPID == target.applicationPID
    }

    private func accessibilityStreamingAnchorLocation(for focus: FocusContext) -> Int? {
        guard focus.isDirectlyWritable else { return nil }
        guard let selectedRange = focus.snapshot?.selectedRange else { return nil }
        return selectedRange.location
    }

    private func selectStreamingMode(
        for focus: FocusContext,
        target: Target?,
        targetFamily: TargetFamily
    ) -> (mode: StreamingSession.Mode?, reason: String) {
        guard focusBelongsToTargetApplication(focus, target: target) else {
            return (nil, "mismatched-target")
        }

        switch targetFamily {
        case .nativeTextControl:
            if let anchorLocation = accessibilityStreamingAnchorLocation(for: focus) {
                return (.accessibility(anchorLocation: anchorLocation), "accessibility-anchor")
            }
        case .browserOrElectron, .codeEditor, .terminalOrConsole, .other:
            break
        }

        if canUseVerifiedNonAXFallbacks(focus, target: target) {
            return (.typingVerified, "typing-verified")
        }

        guard canUseStreamingTypingFallback(focus, target: target, targetFamily: targetFamily) else {
            return (nil, "not-streamable")
        }

        return (.typingBlind, "typing-blind")
    }

    private func canUseStreamingTypingFallback(
        _ focus: FocusContext,
        target: Target?,
        targetFamily: TargetFamily
    ) -> Bool {
        canUseBlindNonAXFallbacks(focus, target: target, targetFamily: targetFamily)
    }

    private func fallbackStreamingFocusFromCapturedContext(
        _ capturedContext: CapturedInsertionContext?,
        target: Target?,
        targetFamily: TargetFamily
    ) -> FocusContext? {
        guard let capturedContext,
              let capturedFocus = capturedContext.focusContext else {
            return nil
        }

        guard targetFamily != .nativeTextControl else {
            return nil
        }

        guard canUseBlindNonAXFallbacks(capturedFocus, target: target, targetFamily: targetFamily) else {
            return nil
        }

        return capturedFocus
    }

    private func logStreamingCompatibilitySummary(
        target: Target?,
        capturedContext: CapturedInsertionContext?,
        focusResolution: StreamingFocusResolution,
        targetFamily: TargetFamily
    ) {
        let frontmostDescription = Self.describeCurrentFrontmostApplication()
        let captureSummary: String
        if let capturedContext {
            captureSummary = "method=\(capturedContext.captureMethod) focus=\(describeCapturedFocus(capturedContext.focusContext, target: capturedContext.target)) targetProbe=\(describeProbeMetadata(capturedContext.targetApplicationProbe)) systemProbe=\(describeProbeMetadata(capturedContext.systemWideProbe))"
        } else {
            captureSummary = "method=none focus=none targetProbe=none systemProbe=none"
        }

        let resolvedFocusSummary: String
        if let focus = focusResolution.focus {
            resolvedFocusSummary = "phase=\(focusResolution.phase.rawValue) matchedTarget=\(focusBelongsToTargetApplication(focus, target: target)) security=\(focus.securityState.rawValue) editable=\(focus.isEditable) snapshot=\(focus.snapshot != nil) writableSelected=\(focus.canSetSelectedText) writableValue=\(focus.canSetValue) source=\(focus.source.rawValue)"
        } else {
            resolvedFocusSummary = "phase=\(focusResolution.phase.rawValue) focus=unavailable"
        }

        DebugLog.log(
            "Live insertion compatibility target=\(describe(target)) family=\(targetFamily.rawValue) frontmost=\(frontmostDescription) capture=\(captureSummary) resolved=\(resolvedFocusSummary)",
            category: "insertion"
        )
    }

    private func bestCapturedFocusContext(
        targetProbe: FocusProbeResult,
        systemProbe: FocusProbeResult,
        target: Target
    ) -> FocusContext? {
        let candidateContexts = [targetProbe.focusContext, systemProbe.focusContext].compactMap { $0 }
        return candidateContexts.max { lhs, rhs in
            Self.focusPriority(for: lhs, target: target) < Self.focusPriority(for: rhs, target: target)
        }
    }

    private func describeCapturedFocus(_ focus: FocusContext?, target: Target?) -> String {
        guard let focus else { return "none" }
        return "source=\(focus.source.rawValue) matchedTarget=\(focusBelongsToTargetApplication(focus, target: target)) owner=\(DebugLog.displayApplicationName(focus.applicationName)) pid=\(DebugLog.displayProcessIdentifier(focus.applicationPID)) bundle=\(DebugLog.displayBundleIdentifier(focus.bundleIdentifier)) role=\(focus.role ?? "unknown") subrole=\(focus.subrole ?? "none") security=\(focus.securityState.rawValue) editable=\(focus.isEditable) snapshot=\(focus.snapshot != nil) writableSelected=\(focus.canSetSelectedText) writableValue=\(focus.canSetValue)"
    }

    private func describeProbeMetadata(_ metadata: CapturedInsertionContext.ProbeMetadata) -> String {
        let errorDescription = metadata.axErrorDescription ?? "none"
        let errorCode = metadata.axErrorCode.map(String.init) ?? "none"
        let security = metadata.securityState?.rawValue ?? "unknown"
        let ownerPID = metadata.applicationPID.map(DebugLog.displayProcessIdentifier) ?? "none"
        return "source=\(metadata.source.rawValue) matchedTarget=\(metadata.matchedTarget) owner=\(DebugLog.displayApplicationName(metadata.applicationName)) pid=\(ownerPID) bundle=\(DebugLog.displayBundleIdentifier(metadata.bundleIdentifier)) role=\(metadata.role ?? "unknown") subrole=\(metadata.subrole ?? "none") security=\(security) snapshot=\(metadata.hasSnapshot) writableSelected=\(metadata.canSetSelectedText) writableValue=\(metadata.canSetValue) usable=\(metadata.usable) axError=\(errorCode):\(errorDescription)"
    }

    private func describe(_ target: Target?) -> String {
        guard let target else { return "current-focus" }
        return "\(DebugLog.displayApplicationName(target.applicationName)) pid=\(DebugLog.displayProcessIdentifier(target.applicationPID)) bundle=\(DebugLog.displayBundleIdentifier(target.bundleIdentifier))"
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
            targetMetadata: { target in
                liveTargetMetadata(for: target)
            },
            prepareTargetForFocusProbing: { target in
                prepareTargetForFocusProbing(target)
            },
            activateTarget: { target in
                activateTargetApplicationIfNeeded(target, workspace: workspace)
            },
            resolveFocusContext: { target in
                resolveFocusContext(for: target)
            },
            resolveImmediateFocusContext: { target in
                resolveImmediateFocusContext(for: target)
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
            updateStreamingAccessibilityText: { text, target, anchorLocation, currentText in
                updateStreamingSessionUsingAccessibility(
                    text,
                    target: target,
                    anchorLocation: anchorLocation,
                    currentText: currentText
                )
            },
            updateStreamingTypingText: { target, deleteCount, textToAppend in
                replaceUsingTyping(
                    target: target,
                    deleteCount: deleteCount,
                    textToAppend: textToAppend
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

    static func liveTargetMetadata(for target: Target?) -> TargetMetadata? {
        guard let target else { return nil }

        targetMetadataCacheLock.lock()
        if let cached = targetMetadataCache[target.applicationPID] {
            targetMetadataCacheLock.unlock()
            return cached
        }
        targetMetadataCacheLock.unlock()

        guard let metadata = loadTargetMetadata(for: target) else {
            return nil
        }

        targetMetadataCacheLock.lock()
        targetMetadataCache[target.applicationPID] = metadata
        targetMetadataCacheLock.unlock()
        return metadata
    }

    static func loadTargetMetadata(for target: Target) -> TargetMetadata? {
        let bundleIdentifier = (
            NSRunningApplication(processIdentifier: target.applicationPID)?.bundleIdentifier ??
            target.bundleIdentifier ??
            ""
        ).lowercased()
        let infoDictionary = NSRunningApplication(processIdentifier: target.applicationPID)?
            .bundleURL
            .flatMap { Bundle(url: $0)?.infoDictionary } ?? [:]

        let isLikelyElectron = infoDictionary["ElectronAsarIntegrity"] != nil ||
            ((infoDictionary["NSPrincipalClass"] as? String)?.lowercased() == "atomapplication")
        let categoryType = (infoDictionary["LSApplicationCategoryType"] as? String)?.lowercased()
        let isCodeEditor = Self.matchesBundle(bundleIdentifier, prefixes: Self.codeEditorBundlePrefixes) ||
            (isLikelyElectron && categoryType == Self.developerToolsCategory)

        guard !bundleIdentifier.isEmpty || isLikelyElectron || isCodeEditor else {
            return nil
        }

        return TargetMetadata(
            isLikelyElectron: isLikelyElectron,
            isCodeEditor: isCodeEditor
        )
    }

    static func prepareTargetForFocusProbing(_ target: Target?) {
        guard let target,
              liveTargetMetadata(for: target)?.isLikelyElectron == true else {
            return
        }

        preparedElectronTargetCacheLock.lock()
        if preparedElectronTargetResults[target.applicationPID] != nil {
            preparedElectronTargetCacheLock.unlock()
            return
        }
        preparedElectronTargetCacheLock.unlock()

        let applicationElement = AXUIElementCreateApplication(target.applicationPID)
        let result = AXUIElementSetAttributeValue(
            applicationElement,
            manualAccessibilityAttribute,
            kCFBooleanTrue
        )
        let succeeded = result == .success

        preparedElectronTargetCacheLock.lock()
        preparedElectronTargetResults[target.applicationPID] = succeeded
        preparedElectronTargetCacheLock.unlock()

        if succeeded {
            DebugLog.log(
                "Enabled AXManualAccessibility for target=\(describe(target))",
                category: "insertion"
            )
        } else {
            DebugLog.log(
                "Failed to enable AXManualAccessibility for target=\(describe(target)) result=\(result.rawValue) (\(axErrorDescription(result)))",
                category: "insertion"
            )
        }
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
            if let target {
                let targetProbe = focusProbeForTargetApplication(target)
                if let context = targetProbe.focusContext {
                    fallbackContext = preferredFallbackContext(
                        current: fallbackContext,
                        candidate: context,
                        target: target
                    )

                    if targetProbe.usable {
                        return context
                    }
                }
            }

            let systemProbe = focusProbeForSystemWideElement(target: target)
            if let systemContext = systemProbe.focusContext {
                fallbackContext = preferredFallbackContext(
                    current: fallbackContext,
                    candidate: systemContext,
                    target: target
                )

                if systemProbe.usable {
                    return systemContext
                }
            }

            if Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
        } while Date() < deadline

        if let fallbackContext {
            DebugLog.log(
                "Timed out waiting for a focused editable element. Falling back to source=\(fallbackContext.source.rawValue) owner=\(DebugLog.displayApplicationName(fallbackContext.applicationName)) pid=\(DebugLog.displayProcessIdentifier(fallbackContext.applicationPID)) bundle=\(DebugLog.displayBundleIdentifier(fallbackContext.bundleIdentifier)) role=\(fallbackContext.role ?? "unknown") subrole=\(fallbackContext.subrole ?? "none") security=\(fallbackContext.securityState.rawValue)",
                category: "insertion"
            )
        }

        return fallbackContext
    }

    static func resolveImmediateFocusContext(for target: Target?) -> FocusContext? {
        if let target {
            let targetProbe = focusProbeForTargetApplication(target)
            if targetProbe.usable {
                return targetProbe.focusContext
            }
        }

        let systemProbe = focusProbeForSystemWideElement(target: target)
        if systemProbe.usable {
            return systemProbe.focusContext
        }

        return nil
    }

    static func focusContextForTargetApplication(_ target: Target) -> FocusContext? {
        let probe = focusProbeForTargetApplication(target)
        guard let context = probe.focusContext else {
            DebugLog.log(
                "Could not resolve focused UI element for target \(describe(target)). Falling back to system-wide focus. Result: \(probe.error.map { String($0.rawValue) } ?? "none") (\(probe.error.map(axErrorDescription) ?? "none"))",
                category: "insertion"
            )
            return nil
        }
        return context
    }

    static func focusContextForSystemWideElement() -> FocusContext? {
        let probe = focusProbeForSystemWideElement(target: nil)
        guard let context = probe.focusContext else {
            DebugLog.log(
                "Could not resolve focused UI element. Result: \(probe.error.map { String($0.rawValue) } ?? "none") (\(probe.error.map(axErrorDescription) ?? "none"))",
                category: "insertion"
            )
            return nil
        }
        return context
    }

    private static func focusProbeForTargetApplication(_ target: Target) -> TextInsertionService.FocusProbeResult {
        let applicationElement = AXUIElementCreateApplication(target.applicationPID)
        var focusedRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            applicationElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )

        guard result == .success, let focusedRef else {
            return TextInsertionService.FocusProbeResult(
                source: .targetApplication,
                focusContext: nil,
                error: result,
                usable: false
            )
        }

        let element = unsafeBitCast(focusedRef, to: AXUIElement.self)
        let context = makeFocusContext(element: element, source: .targetApplication)
        return TextInsertionService.FocusProbeResult(
            source: .targetApplication,
            focusContext: context,
            error: nil,
            usable: isUsableFocusContext(context, target: target)
        )
    }

    private static func focusProbeForSystemWideElement(target: Target?) -> TextInsertionService.FocusProbeResult {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )

        guard result == .success, let focusedRef else {
            return TextInsertionService.FocusProbeResult(
                source: .systemWide,
                focusContext: nil,
                error: result,
                usable: false
            )
        }

        let element = unsafeBitCast(focusedRef, to: AXUIElement.self)
        let context = makeFocusContext(element: element, source: .systemWide)
        return TextInsertionService.FocusProbeResult(
            source: .systemWide,
            focusContext: context,
            error: nil,
            usable: isUsableFocusContext(context, target: target)
        )
    }

    static func makeFocusContext(element: AXUIElement, source: TextInsertionService.FocusContext.Source) -> TextInsertionService.FocusContext {
        let application = runningApplication(for: element)
        let role = stringAttribute(kAXRoleAttribute as CFString, from: element)
        let subrole = stringAttribute(kAXSubroleAttribute as CFString, from: element)
        let roleDescription = stringAttribute(kAXRoleDescriptionAttribute as CFString, from: element)
        let snapshot = verificationSnapshot(for: element)
        let isEditable = booleanAttribute("AXEditable" as CFString, from: element) ?? false
        let canSetSelectedText = isAttributeSettable(kAXSelectedTextAttribute as CFString, on: element)
        let canSetValue = isAttributeSettable(kAXValueAttribute as CFString, on: element)
        let securityState = securityState(
            for: element,
            role: role,
            subrole: subrole,
            roleDescription: roleDescription,
            snapshot: snapshot,
            isEditable: isEditable,
            canSetSelectedText: canSetSelectedText,
            canSetValue: canSetValue
        )

        return TextInsertionService.FocusContext(
            element: element,
            source: source,
            applicationPID: application?.processIdentifier ?? 0,
            applicationName: application?.localizedName,
            bundleIdentifier: application?.bundleIdentifier,
            snapshot: snapshot,
            securityState: securityState,
            role: role,
            subrole: subrole,
            roleDescription: roleDescription,
            isEditable: isEditable,
            canSetSelectedText: canSetSelectedText,
            canSetValue: canSetValue
        )
    }

    private static func probeMetadata(
        from probe: TextInsertionService.FocusProbeResult,
        target: TextInsertionService.Target
    ) -> TextInsertionService.CapturedInsertionContext.ProbeMetadata {
        let matchedTarget = probe.focusContext.map { $0.applicationPID == target.applicationPID } ?? false
        return TextInsertionService.CapturedInsertionContext.ProbeMetadata(
            source: probe.source,
            matchedTarget: matchedTarget,
            role: probe.focusContext?.role,
            subrole: probe.focusContext?.subrole,
            securityState: probe.focusContext?.securityState,
            hasSnapshot: probe.focusContext?.snapshot != nil,
            canSetSelectedText: probe.focusContext?.canSetSelectedText ?? false,
            canSetValue: probe.focusContext?.canSetValue ?? false,
            axErrorCode: probe.error.map { Int32($0.rawValue) },
            axErrorDescription: probe.error.map { axErrorDescription($0) },
            applicationPID: probe.focusContext?.applicationPID,
            applicationName: probe.focusContext?.applicationName,
            bundleIdentifier: probe.focusContext?.bundleIdentifier,
            usable: probe.usable
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

    static func updateStreamingSessionUsingAccessibility(
        _ text: String,
        target: TextInsertionService.Target?,
        anchorLocation: Int,
        currentText: String
    ) -> Bool {
        guard let focus = resolveImmediateFocusContext(for: target),
              focus.isKnownNonSecure,
              let snapshot = focus.snapshot else {
            return false
        }

        let replacementRange = NSRange(
            location: anchorLocation,
            length: (currentText as NSString).length
        )

        if focus.canSetValue {
            return replaceValueInFocusedElement(
                text,
                focus: focus,
                snapshot: snapshot,
                range: replacementRange
            )
        }

        guard focus.canSetSelectedText,
              let element = focus.element,
              setSelectedRange(replacementRange, on: element) else {
            return false
        }

        return AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        ) == .success
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

        activateTargetApplicationIfNeeded(target, workspace: .shared)

        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            DebugLog.log("Could not create a CGEvent source for typing fallback.", category: "insertion")
            return false
        }

        guard postText(text, source: source, target: target) else {
            DebugLog.log("Could not create Unicode keyboard events for typing fallback.", category: "insertion")
            return false
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

        activateTargetApplicationIfNeeded(target, workspace: .shared)

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
              postVirtualKey(9, flags: .maskCommand, source: source, target: target) else {
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

    static func booleanAttribute(_ attribute: CFString, from element: AXUIElement) -> Bool? {
        var valueRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &valueRef)
        guard result == .success else {
            return nil
        }

        return valueRef as? Bool
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

    static func securityState(
        for element: AXUIElement,
        role: String?,
        subrole: String?,
        roleDescription: String?,
        snapshot: TextInsertionService.VerificationSnapshot?,
        isEditable: Bool,
        canSetSelectedText: Bool,
        canSetValue: Bool
    ) -> TextInsertionService.FocusContext.SecurityState {
        if isSecureElement(element, role: role, subrole: subrole) {
            return .secure
        }

        if snapshot != nil || canSetSelectedText || canSetValue || isEditable {
            return .notSecure
        }

        if let role, nativeTextRoles.contains(role) {
            return .notSecure
        }

        if let roleDescription = roleDescription?.lowercased(),
           roleDescription.contains("text") || roleDescription.contains("editor") {
            return .notSecure
        }

        return .unknown
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
        if workspace.frontmostApplication?.processIdentifier == target.applicationPID {
            return
        }
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

    static func postVirtualKey(
        _ keyCode: CGKeyCode,
        flags: CGEventFlags,
        source: CGEventSource,
        target: TextInsertionService.Target? = nil,
        shouldLog: Bool = true
    ) -> Bool {
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            if shouldLog {
                DebugLog.log(
                    "Could not create keyboard events for virtual key \(keyCode) flags=\(flags.rawValue).",
                    category: "insertion"
                )
            }
            return false
        }

        keyDown.flags = flags
        keyUp.flags = flags
        postKeyboardEvent(keyDown, target: target)
        postKeyboardEvent(keyUp, target: target)
        if shouldLog {
            DebugLog.log(
                "Posted virtual key \(keyCode) flags=\(flags.rawValue) to \(target != nil ? "target pid" : "the session tap").",
                category: "insertion"
            )
        }
        return true
    }

    static func setSelectedRange(_ range: NSRange, on element: AXUIElement) -> Bool {
        var selectedRange = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &selectedRange) else {
            return false
        }

        return AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            value
        ) == .success
    }

    static func replaceUsingTyping(
        target: TextInsertionService.Target?,
        deleteCount: Int,
        textToAppend: String
    ) -> Bool {
        activateTargetApplicationIfNeeded(target, workspace: .shared)

        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            return false
        }

        if deleteCount > 0 {
            for _ in 0..<deleteCount {
                guard postVirtualKey(51, flags: [], source: source, target: target, shouldLog: false) else {
                    return false
                }
            }
        }

        guard !textToAppend.isEmpty else {
            return true
        }

        return postText(textToAppend, source: source, target: target)
    }

    static func postText(
        _ text: String,
        source: CGEventSource,
        target: TextInsertionService.Target? = nil
    ) -> Bool {
        for character in text {
            if character == "\n" || character == "\r" {
                guard postVirtualKey(36, flags: [], source: source, target: target, shouldLog: false) else {
                    return false
                }
                continue
            }

            let unicodeScalars = Array(String(character).utf16)
            guard !unicodeScalars.isEmpty,
                  let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                return false
            }

            unicodeScalars.withUnsafeBufferPointer { buffer in
                guard let baseAddress = buffer.baseAddress else { return }
                keyDown.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: baseAddress)
                keyUp.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: baseAddress)
            }

            postKeyboardEvent(keyDown, target: target)
            postKeyboardEvent(keyUp, target: target)
        }

        return true
    }

    static func postKeyboardEvent(
        _ event: CGEvent,
        target: TextInsertionService.Target?
    ) {
        if let target,
           NSWorkspace.shared.frontmostApplication?.processIdentifier != target.applicationPID {
            event.postToPid(target.applicationPID)
        } else {
            event.post(tap: .cgAnnotatedSessionEventTap)
        }
    }

    static func describe(_ target: TextInsertionService.Target?) -> String {
        guard let target else { return "current-focus" }
        return "\(DebugLog.displayApplicationName(target.applicationName)) pid=\(DebugLog.displayProcessIdentifier(target.applicationPID)) bundle=\(DebugLog.displayBundleIdentifier(target.bundleIdentifier))"
    }

    static func describeCurrentFrontmostApplication() -> String {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication else {
            return "unknown-frontmost"
        }
        return "\(DebugLog.displayApplicationName(frontmostApplication.localizedName ?? "pid:\(frontmostApplication.processIdentifier)")) pid=\(DebugLog.displayProcessIdentifier(frontmostApplication.processIdentifier)) bundle=\(DebugLog.displayBundleIdentifier(frontmostApplication.bundleIdentifier))"
    }
}
