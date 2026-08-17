import AppKit
import SwiftUI

/// The dock row along the bottom of the popover, and the drag strip it reveals.
///
/// Split into its own file for the same reason `PopoverView+TaskRow.swift` is:
/// `PopoverView.swift` is already close to the `file_length` limit in
/// `.swiftlint.yml`. The pieces are standalone `View` structs rather than
/// `@ViewBuilder` members because each needs its own `@State` (hover, drag
/// origin), and an extension can't add stored properties.
extension PopoverView {
  var dockRow: some View { PopoverDockRow() }
  var resizeStrip: some View { PopoverResizeStrip() }
}

// MARK: - Dock row

/// A narrow strip of persistent controls, present in every root view.
///
/// Sits on `panelSurface` to bracket the panel against `topBevelArea` at the
/// other end, so the content between them reads as the content.
struct PopoverDockRow: View {
  @Environment(AppCoordinator.self) private var manager
  @Environment(TaskListViewModel.self) private var taskListViewModel

  private func themeColor(_ token: AppThemeColorToken) -> Color {
    manager.preferences.themeColor(for: token)
  }

  var body: some View {
    let chrome = manager.popoverChrome

    HStack(spacing: 2) {
      Spacer(minLength: 0)

      // Only where there is a graph to toggle. A control that does nothing in
      // five of seven views teaches you to ignore it.
      if taskListViewModel.rootTaskView == .daily {
        DockButton(
          systemName: "chart.bar",
          isActive: chrome.showsDailyChart,
          help: chrome.showsDailyChart ? "Hide the graph" : "Show the graph",
          accessibilityLabel: "Toggle the graph"
        ) {
          chrome.showsDailyChart.toggle()
        }
      }

      DockButton(
        systemName: "arrow.up.and.down",
        isActive: chrome.isResizeHandleVisible,
        help: chrome.isResizeHandleVisible ? "Hide the resize handle" : "Resize this view",
        accessibilityLabel: "Toggle the resize handle"
      ) {
        chrome.isResizeHandleVisible.toggle()
      }

      if manager.repository.isLoading {
        ProgressView()
          .scaleEffect(0.5)
          .frame(width: 22, height: PopoverLayout.dockHeight)
          .accessibilityLabel("Refreshing")
      } else {
        DockButton(
          systemName: "arrow.clockwise",
          isActive: false,
          help: "Refresh from Checkvist",
          accessibilityLabel: "Refresh"
        ) {
          Task { await manager.fetchTopTask() }
        }
      }

      DockButton(
        systemName: "gearshape",
        isActive: false,
        help: "Preferences",
        accessibilityLabel: "Open preferences"
      ) {
        AppDelegate.shared.menuSettings()
      }
    }
    .padding(.horizontal, 6)
    .frame(height: PopoverLayout.dockHeight)
    .frame(maxWidth: .infinity)
    .background(themeColor(.panelSurface))
  }
}

/// One icon button. Unlabelled, so it carries both a tooltip and an
/// accessibility label rather than relying on the glyph to explain itself.
private struct DockButton: View {
  @Environment(AppCoordinator.self) private var manager

  let systemName: String
  let isActive: Bool
  let help: String
  let accessibilityLabel: String
  let action: () -> Void

  @State private var isHovering = false

  private func themeColor(_ token: AppThemeColorToken) -> Color {
    manager.preferences.themeColor(for: token)
  }

  var body: some View {
    Button(action: action) {
      Image(systemName: systemName)
        .font(.system(size: 11, weight: .medium))
        .foregroundColor(
          isActive
            ? themeColor(.selectionForeground)
            : themeColor(isHovering ? .textSecondary : .textMuted)
        )
        // A 22×full-height target around an 11pt glyph: the icon is small
        // because the dock is narrow, but the thing you click shouldn't be.
        .frame(width: 22, height: PopoverLayout.dockHeight)
        .background(
          RoundedRectangle(cornerRadius: 4)
            .fill(isHovering ? themeColor(.selectionBackground).opacity(0.5) : Color.clear)
            .padding(.vertical, 3)
        )
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    .help(help)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityAddTraits(isActive ? [.isSelected] : [])
  }
}

// MARK: - Resize strip

/// Drag to set this view's height; double-click to go back to sizing from
/// content.
///
/// Deliberately summoned from the dock rather than always present: a menu-bar
/// panel has no title bar and no system resize corner, so the affordance has to
/// be visible to be findable — but it only needs to be visible when you're
/// actually resizing. Each root view keeps its own height, because the Daily
/// view stacks four sections where the All view is one list.
struct PopoverResizeStrip: View {
  @Environment(AppCoordinator.self) private var manager
  @Environment(TaskListViewModel.self) private var taskListViewModel

  /// Height when the drag began. Captured once per drag: reading the live
  /// height on every frame compounds the translation and the panel runs away
  /// from the cursor.
  @State private var dragStartHeight: CGFloat?

  private func themeColor(_ token: AppThemeColorToken) -> Color {
    manager.preferences.themeColor(for: token)
  }

  var body: some View {
    let view = taskListViewModel.rootTaskView
    let isCustom = manager.popoverChrome.height(for: view) != nil

    RoundedRectangle(cornerRadius: 1.5)
      .fill(themeColor(isCustom ? .textSecondary : .textMuted).opacity(0.5))
      .frame(width: 32, height: 3)
      .frame(maxWidth: .infinity, minHeight: PopoverLayout.resizeStripHeight)
      .contentShape(Rectangle())
      .onHover { inside in
        // Says "resizes" before you commit to a drag.
        if inside {
          NSCursor.resizeUpDown.push()
        } else {
          NSCursor.pop()
        }
      }
      .gesture(
        DragGesture(minimumDistance: 1)
          .onChanged { value in
            let start = dragStartHeight ?? PopoverLayout.preferredHeight(for: manager)
            if dragStartHeight == nil { dragStartHeight = start }
            // Stored in the view's own terms — the Daily view keeps its height
            // without the chart, so the graph button adds and removes the
            // chart's height rather than resizing the checklist under it.
            manager.popoverChrome.setHeight(
              PopoverLayout.storedHeight(
                forDisplayed: start + value.translation.height, in: manager),
              for: view
            )
          }
          .onEnded { _ in dragStartHeight = nil }
      )
      .onTapGesture(count: 2) {
        manager.popoverChrome.resetHeight(for: view)
      }
      .help(
        isCustom
          ? "Drag to resize. Double-click to fit the content again."
          : "Drag to resize this view."
      )
      .accessibilityLabel("Resize this view")
      .accessibilityHint("Drag up or down to change the height. Double-tap to reset.")
  }
}
