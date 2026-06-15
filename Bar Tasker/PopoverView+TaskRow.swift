import SwiftUI

/// Task row rendering for `PopoverView` plus every badge it composes (timer,
/// priority, eisenhower matrix, start-date, recurrence, due, generic metadata
/// token). Pulled out of the main file as part of the Phase-4 split.
extension PopoverView {
  // MARK: - Task Rows

  @ViewBuilder
  func dueSectionHeader(_ title: String) -> some View {
    HStack {
      Text(title.uppercased())
        .font(.system(size: 10, weight: .semibold))
        .foregroundColor(themeColor(.textSecondary))
      Spacer(minLength: 0)
    }
    .padding(.horizontal, PopoverLayout.rowHorizontalPadding)
    .padding(.top, 8)
    .padding(.bottom, 5)
    .background(themeColor(.panelSurface).opacity(0.7))
  }

  @ViewBuilder
  func taskRow(task: CheckvistTask, index: Int, childCount: Int, elapsed: TimeInterval) -> some View
  {
    let isSelected = index == navigationState.currentSiblingIndex
    let showsInlineComposer = isSelected && isAddMode
    let listFocusIsActive = navigationState.rootScopeFocusLevel == 0
    let showsSelectedStyling = isSelected && !showsInlineComposer && listFocusIsActive
    let showsInactiveSelection = isSelected && !showsInlineComposer && !listFocusIsActive
    let isCompleting = manager.quickEntry.completingTaskId == task.id
    let hasObsidianNoteLink = manager.integrations.hasObsidianSyncedNote(task: task, tasks: repository.tasks)
    let hasGoogleCalendarLink = manager.integrations.hasGoogleCalendarEventLink(taskId: task.id, listId: repository.listId)

    HStack(alignment: .top, spacing: PopoverLayout.rowContentSpacing) {
      VStack(alignment: .leading, spacing: 3) {
        if manager.shouldShowBreadcrumbPath(for: task) {
          let includeCurrentParent =
            manager.preferences.showTaskBreadcrumbContext
            && !(manager.quickEntry.quickEntryMode == .search && !manager.quickEntry.searchText.isEmpty)
          let path = breadcrumbPath(
            for: task,
            includeCurrentParent: includeCurrentParent
          )
          if !path.isEmpty {
            Text(path)
              .font(.system(size: 10)).foregroundColor(themeColor(.textSecondary)).lineLimit(1)
          }
        }

        // Inline edit: replace text with editable field when editing this task
        if isSelected && manager.quickEntry.quickEntryMode == .editTask && manager.quickEntry.isQuickEntryFocused {
          QuickEntryField(
            text: Bindable(manager).quickEntry.quickEntryText,
            isFocused: Bindable(manager).quickEntry.isQuickEntryFocused,
            cursorAtEnd: manager.quickEntry.editCursorAtEnd,
            font: Typography.taskNSFont(ofSize: 13),
            placeholder: "Edit task…",
            onSubmit: { submitAction() },
            onTab: {},
            onEscape: { escapeAction() }
          )
          .frame(height: 18)
          .frame(maxWidth: .infinity, alignment: .leading)
        } else {
          HStack(alignment: .center, spacing: 6) {
            fadedTaskTitle(task: task)
            taskInlineMetadata(task: task, elapsed: elapsed)
            if task.hasNotes {
              Image(systemName: "text.alignleft")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(themeColor(.textSecondary))
                .help("Task has notes")
            }
            if hasObsidianNoteLink {
              Button {
                navigationState.rootScopeFocusLevel = 0
                navigationState.currentSiblingIndex = index
                Task {
                  if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                    await manager.integrations.syncTaskToObsidian(taskId: task.id, openMode: .newWindow)
                  } else {
                    await manager.integrations.syncTaskToObsidian(taskId: task.id, openMode: .standard)
                  }
                }
              } label: {
                Image("ObsidianBadge")
                  .renderingMode(.template)
                  .resizable()
                  .interpolation(.high)
                  .scaledToFit()
                  .frame(width: 12, height: 12)
                  .foregroundColor(themeColor(.textSecondary))
              }
              .buttonStyle(.plain)
              .help("Open linked Obsidian note. Shift-click opens in a new window")
            }
            if hasGoogleCalendarLink {
              Button {
                navigationState.rootScopeFocusLevel = 0
                navigationState.currentSiblingIndex = index
                manager.integrations.openSavedGoogleCalendarEventLink(taskId: task.id)
              } label: {
                Image(systemName: "calendar.badge.checkmark")
                  .font(.system(size: 10, weight: .semibold))
                  .foregroundColor(themeColor(.textSecondary))
              }
              .buttonStyle(.plain)
              .help("Open linked Google Calendar event")
            }
          }
        }
      }
      .layoutPriority(1)
      .overlay(alignment: .center) {
        // Strikethrough line that draws left-to-right when completing
        Rectangle()
          .fill(themeColor(.success).opacity(0.65))
          .frame(height: 1.5)
          .scaleEffect(x: isCompleting ? 1.0 : 0.001, y: 1, anchor: .leading)
          .animation(.easeOut(duration: 0.12), value: isCompleting)
      }

      if childCount > 0 {
        Button {
          navigationState.currentSiblingIndex = index
          manager.taskNavigationService.enterChildren()
          if !manager.quickEntry.searchText.isEmpty {
            manager.quickEntry.searchText = ""
            manager.quickEntry.quickEntryMode = .search
            manager.quickEntry.isQuickEntryFocused = false
          }
        } label: {
          HStack(spacing: 3) {
            Text("\(childCount)").font(.caption2).foregroundColor(themeColor(.textSecondary))
            Image(systemName: "chevron.right").font(.system(size: 10)).foregroundColor(
              themeColor(.textSecondary))
          }
        }.buttonStyle(PlainButtonStyle()).help("Enter subtasks (→)")
      }
    }
    .padding(.horizontal, PopoverLayout.rowHorizontalPadding)
    .padding(.vertical, PopoverLayout.rowVerticalPadding)
    .scaleEffect(isCompleting ? 1.01 : 1.0)
    .animation(.spring(response: 0.3, dampingFraction: 0.5), value: isCompleting)
    .background(
      isCompleting
        ? themeColor(.success).opacity(0.12)
        : showsSelectedStyling
          ? themeColor(.selectionBackground).opacity(0.7)
          : showsInactiveSelection ? themeColor(.selectionBackground).opacity(0.28) : Color.clear
    )
    .overlay(alignment: .leading) {
      Rectangle().fill(
        isCompleting
          ? themeColor(.success)
          : showsSelectedStyling ? themeColor(.selectionForeground) : Color.clear
      )
      .frame(width: 3)
    }
    .contentShape(Rectangle())
    .onTapGesture {
      navigationState.rootScopeFocusLevel = 0
      navigationState.currentSiblingIndex = index
    }
  }

  func timerBadge(elapsed: TimeInterval, running: Bool) -> some View {
    HStack(spacing: 3) {
      Image(systemName: running ? "timer" : "pause.circle")
        .font(.system(size: 9))
      Text(formattedTimer(elapsed))
        .font(.system(size: 10, weight: .medium, design: .monospaced))
    }
    .padding(.horizontal, 5).padding(.vertical, 2)
    .background(running ? themeColor(.link).opacity(0.15) : themeColor(.panelSurfaceElevated))
    .foregroundColor(running ? themeColor(.link) : themeColor(.textSecondary))
    .clipShape(RoundedRectangle(cornerRadius: 4))
  }

  func formattedTimer(_ elapsed: TimeInterval) -> String {
    TimerManager.formattedTimer(elapsed)
  }

  @ViewBuilder
  func fadedTaskTitle(task: CheckvistTask) -> some View {
    MarqueeTextLine(fadeWidth: PopoverLayout.rowTextFadeWidth) {
      inlineTaskContent(task: task)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  func inlineTaskContent(task: CheckvistTask) -> Text {
    formatTaskContent(taskDisplayTitle(task.content))
  }

  func taskDisplayTitle(_ text: String) -> String {
    let pattern = "([@#][a-zA-Z0-9_\\-]+)"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
    let range = NSRange(text.startIndex..., in: text)
    let stripped = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    let normalized =
      stripped
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized.isEmpty ? text : normalized
  }

  func taskMetadataTokens(_ text: String) -> [String] {
    let pattern = "([@#][a-zA-Z0-9_\\-]+)"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let range = NSRange(text.startIndex..., in: text)
    let matches = regex.matches(in: text, range: range)
    return matches.compactMap { match in
      guard let matchRange = Range(match.range, in: text) else { return nil }
      return String(text[matchRange])
    }
  }

  @ViewBuilder
  func taskInlineMetadata(task: CheckvistTask, elapsed: TimeInterval) -> some View {
    let metadataTokens = taskMetadataTokens(task.content)
    let startLabel = manager.startDates.startDateLabel(for: task)
    let recurrenceRule = manager.recurrenceRule(for: task)
    let priorityLabel = taskListViewModel.priorityBadgeLabel(for: task)
    let matrixLabel = taskListViewModel.eisenhowerBadgeLabel(for: task)
    if !metadataTokens.isEmpty
      || priorityLabel != nil
      || matrixLabel != nil
      || (manager.timer.timerIsVisible && (elapsed > 0 || manager.timer.timedTaskId == task.id))
      || task.due != nil
      || startLabel != nil
      || recurrenceRule != nil
    {
      HStack(spacing: 4) {
        ForEach(metadataTokens, id: \.self) { token in
          metadataTokenBadge(token)
        }
        if let priorityLabel {
          priorityBadge(priorityLabel)
        }
        if let matrixLabel {
          matrixBadge(matrixLabel)
        }
        if manager.timer.timerIsVisible && (elapsed > 0 || manager.timer.timedTaskId == task.id) {
          timerBadge(
            elapsed: elapsed,
            running: manager.timer.timedTaskId == task.id && manager.timer.timerRunning
          )
        }
        if let label = startLabel {
          startBadge(label: label, isFuture: manager.startDates.startDateIsInFuture(for: task))
        }
        if let due = task.due {
          dueBadge(due: due, overdue: task.isOverdue, today: task.isDueToday)
        }
        if let rule = recurrenceRule {
          recurrenceBadge(rule: rule)
        }
      }
      .fixedSize(horizontal: true, vertical: false)
    }
  }

  @ViewBuilder
  func priorityBadge(_ priorityLabel: String) -> some View {
    let isAbsolute = priorityLabel.hasPrefix("A")
    Text(priorityLabel)
      .font(.system(size: 10, weight: .semibold, design: .monospaced))
      .padding(.horizontal, 5)
      .padding(.vertical, 2)
      .background(isAbsolute ? themeColor(.danger) : themeColor(.selectionBackground))
      .foregroundColor(isAbsolute ? Color.white : themeColor(.selectionForeground))
      .clipShape(RoundedRectangle(cornerRadius: 4))
  }

  @ViewBuilder
  func matrixBadge(_ label: String) -> some View {
    HStack(spacing: 3) {
      Image(systemName: "square.grid.2x2")
        .font(.system(size: 8))
      Text(label)
        .font(.system(size: 10, weight: .medium, design: .monospaced))
    }
    .padding(.horizontal, 5)
    .padding(.vertical, 2)
    .background(themeColor(.panelSurfaceElevated))
    .foregroundColor(themeColor(.textSecondary))
    .clipShape(RoundedRectangle(cornerRadius: 4))
  }

  @ViewBuilder
  func startBadge(label: String, isFuture: Bool) -> some View {
    HStack(spacing: 3) {
      Image(systemName: "play.fill")
        .font(.system(size: 8))
      Text(label)
        .font(.caption2)
    }
    .padding(.horizontal, 5).padding(.vertical, 2)
    .background(
      isFuture
        ? themeColor(.link).opacity(0.12)
        : themeColor(.panelSurfaceElevated)
    )
    .foregroundColor(
      isFuture ? themeColor(.link) : themeColor(.textSecondary)
    )
    .clipShape(RoundedRectangle(cornerRadius: 4))
  }

  @ViewBuilder
  func recurrenceBadge(rule: RecurrenceRule) -> some View {
    HStack(spacing: 3) {
      Image(systemName: "repeat")
        .font(.system(size: 8))
      Text(rule.displayLabel)
        .font(.caption2)
    }
    .padding(.horizontal, 5).padding(.vertical, 2)
    .background(themeColor(.panelSurfaceElevated))
    .foregroundColor(themeColor(.textSecondary))
    .clipShape(RoundedRectangle(cornerRadius: 4))
  }

  @ViewBuilder
  func dueBadge(due: String, overdue: Bool, today: Bool) -> some View {
    let displayText = due == "asap" ? "ASAP" : naturalDateString(from: due)
    Text(displayText).font(.caption2)
      .padding(.horizontal, 5).padding(.vertical, 2)
      .background(
        overdue
          ? themeColor(.danger).opacity(0.15)
          : today ? themeColor(.warning).opacity(0.15) : themeColor(.panelSurfaceElevated)
      )
      .foregroundColor(
        overdue
          ? themeColor(.danger)
          : today ? themeColor(.warning) : themeColor(.textSecondary)
      )
      .clipShape(RoundedRectangle(cornerRadius: 4))
  }
  
  private func naturalDateString(from dueString: String) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    // Try date-only format first
    formatter.dateFormat = "yyyy-MM-dd"
    if let date = formatter.date(from: dueString) {
      return naturalDateString(from: date)
    }
    // Try datetime format
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
    if let date = formatter.date(from: dueString) {
      return naturalDateString(from: date)
    }
    return dueString
  }
  
  private func naturalDateString(from date: Date) -> String {
    let calendar = Calendar.current
    let now = Date()
    let today = calendar.startOfDay(for: now)
    let targetDay = calendar.startOfDay(for: date)
    let dayDiff = calendar.dateComponents([.day], from: today, to: targetDay).day ?? 0
    
    switch dayDiff {
    case 0: return "Today"
    case 1: return "Tomorrow"
    case -1: return "Yesterday"
    case 2...6:
      let formatter = DateFormatter()
      formatter.dateFormat = "EEEE"  // Day name
      return formatter.string(from: date)
    case 7...13: return "Next week"
    case -7...(-2): return "Last week"
    default:
      let formatter = DateFormatter()
      formatter.dateFormat = "MMM d"
      return formatter.string(from: date)
    }
  }

  @ViewBuilder
  func metadataTokenBadge(_ token: String) -> some View {
    Text(token)
      .font(.system(size: 10, weight: .medium))
      .padding(.horizontal, 5)
      .padding(.vertical, 2)
      .background(themeColor(.panelSurfaceElevated))
      .foregroundColor(themeColor(.textSecondary))
      .clipShape(RoundedRectangle(cornerRadius: 4))
  }

  /// Parses Checkvist #tags and @contexts and formats them as inline pills using concatenated Text views
  // swiftlint:disable:next shorthand_operator
  func formatTaskContent(_ text: String) -> Text {
    let pattern = "([@#][a-zA-Z0-9_\\-]+)"
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
      return Text(text).font(Typography.taskFont(size: 13)).foregroundColor(
        themeColor(.textPrimary))
    }

    let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
    guard !matches.isEmpty else {
      return Text(text).font(Typography.taskFont(size: 13)).foregroundColor(
        themeColor(.textPrimary))
    }

    var resultText = Text("")
    var lastEnd = text.startIndex

    for match in matches {
      guard let matchRange = Range(match.range, in: text) else { continue }

      // Add preceding text
      if matchRange.lowerBound > lastEnd {
        let preceding = String(text[lastEnd..<matchRange.lowerBound])
        resultText =
          resultText
          + Text(preceding).font(Typography.taskFont(size: 13))
          .foregroundColor(themeColor(.textPrimary))
      }

      // Add the tag pill
      let tagStr = String(text[matchRange])

      // Markdown trick: We can't actually nest complex View backgrounds inside a concatenated Text in standard SwiftUI without iOS 15 AttributedString APIs,
      // but we CAN use basic inline styling like bolding and foreground colors.
      let tagText = Text(tagStr)
        .font(Typography.taskFont(size: 12, weight: .bold))
        .foregroundColor(themeColor(.link))

      resultText = resultText + tagText
      lastEnd = matchRange.upperBound
    }

    // Add trailing text
    if lastEnd < text.endIndex {
      let trailing = String(text[lastEnd..<text.endIndex])
      resultText =
        resultText
        + Text(trailing).font(Typography.taskFont(size: 13))
        .foregroundColor(themeColor(.textPrimary))
    }

    return resultText
  }
}
