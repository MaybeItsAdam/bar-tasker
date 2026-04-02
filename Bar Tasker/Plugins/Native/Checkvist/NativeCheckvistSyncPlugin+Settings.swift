import SwiftUI

@MainActor
extension NativeCheckvistSyncPlugin: PluginSettingsPageProviding {
  var settingsIconSystemName: String { "checkmark.circle" }

  func makeSettingsView(manager: BarTaskerManager) -> AnyView {
    AnyView(CheckvistSyncPluginSettingsView(manager: manager))
  }
}

private struct CheckvistSyncPluginSettingsView: View {
  @ObservedObject var manager: BarTaskerManager
  @State private var isLoadingLists = false
  @State private var didAutoloadLists = false
  @State private var newListName = ""
  @State private var mergeSourceListId = ""
  @State private var mergeDestinationListId = ""

  var body: some View {
    Group {
      Section(header: Text("Checkvist Sync")) {
        VStack(alignment: .leading, spacing: 10) {
          Text("Username (Email)")
          TextField("", text: $manager.username, prompt: Text("email@example.com"))
            .textFieldStyle(.roundedBorder)
            .labelsHidden()
            .autocorrectionDisabled()

          Text("Remote API Key")
          SecureField("", text: $manager.remoteKey)
            .textFieldStyle(.roundedBorder)

          Text("List ID")
          TextField("", text: $manager.listId)
            .textFieldStyle(.roundedBorder)
            .labelsHidden()
            .autocorrectionDisabled()

          HStack(spacing: 8) {
            Button("Connect & Load Lists") {
              Task { await loadLists(assignFirstIfMissing: true) }
            }
            .disabled(manager.isLoading || isLoadingLists || !manager.canAttemptLogin)

            if !manager.availableLists.isEmpty {
              Button("Reload Lists") {
                Task { await loadLists(assignFirstIfMissing: false) }
              }
              .disabled(manager.isLoading || isLoadingLists)
            }

            Spacer()
            if manager.isLoading || isLoadingLists {
              ProgressView()
                .scaleEffect(0.8)
            }
          }

          if !manager.availableLists.isEmpty {
            Picker("Active List", selection: $manager.listId) {
              ForEach(manager.availableLists) { list in
                Text("\(list.name) (\(list.id))").tag(String(list.id))
              }
            }
            .pickerStyle(.menu)
          } else {
            Text(
              "Tip: Click \"Connect & Load Lists\" to choose a list by name. You only need List ID as fallback."
            )
            .font(.caption)
            .foregroundColor(.secondary)
          }

          if let errorMessage = manager.errorMessage {
            Text(errorMessage)
              .foregroundColor(.red)
              .font(.caption)
          } else if !manager.isLoading && manager.currentTaskText != "Loading..."
            && manager.currentTaskText != "Error"
            && manager.currentTaskText != "Login failed."
            && manager.currentTaskText != "List ID not set."
            && manager.currentTaskText != "Authentication required."
          {
            Text("Connected. Top Task: \(manager.currentTaskText)")
              .foregroundColor(.green)
              .font(.caption)
          }

          Divider()

          Text("Dedicated List")
            .font(.subheadline)
            .fontWeight(.semibold)
          Text(
            "Create a dedicated list for Bar Tasker to avoid conflicts with your existing Checkvist setup."
          )
          .font(.caption)
          .foregroundColor(.secondary)

          HStack {
            TextField("Bar Tasker", text: $newListName)
              .textFieldStyle(.roundedBorder)

            Button("Use Suggested") {
              newListName = suggestedListName
            }
            .disabled(manager.isLoading || isLoadingLists)

            Button("Create & Switch") {
              Task { await createAndSwitchList() }
            }
            .disabled(
              manager.isLoading || isLoadingLists
                || newListName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !manager.canAttemptLogin
            )
          }
        }
        .padding(.top, 4)
      }

      Section(header: Text("Merge Lists")) {
        VStack(alignment: .leading, spacing: 10) {
          Text("Merge open tasks from one list into another.")
            .font(.caption)
            .foregroundColor(.secondary)

          if manager.availableLists.count >= 2 {
            Picker("From", selection: $mergeSourceListId) {
              ForEach(manager.availableLists) { list in
                Text("\(list.name) (\(list.id))").tag(String(list.id))
              }
            }
            .pickerStyle(.menu)

            Picker("Into", selection: $mergeDestinationListId) {
              ForEach(manager.availableLists) { list in
                Text("\(list.name) (\(list.id))").tag(String(list.id))
              }
            }
            .pickerStyle(.menu)

            HStack {
              Button("Use Current List as Destination") {
                mergeDestinationListId = manager.listId
              }
              .disabled(manager.listId.isEmpty)

              Button("Merge Open Tasks") {
                Task {
                  _ = await manager.mergeOpenTasksBetweenLists(
                    sourceListId: mergeSourceListId,
                    destinationListId: mergeDestinationListId
                  )
                }
              }
              .disabled(
                manager.isLoading || isLoadingLists || mergeSourceListId.isEmpty
                  || mergeDestinationListId.isEmpty
                  || mergeSourceListId == mergeDestinationListId
                  || !manager.canAttemptLogin
              )
            }
          } else {
            Text("Load at least two lists to enable merging.")
              .font(.caption)
              .foregroundColor(.secondary)
          }
        }
        .padding(.top, 4)
      }
    }
    .task {
      guard !didAutoloadLists else { return }
      didAutoloadLists = true
      if manager.canAttemptLogin && manager.availableLists.isEmpty {
        await loadLists(assignFirstIfMissing: false)
      }
      seedMergeSelectionsIfNeeded()
      if newListName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        newListName = suggestedListName
      }
    }
    .onChange(of: manager.availableLists.map(\.id)) { _, _ in
      seedMergeSelectionsIfNeeded()
    }
    .onChange(of: manager.listId) { _, _ in
      if !manager.listId.isEmpty {
        mergeDestinationListId = manager.listId
      }
    }
  }

  @MainActor
  private func loadLists(assignFirstIfMissing: Bool) async {
    isLoadingLists = true
    defer { isLoadingLists = false }
    let success = await manager.login()
    guard success else { return }
    await manager.fetchLists()
    if assignFirstIfMissing, manager.listId.isEmpty,
      let first = manager.availableLists.first
    {
      manager.selectList(first)
    }
    seedMergeSelectionsIfNeeded()
  }

  private var suggestedListName: String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return "Bar Tasker \(formatter.string(from: Date()))"
  }

  @MainActor
  private func createAndSwitchList() async {
    let success = await manager.createCheckvistListAndSwitch(name: newListName)
    guard success else { return }
    await loadLists(assignFirstIfMissing: false)
    mergeDestinationListId = manager.listId
  }

  private func seedMergeSelectionsIfNeeded() {
    guard !manager.availableLists.isEmpty else {
      mergeSourceListId = ""
      mergeDestinationListId = ""
      return
    }

    let listIDs = Set(manager.availableLists.map { String($0.id) })

    if !mergeDestinationListId.isEmpty, !listIDs.contains(mergeDestinationListId) {
      mergeDestinationListId = ""
    }
    if !mergeSourceListId.isEmpty, !listIDs.contains(mergeSourceListId) {
      mergeSourceListId = ""
    }

    if mergeDestinationListId.isEmpty {
      if listIDs.contains(manager.listId) {
        mergeDestinationListId = manager.listId
      } else if let first = manager.availableLists.first {
        mergeDestinationListId = String(first.id)
      }
    }

    if mergeSourceListId.isEmpty || mergeSourceListId == mergeDestinationListId {
      if let source = manager.availableLists.first(where: {
        String($0.id) != mergeDestinationListId
      }) {
        mergeSourceListId = String(source.id)
      }
    }
  }
}
