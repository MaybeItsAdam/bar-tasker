import Foundation

enum QuickEntryMode {
  case search
  case addSibling
  /// Same field, opposite side of the selection. Separate from `addSibling`
  /// rather than a flag on it because the placeholder has to say which way it
  /// is going — a composer that inserts above but reads "Add task" is a
  /// composer you will use wrongly once and then distrust.
  case addSiblingAbove
  case addChild
  case editTask
  case command
  case quickAddDefault
  case quickAddSpecific
}
