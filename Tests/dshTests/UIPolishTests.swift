import XCTest
import AppKit
@testable import DSHCore

/// Pins the 2026-11-16 UI review fixes.
final class UIPolishTests: XCTestCase {

    // Titles mirror the official client's presentCall strings exactly, and
    // never depend on status.
    func testStepTitlesMatchUpstreamPresenters() {
        XCTAssertEqual(StepView.stepTitle(name: "read", args: ["file_path": "src/a.ts"]), "Read src/a.ts")
        XCTAssertEqual(StepView.stepTitle(name: "read", args: ["file_path": "a", "offset": 10, "limit": 5]), "Read a (10 - 14)")
        XCTAssertEqual(StepView.stepTitle(name: "read", args: ["file_path": "a", "limit": 400]), "Read a (1 - 400)")
        XCTAssertEqual(StepView.stepTitle(name: "read", args: ["file_path": "a", "offset": 50]), "Read a (from line 50)")
        XCTAssertEqual(StepView.stepTitle(name: "write", args: ["file_path": "a.md"]), "Write a.md")
        XCTAssertEqual(StepView.stepTitle(name: "edit", args: ["file_path": "a.md"]), "Edit a.md")
        XCTAssertEqual(StepView.stepTitle(name: "bash", args: ["command": "swift test", "description": "Run tests"]),
                       "swift test", "bash titles are the command; the description is secondary")
        XCTAssertEqual(StepView.stepTitle(name: "grep", args: ["pattern": "TODO", "path": "Sources", "glob": "*.swift"]),
                       "Grep TODO in Sources (*.swift)")
        XCTAssertEqual(StepView.stepTitle(name: "grep", args: ["pattern": "x"]), "Grep x")
        XCTAssertEqual(StepView.stepTitle(name: "glob", args: ["pattern": "**/*.md", "path": "docs"]), "Glob **/*.md in docs")
        XCTAssertEqual(StepView.stepTitle(name: "web_fetch", args: ["url": "https://e.com"]), "https://e.com")
        XCTAssertEqual(StepView.stepTitle(name: "web_search", args: ["query": "swift actors"]), "swift actors")
        XCTAssertEqual(StepView.stepTitle(name: "subagent", args: ["description": "audit"]), "subagent: audit")
        XCTAssertEqual(StepView.stepTitle(name: "my_plugin_tool", args: [:]), "my_plugin_tool")
    }

    func testDurationTextHidesNoiseAndAvoidsZeroSeconds() {
        XCTAssertEqual(StepView.durationText(0), "")
        XCTAssertEqual(StepView.durationText(12), "", "the old format rendered this as 0.0s")
        XCTAssertEqual(StepView.durationText(340), "340 ms")
        XCTAssertEqual(StepView.durationText(1_240), "1.2s")
    }

    // Icons were drawn into a square box and stretched; aspect-fit must keep
    // the symbol's proportions and stay centered inside the box.
    func testAspectFitKeepsProportions() {
        let box = NSRect(x: 10, y: 10, width: 16, height: 16)
        let wide = ActionButton.aspectFit(NSSize(width: 20, height: 10), in: box)
        XCTAssertEqual(wide.width / wide.height, 2, accuracy: 0.001)
        XCTAssertEqual(wide.width, 16, accuracy: 0.001)
        let tall = ActionButton.aspectFit(NSSize(width: 9, height: 18), in: box)
        XCTAssertEqual(tall.height, 16, accuracy: 0.001)
        XCTAssertEqual(tall.width / tall.height, 0.5, accuracy: 0.001)
        XCTAssertTrue(box.insetBy(dx: -1, dy: -1).contains(wide) && box.insetBy(dx: -1, dy: -1).contains(tall))
        XCTAssertEqual(ActionButton.aspectFit(.zero, in: box), box, "degenerate sizes fall back to the box")
    }

    // A plain NSView is invisible to VoiceOver unless it opts in.
    func testSelectChipIsAnAccessiblePopUp() {
        let chip = SelectChip()
        chip.items = ["fixture/fast", "fixture/reasoning"]
        chip.selected = "fixture/reasoning"
        XCTAssertTrue(chip.isAccessibilityElement())
        XCTAssertEqual(chip.accessibilityRole(), .popUpButton)
        XCTAssertEqual(chip.accessibilityValue() as? String, "fixture/reasoning")
    }
}
