# Systemwide release notes

Workspace (pkg) versions and the daemon crate version are independent: the
installer is `0.7.x` while `sotf-daemon` is `0.1.x`. The mapping for each
release is recorded here.

## Unreleased

- Added an exhaustive startup combination matrix (exchange-file state ×
  crypto-key state × daemon/HAL start order, plus config-negotiation
  round-trips) in driver-hal, and UI-before-daemon / daemon-dies polling
  tests in ConfigBar. The matrix exposed and fixed one wedge: a legacy
  loose-permission exchange file made every daemon start fail; the
  create path now repairs the mode to 0600 (readers still fail closed).

- Startup now verifies the output interface supports the configured
  sample rate (it can differ between devices and change on one device):
  the daemon negotiates to a device-supported rate instead of opening a
  stream whose clock the hardware will not run, which played at the
  wrong speed until the interface was re-selected.
- ConfigBar gains an automated UI test stack: `just test-configbar`
  (real XCTest execution with zero-discovery guard, wired into the macOS
  gate), ViewInspector hosted-view regression tests over a fixture
  daemon socket, image snapshot tests, and `just test-configbar-e2e`
  (lab daemon + real menu-bar binary smoke).

- Fixed the remaining cold-start stall that required switching the audio
  interface once or twice: the driver-config debounce waited for the
  applied geometry to match the HAL's request before applying it, which
  can never happen (the request is consumed once and the geometry only
  changes after the reconfigure), so a 96 kHz startup request from
  coreaudiod was dropped and the engine stayed at 48 kHz. Stability is
  now judged by the request staying unchanged for the debounce window.
- Plugin editor sheets no longer close while a slider is being dragged:
  graph refreshes that echo the editor's own mutation no longer rebuild
  the editor, and rack plugin instances keep their identity across
  refreshes.
- Generic plugin parameter sliders (e.g. Upmixer) use a high-contrast
  thumb that stays visible in light and dark appearances.
- Upmixer/AAE chain rows show the speaker-layout output count
  (2 ch in → 10 ch out) instead of only the stereo input count; the
  channel-compatibility warning now also covers graph nodes, and when
  the selected interface can supply the channels a layout needs, the
  applied output-channel count is raised to match automatically — and
  lowered back when the wide plugin is removed, instead of leaving the
  pipeline running wide on stereo content (which mis-sized the monitor
  taps and distorted playback until a manual reset). Manual channel
  choices are never overridden.
- Outputs & DSP Profiles now stays in sync: the detail pane follows the
  live route when the output is switched from anywhere, the interface name
  in the detail header is a menu for switching interfaces, and virtual
  devices (SotF Virtual Audio and other loopbacks) are no longer offered
  as outputs, where they would create a feedback loop.
- Restored the HAL Input, Audio Output, Outputs & DSP Profiles, and Security
  sections of the configuration window, which were dropped accidentally in
  0.7.15 (only the dead Audio Source selector was meant to be removed), and
  widened the sample-rate segmented control so six daemon-reported rates no
  longer overflow over their label.

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
