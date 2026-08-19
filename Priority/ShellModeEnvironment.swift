import PriorityCore
import SwiftUI

/// The shell the current view tree is being rendered into.
///
/// Defaults to `.panel` so the menu bar path needs no change at all — only
/// `MainWindowController` sets it, and only for its own hosting controller.
private struct ShellModeKey: EnvironmentKey {
  static let defaultValue: ShellMode = .panel
}

extension EnvironmentValues {
  var shellMode: ShellMode {
    get { self[ShellModeKey.self] }
    set { self[ShellModeKey.self] = newValue }
  }
}

/// Pins the content to a measured size, or lets it fill whatever it is given.
///
/// The panel is a borderless window that nothing else constrains, so it has to
/// be told exactly how tall to be. A titled window is sized by AppKit and by the
/// user's drag, and pinning it would make the resize corner do nothing.
struct ShellFrame: ViewModifier {
  let width: CGFloat
  let height: CGFloat
  let isFixed: Bool

  func body(content: Content) -> some View {
    if isFixed {
      content.frame(width: width, height: height, alignment: .top)
    } else {
      content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
  }
}

/// Rounds the content's corners, or leaves them to the window.
///
/// Clipping inside a square titled window doesn't round the window — it cuts
/// wedges out of the content and shows the window's own background through them.
struct ShellCorners: ViewModifier {
  let isRounded: Bool

  func body(content: Content) -> some View {
    if isRounded {
      content.clipShape(RoundedRectangle(cornerRadius: PopoverLayout.cornerRadius))
    } else {
      content
    }
  }
}
