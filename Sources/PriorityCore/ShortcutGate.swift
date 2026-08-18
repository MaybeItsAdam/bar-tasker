import Foundation

/// The modal gates at the top of `KeyboardShortcutRouter.handle`.
///
/// Before any binding is consulted, five states can claim a key press outright:
/// onboarding, the plugin-selection dialog, a running focus session, the focus
/// prompt, and — later in the pass — the delete confirmation. Each decides
/// whether the key is consumed, passed to AppKit, or ignored, and they are
/// tried in a fixed order.
///
/// That order is the rule, and it was expressed as five early returns inside a
/// ~1,000-line function taking `NSEvent` and `AppCoordinator`, so none of it
/// could be tested. Getting it wrong is not subtle: the wrong precedence makes
/// the keyboard dead in a keyboard-first app.
public enum ShortcutGate {

  /// The raw key codes these gates care about. AppKit gives no names for them
  /// and the router had them as bare integers with trailing comments.
  public enum Key {
    public static let escape: UInt16 = 53
    public static let enter: UInt16 = 36
    public static let leftArrow: UInt16 = 123
    public static let rightArrow: UInt16 = 124
    public static let downArrow: UInt16 = 125
    public static let upArrow: UInt16 = 126
  }

  /// The phases a focus session moves through. Mirrors the app's
  /// `FocusSessionManager.phase` without depending on it.
  public enum FocusPhase: Equatable, Sendable {
    case running
    case focusCompleted
    case breakRunning
    case breakCompleted
  }

  /// Everything the gates read, gathered so the decision is a function of
  /// values rather than of six manager objects.
  public struct State: Equatable, Sendable {
    public var needsInitialSetup: Bool
    public var showsPluginSelectionDialog: Bool
    public var focusSessionPhase: FocusPhase?
    public var hasFocusPrompt: Bool
    /// A native text field or the quick-entry box has the keyboard. Several
    /// gates step aside for it so typing still works.
    public var isTextEntryFocused: Bool

    public init(
      needsInitialSetup: Bool = false,
      showsPluginSelectionDialog: Bool = false,
      focusSessionPhase: FocusPhase? = nil,
      hasFocusPrompt: Bool = false,
      isTextEntryFocused: Bool = false
    ) {
      self.needsInitialSetup = needsInitialSetup
      self.showsPluginSelectionDialog = showsPluginSelectionDialog
      self.focusSessionPhase = focusSessionPhase
      self.hasFocusPrompt = hasFocusPrompt
      self.isTextEntryFocused = isTextEntryFocused
    }
  }

  public enum Action: Equatable, Sendable {
    case clearKeySequenceBuffer
    case closeWindow
    case cancelFocusSession
    case startBreak
    case skipBreak
    case startAnotherSession
    case dismissFocusPrompt
    case startFocusSession
    case adjustFocusDuration(minutes: Int)
  }

  public enum Disposition: Equatable, Sendable {
    /// No gate applies; carry on to the bindings.
    case continueDispatch
    /// Consumed. The event goes no further.
    case handled
    /// Deliberately *not* consumed — hand it to AppKit so a text field or the
    /// setup form can have it.
    case notHandled
  }

  public struct Outcome: Equatable, Sendable {
    public var actions: [Action] = []
    public var disposition: Disposition

    public static let continueDispatch = Outcome(disposition: .continueDispatch)
    public static let handled = Outcome(disposition: .handled)
    public static let notHandled = Outcome(disposition: .notHandled)
  }

  /// Tried in order. The order is the contract.
  public static func evaluate(_ state: State, keyCode: UInt16, shift: Bool) -> Outcome {
    // Onboarding, then the plugin-selection dialog. Both let every key through
    // to the form behind them and keep only Escape for themselves.
    //
    // Only the plugin-selection bar does this. Its rows are focusable switches
    // and Space is the default `markDone` binding, so passing keys through
    // would mark a task done instead of flipping the switch under the cursor.
    // The other bars are single-action notices with nothing to focus, and
    // `.checkvist` in particular stays up until dismissed — gating there left
    // the list keyboard-dead for as long as someone put off connecting.
    if state.needsInitialSetup || state.showsPluginSelectionDialog {
      // The buffer is cleared either way: a half-typed two-key sequence must
      // not survive a modal and fire against whatever is showing afterwards.
      guard keyCode == Key.escape else {
        return Outcome(actions: [.clearKeySequenceBuffer], disposition: .notHandled)
      }
      return Outcome(actions: [.clearKeySequenceBuffer, .closeWindow], disposition: .handled)
    }

    // A running session owns the keyboard, but only while nothing is being
    // typed into — otherwise the quick-entry box goes dead mid-session.
    if let phase = state.focusSessionPhase, !state.isTextEntryFocused {
      return focusSessionOutcome(phase: phase, keyCode: keyCode)
    }

    if state.hasFocusPrompt {
      return focusPromptOutcome(state, keyCode: keyCode, shift: shift)
    }

    return .continueDispatch
  }

  private static func focusSessionOutcome(phase: FocusPhase, keyCode: UInt16) -> Outcome {
    // Escape always ends the whole session, from any phase.
    if keyCode == Key.escape {
      return Outcome(actions: [.cancelFocusSession], disposition: .handled)
    }
    if keyCode == Key.enter {
      switch phase {
      // Nothing to advance to mid-session; Enter is swallowed rather than
      // falling through to `addSibling` and creating a task behind the overlay.
      case .running: return .handled
      case .focusCompleted: return Outcome(actions: [.startBreak], disposition: .handled)
      case .breakRunning: return Outcome(actions: [.skipBreak], disposition: .handled)
      case .breakCompleted:
        return Outcome(actions: [.startAnotherSession], disposition: .handled)
      }
    }
    // Every other key is swallowed so it cannot mutate the list underneath.
    return .handled
  }

  private static func focusPromptOutcome(
    _ state: State, keyCode: UInt16, shift: Bool
  ) -> Outcome {
    if keyCode == Key.escape {
      return Outcome(actions: [.dismissFocusPrompt], disposition: .handled)
    }
    if keyCode == Key.enter {
      return Outcome(actions: [.startFocusSession], disposition: .handled)
    }
    // With the duration field focused, digits have to reach it.
    guard !state.isTextEntryFocused else { return .notHandled }

    // Up / Right add, Down / Left subtract. Shift takes five at a time.
    let step = shift ? 5 : 1
    switch keyCode {
    case Key.upArrow, Key.rightArrow:
      return Outcome(actions: [.adjustFocusDuration(minutes: step)], disposition: .handled)
    case Key.downArrow, Key.leftArrow:
      return Outcome(actions: [.adjustFocusDuration(minutes: -step)], disposition: .handled)
    default:
      return .handled
    }
  }
}
