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

  let task: CheckvistTask
  let session: FocusSessionManager.ActiveSession

  private func themeColor(_ token: AppThemeColorToken) -> Color {
    manager.preferences.themeColor(for: token)
  }

  var body: some View {
    let elapsedTotal = manager.timer.timerByTaskId[task.id, default: 0]
    let elapsedInSession = max(0, elapsedTotal - session.baselineElapsed)
    let remaining = max(0, TimeInterval(session.durationSeconds) - elapsedInSession)
    let subtasks = manager.tasks.filter { candidate in
      candidate.status == 0 && candidate.id != task.id
        && manager.isDescendant(candidate, of: task.id)
    }

    VStack(alignment: .leading, spacing: 10) {
      Text("Focus mode")
        .font(.system(size: 11, weight: .semibold))
        .foregroundColor(themeColor(.textSecondary))
        .textCase(.uppercase)
      Text(task.content.strippingTags)
        .font(.system(size: 15, weight: .bold))
        .foregroundColor(themeColor(.textPrimary))
        .lineLimit(2)
      Text(countdownString(remaining))
        .font(.system(size: 28, weight: .bold, design: .monospaced))
        .foregroundColor(remaining <= 0 ? themeColor(.danger) : themeColor(.link))
      Text(remaining <= 0 ? "Time's up" : "Time remaining")
        .font(.system(size: 11))
        .foregroundColor(themeColor(.textSecondary))

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

  private func countdownString(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds.rounded()))
    let minutes = total / 60
    let remainder = total % 60
    return String(format: "%02d:%02d", minutes, remainder)
  }
}
