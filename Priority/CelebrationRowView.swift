import PriorityCore
import SwiftUI

/// The row half of a completion celebration, once, for every surface that has
/// rows.
///
/// This exists because the same twenty lines of `opacity` / `scaleEffect` /
/// tinted background / leading bar / `.animation` were written out in the task
/// list, the Daily checklist and the kanban card, and the three copies had
/// already drifted apart: the kanban card was still on a hardcoded
/// `.spring(response: 0.3, dampingFraction: 0.5)` from before `CelebrationMotion`
/// existed, applied only three of the treatment's six properties, and read the
/// completing flag straight off `QuickEntryManager` — which is exactly what
/// `CelebrationStage`'s doc comment says surfaces must not do. The Eisenhower
/// matrix had no completion rendering at all, because adding it meant copying
/// the twenty lines a fourth time.
///
/// Surfaces differ in two ways only, both parameters here: what their selection
/// looks like underneath the tint, and whether a row is allowed to collapse.
struct CelebratingRow: ViewModifier {
  /// The row this is. `.idle` for every row that isn't the one completing, so
  /// applying this to a whole list costs nothing but a comparison per row.
  let kind: CompletionKind
  /// Painted under the celebration tint rather than replaced by it. The tint
  /// used to *swap out* the selection highlight for the length of the
  /// celebration, so completing the row you were sitting on made the cursor
  /// appear to leave and come back.
  var selectionBackground: Color?
  /// The leading edge marker's colour when the row is not completing.
  var selectionBar: Color?
  /// Kanban and the matrix opt out: their cards sit in a fixed grid, and
  /// folding one shut mid-column shuffles every card below it.
  var allowsCollapse: Bool = true

  @Environment(AppCoordinator.self) private var manager

  func body(content: Content) -> some View {
    let treatment = manager.celebration.rowTreatment
    let phase = manager.celebration.phase(for: kind)
    let reduceMotion = manager.celebration.prefersReducedMotion
    let tint = manager.preferences.themeColor(for: .success)

    content
      .opacity(treatment.fades(at: phase) ? 0 : 1)
      .scaleEffect(treatment.rowScale(for: phase))
      // Collapsing is a vertical scale about the top edge rather than a height
      // animation: the rows below slide up to meet it, and SwiftUI doesn't have
      // to remeasure a row whose badges are mid-fade.
      .scaleEffect(
        x: 1,
        y: allowsCollapse && treatment.collapses(at: phase) ? 0.001 : 1.0,
        anchor: .top
      )
      .background {
        ZStack {
          if let selectionBackground { selectionBackground }
          let opacity = treatment.tintOpacity(for: phase)
          if opacity > 0 { tint.opacity(opacity) }
        }
      }
      .overlay(alignment: .leading) {
        Rectangle()
          .fill(
            treatment.marksLeadingEdge(at: phase) ? tint : (selectionBar ?? Color.clear)
          )
          .frame(width: 3)
      }
      // Below the background and the leading bar, deliberately: `.animation`
      // only covers what is already applied above it. Attached directly under
      // the scale effects — where each of the three copies had it — it left the
      // tint and the bar outside its scope, so those snapped while the row
      // sprang, which is most of why the effect read as a twitch.
      .animation(CelebrationMotion.row(reduceMotion: reduceMotion), value: phase)
      .overlay {
        // Preset-specific decoration (Spark's particles). Rebuilt per completion
        // via `.id` so a second completion re-runs the burst rather than reusing
        // the finished one.
        if phase != .idle, let accent = manager.celebration.rowAccent(for: kind) {
          accent
            .id(kind)
            .allowsHitTesting(false)
        }
      }
  }
}

extension View {
  /// Applies the active preset's row treatment for `kind`.
  func celebrating(
    _ kind: CompletionKind,
    selectionBackground: Color? = nil,
    selectionBar: Color? = nil,
    allowsCollapse: Bool = true
  ) -> some View {
    modifier(
      CelebratingRow(
        kind: kind,
        selectionBackground: selectionBackground,
        selectionBar: selectionBar,
        allowsCollapse: allowsCollapse
      )
    )
  }
}

/// The leading status glyph, and the pop it takes when the row completes.
///
/// The glyph is the reason `CelebrationRowTreatment.iconPop` exists — its own
/// doc comment explains that scaling a full-bleed row by a percent or two is
/// imperceptible because it has no edge to be measured against, whereas the
/// checkmark is a small shape the eye is already fixed on. That reasoning was
/// sound and, for the app's primary surface, entirely theoretical: the Daily
/// checklist had a glyph and read `iconPop`, and the task list had neither. The
/// shipped default therefore played its headline effect on one of the two
/// places you complete things, and on the other applied a 1.01 row nudge and
/// nothing else — precisely the invisible version the retune was written to
/// replace.
struct CelebrationStatusGlyph: View {
  /// Whether the underlying thing is done. Distinct from the celebration:
  /// a daily stays ticked afterwards, a task is on its way out.
  let isDone: Bool
  let kind: CompletionKind

  @Environment(AppCoordinator.self) private var manager

  var body: some View {
    let treatment = manager.celebration.rowTreatment
    let phase = manager.celebration.phase(for: kind)
    let reduceMotion = manager.celebration.prefersReducedMotion
    let showsCheck = isDone || phase == .celebrating

    Image(systemName: showsCheck ? "checkmark.circle.fill" : "circle")
      .font(.system(size: 14))
      .foregroundColor(
        showsCheck
          ? manager.preferences.themeColor(for: .success)
          : manager.preferences.themeColor(for: .textMuted)
      )
      // The glyph swap is the moment a completion is actually *felt*, so it
      // gets a transition rather than a cut — and a pop on top of it while the
      // celebration runs.
      .contentTransition(.symbolEffect(.replace))
      .scaleEffect(treatment.iconScale(for: phase))
      .animation(CelebrationMotion.icon(reduceMotion: reduceMotion), value: phase)
      .animation(CelebrationMotion.icon(reduceMotion: reduceMotion), value: showsCheck)
      .frame(width: PopoverLayout.rowIconWidth)
  }
}

/// The rule drawn through a completing title, left to right.
///
/// Drawn rather than SwiftUI's `.strikethrough`, which is a boolean the
/// framework cannot interpolate and therefore cannot animate. Sized from the
/// text it is struck through: a fixed duration made the rule's *speed* a
/// function of title length, so a three-word task got a flash and a
/// twelve-word task got a crawl.
struct CelebrationStrike: View {
  /// Whether the rule is drawn. Tasks pass the celebration phase; dailies pass
  /// their lasting done-ness, because on a daily the strike is the resting
  /// state rather than a flourish that plays over one.
  let isDrawn: Bool
  let color: Color
  let reduceMotion: Bool

  @State private var width: CGFloat = 0

  var body: some View {
    Rectangle()
      .fill(color)
      .frame(height: 1.5)
      .scaleEffect(x: isDrawn ? 1.0 : 0.001, y: 1, anchor: .leading)
      .animation(
        CelebrationMotion.strike(reduceMotion: reduceMotion, width: width),
        value: isDrawn
      )
      .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
  }
}
