import SwiftUI

// MARK: - KanbanBoardView

struct KanbanBoardView: View {
  @Environment(BarTaskerCoordinator.self) var manager

  private func themeColor(_ token: BarTaskerThemeColorToken) -> Color {
    manager.preferences.themeColor(for: token)
  }

  private var isFilterActive: Bool {
    !manager.kanban.kanbanFilterTag.isEmpty || manager.kanban.kanbanFilterSubtasks
      || manager.kanban.kanbanFilterParentId != nil
  }

  var body: some View {
    let columns = manager.kanban.kanbanColumns
    let childCounts = manager.childCountByTaskId()
    let effectiveSelectedId = manager.kanban.currentKanbanTask?.id
    VStack(spacing: 0) {
      if isFilterActive {
        kanbanFilterBar
        Divider()
      }
      HStack(alignment: .top, spacing: 0) {
        ForEach(Array(columns.enumerated().reversed()), id: \.element.id) { colIndex, column in
          let tasks = manager.kanban.tasksForKanbanColumn(column, allColumns: columns)
          let isFocused = colIndex == manager.kanban.kanbanFocusedColumnIndex
          KanbanColumnView(
            column: column,
            tasks: tasks,
            columnIndex: colIndex,
            isFocused: isFocused,
            childCounts: childCounts,
            effectiveSelectedId: effectiveSelectedId
          )
          if colIndex > 0 {
            Divider()
          }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
  }

  private var kanbanFilterBar: some View {
    HStack(spacing: 6) {
      Image(systemName: "line.3.horizontal.decrease.circle.fill")
        .font(.system(size: 11))
        .foregroundColor(themeColor(.link))

      if let parentId = manager.kanban.kanbanFilterParentId,
        let parentTask = manager.tasks.first(where: { $0.id == parentId })
      {
        filterChip("↳ \(parentTask.content.strippingTags)") {
          manager.kanban.kanbanFilterParentId = nil
        }
      } else if manager.kanban.kanbanFilterSubtasks {
        filterChip("Subtasks of current") {
          manager.kanban.kanbanFilterSubtasks = false
        }
      }
      if !manager.kanban.kanbanFilterTag.isEmpty {
        filterChip("#\(manager.kanban.kanbanFilterTag)") {
          manager.kanban.kanbanFilterTag = ""
        }
      }
      Spacer()
      Button("Clear") {
        manager.kanban.kanbanFilterTag = ""
        manager.kanban.kanbanFilterSubtasks = false
        manager.kanban.kanbanFilterParentId = nil
      }
      .font(.system(size: 10))
      .buttonStyle(.plain)
      .foregroundColor(themeColor(.textSecondary))
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    .background(themeColor(.panelSurface))
  }

  private func filterChip(_ label: String, onRemove: @escaping () -> Void) -> some View {
    HStack(spacing: 3) {
      Text(label)
        .font(.system(size: 10))
      Button {
        onRemove()
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 8, weight: .bold))
      }
      .buttonStyle(.plain)
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 2)
    .background(themeColor(.selectionBackground).opacity(0.3))
    .foregroundColor(themeColor(.link))
    .clipShape(Capsule())
  }
}

// MARK: - KanbanColumnView

private struct KanbanColumnView: View {
  @Environment(BarTaskerCoordinator.self) var manager
  let column: KanbanColumn
  let tasks: [CheckvistTask]
  let columnIndex: Int
  let isFocused: Bool
  let childCounts: [Int: Int]
  let effectiveSelectedId: Int?

  private func themeColor(_ token: BarTaskerThemeColorToken) -> Color {
    manager.preferences.themeColor(for: token)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      columnHeader
      Divider()
      taskListArea
    }
    .frame(width: PopoverLayout.kanbanColumnWidth)
    .frame(maxHeight: .infinity, alignment: .topLeading)
  }

  private var columnHeader: some View {
    HStack(spacing: 6) {
      Text(column.name)
        .font(.system(size: 12, weight: .semibold))
        .foregroundColor(isFocused ? themeColor(.selectionForeground) : themeColor(.textPrimary))
      Spacer()
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
        .dropDestination(for: String.self) { ids, _ in
          guard let idStr = ids.first, let taskId = Int(idStr) else { return false }
          Task { await manager.moveTask(id: taskId, toColumn: column) }
          return true
        }
      } else {
        ScrollViewReader { proxy in
          ScrollView {
            VStack(spacing: 0) {
              ForEach(Array(tasks.enumerated()), id: \.element.id) { taskIndex, task in
                let isSelected = task.id == effectiveSelectedId
                KanbanTaskCard(
                  task: task,
                  isSelected: isSelected,
                  childCount: childCounts[task.id, default: 0]
                )
                .id(task.id)
                .onTapGesture {
                  manager.kanban.kanbanFocusedColumnIndex = columnIndex
                  manager.kanban.kanbanSelectedTaskId = task.id
                  manager.currentSiblingIndex = taskIndex
                  manager.rootScopeFocusLevel = 0
                }
                .draggable(String(task.id))
              }
            }
          }
          .onChange(of: manager.currentSiblingIndex) { _, _ in
            guard isFocused, let task = manager.kanban.currentKanbanTask else { return }
            if tasks.contains(where: { $0.id == task.id }) {
              proxy.scrollTo(task.id, anchor: .center)
            }
          }
          .dropDestination(for: String.self) { ids, _ in
            guard let idStr = ids.first, let taskId = Int(idStr) else { return false }
            Task { await manager.moveTask(id: taskId, toColumn: column) }
            return true
          }
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }
}

// MARK: - KanbanTaskCard

private struct KanbanTaskCard: View {
  @Environment(BarTaskerCoordinator.self) var manager
  let task: CheckvistTask
  let isSelected: Bool
  let childCount: Int

  @State private var isHovered = false

  private func themeColor(_ token: BarTaskerThemeColorToken) -> Color {
    manager.preferences.themeColor(for: token)
  }

  private var isCompleting: Bool { manager.quickEntry.completingTaskId == task.id }

  private func showInAllView() {
    manager.rootTaskView = .all
    manager.rootScopeFocusLevel = 0
    if childCount > 0 {
      manager.currentParentId = task.id
      manager.currentSiblingIndex = 0
    } else {
      manager.navigateTo(task: task)
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .top, spacing: 8) {
        VStack(alignment: .leading, spacing: 3) {
          Text(task.content.strippingTags)
            .font(.system(size: 12))
            .foregroundColor(
              isSelected ? themeColor(.selectionForeground) : themeColor(.textPrimary)
            )
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)

          metadataRow
        }
        Spacer(minLength: 0)
        if isHovered {
          HStack(spacing: 5) {
            if childCount > 0 {
              Button {
                manager.kanban.kanbanFilterParentId = task.id
                manager.kanban.kanbanFilterSubtasks = false
                manager.kanban.kanbanFilterTag = ""
              } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
                  .font(.system(size: 11))
                  .foregroundColor(themeColor(.link))
              }
              .buttonStyle(.plain)
              .help("Filter to subtasks")
            }
            Button(action: showInAllView) {
              Image(systemName: "arrow.forward.circle")
                .font(.system(size: 11))
                .foregroundColor(themeColor(.link))
            }
            .buttonStyle(.plain)
            .help("Show in All view")
          }
        }
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
    }
    .onHover { isHovered = $0 }
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
    let priorityRank = manager.priorityRank(for: task)

    if hasDue || !tags.isEmpty || hasChildren || priorityRank != nil {
      HStack(spacing: 5) {
        if let rank = priorityRank {
          Text("P\(rank)")
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(themeColor(.selectionBackground))
            .foregroundColor(themeColor(.selectionForeground))
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }

        if hasDue, let due = task.due {
          let bucket = manager.rootDueBucket(for: task)
          let isOverdue = bucket == .overdue
          let isToday = bucket == .today
          Text(due == "asap" ? "ASAP" : shortDateString(due))
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(
              isOverdue
                ? themeColor(.danger)
                : isToday
                  ? themeColor(.warning)
                  : themeColor(.textSecondary)
            )
        }

        ForEach(tags.prefix(3), id: \.self) { tag in
          Text(tag)
            .font(.system(size: 10))
            .foregroundColor(themeColor(.link))
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
      return naturalDateString(from: date)
    }
    // Try datetime format
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
    if let date = formatter.date(from: due) {
      return naturalDateString(from: date)
    }
    return due
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
}

// MARK: - String helper

extension String {
  /// Returns the content string with inline tags stripped for cleaner display.
  fileprivate var strippingTags: String {
    let pattern = try? NSRegularExpression(pattern: "\\s*[#@][\\w-]+")
    let range = NSRange(startIndex..., in: self)
    return pattern?.stringByReplacingMatches(in: self, range: range, withTemplate: "") ?? self
  }
}
