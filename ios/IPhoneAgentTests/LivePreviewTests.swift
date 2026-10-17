import XCTest
@testable import IPhoneAgent

@MainActor final class LivePreviewTests: XCTestCase {
    func testBinaryAuthorizationFitsDefaultATTAndRetainsFullToken() {
        let token = "00112233445566778899aabbccddeeff"
        let binary = Data(stride(from: 0, through: 255, by: 17).map { UInt8($0) })
        XCTAssertEqual(binary.count, 16)
        XCTAssertTrue(PreviewAuthorization.matches(binary, token: token))
        XCTAssertTrue(PreviewAuthorization.matches(Data(token.utf8), token: token))
        XCTAssertFalse(PreviewAuthorization.matches(binary.dropLast(), token: token))
        XCTAssertFalse(PreviewAuthorization.matches(Data(repeating: 0, count: 16), token: token))
        XCTAssertFalse(PreviewAuthorization.matches(binary, token: nil))
    }

    func testReauthenticationDiscardsPartialOldMessage() {
        var outbox = PreviewOutbox()
        outbox.enqueue(Data([0, 0, 0, 8, 1, 2, 3, 4, 5, 6, 7, 8]))
        outbox.commit(7)
        XCTAssertEqual(outbox.peek(limit: 4), Data([4, 5, 6, 7]))
        outbox.reset()
        outbox.enqueue(Data([0, 0, 0, 2, 9, 10]))
        XCTAssertEqual(outbox.peek(limit: 4), Data([0, 0, 0, 2]), "new receiver must start at the header, not an old JPEG tail")
    }

    func testBackpressureRetriesIdenticalPreviewBytesAndKeepsQueueBounded() {
        var outbox = PreviewOutbox()
        outbox.enqueue(Data([1, 2, 3, 4]))
        let first = outbox.peek(limit: 2)
        XCTAssertEqual(outbox.peek(limit: 2), first)
        outbox.commit(2)
        for n in 10..<30 { outbox.enqueue(Data([UInt8(n)])) }
        XCTAssertEqual(outbox.packets.count, 8)
        XCTAssertEqual(outbox.peek(limit: 2), Data([3, 4]), "dropping an unsent event must preserve the partial first event")
    }

    func testLookPrecedesModelAndUsesIdenticalBytes() async throws {
        let screen = FakeScreen()
        screen.frame = Data([0xff, 0xd8, 11, 22])
        let expected = screen.frame
        var order: [String] = []
        var lookID = ""
        let model = InspectingModel { data in
            order.append("model")
            XCTAssertEqual(data, expected)
            screen.frame = Data([0xff, 0xd8, 33]) // a later screen must never replace the decision image
        }
        let agent = AgentLoop(phone: nil, screen: screen, actor: model, planner: model, trace: nil)
        agent.onLook = { id, role, data, _ in
            order.append("look")
            lookID = id
            XCTAssertEqual(role, "actor")
            XCTAssertEqual(data, expected)
        }
        agent.onDecision = { id, actions in
            XCTAssertEqual(id, lookID)
            XCTAssertFalse(actions.joined().contains("thought"))
        }
        let acts = try await agent.nextActions()
        XCTAssertEqual(order, ["look", "model"])
        XCTAssertEqual(acts.first?.lookID, lookID)
        XCTAssertEqual(acts.first?.shot, expected)
    }

    func testFailedModelStillKeepsItsInputScreenshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let trace = TraceStore(root: root)
        trace.start(task: "calculate")
        let model = InspectingModel { _ in throw LLMError(message: "offline") }
        let agent = AgentLoop(phone: nil, screen: FakeScreen(), actor: model, planner: model, trace: trace)
        do { _ = try await agent.nextActions(); XCTFail("expected error") } catch {}
        let dir = try XCTUnwrap(trace.dir)
        let text = try String(contentsOf: dir.appendingPathComponent("steps.jsonl"))
        XCTAssertTrue(text.contains("\"kind\": \"look\""))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("002.jpg").path))
    }

    func testPreviewRejectsInvalidAuthorizationWithoutStartingBluetooth() {
        let preview = LivePreview()
        XCTAssertFalse(preview.enable("short"))
        XCTAssertFalse(preview.enable(String(repeating: "z", count: 32)))
    }
}

@MainActor private final class InspectingModel: ChatModel {
    let model = "inspection"
    let inspect: (Data?) throws -> Void
    init(_ inspect: @escaping (Data?) throws -> Void) { self.inspect = inspect }
    func chat(system: String, text: String, image: Data?, maxTokens: Int, temperature: Double) async throws -> ChatResult {
        try inspect(image)
        return ChatResult(text: "THINK: input frame checked\nDO: done ok", firstToken: nil, total: 0)
    }
}
