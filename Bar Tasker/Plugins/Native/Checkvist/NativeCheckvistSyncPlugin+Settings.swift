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
  @State private var uploadDestinationListId = ""

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

          HStack(spacing: 8) {
            Button("Connect & Load Lists") {
              Task { await loadLists(assignFirstIfMissing: false) }
            }
            .disabled(manager.isLoading || isLoadingLists || !manager.canAttemptLogin)

            Button("Reload Lists") {
              Task { await loadLists(assignFirstIfMissing: false) }
            }
            .disabled(manager.isLoading || isLoadingLists || !manager.canAttemptLogin)

            Spacer()
            if manager.isLoading || isLoadingLists {
              ProgressView()
                .scaleEffect(0.8)
            }
          }

          if manager.isUsingOfflineStore {
            Text(
              "Workspace selection stays in Preferences. Connecting here makes your Checkvist lists available there."
            )
            .font(.caption)
            .foregroundColor(.secondary)
          } else if let activeList = manager.availableLists.first(where: {
            String($0.id) == manager.listId
          }) {
            Text("Current workspace in Preferences: \(activeList.name) (\(activeList.id))")
              .font(.caption)
              .foregroundColor(.secondary)
          } else if !manager.listId.isEmpty {
            Text("Current workspace in Preferences: list ID \(manager.listId)")
              .font(.caption)
              .foregroundColor(.secondary)
          }

          if let errorMessage = manager.errorMessage {
            Text(errorMessage)
              .foregroundColor(.red)
              .font(.caption)
          } else if !manager.isLoading && !manager.isUsingOfflineStore
            && manager.currentTaskText != "Loading..."
            && manager.currentTaskText != "Error"
            && manager.currentTaskText != "Login failed."
            && manager.currentTaskText != "List ID not set."
            && manager.currentTaskText != "Authentication required."
          {
            Text("Connected. Top Task: \(manager.currentTaskText)")
              .foregroundColor(.green)
              .font(.caption)
          }
        }
        .padding(.top, 4)
      }
      Section(header: Text("Upload Offline Tasks")) {
        VStack(alignment: .leading, spacing: 10) {
          Text(
            "Copy the tasks from your local offline workspace into a Checkvist list."
          )
          .font(.caption)
          .foregroundColor(.secondary)

          Text(
            manager.offlineOpenTaskCount == 1
              ? "1 offline task is ready to upload."
              : "\(manager.offlineOpenTaskCount) offline tasks are ready to upload."
          )
          .font(.caption)
          .foregroundColor(.secondary)

          if !manager.availableLists.isEmpty {
            Picker("Destination List", selection: $uploadDestinationListId) {
              ForEach(manager.availableLists) { list in
                Text("\(list.name) (\(list.id))").tag(String(list.id))
              }
            }
            .pickerStyle(.menu)

            HStack {
              Button("Use Active List") {
                uploadDestinationListId = manager.listId
              }
              .disabled(manager.listId.isEmpty)

              Button("Upload Offline Tasks") {
                Task {
                  _ = await manager.uploadOfflineTasksToCheckvist(
                    destinationListId: uploadDestinationListId
                  )
                }
              }
              .disabled(
                manager.isLoading || isLoadingLists || uploadDestinationListId.isEmpty
                  || manager.offlineOpenTaskCount == 0 || !manager.canAttemptLogin
              )
            }
          } else if manager.canAttemptLogin {
            Text("Load your Checkvist lists to choose an upload destination.")
              .font(.caption)
              .foregroundColor(.secondary)
          } else {
            Text("Add your Checkvist credentials in Preferences, then load lists here.")
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
      seedUploadDestinationIfNeeded()
    }
    .onChange(of: manager.availableLists.map(\.id)) { _, _ in
      seedUploadDestinationIfNeeded()
    }
    .onChange(of: manager.listId) { _, _ in
      if !manager.listId.isEmpty {
        uploadDestinationListId = manager.listId
      }
    }
  }

  @MainActor
  private func loadLists(assignFirstIfMissing: Bool) async {
    isLoadingLists = true
    defer { isLoadingLists = false }
    _ = await manager.loadCheckvistLists(assignFirstIfMissing: assignFirstIfMissing)
    seedUploadDestinationIfNeeded()
  }
  private func seedUploadDestinationIfNeeded() {
    guard !manager.availableLists.isEmpty else {
      uploadDestinationListId = ""
      return
    }

    let listIDs = Set(manager.availableLists.map { String($0.id) })

    if !uploadDestinationListId.isEmpty, !listIDs.contains(uploadDestinationListId) {
      uploadDestinationListId = ""
    }

    if uploadDestinationListId.isEmpty {
      if listIDs.contains(manager.listId) {
        uploadDestinationListId = manager.listId
      } else if let first = manager.availableLists.first {
        uploadDestinationListId = String(first.id)
      }
    }
  }
}
