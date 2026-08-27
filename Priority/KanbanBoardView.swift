import PriorityCore
import SwiftUI

// MARK: - KanbanBoardView

struct KanbanBoardView: View {
  @Environment(AppCoordinator.self) var manager
  @Environment(TaskListViewModel.self) var taskListViewModel

  private func themeColor(_ token: AppThemeColorToken) -> Color {
    manager.preferences.themeColor(for: token)
  }

  private var isFilterActive: Bool {
    // kanbanFilterParentId is driven implicitly by the selected task's parent scope,
    // so we don't surface it here — the user sees the scope via the selected column/task.
    manager.kanban.kanbanFilterSubtasks
  }

  var body: some View {
    VStack(spacing: 0) {
      if isFilterActive {
        kanbanFilterBar
        Divider()
      }
      if manager.kanban.swimlanesByGoal {
        swimlaneBoard
      } else {
        flatBoard
      }
    }
  }

  /// One row of columns. What the board has always been.
  private var flatBoard: some View {
    let columns = manager.kanban.kanbanColumns
    return columnRow(columns: columns, restrictedTo: nil)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  /// A row per top-level goal.
  ///
  /// Each lane draws the *full* set of columns, including its empty ones —
  /// that emptiness is the comparison the layout exists to make, showing at a
  /// glance which goal has everything stuck in one state.
  private var swimlaneBoard: some View {
    let columns = manager.kanban.kanbanColumns
    let lanes = manager.kanban.swimlanes()
    return ScrollView(.vertical) {
      LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
        if lanes.isEmpty {
          Text("No tasks match any column.")
            .font(.system(size: 11))
            .foregroundColor(themeColor(.textSecondary))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        }
        ForEach(lanes) { lane in
          Section {
            columnRow(columns: columns, restrictedTo: Set(lane.tasks.map(\.id)))
              .frame(height: laneHeight(taskCount: lane.tasks.count))
            Divider()
          } header: {
            laneHeader(lane)
          }
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private func laneHeader(_ lane: KanbanSwimlane<CheckvistTask>) -> some View {
    HStack(spacing: 6) {
      Text(lane.title.strippingTags.uppercased())
        .font(.system(size: 10, weight: .bold))
        .tracking(1.5)
        .foregroundColor(themeColor(.textSecondary))
        .lineLimit(1)
      Spacer()
      Text("\(lane.tasks.count)")
        .font(.system(size: 10, weight: .bold, design: .monospaced))
        .foregroundColor(themeColor(.textSecondary))
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .frame(maxWidth: .infinity)
    .background(themeColor(.panelBackground))
    .overlay(alignment: .bottom) {
      Rectangle().fill(themeColor(.panelDivider)).frame(height: 1)
    }
  }

  /// Lanes are given room for their busiest column rather than a fixed height,
  /// so a goal with two tasks does not reserve the same band as one with forty.
  private func laneHeight(taskCount: Int) -> CGFloat {
    let columnCount = max(1, manager.kanban.kanbanColumns.count)
    let perColumn = max(1, Int(ceil(Double(taskCount) / Double(columnCount))))
    return min(360, max(120, CGFloat(perColumn) * 46 + 44))
  }

  /// The columns, optionally narrowed to one lane's tasks.
  ///
  /// `restrictedTo` filters what a column already claimed rather than changing
  /// how it claims — membership stays the column's business, so a task cannot
  /// land in a different column just because the board is grouped.
  private func columnRow(columns: [KanbanColumn], restrictedTo laneTaskIds: Set<Int>?) -> some View {
    let childCounts = taskListViewModel.childCountByTaskId()
    let effectiveSelectedId = manager.kanban.currentKanbanTask?.id
    return HStack(alignment: .top, spacing: 0) {
      ForEach(Array(columns.enumerated().reversed()), id: \.element.id) { colIndex, column in
        let all = manager.kanban.tasksForKanbanColumn(column, allColumns: columns)
        let tasks = laneTaskIds.map { ids in all.filter { ids.contains($0.id) } } ?? all
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
  }

  private var kanbanFilterBar: some View {
    HStack(spacing: 6) {
      Image(systemName: "line.3.horizontal.decrease.circle.fill")
        .font(.system(size: 11))
        .foregroundColor(themeColor(.link))

      if manager.kanban.kanbanFilterSubtasks {
        filterChip("Subtasks of current") {
          manager.kanban.kanbanFilterSubtasks = false
        }
      }
      
      Spacer()
      Button("Clear") {
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
  @Environment(AppCoordinator.self) var manager
  @Environment(NavigationState.self) var navigationState
  @FocusState private var addFieldFocused: Bool
  /// Where a card currently hovering over this column would be inserted, as
  /// an index into `tasks`. `tasks.count` is the append zone past the last
  /// card. Nil when nothing is being dragged over this column.
  @State private var dropTargetIndex: Int?
  let column: KanbanColumn
  let tasks: [CheckvistTask]
  let columnIndex: Int
  let isFocused: Bool
  let childCounts: [Int: Int]
  let effectiveSelectedId: Int?

  private func themeColor(_ token: AppThemeColorToken) -> Color {
    manager.preferences.themeColor(for: token)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      columnHeader
      Divider()
      taskListArea
    }
    .frame(maxWidth: .infinity)
    .frame(maxHeight: .infinity, alignment: .topLeading)
  }

  private var columnHeader: some View {
    let load = column.load(count: tasks.count)
    return HStack(spacing: 6) {
      Text(column.name)
        .font(.system(size: 12, weight: .semibold))
        .foregroundColor(isFocused ? themeColor(.selectionForeground) : themeColor(.textPrimary))
      Spacer()
      // The count was the cheapest thing missing from this board: a column
      // header that says only its name cannot tell you a column is empty
      // without you counting, or overloaded at all.
      Text(countLabel)
        .font(.system(size: 10, weight: .bold, design: .monospaced))
        .foregroundColor(loadColor(load))
        .padding(.horizontal, load == .unlimited ? 0 : 5)
        .padding(.vertical, load == .unlimited ? 0 : 1)
        .background(
          load == .unlimited
            ? Color.clear
            : loadColor(load).opacity(0.12)
        )
        .overlay(
          load == .unlimited
            ? nil
            : Capsule().stroke(loadColor(load).opacity(0.4), lineWidth: 1)
        )
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

  private var countLabel: String {
    guard let limit = column.wipLimit, limit > 0 else { return "\(tasks.count)" }
    return "\(tasks.count)/\(limit)"
  }

  /// Over a limit is a warning, not an error: nothing was rejected, the column
  /// is simply carrying more than you said it should.
  private func loadColor(_ load: KanbanColumn.Load) -> Color {
    switch load {
    case .unlimited, .within: return themeColor(.textSecondary)
    case .atLimit: return themeColor(.link)
    case .over: return themeColor(.warning)
    }
  }

  private var taskListArea: some View {
    VStack(spacing: 0) {
      if tasks.isEmpty && !isAddingHere {
        VStack {
          Spacer()
          Text("No tasks")
            .font(.caption)
            .foregroundColor(themeColor(.textSecondary))
          Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dropDestination(for: TaskDragPayload.self) { payloads, _ in
          guard let payload = payloads.first else { return false }
          manager.moveTask(id: payload.taskId, toColumn: column, insertBefore: 0)
          return true
        } isTargeted: { targeted in
          dropTargetIndex = targeted ? 0 : nil
        }
        .background(
          dropTargetIndex != nil
            ? themeColor(.selectionBackground).opacity(0.18) : Color.clear
        )
      } else {
        ScrollViewReader { proxy in
          ScrollView {
            VStack(spacing: 0) {
              ForEach(Array(tasks.enumerated()), id: \.element.id) { taskIndex, task in
                let isSelected = task.id == effectiveSelectedId
                VStack(spacing: 0) {
                  dropIndicator(active: dropTargetIndex == taskIndex)
                  KanbanTaskCard(
                    task: task,
                    isSelected: isSelected,
                    childCount: childCounts[task.id, default: 0]
                  )
                }
                .id(task.id)
                .onTapGesture {
                  manager.kanban.kanbanFocusedColumnIndex = columnIndex
                  manager.kanban.kanbanSelectedTaskId = task.id
                  navigationState.currentSiblingIndex = taskIndex
                  navigationState.rootScopeFocusLevel = 0
                }
                .draggable(
                  TaskDragPayload(taskId: task.id, sourceColumnId: column.id.uuidString)
                )
                // Dropping *on* a card always means "put it before this one".
                // The alternative — top half before, bottom half after — needs
                // the card's height at drop time and reads as a coin flip near
                // the middle. The trailing zone below covers "put it last".
                .dropDestination(for: TaskDragPayload.self) { payloads, _ in
                  guard let payload = payloads.first else { return false }
                  dropTargetIndex = nil
                  manager.moveTask(id: payload.taskId, toColumn: column, insertBefore: taskIndex)
                  return true
                } isTargeted: { targeted in
                  if targeted {
                    dropTargetIndex = taskIndex
                  } else if dropTargetIndex == taskIndex {
                    dropTargetIndex = nil
                  }
                }
              }

              // The append zone. Without it the last slot in a column is
              // unreachable by mouse, because every card means "before me".
              VStack(spacing: 0) {
                dropIndicator(active: dropTargetIndex == tasks.count)
                inlineAddField
                  .id("kanban-add-field")
                Color.clear
                  .frame(height: 44)
                  .contentShape(Rectangle())
              }
              .dropDestination(for: TaskDragPayload.self) { payloads, _ in
                guard let payload = payloads.first else { return false }
                dropTargetIndex = nil
                manager.moveTask(
                  id: payload.taskId, toColumn: column, insertBefore: tasks.count)
                return true
              } isTargeted: { targeted in
                if targeted {
                  dropTargetIndex = tasks.count
                } else if dropTargetIndex == tasks.count {
                  dropTargetIndex = nil
                }
              }
            }
          }
          .onChange(of: manager.kanban.kanbanSelectedTaskId) { _, selectedId in
            guard let selectedId, tasks.contains(where: { $0.id == selectedId }) else { return }
            proxy.scrollTo(selectedId, anchor: .center)
          }
          .onChange(of: isAddingHere) { _, adding in
            if adding {
              proxy.scrollTo("kanban-add-field", anchor: .bottom)
            }
          }
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }

  /// A hairline where the card would land. Separation in this app is borders,
  /// not elevation, so the insertion point is a rule rather than a gap that
  /// opens up — which also means the column does not reflow under the cursor
  /// while the drag is still in flight.
  private func dropIndicator(active: Bool) -> some View {
    Rectangle()
      .fill(active ? themeColor(.link) : Color.clear)
      .frame(height: 2)
      .padding(.horizontal, 6)
      .animation(.easeOut(duration: 0.12), value: active)
  }

  private var isAddingHere: Bool {
    manager.kanban.addingToColumnId == column.id
  }

  @ViewBuilder
  private var inlineAddField: some View {
    if isAddingHere {
      @Bindable var kanban = manager.kanban
      TextField("Add task…", text: $kanban.addText)
        .textFieldStyle(.plain)
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(themeColor(.panelSurface))
        .focused($addFieldFocused)
        .onAppear { addFieldFocused = true }
        .onChange(of: isAddingHere) { _, active in
          if active { addFieldFocused = true }
        }
        .onSubmit {
          let text = manager.kanban.addText
          guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            manager.kanban.addingToColumnId = nil
            manager.kanban.addText = ""
            return
          }
          manager.addTaskInKanbanColumn(rawContent: text, column: column)
          manager.kanban.addText = ""
        }
    }
  }
}

// MARK: - KanbanTaskCard

private struct KanbanTaskCard: View {
  @Environment(AppCoordinator.self) var manager
  @Environment(NavigationState.self) var navigationState
  @Environment(TaskListViewModel.self) var taskListViewModel
  let task: CheckvistTask
  let isSelected: Bool
  let childCount: Int

  @State private var isHovered = false

  private func themeColor(_ token: AppThemeColorToken) -> Color {
    manager.preferences.themeColor(for: token)
  }

  private var kind: CompletionKind { .task(id: task.id) }

  /// Cards take everything the preset offers except the collapse: a kanban
  /// column is a fixed grid of cards, and folding one shut mid-column shuffles
  /// every card below it.
  private var treatment: CelebrationRowTreatment { manager.celebration.rowTreatment }

  private func showInAllView() {
    taskListViewModel.rootTaskView = .all
    navigationState.rootScopeFocusLevel = 0
    if childCount > 0 {
      navigationState.currentParentId = task.id
      navigationState.currentSiblingIndex = 0
    } else {
      manager.taskNavigationService.navigate(to: task)
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
            .overlay(alignment: .center) {
              // Cards used to be the one surface that dropped the strike
              // entirely, so completing from the board looked like a different
              // app's animation to completing from the list.
              if treatment.drawsStrikethrough {
                CelebrationStrike(
                  isDrawn: manager.celebration.phase(for: kind) == .celebrating,
                  color: themeColor(.success).opacity(0.65),
                  reduceMotion: manager.celebration.prefersReducedMotion
                )
              }
            }

          metadataRow
        }
        Spacer(minLength: 0)
        if isHovered {
          HStack(spacing: 5) {
            if childCount > 0 {
              Button {
                manager.kanban.kanbanFilterParentId = task.id
                manager.kanban.kanbanFilterSubtasks = false
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
    // A card is opaque, so its resting fill goes in as the layer the tint
    // washes over rather than as a separate `.background` — which would sit
    // *behind* the modifier's and hide both the selection and the tint.
    .celebrating(
      kind,
      selectionBackground: isSelected
        ? themeColor(.selectionBackground)
        : themeColor(.panelBackground),
      selectionBar: isSelected ? themeColor(.selectionForeground) : nil,
      allowsCollapse: false
    )
  }

  @ViewBuilder
  private var metadataRow: some View {
    let hasDue = !(task.due ?? "").isEmpty
    let tags = extractTags(from: task.content)
    let hasChildren = childCount > 0
    let priorityLabel = taskListViewModel.priorityBadgeLabel(for: task)
    let matrixLabel = taskListViewModel.eisenhowerBadgeLabel(for: task)

    if hasDue || !tags.isEmpty || hasChildren || priorityLabel != nil || matrixLabel != nil {
      HStack(spacing: 5) {
        if let label = priorityLabel {
          let isAbsolute = label.hasPrefix("A")
          Text(label)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(isAbsolute ? themeColor(.danger) : themeColor(.selectionBackground))
            .foregroundColor(isAbsolute ? Color.white : themeColor(.selectionForeground))
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        if let matrixLabel {
          HStack(spacing: 2) {
            Image(systemName: "square.grid.2x2")
              .font(.system(size: 8))
            Text(matrixLabel)
              .font(.system(size: 10, weight: .medium, design: .monospaced))
          }
          .padding(.horizontal, 4)
          .padding(.vertical, 1)
          .background(themeColor(.panelSurfaceElevated))
          .foregroundColor(themeColor(.textSecondary))
          .clipShape(RoundedRectangle(cornerRadius: 3))
        }

        if hasDue, let due = task.due {
          let bucket = taskListViewModel.rootDueBucket(for: task)
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
  var strippingTags: String {
    let pattern = try? NSRegularExpression(pattern: "\\s*[#@][\\w-]+")
    let range = NSRange(startIndex..., in: self)
    return pattern?.stringByReplacingMatches(in: self, range: range, withTemplate: "") ?? self
  }
}
