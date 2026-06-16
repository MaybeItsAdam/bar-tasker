import SwiftUI

/// Keybindings pane for `SettingsView` plus every helper used exclusively by
/// it (the three descriptor structs, the static shortcut-reference catalogue,
/// hotkey-card builder, shortcut-binding editor, and search filters). Pulled
/// out of the main file as part of the Phase-4 settings split.
extension SettingsView {
  struct ShortcutReferenceItem: Identifiable {
    let keys: String
    let action: String
    let note: String?
    var id: String { "\(keys)|\(action)" }
  }

  struct ShortcutReferenceGroup: Identifiable {
    let title: String
    let items: [ShortcutReferenceItem]
    var id: String { title }
  }

  struct ShortcutCategoryDescriptor: Identifiable {
    let title: String
    let actions: [ConfigurableShortcutAction]
    var id: String { title }
  }

  var keybindingsPane: some View {
    Group {
      Section(header: Text("Configurable Hotkeys")) {
        Text("These shortcuts work globally, even when Bar Tasker is not focused.")
          .font(.caption)
          .foregroundColor(themeColor(.textSecondary))

        hotkeyCard(
          title: "Global hotkey",
          description: "Shows or hides the task popover from anywhere.",
          defaultDisplay: HotkeyRecorderField.displayString(keyCode: 49, modifiers: 0x0800),
          enabled: preferenceBinding(\.globalHotkeyEnabled),
          keyCode: preferenceBinding(\.globalHotkeyKeyCode),
          modifiers: preferenceBinding(\.globalHotkeyModifiers)
        )
        hotkeyCard(
          title: "Quick Add hotkey",
          description: "Opens Quick Add at your configured target.",
          defaultDisplay: HotkeyRecorderField.displayString(keyCode: 11, modifiers: 0x0A00),
          enabled: preferenceBinding(\.quickAddHotkeyEnabled),
          keyCode: preferenceBinding(\.quickAddHotkeyKeyCode),
          modifiers: preferenceBinding(\.quickAddHotkeyModifiers)
        )

        if hotkeyConflictDetected {
          Label(
            "Global hotkey and Quick Add hotkey currently conflict.",
            systemImage: "exclamationmark.triangle.fill"
          )
          .font(.caption)
          .foregroundColor(themeColor(.danger))
          .padding(10)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(themeColor(.danger).opacity(0.08))
          .overlay(
            RoundedRectangle(cornerRadius: 8)
              .stroke(themeColor(.danger).opacity(0.3), lineWidth: 1)
          )
          .clipShape(RoundedRectangle(cornerRadius: 8))
        }

        HStack {
          Text("Record a modifier plus a key. Press Escape while recording to cancel.")
            .font(.caption)
            .foregroundColor(themeColor(.textSecondary))
          Spacer(minLength: 0)
          Button("Reset hotkeys to defaults") {
            preferences.globalHotkeyKeyCode = 49  // Space
            preferences.globalHotkeyModifiers = 0x0800  // Option
            preferences.quickAddHotkeyKeyCode = 11  // B
            preferences.quickAddHotkeyModifiers = 0x0A00  // Shift + Option
          }
        }
      }

      Section(header: Text("Quick Add Target")) {
        VStack(alignment: .leading, spacing: 6) {
          Text("Quick Add location")
          Picker("", selection: preferenceBinding(\.quickAddLocationMode)) {
            Text("Default (List root)").tag(QuickAddLocationMode.defaultRoot)
            Text("Specific task ID").tag(QuickAddLocationMode.specificParentTask)
          }
          .labelsHidden()
          .pickerStyle(.segmented)

          if preferences.quickAddLocationMode == .specificParentTask {
            HStack {
              TextField("Parent task ID", text: preferenceBinding(\.quickAddSpecificParentTaskId))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 180)
              Button("Use selected task") {
                checkvistManager.taskMutationService.setQuickAddSpecificLocationToCurrentTask()
              }
              .disabled(checkvistManager.taskListViewModel.currentTask == nil)
            }
            Text("Quick Add creates new tasks as children of this task ID.")
              .font(.caption)
              .foregroundColor(themeColor(.textSecondary))
          }
        }
      }

      Section(header: Text("In-App Shortcut Bindings")) {
        Text(
          "Search, edit, or reset the in-app bindings below. Multiple bindings can be separated with commas."
        )
        .font(.caption)
        .foregroundColor(themeColor(.textSecondary))

        HStack(spacing: 8) {
          TextField("Filter shortcuts", text: $shortcutSearchText)
            .textFieldStyle(.roundedBorder)
          if !shortcutSearchText.isEmpty {
            Button("Clear") {
              shortcutSearchText = ""
            }
          }
        }
        .padding(.bottom, 2)

        if filteredShortcutCategories.isEmpty {
          Text("No in-app shortcuts match “\(shortcutSearchText)”.")
            .font(.caption)
            .foregroundColor(themeColor(.textSecondary))
        } else {
          ForEach(filteredShortcutCategories) { category in
            VStack(alignment: .leading, spacing: 8) {
              HStack {
                Text(category.title)
                  .font(.caption)
                  .foregroundColor(themeColor(.textSecondary))
                Spacer(minLength: 0)
                Text("\(category.actions.count)")
                  .font(.system(size: 11, weight: .medium, design: .monospaced))
                  .foregroundColor(themeColor(.textSecondary))
                  .padding(.horizontal, 8)
                  .padding(.vertical, 3)
                  .background(themeColor(.panelSurfaceElevated))
                  .clipShape(Capsule())
              }

              ForEach(category.actions) { action in
                shortcutBindingEditor(for: action)
              }
            }
            .padding(.vertical, 2)
          }
        }

        HStack {
          Spacer(minLength: 0)
          Button("Reset all in-app shortcuts to defaults") {
            preferences.resetConfigurableShortcutBindings()
          }
        }
      }

      Section(header: Text("Shortcut Reference")) {
        Text("Built-in navigation and command patterns that help when learning the app.")
          .font(.caption)
          .foregroundColor(themeColor(.textSecondary))

        if filteredShortcutReferenceGroups.isEmpty {
          Text("No reference shortcuts match “\(shortcutSearchText)”.")
            .font(.caption)
            .foregroundColor(themeColor(.textSecondary))
        } else {
          ForEach(filteredShortcutReferenceGroups) { group in
            VStack(alignment: .leading, spacing: 8) {
              Text(group.title)
                .font(.caption)
                .foregroundColor(themeColor(.textSecondary))
              ForEach(group.items) { item in
                shortcutReferenceRow(item)
              }
            }
            .padding(12)
            .background(themeColor(.panelSurface))
            .overlay(
              RoundedRectangle(cornerRadius: 10)
                .stroke(themeColor(.panelDivider), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
          }
        }
      }
    }
  }

  // MARK: - Pane-local helpers

  fileprivate var hotkeyConflictDetected: Bool {
    guard preferences.globalHotkeyEnabled, preferences.quickAddHotkeyEnabled else {
      return false
    }
    return
      preferences.globalHotkeyKeyCode == preferences.quickAddHotkeyKeyCode
      && preferences.globalHotkeyModifiers == preferences.quickAddHotkeyModifiers
  }

  fileprivate var configurableShortcutCategories: [ShortcutCategoryDescriptor] {
    let grouped = Dictionary(grouping: preferences.configurableShortcutActions, by: \.category)
    let order = ["Navigation", "Task Actions", "Entry & Commands", "Integrations & Timer"]
    return order.compactMap { category in
      guard let actions = grouped[category] else { return nil }
      return ShortcutCategoryDescriptor(title: category, actions: actions)
    }
  }

  fileprivate var filteredShortcutCategories: [ShortcutCategoryDescriptor] {
    let query = shortcutSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return configurableShortcutCategories }

    return configurableShortcutCategories.compactMap { category in
      let matchingActions = category.actions.filter {
        shortcutActionMatchesSearch($0, query: query)
      }
      guard !matchingActions.isEmpty else { return nil }
      return ShortcutCategoryDescriptor(title: category.title, actions: matchingActions)
    }
  }

  fileprivate var filteredShortcutReferenceGroups: [ShortcutReferenceGroup] {
    let query = shortcutSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return Self.shortcutReferenceGroups }

    return Self.shortcutReferenceGroups.compactMap { group in
      let matchingItems = group.items.filter {
        shortcutReferenceItemMatchesSearch($0, query: query)
      }
      guard !matchingItems.isEmpty else { return nil }
      return ShortcutReferenceGroup(title: group.title, items: matchingItems)
    }
  }

  fileprivate func configurableShortcutBinding(for action: ConfigurableShortcutAction)
    -> Binding<String>
  {
    Binding(
      get: { preferences.shortcutBinding(for: action) },
      set: { preferences.setShortcutBinding($0, for: action) }
    )
  }

  fileprivate func hotkeyCard(
    title: String,
    description: String,
    defaultDisplay: String,
    enabled: Binding<Bool>,
    keyCode: Binding<Int>,
    modifiers: Binding<Int>
  ) -> some View {
    HStack(alignment: .top, spacing: 12) {
      VStack(alignment: .leading, spacing: 6) {
        Toggle(isOn: enabled) {
          Text(title)
            .font(.system(size: 13, weight: .semibold))
        }
        Text(description)
          .font(.caption)
          .foregroundColor(themeColor(.textSecondary))
        Text("Default: \(defaultDisplay)")
          .font(.system(size: 11, weight: .medium, design: .monospaced))
          .foregroundColor(themeColor(.textSecondary))
      }
      Spacer()
      if enabled.wrappedValue {
        HotkeyRecorderField(keyCode: keyCode, modifiers: modifiers)
          .frame(width: 150, height: 22)
      } else {
        Text("Off")
          .font(.system(size: 11, weight: .medium, design: .monospaced))
          .foregroundColor(themeColor(.textSecondary))
          .padding(.horizontal, 10)
          .padding(.vertical, 4)
          .background(themeColor(.panelSurfaceElevated))
          .clipShape(Capsule())
      }
    }
    .padding(12)
    .background(themeColor(.panelSurface))
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .stroke(themeColor(.panelDivider), lineWidth: 1)
    )
    .clipShape(RoundedRectangle(cornerRadius: 10))
  }

  fileprivate func shortcutBindingEditor(for action: ConfigurableShortcutAction)
    -> some View
  {
    let isCustomized = isShortcutBindingCustomized(action)
    return VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(action.title)
          .font(.system(size: 13, weight: .semibold))
        if isCustomized {
          Text("Custom")
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(themeColor(.selectionForeground))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(themeColor(.selectionBackground))
            .clipShape(Capsule())
        }
        Spacer(minLength: 0)
      }

      HStack(spacing: 8) {
        TextField("Binding", text: configurableShortcutBinding(for: action))
          .textFieldStyle(.roundedBorder)
          .font(.system(size: 12, design: .monospaced))
        Button("Reset") {
          preferences.setShortcutBinding(action.defaultBinding, for: action)
        }
        .disabled(!isCustomized)
      }

      Text("Default: \(displayShortcutBinding(action.defaultBinding))")
        .font(.system(size: 11, design: .monospaced))
        .foregroundColor(themeColor(.textSecondary))
    }
    .padding(12)
    .background(themeColor(.panelSurface))
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .stroke(themeColor(.panelDivider), lineWidth: 1)
    )
    .clipShape(RoundedRectangle(cornerRadius: 10))
  }

  fileprivate func shortcutReferenceRow(_ item: ShortcutReferenceItem) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Text(item.keys)
          .font(.system(size: 11, weight: .medium, design: .monospaced))
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(themeColor(.panelSurfaceElevated))
          .clipShape(Capsule())
        Text(item.action)
          .font(.system(size: 12))
        Spacer(minLength: 0)
      }
      if let note = item.note, !note.isEmpty {
        Text(note)
          .font(.caption2)
          .foregroundColor(themeColor(.textSecondary))
          .padding(.leading, 4)
      }
    }
  }

  fileprivate func displayShortcutBinding(_ raw: String) -> String {
    raw.split(separator: ",")
      .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .joined(separator: " / ")
  }

  fileprivate func isShortcutBindingCustomized(_ action: ConfigurableShortcutAction)
    -> Bool
  {
    let current = preferences.shortcutBinding(for: action)
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    let defaultValue = action.defaultBinding
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    return !current.isEmpty && current != defaultValue
  }

  fileprivate func shortcutActionMatchesSearch(
    _ action: ConfigurableShortcutAction,
    query: String
  ) -> Bool {
    let normalizedQuery = query.lowercased()
    return action.title.lowercased().contains(normalizedQuery)
      || action.category.lowercased().contains(normalizedQuery)
      || action.defaultBinding.lowercased().contains(normalizedQuery)
      || preferences.shortcutBinding(for: action).lowercased().contains(normalizedQuery)
  }

  fileprivate func shortcutReferenceItemMatchesSearch(
    _ item: ShortcutReferenceItem, query: String
  ) -> Bool {
    let normalizedQuery = query.lowercased()
    return item.keys.lowercased().contains(normalizedQuery)
      || item.action.lowercased().contains(normalizedQuery)
      || (item.note?.lowercased().contains(normalizedQuery) ?? false)
  }

  fileprivate static let shortcutReferenceGroups: [ShortcutReferenceGroup] = [
    ShortcutReferenceGroup(
      title: "Navigation",
      items: [
        .init(keys: "j / ↓", action: "Next task", note: nil),
        .init(keys: "k / ↑", action: "Previous task", note: nil),
        .init(keys: "h / ←", action: "Exit to parent", note: nil),
        .init(keys: "l / →", action: "Enter subtasks", note: nil),
        .init(keys: "Shift+L", action: "Open list switch command", note: nil),
        .init(
          keys: "Ctrl+← / Ctrl+→", action: "Cycle root tabs", note: "All / Due / Tags / Priority"),
        .init(keys: "Ctrl+↑ / Ctrl+↓", action: "Cycle Due/Tag filter", note: nil),
        .init(
          keys: "q / w / e / r", action: "Jump to root tab", note: "All / Due / Tags / Priority"),
        .init(keys: "z / x / c / v / b / n / m", action: "Select root filter chip", note: nil),
      ]
    ),
    ShortcutReferenceGroup(
      title: "Task Actions",
      items: [
        .init(keys: "Space", action: "Mark task done", note: nil),
        .init(keys: "Shift+Space", action: "Invalidate task", note: nil),
        .init(keys: "Enter", action: "Add sibling", note: nil),
        .init(keys: "Shift+Enter / Tab", action: "Add child", note: nil),
        .init(keys: "Cmd+← / Shift+Tab", action: "Unindent selected task", note: nil),
        .init(keys: "Cmd+→", action: "Indent selected task", note: nil),
        .init(keys: "Cmd+↑ / Cmd+↓", action: "Move task", note: nil),
        .init(keys: "Delete", action: "Delete task", note: "Uses delete confirmation setting"),
        .init(keys: "u", action: "Undo last action", note: nil),
        .init(
          keys: "1-9 / Hyper+1-9 / = / -",
          action: "Set scoped priority / set absolute priority / send to back / clear",
          note: nil),
      ]
    ),
    ShortcutReferenceGroup(
      title: "Edit, Search, Commands",
      items: [
        .init(keys: "/", action: "Focus search", note: nil),
        .init(
          keys: "F2 / i / a", action: "Edit selected task",
          note: "F2 and a put cursor at end; i at start"),
        .init(keys: ": / ; / Cmd+K", action: "Open command palette", note: nil),
        .init(keys: "dd / dt", action: "Prefill due command", note: "due / due today"),
        .init(keys: "gt / gu", action: "Prefill tag command", note: "tag / untag"),
        .init(keys: "Esc", action: "Cancel input or close window", note: nil),
      ]
    ),
    ShortcutReferenceGroup(
      title: "Integrations & Timer",
      items: [
        .init(keys: "o / O", action: "Open in Obsidian / new Obsidian window", note: nil),
        .init(keys: "gc", action: "Create Google Calendar event from selected task", note: nil),
        .init(keys: "gg", action: "Open task link", note: nil),
        .init(keys: "t / p", action: "Toggle timer / pause-resume timer", note: nil),
        .init(keys: "Shift+A", action: "Quick Add at configured target", note: nil),
      ]
    ),
  ]
}
