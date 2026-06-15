import SwiftUI

struct FocusPromptOverlay: View {
  @Environment(AppCoordinator.self) var manager

  let task: CheckvistTask

  private func themeColor(_ token: AppThemeColorToken) -> Color {
    manager.preferences.themeColor(for: token)
  }

  var body: some View {
    let durationBinding = Binding<String>(
      get: { String(manager.focusSessionManager.durationMinutes) },
      set: { newValue in
        let digits = newValue.filter { $0.isNumber }
        if let parsed = Int(digits) {
          manager.focusSessionManager.durationMinutes = parsed
        } else if digits.isEmpty {
          manager.focusSessionManager.durationMinutes = FocusSessionManager.minDurationMinutes
        }
      }
    )

    return VStack(alignment: .leading, spacing: 12) {
      Text("Focus on")
        .font(.system(size: 11, weight: .semibold))
        .foregroundColor(themeColor(.textSecondary))
        .textCase(.uppercase)

      Text(task.content.strippingTags)
        .font(.system(size: 15, weight: .bold))
        .foregroundColor(themeColor(.textPrimary))
        .lineLimit(3)

      HStack(spacing: 8) {
        Button {
          manager.focusSessionManager.adjustDuration(by: -5)
        } label: {
          Image(systemName: "minus.circle")
            .font(.system(size: 14))
        }
        .buttonStyle(.plain)
        .foregroundColor(themeColor(.textSecondary))

        TextField("", text: durationBinding)
          .textFieldStyle(.plain)
          .font(.system(size: 28, weight: .bold, design: .monospaced))
          .foregroundColor(themeColor(.textPrimary))
          .multilineTextAlignment(.center)
          .frame(width: 90)
          .padding(.vertical, 6)
          .background(themeColor(.panelSurfaceElevated))
          .clipShape(RoundedRectangle(cornerRadius: 8))

        Button {
          manager.focusSessionManager.adjustDuration(by: 5)
        } label: {
          Image(systemName: "plus.circle")
            .font(.system(size: 14))
        }
        .buttonStyle(.plain)
        .foregroundColor(themeColor(.textSecondary))

        Text("min")
          .font(.system(size: 13))
          .foregroundColor(themeColor(.textSecondary))

        Spacer(minLength: 0)
      }

      Text("↑↓ adjusts by 1 (Shift = 5) • Enter starts • Esc cancels")
        .font(.system(size: 10))
        .foregroundColor(themeColor(.textSecondary))
    }
    .padding(20)
    .frame(maxWidth: 380, alignment: .leading)
    .background(themeColor(.panelSurface))
    .clipShape(RoundedRectangle(cornerRadius: 12))
    .overlay(
      RoundedRectangle(cornerRadius: 12)
        .stroke(themeColor(.panelDivider), lineWidth: 1)
    )
    .shadow(color: Color.black.opacity(0.25), radius: 18, x: 0, y: 8)
  }
}

struct FocusSessionOverlay: View {
  @Environment(AppCoordinator.self) var manager
  @Environment(TaskRepository.self) var repository
  @Environment(TaskListViewModel.self) var taskListViewModel

  /// Task associated with the focus block. `nil` during break phases if the
  /// originating task was deleted — we still want to surface the break UI.
  let task: CheckvistTask?
  let phase: FocusSessionManager.Phase
  let session: FocusSessionManager.ActiveSession?

  private func themeColor(_ token: AppThemeColorToken) -> Color {
    manager.preferences.themeColor(for: token)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      switch phase {
      case .running:
        runningContent
      case .focusCompleted:
        focusCompletedContent
      case .breakRunning(let endsAt):
        breakRunningContent(endsAt: endsAt)
      case .breakCompleted:
        breakCompletedContent
      }
    }
    .padding(20)
    .frame(maxWidth: 380, alignment: .leading)
    .background(themeColor(.panelSurface))
    .clipShape(RoundedRectangle(cornerRadius: 12))
    .overlay(
      RoundedRectangle(cornerRadius: 12)
        .stroke(themeColor(.panelDivider), lineWidth: 1)
    )
    .shadow(color: Color.black.opacity(0.25), radius: 18, x: 0, y: 8)
  }

  @ViewBuilder
  private var runningContent: some View {
    let elapsedTotal = task.map { manager.timer.timerByTaskId[$0.id, default: 0] } ?? 0
    let baseline = session?.baselineElapsed ?? 0
    let duration = TimeInterval(session?.durationSeconds ?? 0)
    let elapsedInSession = max(0, elapsedTotal - baseline)
    let remaining = max(0, duration - elapsedInSession)

    label("Focus mode")
    taskTitle
    Text(countdownString(remaining))
      .font(.system(size: 28, weight: .bold, design: .monospaced))
      .foregroundColor(themeColor(.link))
    Text("Time remaining")
      .font(.system(size: 11))
      .foregroundColor(themeColor(.textSecondary))

    subtaskList

    HStack(spacing: 8) {
      Button("Cancel focus") {
        manager.focusSessionManager.cancelSession()
        manager.timer.pauseTimer()
      }
      .buttonStyle(.plain)
      .font(.system(size: 11, weight: .semibold))
      .foregroundColor(themeColor(.danger))
      Text("Esc to cancel")
        .font(.system(size: 10))
        .foregroundColor(themeColor(.textSecondary))
    }
    .padding(.top, 4)
  }

  @ViewBuilder
  private var focusCompletedContent: some View {
    label("Time's up")
    taskTitle
    Text("00:00")
      .font(.system(size: 28, weight: .bold, design: .monospaced))
      .foregroundColor(themeColor(.danger))
    Text("Focus block complete — take a break?")
      .font(.system(size: 11))
      .foregroundColor(themeColor(.textSecondary))

    HStack(spacing: 8) {
      Button("Take \(manager.focusSessionManager.breakDurationMinutes)-min break") {
        manager.focusSessionManager.startBreak()
      }
      .buttonStyle(.plain)
      .font(.system(size: 11, weight: .semibold))
      .foregroundColor(themeColor(.link))

      Button("End session") {
        manager.focusSessionManager.cancelSession()
      }
      .buttonStyle(.plain)
      .font(.system(size: 11, weight: .semibold))
      .foregroundColor(themeColor(.danger))
    }
    .padding(.top, 4)

    Text("Enter takes break • Esc ends")
      .font(.system(size: 10))
      .foregroundColor(themeColor(.textSecondary))
  }

  @ViewBuilder
  private func breakRunningContent(endsAt: Date) -> some View {
    label("On break")
    if let task {
      Text("Next: \(task.content.strippingTags)")
        .font(.system(size: 13))
        .foregroundColor(themeColor(.textPrimary))
        .lineLimit(2)
    }
    TimelineView(.periodic(from: .now, by: 1)) { context in
      let remaining = max(0, endsAt.timeIntervalSince(context.date))
      Text(countdownString(remaining))
        .font(.system(size: 28, weight: .bold, design: .monospaced))
        .foregroundColor(themeColor(.link))
    }
    Text("Break ends in")
      .font(.system(size: 11))
      .foregroundColor(themeColor(.textSecondary))

    HStack(spacing: 8) {
      Button("Skip break") {
        manager.focusSessionManager.skipBreak()
      }
      .buttonStyle(.plain)
      .font(.system(size: 11, weight: .semibold))
      .foregroundColor(themeColor(.link))

      Button("End session") {
        manager.focusSessionManager.cancelSession()
      }
      .buttonStyle(.plain)
      .font(.system(size: 11, weight: .semibold))
      .foregroundColor(themeColor(.danger))
    }
    .padding(.top, 4)
  }

  @ViewBuilder
  private var breakCompletedContent: some View {
    label("Break over")
    if let task {
      Text(task.content.strippingTags)
        .font(.system(size: 15, weight: .bold))
        .foregroundColor(themeColor(.textPrimary))
        .lineLimit(2)
    }
    Text("Ready for another \(manager.focusSessionManager.durationMinutes)-min focus block?")
      .font(.system(size: 11))
      .foregroundColor(themeColor(.textSecondary))

    HStack(spacing: 8) {
      Button("Start focus") {
        startAnotherSession()
      }
      .buttonStyle(.plain)
      .font(.system(size: 11, weight: .semibold))
      .foregroundColor(themeColor(.link))
      .disabled(task == nil)

      Button("End session") {
        manager.focusSessionManager.cancelSession()
      }
      .buttonStyle(.plain)
      .font(.system(size: 11, weight: .semibold))
      .foregroundColor(themeColor(.danger))
    }
    .padding(.top, 4)

    Text("Enter starts focus • Esc ends")
      .font(.system(size: 10))
      .foregroundColor(themeColor(.textSecondary))
  }

  // MARK: - Shared subviews

  @ViewBuilder
  private func label(_ text: String) -> some View {
    Text(text)
      .font(.system(size: 11, weight: .semibold))
      .foregroundColor(themeColor(.textSecondary))
      .textCase(.uppercase)
  }

  @ViewBuilder
  private var taskTitle: some View {
    if let task {
      Text(task.content.strippingTags)
        .font(.system(size: 15, weight: .bold))
        .foregroundColor(themeColor(.textPrimary))
        .lineLimit(2)
    }
  }

  @ViewBuilder
  private var subtaskList: some View {
    if let task {
      let subtasks = repository.tasks.filter { candidate in
        candidate.status == 0 && candidate.id != task.id
          && taskListViewModel.isDescendant(candidate, of: task.id)
      }
      if !subtasks.isEmpty {
        Divider()
        Text("Subtasks")
          .font(.system(size: 11, weight: .semibold))
          .foregroundColor(themeColor(.textSecondary))
        ForEach(subtasks.prefix(6)) { subtask in
          Text("• \(subtask.content.strippingTags)")
            .font(.system(size: 12))
            .foregroundColor(themeColor(.textPrimary))
            .lineLimit(1)
        }
      }
    }
  }

  private func startAnotherSession() {
    guard let task else { return }
    let baseline = manager.timer.timerByTaskId[task.id, default: 0]
    if !manager.timer.timerIsEnabled {
      manager.timer.timerMode = .visible
    }
    if manager.timer.timedTaskId == task.id {
      if !manager.timer.timerRunning {
        manager.timer.resumeTimer()
      }
    } else {
      manager.timer.toggleTimer(forTaskId: task.id)
    }
    manager.focusSessionManager.startAnotherSession(baselineElapsed: baseline)
  }

  private func countdownString(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds.rounded()))
    let minutes = total / 60
    let remainder = total % 60
    return String(format: "%02d:%02d", minutes, remainder)
  }
}
