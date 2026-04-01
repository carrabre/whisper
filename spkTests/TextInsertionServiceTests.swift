import XCTest
@testable import spk

final class TextInsertionServiceTests: XCTestCase {
    private let target = TextInsertionService.Target(
        applicationPID: 123,
        applicationName: "TextEdit",
        bundleIdentifier: "com.apple.TextEdit"
    )

    func testInsertUsesTargetOnlyBlindTypingWhenFocusMissing() {
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

        XCTAssertEqual(result, .insertedTyping)
        XCTAssertEqual(typingCalls, 1)
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

    func testPasteFallbackReactivatesTargetBeforeBlindInsert() {
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
        XCTAssertEqual(activateCalls, 1)
    }

    func testUnverifiableButEditableBlindFallbacksCanStillCopyTranscriptAfterFailure() {
        let focus = makeFocus(snapshot: nil)
        var typingCalls = 0
        var pasteCalls = 0
        var copiedText: String?
        let service = TextInsertionService(
            environment: makeEnvironment(
                resolveFocusContext: { _ in focus },
                attemptTypingInsert: { _, _ in
                    typingCalls += 1
                    return false
                },
                attemptPasteInsert: { _, _, _ in
                    pasteCalls += 1
                    return false
                },
                copyTextToClipboard: { copiedText = $0 }
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

        XCTAssertEqual(result, .copiedToClipboardAfterFailure)
        XCTAssertEqual(typingCalls, 2)
        XCTAssertEqual(pasteCalls, 2)
        XCTAssertEqual(copiedText, "paste me")
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
            applicationPID: target.applicationPID,
            applicationName: target.applicationName,
            bundleIdentifier: target.bundleIdentifier,
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
        let session = TextInsertionService.StreamingSession.testing(target: frozenTarget, mode: .typingVerified)
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

    func testInsertUsesBlindTypingForSnapshotlessEditableFocus() {
        let codeEditorTarget = TextInsertionService.Target(
            applicationPID: 456,
            applicationName: "Cursor",
            bundleIdentifier: "com.todesktop.cursor"
        )
        let snapshotlessEditableFocus = makeFocus(
            for: codeEditorTarget,
            securityState: .unknown,
            role: "AXGroup",
            roleDescription: "text editor",
            isEditable: true,
            snapshot: nil,
            canSetSelectedText: false,
            canSetValue: false
        )
        var typingTarget: TextInsertionService.Target?
        let service = TextInsertionService(
            environment: makeEnvironment(
                resolveFocusContext: { _ in snapshotlessEditableFocus },
                attemptAccessibilityInsert: { _, _ in
                    XCTFail("Accessibility insertion should be skipped for snapshotless blind fallback focus")
                    return false
                },
                attemptTypingInsert: { text, target in
                    XCTAssertEqual(text, "final text")
                    typingTarget = target
                    return true
                }
            )
        )

        let result = service.insert("final text", target: codeEditorTarget)

        XCTAssertEqual(result, .insertedTyping)
        XCTAssertEqual(typingTarget, codeEditorTarget)
    }

    func testInsertUsesCapturedBlindFallbackWhenLiveFocusMissing() {
        let downloadedAppTarget = TextInsertionService.Target(
            applicationPID: 777,
            applicationName: "Writer Pro",
            bundleIdentifier: "com.example.writerpro"
        )
        let capturedFocus = makeFocus(
            for: downloadedAppTarget,
            securityState: .unknown,
            role: "AXDocument",
            roleDescription: "text editor",
            isEditable: true,
            snapshot: nil,
            canSetSelectedText: false,
            canSetValue: false
        )
        let capturedContext = TextInsertionService.CapturedInsertionContext.testing(
            target: downloadedAppTarget,
            focusContext: capturedFocus,
            targetFamily: .other
        )
        var typingTarget: TextInsertionService.Target?
        let service = TextInsertionService(
            environment: makeEnvironment(
                resolveFocusContext: { _ in nil },
                attemptTypingInsert: { text, target in
                    XCTAssertEqual(text, "captured text")
                    typingTarget = target
                    return true
                }
            )
        )

        let result = service.insert(
            "captured text",
            target: downloadedAppTarget,
            capturedContext: capturedContext
        )

        XCTAssertEqual(result, .insertedTyping)
        XCTAssertEqual(typingTarget, downloadedAppTarget)
    }

    func testInsertUsesAggressiveTargetOnlyBlindFallbackForOtherTargetWhenLiveFocusIsMissing() {
        let downloadedAppTarget = TextInsertionService.Target(
            applicationPID: 777,
            applicationName: "Writer Pro",
            bundleIdentifier: "com.example.writerpro"
        )
        var typingTarget: TextInsertionService.Target?
        let service = TextInsertionService(
            environment: makeEnvironment(
                resolveFocusContext: { _ in nil },
                attemptTypingInsert: { text, target in
                    XCTAssertEqual(text, "captured text")
                    typingTarget = target
                    return true
                }
            )
        )

        let result = service.insert("captured text", target: downloadedAppTarget)

        XCTAssertEqual(result, .insertedTyping)
        XCTAssertEqual(typingTarget, downloadedAppTarget)
    }

    func testBeginStreamingSessionUsesBlindTypingForKnownNonSecureSnapshotlessTargetFocus() {
        let downloadedAppTarget = TextInsertionService.Target(
            applicationPID: 456,
            applicationName: "Cursor",
            bundleIdentifier: "com.todesktop.cursor"
        )
        let snapshotlessFocus = makeFocus(
            for: downloadedAppTarget,
            role: "AXTextArea",
            snapshot: nil,
            canSetSelectedText: false,
            canSetValue: false
        )
        var typingUpdates: [(TextInsertionService.Target?, Int, String)] = []
        let service = TextInsertionService(
            environment: makeEnvironment(
                resolveFocusContext: { _ in
                    XCTFail("Waited focus lookup should not run when immediate focus is already usable")
                    return nil
                },
                resolveImmediateFocusContext: { requestedTarget in
                    XCTAssertEqual(requestedTarget, downloadedAppTarget)
                    return snapshotlessFocus
                },
                updateStreamingAccessibilityText: { _, _, _, _ in
                    XCTFail("Blind typing sessions should not use accessibility streaming")
                    return false
                },
                updateStreamingTypingText: { target, deleteCount, textToAppend in
                    typingUpdates.append((target, deleteCount, textToAppend))
                    return true
                }
            )
        )

        let session = service.beginStreamingSession(target: downloadedAppTarget)

        XCTAssertNotNil(session)
        XCTAssertTrue(service.updateStreamingSession(session!, text: "hello world"))
        XCTAssertEqual(typingUpdates.count, 1)
        XCTAssertEqual(typingUpdates[0].0, downloadedAppTarget)
        XCTAssertEqual(typingUpdates[0].1, 0)
        XCTAssertEqual(typingUpdates[0].2, "hello world")
    }

    func testBeginStreamingSessionUsesBlindTypingForUnknownButEditableSnapshotlessTargetFocus() {
        let downloadedAppTarget = TextInsertionService.Target(
            applicationPID: 456,
            applicationName: "Cursor",
            bundleIdentifier: "com.todesktop.cursor"
        )
        let snapshotlessEditableFocus = makeFocus(
            for: downloadedAppTarget,
            securityState: .unknown,
            role: "AXGroup",
            roleDescription: "text editor",
            isEditable: true,
            snapshot: nil,
            canSetSelectedText: false,
            canSetValue: false
        )
        var typingUpdates: [(TextInsertionService.Target?, Int, String)] = []
        let service = TextInsertionService(
            environment: makeEnvironment(
                resolveImmediateFocusContext: { requestedTarget in
                    XCTAssertEqual(requestedTarget, downloadedAppTarget)
                    return snapshotlessEditableFocus
                },
                updateStreamingAccessibilityText: { _, _, _, _ in
                    XCTFail("Blind typing sessions should not use accessibility streaming")
                    return false
                },
                updateStreamingTypingText: { target, deleteCount, textToAppend in
                    typingUpdates.append((target, deleteCount, textToAppend))
                    return true
                }
            )
        )

        let session = service.beginStreamingSession(target: downloadedAppTarget)

        XCTAssertNotNil(session)
        XCTAssertTrue(service.updateStreamingSession(session!, text: "hello cursor"))
        XCTAssertEqual(typingUpdates.count, 1)
        XCTAssertEqual(typingUpdates[0].0, downloadedAppTarget)
        XCTAssertEqual(typingUpdates[0].1, 0)
        XCTAssertEqual(typingUpdates[0].2, "hello cursor")
    }

    func testCodeEditorReadableFocusPrefersTypingVerifiedOverAccessibility() {
        let codeEditorTarget = TextInsertionService.Target(
            applicationPID: 456,
            applicationName: "Cursor",
            bundleIdentifier: "com.todesktop.cursor"
        )
        let readableFocus = makeFocus(
            for: codeEditorTarget,
            role: "AXTextArea",
            snapshot: TextInsertionService.VerificationSnapshot(
                text: "before",
                selectedRange: NSRange(location: 6, length: 0)
            ),
            canSetSelectedText: true,
            canSetValue: true
        )
        let capturedContext = TextInsertionService.CapturedInsertionContext.testing(
            target: codeEditorTarget,
            focusContext: readableFocus,
            targetFamily: .codeEditor
        )
        var typingUpdates: [(TextInsertionService.Target?, Int, String)] = []
        let service = TextInsertionService(
            environment: makeEnvironment(
                resolveImmediateFocusContext: { _ in readableFocus },
                updateStreamingAccessibilityText: { _, _, _, _ in
                    XCTFail("Code editor live streaming should prefer typing over accessibility replacement")
                    return false
                },
                updateStreamingTypingText: { target, deleteCount, textToAppend in
                    typingUpdates.append((target, deleteCount, textToAppend))
                    return true
                }
            )
        )

        let session = service.beginStreamingSession(capturedContext: capturedContext)

        XCTAssertNotNil(session)
        XCTAssertTrue(service.updateStreamingSession(session!, text: "hello"))
        XCTAssertEqual(typingUpdates.count, 1)
        XCTAssertEqual(typingUpdates[0].0, codeEditorTarget)
        XCTAssertEqual(typingUpdates[0].1, 0)
        XCTAssertEqual(typingUpdates[0].2, "hello")
    }

    func testNativeTextControlStillUsesAccessibilityStreaming() {
        let nativeTarget = TextInsertionService.Target(
            applicationPID: 456,
            applicationName: "TextEdit",
            bundleIdentifier: "com.apple.TextEdit"
        )
        let readableFocus = makeFocus(
            for: nativeTarget,
            role: "AXTextField",
            snapshot: TextInsertionService.VerificationSnapshot(
                text: "before",
                selectedRange: NSRange(location: 6, length: 0)
            ),
            canSetSelectedText: true,
            canSetValue: true
        )
        let capturedContext = TextInsertionService.CapturedInsertionContext.testing(
            target: nativeTarget,
            focusContext: readableFocus,
            targetFamily: .nativeTextControl
        )
        var accessibilityUpdates: [(TextInsertionService.Target?, Int, String, String)] = []
        let service = TextInsertionService(
            environment: makeEnvironment(
                resolveImmediateFocusContext: { _ in readableFocus },
                updateStreamingAccessibilityText: { text, target, anchorLocation, currentText in
                    accessibilityUpdates.append((target, anchorLocation, currentText, text))
                    return true
                },
                updateStreamingTypingText: { _, _, _ in
                    XCTFail("Native text controls should keep using accessibility live replacement")
                    return false
                }
            )
        )

        let session = service.beginStreamingSession(capturedContext: capturedContext)

        XCTAssertNotNil(session)
        XCTAssertTrue(service.updateStreamingSession(session!, text: "hello"))
        XCTAssertEqual(accessibilityUpdates.count, 1)
        XCTAssertEqual(accessibilityUpdates[0].0, nativeTarget)
        XCTAssertEqual(accessibilityUpdates[0].1, 6)
        XCTAssertEqual(accessibilityUpdates[0].2, "")
        XCTAssertEqual(accessibilityUpdates[0].3, "hello")
    }

    func testBeginStreamingSessionUsesCapturedSafeFocusWhenCurrentFocusDisappears() {
        let codeEditorTarget = TextInsertionService.Target(
            applicationPID: 456,
            applicationName: "Cursor",
            bundleIdentifier: "com.todesktop.cursor"
        )
        let capturedFocus = makeFocus(
            for: codeEditorTarget,
            role: "AXTextArea",
            snapshot: nil,
            canSetSelectedText: false,
            canSetValue: false
        )
        let capturedContext = TextInsertionService.CapturedInsertionContext.testing(
            target: codeEditorTarget,
            focusContext: capturedFocus,
            targetFamily: .codeEditor
        )
        var typingUpdates: [(TextInsertionService.Target?, Int, String)] = []
        let service = TextInsertionService(
            environment: makeEnvironment(
                resolveFocusContext: { _ in nil },
                resolveImmediateFocusContext: { _ in nil },
                updateStreamingTypingText: { target, deleteCount, textToAppend in
                    typingUpdates.append((target, deleteCount, textToAppend))
                    return true
                }
            )
        )

        let session = service.beginStreamingSession(capturedContext: capturedContext)

        XCTAssertNotNil(session)
        XCTAssertTrue(service.updateStreamingSession(session!, text: "hello"))
        XCTAssertEqual(typingUpdates.count, 1)
        XCTAssertEqual(typingUpdates[0].0, codeEditorTarget)
        XCTAssertEqual(typingUpdates[0].1, 0)
        XCTAssertEqual(typingUpdates[0].2, "hello")
    }

    func testBeginStreamingSessionUsesCapturedSafeFocusWhenCurrentFocusBelongsToSpk() {
        DebugLog.resetForTesting()

        let codeEditorTarget = TextInsertionService.Target(
            applicationPID: 456,
            applicationName: "Cursor",
            bundleIdentifier: "com.todesktop.cursor"
        )
        let capturedFocus = makeFocus(
            for: codeEditorTarget,
            role: "AXTextArea",
            snapshot: nil,
            canSetSelectedText: false,
            canSetValue: false
        )
        let spkFocus = TextInsertionService.FocusContext(
            element: nil,
            source: .systemWide,
            applicationPID: 999,
            applicationName: "spk",
            bundleIdentifier: "com.acfinc.spk",
            snapshot: nil,
            securityState: .notSecure,
            role: "AXWindow",
            subrole: "AXSystemDialog",
            isEditable: false,
            canSetSelectedText: false,
            canSetValue: false
        )
        let capturedContext = TextInsertionService.CapturedInsertionContext.testing(
            target: codeEditorTarget,
            focusContext: capturedFocus,
            targetFamily: .codeEditor
        )
        var typingUpdates: [(TextInsertionService.Target?, Int, String)] = []
        let service = TextInsertionService(
            environment: makeEnvironment(
                resolveFocusContext: { _ in spkFocus },
                resolveImmediateFocusContext: { _ in spkFocus },
                updateStreamingTypingText: { target, deleteCount, textToAppend in
                    typingUpdates.append((target, deleteCount, textToAppend))
                    return true
                }
            )
        )

        let session = service.beginStreamingSession(capturedContext: capturedContext)

        XCTAssertNotNil(session)
        XCTAssertTrue(service.updateStreamingSession(session!, text: "hello"))
        XCTAssertEqual(typingUpdates.count, 1)
        XCTAssertEqual(typingUpdates[0].0, codeEditorTarget)
        XCTAssertEqual(typingUpdates[0].1, 0)
        XCTAssertEqual(typingUpdates[0].2, "hello")

        let diagnostics = DebugLog.snapshotForTesting()
        XCTAssertTrue(diagnostics.contains("rejected current focus because it belongs to a non-target app"))
        XCTAssertTrue(diagnostics.contains("recovering from captured focus context after rejecting non-target current focus"))
    }

    func testBeginStreamingSessionUsesTargetOnlyBlindFallbackWhenCurrentFocusBelongsToNonTargetAndCapturedFallbackIsUnsafe() {
        let codeEditorTarget = TextInsertionService.Target(
            applicationPID: 456,
            applicationName: "Cursor",
            bundleIdentifier: "com.todesktop.cursor"
        )
        let unsafeCapturedFocus = makeFocus(
            for: codeEditorTarget,
            securityState: .unknown,
            role: "AXWindow",
            roleDescription: "window",
            isEditable: false,
            snapshot: nil,
            canSetSelectedText: false,
            canSetValue: false
        )
        let spkFocus = TextInsertionService.FocusContext(
            element: nil,
            source: .systemWide,
            applicationPID: 999,
            applicationName: "spk",
            bundleIdentifier: "com.acfinc.spk",
            snapshot: nil,
            securityState: .notSecure,
            role: "AXWindow",
            subrole: "AXSystemDialog",
            isEditable: false,
            canSetSelectedText: false,
            canSetValue: false
        )
        let capturedContext = TextInsertionService.CapturedInsertionContext.testing(
            target: codeEditorTarget,
            focusContext: unsafeCapturedFocus,
            targetFamily: .codeEditor
        )
        var typingUpdates: [(TextInsertionService.Target?, Int, String)] = []
        let service = TextInsertionService(
            environment: makeEnvironment(
                resolveFocusContext: { _ in spkFocus },
                resolveImmediateFocusContext: { _ in spkFocus },
                updateStreamingTypingText: { target, deleteCount, textToAppend in
                    typingUpdates.append((target, deleteCount, textToAppend))
                    return true
                }
            )
        )

        let session = service.beginStreamingSession(capturedContext: capturedContext)

        XCTAssertNotNil(session)
        XCTAssertTrue(service.updateStreamingSession(session!, text: "hello"))
        XCTAssertEqual(typingUpdates.count, 1)
        XCTAssertEqual(typingUpdates[0].0, codeEditorTarget)
        XCTAssertEqual(typingUpdates[0].1, 0)
        XCTAssertEqual(typingUpdates[0].2, "hello")
    }

    func testBeginStreamingSessionUsesCapturedAccessibilityFallbackForNativeTextControlsWhenCurrentFocusBelongsToSpk() {
        let nativeTarget = TextInsertionService.Target(
            applicationPID: 456,
            applicationName: "TextEdit",
            bundleIdentifier: "com.apple.TextEdit"
        )
        let capturedFocus = makeFocus(
            for: nativeTarget,
            role: "AXTextField",
            snapshot: TextInsertionService.VerificationSnapshot(
                text: "before",
                selectedRange: NSRange(location: 6, length: 0)
            ),
            canSetSelectedText: true,
            canSetValue: true
        )
        let spkFocus = TextInsertionService.FocusContext(
            element: nil,
            source: .systemWide,
            applicationPID: 999,
            applicationName: "spk",
            bundleIdentifier: "com.acfinc.spk",
            snapshot: nil,
            securityState: .notSecure,
            role: "AXWindow",
            subrole: "AXSystemDialog",
            isEditable: false,
            canSetSelectedText: false,
            canSetValue: false
        )
        let capturedContext = TextInsertionService.CapturedInsertionContext.testing(
            target: nativeTarget,
            focusContext: capturedFocus,
            targetFamily: .nativeTextControl
        )
        var accessibilityUpdates: [(TextInsertionService.Target?, Int, String, String)] = []
        let service = TextInsertionService(
            environment: makeEnvironment(
                resolveFocusContext: { _ in spkFocus },
                resolveImmediateFocusContext: { _ in spkFocus },
                updateStreamingAccessibilityText: { text, target, anchorLocation, currentText in
                    accessibilityUpdates.append((target, anchorLocation, currentText, text))
                    return true
                },
                updateStreamingTypingText: { _, _, _ in
                    XCTFail("Native text controls should keep using accessibility streaming when a captured writable focus is available")
                    return false
                }
            )
        )

        let session = service.beginStreamingSession(capturedContext: capturedContext)

        XCTAssertNotNil(session)
        XCTAssertTrue(service.updateStreamingSession(session!, text: "hello"))
        XCTAssertEqual(accessibilityUpdates.count, 1)
        XCTAssertEqual(accessibilityUpdates[0].0, nativeTarget)
        XCTAssertEqual(accessibilityUpdates[0].1, 6)
        XCTAssertEqual(accessibilityUpdates[0].2, "")
        XCTAssertEqual(accessibilityUpdates[0].3, "hello")
    }

    func testBeginStreamingSessionUsesTargetOnlyBlindFallbackWhenCurrentFocusIsMissing() {
        let codeEditorTarget = TextInsertionService.Target(
            applicationPID: 456,
            applicationName: "Cursor",
            bundleIdentifier: "com.todesktop.cursor"
        )
        let capturedContext = TextInsertionService.CapturedInsertionContext.testing(
            target: codeEditorTarget,
            focusContext: nil,
            targetFamily: .codeEditor
        )
        var typingUpdates: [(TextInsertionService.Target?, Int, String)] = []
        let service = TextInsertionService(
            environment: makeEnvironment(
                resolveFocusContext: { _ in nil },
                resolveImmediateFocusContext: { _ in nil },
                updateStreamingTypingText: { target, deleteCount, textToAppend in
                    typingUpdates.append((target, deleteCount, textToAppend))
                    return true
                }
            )
        )

        let session = service.beginStreamingSession(capturedContext: capturedContext)

        XCTAssertNotNil(session)
        XCTAssertTrue(service.updateStreamingSession(session!, text: "hello"))
        XCTAssertEqual(typingUpdates.count, 1)
        XCTAssertEqual(typingUpdates[0].0, codeEditorTarget)
        XCTAssertEqual(typingUpdates[0].1, 0)
        XCTAssertEqual(typingUpdates[0].2, "hello")
    }

    func testBeginStreamingSessionFailsForSecureFocus() {
        let codeEditorTarget = TextInsertionService.Target(
            applicationPID: 456,
            applicationName: "Cursor",
            bundleIdentifier: "com.todesktop.cursor"
        )
        let secureFocus = makeFocus(
            for: codeEditorTarget,
            securityState: .secure,
            subrole: "AXSecureTextField",
            snapshot: nil,
            canSetSelectedText: false,
            canSetValue: false
        )
        let service = TextInsertionService(
            environment: makeEnvironment(
                resolveFocusContext: { _ in
                    XCTFail("Waited focus lookup should not run for an immediate secure focus")
                    return nil
                },
                resolveImmediateFocusContext: { _ in secureFocus },
            )
        )

        XCTAssertNil(service.beginStreamingSession(target: codeEditorTarget))
    }

    func testBeginStreamingSessionUsesTargetOnlyBlindFallbackWhenImmediateFocusCannotBeProvenStreamable() {
        let downloadedAppTarget = TextInsertionService.Target(
            applicationPID: 456,
            applicationName: "Downloaded App",
            bundleIdentifier: "com.example.downloaded"
        )
        let unknownFocus = makeFocus(
            for: downloadedAppTarget,
            securityState: .unknown,
            role: "AXGroup",
            snapshot: nil,
            canSetSelectedText: false,
            canSetValue: false
        )
        var typingUpdates: [(TextInsertionService.Target?, Int, String)] = []
        let service = TextInsertionService(
            environment: makeEnvironment(
                resolveFocusContext: { _ in
                    XCTFail("Waited focus lookup should not run for an immediate unknown-security focus")
                    return nil
                },
                resolveImmediateFocusContext: { _ in unknownFocus },
                updateStreamingTypingText: { target, deleteCount, textToAppend in
                    typingUpdates.append((target, deleteCount, textToAppend))
                    return true
                }
            )
        )

        let session = service.beginStreamingSession(target: downloadedAppTarget)

        XCTAssertNotNil(session)
        XCTAssertTrue(service.updateStreamingSession(session!, text: "hello"))
        XCTAssertEqual(typingUpdates.count, 1)
        XCTAssertEqual(typingUpdates[0].0, downloadedAppTarget)
        XCTAssertEqual(typingUpdates[0].1, 0)
        XCTAssertEqual(typingUpdates[0].2, "hello")
    }

    func testBeginStreamingSessionWaitsForTargetOwnedFocusWhenImmediateFocusIsUnavailable() {
        let downloadedAppTarget = TextInsertionService.Target(
            applicationPID: 456,
            applicationName: "Downloaded App",
            bundleIdentifier: "com.example.downloaded"
        )
        let waitedFocus = makeFocus(
            for: downloadedAppTarget,
            role: "AXTextArea",
            snapshot: nil,
            canSetSelectedText: false,
            canSetValue: false
        )
        var waitedLookups = 0
        var typingUpdates: [(TextInsertionService.Target?, Int, String)] = []
        let service = TextInsertionService(
            environment: makeEnvironment(
                resolveFocusContext: { requestedTarget in
                    waitedLookups += 1
                    XCTAssertEqual(requestedTarget, downloadedAppTarget)
                    return waitedFocus
                },
                resolveImmediateFocusContext: { _ in nil },
                updateStreamingTypingText: { target, deleteCount, textToAppend in
                    typingUpdates.append((target, deleteCount, textToAppend))
                    return true
                }
            )
        )

        let session = service.beginStreamingSession(target: downloadedAppTarget)

        XCTAssertNotNil(session)
        XCTAssertEqual(waitedLookups, 1)
        XCTAssertTrue(service.updateStreamingSession(session!, text: "hello"))
        XCTAssertEqual(typingUpdates.count, 1)
        XCTAssertEqual(typingUpdates[0].0, downloadedAppTarget)
        XCTAssertEqual(typingUpdates[0].1, 0)
        XCTAssertEqual(typingUpdates[0].2, "hello")
    }

    func testBeginStreamingSessionDoesNotRequireAllowlistedBundlePrefixes() {
        let downloadedAppTarget = TextInsertionService.Target(
            applicationPID: 456,
            applicationName: "Writer Pro",
            bundleIdentifier: "com.example.writerpro"
        )
        let snapshotlessFocus = makeFocus(
            for: downloadedAppTarget,
            role: "AXTextArea",
            snapshot: nil,
            canSetSelectedText: false,
            canSetValue: false
        )
        var typingUpdates: [(TextInsertionService.Target?, Int, String)] = []
        let service = TextInsertionService(
            environment: makeEnvironment(
                resolveImmediateFocusContext: { _ in snapshotlessFocus },
                updateStreamingTypingText: { target, deleteCount, textToAppend in
                    typingUpdates.append((target, deleteCount, textToAppend))
                    return true
                }
            )
        )

        let session = service.beginStreamingSession(target: downloadedAppTarget)

        XCTAssertNotNil(session)
        XCTAssertTrue(service.updateStreamingSession(session!, text: "draft"))
        XCTAssertEqual(typingUpdates.count, 1)
        XCTAssertEqual(typingUpdates[0].0, downloadedAppTarget)
        XCTAssertEqual(typingUpdates[0].1, 0)
        XCTAssertEqual(typingUpdates[0].2, "draft")
    }

    func testBeginStreamingSessionUsesTargetOnlyBlindFallbackForOtherTargetWhenCurrentFocusBelongsToNonTargetApp() {
        let downloadedAppTarget = TextInsertionService.Target(
            applicationPID: 777,
            applicationName: "Writer Pro",
            bundleIdentifier: "com.example.writerpro"
        )
        let unsafeCapturedFocus = makeFocus(
            for: downloadedAppTarget,
            securityState: .unknown,
            role: "AXWindow",
            roleDescription: "window",
            isEditable: false,
            snapshot: nil,
            canSetSelectedText: false,
            canSetValue: false
        )
        let spkFocus = TextInsertionService.FocusContext(
            element: nil,
            source: .systemWide,
            applicationPID: 999,
            applicationName: "spk",
            bundleIdentifier: "com.acfinc.spk",
            snapshot: nil,
            securityState: .notSecure,
            role: "AXWindow",
            subrole: "AXSystemDialog",
            isEditable: false,
            canSetSelectedText: false,
            canSetValue: false
        )
        let capturedContext = TextInsertionService.CapturedInsertionContext.testing(
            target: downloadedAppTarget,
            focusContext: unsafeCapturedFocus,
            targetFamily: .other
        )
        var typingUpdates: [(TextInsertionService.Target?, Int, String)] = []
        let service = TextInsertionService(
            environment: makeEnvironment(
                resolveFocusContext: { _ in spkFocus },
                resolveImmediateFocusContext: { _ in spkFocus },
                updateStreamingTypingText: { target, deleteCount, textToAppend in
                    typingUpdates.append((target, deleteCount, textToAppend))
                    return true
                }
            )
        )

        let session = service.beginStreamingSession(capturedContext: capturedContext)

        XCTAssertNotNil(session)
        XCTAssertTrue(service.updateStreamingSession(session!, text: "hello"))
        XCTAssertEqual(typingUpdates.count, 1)
        XCTAssertEqual(typingUpdates[0].0, downloadedAppTarget)
        XCTAssertEqual(typingUpdates[0].1, 0)
        XCTAssertEqual(typingUpdates[0].2, "hello")
    }

    func testInsertPreparesLikelyElectronTargetBeforeResolvingFocus() {
        let electronTarget = TextInsertionService.Target(
            applicationPID: 456,
            applicationName: "Cursor",
            bundleIdentifier: "com.todesktop.230313mzl4w4u92"
        )
        let focus = makeFocus(
            for: electronTarget,
            role: "AXTextArea",
            snapshot: nil,
            canSetSelectedText: false,
            canSetValue: false
        )
        var didPrepare = false
        var preparedTargets: [TextInsertionService.Target?] = []
        var typingTarget: TextInsertionService.Target?
        let service = TextInsertionService(
            environment: makeEnvironment(
                targetMetadata: { target in
                    XCTAssertEqual(target?.bundleIdentifier, electronTarget.bundleIdentifier)
                    return TextInsertionService.TargetMetadata(
                        isLikelyElectron: true,
                        isCodeEditor: true
                    )
                },
                prepareTargetForFocusProbing: { target in
                    preparedTargets.append(target)
                    didPrepare = true
                },
                resolveFocusContext: { requestedTarget in
                    XCTAssertEqual(requestedTarget, electronTarget)
                    return didPrepare ? focus : nil
                },
                attemptTypingInsert: { _, target in
                    typingTarget = target
                    return true
                }
            )
        )

        let result = service.insert("hello electron", target: electronTarget)

        XCTAssertEqual(result, .insertedTyping)
        XCTAssertEqual(preparedTargets, [electronTarget])
        XCTAssertEqual(typingTarget, electronTarget)
    }

    func testBeginStreamingSessionPreparesLikelyElectronTargetBeforeImmediateFocusLookup() {
        let electronTarget = TextInsertionService.Target(
            applicationPID: 456,
            applicationName: "Electron Notes",
            bundleIdentifier: "com.example.electron-notes"
        )
        let focus = makeFocus(
            for: electronTarget,
            role: "AXTextArea",
            snapshot: nil,
            canSetSelectedText: false,
            canSetValue: false
        )
        var didPrepare = false
        var preparedTargets: [TextInsertionService.Target?] = []
        var typingUpdates: [(TextInsertionService.Target?, Int, String)] = []
        let service = TextInsertionService(
            environment: makeEnvironment(
                targetMetadata: { target in
                    XCTAssertEqual(target?.bundleIdentifier, electronTarget.bundleIdentifier)
                    return TextInsertionService.TargetMetadata(
                        isLikelyElectron: true,
                        isCodeEditor: false
                    )
                },
                prepareTargetForFocusProbing: { target in
                    preparedTargets.append(target)
                    didPrepare = true
                },
                resolveImmediateFocusContext: { requestedTarget in
                    XCTAssertEqual(requestedTarget, electronTarget)
                    return didPrepare ? focus : nil
                },
                updateStreamingTypingText: { target, deleteCount, textToAppend in
                    typingUpdates.append((target, deleteCount, textToAppend))
                    return true
                }
            )
        )

        let session = service.beginStreamingSession(target: electronTarget)

        XCTAssertNotNil(session)
        XCTAssertEqual(preparedTargets, [electronTarget])
        XCTAssertTrue(service.updateStreamingSession(session!, text: "draft"))
        XCTAssertEqual(typingUpdates.count, 1)
        XCTAssertEqual(typingUpdates[0].0, electronTarget)
        XCTAssertEqual(typingUpdates[0].1, 0)
        XCTAssertEqual(typingUpdates[0].2, "draft")
    }

    func testLikelyElectronTargetWithoutFocusAfterPreparationUsesTargetOnlyBlindFallback() {
        let electronTarget = TextInsertionService.Target(
            applicationPID: 456,
            applicationName: "Electron Notes",
            bundleIdentifier: "com.example.electron-notes"
        )
        var preparedTargets: [TextInsertionService.Target?] = []
        var typingCalls = 0
        let service = TextInsertionService(
            environment: makeEnvironment(
                targetMetadata: { target in
                    XCTAssertEqual(target?.bundleIdentifier, electronTarget.bundleIdentifier)
                    return TextInsertionService.TargetMetadata(
                        isLikelyElectron: true,
                        isCodeEditor: false
                    )
                },
                prepareTargetForFocusProbing: { target in
                    preparedTargets.append(target)
                },
                resolveFocusContext: { requestedTarget in
                    XCTAssertEqual(requestedTarget, electronTarget)
                    return nil
                },
                attemptTypingInsert: { _, _ in
                    typingCalls += 1
                    return true
                }
            )
        )

        let result = service.insert("blocked", target: electronTarget)

        XCTAssertEqual(result, .insertedTyping)
        XCTAssertEqual(preparedTargets, [electronTarget])
        XCTAssertEqual(typingCalls, 1)
    }

    func testNativeTargetDoesNotPrepareForElectronFocusProbing() {
        let nativeTarget = TextInsertionService.Target(
            applicationPID: 456,
            applicationName: "TextEdit",
            bundleIdentifier: "com.apple.TextEdit"
        )
        let focus = makeFocus(
            for: nativeTarget,
            role: "AXTextField"
        )
        var preparedTargets: [TextInsertionService.Target?] = []
        let service = TextInsertionService(
            environment: makeEnvironment(
                targetMetadata: { target in
                    XCTAssertEqual(target?.bundleIdentifier, nativeTarget.bundleIdentifier)
                    return TextInsertionService.TargetMetadata(
                        isLikelyElectron: false,
                        isCodeEditor: false
                    )
                },
                prepareTargetForFocusProbing: { target in
                    preparedTargets.append(target)
                },
                resolveImmediateFocusContext: { requestedTarget in
                    XCTAssertEqual(requestedTarget, nativeTarget)
                    return focus
                },
                updateStreamingAccessibilityText: { _, _, _, _ in true }
            )
        )

        XCTAssertNotNil(service.beginStreamingSession(target: nativeTarget))
        XCTAssertTrue(preparedTargets.isEmpty)
    }

    func testCurrentCursorBundleClassifiesAsCodeEditorViaMetadata() {
        DebugLog.resetForTesting()

        let currentCursorTarget = TextInsertionService.Target(
            applicationPID: 456,
            applicationName: "Cursor",
            bundleIdentifier: "com.todesktop.230313mzl4w4u92"
        )
        let focus = makeFocus(
            for: currentCursorTarget,
            role: "AXTextArea",
            snapshot: nil,
            canSetSelectedText: false,
            canSetValue: false
        )
        let service = TextInsertionService(
            environment: makeEnvironment(
                targetMetadata: { target in
                    XCTAssertEqual(target?.bundleIdentifier, currentCursorTarget.bundleIdentifier)
                    return TextInsertionService.TargetMetadata(
                        isLikelyElectron: true,
                        isCodeEditor: true
                    )
                },
                resolveImmediateFocusContext: { _ in focus },
                updateStreamingTypingText: { _, _, _ in true }
            )
        )

        XCTAssertNotNil(service.beginStreamingSession(target: currentCursorTarget))

        let diagnostics = DebugLog.snapshotForTesting()
        XCTAssertTrue(diagnostics.contains("bundle=com.todesktop.230313mzl4w4u92"))
        XCTAssertTrue(diagnostics.contains("family=code-editor"))
    }

    func testUnknownElectronTargetClassifiesAsBrowserOrElectronViaMetadata() {
        DebugLog.resetForTesting()

        let electronTarget = TextInsertionService.Target(
            applicationPID: 456,
            applicationName: "Electron Notes",
            bundleIdentifier: "com.example.electron-notes"
        )
        let focus = makeFocus(
            for: electronTarget,
            role: "AXTextArea",
            snapshot: nil,
            canSetSelectedText: false,
            canSetValue: false
        )
        let service = TextInsertionService(
            environment: makeEnvironment(
                targetMetadata: { target in
                    XCTAssertEqual(target?.bundleIdentifier, electronTarget.bundleIdentifier)
                    return TextInsertionService.TargetMetadata(
                        isLikelyElectron: true,
                        isCodeEditor: false
                    )
                },
                resolveImmediateFocusContext: { _ in focus },
                updateStreamingTypingText: { _, _, _ in true }
            )
        )

        XCTAssertNotNil(service.beginStreamingSession(target: electronTarget))

        let diagnostics = DebugLog.snapshotForTesting()
        XCTAssertTrue(diagnostics.contains("family=browser-or-electron"))
    }

    func testUnknownWebAreaTargetClassifiesAsBrowserOrElectronViaFocusRole() {
        DebugLog.resetForTesting()

        let webWrapperTarget = TextInsertionService.Target(
            applicationPID: 456,
            applicationName: "Wrapped Editor",
            bundleIdentifier: "com.example.wrapped-editor"
        )
        let focus = makeFocus(
            for: webWrapperTarget,
            role: "AXWebArea",
            snapshot: nil,
            canSetSelectedText: false,
            canSetValue: false
        )
        let service = TextInsertionService(
            environment: makeEnvironment(
                targetMetadata: { target in
                    XCTAssertEqual(target?.bundleIdentifier, webWrapperTarget.bundleIdentifier)
                    return TextInsertionService.TargetMetadata(
                        isLikelyElectron: false,
                        isCodeEditor: false
                    )
                },
                resolveImmediateFocusContext: { _ in focus },
                updateStreamingTypingText: { _, _, _ in true }
            )
        )

        XCTAssertNotNil(service.beginStreamingSession(target: webWrapperTarget))

        let diagnostics = DebugLog.snapshotForTesting()
        XCTAssertTrue(diagnostics.contains("family=browser-or-electron"))
    }

    func testInsertAllowsBlindTypingForUnknownWebAreaTarget() {
        let webWrapperTarget = TextInsertionService.Target(
            applicationPID: 456,
            applicationName: "Wrapped Editor",
            bundleIdentifier: "com.example.wrapped-editor"
        )
        let focus = makeFocus(
            for: webWrapperTarget,
            role: "AXWebArea",
            snapshot: nil,
            canSetSelectedText: false,
            canSetValue: false
        )
        var typedText: String?
        var typedTarget: TextInsertionService.Target?
        let service = TextInsertionService(
            environment: makeEnvironment(
                targetMetadata: { target in
                    XCTAssertEqual(target?.bundleIdentifier, webWrapperTarget.bundleIdentifier)
                    return TextInsertionService.TargetMetadata(
                        isLikelyElectron: false,
                        isCodeEditor: false
                    )
                },
                resolveFocusContext: { requestedTarget in
                    XCTAssertEqual(requestedTarget, webWrapperTarget)
                    return focus
                },
                attemptTypingInsert: { text, target in
                    typedText = text
                    typedTarget = target
                    return true
                }
            )
        )

        let result = service.insert("hello wrapped editor", target: webWrapperTarget)

        XCTAssertEqual(result, .insertedTyping)
        XCTAssertEqual(typedText, "hello wrapped editor")
        XCTAssertEqual(typedTarget, webWrapperTarget)
    }

    func testUnknownNonElectronTargetKeepsOtherFamilyClassification() {
        DebugLog.resetForTesting()

        let nonElectronTarget = TextInsertionService.Target(
            applicationPID: 456,
            applicationName: "Writer Pro",
            bundleIdentifier: "com.example.writerpro"
        )
        let focus = makeFocus(
            for: nonElectronTarget,
            role: "AXTextArea",
            snapshot: nil,
            canSetSelectedText: false,
            canSetValue: false
        )
        let service = TextInsertionService(
            environment: makeEnvironment(
                targetMetadata: { target in
                    XCTAssertEqual(target?.bundleIdentifier, nonElectronTarget.bundleIdentifier)
                    return TextInsertionService.TargetMetadata(
                        isLikelyElectron: false,
                        isCodeEditor: false
                    )
                },
                resolveImmediateFocusContext: { _ in focus },
                updateStreamingTypingText: { _, _, _ in true }
            )
        )

        XCTAssertNotNil(service.beginStreamingSession(target: nonElectronTarget))

        let diagnostics = DebugLog.snapshotForTesting()
        XCTAssertTrue(diagnostics.contains("family=other"))
    }

    func testCompatibilityDiagnosticsIncludeUnredactedAppIdentityAndModeReason() {
        DebugLog.resetForTesting()

        let codeEditorTarget = TextInsertionService.Target(
            applicationPID: 456,
            applicationName: "Cursor",
            bundleIdentifier: "com.todesktop.cursor"
        )
        let capturedFocus = makeFocus(
            for: codeEditorTarget,
            role: "AXTextArea",
            snapshot: nil,
            canSetSelectedText: false,
            canSetValue: false
        )
        let targetProbe = TextInsertionService.CapturedInsertionContext.ProbeMetadata(
            source: .targetApplication,
            matchedTarget: true,
            role: "AXTextArea",
            subrole: nil,
            securityState: .notSecure,
            hasSnapshot: false,
            canSetSelectedText: false,
            canSetValue: false,
            axErrorCode: -25212,
            axErrorDescription: "no-value",
            applicationPID: codeEditorTarget.applicationPID,
            applicationName: codeEditorTarget.applicationName,
            bundleIdentifier: codeEditorTarget.bundleIdentifier,
            usable: false
        )
        let systemProbe = TextInsertionService.CapturedInsertionContext.ProbeMetadata(
            source: .systemWide,
            matchedTarget: true,
            role: "AXTextArea",
            subrole: nil,
            securityState: .notSecure,
            hasSnapshot: false,
            canSetSelectedText: false,
            canSetValue: false,
            axErrorCode: -25212,
            axErrorDescription: "no-value",
            applicationPID: codeEditorTarget.applicationPID,
            applicationName: codeEditorTarget.applicationName,
            bundleIdentifier: codeEditorTarget.bundleIdentifier,
            usable: false
        )
        let capturedContext = TextInsertionService.CapturedInsertionContext.testing(
            target: codeEditorTarget,
            focusContext: capturedFocus,
            captureMethod: "focused-app",
            targetFamily: .codeEditor,
            targetApplicationProbe: targetProbe,
            systemWideProbe: systemProbe
        )
        let service = TextInsertionService(
            environment: makeEnvironment(
                resolveFocusContext: { _ in nil },
                resolveImmediateFocusContext: { _ in nil },
                updateStreamingTypingText: { _, _, _ in true }
            )
        )

        let session = service.beginStreamingSession(capturedContext: capturedContext)

        XCTAssertNotNil(session)
        let diagnostics = DebugLog.snapshotForTesting()
        XCTAssertTrue(diagnostics.contains("target=Cursor pid=456 bundle=com.todesktop.cursor"))
        XCTAssertTrue(diagnostics.contains("family=code-editor"))
        XCTAssertTrue(diagnostics.contains("capture=method=focused-app"))
        XCTAssertTrue(diagnostics.contains("axError=-25212:no-value"))
        XCTAssertTrue(diagnostics.contains("mode=typing-blind"))
        XCTAssertTrue(diagnostics.contains("reason=typing-blind"))
    }

    func testInsertBlocksTargetOnlyBlindFallbackWhenCapturedFrozenFocusWasSecure() {
        let downloadedAppTarget = TextInsertionService.Target(
            applicationPID: 777,
            applicationName: "Writer Pro",
            bundleIdentifier: "com.example.writerpro"
        )
        let secureCapturedFocus = makeFocus(
            for: downloadedAppTarget,
            securityState: .secure,
            subrole: "AXSecureTextField",
            snapshot: nil,
            canSetSelectedText: false,
            canSetValue: false
        )
        let capturedContext = TextInsertionService.CapturedInsertionContext.testing(
            target: downloadedAppTarget,
            focusContext: secureCapturedFocus,
            targetFamily: .other
        )
        let service = TextInsertionService(
            environment: makeEnvironment(
                resolveFocusContext: { _ in nil },
                attemptTypingInsert: { _, _ in
                    XCTFail("Blind typing should not run when the captured frozen focus was secure")
                    return false
                }
            )
        )

        let result = service.insert(
            "secret",
            target: downloadedAppTarget,
            capturedContext: capturedContext
        )

        XCTAssertEqual(result, .secureFieldBlocked)
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
                    false
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

    func testAccessibilityInsertIsSkippedWhenFocusDoesNotReportWritableAttributesButTypingCanStillRecover() {
        let focus = makeFocus(
            snapshot: TextInsertionService.VerificationSnapshot(
                text: "before",
                selectedRange: NSRange(location: 6, length: 0)
            ),
            canSetSelectedText: false,
            canSetValue: false
        )
        var typingCalled = false
        let service = TextInsertionService(
            environment: makeEnvironment(
                resolveFocusContext: { _ in focus },
                attemptAccessibilityInsert: { _, _ in
                    XCTFail("Accessibility insertion should be skipped when the focus is not writable")
                    return false
                },
                attemptTypingInsert: { _, _ in
                    typingCalled = true
                    return true
                }
            )
        )

        let result = service.insert("typed", target: target)

        XCTAssertEqual(result, .insertedTyping)
        XCTAssertTrue(typingCalled)
    }

    func testCodeEditorsPreferTypingBeforePasteEvenWhenPasteFallbackIsEnabled() {
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
                    true
                },
                attemptPasteInsert: { _, target, _ in
                    XCTFail("Paste fallback should not run after typing succeeds for code editors")
                    XCTAssertEqual(target?.bundleIdentifier, "com.todesktop.cursor")
                    return false
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

        XCTAssertEqual(result, .insertedTyping)
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

    func testUnknownNonEditableSecurityStateFallsBackToAggressiveTargetAuthorityTyping() {
        let focus = makeFocus(
            securityState: .unknown,
            role: "AXGroup",
            roleDescription: "group",
            isEditable: false,
            snapshot: nil,
            canSetSelectedText: false,
            canSetValue: false
        )
        var typingCalls = 0
        var pasteCalls = 0
        var copiedText: String?
        let service = TextInsertionService(
            environment: makeEnvironment(
                resolveFocusContext: { _ in focus },
                attemptTypingInsert: { _, _ in
                    typingCalls += 1
                    return false
                },
                attemptPasteInsert: { _, _, _ in
                    pasteCalls += 1
                    return false
                },
                copyTextToClipboard: { copiedText = $0 }
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

        XCTAssertEqual(result, .copiedToClipboardAfterFailure)
        XCTAssertEqual(typingCalls, 2)
        XCTAssertEqual(pasteCalls, 2)
        XCTAssertEqual(copiedText, "fallback text")
    }

    func testDegradedStreamingSessionCanStillClearLastKnownPreview() {
        let frozenTarget = TextInsertionService.Target(
            applicationPID: 456,
            applicationName: "Cursor",
            bundleIdentifier: "com.todesktop.cursor"
        )
        let session = TextInsertionService.StreamingSession.testing(target: frozenTarget, mode: .typingBlind)
        var typingUpdates: [(TextInsertionService.Target?, Int, String)] = []
        let service = TextInsertionService(
            environment: makeEnvironment(
                updateStreamingTypingText: { target, deleteCount, textToAppend in
                    typingUpdates.append((target, deleteCount, textToAppend))
                    return typingUpdates.count != 2
                }
            )
        )

        XCTAssertTrue(service.updateStreamingSession(session, text: "hello"))
        XCTAssertFalse(service.updateStreamingSession(session, text: "hello world"))
        XCTAssertFalse(session.isHealthy)

        service.cancelStreamingSession(session)

        XCTAssertEqual(typingUpdates.count, 3)
        XCTAssertEqual(typingUpdates[0].0, frozenTarget)
        XCTAssertEqual(typingUpdates[0].1, 0)
        XCTAssertEqual(typingUpdates[0].2, "hello")
        XCTAssertEqual(typingUpdates[1].0, frozenTarget)
        XCTAssertEqual(typingUpdates[1].1, 0)
        XCTAssertEqual(typingUpdates[1].2, " world")
        XCTAssertEqual(typingUpdates[2].0, frozenTarget)
        XCTAssertEqual(typingUpdates[2].1, 5)
        XCTAssertEqual(typingUpdates[2].2, "")
        XCTAssertTrue(session.isHealthy)
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
        targetMetadata: @escaping (TextInsertionService.Target?) -> TextInsertionService.TargetMetadata? = { _ in nil },
        prepareTargetForFocusProbing: @escaping (TextInsertionService.Target?) -> Void = { _ in },
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
            targetMetadata: targetMetadata,
            prepareTargetForFocusProbing: prepareTargetForFocusProbing,
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
        for target: TextInsertionService.Target? = nil,
        securityState: TextInsertionService.FocusContext.SecurityState = .notSecure,
        role: String? = "AXTextField",
        subrole: String? = nil,
        roleDescription: String? = nil,
        isEditable: Bool = false,
        snapshot: TextInsertionService.VerificationSnapshot? = TextInsertionService.VerificationSnapshot(
            text: "before",
            selectedRange: NSRange(location: 6, length: 0)
        ),
        canSetSelectedText: Bool = true,
        canSetValue: Bool = true
    ) -> TextInsertionService.FocusContext {
        let resolvedTarget = target ?? self.target
        return TextInsertionService.FocusContext(
            element: nil,
            source: .systemWide,
            applicationPID: resolvedTarget.applicationPID,
            applicationName: resolvedTarget.applicationName,
            bundleIdentifier: resolvedTarget.bundleIdentifier,
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
}
