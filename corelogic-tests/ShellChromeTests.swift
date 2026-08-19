import XCTest

@testable import PriorityCore

final class ShellChromeTests: XCTestCase {

  func testPanelDrawsTheChromeAppKitWouldOtherwiseProvide() {
    // The panel has no title bar and no system resize corner, so it draws its
    // own bevel, rounded edge and drag strip, and has to be told its size.
    for element in [
      ShellChromeElement.topBevel,
      .resizeStrip,
      .resizeDockButton,
      .roundedCorners,
      .fixedSize,
    ] {
      XCTAssertTrue(
        ShellChrome.shows(element, in: .panel),
        "\(element) should be drawn by the panel"
      )
      XCTAssertFalse(
        ShellChrome.shows(element, in: .window),
        "\(element) duplicates what a titled window already provides"
      )
    }
  }

  func testSupportSurfacesAreWindowOnly() {
    for element in [ShellChromeElement.diagnosticsDockButton, .syncStatusReadout] {
      XCTAssertTrue(ShellChrome.shows(element, in: .window))
      XCTAssertFalse(ShellChrome.shows(element, in: .panel))
    }
  }

  func testTabStripDividesEvenlyOnlyInThePanel() {
    XCTAssertTrue(ShellChrome.shows(.evenlyDividedTabStrip, in: .panel))
    XCTAssertFalse(ShellChrome.shows(.evenlyDividedTabStrip, in: .window))
  }

  func testEveryElementIsDecidedForEveryMode() {
    // Guards against a new case being added to the enum without a rule: the
    // switch in `ShellChrome` is exhaustive, so this only fails to compile if
    // something is missed — but it also documents that no element is ambiguous.
    for element in ShellChromeElement.allCases {
      let decisions = ShellMode.allCases.map { ShellChrome.shows(element, in: $0) }
      XCTAssertEqual(decisions.count, 2)
      XCTAssertNotEqual(
        decisions[0], decisions[1],
        "\(element) is identical in both shells — it does not need to be a ShellChromeElement"
      )
    }
  }
}
