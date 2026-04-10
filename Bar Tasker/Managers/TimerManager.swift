import Combine
import Foundation
import OSLog

@MainActor
class TimerManager: ObservableObject {
  private let logger = Logger(subsystem: "uk.co.maybeitsadam.bar-tasker", category: "timer")
  private let preferencesStore: BarTaskerPreferencesStore
  private var cancellables = Set<AnyCancellable>()

  @Published var timedTaskId: Int? = nil
  @Published var timerByTaskId: [Int: TimeInterval] = [:]
  @Published var timerRunning: Bool = false
  @Published var timerBarLeading: Bool
  @Published var timerMode: TimerMode
  var timerTask: Task<Void, Never>? = nil

  var timerIsEnabled: Bool { timerMode != .disabled }
  var timerIsVisible: Bool { timerMode == .visible }

  init(preferencesStore: BarTaskerPreferencesStore) {
    self.preferencesStore = preferencesStore
    self.timerBarLeading = preferencesStore.bool(.timerBarLeading, default: false)
    self.timerMode = TimerMode(rawValue: preferencesStore.int(.timerMode, default: 0)) ?? .visible
    self.timerByTaskId = Self.timerDictionaryFromDefaults(preferencesStore: preferencesStore)
    setupBindings()
  }

  private func setupBindings() {
    $timerBarLeading.sink { [weak self] in
      self?.preferencesStore.set($0, for: .timerBarLeading)
    }.store(in: &cancellables)

    $timerMode.sink { [weak self] mode in
      self?.preferencesStore.set(mode.rawValue, for: .timerMode)
      if mode == .disabled {
        Task { @MainActor in
          self?.stopTimer()
        }
      }
    }.store(in: &cancellables)

    $timerByTaskId.sink { [weak self] timers in
      guard let self else { return }
      let encoded = Dictionary(uniqueKeysWithValues: timers.map { (String($0.key), $0.value) })
      self.preferencesStore.set(encoded, for: .timerByTaskId)
    }.store(in: &cancellables)
  }

  // MARK: - Timer Operations

  func toggleTimer(forTaskId taskId: Int) {
    guard timerIsEnabled else { return }
    if timedTaskId == taskId {
      timerRunning ? pauseTimer() : resumeTimer()
    } else {
      pauseTimer()
      timedTaskId = taskId
      if timerByTaskId[taskId] == nil {
        timerByTaskId[taskId] = 0
      }
      resumeTimer()
    }
  }

  func pauseTimer() {
    timerRunning = false
    timerTask?.cancel()
    timerTask = nil
  }

  func resumeTimer() {
    guard timerIsEnabled, let activeTaskId = timedTaskId, !timerRunning else { return }
    timerRunning = true
    timerTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        guard !Task.isCancelled else { break }
        await MainActor.run {
          self?.timerByTaskId[activeTaskId, default: 0] += 1
        }
      }
    }
  }

  func stopTimer() {
    pauseTimer()
    timedTaskId = nil
  }

  /// Stop the timer if the currently-timed task is no longer in the given set of open task IDs.
  func stopTimerIfTaskRemoved(openTaskIds: Set<Int>) {
    if let activeTimerTaskId = timedTaskId, !openTaskIds.contains(activeTimerTaskId) {
      stopTimer()
    }
  }

  // MARK: - Display

  static func formattedTimer(_ elapsed: TimeInterval) -> String {
    BarTaskerTimerStore.formatted(elapsed)
  }

  func timerBarString(currentTaskId: Int?, totalElapsedForCurrentTask: TimeInterval) -> String? {
    guard timerMode == .visible, let currentTaskId else { return nil }
    let elapsed = totalElapsedForCurrentTask
    let currentTaskHasActiveTimer = timedTaskId == currentTaskId
    guard elapsed > 0 || currentTaskHasActiveTimer else { return nil }
    return Self.formattedTimer(elapsed)
  }

  // MARK: - Persistence Helpers

  static func timerDictionaryFromDefaults(
    preferencesStore: BarTaskerPreferencesStore
  ) -> [Int: TimeInterval] {
    let raw = preferencesStore.timerDictionary()
    guard !raw.isEmpty else { return [:] }
    var result: [Int: TimeInterval] = [:]
    for (key, value) in raw {
      if let id = Int(key) { result[id] = value }
    }
    return result
  }
}

// MARK: - TimerMode (moved from BarTaskerManager+Types)

enum TimerMode: Int, CaseIterable {
  case visible
  case hidden
  case disabled
}
