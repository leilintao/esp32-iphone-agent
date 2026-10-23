# Orthogonal-firmware companion App — 1.0.6 (7)

The user supplied Google-assisted fixes after the 2026-10-23 diagnostic runs.
This App update preserves those iOS changes:

- A manually tapped pointer is a rough seed for stage-two touch fitting, not a
  final through-origin calibration. Fit slope and intercept before validation.
- While the calibration overlay is open, keep-awake may ping but must not nudge
  the pointer.
- Background debug-log callbacks hop to the main actor before relaying to BLE.
- Move timeouts include travel on both axes for the new sequential-axis firmware.

Companion changes added during verification:

- Bump the calibration verification generation: old diagonal-motion success
  cannot authorize runs on the new orthogonal-motion firmware.
- Five regression tests cover both-axis timeout accounting, heartbeat with
  nudges suppressed, normal idle nudges, manual seed offset fitting, and
  invalidation of the previous firmware's verification record.
- Version and build are distinct from the installed 1.0.5 (6).

The user reports the board firmware has already been flashed. No additional
board flash is performed for this App build. Firmware root-cause statements,
40-ms settling, zero-delta USB keep-alive and USB stability still require
real-phone evidence; host tests alone do not validate them.

Acceptance order: install this App without uninstalling the old one; confirm
version, USB and mirroring; perform touch calibration and all eight independent
checks; inspect a real Calculator frame and a single digit; only then run the
full calculation. Keep the 1.5% limit and keep Mac model-frame preview visible.
