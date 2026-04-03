import SwiftUI

// MARK: - KanbanBoardView

struct KanbanBoardView: View {
  @EnvironmentObject var manager: BarTaskerManager

  private func themeColor(_ token: BarTaskerThemeColorToken) -> Color {
    manager.themeColor(for: token)
  }

  var body: some View {
    let columns = manager.kanbanColumns
    let childCounts = manager.childCountByTaskId()
    HStack(alignment: .top, spacing: 0) {
      ForEach(Array(columns.enumerated()), id: \.element.id) { colIndex, column in
        let tasks = manager.tasksForKanbanColumn(column, allColumns: columns)
        let isFocused = colIndex == manager.kanbanFocusedColumnIndex
        KanbanColumnView(
          column: column,
          tasks: tasks,
          columnIndex: colIndex,
          isFocused: isFocused,
          childCounts: childCounts
        )
        if colIndex < columns.count - 1 {
          Divider()
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}

// MARK: - KanbanColumnView

private struct KanbanColumnView: View {
  @EnvironmentObject var manager: BarTaskerManager
  let column: KanbanColumn
  let tasks: [CheckvistTask]
  let columnIndex: Int
  let isFocused: Bool
  let childCounts: [Int: Int]

  private func themeColor(_ token: BarTaskerThemeColorToken) -> Color {
    manager.themeColor(for: token)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      columnHeader
      Divider()
      taskListArea
    }
    .frame(width: PopoverLayout.kanbanColumnWidth, maxHeight: .infinity, alignment: .topLeading)
    .overlay {
      if isFocused {
        Rectangle()
          .stroke(themeColor(.focusRing), lineWidth: 1)
          .allowsHitTesting(false)
      }
    }
  }

  private var columnHeader: some View {
    HStack(spacing: 6) {
      Text(column.name)
        .font(.system(size: 12, weight: .semibold))
        .foregroundColor(isFocused ? themeColor(.selectionForeground) : themeColor(.textPrimary))
      Spacer()
      Text("\(tasks.count)")
        .font(.system(size: 11, weight: .medium))
        .foregroundColor(themeColor(.textSecondary))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(themeColor(.panelSurface))
        .clipShape(Capsule())
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(
      isFocused
        ? themeColor(.selectionBackground).opacity(0.18)
        : themeColor(.panelBackground)
    )
  }

  private var taskListArea: some View {
    Group {
      if tasks.isEmpty {
        VStack {
          Spacer()
          Text("No tasks")
            .font(.caption)
            .foregroundColor(themeColor(.textSecondary))
          Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollViewReader { proxy in
          ScrollView {
            VStack(spacing: 0) {
              ForEach(Array(tasks.enumerated()), id: \.element.id) { taskIndex, task in
                let isSelected =
                  isFocused && taskIndex == manager.currentSiblingIndex
                KanbanTaskCard(
                  task: task,
                  isSelected: isSelected,
                  childCount: childCounts[task.id, default: 0]
                )
                .id(task.id)
                .onTapGesture {
                  manager.kanbanFocusedColumnIndex = columnIndex
                  manager.rootScopeFocusLevel = 0
                  manager.currentSiblingIndex = taskIndex
                }
              }
            }
          }
          .onChange(of: manager.currentSiblingIndex) { _, _ in
            guard isFocused, let task = manager.currentTask else { return }
            if tasks.contains(where: { $0.id == task.id }) {
              proxy.scrollTo(task.id, anchor: .center)
            }
          }
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }
}

// MARK: - KanbanTaskCard

private struct KanbanTaskCard: View {
  @EnvironmentObject var manager: BarTaskerManager
  let task: CheckvistTask
  let isSelected: Bool
  let childCount: Int

  private func themeColor(_ token: BarTaskerThemeColorToken) -> Color {
    manager.themeColor(for: token)
  }

  private var isCompleting: Bool { manager.completingTaskId == task.id }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .top, spacing: 8) {
        Image(
          systemName: isCompleting
            ? "checkmark.circle.fill"
            : isSelected ? "largecircle.fill.circle" : "circle"
        )
        .foregroundColor(
          isCompleting
            ? themeColor(.success)
            : isSelected ? themeColor(.selectionForeground) : themeColor(.textSecondary)
        )
        .font(.system(size: 13))
        .padding(.top, 1)
        .scaleEffect(isCompleting ? 1.3 : 1.0)
        .animation(.spring(response: 0.28, dampingFraction: 0.45), value: isCompleting)
        .symbolEffect(.bounce, value: isCompleting)
        .onTapGesture {
          Task { await manager.markCurrentTaskDone() }
        }

        VStack(alignment: .leading, spacing: 3) {
          Text(task.content.strippingTags)
            .font(.system(size: 12))
            .foregroundColor(isSelected ? themeColor(.selectionForeground) : themeColor(.textPrimary))
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)

          metadataRow
        }
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      isSelected
        ? themeColor(.selectionBackground)
        : themeColor(.panelBackground)
    )
    .overlay(alignment: .leading) {
      if isSelected {
        Rectangle()
          .fill(themeColor(.selectionForeground))
          .frame(width: 3)
      }
    }
  }

  @ViewBuilder
  private var metadataRow: some View {
    let hasDue = !(task.due ?? "").isEmpty
    let tags = extractTags(from: task.content)
    let hasChildren = childCount > 0

    if hasDue || !tags.isEmpty || hasChildren {
      HStack(spacing: 5) {
        if hasDue, let due = task.due {
          let bucket = manager.rootDueBucket(for: task)
          let isOverdue = bucket == .overdue
          let isToday = bucket == .today
          Text(due == "asap" ? "ASAP" : shortDateString(due))
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(
              isOverdue ? themeColor(.danger)
              : isToday ? themeColor(.warning)
              : themeColor(.textSecondary)
            )
        }

        ForEach(tags.prefix(3), id: \.self) { tag in
          Text(tag)
            .font(.system(size: 10))
            .foregroundColor(themeColor(.accent))
        }

        if hasChildren {
          HStack(spacing: 2) {
            Image(systemName: "chevron.right")
              .font(.system(size: 9))
            Text("\(childCount)")
              .font(.system(size: 10))
          }
          .foregroundColor(themeColor(.textSecondary))
        }
      }
    }
  }

  private func extractTags(from content: String) -> [String] {
    let pattern = try? NSRegularExpression(pattern: "[#@][\\w-]+")
    let range = NSRange(content.startIndex..., in: content)
    let matches = pattern?.matches(in: content, range: range) ?? []
    return matches.compactMap { match in
      guard let r = Range(match.range, in: content) else { return nil }
      return String(content[r])
    }
  }

  private func shortDateString(_ due: String) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    // Try date-only format first
    formatter.dateFormat = "yyyy-MM-dd"
    if let date = formatter.date(from: due) {
      let out = DateFormatter()
      out.dateFormat = "MMM d"
      return out.string(from: date)
    }
    // Try datetime format
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
    if let date = formatter.date(from: due) {
      let out = DateFormatter()
      out.dateFormat = "MMM d"
      return out.string(from: date)
    }
    return due
  }
}

// MARK: - String helper

private extension String {
  /// Returns the content string with inline tags stripped for cleaner display.
  var strippingTags: String {
    let pattern = try? NSRegularExpression(pattern: "\\s*[#@][\\w-]+")
    let range = NSRange(startIndex..., in: self)
    return pattern?.stringByReplacingMatches(in: self, range: range, withTemplate: "") ?? self
  }
}
