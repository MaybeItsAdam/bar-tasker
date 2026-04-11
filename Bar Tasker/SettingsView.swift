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
    let actions: [ConfigurableShortcutAction]
    var id: String { title }
  }

  private struct BuiltInPluginSettingsDescriptor: Identifiable {
    let pluginIdentifier: String
    let displayName: String
    let pluginDescription: String
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
    let description: String
    let settingsIconSystemName: String
    let source: Source
  }

  @Environment(BarTaskerCoordinator.self) var checkvistManager
  @Environment(SettingsNavState.self) var navState
  @State private var selectedPluginCardID: String?
  @State private var themeJSONDraft: String = ""
  @State private var themeJSONStatusMessage: String = ""
  @State private var themeJSONStatusIsError: Bool = false
  @State private var isLoadingCheckvistLists = false
  @State private var didAutoloadCheckvistLists = false
  @State private var mergeSourceListId = ""
  @State private var mergeDestinationListId = ""
  @State private var shortcutSearchText = ""

  private var preferences: PreferencesManager {
    checkvistManager.preferences
  }

  private func preferenceBinding<T>(_ keyPath: ReferenceWritableKeyPath<PreferencesManager, T>)
    -> Binding<T>
  {
    Binding(
      get: { preferences[keyPath: keyPath] },
      set: { preferences[keyPath: keyPath] = $0 }
    )
  }

  private func themeColor(_ token: BarTaskerThemeColorToken) -> Color {
    preferences.themeColor(for: token)
  }

  var body: some View {
    paneContent {
      selectedPaneContent
    }
    .tint(preferences.themeAccentColor)
    .task {
      syncSelectedPluginCardIfNeeded()
      if themeJSONDraft.isEmpty {
        themeJSONDraft = preferences.exportThemeJSON(prettyPrinted: true)
      }
      await autoloadCheckvistListsIfNeeded()
    }
    .onChange(of: pluginCardIDs) { _, _ in
      syncSelectedPluginCardIfNeeded()
    }
    .onChange(of: checkvistManager.availableLists.map(\.id)) { _, _ in
      seedMergeSelectionsIfNeeded()
    }
    .onChange(of: checkvistManager.listId) { _, _ in
      if !checkvistManager.listId.isEmpty {
        mergeDestinationListId = checkvistManager.listId
      }
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
    case .kanban:
      KanbanSettingsView()
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
        pluginDescription: $0.pluginDescription,
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
        description: page.pluginDescription,
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
        description: plugin.manifest.summary ?? "User-installed plugin",
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
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: card.settingsIconSystemName)
        .frame(width: 18, alignment: .center)
        .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(card.title)
            .lineLimit(1)
          Spacer(minLength: 6)
          Text(card.subtitle)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        Text(card.description)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
    }
  }

  private func userPluginDetailView(for plugin: UserPluginManager.InstalledUserPlugin) -> some View
  {
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
      return checkvistManager.integrations.obsidianIntegrationEnabled ? "Enabled" : "Disabled"
    case "native.google.calendar.integration":
      return checkvistManager.integrations.googleCalendarIntegrationEnabled ? "Enabled" : "Disabled"
    case "native.mcp.integration":
      return checkvistManager.integrations.mcpIntegrationEnabled ? "Enabled" : "Disabled"
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
    Group {
      Section(header: Text("Workspace")) {
        VStack(alignment: .leading, spacing: 10) {
          if checkvistManager.canAttemptLogin || !checkvistManager.availableLists.isEmpty {
            HStack(spacing: 8) {
              Button("Reload Lists") {
                Task { await loadCheckvistLists(assignFirstIfMissing: false) }
              }
              .disabled(
                checkvistManager.isLoading || isLoadingCheckvistLists
                  || !checkvistManager.canAttemptLogin)

              Spacer()
              if checkvistManager.isLoading || isLoadingCheckvistLists {
                ProgressView()
                  .scaleEffect(0.8)
              }
            }
          }

          Picker("Workspace", selection: activeCheckvistWorkspaceBinding) {
            Text("Offline Workspace").tag("")
            if !checkvistManager.listId.isEmpty && !isCurrentListInAvailableLists {
              Text("Current List ID (\(checkvistManager.listId))").tag(checkvistManager.listId)
            }
            ForEach(checkvistManager.availableLists) { list in
              Text("\(list.name) (\(list.id))").tag(String(list.id))
            }
          }
          .pickerStyle(.menu)

          Text(checkvistWorkspaceCaption)
            .font(.caption)
            .foregroundColor(themeColor(.textSecondary))

          if let errorMessage = checkvistManager.errorMessage {
            Text(errorMessage)
              .foregroundColor(themeColor(.danger))
              .font(.caption)
          } else if checkvistManager.canAttemptLogin || !checkvistManager.availableLists.isEmpty {
            Text(checkvistConnectionStatusText)
              .foregroundColor(checkvistStatusColor)
              .font(.caption)
          }
        }
        .padding(.top, 4)
      }

      Section(header: Text("Merge Lists")) {
        VStack(alignment: .leading, spacing: 10) {
          Text("Copy open tasks from one Checkvist list into another.")
            .font(.caption)
            .foregroundColor(themeColor(.textSecondary))

          if checkvistManager.availableLists.count >= 2 {
            Picker("From", selection: $mergeSourceListId) {
              ForEach(checkvistManager.availableLists) { list in
                Text("\(list.name) (\(list.id))").tag(String(list.id))
              }
            }
            .pickerStyle(.menu)

            Picker("Into", selection: $mergeDestinationListId) {
              ForEach(checkvistManager.availableLists) { list in
                Text("\(list.name) (\(list.id))").tag(String(list.id))
              }
            }
            .pickerStyle(.menu)

            HStack {
              Button("Use Active List as Destination") {
                mergeDestinationListId = checkvistManager.listId
              }
              .disabled(checkvistManager.listId.isEmpty)

              Button("Merge Open Tasks") {
                Task {
                  _ = await checkvistManager.mergeOpenTasksBetweenLists(
                    sourceListId: mergeSourceListId,
                    destinationListId: mergeDestinationListId
                  )
                }
              }
              .disabled(
                checkvistManager.isLoading || isLoadingCheckvistLists || mergeSourceListId.isEmpty
                  || mergeDestinationListId.isEmpty
                  || mergeSourceListId == mergeDestinationListId
                  || !checkvistManager.canAttemptLogin
              )
            }
          } else if checkvistManager.canAttemptLogin {
            Text("Connect and load at least two Checkvist lists to enable merging.")
              .font(.caption)
              .foregroundColor(themeColor(.textSecondary))
          } else {
            Text("Add your Checkvist account above, then load lists to enable merging.")
              .font(.caption)
              .foregroundColor(themeColor(.textSecondary))
          }
        }
        .padding(.top, 4)
      }

      Section(header: Text("Preferences")) {
        Toggle("Confirm before deleting tasks", isOn: preferenceBinding(\.confirmBeforeDelete))
        if #available(macOS 13.0, *) {
          Toggle("Launch at login", isOn: preferenceBinding(\.launchAtLogin))
        }

        VStack(alignment: .leading) {
          Text("Max Menu Bar Width: \(Int(preferences.maxTitleWidth))px")
          Slider(value: preferenceBinding(\.maxTitleWidth), in: 50...800, step: 10)
        }
        .padding(.top, 4)

        VStack(alignment: .leading, spacing: 6) {
          Text("Timer position in menu bar")
          Picker(
            "",
            selection: Binding(
              get: { checkvistManager.timer.timerBarLeading },
              set: { checkvistManager.timer.timerBarLeading = $0 }
            )
          ) {
            Text("After task").tag(false)
            Text("Before task").tag(true)
          }
          .labelsHidden()
          .pickerStyle(.segmented)
          .disabled(checkvistManager.timer.timerMode != .visible)
        }
        .padding(.top, 4)

        VStack(alignment: .leading, spacing: 6) {
          Text("Timer mode")
          Picker(
            "",
            selection: Binding(
              get: { checkvistManager.timer.timerMode },
              set: { checkvistManager.timer.timerMode = $0 }
            )
          ) {
            Text("Visible").tag(TimerMode.visible)
            Text("Hidden").tag(TimerMode.hidden)
            Text("Disabled").tag(TimerMode.disabled)
          }
          .labelsHidden()
          .pickerStyle(.segmented)
        }
        .padding(.top, 4)
      }
      
      Section(header: Text("View Modes Order")) {
        VStack(alignment: .leading, spacing: 10) {
          Text("Drag to reorder the view mode tabs")
            .font(.caption)
            .foregroundColor(themeColor(.textSecondary))
          
          ModeOrderList(manager: checkvistManager)
        }
        .padding(.top, 4)
      }

      Section(header: Text("Named Times")) {
        VStack(alignment: .leading, spacing: 10) {
          Text("Customize what hour named times resolve to when scheduling tasks.")
            .font(.caption)
            .foregroundColor(themeColor(.textSecondary))

          NamedTimePickerRow(
            label: "Morning",
            hour: preferenceBinding(\.namedTimeMorningHour)
          )
          NamedTimePickerRow(
            label: "Afternoon",
            hour: preferenceBinding(\.namedTimeAfternoonHour)
          )
          NamedTimePickerRow(
            label: "Evening",
            hour: preferenceBinding(\.namedTimeEveningHour)
          )
          NamedTimePickerRow(
            label: "EOD / COB",
            hour: preferenceBinding(\.namedTimeEodHour)
          )
        }
        .padding(.top, 4)
      }
    }
  }

  private var activeCheckvistWorkspaceBinding: Binding<String> {
    Binding(
      get: { checkvistManager.listId },
      set: { newValue in
        Task { await switchCheckvistWorkspace(to: newValue) }
      }
    )
  }

  private var isCurrentListInAvailableLists: Bool {
    checkvistManager.availableLists.contains { String($0.id) == checkvistManager.listId }
  }

  private var checkvistWorkspaceCaption: String {
    if checkvistManager.isUsingOfflineStore {
      if checkvistManager.availableLists.isEmpty {
        return "You’re using the local offline workspace. Load your Checkvist lists to switch."
      }
      return
        "You’re using the local offline workspace. Your Checkvist lists are available in the picker."
    }

    if let activeList = checkvistManager.availableLists.first(where: {
      String($0.id) == checkvistManager.listId
    }) {
      return "Bar Tasker is currently working against “\(activeList.name)”."
    }

    return "Bar Tasker is currently using Checkvist list ID \(checkvistManager.listId)."
  }

  private var checkvistConnectionStatusText: String {
    if checkvistManager.isUsingOfflineStore {
      return "Offline workspace active."
    }
    if checkvistManager.canAttemptLogin || !checkvistManager.availableLists.isEmpty {
      return "Checkvist lists are available."
    }
    return "Connect Checkvist in Plugins to load lists."
  }

  private var checkvistStatusColor: Color {
    if checkvistManager.isUsingOfflineStore {
      return themeColor(.textSecondary)
    }
    return checkvistManager.canAttemptLogin ? themeColor(.success) : themeColor(.textSecondary)
  }

  @MainActor
  private func autoloadCheckvistListsIfNeeded() async {
    guard !didAutoloadCheckvistLists else { return }
    didAutoloadCheckvistLists = true

    if checkvistManager.canAttemptLogin && checkvistManager.availableLists.isEmpty {
      await loadCheckvistLists(assignFirstIfMissing: false)
    } else {
      seedMergeSelectionsIfNeeded()
    }
  }

  @MainActor
  private func loadCheckvistLists(assignFirstIfMissing: Bool) async {
    isLoadingCheckvistLists = true
    defer { isLoadingCheckvistLists = false }
    _ = await checkvistManager.loadCheckvistLists(assignFirstIfMissing: assignFirstIfMissing)
    seedMergeSelectionsIfNeeded()
  }

  @MainActor
  private func switchCheckvistWorkspace(to newValue: String) async {
    await checkvistManager.switchCheckvistList(to: newValue)
    seedMergeSelectionsIfNeeded()
  }

  private func seedMergeSelectionsIfNeeded() {
    guard !checkvistManager.availableLists.isEmpty else {
      mergeSourceListId = ""
      mergeDestinationListId = ""
      return
    }

    let listIDs = Set(checkvistManager.availableLists.map { String($0.id) })

    if !mergeDestinationListId.isEmpty, !listIDs.contains(mergeDestinationListId) {
      mergeDestinationListId = ""
    }
    if !mergeSourceListId.isEmpty, !listIDs.contains(mergeSourceListId) {
      mergeSourceListId = ""
    }

    if mergeDestinationListId.isEmpty {
      if listIDs.contains(checkvistManager.listId) {
        mergeDestinationListId = checkvistManager.listId
      } else if let first = checkvistManager.availableLists.first {
        mergeDestinationListId = String(first.id)
      }
    }

    if mergeSourceListId.isEmpty || mergeSourceListId == mergeDestinationListId {
      if let source = checkvistManager.availableLists.first(where: {
        String($0.id) != mergeDestinationListId
      }) {
        mergeSourceListId = String(source.id)
      }
    }
  }

  private var keybindingsPane: some View {
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

  private var themePane: some View {
    Section(header: Text("Theme")) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Appearance")
        Picker("", selection: preferenceBinding(\.appTheme)) {
          Text("System").tag(AppTheme.system)
          Text("Light").tag(AppTheme.light)
          Text("Dark").tag(AppTheme.dark)
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
        Picker("", selection: preferenceBinding(\.themeAccentPreset)) {
          ForEach(ThemeAccentPreset.allCases) { preset in
            Text(preset.title).tag(preset)
          }
        }
        .labelsHidden()
        .pickerStyle(.menu)

        HStack(spacing: 8) {
          ForEach(ThemeAccentPreset.allCases.filter { $0 != .custom }) { preset in
            Button {
              preferences.themeAccentPreset = preset
            } label: {
              Circle()
                .fill(BarTaskerThemeColorCodec.color(from: preset.hex) ?? .accentColor)
                .frame(width: 18, height: 18)
                .overlay(
                  Circle().stroke(
                    preferences.themeAccentPreset == preset
                      ? themeColor(.textPrimary).opacity(0.55) : Color.clear,
                    lineWidth: 1.5
                  )
                )
            }
            .buttonStyle(.plain)
          }
          Spacer(minLength: 0)
          Button("Reset") {
            preferences.resetThemeCustomization()
          }
          .disabled(
            preferences.themeAccentPreset == .blue
              && preferences.themeCustomAccentHex
                == ThemeAccentPreset.blue.hex
          )
        }

        ColorPicker(
          "Custom Accent",
          selection: Binding(
            get: { preferences.themeAccentColor },
            set: { preferences.setCustomThemeAccentColor($0) }
          ),
          supportsOpacity: false
        )

        if preferences.themeAccentPreset == .custom {
          TextField("#RRGGBB", text: preferenceBinding(\.themeCustomAccentHex))
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12, design: .monospaced))
        } else {
          Text("Using \(preferences.themeAccentPreset.title) accent")
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

        ForEach(preferences.configurableThemeColorTokens) { token in
          HStack(spacing: 10) {
            Text(token.title)
              .frame(maxWidth: .infinity, alignment: .leading)
            Text(preferences.themeColorHex(for: token))
              .font(.system(size: 11, weight: .medium, design: .monospaced))
              .foregroundColor(themeColor(.textSecondary))
              .frame(width: 88, alignment: .trailing)
            ColorPicker(
              "",
              selection: Binding(
                get: { preferences.themeColor(for: token) },
                set: { preferences.setThemeColor(token, color: $0) }
              ),
              supportsOpacity: false
            )
            .labelsHidden()
            .frame(width: 72)
            Button("Reset") {
              preferences.resetThemeColorOverride(token)
            }
            .disabled(preferences.themeColorTokenHexOverrides[token.rawValue] == nil)
          }
        }

        HStack {
          Button("Reset all semantic overrides") {
            preferences.resetAllThemeColorOverrides()
          }
          .disabled(!preferences.hasThemeColorOverrides)
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
            themeJSONDraft = preferences.exportThemeJSON(prettyPrinted: true)
            themeJSONStatusMessage = ""
            themeJSONStatusIsError = false
          }
          Button("Import JSON") {
            do {
              try preferences.importThemeJSON(themeJSONDraft)
              themeJSONDraft = preferences.exportThemeJSON(prettyPrinted: true)
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
            let payload = preferences.exportThemeJSON(prettyPrinted: true)
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
      Section(header: Text(card.title)) {
        VStack(alignment: .leading, spacing: 6) {
          Text(page.pluginDescription)
            .foregroundStyle(.secondary)
          Text("Status: \(card.subtitle)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.top, 2)
      }
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
    guard preferences.globalHotkeyEnabled, preferences.quickAddHotkeyEnabled else {
      return false
    }
    return
      preferences.globalHotkeyKeyCode == preferences.quickAddHotkeyKeyCode
      && preferences.globalHotkeyModifiers == preferences.quickAddHotkeyModifiers
  }

  private var configurableShortcutCategories: [ShortcutCategoryDescriptor] {
    let grouped = Dictionary(grouping: preferences.configurableShortcutActions, by: \.category)
    let order = ["Navigation", "Task Actions", "Entry & Commands", "Integrations & Timer"]
    return order.compactMap { category in
      guard let actions = grouped[category] else { return nil }
      return ShortcutCategoryDescriptor(title: category, actions: actions)
    }
  }

  private var filteredShortcutCategories: [ShortcutCategoryDescriptor] {
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

  private var filteredShortcutReferenceGroups: [ShortcutReferenceGroup] {
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

  private func configurableShortcutBinding(for action: ConfigurableShortcutAction)
    -> Binding<String>
  {
    Binding(
      get: { preferences.shortcutBinding(for: action) },
      set: { preferences.setShortcutBinding($0, for: action) }
    )
  }

  private func hotkeyCard(
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

  private func shortcutBindingEditor(for action: ConfigurableShortcutAction)
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

  private func shortcutReferenceRow(_ item: ShortcutReferenceItem) -> some View {
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

  private func displayShortcutBinding(_ raw: String) -> String {
    raw.split(separator: ",")
      .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .joined(separator: " / ")
  }

  private func isShortcutBindingCustomized(_ action: ConfigurableShortcutAction)
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

  private func shortcutActionMatchesSearch(
    _ action: ConfigurableShortcutAction,
    query: String
  ) -> Bool {
    let normalizedQuery = query.lowercased()
    return action.title.lowercased().contains(normalizedQuery)
      || action.category.lowercased().contains(normalizedQuery)
      || action.defaultBinding.lowercased().contains(normalizedQuery)
      || preferences.shortcutBinding(for: action).lowercased().contains(normalizedQuery)
  }

  private func shortcutReferenceItemMatchesSearch(_ item: ShortcutReferenceItem, query: String)
    -> Bool
  {
    let normalizedQuery = query.lowercased()
    return item.keys.lowercased().contains(normalizedQuery)
      || item.action.lowercased().contains(normalizedQuery)
      || (item.note?.lowercased().contains(normalizedQuery) ?? false)
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
        .init(keys: "gc", action: "Create Google Calendar event from selected task", note: nil),
        .init(keys: "gg", action: "Open task link", note: nil),
        .init(keys: "t / p", action: "Toggle timer / pause-resume timer", note: nil),
        .init(keys: "Shift+A", action: "Quick Add at configured target", note: nil),
      ]
    ),
  ]
}
// swiftlint:enable type_body_length

private struct ModeOrderList: View {
  var manager: BarTaskerCoordinator
  @State private var orderedModes: [RootTaskView] = []

  var body: some View {
    List {
      ForEach(orderedModes, id: \.rawValue) { mode in
        HStack(spacing: 8) {
          Image(systemName: "line.3.horizontal")
            .foregroundColor(.secondary)
          Text(mode.title)
          Spacer(minLength: 0)
          if manager.rootTaskView == mode {
            Text("Current")
              .font(.caption2)
              .foregroundColor(.secondary)
          }
        }
        .padding(.vertical, 2)
      }
      .onMove(perform: moveModes)
    }
    .listStyle(.inset)
    .frame(minHeight: 150, maxHeight: 210)
    .onAppear(perform: syncModeOrder)
  }

  private func syncModeOrder() {
    orderedModes = manager.orderedRootTaskViews
  }

  private func moveModes(from source: IndexSet, to destination: Int) {
    orderedModes.move(fromOffsets: source, toOffset: destination)
    manager.saveRootTaskViewOrder(orderedModes)
  }
}

private struct NamedTimePickerRow: View {
  let label: String
  @Binding var hour: Int

  private let hours = Array(0...23)

  private func hourLabel(_ h: Int) -> String {
    let components = DateComponents(hour: h, minute: 0)
    let date = Calendar.current.date(from: components) ?? Date()
    let formatter = DateFormatter()
    formatter.dateFormat = "h a"
    return formatter.string(from: date)
  }

  var body: some View {
    HStack {
      Text(label)
        .frame(width: 80, alignment: .leading)
      Picker("", selection: $hour) {
        ForEach(hours, id: \.self) { h in
          Text(hourLabel(h)).tag(h)
        }
      }
      .labelsHidden()
      .pickerStyle(.menu)
      .frame(width: 100)
    }
  }
}
