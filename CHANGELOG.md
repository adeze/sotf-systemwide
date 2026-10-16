# Systemwide release notes

Workspace (pkg) versions and the daemon crate version are independent: the
installer is `0.7.x` while `sotf-daemon` is `0.1.x`. The mapping for each
release is recorded here.

## 0.7.15 (daemon 0.1.38)

### Cold start

- Startup retries now absorb the two transient cold-start races that forced
  users to switch the output interface away and back: the playback-callback
  timeout and the HAL config-ack timeout (budget raised 750 ms -> 3 s).
- ConfigBar's watchdog escalates a reachable-but-latched
  (`pipeline_recovery`) daemon to a restart after two probes instead of
  adopting it as healthy forever.
- Daemon restarts adopt the live HAL header geometry instead of resetting
  the transport to 48 kHz/512/stereo, and header re-init preserves the
  HAL-owned `driver_ready` flag.
- Cold start invalidates the 2 s device-registry cache and re-resolves the
  startup chain when the fallback device changes mid-retry.

### 96 kHz

- Buffer frames scale across rate-only changes so block *duration* stays
  constant (512 frames at 48 kHz becomes 1024 at 96 kHz).
- The HAL ring is sized in seconds on both sides (Rust `ring_block_count`,
  Swift `ringBufferCount(forSampleRate:)`); creation sizes the file for the
  deepest supported rate.
- Encrypted ring overflow drops only the incoming record instead of the
  whole backlog, and `encryption.overflow_count` is surfaced in status.

### Interface

- Removed the Audio Source picker: it mutated local state while the daemon
  has no capture-source concept, and the footer presented it as daemon state.
- Stored-profile parameter edits are no longer discarded; profile rows hide
  the per-plugin channel/bypass controls the profile schema cannot persist.
- Output-route switches get the 30 s pipeline-mutation timeout and a
  generation guard with one conflict retry (previously 1 s + false failure).
- `get_output_profiles` gets the 256 KiB response budget; HAL Driver menu
  status refreshes on the 0.5 s tick; destructive deletes ask first; the
  rate picker offers every daemon-supported rate; the HAL negotiation row
  now receives real `config_status`/`config_source`.

### Plugins

- The daemon installs authorized-runtime sandbox options at startup
  (grants + preset root), matching `sotf-player`.
- `spectrum_analyzer`/`resampler` are stripped from direct rack loads like
  everywhere else; `add_plugin` errors on out-of-range index; available
  plugin defaults are computed at the live driver rate; output profiles are
  validated at upsert and their channel geometry applies on route switch.

### Release mechanics

- Root changelog created (this file); dual versioning documented above.
- `scripts/sign-macos.sh`: desktop/plugin-worker entitlement plists vendored
  into `builds/macos/` with fail-loud checks.
- LaunchAgent plists marked as templates; the postinstall refuses to install
  one still carrying a `__SOTF_` placeholder.
- Security hardening from the 0.7.14 audit cycle (see `SECURITY_REPORT.md`):
  exchange-file permissions, Windows IPC credential, artifact-path policy.

## 0.7.14 and earlier

See `crates/daemon/CHANGELOG.md` for daemon-crate history and git history
for the workspace. Release notes were not kept at the root before 0.7.15.
