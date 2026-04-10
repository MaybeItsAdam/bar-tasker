import SwiftUI

// MARK: - KanbanSettingsView

struct KanbanSettingsView: View {
  @EnvironmentObject var manager: BarTaskerManager

  @State private var editingColumn: KanbanColumn? = nil
  @State private var showingAddColumn = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      headerRow
      Divider()
      columnList
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .sheet(item: $editingColumn) { col in
      KanbanColumnEditorView(column: col) { updated in
        if let idx = manager.kanban.kanbanColumns.firstIndex(where: { $0.id == updated.id }) {
          manager.kanban.kanbanColumns[idx] = updated
        }
        editingColumn = nil
      } onCancel: {
        editingColumn = nil
      }
    }
    .sheet(isPresented: $showingAddColumn) {
      let fresh = KanbanColumn(name: "New Column", conditions: [.catchAll])
      KanbanColumnEditorView(column: fresh) { created in
        manager.kanban.kanbanColumns.append(created)
        showingAddColumn = false
      } onCancel: {
        showingAddColumn = false
      }
    }
  }

  private var headerRow: some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text("Kanban Columns")
          .font(.system(size: 13, weight: .semibold))
        Text("Columns are evaluated left-to-right; a task appears in the first column it matches.")
          .font(.caption)
          .foregroundColor(.secondary)
      }
      Spacer()
      Button {
        showingAddColumn = true
      } label: {
        Label("Add Column", systemImage: "plus")
          .font(.system(size: 12))
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
    }
    .padding(16)
  }

  private var columnList: some View {
    List {
      ForEach(manager.kanban.kanbanColumns) { col in
        KanbanColumnRow(column: col) {
          editingColumn = col
        } onDelete: {
          manager.kanban.kanbanColumns.removeAll { $0.id == col.id }
        }
      }
      .onMove { from, to in
        manager.kanban.kanbanColumns.move(fromOffsets: from, toOffset: to)
      }
    }
    .listStyle(.inset)
  }
}

// MARK: - KanbanColumnRow

private struct KanbanColumnRow: View {
  let column: KanbanColumn
  let onEdit: () -> Void
  let onDelete: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 3) {
        Text(column.name)
          .font(.system(size: 13, weight: .medium))
        conditionsSummary
      }
      Spacer()
      Text(column.sortOrder.title)
        .font(.caption)
        .foregroundColor(.secondary)
      Button("Edit", action: onEdit)
        .buttonStyle(.bordered)
        .controlSize(.small)
      Button(role: .destructive, action: onDelete) {
        Image(systemName: "trash")
      }
      .buttonStyle(.plain)
      .foregroundColor(.red)
    }
    .padding(.vertical, 4)
  }

  private var conditionsSummary: some View {
    let titles = column.conditions.map(\.displayTitle)
    return Text(titles.joined(separator: " or "))
      .font(.caption)
      .foregroundColor(.secondary)
      .lineLimit(1)
  }
}

// MARK: - KanbanColumnEditorView

struct KanbanColumnEditorView: View {
  @State var column: KanbanColumn
  let onSave: (KanbanColumn) -> Void
  let onCancel: () -> Void

  @State private var pendingCondition: PendingCondition = .tag
  @State private var pendingTagName: String = ""
  @State private var pendingDueBucket: BarTaskerManager.RootDueBucket = .today

  private enum PendingCondition: String, CaseIterable, Identifiable {
    case tag, due, catchAll
    var id: String { rawValue }
    var title: String {
      switch self {
      case .tag: return "Tag"
      case .due: return "Due bucket"
      case .catchAll: return "Everything else (catch-all)"
      }
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(column.name.isEmpty ? "New Column" : column.name)
        .font(.headline)

      Group {
        LabeledContent("Name") {
          TextField("Column name", text: $column.name)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 240)
        }

        LabeledContent("Sort order") {
          Picker("", selection: $column.sortOrder) {
            ForEach(KanbanSortOrder.allCases) { order in
              Text(order.title).tag(order)
            }
          }
          .pickerStyle(.menu)
          .frame(maxWidth: 240)
        }
      }

      Divider()

      Text("Conditions")
        .font(.system(size: 12, weight: .semibold))
      Text("A task matches this column if it satisfies any condition below.")
        .font(.caption)
        .foregroundColor(.secondary)

      conditionList

      Divider()

      addConditionSection

      Spacer()

      HStack {
        Spacer()
        Button("Cancel", action: onCancel)
          .keyboardShortcut(.cancelAction)
        Button("Save") { onSave(column) }
          .keyboardShortcut(.defaultAction)
          .disabled(column.name.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }
    .padding(20)
    .frame(width: 480, height: 460)
  }

  private var conditionList: some View {
    List {
      if column.conditions.isEmpty {
        Text("No conditions — add one below.")
          .foregroundColor(.secondary)
          .font(.caption)
      } else {
        ForEach(Array(column.conditions.enumerated()), id: \.offset) { idx, cond in
          HStack {
            Image(systemName: conditionIcon(cond))
              .foregroundColor(.secondary)
              .frame(width: 16)
            Text(cond.displayTitle)
              .font(.system(size: 12))
            Spacer()
            Button {
              column.conditions.remove(at: idx)
            } label: {
              Image(systemName: "minus.circle.fill")
                .foregroundColor(.red)
            }
            .buttonStyle(.plain)
          }
        }
        .onMove { from, to in
          column.conditions.move(fromOffsets: from, toOffset: to)
        }
      }
    }
    .listStyle(.inset)
    .frame(height: 120)
  }

  private var addConditionSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Add condition")
        .font(.system(size: 12, weight: .semibold))

      HStack(spacing: 8) {
        Picker("", selection: $pendingCondition) {
          ForEach(PendingCondition.allCases) { c in
            Text(c.title).tag(c)
          }
        }
        .pickerStyle(.menu)
        .frame(width: 180)

        switch pendingCondition {
        case .tag:
          TextField("#tagname", text: $pendingTagName)
            .textFieldStyle(.roundedBorder)
            .frame(width: 120)
        case .due:
          Picker("", selection: $pendingDueBucket) {
            ForEach(BarTaskerManager.RootDueBucket.allCases, id: \.rawValue) { bucket in
              Text(bucket.title).tag(bucket)
            }
          }
          .pickerStyle(.menu)
          .frame(width: 160)
        case .catchAll:
          EmptyView()
        }

        Button("Add") {
          addPendingCondition()
        }
        .buttonStyle(.bordered)
        .disabled(!canAddPendingCondition)
      }
    }
  }

  private var canAddPendingCondition: Bool {
    switch pendingCondition {
    case .tag: return !pendingTagName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    case .due, .catchAll: return true
    }
  }

  private func addPendingCondition() {
    let condition: KanbanColumnCondition
    switch pendingCondition {
    case .tag:
      let name = pendingTagName
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "#", with: "")
      guard !name.isEmpty else { return }
      condition = .tag(name)
      pendingTagName = ""
    case .due:
      condition = .dueBucket(pendingDueBucket.rawValue)
    case .catchAll:
      condition = .catchAll
    }
    // Avoid duplicates
    guard !column.conditions.contains(condition) else { return }
    column.conditions.append(condition)
  }

  private func conditionIcon(_ cond: KanbanColumnCondition) -> String {
    switch cond {
    case .tag: return "tag"
    case .dueBucket: return "calendar"
    case .catchAll: return "tray"
    }
  }
}
