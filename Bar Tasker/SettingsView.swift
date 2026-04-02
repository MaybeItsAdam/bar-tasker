import AppKit
import SwiftUI

// swiftlint:disable file_length
// MARK: - Carbon modifier constants (avoid importing Carbon in SwiftUI file)
private let carbonCmdKey = 0x0100
private let carbonShiftKey = 0x0200
private let carbonOptionKey = 0x0800
private let carbonControlKey = 0x1000

// MARK: - Hotkey Recorder

class HotkeyNSTextField: NSTextField {
  var isRecording = false
  var onRecord: ((Int, Int) -> Void)?
  var displayString: String = ""

  override var acceptsFirstResponder: Bool { true }

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
  }

  override func becomeFirstResponder() -> Bool {
    isRecording = true
    stringValue = "Type shortcut\u{2026}"
    return super.becomeFirstResponder()
  }

  override func resignFirstResponder() -> Bool {
    isRecording = false
    stringValue = displayString
    return super.resignFirstResponder()
  }

  override func keyDown(with event: NSEvent) {
    guard isRecording else { return }

    if event.keyCode == 53 {  // Escape = cancel
      window?.makeFirstResponder(nil)
      return
    }

    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    var carbonMods = 0
    if flags.contains(.command) { carbonMods |= carbonCmdKey }
    if flags.contains(.shift) { carbonMods |= carbonShiftKey }
    if flags.contains(.option) { carbonMods |= carbonOptionKey }
    if flags.contains(.control) { carbonMods |= carbonControlKey }

    // Require at least one modifier for a global hotkey
    guard carbonMods != 0 else { return }

    onRecord?(Int(event.keyCode), carbonMods)
    window?.makeFirstResponder(nil)
  }
}

struct HotkeyRecorderField: NSViewRepresentable {
  @Binding var keyCode: Int
  @Binding var modifiers: Int

  func makeNSView(context: Context) -> HotkeyNSTextField {
    let tf = HotkeyNSTextField()
    tf.isEditable = false
    tf.isSelectable = false
    tf.alignment = .center
    tf.font = .systemFont(ofSize: 12)
    tf.bezelStyle = .roundedBezel
    tf.displayString = Self.displayString(keyCode: keyCode, modifiers: modifiers)
    tf.stringValue = tf.displayString
    tf.onRecord = { code, mods in
      keyCode = code
      modifiers = mods
    }
    return tf
  }

  func updateNSView(_ tf: HotkeyNSTextField, context: Context) {
    tf.displayString = Self.displayString(keyCode: keyCode, modifiers: modifiers)
    if !tf.isRecording {
      tf.stringValue = tf.displayString
    }
    tf.onRecord = { code, mods in
      keyCode = code
      modifiers = mods
    }
  }

  static func displayString(keyCode: Int, modifiers: Int) -> String {
    var mods = ""
    if modifiers & carbonControlKey != 0 { mods += "\u{2303}" }
    if modifiers & carbonOptionKey != 0 { mods += "\u{2325}" }
    if modifiers & carbonShiftKey != 0 { mods += "\u{21E7}" }
    if modifiers & carbonCmdKey != 0 { mods += "\u{2318}" }

    let keyNames: [Int: String] = [
      0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
      8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
      16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
      23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
      30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
      36: "\u{21A9}", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";",
      43: ",", 44: "/", 45: "N", 46: "M", 47: ".",
      48: "\u{21E5}", 49: "Space", 50: "`", 51: "\u{232B}",
      96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9",
      103: "F11", 109: "F10", 111: "F12", 118: "F4", 120: "F2", 122: "F1",
      123: "\u{2190}", 124: "\u{2192}", 125: "\u{2193}", 126: "\u{2191}",
    ]

    let keyName = keyNames[keyCode] ?? "Key\(keyCode)"
    return mods + keyName
  }
}

// MARK: - Settings View

// swiftlint:disable file_length type_body_length
struct SettingsView: View {
  private struct ShortcutReferenceItem: Identifiable {
    let keys: String
    let action: String
    let note: String?
    var id: String { "\(keys)|\(action)" }
  }

  private struct ShortcutReferenceGroup: Identifiable {
    let title: String
    let items: [ShortcutReferenceItem]
    var id: String { title }
  }

  private struct ShortcutCategoryDescriptor: Identifiable {
    let title: String
    let actions: [BarTaskerManager.ConfigurableShortcutAction]
    var id: String { title }
  }

  private struct BuiltInPluginSettingsDescriptor: Identifiable {
    let pluginIdentifier: String
    let displayName: String
    let settingsIconSystemName: String
    let plugin: any PluginSettingsPageProviding
    var id: String { pluginIdentifier }

    var shortName: String {
      if displayName.hasPrefix("Native ") {
        return String(displayName.dropFirst("Native ".count))
      }
      return displayName
    }
  }

  private struct PluginCardDescriptor: Identifiable {
    enum Source {
      case builtIn(BuiltInPluginSettingsDescriptor)
      case user(UserPluginManager.InstalledUserPlugin)
    }

    let id: String
    let title: String
    let subtitle: String
    let settingsIconSystemName: String
    let source: Source
  }

  @EnvironmentObject var checkvistManager: BarTaskerManager
  @EnvironmentObject var navState: SettingsNavState
  @State private var selectedPluginCardID: String?
  @State private var themeJSONDraft: String = ""
  @State private var themeJSONStatusMessage: String = ""
  @State private var themeJSONStatusIsError: Bool = false

  private func themeColor(_ token: BarTaskerThemeColorToken) -> Color {
    checkvistManager.themeColor(for: token)
  }

  var body: some View {
    paneContent {
      selectedPaneContent
    }
    .tint(checkvistManager.themeAccentColor)
    .task {
      syncSelectedPluginCardIfNeeded()
      if themeJSONDraft.isEmpty {
        themeJSONDraft = checkvistManager.exportThemeJSON(prettyPrinted: true)
      }
    }
    .onChange(of: pluginCardIDs) { _, _ in
      syncSelectedPluginCardIfNeeded()
    }
  }

  @ViewBuilder
  private var selectedPaneContent: some View {
    switch navState.selectedPane {
    case .preferences:
      preferencesPane
    case .keybindings:
      keybindingsPane
    case .theme:
      themePane
    case .plugins:
      pluginsPane
    #if DEBUG
      case .debug:
        debugPane
    #endif
    }
  }

  private var builtInPluginSettingsPages: [BuiltInPluginSettingsDescriptor] {
    checkvistManager.activePluginSettingsPages.map {
      BuiltInPluginSettingsDescriptor(
        pluginIdentifier: $0.pluginIdentifier,
        displayName: $0.displayName,
        settingsIconSystemName: $0.settingsIconSystemName,
        plugin: $0
      )
    }
  }

  private var pluginCards: [PluginCardDescriptor] {
    builtInPluginSettingsPages.map { page in
      PluginCardDescriptor(
        id: "builtin:\(page.pluginIdentifier)",
        title: page.shortName,
        subtitle: pluginStatusLabel(for: page.pluginIdentifier),
        settingsIconSystemName: page.settingsIconSystemName,
        source: .builtIn(page)
      )
    }
  }

  private var userPluginCards: [PluginCardDescriptor] {
    checkvistManager.userPluginManager.sortedInstalledPlugins.map { plugin in
      let enabled = checkvistManager.userPluginManager.isPluginEnabled(plugin.manifest.id)
      return PluginCardDescriptor(
        id: "user:\(plugin.manifest.id)",
        title: plugin.manifest.name,
        subtitle: enabled ? "Enabled" : "Disabled",
        settingsIconSystemName: "puzzlepiece",
        source: .user(plugin)
      )
    }
  }

  private var allPluginCards: [PluginCardDescriptor] { pluginCards + userPluginCards }

  private var pluginCardIDs: [String] {
    allPluginCards.map(\.id)
  }

  private var selectedPluginCard: PluginCardDescriptor? {
    if let selectedPluginCardID,
      let selected = allPluginCards.first(where: { $0.id == selectedPluginCardID })
    {
      return selected
    }
    return pluginCards.first
  }

  private var pluginsPane: some View {
    HStack(spacing: 0) {
      // Sidebar
      VStack(spacing: 0) {
        List(selection: $selectedPluginCardID) {
          Section("Built-in") {
            ForEach(pluginCards) { card in
              pluginListRow(for: card).tag(card.id as String?)
            }
          }
          if !userPluginCards.isEmpty {
            Section("User Plugins") {
              ForEach(userPluginCards) { card in
                pluginListRow(for: card).tag(card.id as String?)
              }
            }
          }
        }
        .listStyle(.sidebar)

        Divider()
        HStack(spacing: 6) {
          Button {
            checkvistManager.userPluginManager.installPluginPackageInteractively()
          } label: {
            Label("Install Plugin", systemImage: "plus")
          }
          Button {
            checkvistManager.userPluginManager.openPluginsFolder()
          } label: {
            Label("Open Folder", systemImage: "folder")
          }
        }
        .buttonStyle(.borderless)
        .labelStyle(.iconOnly)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(minWidth: 180, idealWidth: 200, maxWidth: 240)

      Divider()

      // Detail
      Group {
        if let selectedPluginCard {
          switch selectedPluginCard.source {
          case .builtIn:
            Form { pluginSettingsView(for: selectedPluginCard) }
              .formStyle(.grouped)
          case .user(let plugin):
            userPluginDetailView(for: plugin)
          }
        } else {
          ContentUnavailableView(
            "Select a Plugin",
            systemImage: "puzzlepiece.extension",
            description: Text("Choose a plugin from the sidebar to view its settings.")
          )
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func pluginListRow(for card: PluginCardDescriptor) -> some View {
    Label {
      Text(card.title).lineLimit(1)
    } icon: {
      Image(systemName: card.settingsIconSystemName)
    }
  }

  private func userPluginDetailView(for plugin: UserPluginManager.InstalledUserPlugin) -> some View {
    let manager = checkvistManager.userPluginManager
    return Form {
      Section(header: Text(plugin.manifest.name)) {
        if let summary = plugin.manifest.summary, !summary.isEmpty {
          Text(summary)
            .foregroundStyle(.secondary)
        }
        LabeledContent("Version", value: plugin.manifest.version ?? "—")
        LabeledContent("ID", value: plugin.manifest.id)
        Toggle(
          "Enabled",
          isOn: Binding(
            get: { manager.isPluginEnabled(plugin.manifest.id) },
            set: { manager.setPluginEnabled($0, pluginIdentifier: plugin.manifest.id) }
          )
        )
      }
      Section {
        Button("Reveal in Finder") {
          manager.revealPluginInFinder(plugin)
        }
        Button("Remove Plugin", role: .destructive) {
          manager.removePlugin(plugin)
        }
      }
    }
    .formStyle(.grouped)
    .id(plugin.id)
  }

  private func pluginStatusLabel(for pluginIdentifier: String) -> String {
    switch pluginIdentifier {
    case "native.checkvist.sync":
      return "Active"
    case "native.obsidian.integration":
      return checkvistManager.obsidianIntegrationEnabled ? "Enabled" : "Disabled"
    case "native.google.calendar.integration":
      return checkvistManager.googleCalendarIntegrationEnabled ? "Enabled" : "Disabled"
    case "native.mcp.integration":
      return checkvistManager.mcpIntegrationEnabled ? "Enabled" : "Disabled"
    default:
      return "Built-in plugin"
    }
  }

  @ViewBuilder
  private func paneContent<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    if navState.selectedPane == .plugins {
      content()
        .padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      Form {
        content()
      }
      .formStyle(.grouped)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private var preferencesPane: some View {
    Section(header: Text("Preferences")) {
      Toggle("Confirm before deleting tasks", isOn: $checkvistManager.confirmBeforeDelete)
      if #available(macOS 13.0, *) {
        Toggle("Launch at login", isOn: $checkvistManager.launchAtLogin)
      }

      VStack(alignment: .leading) {
        Text("Max Menu Bar Width: \(Int(checkvistManager.maxTitleWidth))px")
        Slider(value: $checkvistManager.maxTitleWidth, in: 50...800, step: 10)
      }
      .padding(.top, 4)

      VStack(alignment: .leading, spacing: 6) {
        Text("Timer position in menu bar")
        Picker("", selection: $checkvistManager.timerBarLeading) {
          Text("After task").tag(false)
          Text("Before task").tag(true)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .disabled(checkvistManager.timerMode != .visible)
      }
      .padding(.top, 4)

      VStack(alignment: .leading, spacing: 6) {
        Text("Timer mode")
        Picker("", selection: $checkvistManager.timerMode) {
          Text("Visible").tag(BarTaskerManager.TimerMode.visible)
          Text("Hidden").tag(BarTaskerManager.TimerMode.hidden)
          Text("Disabled").tag(BarTaskerManager.TimerMode.disabled)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
      }
      .padding(.top, 4)
    }
  }

  private var keybindingsPane: some View {
    Group {
      Section(header: Text("Configurable Hotkeys")) {
        hotkeyRow(
          title: "Global hotkey",
          description: "Shows/hides the task popover from anywhere.",
          enabled: $checkvistManager.globalHotkeyEnabled,
          keyCode: $checkvistManager.globalHotkeyKeyCode,
          modifiers: $checkvistManager.globalHotkeyModifiers
        )
        hotkeyRow(
          title: "Quick Add hotkey",
          description: "Opens the quick add prompt at your configured location.",
          enabled: $checkvistManager.quickAddHotkeyEnabled,
          keyCode: $checkvistManager.quickAddHotkeyKeyCode,
          modifiers: $checkvistManager.quickAddHotkeyModifiers
        )

        if hotkeyConflictDetected {
          Text("Global hotkey and Quick Add hotkey currently conflict.")
            .font(.caption)
            .foregroundColor(themeColor(.danger))
        }

        Button("Reset hotkeys to defaults") {
          checkvistManager.globalHotkeyKeyCode = 49  // Space
          checkvistManager.globalHotkeyModifiers = 0x0800  // Option
          checkvistManager.quickAddHotkeyKeyCode = 11  // B
          checkvistManager.quickAddHotkeyModifiers = 0x0A00  // Shift + Option
        }
      }

      Section(header: Text("Quick Add Target")) {
        VStack(alignment: .leading, spacing: 6) {
          Text("Quick Add location")
          Picker("", selection: $checkvistManager.quickAddLocationMode) {
            Text("Default (List root)").tag(BarTaskerManager.QuickAddLocationMode.defaultRoot)
            Text("Specific task ID").tag(BarTaskerManager.QuickAddLocationMode.specificParentTask)
          }
          .labelsHidden()
          .pickerStyle(.segmented)

          if checkvistManager.quickAddLocationMode == .specificParentTask {
            HStack {
              TextField("Parent task ID", text: $checkvistManager.quickAddSpecificParentTaskId)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 180)
              Button("Use selected task") {
                checkvistManager.setQuickAddSpecificLocationToCurrentTask()
              }
              .disabled(checkvistManager.currentTask == nil)
            }
            Text("Quick Add creates new tasks as children of this task ID.")
              .font(.caption)
              .foregroundColor(themeColor(.textSecondary))
          }
        }
      }

      Section(header: Text("In-App Shortcut Bindings")) {
        Text("Bindings are comma-separated tokens (examples: `cmd+k`, `shift+a`, `down`, `dd`).")
          .font(.caption)
          .foregroundColor(themeColor(.textSecondary))

        ForEach(configurableShortcutCategories) { category in
          VStack(alignment: .leading, spacing: 8) {
            Text(category.title)
              .font(.caption)
              .foregroundColor(themeColor(.textSecondary))

            ForEach(category.actions) { action in
              HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(action.title)
                  .frame(width: 250, alignment: .leading)
                TextField("", text: configurableShortcutBinding(for: action))
                  .textFieldStyle(.roundedBorder)
                  .font(.system(size: 12, design: .monospaced))
              }
            }
          }
          .padding(.vertical, 2)
        }

        Button("Reset all in-app shortcuts to defaults") {
          checkvistManager.resetConfigurableShortcutBindings()
        }
      }

      Section(header: Text("Shortcut Reference")) {
        ForEach(Self.shortcutReferenceGroups) { group in
          VStack(alignment: .leading, spacing: 6) {
            Text(group.title)
              .font(.caption)
              .foregroundColor(themeColor(.textSecondary))
            ForEach(group.items) { item in
              HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(item.keys)
                  .font(.system(size: 11, weight: .medium, design: .monospaced))
                  .frame(width: 180, alignment: .leading)
                Text(item.action)
                  .font(.system(size: 12))
                Spacer(minLength: 0)
              }
              if let note = item.note, !note.isEmpty {
                Text(note)
                  .font(.caption2)
                  .foregroundColor(themeColor(.textSecondary))
                  .padding(.leading, 192)
              }
            }
          }
          .padding(.vertical, 3)
        }
      }
    }
  }

  private var themePane: some View {
    Section(header: Text("Theme")) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Appearance")
        Picker("", selection: $checkvistManager.appTheme) {
          Text("System").tag(BarTaskerManager.AppTheme.system)
          Text("Light").tag(BarTaskerManager.AppTheme.light)
          Text("Dark").tag(BarTaskerManager.AppTheme.dark)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
      }
      .padding(.top, 4)

      Text("Applies immediately to the app and preferences window.")
        .font(.caption)
        .foregroundColor(themeColor(.textSecondary))

      Divider()
        .padding(.vertical, 6)

      VStack(alignment: .leading, spacing: 8) {
        Text("Accent color")
        Picker("", selection: $checkvistManager.themeAccentPreset) {
          ForEach(BarTaskerManager.ThemeAccentPreset.allCases) { preset in
            Text(preset.title).tag(preset)
          }
        }
        .labelsHidden()
        .pickerStyle(.menu)

        HStack(spacing: 8) {
          ForEach(BarTaskerManager.ThemeAccentPreset.allCases.filter { $0 != .custom }) { preset in
            Button {
              checkvistManager.themeAccentPreset = preset
            } label: {
              Circle()
                .fill(BarTaskerThemeColorCodec.color(from: preset.hex) ?? .accentColor)
                .frame(width: 18, height: 18)
                .overlay(
                  Circle().stroke(
                    checkvistManager.themeAccentPreset == preset
                      ? themeColor(.textPrimary).opacity(0.55) : Color.clear,
                    lineWidth: 1.5
                  )
                )
            }
            .buttonStyle(.plain)
          }
          Spacer(minLength: 0)
          Button("Reset") {
            checkvistManager.resetThemeCustomization()
          }
          .disabled(
            checkvistManager.themeAccentPreset == .blue
              && checkvistManager.themeCustomAccentHex
                == BarTaskerManager.ThemeAccentPreset.blue.hex
          )
        }

        ColorPicker(
          "Custom Accent",
          selection: Binding(
            get: { checkvistManager.themeAccentColor },
            set: { checkvistManager.setCustomThemeAccentColor($0) }
          ),
          supportsOpacity: false
        )

        if checkvistManager.themeAccentPreset == .custom {
          TextField("#RRGGBB", text: $checkvistManager.themeCustomAccentHex)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12, design: .monospaced))
        } else {
          Text("Using \(checkvistManager.themeAccentPreset.title) accent")
            .font(.caption)
            .foregroundColor(themeColor(.textSecondary))
        }
      }

      Divider()
        .padding(.vertical, 6)

      VStack(alignment: .leading, spacing: 8) {
        Text("Semantic colors")
        Text("These tokens drive popover, focus, selection, text, and status colors.")
          .font(.caption)
          .foregroundColor(themeColor(.textSecondary))

        ForEach(checkvistManager.configurableThemeColorTokens) { token in
          HStack(spacing: 10) {
            Text(token.title)
              .frame(maxWidth: .infinity, alignment: .leading)
            Text(checkvistManager.themeColorHex(for: token))
              .font(.system(size: 11, weight: .medium, design: .monospaced))
              .foregroundColor(themeColor(.textSecondary))
              .frame(width: 88, alignment: .trailing)
            ColorPicker(
              "",
              selection: Binding(
                get: { checkvistManager.themeColor(for: token) },
                set: { checkvistManager.setThemeColor(token, color: $0) }
              ),
              supportsOpacity: false
            )
            .labelsHidden()
            .frame(width: 72)
            Button("Reset") {
              checkvistManager.resetThemeColorOverride(token)
            }
            .disabled(checkvistManager.themeColorTokenHexOverrides[token.rawValue] == nil)
          }
        }

        HStack {
          Button("Reset all semantic overrides") {
            checkvistManager.resetAllThemeColorOverrides()
          }
          .disabled(!checkvistManager.hasThemeColorOverrides)
          Spacer(minLength: 0)
        }
      }

      Divider()
        .padding(.vertical, 6)

      VStack(alignment: .leading, spacing: 8) {
        Text("Theme JSON")
        Text(
          "Import/export full theme state (appearance, accent, and semantic color overrides)."
        )
        .font(.caption)
        .foregroundColor(themeColor(.textSecondary))

        TextEditor(text: $themeJSONDraft)
          .font(.system(size: 12, design: .monospaced))
          .frame(minHeight: 140, maxHeight: 180)
          .overlay(
            RoundedRectangle(cornerRadius: 6)
              .stroke(themeColor(.panelDivider), lineWidth: 1)
          )

        HStack(spacing: 8) {
          Button("Load current") {
            themeJSONDraft = checkvistManager.exportThemeJSON(prettyPrinted: true)
            themeJSONStatusMessage = ""
            themeJSONStatusIsError = false
          }
          Button("Import JSON") {
            do {
              try checkvistManager.importThemeJSON(themeJSONDraft)
              themeJSONDraft = checkvistManager.exportThemeJSON(prettyPrinted: true)
              themeJSONStatusMessage = "Theme imported."
              themeJSONStatusIsError = false
            } catch {
              themeJSONStatusMessage =
                error.localizedDescription.isEmpty
                ? "Theme import failed." : error.localizedDescription
              themeJSONStatusIsError = true
            }
          }
          Button("Copy current JSON") {
            let payload = checkvistManager.exportThemeJSON(prettyPrinted: true)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(payload, forType: .string)
            themeJSONStatusMessage = "Current theme JSON copied to clipboard."
            themeJSONStatusIsError = false
          }
        }

        if !themeJSONStatusMessage.isEmpty {
          Text(themeJSONStatusMessage)
            .font(.caption)
            .foregroundColor(themeJSONStatusIsError ? themeColor(.danger) : themeColor(.success))
        }
      }
    }
  }

  #if DEBUG
    private var debugPane: some View {
      Section(header: Text("Debug")) {
        Text("Shortcut: Cmd+Shift+K toggles keychain mode for development.")
          .font(.caption)
          .foregroundColor(themeColor(.textSecondary))
        Button("Reset onboarding state") {
          checkvistManager.resetOnboardingForDebug()
        }
        .foregroundColor(themeColor(.danger))
      }
    }
  #endif

  @ViewBuilder
  private func pluginSettingsView(for card: PluginCardDescriptor) -> some View {
    switch card.source {
    case .builtIn(let page):
      page.plugin.makeSettingsView(manager: checkvistManager)
    case .user:
      EmptyView()
    }
  }

  private func syncSelectedPluginCardIfNeeded() {
    let activeIdentifiers = Set(pluginCardIDs)
    guard !activeIdentifiers.isEmpty else {
      selectedPluginCardID = nil
      return
    }
    if let selectedPluginCardID, activeIdentifiers.contains(selectedPluginCardID) {
      return
    }
    selectedPluginCardID = pluginCards.first?.id
  }

  private var hotkeyConflictDetected: Bool {
    guard checkvistManager.globalHotkeyEnabled, checkvistManager.quickAddHotkeyEnabled else {
      return false
    }
    return
      checkvistManager.globalHotkeyKeyCode == checkvistManager.quickAddHotkeyKeyCode
      && checkvistManager.globalHotkeyModifiers == checkvistManager.quickAddHotkeyModifiers
  }

  private var configurableShortcutCategories: [ShortcutCategoryDescriptor] {
    let grouped = Dictionary(grouping: checkvistManager.configurableShortcutActions, by: \.category)
    let order = ["Navigation", "Task Actions", "Entry & Commands", "Integrations & Timer"]
    return order.compactMap { category in
      guard let actions = grouped[category] else { return nil }
      return ShortcutCategoryDescriptor(title: category, actions: actions)
    }
  }

  private func configurableShortcutBinding(for action: BarTaskerManager.ConfigurableShortcutAction)
    -> Binding<String>
  {
    Binding(
      get: { checkvistManager.shortcutBinding(for: action) },
      set: { checkvistManager.setShortcutBinding($0, for: action) }
    )
  }

  private func hotkeyRow(
    title: String,
    description: String,
    enabled: Binding<Bool>,
    keyCode: Binding<Int>,
    modifiers: Binding<Int>
  ) -> some View {
    HStack(alignment: .top) {
      VStack(alignment: .leading, spacing: 4) {
        Toggle(title, isOn: enabled)
        Text(description)
          .font(.caption)
          .foregroundColor(themeColor(.textSecondary))
      }
      Spacer()
      if enabled.wrappedValue {
        HotkeyRecorderField(keyCode: keyCode, modifiers: modifiers)
          .frame(width: 150, height: 22)
      }
    }
  }

  private static let shortcutReferenceGroups: [ShortcutReferenceGroup] = [
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
        .init(keys: "Shift+Tab", action: "Unindent selected task", note: nil),
        .init(keys: "Cmd+↑ / Cmd+↓", action: "Move task", note: nil),
        .init(keys: "Delete", action: "Delete task", note: "Uses delete confirmation setting"),
        .init(keys: "u", action: "Undo last action", note: nil),
        .init(keys: "1-9 / = / -", action: "Set priority / send to back / clear", note: nil),
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
        .init(keys: "gc", action: "Add selected task to Google Calendar", note: nil),
        .init(keys: "gg", action: "Open task link", note: nil),
        .init(keys: "t / p", action: "Toggle timer / pause-resume timer", note: nil),
        .init(keys: "Shift+A", action: "Quick Add at configured target", note: nil),
      ]
    ),
  ]
}
// swiftlint:enable type_body_length
