import Foundation

/// The keyboard reference, derived from the bindings themselves.
///
/// It replaces a hand-written table in the settings pane, which had drifted
/// badly enough to be worse than nothing: it listed `u` as undo (undo moved to
/// `Cmd+Z` when `u` became the Daily tab), `t` as the timer (`t` is the Kanban
/// tab; the timer is `p`), and `m` as a filter slot (it is `,`). It also
/// described *default* bindings as though they were facts, so anyone who had
/// customised a shortcut was reading someone else's keyboard.
///
/// Everything here comes from `ConfigurableShortcutAction` and from a caller-
/// supplied lookup of the binding actually in force, so neither kind of drift
/// is expressible. `ShortcutReferenceTests` pins the rest: every action appears
/// exactly once, and no section is empty.
public enum ShortcutReference {

  public struct Entry: Identifiable, Equatable, Sendable {
    public let action: ConfigurableShortcutAction
    /// Display-ready alternatives — `["⌘↑", "⌘J"]` — in the order the binding
    /// lists them.
    public let keys: [String]
    public let title: String
    /// Context the title alone doesn't carry: a different meaning in one view,
    /// or a Checkvist convention worth naming.
    public let note: String?

    public var id: String { action.rawValue }

    public init(
      action: ConfigurableShortcutAction,
      keys: [String],
      title: String,
      note: String?
    ) {
      self.action = action
      self.keys = keys
      self.title = title
      self.note = note
    }
  }

  public struct Section: Identifiable, Equatable, Sendable {
    public let title: String
    public let entries: [Entry]

    public var id: String { title }

    public init(title: String, entries: [Entry]) {
      self.title = title
      self.entries = entries
    }
  }

  /// Section order. Matches the settings pane's, which is roughly
  /// most-pressed-first.
  public static let sectionOrder = [
    "Navigation", "Task Actions", "Entry & Commands", "Integrations & Timer",
  ]

  /// - Parameter binding: the binding in force for an action — pass
  ///   `PreferencesManager.shortcutBinding(for:)`, so a customised shortcut is
  ///   what the reference shows. Defaults to the shipped binding, which is what
  ///   a test or a headless caller wants.
  public static func sections(
    binding: (ConfigurableShortcutAction) -> String = { $0.defaultBinding }
  ) -> [Section] {
    let grouped = Dictionary(grouping: ConfigurableShortcutAction.allCases, by: \.category)
    return sectionOrder.compactMap { title in
      guard let actions = grouped[title], !actions.isEmpty else { return nil }
      return Section(
        title: title,
        entries: actions.map { action in
          Entry(
            action: action,
            keys: displayKeys(forBinding: binding(action)),
            title: action.title,
            note: notes[action]
          )
        }
      )
    }
  }

  /// Splits a binding on its commas and renders each alternative.
  public static func displayKeys(forBinding binding: String) -> [String] {
    binding
      .split(separator: ",")
      .map { display(token: String($0).trimmingCharacters(in: .whitespacesAndNewlines)) }
      .filter { !$0.isEmpty }
  }

  /// One binding token as it should be read on a Mac keyboard.
  ///
  /// Two-key sequences are rendered spaced — `d d`, not `dd` — because the
  /// unspaced form reads as one chord and is the reason people press `d` and
  /// wonder why nothing happened.
  public static func display(token rawToken: String) -> String {
    let token = rawToken.lowercased()
    guard !token.isEmpty else { return "" }

    if !token.contains("+"), token.count > 1, let named = keyName[token] {
      return named
    }
    // A modifier-free multi-character token is a sequence, not a key name.
    if !token.contains("+"), token.count > 1 {
      return token.map(String.init).map { $0.uppercased() }.joined(separator: " ")
    }

    let parts = token.split(separator: "+").map(String.init)
    guard let base = parts.last else { return "" }
    let symbols = parts.dropLast().map { modifierSymbol[$0] ?? $0 }.joined()
    return symbols + (keyName[base] ?? base.uppercased())
  }

  /// In the order macOS writes them, which is not the order the binding format
  /// stores them in.
  private static let modifierSymbol: [String: String] = [
    "ctrl": "⌃", "option": "⌥", "shift": "⇧", "cmd": "⌘",
  ]

  private static let keyName: [String: String] = [
    "up": "↑", "down": "↓", "left": "←", "right": "→",
    "enter": "↩", "tab": "⇥", "escape": "⎋", "delete": "⌫",
    "space": "Space", "comma": ",", "f2": "F2",
  ]

  /// Only where the action's own title leaves something material unsaid.
  /// Deliberately sparse — a note on every row is a note on none.
  private static let notes: [ConfigurableShortcutAction: String] = [
    .nextTask: "In the Daily view, moves through the checklist",
    .previousTask: "In the Daily view, moves through the checklist",
    .markDone: "Ticks a daily in the Daily view",
    .addSibling: "Adds a daily in the Daily view, and stays open",
    .addChild: "Tab indents instead, as in Checkvist",
    .indentTask: "Tab, matching Shift+Tab for unindent",
    .addSiblingAbove: "Checkvist's Alt+Enter",
    .duplicateTask: "Content only — no due date, tags or subtasks",
    .deleteTask: "In the Daily view, deletes the daily — restorable in Preferences",
    .editTaskAtEnd: "Renames a daily in the Daily view",
    .editTaskAtStart: "Renames a daily in the Daily view",
    .moveTaskUp: "Reorders dailies in the Daily view",
    .moveTaskDown: "Reorders dailies in the Daily view",
    .clearPriority: "0 is Checkvist's spelling",
    .zoomIntoTask: "Checkvist calls this hoisting",
    .kanbanFocusMode: "Works from any view",
    .setPriorityRank: "Within the parent, not the whole list",
    .setAbsolutePriorityRank: "Across the whole list",
    .showShortcutReference: "This screen",
  ]
}
