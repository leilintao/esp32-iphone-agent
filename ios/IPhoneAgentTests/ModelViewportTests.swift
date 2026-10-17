import UIKit
import XCTest
@testable import IPhoneAgent

@MainActor final class ModelViewportTests: XCTestCase {
    private func source() -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 720, height: 1560), format: format)
            .jpegData(withCompressionQuality: 0.8) { context in
                UIColor.orange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 720, height: 1560))
            }
    }

    func testModelImageHasExactly1000PixelsAndPreservesAspect() throws {
        let viewport = ModelViewport(size: CGSize(width: 720, height: 1560))
        let image = try XCTUnwrap(UIImage(data: viewport.image(source())))
        XCTAssertEqual(image.cgImage?.width, 1000)
        XCTAssertEqual(image.cgImage?.height, 1000)
        XCTAssertEqual(viewport.content.width / viewport.content.height, 720.0 / 1560, accuracy: 0.00001)
        XCTAssertEqual(viewport.content.midX, 500)
        XCTAssertEqual(viewport.content.midY, 500)
    }

    func testReported1230PixelTargetCanNeverBeClampedToBottom() {
        let viewport = ModelViewport(size: CGSize(width: 720, height: 1560))
        XCTAssertThrowsError(try viewport.phoneAction(["action": .str("tap"), "x": .int(103), "y": .int(1230)]))
        XCTAssertThrowsError(try viewport.phoneAction(["action": .str("tap"), "x": .int(100), "y": .int(500)]),
                             "black letterbox padding is not part of the phone")
    }

    func testCalculatorOneButtonMapsToItsActualPhonePosition() throws {
        let viewport = ModelViewport(size: CGSize(width: 720, height: 1560))
        let canvas = viewport.canvasPoint(CGPoint(x: 103.0 / 720 * 1000, y: 1230.0 / 1560 * 1000))
        let action = try viewport.phoneAction(["action": .str("tap"), "x": .num(canvas.x), "y": .num(canvas.y)])
        XCTAssertEqual(action["x"]?.double ?? -1, 143, accuracy: 1)
        XCTAssertEqual(action["y"]?.double ?? -1, 788, accuracy: 1)
    }

    func testSwipePathAndCircleRoundTripForHistory() throws {
        let viewport = ModelViewport(size: CGSize(width: 720, height: 1560))
        for command in ["tap 500 500", "swipe 0 1000 1000 0", "swipe 300 700 700 300", "path 300 300 500 500 700 700", "circle 500 500 100"] {
            let phone = try Actions.parseCommand(command)
            let restored = try viewport.phoneAction(viewport.canvasAction(phone))
            for key in ["x", "y", "x1", "y1", "x2", "y2", "r"] where phone[key] != nil {
                XCTAssertEqual(restored[key]?.double ?? -1, phone[key]?.double ?? -100, accuracy: 2)
            }
            if case .arr(let points)? = restored["points"] {
                XCTAssertEqual(points.count, 3)
            }
        }
    }

    func testPreviewAndModelReceiveSameCanvasButGesturesRetainSourceFrame() async throws {
        let screen = FakeScreen(); let original = source()
        screen.frame = original; screen.modelViewport = ModelViewport(size: CGSize(width: 720, height: 1560))
        let model = FakeModel { _ in "DO: tap 500 500" }
        let agent = AgentLoop(phone: nil, screen: screen, actor: model, planner: model, trace: nil)
        var shown: Data?
        agent.onLook = { _, _, data, _ in shown = data }
        let actions = try await agent.nextActions()
        XCTAssertEqual(model.images.first!, shown)
        XCTAssertNotEqual(shown, original)
        XCTAssertEqual(UIImage(data: shown!)?.cgImage?.width, 1000)
        XCTAssertEqual(actions.first?.shot, original, "phone-side change detection must not compare against a padded image")
    }

    func testWholeInvalidBatchIsRejectedBeforeReturningAnyGesture() async throws {
        let screen = FakeScreen(); screen.frame = source()
        screen.modelViewport = ModelViewport(size: CGSize(width: 720, height: 1560))
        let model = FakeModel { n in n == 1 ? "DO: tap 500 500\nDO: tap 103 1230" : "DO: tap 500 500" }
        let agent = AgentLoop(phone: nil, screen: screen, actor: model, planner: model, trace: nil)
        let actions = try await agent.nextActions()
        XCTAssertEqual(model.prompts.count, 2)
        XCTAssertTrue(model.prompts[1].contains("Invalid target"))
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions[0].act["x"], .int(500))
        XCTAssertEqual(actions[0].act["y"], .int(500))
    }
}
