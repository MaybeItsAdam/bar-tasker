import AppKit
import SwiftUI

@MainActor
protocol FeedbackService {
  func performTaskCompletionSequence(
    for taskId: Int, stateManager: @MainActor @escaping (Int?) -> Void) async throws
}

@MainActor
class DefaultFeedbackService: FeedbackService {
  func performTaskCompletionSequence(
    for taskId: Int, stateManager: @MainActor @escaping (Int?) -> Void
  ) async throws {
    NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    try await Task.sleep(nanoseconds: 60_000_000)
    NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    // Spring the checkmark in.
    withAnimation(.spring(response: 0.28, dampingFraction: 0.45)) { stateManager(taskId) }
    // Confirmation tap.
    try await Task.sleep(nanoseconds: 120_000_000)
    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    // Hold so strikethrough and pulse are visible.
    try await Task.sleep(nanoseconds: 360_000_000)
  }
}
