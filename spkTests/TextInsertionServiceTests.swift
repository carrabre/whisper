import XCTest
@testable import spk

final class TextInsertionServiceTests: XCTestCase {
    private let target = TextInsertionService.Target(
        applicationPID: 123,
        applicationName: "Cursor",
        bundleIdentifier: "com.todesktop.cursor"
    )

    func testInsertFallsBackToTypingWhenFocusMissing() {
        var typingCalls = 0
        let service = TextInsertionService(
            environment: makeEnvironment(
                attemptTypingInsert: { text, target in
                    typingCalls += 1
                    XCTAssertEqual(text, "hello world")
                    XCTAssertEqual(target?.applicationName, "Cursor")
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
        let secureFocus = makeFocus(isSecure: true, subrole: "AXSecureTextField")
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

    func testVerifiedTypingShortCircuitsPaste() {
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
                    XCTAssertEqual(target?.bundleIdentifier, "com.todesktop.cursor")
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

        let result = service.insert("typed", target: target)

        XCTAssertEqual(result, .insertedTyping)
    }

    func testTypingFailureFallsBackToPaste() {
        var pasteCalls = 0
        let service = TextInsertionService(
            environment: makeEnvironment(
                attemptTypingInsert: { _, _ in false },
                attemptPasteInsert: { text, target, options in
                    pasteCalls += 1
                    XCTAssertEqual(text, "paste me")
                    XCTAssertEqual(target?.bundleIdentifier, "com.todesktop.cursor")
                    XCTAssertTrue(options.restoreClipboardAfterPaste)
                    XCTAssertTrue(options.copyToClipboardOnFailure)
                    return true
                }
            )
        )

        let result = service.insert("paste me", target: target)

        XCTAssertEqual(result, .insertedPaste)
        XCTAssertEqual(pasteCalls, 1)
    }

    func testPasteRunsBeforeTypingWhenFocusCannotBeVerified() {
        let focus = makeFocus()
        let service = TextInsertionService(
            environment: makeEnvironment(
                resolveFocusContext: { _ in focus },
                attemptTypingInsert: { _, _ in
                    XCTFail("Typing should not run before paste when AX verification is unavailable")
                    return false
                },
                attemptPasteInsert: { text, target, _ in
                    XCTAssertEqual(text, "paste me")
                    XCTAssertEqual(target?.bundleIdentifier, "com.todesktop.cursor")
                    return true
                }
            )
        )

        let result = service.insert("paste me", target: target)

        XCTAssertEqual(result, .insertedPaste)
    }

    func testInsertUsesFocusedTargetBeforePreferredTarget() {
        let focusedTarget = TextInsertionService.Target(
            applicationPID: 456,
            applicationName: "TextEdit",
            bundleIdentifier: "com.apple.TextEdit"
        )
        var typingTarget: TextInsertionService.Target?
        let service = TextInsertionService(
            environment: makeEnvironment(
                currentFocusedTarget: { focusedTarget },
                attemptTypingInsert: { _, target in
                    typingTarget = target
                    return true
                },
                attemptPasteInsert: { _, _, _ in false }
            )
        )

        let result = service.insert("hello world", target: target)

        XCTAssertEqual(result, .insertedTyping)
        XCTAssertEqual(typingTarget, focusedTarget)
    }

    func testPasteCanKeepTranscriptOnClipboard() {
        var receivedOptions: TextInsertionService.InsertionOptions?
        let service = TextInsertionService(
            environment: makeEnvironment(
                attemptTypingInsert: { _, _ in false },
                attemptPasteInsert: { _, _, options in
                    receivedOptions = options
                    return true
                }
            )
        )

        let result = service.insert(
            "paste me",
            target: target,
            options: TextInsertionService.InsertionOptions(
                restoreClipboardAfterPaste: false,
                copyToClipboardOnFailure: true
            )
        )

        XCTAssertEqual(result, .insertedPaste)
        XCTAssertEqual(receivedOptions?.restoreClipboardAfterPaste, false)
        XCTAssertEqual(receivedOptions?.copyToClipboardOnFailure, true)
    }

    func testCopiesTranscriptWhenAllStrategiesFail() {
        var copiedText: String?
        let service = TextInsertionService(
            environment: makeEnvironment(
                attemptTypingInsert: { _, _ in false },
                attemptPasteInsert: { _, _, _ in false },
                copyTextToClipboard: { copiedText = $0 }
            )
        )

        let result = service.insert("fallback text", target: target)

        XCTAssertEqual(result, .copiedToClipboardAfterFailure)
        XCTAssertEqual(copiedText, "fallback text")
    }

    func testDoesNotCopyTranscriptWhenFailureClipboardFallbackDisabled() {
        var copiedText: String?
        let service = TextInsertionService(
            environment: makeEnvironment(
                attemptTypingInsert: { _, _ in false },
                attemptPasteInsert: { _, _, _ in false },
                copyTextToClipboard: { copiedText = $0 }
            )
        )

        let result = service.insert(
            "fallback text",
            target: target,
            options: TextInsertionService.InsertionOptions(
                restoreClipboardAfterPaste: true,
                copyToClipboardOnFailure: false
            )
        )

        XCTAssertEqual(result, .failedToInsert)
        XCTAssertNil(copiedText)
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
        attemptAccessibilityInsert: @escaping (String, TextInsertionService.FocusContext) -> Bool = { _, _ in false },
        attemptTypingInsert: @escaping (String, TextInsertionService.Target?) -> Bool = { _, _ in false },
        attemptPasteInsert: @escaping (String, TextInsertionService.Target?, TextInsertionService.InsertionOptions) -> Bool = { _, _, _ in false },
        currentSnapshot: @escaping (TextInsertionService.FocusContext) -> TextInsertionService.VerificationSnapshot? = { _ in nil },
        copyTextToClipboard: @escaping (String) -> Void = { _ in }
    ) -> TextInsertionService.Environment {
        TextInsertionService.Environment(
            isProcessTrusted: isProcessTrusted,
            currentFocusedTarget: currentFocusedTarget,
            activateTarget: activateTarget,
            resolveFocusContext: resolveFocusContext,
            attemptAccessibilityInsert: attemptAccessibilityInsert,
            attemptTypingInsert: attemptTypingInsert,
            attemptPasteInsert: attemptPasteInsert,
            currentSnapshot: currentSnapshot,
            copyTextToClipboard: copyTextToClipboard
        )
    }

    private func makeFocus(
        isSecure: Bool = false,
        role: String? = "AXTextField",
        subrole: String? = nil,
        snapshot: TextInsertionService.VerificationSnapshot? = nil
    ) -> TextInsertionService.FocusContext {
        TextInsertionService.FocusContext(
            element: nil,
            source: .systemWide,
            applicationPID: target.applicationPID,
            applicationName: target.applicationName,
            bundleIdentifier: target.bundleIdentifier,
            snapshot: snapshot,
            isSecure: isSecure,
            role: role,
            subrole: subrole
        )
    }
}
