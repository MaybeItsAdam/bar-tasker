import Foundation

enum RootTaskView: Int, CaseIterable {
  case all
  case due
  case tags
  case priority
  case kanban

  var title: String {
    switch self {
    case .all: return "All"
    case .due: return "Due"
    case .tags: return "Tags"
    case .priority: return "Priority"
    case .kanban: return "Kanban"
    }
  }
}
