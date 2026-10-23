# Calibration validation hardening — 1.0.5 (6)

Real-phone evidence on 2026-10-23 showed a centre check error of 0.6%, but
the pointer aimed at Calculator 1 landed about 4% of screen height above its
centre. A manual relative correction then produced an actual 1. This proves
the previous single check was insufficient, not that the mapping is repaired.

The new App fails closed:

- Task startup checks verification, aspect and drift, not merely a saved span.
- Legacy calibration files remain readable but require new validation once.
- Four independent positions include both lower sides of the screen. They are
  tested from home and again with relative moves (eight real touch checks).
- Missing touches, excessive error, cancellation or loss of foreground/USB/
  mirroring cannot become success. Fit residual over 1.5% also rejects the fit;
  the 1.90% residual measured today would now be rejected, not hidden by the
  good centre check. Failed touch verification does not fall through to vision
  and overwrite the failure with a success.
- The reported quality is the worst independent check, not the last one.
- Manual calibration and video fallback also need independent checks.
- The learned offset immediately after fitting is the drift baseline, not
  itself evidence of later drift. The baseline survives App restarts.

These changes do not fix the independently observed USB unmount, guarantee a
linear mouse response, or prove the Calculator task works. A failed multi-point
check should remain failed while its logged target/landing pairs are diagnosed;
do not repeatedly recalibrate or loosen tolerance just to obtain a green badge.

Validation: local Swift parsing and policy type checking; policy smoke checks;
ten new iOS unit tests cover partial/timeout/non-finite/lower-keypad/relative
failures, worst-error reporting, legacy persistence, invalidation and drift
baseline. The full simulator suite must pass in the IPA workflow. Real-phone
installation and multi-point/Calculator acceptance are still required.

No board firmware or model settings changed in this App update. The existing
uncommitted minimal-firmware A/B experiment remains separate.
