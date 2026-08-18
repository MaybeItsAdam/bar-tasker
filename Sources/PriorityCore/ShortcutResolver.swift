import Foundation

/// Everything `KeyboardShortcutRouter` gates its bindings on, as values.
public struct ShortcutContext: Equatable {
  public var rootTaskView: RootTaskView
  /// A native text field or the quick-entry box has the keyboard.
  public var isTextEntryFocused: Bool
  /// The root scope row above the list has focus, so arrows move within it.
  public var isRootScopeFocused: Bool
  public var showsRootScopeSection: Bool
  public var showsRootFilterControls: Bool
  /// Ctrl, Cmd or Option is down. A few bindings are only live unmodified.
  public var hasCommandModifiers: Bool

  public init(
    rootTaskView: RootTaskView = .all,
    isTextEntryFocused: Bool = false,
    isRootScopeFocused: Bool = false,
    showsRootScopeSection: Bool = true,
    showsRootFilterControls: Bool = false,
    hasCommandModifiers: Bool = false
  ) {
    self.rootTaskView = rootTaskView
    self.isTextEntryFocused = isTextEntryFocused
    self.isRootScopeFocused = isRootScopeFocused
    self.showsRootScopeSection = showsRootScopeSection
    self.showsRootFilterControls = showsRootFilterControls
    self.hasCommandModifiers = hasCommandModifiers
  }
}

/// Where each binding is live, and in what order the router considers them.
///
/// `KeyboardShortcutRouter.handle` is a ~1,000-line function whose 60 binding
/// branches each carry their own hand-written guard — `!isFocused`,
/// `!rootScopeFocused`, `rootTaskView == .kanban`, and combinations. The guards
/// were the untested part: nothing stopped two branches claiming the same key,
/// or an early unguarded branch shadowing a later specific one.
///
/// This table is the single source of truth for those guards. The router asks
/// it rather than re-stating them, so the two cannot drift, and the order here
/// mirrors the order there — which is what makes shadowing detectable.
public enum ShortcutResolver {

  /// A guard, as data. `nil` means "does not care"; the defaults describe the
  /// common case of a binding that is live whenever nothing is being typed.
  public struct Availability: Equatable, Sendable {
    public var textEntryFocused: Bool? = false
    public var rootScopeFocused: Bool?
    public var views: Set<RootTaskView>?
    public var requiresRootScopeSection = false
    public var requiresRootFilterControls = false
    /// Live only unmodified — the root scope row's arrows, which must not
    /// swallow Ctrl+← used for switching tabs.
    public var requiresNoCommandModifiers = false

    public init(
      textEntryFocused: Bool? = false,
      rootScopeFocused: Bool? = nil,
      views: Set<RootTaskView>? = nil,
      requiresRootScopeSection: Bool = false,
      requiresRootFilterControls: Bool = false,
      requiresNoCommandModifiers: Bool = false
    ) {
      self.textEntryFocused = textEntryFocused
      self.rootScopeFocused = rootScopeFocused
      self.views = views
      self.requiresRootScopeSection = requiresRootScopeSection
      self.requiresRootFilterControls = requiresRootFilterControls
      self.requiresNoCommandModifiers = requiresNoCommandModifiers
    }

    /// Available in every context. Used by the bindings the router checks
    /// before any guard, such as reordering.
    public static let always = Availability(textEntryFocused: nil)

    public func permits(_ context: ShortcutContext) -> Bool {
      if let textEntryFocused, textEntryFocused != context.isTextEntryFocused { return false }
      if let rootScopeFocused, rootScopeFocused != context.isRootScopeFocused { return false }
      if let views, !views.contains(context.rootTaskView) { return false }
      if requiresRootScopeSection, !context.showsRootScopeSection { return false }
      if requiresRootFilterControls, !context.showsRootFilterControls { return false }
      if requiresNoCommandModifiers, context.hasCommandModifiers { return false }
      return true
    }
  }

  /// Which of an action's rules is meant, for the handful that mean different
  /// things in different places. `.general` is the ordinary binding; the others
  /// name the branch that claims the same key first.
  public enum Scope: Equatable, Sendable {
    case general
    /// The root scope row above the list, where the arrows move within the row.
    case rootScopeRow
    /// The Daily view, which owns its own navigation and reordering.
    case daily
  }

  public struct Rule: Equatable, Sendable {
    public let action: ConfigurableShortcutAction
    public let availability: Availability
    public let scope: Scope

    public init(
      _ action: ConfigurableShortcutAction,
      _ availability: Availability = Availability(),
      scope: Scope = .general
    ) {
      self.action = action
      self.availability = availability
      self.scope = scope
    }
  }

  private static let unfocused = Availability()
  private static let inList = Availability(rootScopeFocused: false)
  private static let inKanban = Availability(views: [.kanban])
  private static let inKanbanList = Availability(rootScopeFocused: false, views: [.kanban])
  private static let inDaily = Availability(rootScopeFocused: false, views: [.daily])
  private static let onRootScope = Availability(
    rootScopeFocused: true, requiresNoCommandModifiers: true)
  private static let withRootScope = Availability(requiresRootScopeSection: true)
  private static let withFilterControls = Availability(requiresRootFilterControls: true)

  /// In the router's dispatch order. An action may appear more than once when
  /// it means different things in different views.
  public static let table: [Rule] = [
    Rule(.openCommandPalette),

    Rule(.rootCycleTabPrevious, withRootScope),
    Rule(.rootCycleTabNext, withRootScope),
    Rule(.rootCycleFilterPrevious, withRootScope),
    Rule(.rootCycleFilterNext, withRootScope),

    Rule(.kanbanMoveLeft, inKanban),
    Rule(.kanbanMoveRight, inKanban),
    Rule(.kanbanShowInAll, inKanban),

    Rule(.kanbanEnterTaskChildren, inList),
    Rule(.kanbanFocusMode, inList),
    Rule(.kanbanExitToTaskParent, inList),

    Rule(.openInObsidian),
    Rule(.openInObsidianNewWindow),

    Rule(.nextTask, inDaily, scope: .daily),
    Rule(.previousTask, inDaily, scope: .daily),
    Rule(.addSibling, inDaily, scope: .daily),
    Rule(.editTaskAtEnd, inDaily, scope: .daily),
    Rule(.editTaskAtStart, inDaily, scope: .daily),
    Rule(.deleteTask, inDaily, scope: .daily),
    Rule(.moveTaskUp, inDaily, scope: .daily),
    Rule(.moveTaskDown, inDaily, scope: .daily),

    // After the Daily rules, deliberately: these are live everywhere, so
    // ordering them first made the Daily pair above unreachable.
    Rule(.moveTaskDown, .always),
    Rule(.moveTaskUp, .always),

    Rule(.nextTask, unfocused),
    Rule(.previousTask, unfocused),

    Rule(.enterChildren, onRootScope, scope: .rootScopeRow),
    Rule(.exitToParent, onRootScope, scope: .rootScopeRow),

    Rule(.kanbanFocusLeft, inKanbanList),
    Rule(.kanbanFocusRight, inKanbanList),

    Rule(.zoomIntoTask, inList),
    Rule(.zoomOutOfTask, inList),

    Rule(.enterChildren, .always),
    Rule(.exitToParent, .always),

    Rule(.invalidateTask, inList),
    Rule(.markDone, inList),

    Rule(.addSibling, .always),
    Rule(.addSiblingAbove, .always),
    Rule(.addChild, .always),
    Rule(.unindentTask, .always),
    Rule(.indentTask, .always),
    Rule(.closeOrCancel, .always),

    Rule(.editTaskAtEnd),
    Rule(.copyTask),
    Rule(.duplicateTask),
    Rule(.deleteTask),
    // Live in every view, and — unlike everything around it — deliberately not
    // while typing: `?` is a character someone is entitled to put in a task.
    Rule(.showShortcutReference),

    Rule(.rootTabAll),
    Rule(.rootTabDue),
    Rule(.rootTabTags),
    Rule(.rootTabPriority),
    Rule(.rootTabKanban),
    Rule(.rootTabMatrix),
    Rule(.rootTabDaily),

    Rule(.rootFilter1, withFilterControls),
    Rule(.rootFilter2, withFilterControls),
    Rule(.rootFilter3, withFilterControls),
    Rule(.rootFilter4, withFilterControls),
    Rule(.rootFilter5, withFilterControls),
    Rule(.rootFilter6, withFilterControls),
    Rule(.rootFilter7, withFilterControls),

    Rule(.toggleTimer),
    Rule(.toggleTimerPause),
    Rule(.undo),
    Rule(.toggleHideFuture),
    Rule(.quickListSwitch),
    Rule(.quickAdd),
    Rule(.focusSearch),

    Rule(.clearAbsolutePriority, inList),
    Rule(.clearPriority, inList),
    Rule(.pushPriorityBack, inList),
    Rule(.setPriorityRank, inList),
    Rule(.setAbsolutePriorityRank, inList),

    Rule(.editTaskAtStart),
  ]

  /// Whether the router's branch for `action` in `scope` should fire here.
  ///
  /// The scope matters for the seven actions that appear in the table twice:
  /// asking only by action would let the Daily view's `nextTask` rule answer
  /// for the general one, and the root scope row's `enterChildren` fire in the
  /// list.
  public static func permits(
    _ action: ConfigurableShortcutAction,
    scope: Scope = .general,
    in context: ShortcutContext
  ) -> Bool {
    table.contains {
      $0.action == action && $0.scope == scope && $0.availability.permits(context)
    }
  }

  /// Whether Enter or Escape should dismiss the root scope row and hand focus
  /// back to the list.
  ///
  /// These two are not `ConfigurableShortcutAction`s — the row is a transient
  /// focus state rather than something you navigate to, so its way out is
  /// fixed. The rule lives here because in the router it was a bare
  /// `event.keyCode == 36 || event.keyCode == 53` sitting inside an
  /// `if rootScopeFocused` block, and moving that block's other two branches
  /// into this table left the key test behind *without* its guard. Every
  /// unmodified Enter in the list then dismissed a row that had no focus and
  /// returned handled, so Enter stopped adding a task at all.
  public static func dismissesRootScopeRow(keyCode: UInt16, in context: ShortcutContext) -> Bool {
    guard onRootScope.permits(context) else { return false }
    return keyCode == ShortcutGate.Key.enter || keyCode == ShortcutGate.Key.escape
  }

  /// Every action live in a context, in dispatch order, with duplicates
  /// collapsed to their first occurrence.
  public static func availableActions(in context: ShortcutContext) -> [ConfigurableShortcutAction] {
    var seen = Set<ConfigurableShortcutAction>()
    return table.compactMap { rule in
      guard rule.availability.permits(context), seen.insert(rule.action).inserted else {
        return nil
      }
      return rule.action
    }
  }

  // MARK: - Auditing the table

  /// Every context the guards can distinguish. Small and finite, so the audits
  /// below enumerate it rather than reasoning about implication.
  public static var allContexts: [ShortcutContext] {
    var contexts: [ShortcutContext] = []
    for view in RootTaskView.allCases {
      for textEntry in [false, true] {
        for rootScope in [false, true] {
          for section in [false, true] {
            for filters in [false, true] {
              for modifiers in [false, true] {
                contexts.append(
                  ShortcutContext(
                    rootTaskView: view, isTextEntryFocused: textEntry,
                    isRootScopeFocused: rootScope, showsRootScopeSection: section,
                    showsRootFilterControls: filters, hasCommandModifiers: modifiers))
              }
            }
          }
        }
      }
    }
    return contexts
  }

  /// A rule that can never fire, because an earlier rule for the same action is
  /// live everywhere it is. The specific rule is dead code and the general one
  /// silently answers in its place — which is a keyboard behaving differently
  /// from how it reads.
  public struct ShadowedRule: Equatable {
    public let action: ConfigurableShortcutAction
    public let shadowedIndex: Int
    public let shadowedByIndex: Int

    public init(
      action: ConfigurableShortcutAction,
      shadowedIndex: Int,
      shadowedByIndex: Int
    ) {
    self.action = action
    self.shadowedIndex = shadowedIndex
    self.shadowedByIndex = shadowedByIndex
    }
  }

  public static func shadowedRules() -> [ShadowedRule] {
    let contexts = allContexts
    var shadowed: [ShadowedRule] = []
    for (index, rule) in table.enumerated() {
      let live = contexts.filter { rule.availability.permits($0) }
      guard !live.isEmpty else { continue }
      for (earlierIndex, earlier) in table.prefix(index).enumerated()
      where earlier.action == rule.action && live.allSatisfy(earlier.availability.permits) {
        shadowed.append(
          ShadowedRule(
            action: rule.action, shadowedIndex: index, shadowedByIndex: earlierIndex))
        break
      }
    }
    return shadowed
  }

  /// Two actions live in the same context that resolve to the same key. The
  /// earlier one wins and the later is unreachable there.
  public struct BindingCollision: Equatable {
    public let token: String
    public let winner: ConfigurableShortcutAction
    public let loser: ConfigurableShortcutAction

    public init(
      token: String,
      winner: ConfigurableShortcutAction,
      loser: ConfigurableShortcutAction
    ) {
    self.token = token
    self.winner = winner
    self.loser = loser
    }
  }

  /// A binding that never wins anywhere. Unlike a collision — which is often
  /// deliberate, since a view-specific branch is *meant* to claim the arrows
  /// ahead of the general one — this is an advertised key that no context lets
  /// through, so it does nothing at all.
  public struct DeadBinding: Equatable, Hashable, Comparable {
    public let action: ConfigurableShortcutAction
    public let token: String

    public static func < (lhs: Self, rhs: Self) -> Bool {
      (lhs.action.rawValue, lhs.token) < (rhs.action.rawValue, rhs.token)
    }
  }

  public static func deadBindings(
    _ bindings: (ConfigurableShortcutAction) -> [String]
  ) -> [DeadBinding] {
    var winners = Set<DeadBinding>()
    for context in allContexts {
      var claimed = Set<String>()
      for action in availableActions(in: context) {
        for token in bindings(action) where !token.isEmpty {
          guard claimed.insert(token).inserted else { continue }
          winners.insert(DeadBinding(action: action, token: token))
        }
      }
    }
    var dead: [DeadBinding] = []
    for action in ConfigurableShortcutAction.allCases where !action.isTwoKeySequence {
      for token in bindings(action) where !token.isEmpty {
        let candidate = DeadBinding(action: action, token: token)
        if !winners.contains(candidate) { dead.append(candidate) }
      }
    }
    return dead.sorted()
  }

  /// `bindings` yields the tokens configured for an action, so this audits the
  /// user's real bindings rather than only the shipped defaults.
  public static func collisions(
    in context: ShortcutContext,
    bindings: (ConfigurableShortcutAction) -> [String]
  ) -> [BindingCollision] {
    var claimed: [String: ConfigurableShortcutAction] = [:]
    var collisions: [BindingCollision] = []
    for action in availableActions(in: context) {
      for token in bindings(action) where !token.isEmpty {
        if let winner = claimed[token], winner != action {
          collisions.append(BindingCollision(token: token, winner: winner, loser: action))
        } else {
          claimed[token] = action
        }
      }
    }
    return collisions
  }
}
