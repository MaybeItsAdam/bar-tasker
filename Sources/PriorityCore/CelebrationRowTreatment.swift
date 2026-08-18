import Foundation

/// How a row should render while it is being completed.
///
/// Data rather than a view, so the row stays one piece of generic layout that
/// every preset shares. The alternative — letting each preset draw its own row —
/// would mean four copies of the badge stack, the breadcrumb line and the
/// disclosure button, which is where the interesting bugs would live.
///
/// Pure, and in `PriorityCore`, so the presets' visual contracts can be asserted
/// without standing up SwiftUI.
public struct CelebrationRowTreatment: Equatable, Sendable {
  /// Draws the line through the row's title, left to right.
  public var drawsStrikethrough: Bool
  /// Opacity of the success tint washed over the row. Zero leaves the row's
  /// normal background alone.
  public var tintOpacity: Double
  /// Multiplier on the row's size. `1.0` is no change; the shipped default
  /// nudges to `1.01`, which reads as a press rather than a zoom.
  public var scale: Double
  /// Collapses the row's height toward zero, so removal looks like the row
  /// being folded away rather than blinking out.
  public var collapses: Bool
  /// Fades the row's contents out. Pairs with `collapses`; on its own it reads
  /// as the row going quiet.
  public var fades: Bool
  /// Multiplier on the row's leading status icon at the peak of the effect.
  ///
  /// Separate from `scale` because the two are doing different jobs, and the
  /// row is the wrong place to express the interesting one. Scaling a
  /// full-bleed row a percent or two is barely perceptible — it has no edges
  /// near anything to measure it against — whereas the checkmark is a small
  /// glyph the eye is already fixed on, so the same proportional change reads
  /// there as a distinct pop. `1.0` leaves the icon alone.
  public var iconPop: Double

  public init(
    drawsStrikethrough: Bool = false,
    tintOpacity: Double = 0,
    scale: Double = 1.0,
    collapses: Bool = false,
    fades: Bool = false,
    iconPop: Double = 1.0
  ) {
    self.drawsStrikethrough = drawsStrikethrough
    self.tintOpacity = tintOpacity
    self.scale = scale
    self.collapses = collapses
    self.fades = fades
    self.iconPop = iconPop
  }

  /// Nothing at all — the row is unchanged right up until it disappears.
  public static let none = CelebrationRowTreatment()

  /// The shipped default: a line drawn through, a wash of success tint, a
  /// one-percent nudge on the row, and a pop on the checkmark.
  ///
  /// The pop is where the retune went. The row nudge was doing the whole job
  /// on its own and doing it invisibly; moving the emphasis onto the glyph
  /// costs no extra time inside `inlineBudget` and is the part you actually
  /// see.
  public static let strike = CelebrationRowTreatment(
    drawsStrikethrough: true,
    tintOpacity: 0.14,
    scale: 1.01,
    iconPop: 1.35
  )

  /// The row folds shut and fades. No strikethrough — the collapse *is* the
  /// statement, and drawing a line through something that is busy vanishing
  /// reads as two effects fighting.
  public static let fold = CelebrationRowTreatment(
    tintOpacity: 0.10,
    scale: 1.0,
    collapses: true,
    fades: true,
    // No pop: the icon is going away with the rest of the row, and a glyph
    // that grows while its container folds shut reads as two effects fighting
    // — the same reason this preset has no strikethrough.
    iconPop: 1.0
  )

  /// Strike plus a brighter wash, to sit under the spark burst without the
  /// particles reading as unrelated to the row they came from.
  public static let spark = CelebrationRowTreatment(
    drawsStrikethrough: true,
    tintOpacity: 0.18,
    scale: 1.02,
    // Larger than Strike's: the particles burst from the icon, so it has to be
    // the loudest thing on the row rather than compete with them.
    iconPop: 1.5
  )
}
