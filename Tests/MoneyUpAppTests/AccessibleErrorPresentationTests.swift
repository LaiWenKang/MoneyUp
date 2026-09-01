@testable import MoneyUp
import XCTest

final class AccessibleErrorPresentationTests: XCTestCase {
    func testOperationFailureIsSnapshottedExactlyOnceUntilDismissed() {
        var state = MoneyUpOperationErrorPresentationState()

        state.receive("Safe failure")
        state.receive("Safe failure")
        state.receive("A later value cannot replace the active summary")

        XCTAssertEqual(
            state.active,
            MoneyUpOperationErrorPresentation(id: 1, message: "Safe failure")
        )
        XCTAssertEqual(state.presentationCount, 1)

        XCTAssertTrue(
            state.beginDismissal(
                bindingSnapshot: "A later value cannot replace the active summary"
            )
        )
        state.completeDismissal(bindingSnapshot: nil)
        XCTAssertEqual(
            state.active,
            MoneyUpOperationErrorPresentation(
                id: 2,
                message: "A later value cannot replace the active summary"
            )
        )
    }

    func testDismissalAllowsASeparateFailureToBePresented() {
        var state = MoneyUpOperationErrorPresentationState()
        state.receive("First safe failure")
        XCTAssertTrue(state.beginDismissal(bindingSnapshot: "First safe failure"))
        state.completeDismissal(bindingSnapshot: nil)
        state.receive("Second safe failure")

        XCTAssertEqual(
            state.active,
            MoneyUpOperationErrorPresentation(id: 2, message: "Second safe failure")
        )
        XCTAssertEqual(state.presentationCount, 2)
    }

    func testFailureArrivingDuringPendingPromotionCannotReorderAStaleSummary() {
        var state = MoneyUpOperationErrorPresentationState()
        state.receive("Active failure")
        state.receive("Pending failure")

        XCTAssertTrue(state.beginDismissal(bindingSnapshot: "Pending failure"))
        state.receive("Newest failure")

        XCTAssertNil(state.active)
        XCTAssertEqual(state.pendingMessage, "Newest failure")
        state.completeDismissal(bindingSnapshot: "Newest failure")
        XCTAssertEqual(
            state.active,
            MoneyUpOperationErrorPresentation(id: 2, message: "Newest failure")
        )
        XCTAssertNil(state.pendingMessage)
        XCTAssertTrue(state.beginDismissal(bindingSnapshot: "Newest failure"))
        state.completeDismissal(bindingSnapshot: nil)
        XCTAssertNil(state.active)

        var superseded = MoneyUpOperationErrorPresentationState()
        superseded.receive("Visible failure")
        superseded.receive("Superseded failure")
        superseded.receive("Visible failure")
        XCTAssertNil(superseded.pendingMessage)
        XCTAssertTrue(
            superseded.beginDismissal(bindingSnapshot: "Visible failure")
        )
        superseded.completeDismissal(bindingSnapshot: nil)
        XCTAssertNil(superseded.active)
    }

    func testPostDismissalBindingSnapshotRecoversCoalescedIdenticalFailure() {
        var state = MoneyUpOperationErrorPresentationState()
        state.receive("Same safe failure")

        // Model the binding update chain, not just reducer delivery: the alert
        // clears A to nil, then a second operation republishes A before
        // SwiftUI emits onChange. Only the post-yield binding snapshot sees it.
        XCTAssertTrue(
            state.beginDismissal(bindingSnapshot: "Same safe failure")
        )
        XCTAssertTrue(state.isCompletingDismissal)
        state.completeDismissal(bindingSnapshot: "Same safe failure")

        XCTAssertEqual(
            state.active,
            MoneyUpOperationErrorPresentation(id: 2, message: "Same safe failure")
        )
        XCTAssertFalse(state.isCompletingDismissal)
        XCTAssertNil(state.pendingMessage)
    }

    func testBlankFailureCannotCreateAnEmptyAccessibilityAlert() {
        var state = MoneyUpOperationErrorPresentationState()

        state.receive(nil)
        state.receive("  \n ")

        XCTAssertNil(state.active)
        XCTAssertEqual(state.presentationCount, 0)
    }

    func testRestoreSuccessRouteFollowsTheSurvivingHierarchy() {
        XCTAssertEqual(
            RestoreCompletionAccessibilityRoute(
                initialState: .ready
            ),
            .focusVisibleConfirmation
        )
        XCTAssertEqual(
            RestoreCompletionAccessibilityRoute(
                initialState: .failed("Generic recovery")
            ),
            .announceAfterRecoveryTransition
        )
        XCTAssertEqual(
            RestoreCompletionAccessibilityRoute(
                initialState: .failed("Missing key")
            ),
            .announceAfterRecoveryTransition
        )
    }

    func testRestoreResultWaitsForSheetDismissalAndIsOneShot() {
        var state = RestoreOperationPresentationState()
        state.queue(.success("Restore complete"))

        XCTAssertEqual(
            state.pendingAfterSheetDismissal,
            .success("Restore complete")
        )
        XCTAssertEqual(
            state.takeAfterSheetDismissal(),
            .success("Restore complete")
        )
        XCTAssertNil(state.takeAfterSheetDismissal())

        state.queue(.failure("Safe failure"))
        XCTAssertEqual(
            state.takeAfterSheetDismissal(),
            .failure("Safe failure")
        )

        state.presentVisibleSuccess("Restore complete")
        XCTAssertEqual(state.visibleSuccess, "Restore complete")
        state.clearVisibleSuccess()
        XCTAssertNil(state.visibleSuccess)
    }

    @MainActor
    func testRestoreAnnouncementSurvivesEitherReadyAppearanceOrderingOnce() {
        let model = AppModel(dataEraseIntent: .none)
        model.state = .failed("Recovery")

        model.queueRestoreCompletionForReadyHierarchy("First completion")
        XCTAssertNil(model.takeRestoreCompletionForReadyHierarchy())
        XCTAssertEqual(
            model.pendingRestoreCompletionAnnouncement,
            "First completion"
        )
        model.state = .ready
        XCTAssertEqual(
            model.takeRestoreCompletionForReadyHierarchy(),
            "First completion"
        )
        XCTAssertNil(model.takeRestoreCompletionForReadyHierarchy())

        // If the ready hierarchy appears first, its initial take is empty;
        // the observed token change still has exactly one value to consume.
        XCTAssertNil(model.takeRestoreCompletionForReadyHierarchy())
        model.queueRestoreCompletionForReadyHierarchy("Second completion")
        XCTAssertEqual(
            model.takeRestoreCompletionForReadyHierarchy(),
            "Second completion"
        )
        XCTAssertNil(model.takeRestoreCompletionForReadyHierarchy())

        model.queueRestoreCompletionForReadyHierarchy("Stale completion")
        model.lock()
        XCTAssertNil(model.pendingRestoreCompletionAnnouncement)
    }
}
