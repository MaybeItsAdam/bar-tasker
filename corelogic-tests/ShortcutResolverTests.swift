import XCTest

@testable import PriorityCore

/// Where each binding is live, and in what order the router considers them.
///
/// `KeyboardShortcutRouter.handle` used to state each guard by hand alongside
/// its branch — `!isFocused`, `!rootScopeFocused`, `rootTaskView == .kanban` —
/// with nothing checking that two branches didn't claim the same key, or that
/// an early unguarded branch didn't shadow a later specific one. The table is
/// now the only statement of those guards, so these tests reach them.
final class ShortcutResolverTests: XCTestCase {

  // MARK: - The audits

  /// The one that found a live bug. A rule that an earlier rule for the same
  /// action covers everywhere can never fire: the general branch answers first
  /// and returns, so the specific one is dead code and the keyboard behaves
  /// differently from how it reads.
  ///
  /// This failed when written. `moveTaskUp` / `moveTaskDown` were dispatched
  /// unguarded *above* the Daily view's block, which binds the same gesture to
  /// reordering a daily — so in the Daily view, Cmd+↑/↓ silently reordered a
  /// task in the list underneath and the Daily handler was unreachable. The fix
  /// was to move the general pair below the Daily block.
  func testNoRuleIsShadowedByAnEarlierOne() {
    let shadowed = ShortcutResolver.shadowedRules().map {
      "\($0.action.rawValue) (rule \($0.shadowedIndex) is unreachable behind rule \($0.shadowedByIndex))"
    }
    XCTAssertEqual(shadowed, [], "these branches can never fire")
  }

  /// A collision is usually deliberate: in kanban the arrows are *meant* to
  /// move between columns rather than enter children, so `kanbanFocusLeft`
  /// claiming `left` ahead of `exitToParent` is the feature working. What is
  /// never intended is a binding that wins in no context at all — an advertised
  /// key that does nothing, anywhere.
  func testNoBindingIsCompletelyDead() {
    let dead = ShortcutResolver.deadBindings {
      $0.defaultBinding.split(separator: ",").map(String.init)
    }
    XCTAssertEqual(dead.map { "\($0.action.rawValue) \($0.token)" }, [])
  }

  /// `moveTaskUp` advertises `cmd+k` as an alias and `ARCHITECTURE_IMPROVEMENT_PLAN.md`
  /// recorded it as simply unreachable. It is not, quite: `openCommandPalette`
  /// claims `cmd+k` first but only while nothing has keyboard focus, so the
  /// alias survives in exactly the situation nobody would use it — mid-typing,
  /// where it reorders the task behind the field.
  ///
  /// Left as it is. Both halves are long-standing behaviour and changing either
  /// is a user-facing call; this pins what is actually true so the next reader
  /// is not misled the way the plan document was.
  func testCmdKReachesTheCommandPaletteExceptWhileTyping() {
    XCTAssertEqual(winner(of: "cmd+k", in: .init()), .openCommandPalette)
    XCTAssertEqual(
      winner(of: "cmd+k", in: .init(isTextEntryFocused: true)), .moveTaskUp)
  }

  /// Collisions themselves are recorded rather than forbidden, so a change that
  /// adds one is at least visible in the diff.
  func testKanbanDeliberatelyClaimsTheArrowsAheadOfTheGeneralBindings() {
    let collisions = ShortcutResolver.collisions(
      in: .init(rootTaskView: .kanban),
      bindings: { $0.defaultBinding.split(separator: ",").map(String.init) })

    XCTAssertTrue(
      collisions.contains { $0.winner == .kanbanFocusLeft && $0.loser == .exitToParent },
      "in kanban, ← moves between columns instead of leaving the scope")
  }

  /// The first available action claiming `token` — what the router would reach.
  private func winner(
    of token: String, in context: ShortcutContext
  ) -> ConfigurableShortcutAction? {
    ShortcutResolver.availableActions(in: context).first { action in
      action.defaultBinding.split(separator: ",").map(String.init).contains(token)
    }
  }

  // MARK: - Availability

  func testMostBindingsAreDeadWhileTyping() {
    let typing = ShortcutContext(isTextEntryFocused: true)
    XCTAssertFalse(ShortcutResolver.permits(.markDone, in: typing))
    XCTAssertFalse(ShortcutResolver.permits(.rootTabAll, in: typing))
  }

  /// Escape, Enter and Tab keep working in a text field — cancelling, adding
  /// and indenting are exactly what a field needs.
  func testTheAlwaysLiveBindingsSurviveTextEntry() {
    let typing = ShortcutContext(isTextEntryFocused: true)
    for action in [
      ConfigurableShortcutAction.closeOrCancel, .addSibling, .addChild, .indentTask,
      .unindentTask, .moveTaskUp, .moveTaskDown,
    ] {
      XCTAssertTrue(
        ShortcutResolver.permits(action, in: typing), "\(action.rawValue) should survive typing")
    }
  }

  func testKanbanBindingsAreDeadOutsideKanban() {
    XCTAssertTrue(
      ShortcutResolver.permits(.kanbanMoveLeft, in: .init(rootTaskView: .kanban)))
    XCTAssertFalse(
      ShortcutResolver.permits(.kanbanMoveLeft, in: .init(rootTaskView: .all)))
  }

  func testTheDailyViewOwnsItsOwnNavigation() {
    XCTAssertTrue(
      ShortcutResolver.permits(.nextTask, scope: .daily, in: .init(rootTaskView: .daily)))
    XCTAssertFalse(
      ShortcutResolver.permits(.nextTask, scope: .daily, in: .init(rootTaskView: .all)))
  }

  /// The distinction scopes exist for: asking by action alone would let the
  /// Daily rule answer for the general branch, and vice versa.
  func testAScopedRuleDoesNotAnswerForTheGeneralOne() {
    let list = ShortcutContext(rootTaskView: .all)
    XCTAssertTrue(ShortcutResolver.permits(.nextTask, in: list))
    XCTAssertFalse(ShortcutResolver.permits(.nextTask, scope: .daily, in: list))
  }

  func testTheRootScopeRowClaimsArrowsOnlyWhileItHasFocus() {
    XCTAssertTrue(
      ShortcutResolver.permits(
        .enterChildren, scope: .rootScopeRow, in: .init(isRootScopeFocused: true)))
    XCTAssertFalse(
      ShortcutResolver.permits(
        .enterChildren, scope: .rootScopeRow, in: .init(isRootScopeFocused: false)))
  }

  /// Ctrl+← switches root tabs. If the root scope row claimed modified arrows
  /// too, it would swallow that.
  func testTheRootScopeRowIgnoresModifiedArrows() {
    XCTAssertFalse(
      ShortcutResolver.permits(
        .enterChildren, scope: .rootScopeRow,
        in: .init(isRootScopeFocused: true, hasCommandModifiers: true)))
  }

  func testRootTabCyclingNeedsTheScopeSectionOnScreen() {
    XCTAssertTrue(
      ShortcutResolver.permits(.rootCycleTabNext, in: .init(showsRootScopeSection: true)))
    XCTAssertFalse(
      ShortcutResolver.permits(.rootCycleTabNext, in: .init(showsRootScopeSection: false)))
  }

  func testRootFiltersNeedTheFilterRowOnScreen() {
    XCTAssertTrue(
      ShortcutResolver.permits(.rootFilter1, in: .init(showsRootFilterControls: true)))
    XCTAssertFalse(
      ShortcutResolver.permits(.rootFilter1, in: .init(showsRootFilterControls: false)))
  }

  func testPriorityBindingsAreDeadOnTheRootScopeRow() {
    XCTAssertFalse(
      ShortcutResolver.permits(.setPriorityRank, in: .init(isRootScopeFocused: true)))
    XCTAssertTrue(
      ShortcutResolver.permits(.setPriorityRank, in: .init(isRootScopeFocused: false)))
  }

  // MARK: - Ordering

  func testAvailableActionsFollowTheDispatchOrder() {
    let actions = ShortcutResolver.availableActions(in: .init(rootTaskView: .kanban))
    let palette = actions.firstIndex(of: .openCommandPalette)
    let kanbanMove = actions.firstIndex(of: .kanbanMoveLeft)
    XCTAssertNotNil(palette)
    XCTAssertNotNil(kanbanMove)
    XCTAssertLessThan(palette!, kanbanMove!, "the palette is checked before anything view-specific")
  }

  func testAnActionAppearsOnceEvenWhenItHasSeveralRules() {
    let actions = ShortcutResolver.availableActions(in: .init(rootTaskView: .daily))
    XCTAssertEqual(actions.filter { $0 == .nextTask }.count, 1)
  }
}
