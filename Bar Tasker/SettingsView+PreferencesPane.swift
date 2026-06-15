import SwiftUI

/// Preferences pane for `SettingsView` plus its Checkvist workspace summary
/// helpers and the auto/manual list-loading routines. Pulled out of the main
/// file as part of the Phase-4 settings split.
///
/// `fileprivate` is used on members that no other pane needs to reach into
/// (the connection-state summary subviews, the list-loading async helpers);
/// the pane itself stays `internal` so `SettingsView.selectedPaneContent` can
/// dispatch to it.
extension SettingsView {
  var preferencesPane: some View {
    Group {
      Section(header: Text("Checkvist")) {
        checkvistWorkspaceSummary
      }

      if checkvistManager.checkvistIntegrationEnabled {
      Section(header: Text("Merge Lists")) {
        VStack(alignment: .leading, spacing: 10) {
          Text("Copy open tasks from one Checkvist list into another.")
            .font(.caption)
            .foregroundColor(themeColor(.textSecondary))

          if checkvistManager.repository.availableLists.count >= 2 {
            Picker("From", selection: $mergeSourceListId) {
              ForEach(checkvistManager.repository.availableLists) { list in
                Text("\(list.name) (\(list.id))").tag(String(list.id))
              }
            }
            .pickerStyle(.menu)

            Picker("Into", selection: $mergeDestinationListId) {
              ForEach(checkvistManager.repository.availableLists) { list in
                Text("\(list.name) (\(list.id))").tag(String(list.id))
              }
            }
            .pickerStyle(.menu)

            HStack {
              Button("Use Active List as Destination") {
                mergeDestinationListId = checkvistManager.repository.listId
              }
              .disabled(checkvistManager.repository.listId.isEmpty)

              Button("Merge Open Tasks") {
                Task {
                  _ = await checkvistManager.syncService.mergeOpenTasksBetweenLists(
                    sourceListId: mergeSourceListId,
                    destinationListId: mergeDestinationListId
                  )
                }
              }
              .disabled(
                checkvistManager.repository.isLoading || isLoadingCheckvistLists || mergeSourceListId.isEmpty
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

  fileprivate var checkvistWorkspaceSummary: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: checkvistSummaryIconName)
          .font(.system(size: 14, weight: .semibold))
          .foregroundColor(checkvistSummaryTint)
          .frame(width: 18)
        VStack(alignment: .leading, spacing: 2) {
          Text(checkvistSummaryTitle)
            .font(.system(size: 12, weight: .semibold))
          Text(checkvistSummarySubtitle)
            .font(.caption)
            .foregroundColor(themeColor(.textSecondary))
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 0)
        Button(checkvistSummaryButtonTitle) {
          navState.select(pane: .plugins)
        }
      }

      if let errorMessage = checkvistManager.repository.errorMessage {
        Text(errorMessage)
          .foregroundColor(themeColor(.danger))
          .font(.caption)
      }
    }
    .padding(.top, 4)
  }

  fileprivate var checkvistSummaryIconName: String {
    if !checkvistManager.checkvistIntegrationEnabled { return "tray" }
    switch checkvistManager.checkvistConnectionState {
    case .disconnected: return "circle.dashed"
    case .connecting: return "arrow.triangle.2.circlepath"
    case .awaitingConnect: return "bolt.horizontal.circle"
    case .connected: return checkvistManager.canSyncRemotely ? "checkmark.circle.fill" : "tray"
    }
  }

  fileprivate var checkvistSummaryTint: Color {
    if !checkvistManager.checkvistIntegrationEnabled { return themeColor(.textSecondary) }
    switch checkvistManager.checkvistConnectionState {
    case .disconnected: return themeColor(.textSecondary)
    case .connecting: return themeColor(.link)
    case .awaitingConnect: return themeColor(.warning)
    case .connected:
      return checkvistManager.canSyncRemotely
        ? themeColor(.success) : themeColor(.textSecondary)
    }
  }

  fileprivate var checkvistSummaryTitle: String {
    if !checkvistManager.checkvistIntegrationEnabled { return "Offline mode" }
    switch checkvistManager.checkvistConnectionState {
    case .disconnected:
      return "Not connected"
    case .connecting:
      return "Connecting…"
    case .awaitingConnect:
      return "Credentials entered"
    case .connected:
      if let active = checkvistManager.repository.availableLists.first(where: {
        String($0.id) == checkvistManager.repository.listId
      }) {
        return "Syncing with “\(active.name)”"
      }
      if !checkvistManager.repository.listId.isEmpty {
        return "Syncing with list \(checkvistManager.repository.listId)"
      }
      return "Offline workspace active"
    }
  }

  fileprivate var checkvistSummarySubtitle: String {
    if !checkvistManager.checkvistIntegrationEnabled {
      return "Checkvist sync is turned off. Enable the plugin to sync your tasks."
    }
    switch checkvistManager.checkvistConnectionState {
    case .disconnected:
      return "Bar Tasker is running in offline mode. Connect Checkvist to sync your tasks."
    case .connecting:
      return "Signing in and loading your lists."
    case .awaitingConnect:
      return "Open Checkvist settings to finish connecting."
    case .connected(let listCount):
      let listWord = listCount == 1 ? "list" : "lists"
      return "Connected as \(checkvistManager.repository.username). \(listCount) \(listWord) available."
    }
  }

  fileprivate var checkvistSummaryButtonTitle: String {
    if !checkvistManager.checkvistIntegrationEnabled { return "Enable Checkvist" }
    switch checkvistManager.checkvistConnectionState {
    case .disconnected, .awaitingConnect: return "Set Up Checkvist"
    case .connecting, .connected: return "Checkvist Settings"
    }
  }

  @MainActor
  func autoloadCheckvistListsIfNeeded() async {
    guard !didAutoloadCheckvistLists else { return }
    didAutoloadCheckvistLists = true

    if checkvistManager.checkvistIntegrationEnabled, checkvistManager.canAttemptLogin,
      checkvistManager.repository.availableLists.isEmpty
    {
      await loadCheckvistLists(assignFirstIfMissing: false)
    } else {
      seedMergeSelectionsIfNeeded()
    }
  }

  @MainActor
  fileprivate func loadCheckvistLists(assignFirstIfMissing: Bool) async {
    isLoadingCheckvistLists = true
    defer { isLoadingCheckvistLists = false }
    _ = await checkvistManager.syncService.loadCheckvistLists(assignFirstIfMissing: assignFirstIfMissing)
    seedMergeSelectionsIfNeeded()
  }

  func seedMergeSelectionsIfNeeded() {
    guard !checkvistManager.repository.availableLists.isEmpty else {
      mergeSourceListId = ""
      mergeDestinationListId = ""
      return
    }

    let listIDs = Set(checkvistManager.repository.availableLists.map { String($0.id) })

    if !mergeDestinationListId.isEmpty, !listIDs.contains(mergeDestinationListId) {
      mergeDestinationListId = ""
    }
    if !mergeSourceListId.isEmpty, !listIDs.contains(mergeSourceListId) {
      mergeSourceListId = ""
    }

    if mergeDestinationListId.isEmpty {
      if listIDs.contains(checkvistManager.repository.listId) {
        mergeDestinationListId = checkvistManager.repository.listId
      } else if let first = checkvistManager.repository.availableLists.first {
        mergeDestinationListId = String(first.id)
      }
    }

    if mergeSourceListId.isEmpty || mergeSourceListId == mergeDestinationListId {
      if let source = checkvistManager.repository.availableLists.first(where: {
        String($0.id) != mergeDestinationListId
      }) {
        mergeSourceListId = String(source.id)
      }
    }
  }
}
