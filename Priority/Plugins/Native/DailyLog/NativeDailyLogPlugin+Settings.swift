import SwiftUI

@MainActor
extension NativeDailyLogPlugin: PluginSettingsPageProviding {
  var settingsIconSystemName: String { "chart.bar.xaxis" }

  func sidebarStatusLabel(manager: AppCoordinator) -> String {
    manager.dailyLog.dailyLogEnabled ? "Enabled" : "Disabled"
  }

  func makeSettingsView(manager: AppCoordinator) -> AnyView {
    AnyView(DailyLogPluginSettingsView(manager: manager))
  }
}

private struct DailyLogPluginSettingsView: View {
  var manager: AppCoordinator

  @State private var fileNameFormat: String = ""
  @State private var folderFormat: String = ""
  @State private var previewDate = Date()

  var body: some View {
    let dailyLog = manager.dailyLog

    Section(header: Text("Daily Log Plugin")) {
      Text(
        "Completions, focus sessions and the day's plan are always recorded locally — "
          + "that's what the Daily view reads. This section controls the Obsidian half."
      )
      .font(.caption)
      .foregroundColor(.secondary)

      dailiesEditor

      Picker("Day starts at", selection: rolloverBinding) {
        ForEach(0..<24, id: \.self) { hour in
          Text(String(format: "%02d:00", hour)).tag(hour)
        }
      }
      Text(
        "Work finished before this hour counts towards the previous day. "
          + "Midnight is rarely the right answer."
      )
      .font(.caption)
      .foregroundColor(.secondary)

      // Configuration comes before the switch that acts on it. Hiding the folder
      // picker behind the enable toggle would mean turning writing on before
      // there is anywhere to write to.
      VStack(alignment: .leading, spacing: 8) {
        Text("Dailies Folder")
        if dailyLog.dailiesFolderPath.isEmpty {
          Text("No folder selected")
            .foregroundColor(.secondary)
            .font(.caption)
        } else {
          Text(dailyLog.dailiesFolderPath)
            .font(.caption)
            .textSelection(.enabled)
        }

        HStack {
          Button("Choose Folder") { dailyLog.chooseDailiesFolder() }
          if !dailyLog.dailiesFolderPath.isEmpty {
            Button("Clear") { dailyLog.clearDailiesFolder() }
          }
          Spacer()
        }
      }
      .padding(.top, 4)

      VStack(alignment: .leading, spacing: 8) {
        Text("Note Naming")
        // Saved as you type rather than on submit: clicking away from a
        // settings field without pressing Return is normal, and silently
        // discarding the format would point the writer at the wrong file.
        TextField("File name format", text: $fileNameFormat)
          .onChange(of: fileNameFormat) { _, _ in saveFormat() }
        TextField("Subfolder format (optional)", text: $folderFormat)
          .onChange(of: folderFormat) { _, _ in saveFormat() }
        Text("Today's note would be: \(previewPath)")
          .font(.caption)
          .foregroundColor(.secondary)
          .textSelection(.enabled)
        Text(
          "Date patterns, e.g. yyyy-MM-dd for the file and yyyy/MM to nest by year and month. "
            + "Leave the subfolder empty for a flat folder."
        )
        .font(.caption)
        .foregroundColor(.secondary)
      }
      .padding(.top, 4)

      Toggle("Create missing notes", isOn: createsMissingNotesBinding)
      Text(
        createsMissingNotesBinding.wrappedValue
          ? "Priority will create the note if it doesn't exist yet. Turn this off if a "
            + "template builds your dailies — otherwise a bare stub can win the race."
          : "Priority only writes into notes that already exist, so it can never beat your "
            + "daily-note template to the file."
      )
      .font(.caption)
      .foregroundColor(.secondary)

      // The master switch, last: it acts on everything above it. Unreachable
      // until a folder exists, so it can never be on with nowhere to write.
      Toggle("Write days into Obsidian daily notes", isOn: dailyLogEnabledBinding)
        .disabled(dailyLog.dailiesFolderPath.isEmpty)

      if dailyLog.dailiesFolderPath.isEmpty {
        Text("Choose a dailies folder above to turn this on.")
          .font(.caption)
          .foregroundColor(.secondary)
      } else if !dailyLog.dailyLogEnabled {
        Text("Days are still recorded locally; nothing is written to your vault.")
          .font(.caption)
          .foregroundColor(.secondary)
      }

      if dailyLog.dailyLogEnabled {
        Toggle("Write automatically at day rollover", isOn: writesAutomaticallyBinding)

        HStack {
          Button("Write Yesterday's Note Now") {
            let yesterday = dailyLog.plugin.boundary.day(offsetBy: -1, from: Date())
            _ = dailyLog.writeNoteNow(for: yesterday)
          }
          Spacer()
        }
      }
    }
    .onAppear {
      fileNameFormat = dailyLog.plugin.noteFormat.fileNameFormat
      folderFormat = dailyLog.plugin.noteFormat.folderFormat
    }
  }

  /// Full editor for the set of dailies — schedules and archiving, the things
  /// the popover's checklist deliberately doesn't carry. Adding and ticking
  /// stay in the Daily view, because that is where you are when you think of
  /// them; this is for the occasional reshuffle.
  @ViewBuilder
  private var dailiesEditor: some View {
    let dailyLog = manager.dailyLog
    let _ = dailyLog.revision

    VStack(alignment: .leading, spacing: 8) {
      Text("Dailies")
      Text(
        "Recurring things you intend to do. They reset every rollover — miss one "
          + "and it is simply a gap in the history, never an overdue task."
      )
      .font(.caption)
      .foregroundColor(.secondary)

      ForEach(dailyLog.allDailies) { daily in
        HStack(spacing: 8) {
          TextField(
            "Title",
            text: Binding(
              get: { daily.title },
              set: { dailyLog.renameDaily(daily, to: $0) }
            )
          )
          .textFieldStyle(.roundedBorder)
          Picker(
            "",
            selection: Binding(
              get: { daily.isEveryDay ? 0 : (daily.activeWeekdays == Daily.mondayToFriday ? 1 : 2) },
              set: { choice in
                // "Custom" is only ever a readout of an existing custom set —
                // selecting it shouldn't silently rewrite the days.
                guard choice != 2 else { return }
                dailyLog.setDailyWeekdays(
                  daily, to: choice == 0 ? Daily.allWeekdays : Daily.mondayToFriday)
              }
            )
          ) {
            Text("Every day").tag(0)
            Text("Weekdays").tag(1)
            if !daily.isEveryDay && daily.activeWeekdays != Daily.mondayToFriday {
              Text(daily.scheduleLabel).tag(2)
            }
          }
          .labelsHidden()
          .frame(width: 130)

          Button {
            dailyLog.archiveDaily(daily)
          } label: {
            Image(systemName: "trash")
          }
          .buttonStyle(.borderless)
          .help("Archive. Past days keep their record of this daily.")
        }
      }

      if dailyLog.allDailies.isEmpty {
        Text("None yet — add them from the Daily view (Shift+T, then Return).")
          .font(.caption)
          .foregroundColor(.secondary)
      }
    }
    .padding(.top, 4)
  }

  // The plugin's settings are plain stored properties rather than `@Observable`
  // state, so the toggles bind through explicitly instead of via `@Bindable`.

  private var dailyLogEnabledBinding: Binding<Bool> {
    Binding(
      get: { manager.dailyLog.dailyLogEnabled },
      set: { manager.dailyLog.dailyLogEnabled = $0 }
    )
  }

  private var rolloverBinding: Binding<Int> {
    Binding(
      get: { manager.dailyLog.plugin.rolloverHour },
      set: { manager.dailyLog.plugin.rolloverHour = $0 }
    )
  }

  private var createsMissingNotesBinding: Binding<Bool> {
    Binding(
      get: { manager.dailyLog.plugin.createsMissingNotes },
      set: { manager.dailyLog.plugin.createsMissingNotes = $0 }
    )
  }

  private var writesAutomaticallyBinding: Binding<Bool> {
    Binding(
      get: { manager.dailyLog.plugin.writesNotesAutomatically },
      set: { manager.dailyLog.plugin.writesNotesAutomatically = $0 }
    )
  }

  private var previewPath: String {
    DailyNotePath.relativePath(
      for: previewDate,
      format: DailyNoteFormat(fileNameFormat: fileNameFormat, folderFormat: folderFormat)
    )
  }

  private func saveFormat() {
    manager.dailyLog.plugin.noteFormat = DailyNoteFormat(
      fileNameFormat: fileNameFormat,
      folderFormat: folderFormat
    )
  }
}
