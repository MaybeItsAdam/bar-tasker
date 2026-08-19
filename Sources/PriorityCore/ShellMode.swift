import Foundation

/// Which shell the task UI is being rendered into.
///
/// The same content view serves both surfaces; only its chrome differs. Keeping
/// that difference as a value rather than two view hierarchies is what stops the
/// window from forking `PopoverView` — every member of `PopoverView+Dock`,
/// `+TaskRow` and `+QuickEntryBar` is an extension on that one type.
public enum ShellMode: Sendable, CaseIterable {
  /// The menu bar panel: anchored under the status item, pinned to a computed
  /// size, no title bar.
  case panel
  /// An ordinary titled, resizable window.
  case window
}

/// A piece of chrome whose presence depends on the shell.
public enum ShellChromeElement: Sendable, CaseIterable {
  /// The 6pt strip that fakes a title bar bevel on a chromeless panel.
  case topBevel
  /// The drag strip revealed by the dock's resize button.
  case resizeStrip
  /// The dock button that reveals the drag strip.
  case resizeDockButton
  /// Clipping the content to a rounded rectangle.
  case roundedCorners
  /// Pinning the content to `PopoverLayout`'s computed width and height.
  case fixedSize
  /// The dock button that opens the diagnostics sheet.
  case diagnosticsDockButton
  /// The dock row's right-aligned sync status readout.
  case syncStatusReadout
  /// Root tabs that divide the full width evenly, rather than sizing to fit.
  case evenlyDividedTabStrip
}

/// Which chrome each shell draws.
///
/// A table rather than `if shellMode == .window` scattered through the views, so
/// the rules are stated once and can be tested without standing up SwiftUI.
public enum ShellChrome {
  public static func shows(_ element: ShellChromeElement, in mode: ShellMode) -> Bool {
    switch element {
    // The panel has no title bar and no system resize corner, so it draws its
    // own bevel, its own rounded edge and its own drag strip, and it has to be
    // told its size because nothing else constrains it. A titled window gets all
    // four from AppKit.
    case .topBevel, .resizeStrip, .resizeDockButton, .roundedCorners, .fixedSize:
      return mode == .panel

    // Support surfaces. The diagnostics sheet needs a window to attach to, and
    // the status readout needs width the panel would rather spend on tasks.
    case .diagnosticsDockButton, .syncStatusReadout:
      return mode == .window

    // Seven tabs divide 400pt into readable thirds of an inch; at window widths
    // the same rule gives each tab a wasteland of empty space.
    case .evenlyDividedTabStrip:
      return mode == .panel
    }
  }
}
