import XCTest

@testable import CheckvistFocusCore

final class CoreLogicRegressionTests: XCTestCase {
  func testRemoteKeyBootstrapLoadsFromKeychainOnce() {
    var keychainReadCount = 0
    var state = RemoteKeyBootstrapState(remoteKey: "", hasAttemptedBootstrap: false)

    state = RemoteKeyBootstrapPolicy.bootstrap(
      state: state,
      usesKeychainStorage: true,
      loadFromKeychain: {
        keychainReadCount += 1
        return "rk_test_123"
      })

    XCTAssertEqual(state.remoteKey, "rk_test_123")
    XCTAssertTrue(state.hasAttemptedBootstrap)
    XCTAssertEqual(keychainReadCount, 1)

    state = RemoteKeyBootstrapPolicy.bootstrap(
      state: state,
      usesKeychainStorage: true,
      loadFromKeychain: {
        keychainReadCount += 1
        return "should_not_be_used"
      })

    XCTAssertEqual(state.remoteKey, "rk_test_123")
    XCTAssertTrue(state.hasAttemptedBootstrap)
    XCTAssertEqual(keychainReadCount, 1)
  }

  func testRemoteKeyBootstrapNoopWhenKeychainDisabled() {
    var keychainReadCount = 0
    let state = RemoteKeyBootstrapState(remoteKey: "", hasAttemptedBootstrap: false)

    let next = RemoteKeyBootstrapPolicy.bootstrap(
      state: state,
      usesKeychainStorage: false,
      loadFromKeychain: {
        keychainReadCount += 1
        return "rk_test_123"
      })

    XCTAssertEqual(next, state)
    XCTAssertEqual(keychainReadCount, 0)
  }

  func testRemoteKeyBootstrapTreatsWhitespaceAsEmpty() {
    var keychainReadCount = 0
    let state = RemoteKeyBootstrapState(remoteKey: "   ", hasAttemptedBootstrap: false)

    let next = RemoteKeyBootstrapPolicy.bootstrap(
      state: state,
      usesKeychainStorage: true,
      loadFromKeychain: {
        keychainReadCount += 1
        return "rk_test_123"
      })

    XCTAssertEqual(next.remoteKey, "rk_test_123")
    XCTAssertTrue(next.hasAttemptedBootstrap)
    XCTAssertEqual(keychainReadCount, 1)
  }

  func testOnboardingResetPreservesRemoteKeyAndClearsSessionState() {
    let initial = OnboardingResetState(
      remoteKey: "rk_keep_me",
      onboardingCompleted: true,
      username: "user@example.com",
      listId: "12345",
      availableListsCount: 4,
      tasksCount: 99,
      currentParentId: 42,
      currentSiblingIndex: 3
    )

    let reset = OnboardingResetPolicy.reset(initial)

    XCTAssertEqual(reset.remoteKey, "rk_keep_me")
    XCTAssertFalse(reset.onboardingCompleted)
    XCTAssertEqual(reset.username, "")
    XCTAssertEqual(reset.listId, "")
    XCTAssertEqual(reset.availableListsCount, 0)
    XCTAssertEqual(reset.tasksCount, 0)
    XCTAssertEqual(reset.currentParentId, 0)
    XCTAssertEqual(reset.currentSiblingIndex, 0)
  }

  func testAppTerminationPolicyRequiresExplicitQuit() {
    XCTAssertEqual(
      AppTerminationPolicy.decision(explicitQuitRequested: false),
      .cancel
    )
    XCTAssertEqual(
      AppTerminationPolicy.decision(explicitQuitRequested: true),
      .terminateNow
    )
  }
}
