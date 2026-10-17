import XCTest
@testable import IPhoneAgent

/// `video` chunk reassembly (docs/ble-protocol.md).
final class VideoTests: XCTestCase {
    private func decoded(ms: UInt32, snap: Bool) -> H264Decoder.Frame {
        H264Decoder.Frame(jpeg: Data([0xff, 0xd8]), width: 480, height: 1040, decodeMs: 1,
                          unit: AccessUnit(data: Data(), idr: true, config: false, snap: snap, boardMs: ms))
    }

    @MainActor func testOldStillNeedsExactRecentBoardWatermarkAndNoBacklog() async throws {
        var time = 100.0
        let decoder = H264Decoder()
        let feed = VideoFeed(decoder: decoder, clock: { time })
        let device = FakeDevice()
        let metrics = Metrics()
        feed.device = device; feed.metrics = metrics; feed.mirroring = true
        feed.boardClock(ms: 30_000)
        decoder.onFrame?(decoded(ms: 30_000, snap: false))
        try await Task.sleep(nanoseconds: 20_000_000)
        time = 120
        XCTAssertFalse(feed.live)
        metrics.status(BoardStatus(up: 50_000, ap: "streaming", vwait: 0, vage: 20_000, vpending: 0))
        XCTAssertTrue(feed.live, "unchanged calculator screen is current, not a transport failure")
        XCTAssertEqual(feed.frameAge, 20, accuracy: 0.001, "must not falsify capture timestamp")
        metrics.status(BoardStatus(up: 50_000, ap: "streaming", vwait: 0, vage: 20_000, vpending: 1))
        XCTAssertFalse(feed.live, "a pending AU must never count as a quiet tail")
        metrics.status(BoardStatus(up: 50_000, ap: "streaming", vwait: 0, vage: 19_000, vpending: 0))
        XCTAssertFalse(feed.live, "board has a different, newer frame")
        metrics.status(BoardStatus(up: 50_000, ap: "streaming", vwait: 1, vage: 20_000, vpending: 0))
        XCTAssertFalse(feed.live, "keyframe failure overrides a matching timestamp")
        metrics.status(BoardStatus(up: 50_000, ap: "streaming", vwait: 0, vage: 20_000, vpending: 0))
        XCTAssertTrue(feed.live)
        try await Task.sleep(nanoseconds: 3_050_000_000)
        XCTAssertFalse(feed.live, "old cached status isn't proof of a current still frame")
    }

    @MainActor func testLogged1358SecondOldSnapIsNotReportedAsReady() async {
        let decoder = H264Decoder()
        let feed = VideoFeed(decoder: decoder, clock: { 100 })
        let device = FakeDevice()
        feed.device = device
        feed.mirroring = true
        feed.boardClock(ms: 30_000) // offset 70s; board 16420ms = local 86.42s
        device.onSend = { command in
            if command == "snap" { decoder.onFrame?(self.decoded(ms: 16_420, snap: true)) }
        }
        do {
            // Even an overly permissive caller cannot override the shared 10s safety limit.
            try await feed.currentFrame(maxAge: 60, wait: 0, catchUp: 0.06)
            XCTFail("the logged failure must now be rejected inside currentFrame, not later by start")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("画面延迟"))
            XCTAssertFalse(error.localizedDescription.contains("开启屏幕镜像并选择"))
        }
        XCTAssertEqual(feed.frameAge, 13.58, accuracy: 0.001)
        XCTAssertFalse(feed.live)
        XCTAssertEqual(device.sent, ["snap"])
    }

    @MainActor func testSlowSnapWaitsForFreshTailBeforeReturning() async throws {
        let decoder = H264Decoder()
        let feed = VideoFeed(decoder: decoder, clock: { 100 })
        let device = FakeDevice()
        feed.device = device
        feed.mirroring = true
        feed.boardClock(ms: 30_000)
        try await feed.stream(true)
        var tail: Task<Void, Never>?
        defer { tail?.cancel() }
        device.onSend = { command in
            guard command == "snap" else { return }
            decoder.onFrame?(self.decoded(ms: 16_420, snap: true))
            tail = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard !Task.isCancelled else { return }
                XCTAssertFalse(feed.live, "a newly received but old SNAP must not become live")
                decoder.onFrame?(self.decoded(ms: 30_000, snap: false))
            }
        }
        let source = try await feed.currentFrame(wait: 0, catchUp: 1)
        XCTAssertEqual(source, "snap (caught up)")
        XCTAssertTrue(feed.live, "every successful frame return must also pass AgentLoop.start's check")
        XCTAssertEqual(device.sent.filter { $0 == "snap" }.count, 1)
    }

    @MainActor func testProgressingLiveGOPCatchesUpWithoutDuplicateSnapshot() async throws {
        let decoder = H264Decoder()
        let feed = VideoFeed(decoder: decoder, clock: { 100 })
        let device = FakeDevice()
        feed.device = device
        feed.mirroring = true
        feed.boardClock(ms: 30_000)
        try await feed.stream(true)
        let tail = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 20_000_000)
            guard !Task.isCancelled else { return }
            decoder.onFrame?(self.decoded(ms: 16_420, snap: false))
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            decoder.onFrame?(self.decoded(ms: 30_000, snap: false))
        }
        defer { tail.cancel() }
        let source = try await feed.currentFrame(wait: 0.1, catchUp: 1)
        XCTAssertEqual(source, "live (caught up)")
        XCTAssertTrue(feed.live)
        XCTAssertFalse(device.sent.contains("snap"))
    }

    @MainActor func testFreshnessBoundaryIsSharedAndDoesNotUseReceiveTime() {
        var time = 100.0
        let feed = VideoFeed(clock: { time })
        let device = FakeDevice()
        feed.device = device
        feed.mirroring = true
        feed.show(Data([0xff, 0xd8]), width: 480, height: 1040)
        time = 109.99
        XCTAssertTrue(feed.live)
        time = 110
        XCTAssertFalse(feed.live)
        XCTAssertTrue(feed.unavailableReason?.contains("画面延迟") == true)
    }

    @MainActor func testCancellationInterruptsStaleSnapCatchUp() async {
        let decoder = H264Decoder()
        let feed = VideoFeed(decoder: decoder, clock: { 100 })
        let device = FakeDevice()
        feed.device = device
        feed.mirroring = true
        feed.boardClock(ms: 30_000)
        device.onSend = { command in
            if command == "snap" { decoder.onFrame?(self.decoded(ms: 16_420, snap: true)) }
        }
        let request = Task { try await feed.currentFrame(wait: 0, catchUp: 15) }
        try? await Task.sleep(nanoseconds: 100_000_000)
        request.cancel()
        do {
            _ = try await request.value
            XCTFail("cancelled startup must not continue waiting or start the agent")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    @MainActor func testTransportFailuresAreNotMisreportedAsFrameDelay() async throws {
        let feed = VideoFeed()
        let device = FakeDevice()
        feed.device = device
        feed.mirroring = true
        feed.show(Data([0xff, 0xd8]), width: 480, height: 1040)
        device.connected = false
        XCTAssertTrue(feed.unavailableReason?.contains("蓝牙") == true)
        device.connected = true
        feed.mirroring = false
        XCTAssertTrue(feed.unavailableReason?.contains("屏幕镜像尚未连接") == true)
        feed.mirroring = true
        let metrics = Metrics()
        metrics.status(try XCTUnwrap(BoardStatus.decode(Data(#"{"vwait":1,"vover":2}"#.utf8))))
        feed.metrics = metrics
        do {
            try await feed.currentFrame(wait: 0, catchUp: 0)
            XCTFail("a fresh frame must not bypass waiting-keyframe state")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("关键帧"))
        }
        XCTAssertFalse(feed.live)
        XCTAssertTrue(device.sent.isEmpty)
    }

    @MainActor func testReconnectAndLinkLossDoNotExposeAnOldFrameAsLive() {
        let feed = VideoFeed()
        let device = FakeDevice()
        feed.device = device
        feed.mirroring = true
        feed.show(Data([0xff, 0xd8]), width: 480, height: 1040)
        XCTAssertTrue(feed.live)
        feed.linkLost()
        XCTAssertFalse(feed.live)
        feed.resetStream()
        XCTAssertNil(feed.frame)
        XCTAssertEqual(feed.capturedAt, 0)
        XCTAssertFalse(feed.live)
    }

    @MainActor func testSnapAcknowledgementWithoutDecodedImageFails() async {
        let feed = VideoFeed()
        let device = FakeDevice()
        feed.device = device
        feed.show(Data([0xff, 0xd8]), width: 480, height: 1040)
        do {
            try await feed.snap()
            XCTFail("a command ACK must not pass off the old image as a new snapshot")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("没有解码出新的画面"))
        }
    }

    typealias F = VideoAssembler.Flags

    func chunk(_ seq: UInt16, _ flags: F, _ payload: [UInt8], ms: UInt32? = nil) -> Data {
        var d = Data([UInt8(seq & 0xff), UInt8(seq >> 8), flags.rawValue])
        if let ms { d.append(contentsOf: [UInt8(ms & 0xff), UInt8(ms >> 8 & 0xff), UInt8(ms >> 16 & 0xff), UInt8(ms >> 24)]) }
        d.append(contentsOf: payload)
        return d
    }

    let sps: [UInt8] = [0, 0, 0, 1, 0x67, 1, 2]
    let idr: [UInt8] = [0, 0, 0, 1, 0x65, 9, 9]
    let p: [UInt8] = [0, 0, 0, 1, 0x41, 7]

    func testInOrderChunksMakeAccessUnits() {
        var a = VideoAssembler()
        XCTAssertEqual(a.add(chunk(0, [.start, .end, .config], sps, ms: 1000))?.config, true)
        XCTAssertNil(a.add(chunk(1, [.start, .idr], Array(idr[0..<5]), ms: 1001)))
        let unit = a.add(chunk(2, [.end, .idr], Array(idr[5...])))
        XCTAssertEqual(unit, AccessUnit(data: Data(idr), idr: true, config: false, snap: false, boardMs: 1001))
        XCTAssertEqual(a.add(chunk(3, [.start, .end], p, ms: 1200))?.data, Data(p))
        XCTAssertEqual(a.drops, 0)
    }

    func testGapDropsUntilTheNextKeyUnit() {
        var a = VideoAssembler()
        _ = a.add(chunk(10, [.start, .end, .idr], idr, ms: 1))
        XCTAssertNil(a.add(chunk(11, [.start], p, ms: 2)))
        XCTAssertNil(a.add(chunk(13, [.end], p)))           // 12 lost: the half unit is dropped
        XCTAssertEqual(a.drops, 1)
        XCTAssertNil(a.add(chunk(14, [.start, .end], p, ms: 3)))  // a P-frame after a gap is useless
        XCTAssertNotNil(a.add(chunk(15, [.start, .end, .config], sps, ms: 4)))  // recovered on CONFIG
        XCTAssertNotNil(a.add(chunk(16, [.start, .end], p, ms: 5)))
    }

    func testRecoversOnIDRAndWrapsSeq() {
        var a = VideoAssembler()
        _ = a.add(chunk(65534, [.start, .end, .idr], idr, ms: 1))
        XCTAssertNotNil(a.add(chunk(65535, [.start, .end], p, ms: 2)))
        XCTAssertNotNil(a.add(chunk(0, [.start, .end], p, ms: 3)))  // u16 wrap is not a gap
        XCTAssertEqual(a.drops, 0)
        XCTAssertNil(a.add(chunk(5, [.start, .end], p, ms: 4)))
        XCTAssertEqual(a.drops, 4)
        let unit = a.add(chunk(6, [.start, .end, .idr, .snap], idr, ms: 5))
        XCTAssertEqual(unit?.snap, true)
    }

    func testWaitsForAKeyUnitAtStartAndIgnoresBench() {
        var a = VideoAssembler()
        XCTAssertNil(a.add(chunk(0, [.start, .end], p, ms: 1)))
        XCTAssertNil(a.add(chunk(1, [.bench], [UInt8](repeating: 0, count: 100))))
        XCTAssertEqual(a.benchBytes, 103)
        XCTAssertNotNil(a.add(chunk(2, [.start, .end, .idr], idr, ms: 2)))
    }

    func testAnnexBSplitsNALUnits() {
        let units = annexBUnits(Data(sps + [0, 0, 1, 0x68, 5] + idr))
        XCTAssertEqual(units.map { $0.first! & 0x1f }, [7, 8, 5])
        XCTAssertEqual(units[0], Data([0x67, 1, 2]))
    }
}
