import XCTest
@testable import IPhoneAgent

/// Runs read back from trace folders (what the Runs list and the replay player show), and saved intents.
@MainActor final class StoreTests: XCTestCase {
    func testRapidStartsNeverShareATraceDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let traces = TraceStore(root: root)
        traces.start(task: "first")
        let first = try XCTUnwrap(traces.dir)
        traces.start(task: "second")
        let second = try XCTUnwrap(traces.dir)
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(try String(contentsOf: first.appendingPathComponent("steps.jsonl")).contains("second"))
    }

    func testStartingRejectsASecondTaskAndStopCancelsDeparture() async {
        let app = AppModel()
        let first = Task { await app.run("first") }
        while !app.starting { await Task.yield() }
        await app.run("second")
        XCTAssertEqual(app.lastTask, "first")
        XCTAssertTrue(app.starting)
        // Keep the test away from hardware/calibration, while exercising cancellation during departure.
        app.startCancelled = true
        await first.value
        XCTAssertFalse(app.starting)
        XCTAssertFalse(app.departing)
        XCTAssertFalse(app.agent.running)
    }

    func testRunIsReadBackWithFramesOutcomeAndDuration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let traces = TraceStore(root: root)
        traces.start(task: "Open Settings")
        traces.write(Data([0xFF, 0xD8]), kind: "llm", ["role": .str("actor")])
        traces.write(kind: "step", ["action": .str("tap"), "x": .int(500), "y": .int(300), "changed": .bool(true)])
        traces.write(kind: "step", ["action": .str("done"), "answer": .str("ok")])

        let store = RunStore(traces: traces)
        store.reload()
        let run = try XCTUnwrap(store.runs.first)
        XCTAssertEqual(run.task, "Open Settings")
        XCTAssertEqual(run.steps.count, 2)
        XCTAssertEqual(run.moves.count, 1)
        XCTAssertEqual(run.outcome, .done)
        XCTAssertNotNil(run.steps[0].frame)
        XCTAssertNotNil(run.duration)
        XCTAssertEqual(StepText.title(run.steps[0].action), "Tap at 500, 300")
        try? FileManager.default.removeItem(at: root)
    }

    func testIntentsAreSavedAndDeleted() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = IntentStore(defaults: defaults)
        XCTAssertFalse(store.items.isEmpty)  // seeded with the examples
        store.add(name: "", prompt: "Open Notes and write hello")
        XCTAssertEqual(store.items.first?.name, "Open Notes and write hello")
        XCTAssertEqual(IntentStore(defaults: defaults).items.count, store.items.count)
        store.delete(at: IndexSet(integer: 0))
        XCTAssertEqual(IntentStore(defaults: defaults).items.first?.name, IntentStore.examples[0].name)
    }
}
