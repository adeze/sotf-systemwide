#!/usr/bin/env bash
# Tier-4 smoke: real daemon (lab driver, isolated runtime dir) + real
# ConfigBar executable, exercised together over the production IPC socket.
#
# This is a process-level end-to-end check, not GUI automation: it proves
# the shipped binaries start against each other, the menu-bar app stays
# alive while polling the lab daemon, and core IPC commands round-trip.
# Click-level GUI automation would need an XCUITest host, which the
# SwiftPM-only app does not have; hosted-view and snapshot suites cover
# interaction logic in-process instead (scripts/test-configbar.sh).
#
# Requires a logged-in GUI session for the menu-bar app. Manual/nightly
# tier: just test-configbar-e2e
set -euo pipefail

cd "$(dirname "$0")/.."

runtime_dir="$(mktemp -d /private/tmp/sotf-configbar-e2e.XXXXXX)"
daemon_pid=""
app_pid=""
cleanup() {
    [[ -n "$app_pid" ]] && kill "$app_pid" 2>/dev/null || true
    [[ -n "$daemon_pid" ]] && kill "$daemon_pid" 2>/dev/null || true
    wait 2>/dev/null || true
    rm -rf "$runtime_dir"
}
trap cleanup EXIT

export SOTF_SYSTEMWIDE_RUNTIME_DIR="$runtime_dir"
export SOTF_SYSTEMWIDE_DRIVER=lab

echo "==> Building daemon and ConfigBar"
cargo build -p sotf-daemon --bin sotf-daemon
swift build --package-path swift/configbar \
    --scratch-path target/configbar-swiftpm \
    --product sotf-systemwide

daemon_bin="target/debug/sotf-daemon"
app_bin="target/configbar-swiftpm/out/Products/Debug/sotf-systemwide"
socket_path="$runtime_dir/daemon.sock"

echo "==> Starting lab daemon"
"$daemon_bin" >"$runtime_dir/daemon.log" 2>&1 &
daemon_pid=$!
for _ in $(seq 1 50); do
    [[ -S "$socket_path" ]] && break
    kill -0 "$daemon_pid" 2>/dev/null || { echo "daemon exited early:" >&2; cat "$runtime_dir/daemon.log" >&2; exit 1; }
    sleep 0.2
done
[[ -S "$socket_path" ]] || { echo "daemon socket did not appear" >&2; exit 1; }

echo "==> IPC round-trips"
SOTF_E2E_SOCKET="$socket_path" python3 - <<'PY'
import json, os, socket, sys

path = os.environ["SOTF_E2E_SOCKET"]

def command(payload):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.settimeout(10)
        sock.connect(path)
        sock.sendall((json.dumps(payload) + "\n").encode())
        data = b""
        while not data.endswith(b"\n"):
            chunk = sock.recv(65536)
            if not chunk:
                break
            data += chunk
    return json.loads(data.decode())

for payload in (
    {"command": "ping"},
    {"command": "status"},
    {"command": "get_snapshot"},
    {"command": "get_output_profiles"},
    {"command": "list_devices"},
):
    response = command(payload)
    if not response.get("success"):
        print(f"IPC {payload['command']} failed: {response}", file=sys.stderr)
        sys.exit(1)
    print(f"IPC {payload['command']}: ok")
PY

echo "==> Launching ConfigBar against lab daemon"
"$app_bin" >"$runtime_dir/configbar.log" 2>&1 &
app_pid=$!
sleep 4
kill -0 "$app_pid" 2>/dev/null || {
    echo "ConfigBar exited early:" >&2
    cat "$runtime_dir/configbar.log" >&2
    exit 1
}
# The app polls get_snapshot on a 1 Hz timer; a second check after the
# poll confirms the daemon stayed healthy under real client traffic.
SOTF_E2E_SOCKET="$socket_path" python3 - <<'PY'
import json, os, socket, sys

path = os.environ["SOTF_E2E_SOCKET"]
with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
    sock.settimeout(10)
    sock.connect(path)
    sock.sendall(b'{"command":"status"}\n')
    data = sock.recv(65536)
response = json.loads(data.decode())
if not response.get("success"):
    print(f"post-launch status failed: {response}", file=sys.stderr)
    sys.exit(1)
print("post-launch status: ok")
PY

echo "ConfigBar E2E smoke passed."
