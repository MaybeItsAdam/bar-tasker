import SwiftUI

@MainActor
extension NativeCheckvistSyncPlugin: PluginSettingsPageProviding {
  var settingsIconSystemName: String { "checkmark.circle" }

  func makeSettingsView(manager: AppCoordinator) -> AnyView {
    AnyView(CheckvistSyncPluginSettingsView(manager: manager))
  }
}

private let checkvistAPIKeyURL = URL(string: "https://checkvist.com/auth/profile")!

private struct CheckvistSyncPluginSettingsView: View {
  var manager: AppCoordinator
  @State private var isLoadingLists = false
  @State private var didAutoloadLists = false
  @State private var uploadDestinationListId = ""

  private var connectionState: CheckvistConnectionState {
    manager.checkvistConnectionState
  }

  private var isBusy: Bool {
    manager.isLoading || isLoadingLists
  }

  private var connectButtonLabel: String {
    switch connectionState {
    case .connecting: return "Connecting…"
    case .connected: return "Reconnect"
    case .disconnected, .awaitingConnect: return "Connect"
    }
  }

  var body: some View {
    @Bindable var manager = manager
    Group {
      Section(header: Text("Checkvist Sync")) {
        Toggle(
          "Enable Checkvist sync",
          isOn: Binding(
            get: { manager.checkvistIntegrationEnabled },
            set: { manager.checkvistIntegrationEnabled = $0 }
          )
        )
        Text(
          "When disabled, Bar Tasker runs offline and your Checkvist credentials and list selection are preserved for when you re-enable it."
        )
        .font(.caption)
        .foregroundColor(.secondary)
      }

      if manager.checkvistIntegrationEnabled {
      Section(header: Text("Connection")) {
        VStack(alignment: .leading, spacing: 14) {
          connectionStatusBanner

          stepHeader(number: 1, title: "Enter your Checkvist credentials")
          VStack(alignment: .leading, spacing: 8) {
            Text("Email")
              .font(.caption)
              .foregroundColor(.secondary)
            TextField("", text: $manager.username, prompt: Text("email@example.com"))
              .textFieldStyle(.roundedBorder)
              .labelsHidden()
              .autocorrectionDisabled()

            HStack(spacing: 6) {
              Text("OpenAPI key")
                .font(.caption)
                .foregroundColor(.secondary)
              Spacer(minLength: 0)
              Link("Where do I find this?", destination: checkvistAPIKeyURL)
                .font(.caption)
            }
            SecureField("", text: $manager.remoteKey, prompt: Text("Paste your key"))
              .textFieldStyle(.roundedBorder)
              .labelsHidden()
          }

          stepHeader(number: 2, title: "Connect")
          HStack(spacing: 8) {
            Button(connectButtonLabel) {
              Task { await loadLists(assignFirstIfMissing: false) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isBusy || !manager.canAttemptLogin)

            if isBusy {
              ProgressView().scaleEffect(0.7)
            }
            Spacer(minLength: 0)
          }

          if case .connected(let listCount) = connectionState {
            stepHeader(number: 3, title: "Choose a workspace")
            VStack(alignment: .leading, spacing: 6) {
              Picker("", selection: activeWorkspaceBinding) {
                Text("Offline workspace").tag("")
                if !manager.listId.isEmpty && !isCurrentListInAvailableLists {
                  Text("Current list (\(manager.listId))").tag(manager.listId)
                }
                ForEach(manager.availableLists) { list in
                  Text(list.name).tag(String(list.id))
                }
              }
              .labelsHidden()
              .pickerStyle(.menu)

              Text(workspaceCaption(listCount: listCount))
                .font(.caption)
                .foregroundColor(.secondary)
            }
          }

          if let errorMessage = manager.errorMessage {
            errorBanner(message: errorMessage) {
              manager.errorMessage = nil
            }
          }
        }
        .padding(.top, 4)
      }

      if case .connected = connectionState {
        uploadOfflineTasksSection
      }
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

  @ViewBuilder
  private var connectionStatusBanner: some View {
    let style = statusStyle(for: connectionState)
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: style.iconName)
        .font(.system(size: 14, weight: .semibold))
        .foregroundColor(style.tint)
        .frame(width: 18)
      VStack(alignment: .leading, spacing: 2) {
        Text(style.title)
          .font(.system(size: 12, weight: .semibold))
        Text(style.message)
          .font(.caption)
          .foregroundColor(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
    .padding(10)
    .background(style.tint.opacity(0.08))
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(style.tint.opacity(0.3), lineWidth: 1)
    )
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }

  private func errorBanner(message: String, dismiss: @escaping () -> Void) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundColor(.red)
        .frame(width: 18)
      Text(message)
        .font(.caption)
        .foregroundColor(.primary)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
      Button {
        dismiss()
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 9, weight: .bold))
          .frame(width: 16, height: 16)
      }
      .buttonStyle(.plain)
      .foregroundColor(.secondary)
    }
    .padding(10)
    .background(Color.red.opacity(0.08))
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(Color.red.opacity(0.3), lineWidth: 1)
    )
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }

  private func stepHeader(number: Int, title: String) -> some View {
    HStack(spacing: 8) {
      Text("\(number)")
        .font(.system(size: 10, weight: .bold, design: .rounded))
        .foregroundColor(.white)
        .frame(width: 18, height: 18)
        .background(Circle().fill(Color.accentColor))
      Text(title)
        .font(.system(size: 12, weight: .semibold))
    }
  }

  private struct StatusStyle {
    let iconName: String
    let tint: Color
    let title: String
    let message: String
  }

  private func statusStyle(for state: CheckvistConnectionState) -> StatusStyle {
    switch state {
    case .disconnected:
      return StatusStyle(
        iconName: "circle.dashed",
        tint: .secondary,
        title: "Not connected",
        message: "Enter your Checkvist email and OpenAPI key below to sync. You can keep working offline without connecting."
      )
    case .connecting:
      return StatusStyle(
        iconName: "arrow.triangle.2.circlepath",
        tint: .accentColor,
        title: "Connecting…",
        message: "Signing in and loading your lists."
      )
    case .awaitingConnect:
      return StatusStyle(
        iconName: "bolt.horizontal.circle",
        tint: .orange,
        title: "Credentials entered",
        message: "Click Connect to sign in and load your lists."
      )
    case .connected(let listCount):
      let email = manager.username
      let listWord = listCount == 1 ? "list" : "lists"
      return StatusStyle(
        iconName: "checkmark.circle.fill",
        tint: .green,
        title: "Connected as \(email)",
        message: "\(listCount) \(listWord) available. Pick one below."
      )
    }
  }

  private var activeWorkspaceBinding: Binding<String> {
    Binding(
      get: { manager.listId },
      set: { newValue in
        Task { await manager.switchCheckvistList(to: newValue) }
      }
    )
  }

  private var isCurrentListInAvailableLists: Bool {
    manager.availableLists.contains { String($0.id) == manager.listId }
  }

  private func workspaceCaption(listCount: Int) -> String {
    if manager.isUsingOfflineStore {
      return "You’re using the offline workspace. Pick a Checkvist list above to start syncing."
    }
    if let active = manager.availableLists.first(where: { String($0.id) == manager.listId }) {
      return "Bar Tasker is syncing with “\(active.name)”."
    }
    return "Bar Tasker is syncing with list ID \(manager.listId)."
  }

  private var uploadOfflineTasksSection: some View {
    Section(header: Text("Upload Offline Tasks")) {
      VStack(alignment: .leading, spacing: 10) {
        Text("Copy tasks created in the offline workspace into a Checkvist list.")
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
              isBusy || uploadDestinationListId.isEmpty
                || manager.offlineOpenTaskCount == 0 || !manager.canAttemptLogin
            )
          }
        }
      }
      .padding(.top, 4)
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
