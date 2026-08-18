import XCTest

@testable import PriorityCore

/// The five modal gates at the top of `KeyboardShortcutRouter.handle`, and the
/// order they are tried in. Getting the order wrong makes the keyboard dead in
/// a keyboard-first app, and none of it could be tested while it lived inside a
/// ~1,000-line function taking `NSEvent` and `AppCoordinator`.
final class ShortcutGateTests: XCTestCase {

  private typealias Key = ShortcutGate.Key

  private func evaluate(
    _ state: ShortcutGate.State, _ keyCode: UInt16, shift: Bool = false
  ) -> ShortcutGate.Outcome {
    ShortcutGate.evaluate(state, keyCode: keyCode, shift: shift)
  }

  // MARK: - No gate

  func testAnUnmodalStateFallsThroughToTheBindings() {
    XCTAssertEqual(evaluate(.init(), Key.enter), .continueDispatch)
  }

  // MARK: - Onboarding and the plugin dialog

  /// Every key reaches the setup form; only Escape is kept.
  func testOnboardingPassesKeysToTheFormBehindIt() {
    let outcome = evaluate(.init(needsInitialSetup: true), Key.enter)
    XCTAssertEqual(outcome.disposition, .notHandled)
  }

  func testOnboardingKeepsEscapeToCloseTheWindow() {
    XCTAssertEqual(
      evaluate(.init(needsInitialSetup: true), Key.escape),
      .init(actions: [.clearKeySequenceBuffer, .closeWindow], disposition: .handled))
  }

  /// A half-typed two-key sequence must not survive a modal and fire against
  /// whatever is on screen afterwards.
  func testAModalAlwaysClearsThePendingKeySequence() {
    for keyCode in [Key.enter, Key.escape, UInt16(1)] {
      XCTAssertTrue(
        evaluate(.init(needsInitialSetup: true), keyCode).actions
          .contains(.clearKeySequenceBuffer),
        "key \(keyCode) left a partial sequence behind")
    }
  }

  func testThePluginSelectionDialogBehavesLikeOnboarding() {
    XCTAssertEqual(
      evaluate(.init(showsPluginSelectionDialog: true), Key.escape),
      .init(actions: [.clearKeySequenceBuffer, .closeWindow], disposition: .handled))
    XCTAssertEqual(
      evaluate(.init(showsPluginSelectionDialog: true), Key.enter).disposition, .notHandled)
  }

  // MARK: - A running focus session

  func testEscapeEndsTheSessionFromEveryPhase() {
    for phase in [.running, .focusCompleted, .breakRunning, .breakCompleted]
      as [ShortcutGate.FocusPhase]
    {
      XCTAssertEqual(
        evaluate(.init(focusSessionPhase: phase), Key.escape),
        .init(actions: [.cancelFocusSession], disposition: .handled),
        "\(phase) did not cancel on Escape")
    }
  }

  func testEnterAdvancesThePomodoroFlow() {
    XCTAssertEqual(
      evaluate(.init(focusSessionPhase: .focusCompleted), Key.enter).actions, [.startBreak])
    XCTAssertEqual(
      evaluate(.init(focusSessionPhase: .breakRunning), Key.enter).actions, [.skipBreak])
    XCTAssertEqual(
      evaluate(.init(focusSessionPhase: .breakCompleted), Key.enter).actions,
      [.startAnotherSession])
  }

  /// Mid-session there is nothing to advance to. Enter must still be consumed —
  /// falling through to `addSibling` would create a task behind the overlay.
  func testEnterWhileRunningIsSwallowedRatherThanPassedOn() {
    let outcome = evaluate(.init(focusSessionPhase: .running), Key.enter)
    XCTAssertEqual(outcome, .handled)
  }

  func testEveryOtherKeyIsSwallowedDuringASession() {
    XCTAssertEqual(evaluate(.init(focusSessionPhase: .running), Key.upArrow), .handled)
  }

  /// The session must not swallow keys aimed at a text field, or the
  /// quick-entry box goes dead for the length of the session.
  func testASessionStepsAsideForTextEntry() {
    XCTAssertEqual(
      evaluate(.init(focusSessionPhase: .running, isTextEntryFocused: true), Key.upArrow),
      .continueDispatch)
  }

  // MARK: - The focus prompt

  func testTheFocusPromptStartsOnEnterAndDismissesOnEscape() {
    XCTAssertEqual(
      evaluate(.init(hasFocusPrompt: true), Key.enter).actions, [.startFocusSession])
    XCTAssertEqual(
      evaluate(.init(hasFocusPrompt: true), Key.escape).actions, [.dismissFocusPrompt])
  }

  func testUpAndRightAddToTheDurationDownAndLeftSubtract() {
    for keyCode in [Key.upArrow, Key.rightArrow] {
      XCTAssertEqual(
        evaluate(.init(hasFocusPrompt: true), keyCode).actions,
        [.adjustFocusDuration(minutes: 1)])
    }
    for keyCode in [Key.downArrow, Key.leftArrow] {
      XCTAssertEqual(
        evaluate(.init(hasFocusPrompt: true), keyCode).actions,
        [.adjustFocusDuration(minutes: -1)])
    }
  }

  func testShiftTakesTheDurationFiveAtATime() {
    XCTAssertEqual(
      evaluate(.init(hasFocusPrompt: true), Key.upArrow, shift: true).actions,
      [.adjustFocusDuration(minutes: 5)])
    XCTAssertEqual(
      evaluate(.init(hasFocusPrompt: true), Key.downArrow, shift: true).actions,
      [.adjustFocusDuration(minutes: -5)])
  }

  /// Enter and Escape still work while the duration field has focus — it is
  /// only the digits that have to reach it.
  func testTheFocusedDurationFieldStillGetsItsDigits() {
    let typing = ShortcutGate.State(hasFocusPrompt: true, isTextEntryFocused: true)
    XCTAssertEqual(evaluate(typing, UInt16(18)).disposition, .notHandled)
    XCTAssertEqual(evaluate(typing, Key.enter).actions, [.startFocusSession])
    XCTAssertEqual(evaluate(typing, Key.escape).actions, [.dismissFocusPrompt])
  }

  func testTheUnfocusedPromptSwallowsKeysItHasNoUseFor() {
    XCTAssertEqual(evaluate(.init(hasFocusPrompt: true), UInt16(18)), .handled)
  }

  // MARK: - Precedence

  /// The whole point of the ordering: onboarding outranks everything, so a
  /// session left running before setup cannot eat the setup form's keys.
  func testOnboardingOutranksAnActiveSession() {
    let outcome = evaluate(
      .init(needsInitialSetup: true, focusSessionPhase: .running, hasFocusPrompt: true),
      Key.escape)
    XCTAssertEqual(outcome.actions, [.clearKeySequenceBuffer, .closeWindow])
  }

  func testARunningSessionOutranksThePrompt() {
    XCTAssertEqual(
      evaluate(.init(focusSessionPhase: .running, hasFocusPrompt: true), Key.escape).actions,
      [.cancelFocusSession])
  }

  /// With text entry focused the session gate steps aside, and the prompt gate
  /// behind it is what answers.
  func testThePromptAnswersWhenTheSessionGateStepsAside() {
    XCTAssertEqual(
      evaluate(
        .init(focusSessionPhase: .running, hasFocusPrompt: true, isTextEntryFocused: true),
        Key.escape
      ).actions,
      [.dismissFocusPrompt])
  }
}
