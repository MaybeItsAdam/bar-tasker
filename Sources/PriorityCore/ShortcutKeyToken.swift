import Foundation

/// Encodes a key press as the canonical token string that keybindings are
/// written in — `"cmd+k"`, `"shift+enter"`, `"escape"`, `"j"`.
///
/// This is one half of a format contract with
/// `ConfigurableShortcutAction.defaultBinding`, which spells the *same* strings
/// out by hand, and with `PreferencesManager.shortcutMatches`, which compares
/// the two. Nothing tied the halves together: a token this encoder cannot
/// produce is a binding that silently never fires, and the failure looks like
/// "that key just doesn't do anything" rather than like a bug. The tokens are
/// also persisted — a user's customised bindings are stored in this format — so
/// the spelling cannot drift even when it is wrong.
///
/// Lifted out of `KeyboardShortcutRouter` (where it was a private static on a
/// type that takes `NSEvent` and `AppCoordinator`, and so could not be reached
/// by a test) with the AppKit dependency reduced to the two primitives it
/// actually reads.
public enum ShortcutKeyToken {
  /// Keys whose name is spelled out rather than taken from the characters the
  /// event carries — either because they have no printable character, or
  /// because the character depends on the keyboard layout and the modifier
  /// state in ways a stored binding must not.
  public static let nameByKeyCode: [UInt16: String] = [
    18: "1",
    19: "2",
    20: "3",
    21: "4",
    23: "5",
    22: "6",
    26: "7",
    28: "8",
    25: "9",
    29: "0",
    27: "-",
    24: "=",
    // Named rather than spelled `,` because bindings are stored as a
    // comma-separated list and the format has no escape. `rootFilter7` has
    // defaulted to "comma" since it was added; nothing produced that token, so
    // the seventh filter slot simply had no working shortcut.
    43: "comma",
    49: "space",
    36: "enter",
    48: "tab",
    53: "escape",
    120: "f2",
    // Both delete keys, because the one labelled "delete" on a Mac keyboard is
    // 51 (backspace) and 117 is the forward delete hidden behind fn. Only 117
    // was mapped, so the `delete` binding — the only way to delete a daily —
    // fired for nobody who pressed the key the UI names. 51 carries a
    // non-printable character, so without an entry here it tokenised as that
    // control character and matched nothing.
    51: "delete",
    117: "delete",
    123: "left",
    124: "right",
    125: "down",
    126: "up",
  ]

  /// Modifier order is fixed — ctrl, cmd, option, shift — because the token is
  /// compared as a string. `"cmd+shift+k"` and `"shift+cmd+k"` are the same
  /// chord and must not be two different tokens.
  public static func make(
    keyCode: UInt16,
    charactersIgnoringModifiers rawCharacters: String,
    shift: Bool,
    ctrl: Bool,
    cmd: Bool,
    option: Bool
  ) -> String {
    let characters = rawCharacters.trimmingCharacters(in: .whitespacesAndNewlines)
    let base =
      nameByKeyCode[keyCode]
      ?? (characters.isEmpty ? "key\(keyCode)" : characters.lowercased())

    var parts: [String] = []
    if ctrl { parts.append("ctrl") }
    if cmd { parts.append("cmd") }
    if option { parts.append("option") }
    if shift { parts.append("shift") }
    parts.append(base)
    return parts.joined(separator: "+")
  }
}
