import XCTest

@testable import PriorityCore

/// The two-key shortcut state machine. It is one character of state read and
/// written at nine points inside `KeyboardShortcutRouter.handle`; a buffer left
/// standing swallows the next key press with no visible cause.
final class ShortcutSequenceBufferTests: XCTestCase {

  private let starters: Set<String> = ["d", "t", "m"]
  private let matrixStarters: Set<String> = ["m"]

  private func advance(
    buffer: String,
    _ characters: String,
    focused: Bool = false,
    shift: Bool = false,
    ctrl: Bool = false
  ) -> ShortcutSequenceBuffer.Outcome {
    ShortcutSequenceBuffer.advance(
      buffer: buffer, characters: characters, starters: starters,
      matrixStarters: matrixStarters, isTextEntryFocused: focused, shift: shift, ctrl: ctrl)
  }

  // MARK: - Starting

  func testAStarterKeyOpensASequence() {
    XCTAssertEqual(
      advance(buffer: "", "d"),
      .init(buffer: "d", effect: .awaitSecondKey))
  }

  func testANonStarterIsLeftForTheOtherBindings() {
    XCTAssertEqual(advance(buffer: "", "q"), .init(buffer: "", effect: .pass))
  }

  func testStartersAreCaseInsensitiveButBufferLowercased() {
    XCTAssertEqual(advance(buffer: "", "D"), .init(buffer: "d", effect: .awaitSecondKey))
  }

  /// `shift+d` and `ctrl+d` have to stay available as ordinary bindings, so a
  /// modified starter is not a starter.
  func testAModifiedStarterIsNotASequence() {
    XCTAssertEqual(advance(buffer: "", "d", shift: true).effect, .pass)
    XCTAssertEqual(advance(buffer: "", "d", ctrl: true).effect, .pass)
  }

  func testNoSequenceStartsWhileTypingIntoAField() {
    XCTAssertEqual(advance(buffer: "", "d", focused: true).effect, .pass)
  }

  // MARK: - Completing

  func testASecondKeyCompletesTheSequenceAndClearsTheBuffer() {
    XCTAssertEqual(
      advance(buffer: "d", "d"),
      .init(buffer: "", effect: .attempt(sequence: "dd")))
  }

  /// The buffer is cleared *before* the lookup, so a sequence that matches
  /// nothing cannot poison the next key press.
  func testAnUnmatchedSequenceStillClearsTheBuffer() {
    XCTAssertEqual(advance(buffer: "d", "z").buffer, "")
  }

  /// Typing resumes mid-sequence: the pending buffer is dropped and the
  /// character is handed on so it lands in the field.
  func testAPendingSequenceIsAbandonedWhenAFieldTakesFocus() {
    XCTAssertEqual(
      advance(buffer: "d", "x", focused: true),
      .init(buffer: "", effect: .abandon))
  }

  // MARK: - The matrix coordinate

  func testTheMatrixStarterFollowedByADigitAdvancesRatherThanCompletes() {
    XCTAssertEqual(
      advance(buffer: "m", "3"),
      .init(buffer: "m3", effect: .reportMatrixUrgency("3")))
  }

  func testASecondDigitCompletesTheCoordinate() {
    XCTAssertEqual(
      advance(buffer: "m3", "7"),
      .init(buffer: "", effect: .applyMatrixCoordinate(urgency: 3, importance: 7)))
  }

  func testZeroIsAValidCoordinate() {
    XCTAssertEqual(
      advance(buffer: "m0", "0").effect,
      .applyMatrixCoordinate(urgency: 0, importance: 0))
  }

  /// A non-digit after the matrix starter is an ordinary two-key sequence, not
  /// a broken coordinate.
  func testANonDigitAfterTheMatrixStarterCompletesNormally() {
    XCTAssertEqual(
      advance(buffer: "m", "t"),
      .init(buffer: "", effect: .attempt(sequence: "mt")))
  }

  func testANonMatrixStarterFollowedByADigitIsAnOrdinarySequence() {
    XCTAssertEqual(
      advance(buffer: "d", "3"),
      .init(buffer: "", effect: .attempt(sequence: "d3")))
  }

  /// The three-key form is unavailable while typing, so the coordinate is not
  /// half-applied from digits meant for a text field.
  func testTheCoordinateDoesNotAdvanceWhileTypingIntoAField() {
    XCTAssertEqual(advance(buffer: "m", "3", focused: true).effect, .abandon)
  }

  // MARK: - Deriving starters from bindings

  func testStartersAreTheFirstCharacterOfEachBinding() {
    XCTAssertEqual(
      ShortcutSequenceBuffer.starters(fromBindings: ["dd", "dt", "gc"]), ["d", "g"])
  }

  /// A one-character token is not a sequence. Treating it as one would let a
  /// malformed binding claim every press of that letter.
  func testSingleCharacterBindingsAreNotStarters() {
    XCTAssertEqual(ShortcutSequenceBuffer.starters(fromBindings: ["d", ""]), [])
  }

  func testBindingsAreTrimmedAndLowercasedBeforeUse() {
    XCTAssertEqual(ShortcutSequenceBuffer.starters(fromBindings: ["  DD "]), ["d"])
  }
}
