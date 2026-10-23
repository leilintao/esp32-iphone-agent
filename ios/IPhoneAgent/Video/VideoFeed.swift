import Foundation
import UIKit

/// What the agent and the pointer need from the screen (VideoFeed, or a fake in tests). Port of screen.py.
@MainActor protocol ScreenSource: AnyObject {
    var live: Bool { get }
    var frame: Data? { get }
    var updated: Double { get }
    var capturedAt: Double { get }
    var aspect: Double { get }
    var modelViewport: ModelViewport? { get }
    var unavailableReason: String? { get }
    /// After a gesture that ended at `since`: wait until the screen shows its result (and fetch it, in snap mode).
    func afterAction(since: Double) async
}

/// How a run gets its frames: the live stream (`stream on`, the default: a frame in under a second), or one
/// snap after each action (`stream off`; waits for the board's whole GOP, often 20-30 s).
enum FrameMode: String {
    case stream, snap
    static let key = "frameModeV2"  // V2: drops the old saved "snap" left by earlier automatic fallbacks
    /// A command timeout switches the current run to snap; not saved, so the next run streams again.
    static var fallback: FrameMode?
    static var current: FrameMode {
        get { fallback ?? FrameMode(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .stream }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key); fallback = nil }
    }
}

extension ScreenSource {
    var modelViewport: ModelViewport? { nil }
    var unavailableReason: String? { live ? nil : "no phone screen: start Screen Mirroring first" }
    func afterAction(since: Double) async { await settled() }

    /// Wait until the screen stops changing (AirPlay only sends frames on change). Mid-animation frames are big and
    /// can reach us late over BLE, so a gap is only "quiet" once it also covers the last frame's transport lag.
    func settled(quiet: Double = 0.5, least: Double = 0.3, most: Double = 4) async {
        let started = now()
        try? await Task.sleep(nanoseconds: UInt64(least * 1e9))
        while now() - updated < quiet + lag && now() - started < most {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// How late the shown frame arrived after the board got it (0 when unknown), capped.
    private var lag: Double { capturedAt > 0 ? min(max(updated - capturedAt, 0), 1) : 0 }

    /// The first frame captured after `since` (received, when capture times are unknown), or nil if none in time.
    func fresh(since: Double, timeout: Double = 0.8) async -> Data? {
        let deadline = now() + timeout
        while (capturedAt > 0 ? capturedAt : updated) <= since {
            if now() > deadline { return nil }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return frame
    }
}

/// The phone's screen, mirrored over AirPlay to the board and forwarded over BLE, as JPEG frames.
@MainActor final class VideoFeed: ObservableObject, ScreenSource {
    @Published private(set) var frame: Data?
    @Published private(set) var size = CGSize.zero
    @Published private(set) var note = ""  // last decoder problem, shown in Diagnostics
    private(set) var updated = 0.0
    /// When the board received the shown frame, in local time (≈; see `boardClock`).
    private(set) var capturedAt = 0.0
    /// A decode error or a lost chunk since the last good frame: the shown frame is stale until the next IDR.
    private(set) var broken = false
    private var snapRevision = 0
    private var frameBoardMs: UInt32?
    private var clockOffset: Double?  // local s − board s, the smallest seen (≈ the link latency)
    var mirroring = false  // board status says ap == streaming
    var metrics: Metrics?
    weak var device: HIDDevice?

    private var assembler = VideoAssembler()
    private let decoder: H264Decoder
    private let clock: () -> Double
    static let maxFrameAge: Double = 10

    init(decoder: H264Decoder = H264Decoder(), clock: @escaping () -> Double = now) {
        self.decoder = decoder
        self.clock = clock
        decoder.onFrame = { [weak self] f in DispatchQueue.main.async { self?.publish(f) } }
        decoder.onError = { [weak self] msg in
            DispatchQueue.main.async {
                let bg = UIApplication.shared.applicationState == .background
                self?.note = bg ? "\(msg) [in background]" : msg
                self?.metrics?.decodeError(background: bg)
                self?.broken = true
            }
        }
    }

    var live: Bool { unavailableReason == nil }

    var unavailableReason: String? {
        if let reason = transportProblem { return reason }
        if broken { return "视频解码或传输中断，正在等待可解码的新画面；请重新开启屏幕镜像" }
        if frame == nil { return "已连接投屏，但尚未收到可解码的手机画面" }
        if !usable(maxAge: Self.maxFrameAge) {
            return String(format: "画面延迟 %.2f 秒，超过 %.0f 秒安全上限；请重新开启屏幕镜像以清除积压", frameAge, Self.maxFrameAge)
        }
        return nil
    }

    private var transportProblem: String? {
        if device?.connected != true { return "开发板蓝牙未连接，请先连接开发板" }
        if !mirroring { return "屏幕镜像尚未连接，请开启屏幕镜像并选择 ESP32 Agent" }
        // vwait means the cache lost its IDR anchor. A warm decoder may still be receiving a
        // continuous, decodable tail (vcont); only a stalled one needs a keyframe.
        if metrics?.board?.vwait == 1 && metrics?.board?.vcont != 1 {
            return "视频正在等待关键帧（缓存溢出次数：\(metrics?.board?.vover ?? 0)），请停止并重新开启屏幕镜像"
        }
        return nil
    }

    var frameAge: Double { capturedAt > 0 ? max(0, clock() - capturedAt) : .infinity }

    var diagnosticState: String {
        String(format: "connected=%@ mirroring=%@ stream=%@ frame=%@ broken=%@ age=%.2fs waitIDR=%d liveTail=%d overflow=%d pending=%d gop=%d/%d quietTail=%@",
               String(device?.connected ?? false), String(mirroring), String(streamOn), String(frame != nil),
               String(broken), frameAge, metrics?.board?.vwait ?? -1, metrics?.board?.vcont ?? -1,
               metrics?.board?.vover ?? -1, metrics?.board?.vpending ?? -1,
               metrics?.board?.gop ?? -1, metrics?.board?.gopcap ?? -1, String(verifiedQuietTail))
    }

    // AirPlay may send NO frames on an unchanged screen. Only a recent board watermark
    // proving that our decoded frame is its latest AU, with no pending backlog, may
    // validate an old still. Never replace capture time with receive time.
    private var verifiedQuietTail: Bool {
        guard let metrics, metrics.hasRecentStatus, let s = metrics.board,
              s.ap == "streaming", s.vwait == 0 || s.vcont == 1, s.vpending == 0,
              let up = s.up, let age = s.vage, age >= 0, age < Int(UInt32.max),
              let frameBoardMs else { return false }
        let latest = UInt32(truncatingIfNeeded: up - age)
        return abs(Int(Int32(bitPattern: latest &- frameBoardMs))) <= 5
    }

    private func usable(maxAge: Double) -> Bool {
        frame != nil && !broken && (frameAge < min(maxAge, Self.maxFrameAge) || verifiedQuietTail)
    }

    /// Frame width / height (portrait iPhone as a fallback).
    var aspect: Double { size.width > 0 && size.height > 0 ? size.width / size.height : 9 / 19.5 }
    var modelViewport: ModelViewport? { size.width > 0 && size.height > 0 ? ModelViewport(size: size) : nil }

    /// One `video` notify from BoardLink.
    func receive(_ chunk: Data) {
        metrics?.videoBytes(chunk.count)
        let dropsBefore = assembler.drops
        let unit = assembler.add(chunk)
        if assembler.drops > dropsBefore { metrics?.videoDrops(assembler.drops - dropsBefore); broken = true }
        guard let unit else { return }
        if !unit.snap { boardClock(ms: Int(unit.boardMs)) }  // snap units are resent late: their ages say nothing
        if unit.idr { metrics?.idrSeen() }
        decoder.queue.async { [decoder] in decoder.decode(unit) }
    }

    /// The link (re)connected: chunk numbering starts over.
    func resetStream() {
        assembler.reset()
        clockOffset = nil
        frame = nil
        updated = 0
        capturedAt = 0
        frameBoardMs = nil
        broken = true
        streamOn = false
    }

    /// A board timestamp (status `up`, or a streamed unit) just arrived: keep the smallest offset.
    func boardClock(ms: Int) {
        let offset = clock() - Double(ms) / 1000
        clockOffset = min(clockOffset ?? offset, offset)
    }

    /// Show a still frame (demo data).
    func show(_ jpeg: Data, width: Int, height: Int) {
        publish(H264Decoder.Frame(jpeg: jpeg, width: width, height: height, decodeMs: 4.2,
                                  unit: AccessUnit(data: Data(), idr: false, config: false, snap: false, boardMs: 0)))
    }

    private func publish(_ f: H264Decoder.Frame) {
        frame = f.jpeg
        frameBoardMs = f.unit.boardMs
        if f.unit.snap { snapRevision += 1 }
        updated = clock()
        capturedAt = clockOffset.map { Double(f.unit.boardMs) / 1000 + $0 } ?? updated
        broken = false
        if size.width != CGFloat(f.width) || size.height != CGFloat(f.height) {
            size = CGSize(width: f.width, height: f.height)
        }
        metrics?.frameDecoded(ms: f.decodeMs)
    }

    /// The app asked the board to forward the stream (`stream on`).
    private(set) var streamOn = false

    /// Firmware spends at most 20s transferring a snap. Allow queue/chunk latency and decode delivery;
    /// a shorter client deadline would abandon a request while the board was still sending it.
    var snapTimeout: Double {
        30
    }

    /// Prefer a very recent live frame. If delivery is progressing, let it catch up before requesting
    /// a whole GOP again. A SNAP ACK/decoded frame is not proof of freshness: after a slow replay,
    /// wait for the live tail, and only return a frame which passes the SAME check as AgentLoop.start.
    @discardableResult
    func currentFrame(maxAge: Double = 1, wait: Double = 3, catchUp: Double = 15) async throws -> String {
        try Task.checkCancellation()
        if let reason = transportProblem { throw DeviceError(message: reason) }
        let before = updated
        if streamOn {
            if usable(maxAge: maxAge) { return "live" }
            if try await waitForUsable(maxAge: maxAge, timeout: wait) { return "live (waited)" }
            // The initial IDR/GOP can take >3s over BLE. Replaying it again adds backlog.
            if updated > before {
                DebugLog.write("frame: live delivery progressing; waiting for tail; \(diagnosticState)")
                if try await waitForUsable(maxAge: Self.maxFrameAge, timeout: catchUp) {
                    return "live (caught up)"
                }
                throw DeviceError(message: unavailableReason ?? "视频传输积压，尚未追上实时画面")
            }
        }
        // A second request cannot cancel a timed-out first transfer on older firmware; it only
        // adds another whole GOP to the backlog. Fail clearly instead of automatically doubling it.
        try await snap()
        if live { return "snap" }
        DebugLog.write("frame: decoded snap is not ready; waiting for live tail; \(diagnosticState)")
        if try await waitForUsable(maxAge: Self.maxFrameAge, timeout: catchUp) {
            return "snap (caught up)"
        }
        throw DeviceError(message: unavailableReason ?? "截图已解码，但尚未收到实时画面")
    }

    private func waitForUsable(maxAge: Double, timeout: Double) async throws -> Bool {
        let deadline = now() + max(0, timeout)
        while true {
            try Task.checkCancellation()
            if let reason = transportProblem { throw DeviceError(message: reason) }
            if usable(maxAge: maxAge) { return true }
            if now() >= deadline { return false }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Ask the board for the current GOP and wait until it is decoded. Returns the latency in ms.
    @discardableResult
    func snap(timeout: Double? = nil) async throws -> Double {
        guard let device else { throw DeviceError(message: "board not connected") }
        let started = now()
        let revision = snapRevision
        if let channel = device as? CommandChannel {
            try await channel.send("snap", timeout: timeout ?? snapTimeout)
        } else {
            try await device.send("snap")
        }
        await withCheckedContinuation { c in decoder.queue.async { c.resume() } }  // the GOP is decoded
        try? await Task.sleep(nanoseconds: 30_000_000)  // let the last frame reach the main queue
        guard snapRevision > revision, frame != nil, !broken else {
            throw DeviceError(message: "截图传输完成，但没有解码出新的画面；请重新开启屏幕镜像")
        }
        let ms = (now() - started) * 1000
        DebugLog.write(String(format: "frame: snap decoded; capture age %.2fs, transfer %.0fms", frameAge, ms))
        metrics?.snapLatency(ms)
        return ms
    }

    func stream(_ on: Bool) async throws {
        try await device?.send("stream \(on ? "on" : "off")")
        streamOn = on
    }

    /// The model must never see a frame from before the action that ended at `since`. Stream: let the screen
    /// settle, then wait (bounded) for a frame captured after the action; none while the stream is healthy means
    /// the screen did not change, but a broken stream (waiting for an IDR) needs a snap. Snap: give the UI a moment,
    /// snap, and snap once more if the GOP still ends before the action.
    func afterAction(since: Double) async {
        do {
            if FrameMode.current == .snap {
                try await Task.sleep(nanoseconds: 700_000_000)
                try await currentFrame()
                guard capturedAt < since else { return }
                DebugLog.write(String(format: "frame: snap ends %.1f s before the action; snapping again", since - capturedAt))
                try await Task.sleep(nanoseconds: 500_000_000)
                try await currentFrame()
            } else {
                await settled()
                if await newer(than: since, timeout: 1.5) { return }
                guard broken || !streamOn else { return DebugLog.write("frame: none after the action; screen unchanged") }
                DebugLog.write("frame: stream stale (waiting for an IDR); snapping")
                try await snap()
            }
        } catch {
            DebugLog.write("frame after action failed: \(error.localizedDescription)")
        }
        if capturedAt < since { DebugLog.write(String(format: "frame: still %.1f s older than the action", since - capturedAt)) }
    }

    /// Waits until the shown frame was captured after `t`; false on timeout.
    private func newer(than t: Double, timeout: Double) async -> Bool {
        let deadline = now() + timeout
        while capturedAt < t {
            if now() > deadline { return false }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return true
    }

    /// The link dropped: the board forgets `stream on`.
    func linkLost() { streamOn = false; broken = true }
}
