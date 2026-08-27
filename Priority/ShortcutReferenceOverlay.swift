import PriorityCore
import SwiftUI

/// The keyboard reference, on `?` — the key Checkvist puts it on.
///
/// Every row is derived from the binding actually in force, via
/// `ShortcutReference.sections(binding:)`, so it shows *your* keyboard rather
/// than the defaults. That is the whole reason it exists: the reference this
/// replaces was a hand-written list that had drifted three bindings out of date
/// and could never have reflected a customisation at all.
struct ShortcutReferenceOverlay: View {
  @Environment(AppCoordinator.self) private var manager

  @State private var query: String = ""
  @FocusState private var searchFocused: Bool

  private func themeColor(_ token: AppThemeColorToken) -> Color {
    manager.preferences.themeColor(for: token)
  }

  private var sections: [ShortcutReference.Section] {
    let binding: (ConfigurableShortcutAction) -> String = { action in
      manager.preferences.shortcutBinding(for: action)
    }
    // What applies right here, first. The full list still follows — this
    // narrows the answer to "what can I do to this task, now" without hiding
    // anything, and it costs no permanent chrome because it is only ever on
    // screen while this overlay is.
    let contextual = ShortcutReference.contextualSection(
      for: manager.taskListViewModel.rootTaskView, binding: binding)
    let all = (contextual.map { [$0] } ?? []) + ShortcutReference.sections(binding: binding)
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !trimmed.isEmpty else { return all }
    return all.compactMap { section in
      let matches = section.entries.filter { entry in
        entry.title.lowercased().contains(trimmed)
          || entry.keys.contains { $0.lowercased().contains(trimmed) }
          || (entry.note?.lowercased().contains(trimmed) ?? false)
      }
      return matches.isEmpty ? nil : .init(title: section.title, entries: matches)
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      if sections.isEmpty {
        Text("Nothing matches “\(query)”.")
          .font(.system(size: 12))
          .foregroundColor(themeColor(.textMuted))
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 14) {
            ForEach(sections) { section in
              VStack(alignment: .leading, spacing: 4) {
                Text(section.title.uppercased())
                  .font(.system(size: 10, weight: .semibold))
                  .foregroundColor(themeColor(.textSecondary))
                  .padding(.bottom, 2)
                ForEach(section.entries) { entry in
                  row(entry)
                }
              }
            }
          }
          .padding(.horizontal, PopoverLayout.rowHorizontalPadding)
          .padding(.vertical, 10)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
    .background(themeColor(.panelSurface))
  }

  @ViewBuilder
  private var header: some View {
    HStack(spacing: 8) {
      Text("KEYBOARD")
        .font(.system(size: 10, weight: .semibold))
        .foregroundColor(themeColor(.textSecondary))
      TextField("Filter…", text: $query)
        .textFieldStyle(.plain)
        .font(.system(size: 12))
        .foregroundColor(themeColor(.textPrimary))
        .focused($searchFocused)
        .onAppear { searchFocused = true }
      Text("Esc")
        .font(.system(size: 10, weight: .medium))
        .foregroundColor(themeColor(.textMuted))
      Button {
        manager.popoverChrome.showsShortcutReference = false
      } label: {
        Image(systemName: "xmark.circle.fill")
          .font(.system(size: 12))
          .foregroundColor(themeColor(.textSecondary))
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Close the keyboard reference")
    }
    .padding(.horizontal, PopoverLayout.rowHorizontalPadding)
    .padding(.vertical, 8)
    .background(themeColor(.panelSurfaceElevated))
  }

  @ViewBuilder
  private func row(_ entry: ShortcutReference.Entry) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      // Fixed-width key column, so the whole sheet reads as two columns rather
      // than as a ragged list — the keys are what you scan for.
      HStack(spacing: 3) {
        ForEach(Array(entry.keys.enumerated()), id: \.offset) { index, key in
          if index > 0 {
            Text("/")
              .font(.system(size: 9))
              .foregroundColor(themeColor(.textMuted))
          }
          Text(key)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundColor(themeColor(.textPrimary))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
              RoundedRectangle(cornerRadius: 4)
                .fill(themeColor(.panelSurfaceElevated))
            )
        }
      }
      .frame(width: 118, alignment: .leading)

      VStack(alignment: .leading, spacing: 0) {
        Text(entry.title)
          .font(.system(size: 12))
          .foregroundColor(themeColor(.textPrimary))
        if let note = entry.note {
          Text(note)
            .font(.system(size: 10))
            .foregroundColor(themeColor(.textMuted))
        }
      }
      Spacer(minLength: 0)
    }
  }
}
