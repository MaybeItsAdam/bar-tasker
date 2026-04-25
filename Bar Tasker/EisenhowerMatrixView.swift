import SwiftUI

struct EisenhowerMatrixView: View {
  private struct MatrixPlotPoint {
    let task: CheckvistTask
    let position: CGPoint
  }

  @Environment(AppCoordinator.self) var manager
  @State private var hoveredTaskId: Int?

  private func themeColor(_ token: AppThemeColorToken) -> Color {
    manager.preferences.themeColor(for: token)
  }

  var body: some View {
    let levels = manager.repository.taskEisenhowerLevels
    let tasks = manager.tasks.filter { task in task.status == 0 && levels[task.id] != nil && (levels[task.id]!.urgency != 0.0 || levels[task.id]!.importance != 0.0) }
    let currentSelectedId = manager.currentTask?.id

    GeometryReader { proxy in
      let size = min(proxy.size.width, proxy.size.height) - 40
      let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
      let plotPoints = tasks.map { task -> MatrixPlotPoint in
        let level = levels[task.id] ?? .zero
        // Map -9...9 to -size/2...size/2
        // Urgency is X (positive is right/urgent), Importance is Y (positive is up/important)
        let xOffset = (CGFloat(level.urgency) / 10.0) * (size / 2.0)
        let yOffset = -(CGFloat(level.importance) / 10.0) * (size / 2.0)
        return MatrixPlotPoint(
          task: task,
          position: CGPoint(x: center.x + xOffset, y: center.y + yOffset)
        )
      }

      ZStack {
        // Background Grid / Quadrants
        Group {
          // Quadrant Labels in corners
          quadrantLabel("DO", color: .red.opacity(0.1), alignment: .topTrailing, size: proxy.size)
          quadrantLabel("SCHEDULE", color: .blue.opacity(0.1), alignment: .topLeading, size: proxy.size)
          quadrantLabel("DELEGATE", color: .orange.opacity(0.1), alignment: .bottomTrailing, size: proxy.size)
          quadrantLabel("ELIMINATE", color: .gray.opacity(0.1), alignment: .bottomLeading, size: proxy.size)
          
          // Axes
          Path { path in
            path.move(to: CGPoint(x: 20, y: center.y))
            path.addLine(to: CGPoint(x: proxy.size.width - 20, y: center.y))
            path.move(to: CGPoint(x: center.x, y: 20))
            path.addLine(to: CGPoint(x: center.x, y: proxy.size.height - 20))
          }
          .stroke(themeColor(.panelDivider), lineWidth: 1)
        }

        // Axis Labels
        Group {
          Text("URGENT")
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(themeColor(.textSecondary))
            .position(x: proxy.size.width - 40, y: center.y + 12)
          
          Text("IMPORTANT")
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(themeColor(.textSecondary))
            .rotationEffect(.degrees(-90))
            .position(x: center.x - 12, y: 40)
        }

        // Task Dots
        ForEach(plotPoints, id: \.task.id) { point in
          TaskDotView(
            task: point.task,
            isSelected: point.task.id == currentSelectedId,
            isHovered: point.task.id == hoveredTaskId
          )
          .position(point.position)
          .onTapGesture {
            manager.navigateTo(task: point.task)
            // Optional: stay in Matrix view or switch? 
            // Let's stay in Matrix but highlight selection.
          }
        }
        
        // Hover Detail Overlay
        if let hoveredTaskId, let task = tasks.first(where: { $0.id == hoveredTaskId }) {
            hoverDetail(task: task, levels: levels)
                .position(x: center.x, y: proxy.size.height - 40)
        }
      }
      .contentShape(Rectangle())
      .onContinuousHover { phase in
        switch phase {
        case .active(let location):
          hoveredTaskId = nearestTaskId(to: location, in: plotPoints)
        case .ended:
          hoveredTaskId = nil
        }
      }
    }
    .background(themeColor(.panelSurface))
  }

  private func quadrantLabel(_ text: String, color: Color, alignment: Alignment, size: CGSize) -> some View {
      Text(text)
          .font(.system(size: 24, weight: .black))
          .foregroundColor(color)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
          .padding(30)
  }

  private func hoverDetail(task: CheckvistTask, levels: [Int: EisenhowerLevel]) -> some View {
      let level = levels[task.id] ?? .zero
      return VStack(spacing: 4) {
          Text(task.content)
              .font(.system(size: 11, weight: .semibold))
              .lineLimit(1)
          HStack(spacing: 12) {
              Text("Urgency: \(formatCoordinate(level.urgency))")
              Text("Importance: \(formatCoordinate(level.importance))")
          }
          .font(.system(size: 9, design: .monospaced))
          .foregroundColor(themeColor(.textSecondary))
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .background(themeColor(.panelSurfaceElevated))
      .cornerRadius(8)
      .shadow(radius: 4)
  }

  private func formatCoordinate(_ value: Double) -> String {
    if value.rounded() == value {
      return String(Int(value))
    }
    return String(format: "%.1f", value)
  }

  private func nearestTaskId(to location: CGPoint, in points: [MatrixPlotPoint]) -> Int? {
    guard let nearest = points.min(by: {
      squaredDistance($0.position, location) < squaredDistance($1.position, location)
    }) else { return nil }
    return nearest.task.id
  }

  private func squaredDistance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
    let dx = a.x - b.x
    let dy = a.y - b.y
    return dx * dx + dy * dy
  }
}

struct TaskDotView: View {
  let task: CheckvistTask
  let isSelected: Bool
  let isHovered: Bool
  @Environment(AppCoordinator.self) var manager

  private func themeColor(_ token: AppThemeColorToken) -> Color {
    manager.preferences.themeColor(for: token)
  }

  var body: some View {
    Circle()
      .fill(isSelected ? themeColor(.link) : (isHovered ? themeColor(.textPrimary) : themeColor(.textSecondary).opacity(0.6)))
      .frame(width: isSelected || isHovered ? 10 : 6, height: isSelected || isHovered ? 10 : 6)
      .overlay(
        Circle()
          .stroke(Color.white, lineWidth: isSelected || isHovered ? 2 : 0)
      )
      .animation(.spring(response: 0.2), value: isSelected || isHovered)
  }
}
