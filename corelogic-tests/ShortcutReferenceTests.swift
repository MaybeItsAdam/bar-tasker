import XCTest

@testable import PriorityCore

/// The reference this replaces was a hand-written list of 34 rows that had
/// drifted three entries out of date without anything noticing — it named `u`
/// as undo, `t` as the timer and `m` as a filter slot, all of which had moved
/// underneath it. These are the tests that make that class of drift impossible
/// rather than merely fixed.
final class ShortcutReferenceTests: XCTestCase {

  // MARK: - Coverage

  /// The one that matters. A binding nobody documented is a binding nobody
  /// finds, and the old list's failure mode was exactly this: actions were
  /// added over two years and the reference was not.
  func testEveryActionAppearsExactlyOnce() {
    let listed = ShortcutReference.sections().flatMap(\.entries).map(\.action)

    XCTAssertEqual(
      Set(listed), Set(ConfigurableShortcutAction.allCases),
      "every configurable action has to be reachable from the reference")
    XCTAssertEqual(listed.count, Set(listed).count, "no action is listed twice")
  }

  func testNoSectionIsEmpty() {
    for section in ShortcutReference.sections() {
      XCTAssertFalse(section.entries.isEmpty, "\(section.title) is an empty heading")
    }
  }

  func testSectionsComeBackInTheDeclaredOrder() {
    let titles = ShortcutReference.sections().map(\.title)
    XCTAssertEqual(titles, ShortcutReference.sectionOrder.filter(titles.contains))
  }

  /// Every action has at least one key, or the row renders as a description of
  /// something you cannot do.
  func testEveryEntryHasAtLeastOneKey() {
    for entry in ShortcutReference.sections().flatMap(\.entries) {
      XCTAssertFalse(
        entry.keys.isEmpty,
        "\(entry.action.rawValue) has binding \"\(entry.action.defaultBinding)\" and renders no keys")
    }
  }

  // MARK: - Reflecting customisation

  /// The other half of why the static list was wrong: it showed the shipped
  /// defaults to someone who had rebound them.
  func testTheReferenceShowsCustomBindingsRatherThanDefaults() {
    let sections = ShortcutReference.sections { action in
      action == .markDone ? "cmd+shift+x" : action.defaultBinding
    }
    let markDone = sections.flatMap(\.entries).first { $0.action == .markDone }

    XCTAssertEqual(markDone?.keys, ["⌘⇧X"])
  }

  // MARK: - Rendering

  func testModifiersRenderInTheOrderMacOSWritesThem() {
    // Stored ctrl, cmd, option, shift — displayed control, option, shift,
    // command. The binding format and the convention disagree, deliberately.
    XCTAssertEqual(ShortcutReference.display(token: "cmd+up"), "⌘↑")
    XCTAssertEqual(ShortcutReference.display(token: "shift+enter"), "⇧↩")
    XCTAssertEqual(ShortcutReference.display(token: "option+enter"), "⌥↩")
    XCTAssertEqual(ShortcutReference.display(token: "ctrl+left"), "⌃←")
  }

  func testNamedKeysUseTheirGlyph() {
    XCTAssertEqual(ShortcutReference.display(token: "escape"), "⎋")
    XCTAssertEqual(ShortcutReference.display(token: "tab"), "⇥")
    XCTAssertEqual(ShortcutReference.display(token: "delete"), "⌫")
    XCTAssertEqual(ShortcutReference.display(token: "space"), "Space")
    // Stored as a word because the binding format is comma-separated and has no
    // escape — see `ShortcutKeyToken.nameByKeyCode`.
    XCTAssertEqual(ShortcutReference.display(token: "comma"), ",")
  }

  /// Spaced, so `dd` reads as two presses. Unspaced it looks like a chord, and
  /// somebody presses `d` and concludes the shortcut is broken.
  func testTwoKeySequencesRenderAsTwoPresses() {
    XCTAssertEqual(ShortcutReference.display(token: "dd"), "D D")
    XCTAssertEqual(ShortcutReference.display(token: "gc"), "G C")
  }

  func testAlternativesAreSplitOnCommas() {
    XCTAssertEqual(ShortcutReference.displayKeys(forBinding: "down,j"), ["↓", "J"])
    XCTAssertEqual(ShortcutReference.displayKeys(forBinding: "cmd+up,cmd+k"), ["⌘↑", "⌘K"])
  }

  // MARK: - The Checkvist alignment, pinned

  /// Tab indents, as it does in Checkvist, and as this app's own `Shift+Tab`
  /// already implied. It used to add a child, which left unindent with a
  /// counterpart that indented nothing.
  func testTabIndentsRatherThanAddingAChild() {
    XCTAssertTrue(ConfigurableShortcutAction.indentTask.defaultBinding.contains("tab"))
    XCTAssertFalse(
      ConfigurableShortcutAction.addChild.defaultBinding.split(separator: ",").contains("tab"),
      "Tab cannot mean two things at once")
  }

  func testShiftTabStillUnindents() {
    XCTAssertTrue(ConfigurableShortcutAction.unindentTask.defaultBinding.contains("shift+tab"))
  }

  /// `0` is Checkvist's "remove priority colours". `-` predates it here and is
  /// kept: a binding already in someone's fingers is not worth taking away to
  /// make a table tidier.
  func testClearPriorityAnswersToBothSpellings() {
    let keys = ConfigurableShortcutAction.clearPriority.defaultBinding.split(separator: ",")
    XCTAssertTrue(keys.contains("0"))
    XCTAssertTrue(keys.contains("-"))
  }

  func testTheGesturesCheckvistUsersAlreadyKnowAreUnchanged() {
    // These are the ones muscle memory is built on. If a refactor moves any of
    // them, that should be a decision rather than a side effect.
    let expected: [ConfigurableShortcutAction: String] = [
      .markDone: "space",
      .invalidateTask: "shift+space",
      .addSibling: "enter",
      .addChild: "shift+enter",
      .unindentTask: "cmd+left,shift+tab",
      .zoomIntoTask: "shift+right",
      .zoomOutOfTask: "shift+left",
      .moveTaskUp: "cmd+up,cmd+k",
      .moveTaskDown: "cmd+down,cmd+j",
      .deleteTask: "delete",
      .sequenceDue: "dd",
      .sequenceRepeat: "dr",
      .sequenceOpenLink: "gg",
      .sequenceToggleContext: "sc",
      .focusSearch: "/",
    ]
    for (action, binding) in expected {
      XCTAssertEqual(action.defaultBinding, binding, "\(action.rawValue) moved")
    }
  }

  /// Checkvist opens its shortcut help on `?`. So does this — and the token has
  /// to be one `ShortcutKeyToken` can actually produce, or the binding silently
  /// never fires.
  func testTheReferenceOpensOnAKeyTheTokeniserCanProduce() {
    let token = ShortcutKeyToken.make(
      keyCode: 44, charactersIgnoringModifiers: "/", shift: true, ctrl: false, cmd: false,
      option: false)

    XCTAssertEqual(token, ConfigurableShortcutAction.showShortcutReference.defaultBinding)
  }
}
