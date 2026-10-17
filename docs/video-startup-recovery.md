# Startup and video recovery changes

The exported logs showed a second task starting while the first task was still
waiting for its initial snapshot. The shared trace/video destination was replaced,
so the first task's error appeared in the second task's trace.

- `AppModel.starting` covers departure, calibration and the first-frame wait.
  Repeated starts and demonstration recording are rejected during this phase.
  Stop marks startup cancelled; the gate remains held until its cleanup finishes.
- Each trace directory has a unique suffix; old timestamp-only traces still load.
- Live firmware video delivery yields after four BLE chunks, keeping its chunk
  cursor across iterations. A queued snapshot interrupts partial live delivery
  and begins with CONFIG/START. Successful snapshots resume live delivery after
  the transmitted GOP, rather than transmitting that GOP twice.
- Snapshot transfers have one 20-second firmware budget across all generation
  retries. The app waits 30 seconds, and no longer automatically adds a second
  snapshot to an already stalled transfer.
- A snapshot ACK alone is insufficient: the app requires a newly decoded SNAP
  frame. Reconnection clears the displayed frame; broken/old frames aren't live.
- Oversized access units invalidate the GOP instead of permanently wedging the
  transmitter at an unsendable unit. Recovery still requires a normal new IDR.

Firmware status adds `vwait` (0/1, waiting for IDR), `vover` (GOP overflow count),
`vage` (milliseconds since the latest accepted AU; UINT32_MAX when none), and
`vlarge` (AUs larger than the 512-KiB transmit scratch). These also appear in
reduced status notifications, App Diagnostics, and debug logs. Serial/BLE
`<id> status` returns the full JSON for diagnostics. Incoming FPS is reported as
zero while the cache is waiting for IDR, even if undecodable P-frames arrive.

A cache overflow was a plausible explanation for the supplied failure, not
proven by the old logs: they did not contain these counters. These changes do
not request IDRs from AirPlay or bypass screen-capture restrictions. If the GOP
is invalid and a fresh IDR doesn't arrive, stop and restart Screen Mirroring.
Enterprise apps that prohibit capture remain unsupported on this video path.

Validation: build with `hardware/flash.sh --display-es3c28p --build-only`;
host buffer/chunker tests in `hardware/tests`; iOS startup, trace-isolation,
video-health merge, reconnect and snapshot-ACK regression tests in the normal
iOS unit-test suite. The GitHub IPA workflow runs that suite on an available
iPhone simulator before archiving. Real phone AirPlay/BLE latency and HID actions
must still be checked after installing the new IPA and board firmware together.

## Follow-up: slow snapshot accepted, then rejected at startup (1.0.1 build 2)

A real-phone trace exposed an uncovered interaction: a SNAP took 13.97 seconds
and decoded successfully, but the resulting frame was 13.58 seconds old. The
snapshot path returned success without a freshness check; `AgentLoop.start`
then rejected it against `VideoFeed.live`'s 10-second limit with a generic
"start Screen Mirroring" error. AirPlay was streaming and overflow was zero.

`VideoFeed.currentFrame` now returns only when the same readiness rule as
`VideoFeed.live` is satisfied (connected, mirroring, decoded/unbroken, not
waiting for IDR, capture age strictly below 10 seconds). Initial live delivery
which advances while waiting gets up to 15 additional seconds to catch up,
without requesting another complete GOP. A decoded but stale SNAP similarly
waits up to 15 seconds for the live tail, then fails explicitly with frame age.
It never refreshes a capture timestamp just because an old frame was received.
Direct `snap()` remains a low-level transfer/decode diagnostic, not a freshness
guarantee. Non-streaming snapshots that remain stale fail the same safety rule.

The startup log and failure trace include connected/mirroring/stream/frame/
broken/age/waitIDR/overflow values. No board firmware change is required.
Regression tests reproduce the 13.58-second-old SNAP, a fresh tail arriving
later, live catch-up without a duplicate SNAP, the 10-second boundary, task
cancellation, and connection/keyframe failure messages. An injected decoder
output and clock avoid waiting 14 real seconds or requiring physical hardware.

## Firmware follow-up: continuous transfer backlog

The two latest real-phone runs (21:09:13 and 21:09:58) failed at capture ages
22.95s and 16.29s. Both had connected/mirroring/stream/frame=true,
broken=false, waitIDR=0 and overflow=0. Thus the 1.0.1 check was correctly
rejecting old video, but waiting alone could not fix the underlying backlog.

The firmware's one-second controller-credit cap was refreshed by every BLE
write, including routine heartbeat pings and debug relays. These no longer
refresh the cap; actual HID/control commands still do. Queued control replies
retain unconditional priority and reserved NimBLE buffers. Live delivery no
longer adds a 20ms sleep between AUs while a GOP backlog remains. The video
payload MTU is chosen from video subscribers only, not read-only observers.

Status adds `vtxage` (milliseconds since the last fully forwarded video AU's
capture, UINT32_MAX before the first) and `vpending` (estimated unsent AUs in
the current GOP). These are board-side send diagnostics, not proof of iPhone
decode or task completion. A phone receiving a 256KiB synthetic BLE transfer
completed it in 7883ms (~266kbps) while a separate observer sent pings every
250ms; maximum measured ping round-trip was 49ms. This was not a live AirPlay
end-to-end acceptance test; the real Whiteboard run remains to be verified.

The `--debug` flag now uses the project-specific `AGENT_DEBUG_SERIAL` macro,
avoiding collision with Adafruit BusIO's `DEBUG_SERIAL` stream macro. The flash
script tolerates the normal temporary absence of a serial port during USB
bootloader re-enumeration. Screen and greeting support remain enabled.

### Interrupted sends and pause/resume

The live Whiteboard test reached the model and executed HID gestures, but a
temporary send failure replayed ~190 seconds / 720 AUs of history. The sender
now commits its cursor and sequence number only after a successful enqueue;
failed first/middle/end chunks retry byte-for-byte. Only a real VIDEO
subscription/disconnection epoch or a new GOP resets decoder synchronization.
`stream off/on` preserves the current cursor while that decoder stays subscribed.
The host test injects failures in all three chunk positions, including sequence wrap.

App 1.0.2 (3) warms the stream when mirroring starts and keeps it warm between
runs. A bounded 45-second startup catch-up exposes progress and supports actual
cancellation. An unchanged old frame is usable ONLY with a recent (<3s) board
status proving an exact latest-AU watermark, zero backlog and no keyframe failure.
The capture timestamp itself is never changed to make a frame appear newer.

The calculator tests on 1.0.1 (2) have NOT passed acceptance: one start failed
on historical video and a warm attempt repeatedly clicked without a confirmed
5535 result. No success is inferred from command acknowledgements. New firmware
and App still require the same real-phone acceptance after installation.

### Model-frame viewer

`hardware/tools/live_preview.py` opens a loopback-only viewer on port 8765.
With App 1.0.2 (3) in the foreground, it authorizes a one-hour session through
the existing board debug relay and receives model screenshots directly from
the phone over a separate Bluetooth GATT service. It never subscribes to board
VIDEO or sends HID/task commands. Each `look` event contains the exact JPEG
passed to the model, a call UUID, role and capture age; subsequent decisions and
executed actions reference that UUID. Screenshots are recorded BEFORE model
requests, so failed/cancelled API calls retain evidence too. Existing trace
replay remains compatible with older frame-on-llm records.

The web page marks history, connection loss and the distinction between a
decision screenshot and continuous video. It retains up to 120 events/images
in memory, uses no cloud uploads or external assets and requires a per-session
128-bit token before serving screenshots. Ctrl-C revokes the session when the
board is reachable; otherwise it expires after one hour. First discovery must
happen with the iPhone app in front; background reconnection is not guaranteed.
Actual phone-to-Mac throughput/background delivery remains to be verified.
