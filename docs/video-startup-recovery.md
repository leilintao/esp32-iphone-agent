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
