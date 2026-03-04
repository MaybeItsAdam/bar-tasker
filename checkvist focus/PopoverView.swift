import SwiftUI

struct PopoverView: View {
    @EnvironmentObject var checkvistManager: CheckvistManager
    @State private var newTaskContent: String = ""
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Header ──────────────────────────────────────
            HStack {
                Text("Checkvist Focus")
                    .font(.headline)
                    .foregroundColor(.secondary)
                Spacer()
                Button {
                    Task { await checkvistManager.fetchTopTask() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(PlainButtonStyle())
                .help("Refresh tasks")

                if #available(macOS 13.0, *) {
                    SettingsLink {
                        Image(systemName: "gearshape")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .padding(.leading, 6)
                }

                Button { NSApplication.shared.terminate(nil) } label: {
                    Image(systemName: "xmark.circle")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.leading, 6)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            if checkvistManager.isLoading && checkvistManager.tasks.isEmpty {
                // Initial loading state
                HStack {
                    Spacer()
                    ProgressView().padding()
                    Spacer()
                }
            } else if checkvistManager.tasks.isEmpty {
                // Empty state
                HStack {
                    Spacer()
                    VStack(spacing: 6) {
                        Image(systemName: "checkmark.circle")
                            .font(.title2)
                            .foregroundColor(.secondary)
                        Text("No open tasks")
                            .foregroundColor(.secondary)
                            .font(.callout)
                    }
                    .padding()
                    Spacer()
                }
            } else {
                // ── Current Task ──────────────────────────────
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        // Navigation
                        Button { checkvistManager.previousTask() } label: {
                            Image(systemName: "chevron.left")
                        }
                        .buttonStyle(PlainButtonStyle())
                        .foregroundColor(.secondary)

                        Text("\(checkvistManager.currentTaskIndex + 1) of \(checkvistManager.tasks.count)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(minWidth: 40)

                        Button { checkvistManager.nextTask() } label: {
                            Image(systemName: "chevron.right")
                        }
                        .buttonStyle(PlainButtonStyle())
                        .foregroundColor(.secondary)

                        Spacer()

                        // Due date badge
                        if let task = checkvistManager.currentTask, let due = task.due {
                            dueBadge(due: due, overdue: task.isOverdue, today: task.isDueToday)
                        }
                    }

                    Text(checkvistManager.currentTask?.content ?? "")
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)

                    // Mark done button
                    Button {
                        Task { await checkvistManager.markCurrentTaskDone() }
                    } label: {
                        Label("Mark done", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(checkvistManager.isLoading)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                Divider()

                // ── Task List ──────────────────────────────────
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(checkvistManager.tasks.enumerated()), id: \.element.id) { index, task in
                            Button {
                                checkvistManager.currentTaskIndex = index
                            } label: {
                                let indent = CGFloat((task.level ?? 1) - 1) * 12
                                HStack(spacing: 6) {
                                    // Hierarchy indent
                                    if indent > 0 {
                                        Rectangle().fill(Color.clear).frame(width: indent, height: 1)
                                        Image(systemName: "arrow.turn.down.right")
                                            .font(.system(size: 9))
                                            .foregroundColor(.secondary.opacity(0.5))
                                    }

                                    Image(systemName: index == checkvistManager.currentTaskIndex
                                          ? "largecircle.fill.circle" : "circle")
                                        .foregroundColor(index == checkvistManager.currentTaskIndex ? .blue : .secondary)
                                        .font(.caption)

                                    Text(task.content)
                                        .font(.caption)
                                        .foregroundColor(index == checkvistManager.currentTaskIndex ? .primary : .secondary)
                                        .lineLimit(1)

                                    Spacer()

                                    if let due = task.due {
                                        dueBadge(due: due, overdue: task.isOverdue, today: task.isDueToday)
                                            .scaleEffect(0.8)
                                    }
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 5)
                                .background(
                                    index == checkvistManager.currentTaskIndex
                                        ? Color.accentColor.opacity(0.08)
                                        : Color.clear
                                )
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                }
                .frame(maxHeight: 130)
            }

            Divider()

            // ── Add Task ───────────────────────────────────
            HStack(spacing: 8) {
                TextField("Add a task…", text: $newTaskContent)
                    .textFieldStyle(PlainTextFieldStyle())
                    .focused($isTextFieldFocused)
                    .onSubmit { submitTask() }
                    .disabled(checkvistManager.isLoading)

                if checkvistManager.isLoading {
                    ProgressView().scaleEffect(0.6).frame(width: 16, height: 16)
                } else {
                    Button(action: submitTask) {
                        Image(systemName: "arrow.up.circle.fill")
                            .foregroundColor(newTaskContent.isEmpty ? .gray : .accentColor)
                            .imageScale(.large)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(newTaskContent.isEmpty || checkvistManager.isLoading)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            // Error message
            if let error = checkvistManager.errorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundColor(.red)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
            }
        }
        .frame(width: 320)
    }

    @ViewBuilder
    private func dueBadge(due: String, overdue: Bool, today: Bool) -> some View {
        Text(due)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                overdue ? Color.red.opacity(0.15) :
                today   ? Color.orange.opacity(0.15) :
                          Color.secondary.opacity(0.1)
            )
            .foregroundColor(
                overdue ? .red :
                today   ? .orange :
                          .secondary
            )
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func submitTask() {
        guard !newTaskContent.isEmpty else { return }
        let content = newTaskContent
        newTaskContent = ""
        Task { await checkvistManager.addTask(content: content) }
    }
}
