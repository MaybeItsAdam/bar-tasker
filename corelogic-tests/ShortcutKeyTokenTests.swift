import XCTest

@testable import PriorityCore

/// The keybinding format has two halves that never met: `ShortcutKeyToken.make`
/// encodes a key press, `ConfigurableShortcutAction.defaultBinding` spells the
/// expected strings by hand, and `PreferencesManager.shortcutMatches` compares
/// them. Nothing checked that they agree, and a mismatch is invisible — the key
/// simply does nothing.
final class ShortcutKeyTokenTests: XCTestCase {

  // MARK: - Encoding

  func testAPlainLetterIsItsLowercasedCharacter() {
    XCTAssertEqual(token(keyCode: 38, characters: "J"), "j")
  }

  func testNamedKeysUseTheirNameRatherThanTheirCharacter() {
    XCTAssertEqual(token(keyCode: 49, characters: " "), "space")
    XCTAssertEqual(token(keyCode: 36, characters: "\r"), "enter")
    XCTAssertEqual(token(keyCode: 53, characters: "\u{1B}"), "escape")
    XCTAssertEqual(token(keyCode: 126, characters: ""), "up")
  }

  /// Number-row keys are named by code rather than by character so that a
  /// layout where Shift+1 reports "!" still binds as "shift+1".
  /// The key labelled "delete" on a Mac keyboard is backspace, keyCode 51.
  /// Only 117 — the forward delete behind fn — was mapped, so the `delete`
  /// binding never fired for the key its own help text names, and a daily
  /// could not be deleted at all.
  func testBothDeleteKeysProduceTheDeleteToken() {
    XCTAssertEqual(token(keyCode: 51, characters: "\u{8}"), "delete")
    XCTAssertEqual(token(keyCode: 117, characters: "\u{7F}"), "delete")
  }

  func testNumberRowKeysAreNamedByCodeNotByCharacter() {
    XCTAssertEqual(token(keyCode: 18, characters: "!", shift: true), "shift+1")
  }

  func testModifiersAlwaysAppearInAFixedOrder() {
    let chord = token(keyCode: 38, characters: "j", shift: true, ctrl: true, cmd: true, option: true)

    XCTAssertEqual(
      chord, "ctrl+cmd+option+shift+j",
      "tokens are compared as strings, so one chord must have exactly one spelling")
  }

  func testAnUnknownKeyWithNoCharacterFallsBackToItsCode() {
    XCTAssertEqual(token(keyCode: 999, characters: ""), "key999")
  }

  func testSurroundingWhitespaceInTheCharactersIsIgnored() {
    XCTAssertEqual(token(keyCode: 38, characters: "  j  "), "j")
  }

  // MARK: - Agreement with the declared defaults

  /// Every single-chord default has to be a token this encoder can actually
  /// produce. One that is spelled some other way is dead on arrival — which is
  /// exactly what had happened to `rootFilter7`, whose default was the
  /// unproducible `"comma"`, leaving the seventh filter slot with no working
  /// shortcut at all.
  ///
  /// Two-key sequences are excluded: they are matched against an accumulated
  /// key buffer, not against a token, so `"dd"` is correct there.
  func testEverySingleChordDefaultIsAProducibleToken() {
    let producible = producibleTokens()

    for action in ConfigurableShortcutAction.allCases where !action.isTwoKeySequence {
      for binding in action.defaultBinding.split(separator: ",") {
        let token = binding.trimmingCharacters(in: .whitespaces).lowercased()
        XCTAssertTrue(
          producible.contains(token),
          "\(action.rawValue) defaults to \"\(token)\", which no key press produces")
      }
    }
  }

  /// A sequence binding must be two plain characters. Anything with a `+` in it
  /// would be compared against the key buffer, which never contains modifiers,
  /// so it could never match.
  func testEverySequenceDefaultIsAPlainTwoKeyString() {
    for action in ConfigurableShortcutAction.allCases where action.isTwoKeySequence {
      for binding in action.defaultBinding.split(separator: ",") {
        let sequence = binding.trimmingCharacters(in: .whitespaces)
        XCTAssertFalse(
          sequence.contains("+"),
          "\(action.rawValue) binds \"\(sequence)\", but the key buffer holds no modifiers")
        XCTAssertEqual(
          sequence.count, 2,
          "\(action.rawValue) binds \"\(sequence)\", which is not a two-key sequence")
      }
    }
  }

  /// The comma key specifically: bindings are stored comma-separated with no
  /// escape, so `,` has to travel under a name or it splits the list it is in.
  func testTheCommaKeyIsNamedRatherThanSpelled() {
    XCTAssertEqual(token(keyCode: 43, characters: ","), "comma")
    XCTAssertEqual(
      ConfigurableShortcutAction.rootFilter7.defaultBinding, "comma",
      "and the binding that depends on it still agrees")
  }

  func testEveryActionHasANonEmptyDefaultBinding() {
    for action in ConfigurableShortcutAction.allCases {
      XCTAssertFalse(
        action.defaultBinding.trimmingCharacters(in: .whitespaces).isEmpty,
        "\(action.rawValue) has no default binding")
    }
  }

  // MARK: - Helpers

  private func token(
    keyCode: UInt16,
    characters: String,
    shift: Bool = false,
    ctrl: Bool = false,
    cmd: Bool = false,
    option: Bool = false
  ) -> String {
    ShortcutKeyToken.make(
      keyCode: keyCode,
      charactersIgnoringModifiers: characters,
      shift: shift, ctrl: ctrl, cmd: cmd, option: option)
  }

  /// Every token reachable from a single key press: the named keys and the
  /// printable ASCII characters, across all sixteen modifier combinations.
  private func producibleTokens() -> Set<String> {
    var bases = Set(ShortcutKeyToken.nameByKeyCode.values)
    for scalar in UnicodeScalar("a").value...UnicodeScalar("z").value {
      bases.insert(String(UnicodeScalar(scalar)!))
    }
    for punctuation in ";',./[]\\`" {
      bases.insert(String(punctuation))
    }

    var tokens: Set<String> = []
    for base in bases {
      for mask in 0..<16 {
        var parts: [String] = []
        if mask & 1 != 0 { parts.append("ctrl") }
        if mask & 2 != 0 { parts.append("cmd") }
        if mask & 4 != 0 { parts.append("option") }
        if mask & 8 != 0 { parts.append("shift") }
        parts.append(base)
        tokens.insert(parts.joined(separator: "+"))
      }
    }
    return tokens
  }
}
