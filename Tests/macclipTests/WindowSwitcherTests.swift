import XCTest
@testable import macclip

final class WindowSwitcherTests: XCTestCase {
    func testCycleWrapsForwardAndBackward() {
        XCTAssertEqual(cycledIndex(0, step: 1, count: 5), 1)
        XCTAssertEqual(cycledIndex(4, step: 1, count: 5), 0)
        XCTAssertEqual(cycledIndex(0, step: -1, count: 5), 4)
        XCTAssertEqual(cycledIndex(0, step: 1, count: 1), 0)
        XCTAssertEqual(cycledIndex(3, step: 1, count: 0), 0)
    }

    func testThumbSizeSettingDrivesCellSize() {
        let switcher = WindowSwitcher()
        defer { switcher.thumbSize = .medium }
        switcher.thumbSize = .small
        let small = SwitcherGridView.cell
        switcher.thumbSize = .large
        XCTAssertGreaterThan(SwitcherGridView.cell.width, small.width)
        XCTAssertGreaterThan(SwitcherGridView.cell.height, small.height)
        XCTAssertNil(SwitcherThumbSize(rawValue: 7))
        XCTAssertNil(SwitcherModifier(rawValue: "command"))
    }
}
