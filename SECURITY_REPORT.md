# Systemwide Security Report

Audit of the two critical areas — the private exchange transport
(`audio.shm`, session keys, control socket) and external-plugin sandboxing —
plus every fix applied. All fixes are implemented, tested red-to-green, and
gated.

## Scope

- Exchange transport: `crates/daemon/bin/security/`,
  `crates/daemon/bin/ipc_transport.rs`, `crates/daemon/bin/sotf_daemon/`,
  `swift/driver-hal/Sources/SharedMemory.swift`,
  `swift/driver-hal/Sources/Encryption.swift`, and
  `../sotf-daw/crates/driver-hal/src/shared_memory/`.
- External plugins: `../sotf-daw/crates/sotf-plugins/src/factory/`
  (`external.rs`, `validate.rs`, `parse.rs`, `create.rs`) and the engine
  pre-validation in `sotf-engine/src/engine/manager_thread/validate.rs`.

## Threat model

- The privacy boundary is the **UID, not the process**. Any process running
  as the daemon owner passes IPC authentication with full Owner rights, and
  can read the shared-memory audio and key files. This is documented and
  accepted: per-user privacy against other users, not intra-user isolation.
- `coreaudiod` (macOS UID 202) is a privileged but restricted peer: it may
  only query driver/encryption status, never mutate pipelines, devices, or
  keys.
- IPC clients are trusted at the UID level only after credential checks;
  payloads (plugin configs, file paths) are untrusted input.

## Findings and fixes

### 1. Windows IPC had no peer authentication (fixed)

Loopback TCP was the whole credential check, so any local user could drive
the daemon with Owner rights. The daemon now generates a fresh 128-bit auth
credential from the OS RNG per listener bind, publishes it in a `daemon.token`
file beside the port file (same atomic temp-file-plus-rename discipline,
never following symlinks), and drops connections that do not present it as
the first line. Comparison is constant-time, every failure maps to one static
error, the credential type has a redacted `Debug`, and authentication happens
before a client slot is consumed so scanners cannot exhaust the slot budget.

- `crates/daemon/bin/ipc_transport.rs` (`IpcAuthToken`,
  `authenticate_client`, `bind_windows_listener`, `connect_windows`)
- `crates/daemon/bin/sotf_daemon/audio_daemon.rs` (accept-loop gate)
- `crates/daemon/bin/security/verify.rs` (locality-is-necessary docs)
- Windows clients must read `daemon.token` and send its contents as the
  first line. The `cfg(windows)` blocks are type-checked via targeted
  `rustc --cfg windows` probing (no MSVC toolchain on this host); CI must
  run the real Windows build.

### 2. `load_plugin_artifact_path` skipped file validation (fixed)

`load` enforces absolute, same-owner, non-symlink regular files, but the
artifact-path command opened whatever path it was given. It now runs the same
`validate_user_load_path` check and hands the canonical path to the parser.

- `crates/daemon/bin/sotf_daemon/audio_daemon.rs`
- Regression test `testkit_load_plugin_artifact_path_rejects_non_absolute_paths`
  fails on the old code, passes on the new.

### 3. Swift HAL trusted the filesystem more than Rust did (fixed)

- `SharedMemory.swift` opened with plain `open()` and mapped whatever was
  there. It now uses `O_NOFOLLOW` plus an ownership/type/mode check
  (console-user-owned, owner-only regular file), with a fail-closed rule when
  no console user exists.
- `Encryption.swift` accepted group-readable (`0640`) session keys with a
  warning and fell back to probing `~/.config` (unreachable to sandboxed
  `coreaudiod`) when no console user existed. It now refuses non-`0600` keys
  and fails closed to `/tmp/sotf-unknown/session.key`; the stale comment
  claiming the HAL reads `~/.config` was corrected to the HAL-readable copy.
- Swift fixtures now create `0600` files like the daemon does.

### 4. `coreaudiod` ACL grants failed silently (fixed)

`chmod +a` failures only logged a warning, degrading silently into
undecodable audio. Grants now return errors that abort driver/key setup, so a
broken transport is a loud startup/driver fault instead of silence.

- `../sotf-daw/crates/driver-hal/src/shared_memory/grant.rs`,
  `ensure.rs`, `shared_audio_buffer.rs`
- `crates/daemon/bin/security/get.rs` (key-grant propagation)

### 5. Shared-memory files were never mode-checked on open (fixed)

Creation sets `0600`, but opening an existing file did not verify it, so a
group/other-readable file would be mapped. `validate_shared_memory_file`
now requires owner-only `0600` (macOS `_coreaudiod` ACLs do not alter mode
bits, so the grant path is unaffected).

- `../sotf-daw/crates/driver-hal/src/shared_memory/validate.rs`
- Regression test `test_open_rejects_group_readable_shared_memory_file`
  fails on the old code, passes on the new.

### 6. Plugin descriptor fell back to the unresolved path (fixed)

`canonicalize().unwrap_or(path)` silently kept a symlink alias when
resolution failed, so the existence check and the worker could disagree about
which file loads. Resolution failure is now a loud error.

- `../sotf-daw/crates/sotf-plugins/src/factory/parse.rs`
- Test `external_plugin_descriptor_resolves_symlink_to_canonical_path`
  pins the canonical-path contract.

### 7. External-plugin sandboxing (audited, no change needed)

The layering is sound: untrusted is the default (`Unknown` counts),
isolation defaults on, untrusted callers cannot disable it, `signed` trust
cannot be granted from IPC config, worker-binary overrides are rejected, the
engine re-validates behind the factory, and untrusted policy requires
sandbox-before-load with no network, no child processes, and no extra
filesystem paths. The in-process fallback is unreachable from IPC on
Linux/macOS/Windows. Residual notes: descriptor existence is check-then-use
(same-UID boundary makes this acceptable), and non-desktop platforms have no
sandbox backend (documented limitation, not a shipped configuration).

## Accepted boundaries (not fixed)

- Same-UID processes have full Owner access by design.
- `SOTF_*` path overrides redirect the transport; they are operator-controlled
  env, trusted like the rest of the owner's environment.
- `_coreaudiod` (UID 202) is matched by literal UID with a most-restricted
  fallback class; a UID change by Apple fails closed.

## Verification

- `cargo test -p sotf-daemon`: 237 pass; 1 pre-existing environment failure
  (`testkit_apply_with_missing_desired_device...` needs an audio device —
  fails on the unmodified tree too).
- `cargo test -p sotf-daemon --features hal --bin sotf-daemon security`:
  25 pass. `cargo check`/`cargo clippy` clean on both feature sets;
  `cargo fmt --check` clean.
- `../sotf-daw`: `driver-hal` 109 pass, `sotf-plugins` factory 64 pass,
  strict `clippy -D warnings` clean. One run in ~12 of the cross-process
  ring stress test flakes on a 5 s worker-ready deadline under parallel-suite
  load; it also flakes without these changes and passes 12/12 in isolation.
- Swift HAL `swiftc -typecheck` gate passes; the test runner scores 13/14,
  with the single failure requiring the `SOTF_RUST_HAL_TRANSPORT_WORKER`
  harness binary (missing in this environment, fails on baseline too).
- Note: `cargo` rewrites `Cargo.lock` on every invocation in this checkout;
  the lockfile was reverted after testing and is intentionally not part of
  this change.
