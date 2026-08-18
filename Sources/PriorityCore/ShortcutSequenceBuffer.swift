import Foundation

/// The two-key shortcut state machine: `d`-then-`d` for due, `m`-then-digit-
/// then-digit for an Eisenhower coordinate, and so on.
///
/// One character of state — `quickEntry.keyBuffer` — read and written at nine
/// points scattered through `KeyboardShortcutRouter.handle`. A buffer left
/// standing swallows the next key press with no visible cause, which is the
/// failure mode this exists to make testable.
public enum ShortcutSequenceBuffer {

  /// What the router should do, alongside the buffer's new value. The buffer is
  /// always part of the answer, so no caller has to remember to clear it.
  public struct Outcome: Equatable {
    public var buffer: String
    public var effect: Effect

    public init(
      buffer: String,
      effect: Effect
    ) {
    self.buffer = buffer
    self.effect = effect
    }
  }

  public enum Effect: Equatable {
    /// Not a sequence key. Carry on to the remaining bindings.
    case pass
    /// A starter was accepted; the next key completes it.
    case awaitSecondKey
    /// `m` then a digit: half of a matrix coordinate, echoed to the status bar.
    case reportMatrixUrgency(String)
    /// `m` then two digits: the whole coordinate.
    case applyMatrixCoordinate(urgency: Double, importance: Double)
    /// A complete two-key sequence for the router to look up.
    case attempt(sequence: String)
    /// A sequence was pending but the second key arrived while a text field
    /// had focus. The buffer is dropped and the event is handed on unclaimed,
    /// so the character still lands in the field the user is typing into.
    case abandon
  }

  /// `starters` and `matrixStarters` are the first characters of the configured
  /// sequence bindings — derived from the bindings rather than hardcoded, so a
  /// rebound sequence keeps working.
  public static func advance(
    buffer: String,
    characters: String,
    starters: Set<String>,
    matrixStarters: Set<String>,
    isTextEntryFocused: Bool,
    shift: Bool,
    ctrl: Bool
  ) -> Outcome {
    let key = characters.lowercased()
    let pending = buffer.lowercased()

    guard !pending.isEmpty else {
      // Modifiers are excluded so `shift+d` and `ctrl+d` stay available as
      // ordinary bindings rather than being eaten as sequence starters.
      guard starters.contains(key), !shift, !ctrl, !isTextEntryFocused else {
        return Outcome(buffer: buffer, effect: .pass)
      }
      return Outcome(buffer: key, effect: .awaitSecondKey)
    }

    if !isTextEntryFocused, let matrix = matrixStep(pending, key, matrixStarters) {
      return matrix
    }

    // Any other second key ends the sequence, matched or not. Clearing the
    // buffer here — before the lookup — is what stops a failed sequence from
    // poisoning the next key press.
    //
    // A sequence that matches nothing is *not* re-tried as a single-key
    // binding: the event is handed on unclaimed either way.
    guard !isTextEntryFocused else { return Outcome(buffer: "", effect: .abandon) }
    return Outcome(buffer: "", effect: .attempt(sequence: pending + key))
  }

  /// The matrix sequence is the only three-key one, so it advances the buffer a
  /// second time instead of completing.
  private static func matrixStep(
    _ pending: String, _ key: String, _ matrixStarters: Set<String>
  ) -> Outcome? {
    guard key.count == 1, let digit = key.first, digit.isNumber else { return nil }

    if pending.count == 1, matrixStarters.contains(pending) {
      return Outcome(buffer: pending + key, effect: .reportMatrixUrgency(key))
    }
    if pending.count == 2,
      let starter = pending.first.map(String.init),
      matrixStarters.contains(starter),
      let urgencyDigit = pending.last, urgencyDigit.isNumber,
      let urgency = Double(String(urgencyDigit)),
      let importance = Double(key)
    {
      return Outcome(
        buffer: "",
        effect: .applyMatrixCoordinate(urgency: urgency, importance: importance))
    }
    return nil
  }

  /// The first character of each configured binding. Tokens shorter than two
  /// characters are not sequences and are skipped, so a malformed binding
  /// cannot claim every press of a single letter.
  public static func starters(fromBindings tokens: [String]) -> Set<String> {
    Set(
      tokens.compactMap { token in
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.count >= 2 else { return nil }
        return String(normalized.prefix(1))
      })
  }
}
