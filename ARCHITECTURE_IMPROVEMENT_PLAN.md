# Bar Tasker Architecture Improvement Plan

## Overview
This document outlines a strategic plan to address current architectural debt in the Bar Tasker macOS application. The primary goals are to improve testability, enforce the Single Responsibility Principle (SRP), eliminate leaky abstractions, and create a more robust and scalable foundation for future development.

## 1. Decompose the "God Object" (`BarTaskerCoordinator`)

**Problem:** `BarTaskerCoordinator` is a centralized "God Object." It manages navigation, UI state, task mutations, manual caching, and side effects. Its implementation is split across numerous large extensions, making it hard to maintain and test. It also acts as a middleman, exposing many forwarding properties for the `TaskRepository`.

**Solution:**
*   **Domain-Specific State Objects:** Break the coordinator into smaller, focused `@Observable` objects.
    *   `NavigationState`: Manages popover visibility, current view routing (e.g., Settings vs. Main), and focus levels.
    *   `TaskListViewModel`: Encapsulates task fetching, filtering, and sorting logic, consuming data directly from the `TaskRepository`.
    *   `TaskIntentHandler`: A dedicated service for executing user actions (e.g., mark done, reopen, reorder).
*   **Eliminate Forwarding:** Remove properties like `tasks`, `listId`, and `errorMessage` from the coordinator. Views should depend directly on the specific view models or the `TaskRepository` if appropriate.

## 2. Refactor Cache Management

**Problem:** The app uses a manual `BarTaskerCacheState` managed via `invalidateCaches()` calls inside property `didSet` observers. This is fragile; forgetting to call invalidate leads to stale UI, and coarse invalidation leads to redundant computation.

**Solution:**
*   **Reactive Derivation:** Replace manual caching with SwiftUI's native computed properties where performance allows.
*   **Dedicated Derived State:** For expensive operations (like complex task tree flattening), introduce specialized `@Observable` objects or use Swift Concurrency (AsyncStream) / Combine to automatically react to changes in the underlying source of truth (`TaskRepository` or specific preferences) rather than relying on manual triggers.

## 3. Encapsulate Plugin Logic (Fix Leaky Abstractions)

**Problem:** `BarTaskerCoordinator` contains implementation-specific details. For example, `taskAction()` explicitly checks `if isUsingOfflineStore` and manually manages offline state arrays and dictionaries. This defeats the purpose of the plugin architecture.

**Solution:**
*   **Push Logic Down:** Move all storage-specific logic down into the `TaskRepository` and the respective `BarTaskerPlugin` implementations (e.g., an `OfflineStorePlugin` or `NativeCheckvistSyncPlugin`).
*   **Strengthen Protocols:** Ensure the plugin protocols (e.g., `TaskMutationProvider`) define clear, agnostic contracts for actions like `func completeTask(id: String) async throws`. The caller should not know or care how the completion is implemented.

## 4. Decouple Side Effects

**Problem:** Business logic methods (like `markCurrentTaskDone`) mix data mutations with UI-specific side effects, including haptics, spring animations, and `Task.sleep` delays. This makes the logic difficult to test in a headless environment.

**Solution:**
*   **Feedback Service:** Introduce a `FeedbackService` or `HapticManager` protocol.
*   **Separate Concerns:** The business logic (e.g., `TaskIntentHandler`) should only update the state and return a result. The UI layer (or a specialized UI coordinator) should listen for these results and trigger the appropriate animations and haptics independently.

## 5. Slim Down `AppDelegate`

**Problem:** `AppDelegate` handles application lifecycle, `NSStatusItem` management, custom window/popover lifecycle, global Carbon hotkeys, and plugin registration.

**Solution:**
*   **Extract Window Management:** Move `NSStatusItem` and popover logic into a dedicated `MenuBarController`.
*   **Extract Hotkeys:** Move Carbon hotkey registration into a `GlobalShortcutManager`.
*   **Focus AppDelegate:** Keep `AppDelegate` strictly focused on high-level application lifecycle events (`applicationDidFinishLaunching`), delegating the actual setup to these specialized controllers.

## Phased Implementation Strategy

### Phase 1: Foundation & Extraction
*   Extract `GlobalShortcutManager` and `MenuBarController` from `AppDelegate`.
*   Define the `FeedbackService` protocol and extract haptics/animations out of `BarTaskerCoordinator`.

### Phase 2: Plugin Encapsulation
*   Audit `BarTaskerCoordinator` and `TaskRepository` for leaked storage-specific logic.
*   Update plugin protocols to handle task mutations generically and move offline logic into its proper plugin/manager.

### Phase 3: State Decomposition
*   Introduce `NavigationState` and migrate routing logic.
*   Introduce `TaskListViewModel` and replace manual cache invalidation with reactive derived state.
*   Deconstruct the remaining responsibilities of `BarTaskerCoordinator` until it can be safely removed or repurposed as a lightweight dependency container.
