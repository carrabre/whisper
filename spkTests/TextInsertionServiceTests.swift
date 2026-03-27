import XCTest
@testable import spk

final class TextInsertionServiceTests: XCTestCase {
    private let target = TextInsertionService.Target(
        applicationPID: 123,
        applicationName: "TextEdit",
        bundleIdentifier: "com.apple.TextEdit"
    )

    func testInsertBlocksWhenFocusMissing() {
        var typingCalls = 0
        let service = TextInsertionService(
            environment: makeEnvironment(
                attemptTypingInsert: { _, _ in
                    typingCalls += 1
                    return true
                }
            )
        )

        let result = service.insert("hello world", target: target)

        XCTAssertEqual(result, .privacyGuardBlocked)
        XCTAssertEqual(typingCalls, 0)
    }

    func testCaptureInsertionTargetPrefersFocusedTarget() {
        let focusedTarget = TextInsertionService.Target(
            applicationPID: 456,
            applicationName: "TextEdit",
            bundleIdentifier: "com.apple.TextEdit"
        )
        let service = TextInsertionService(
            environment: makeEnvironment(currentFocusedTarget: { focusedTarget })
        )

        XCTAssertEqual(service.captureInsertionTarget(), focusedTarget)
    }

    func testSecureFieldBlocksAllFallbacks() {
        let secureFocus = makeFocus(
            securityState: .secure,
            subrole: "AXSecureTextField"
        )
        let service = TextInsertionService(
            environment: makeEnvironment(
                resolveFocusContext: { _ in secureFocus },
                attemptAccessibilityInsert: { _, _ in
                    XCTFail("Accessibility insertion should not run for secure fields")
                    return false
                },
                attemptTypingInsert: { _, _ in
                    XCTFail("Typing fallback should not run for secure fields")
                    return false
                },
                attemptPasteInsert: { _, _, _ in
                    XCTFail("Paste fallback should not run for secure fields")
                    return false
                }
            )
        )

        let result = service.insert("secret", target: target)

        XCTAssertEqual(result, .secureFieldBlocked)
    }

    func testAccessibilitySuccessShortCircuitsLaterStrategies() {
        let focus = makeFocus()
        let service = TextInsertionService(
            environment: makeEnvironment(
                resolveFocusContext: { _ in focus },
                attemptAccessibilityInsert: { text, resolvedFocus in
                    XCTAssertEqual(text, "typed")
                    XCTAssertEqual(resolvedFocus.role, "AXTextField")
                    return true
                },
                attemptTypingInsert: { _, _ in
                    XCTFail("Typing fallback should not run after AX success")
                    return false
                },
                attemptPasteInsert: { _, _, _ in
                    XCTFail("Paste fallback should not run after AX success")
                    return false
                }
            )
        )

        let result = service.insert("typed", target: target)

        XCTAssertEqual(result, .insertedAccessibility)
    }

    func testAccessibilitySuccessDoesNotReactivateTargetBeforeFirstAttempt() {
        let focus = makeFocus()
        var activateCalls = 0
        let service = TextInsertionService(
            environment: makeEnvironment(
                activateTarget: { _ in activateCalls += 1 },
                resolveFocusContext: { _ in focus },
                attemptAccessibilityInsert: { _, _ in true }
            )
        )

        let result = service.insert("typed", target: target)

        XCTAssertEqual(result, .insertedAccessibility)
        XCTAssertEqual(activateCalls, 0)
    }

    func testVerifiedTypingShortCircuitsPasteWhenEnabled() {
        let focus = makeFocus(
            snapshot: TextInsertionService.VerificationSnapshot(
                text: "before",
                selectedRange: NSRange(location: 6, length: 0)
            )
        )
        let service = TextInsertionService(
            environment: makeEnvironment(
                resolveFocusContext: { _ in focus },
                attemptTypingInsert: { text, target in
                    XCTAssertEqual(text, "typed")
                    XCTAssertEqual(target?.bundleIdentifier, "com.apple.TextEdit")
                    return true
                },
                attemptPasteInsert: { _, _, _ in
                    XCTFail("Paste fallback should not run when typing is verified")
                    return false
                },
                currentSnapshot: { _ in
                    TextInsertionService.VerificationSnapshot(
                        text: "beforetyped",
                        selectedRange: NSRange(location: 11, length: 0)
                    )
                }
            )
        )

        let result = service.insert(
            "typed",
            target: target,
            options: TextInsertionService.InsertionOptions(
                restoreClipboardAfterPaste: true,
                copyToClipboardOnFailure: true,
                allowPasteFallback: true
            )
        )

        XCTAssertEqual(result, .insertedTyping)
    }

    func testTypingFailureFallsBackToPasteWhenExplicitlyEnabled() {
        let focus = makeFocus(
            snapshot: TextInsertionService.VerificationSnapshot(
                text: "before",
                selectedRange: NSRange(location: 6, length: 0)
            )
        )
        var pasteCalls = 0
        let service = TextInsertionService(
            environment: makeEnvironment(
                resolveFocusContext: { _ in focus },
                attemptTypingInsert: { _, _ in false },
                attemptPasteInsert: { text, target, options in
                    pasteCalls += 1
                    XCTAssertEqual(text, "paste me")
                    XCTAssertEqual(target?.bundleIdentifier, "com.apple.TextEdit")
                    XCTAssertTrue(options.restoreClipboardAfterPaste)
                    XCTAssertTrue(options.copyToClipboardOnFailure)
                    XCTAssertTrue(options.allowPasteFallback)
                    return true
                }
            )
        )

        let result = service.insert(
            "paste me",
            target: target,
            options: TextInsertionService.InsertionOptions(
                restoreClipboardAfterPaste: true,
                copyToClipboardOnFailure: true,
                allowPasteFallback: true
            )
        )

        XCTAssertEqual(result, .insertedPaste)
        XCTAssertEqual(pasteCalls, 1)
    }

    func testPasteFallbackCanSucceedWithoutReactivatingTargetOnFirstAttempt() {
        let codeEditorTarget = TextInsertionService.Target(
            applicationPID: 456,
            applicationName: "Cursor",
            bundleIdentifier: "com.todesktop.cursor"
        )
        let focus = TextInsertionService.FocusContext(
            element: nil,
            source: .systemWide,
            applicationPID: codeEditorTarget.applicationPID,
            applicationName: codeEditorTarget.applicationName,
            bundleIdentifier: codeEditorTarget.bundleIdentifier,
            snapshot: TextInsertionService.VerificationSnapshot(
                text: "before",
                selectedRange: NSRange(location: 6, length: 0)
            ),
            securityState: .notSecure,
            role: "AXTextField",
            subrole: nil,
            canSetSelectedText: true,
            canSetValue: true
        )
        var activateCalls = 0
        let service = TextInsertionService(
            environment: makeEnvironment(
                activateTarget: { _ in activateCalls += 1 },
                resolveFocusContext: { _ in focus },
                attemptAccessibilityInsert: { _, _ in false },
                attemptPasteInsert: { _, target, _ in
                    XCTAssertEqual(target?.bundleIdentifier, "com.todesktop.cursor")
                    return true
                }
            )
        )

        let result = service.insert(
            "paste me",
            target: codeEditorTarget,
            options: TextInsertionService.InsertionOptions(
                restoreClipboardAfterPaste: true,
                copyToClipboardOnFailure: true,
                allowPasteFallback: true
            )
        )

        XCTAssertEqual(result, .insertedPaste)
        XCTAssertEqual(activateCalls, 0)
    }

    func testUnverifiableFocusBlocksTypingAndPasteFallbacks() {
        let focus = makeFocus(snapshot: nil)
        let service = TextInsertionService(
            environment: makeEnvironment(
                resolveFocusContext: { _ in focus },
                attemptTypingInsert: { _, _ in
                    XCTFail("Typing should not run when the field cannot be verified")
                    return false
                },
                attemptPasteInsert: { _, _, _ in
                    XCTFail("Paste should not run when the field cannot be verified")
                    return false
                }
            )
        )

        let result = service.insert("paste me", target: target)

        XCTAssertEqual(result, .privacyGuardBlocked)
    }

    func testInsertUsesPreferredTargetBeforeFocusedTarget() {
        let focusedTarget = TextInsertionService.Target(
            applicationPID: 456,
            applicationName: "TextEdit",
            bundleIdentifier: "com.apple.TextEdit"
        )
        let focus = TextInsertionService.FocusContext(
            element: nil,
            source: .systemWide,
            applicationPID: focusedTarget.applicationPID,
            applicationName: focusedTarget.applicationName,
            bundleIdentifier: focusedTarget.bundleIdentifier,
            snapshot: TextInsertionService.VerificationSnapshot(
                text: "before",
                selectedRange: NSRange(location: 6, length: 0)
            ),
            securityState: .notSecure,
            role: "AXTextField",
            subrole: nil,
            canSetSelectedText: true,
            canSetValue: true
        )
        var typingTarget: TextInsertionService.Target?
        let service = TextInsertionService(
            environment: makeEnvironment(
                currentFocusedTarget: { focusedTarget },
                resolveFocusContext: { _ in focus },
                attemptAccessibilityInsert: { _, _ in false },
                attemptTypingInsert: { _, target in
                    typingTarget = target
                    return true
                }
            )
        )

        let result = service.insert("hello world", target: target)

        XCTAssertEqual(result, .insertedTyping)
        XCTAssertEqual(typingTarget, target)
    }

    func testCommitStreamingSessionFallsBackToFrozenTargetWhenLiveUpdateFails() {
        let frozenTarget = TextInsertionService.Target(
            applicationPID: 456,
            applicationName: "Cursor",
            bundleIdentifier: "com.todesktop.cursor"
        )
        let transientFocusedTarget = TextInsertionService.Target(
            applicationPID: 789,
            applicationName: "Notes",
            bundleIdentifier: "com.apple.Notes"
        )
        let focus = TextInsertionService.FocusContext(
            element: nil,
            source: .systemWide,
            applicationPID: frozenTarget.applicationPID,
            applicationName: frozenTarget.applicationName,
            bundleIdentifier: frozenTarget.bundleIdentifier,
            snapshot: TextInsertionService.VerificationSnapshot(
                text: "before",
                selectedRange: NSRange(location: 6, length: 0)
            ),
            securityState: .notSecure,
            role: "AXTextField",
            subrole: nil,
            canSetSelectedText: true,
            canSetValue: true
        )
        let session = TextInsertionService.StreamingSession.testing(target: frozenTarget, mode: .typing)
        var typingTarget: TextInsertionService.Target?
        let service = TextInsertionService(
            environment: makeEnvironment(
                currentFocusedTarget: { transientFocusedTarget },
                resolveFocusContext: { requestedTarget in
                    requestedTarget == frozenTarget ? focus : nil
                },
                attemptAccessibilityInsert: { _, _ in false },
                attemptTypingInsert: { text, target in
                    typingTarget = target
                    XCTAssertEqual(text, "final text")
                    return true
                },
                updateStreamingTypingText: { _, _, _ in
                    false
                },
                currentSnapshot: { _ in
                    TextInsertionService.VerificationSnapshot(
                        text: "beforefinal text",
                        selectedRange: NSRange(location: 16, length: 0)
                    )
                }
            )
        )

        let result = service.commitStreamingSession(session, finalText: "final text")

        XCTAssertEqual(result, TextInsertionService.InsertionOutcome.insertedTyping)
        XCTAssertEqual(typingTarget, frozenTarget)
    }

    func testPasteCanKeepTranscriptOnClipboard() {
        let codeEditorTarget = TextInsertionService.Target(
            applicationPID: 456,
            applicationName: "Cursor",
            bundleIdentifier: "com.todesktop.cursor"
        )
        let focus = TextInsertionService.FocusContext(
            element: nil,
            source: .systemWide,
            applicationPID: codeEditorTarget.applicationPID,
            applicationName: codeEditorTarget.applicationName,
            bundleIdentifier: codeEditorTarget.bundleIdentifier,
            snapshot: TextInsertionService.VerificationSnapshot(
                text: "before",
                selectedRange: NSRange(location: 6, length: 0)
            ),
            securityState: .notSecure,
            role: "AXTextField",
            subrole: nil,
            canSetSelectedText: true,
            canSetValue: true
        )
        var receivedOptions: TextInsertionService.InsertionOptions?
        let service = TextInsertionService(
            environment: makeEnvironment(
                resolveFocusContext: { _ in focus },
                attemptTypingInsert: { _, _ in
                    XCTFail("Typing should not run before paste for code editors")
                    return false
                },
                attemptPasteInsert: { _, _, options in
                    receivedOptions = options
                    return true
                }
            )
        )

        let result = service.insert(
            "paste me",
            target: codeEditorTarget,
            options: TextInsertionService.InsertionOptions(
                restoreClipboardAfterPaste: false,
                copyToClipboardOnFailure: true,
                allowPasteFallback: true
            )
        )

        XCTAssertEqual(result, .insertedPaste)
        XCTAssertEqual(receivedOptions?.restoreClipboardAfterPaste, false)
        XCTAssertEqual(receivedOptions?.copyToClipboardOnFailure, true)
        XCTAssertEqual(receivedOptions?.allowPasteFallback, true)
    }

    func testAccessibilityInsertIsSkippedWhenFocusDoesNotReportWritableAttributes() {
        let focus = makeFocus(
            snapshot: TextInsertionService.VerificationSnapshot(
                text: "before",
                selectedRange: NSRange(location: 6, length: 0)
            ),
            canSetSelectedText: false,
            canSetValue: false
        )
        let service = TextInsertionService(
            environment: makeEnvironment(
                resolveFocusContext: { _ in focus },
                attemptAccessibilityInsert: { _, _ in
                    XCTFail("Accessibility insertion should be skipped when the focus is not writable")
                    return false
                },
                attemptTypingInsert: { _, _ in
                    XCTFail("Typing should be blocked by the privacy guard")
                    return false
                }
            )
        )

        let result = service.insert("typed", target: target)

        XCTAssertEqual(result, .privacyGuardBlocked)
    }

    func testCodeEditorsPreferPasteBeforeTypingEvenWhenFocusIsVerifiable() {
        let codeEditorTarget = TextInsertionService.Target(
            applicationPID: 456,
            applicationName: "Cursor",
            bundleIdentifier: "com.todesktop.cursor"
        )
        let focus = TextInsertionService.FocusContext(
            element: nil,
            source: .systemWide,
            applicationPID: codeEditorTarget.applicationPID,
            applicationName: codeEditorTarget.applicationName,
            bundleIdentifier: codeEditorTarget.bundleIdentifier,
            snapshot: TextInsertionService.VerificationSnapshot(
                text: "before",
                selectedRange: NSRange(location: 6, length: 0)
            ),
            securityState: .notSecure,
            role: "AXTextField",
            subrole: nil,
            canSetSelectedText: true,
            canSetValue: true
        )
        let service = TextInsertionService(
            environment: makeEnvironment(
                resolveFocusContext: { _ in focus },
                attemptTypingInsert: { _, _ in
                    XCTFail("Typing should not run before paste for code editors")
                    return false
                },
                attemptPasteInsert: { _, target, _ in
                    XCTAssertEqual(target?.bundleIdentifier, "com.todesktop.cursor")
                    return true
                }
            )
        )

        let result = service.insert(
            "paste me",
            target: codeEditorTarget,
            options: TextInsertionService.InsertionOptions(
                restoreClipboardAfterPaste: true,
                copyToClipboardOnFailure: true,
                allowPasteFallback: true
            )
        )

        XCTAssertEqual(result, .insertedPaste)
    }

    func testAccessibilityFailureRefreshesFocusAndRetriesOnce() {
        let initialFocus = makeFocus(canSetSelectedText: true)
        let refreshedFocus = makeFocus(canSetSelectedText: true)
        var focusCalls = 0
        var activateCalls = 0
        var accessibilityCalls = 0
        let service = TextInsertionService(
            environment: makeEnvironment(
                activateTarget: { _ in activateCalls += 1 },
                resolveFocusContext: { _ in
                    defer { focusCalls += 1 }
                    return focusCalls == 0 ? initialFocus : refreshedFocus
                },
                attemptAccessibilityInsert: { _, _ in
                    accessibilityCalls += 1
                    return accessibilityCalls == 2
                }
            )
        )

        let result = service.insert("hello", target: target)

        XCTAssertEqual(result, .insertedAccessibility)
        XCTAssertEqual(accessibilityCalls, 2)
        XCTAssertGreaterThanOrEqual(activateCalls, 1)
    }

    func testCopiesTranscriptWhenAllStrategiesFail() {
        let focus = makeFocus(
            snapshot: TextInsertionService.VerificationSnapshot(
                text: "before",
                selectedRange: NSRange(location: 6, length: 0)
            )
        )
        var copiedText: String?
        let service = TextInsertionService(
            environment: makeEnvironment(
                resolveFocusContext: { _ in focus },
                attemptAccessibilityInsert: { _, _ in false },
                attemptTypingInsert: { _, _ in false },
                copyTextToClipboard: { copiedText = $0 }
            )
        )

        let result = service.insert("fallback text", target: target)

        XCTAssertEqual(result, .copiedToClipboardAfterFailure)
        XCTAssertEqual(copiedText, "fallback text")
    }

    func testDoesNotCopyTranscriptWhenFailureClipboardFallbackDisabled() {
        let focus = makeFocus(
            snapshot: TextInsertionService.VerificationSnapshot(
                text: "before",
                selectedRange: NSRange(location: 6, length: 0)
            )
        )
        var copiedText: String?
        let service = TextInsertionService(
            environment: makeEnvironment(
                resolveFocusContext: { _ in focus },
                attemptAccessibilityInsert: { _, _ in false },
                attemptTypingInsert: { _, _ in false },
                copyTextToClipboard: { copiedText = $0 }
            )
        )

        let result = service.insert(
            "fallback text",
            target: target,
            options: TextInsertionService.InsertionOptions(
                restoreClipboardAfterPaste: true,
                copyToClipboardOnFailure: false,
                allowPasteFallback: false
            )
        )

        XCTAssertEqual(result, .failedToInsert)
        XCTAssertNil(copiedText)
    }

    func testUnknownSecurityStateBlocksNonAXFallbacks() {
        let focus = makeFocus(
            securityState: .unknown,
            snapshot: TextInsertionService.VerificationSnapshot(
                text: "before",
                selectedRange: NSRange(location: 6, length: 0)
            )
        )
        let service = TextInsertionService(
            environment: makeEnvironment(
                resolveFocusContext: { _ in focus },
                attemptTypingInsert: { _, _ in
                    XCTFail("Typing should not run when security is ambiguous")
                    return false
                },
                attemptPasteInsert: { _, _, _ in
                    XCTFail("Paste should not run when security is ambiguous")
                    return false
                }
            )
        )

        let result = service.insert(
            "fallback text",
            target: target,
            options: TextInsertionService.InsertionOptions(
                restoreClipboardAfterPaste: true,
                copyToClipboardOnFailure: true,
                allowPasteFallback: true
            )
        )

        XCTAssertEqual(result, .privacyGuardBlocked)
    }

    func testExplicitCopyUsesClipboardEnvironment() {
        var copiedText: String?
        let service = TextInsertionService(
            environment: makeEnvironment(copyTextToClipboard: { copiedText = $0 })
        )

        service.copyToClipboard("copied text")

        XCTAssertEqual(copiedText, "copied text")
    }

    private func makeEnvironment(
        isProcessTrusted: @escaping () -> Bool = { true },
        currentFocusedTarget: @escaping () -> TextInsertionService.Target? = { nil },
        activateTarget: @escaping (TextInsertionService.Target?) -> Void = { _ in },
        resolveFocusContext: @escaping (TextInsertionService.Target?) -> TextInsertionService.FocusContext? = { _ in nil },
        resolveImmediateFocusContext: @escaping (TextInsertionService.Target?) -> TextInsertionService.FocusContext? = { _ in nil },
        attemptAccessibilityInsert: @escaping (String, TextInsertionService.FocusContext) -> Bool = { _, _ in false },
        attemptTypingInsert: @escaping (String, TextInsertionService.Target?) -> Bool = { _, _ in false },
        attemptPasteInsert: @escaping (String, TextInsertionService.Target?, TextInsertionService.InsertionOptions) -> Bool = { _, _, _ in false },
        updateStreamingAccessibilityText: @escaping (String, TextInsertionService.Target?, Int, String) -> Bool = { _, _, _, _ in false },
        updateStreamingTypingText: @escaping (TextInsertionService.Target?, Int, String) -> Bool = { _, _, _ in false },
        currentSnapshot: @escaping (TextInsertionService.FocusContext) -> TextInsertionService.VerificationSnapshot? = { _ in nil },
        copyTextToClipboard: @escaping (String) -> Void = { _ in }
    ) -> TextInsertionService.Environment {
        TextInsertionService.Environment(
            isProcessTrusted: isProcessTrusted,
            currentFocusedTarget: currentFocusedTarget,
            activateTarget: activateTarget,
            resolveFocusContext: resolveFocusContext,
            resolveImmediateFocusContext: resolveImmediateFocusContext,
            attemptAccessibilityInsert: attemptAccessibilityInsert,
            attemptTypingInsert: attemptTypingInsert,
            attemptPasteInsert: attemptPasteInsert,
            updateStreamingAccessibilityText: updateStreamingAccessibilityText,
            updateStreamingTypingText: updateStreamingTypingText,
            currentSnapshot: currentSnapshot,
            copyTextToClipboard: copyTextToClipboard
        )
    }

    private func makeFocus(
        securityState: TextInsertionService.FocusContext.SecurityState = .notSecure,
        role: String? = "AXTextField",
        subrole: String? = nil,
        snapshot: TextInsertionService.VerificationSnapshot? = TextInsertionService.VerificationSnapshot(
            text: "before",
            selectedRange: NSRange(location: 6, length: 0)
        ),
        canSetSelectedText: Bool = true,
        canSetValue: Bool = true
    ) -> TextInsertionService.FocusContext {
        TextInsertionService.FocusContext(
            element: nil,
            source: .systemWide,
            applicationPID: target.applicationPID,
            applicationName: target.applicationName,
            bundleIdentifier: target.bundleIdentifier,
            snapshot: snapshot,
            securityState: securityState,
            role: role,
            subrole: subrole,
            canSetSelectedText: canSetSelectedText,
            canSetValue: canSetValue
        )
    }
}
