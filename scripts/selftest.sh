#!/bin/bash
# Build, install and run the self-tests, on the simulator or on a device.
#
#   bash scripts/selftest.sh              simulator, against a local test host
#   bash scripts/selftest.sh device       your iPhone, against the same host
#                                         over the LAN
#   bash scripts/selftest.sh device --live   also drive a Conterm that is
#                                         really running on this Mac
#
# Starts the throwaway sshd itself if one isn't already up, and leaves it
# running so a second run is quick. `scripts/test-host.sh stop` when done.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

TARGET="${1:-sim}"
LIVE=""
[ "${2:-}" = "--live" ] && LIVE=1

# --- the far end ---------------------------------------------------------
if [ "$TARGET" = "device" ]; then
    bash scripts/test-host.sh start --lan >/dev/null || exit 1
else
    bash scripts/test-host.sh start >/dev/null || exit 1
fi
eval "$(bash scripts/test-host.sh env)"
echo "==> host $CONTERM_SSHTEST_USER@$CONTERM_SSHTEST_HOST:$CONTERM_SSHTEST_PORT"

# --- build and install ---------------------------------------------------
if [ "$TARGET" = "device" ]; then
    UDID="${CONTERM_DEVICE:-$(xcrun devicectl list devices 2>/dev/null \
        | awk '/connected/ {print $(NF-2); exit}')}"
    [ -n "$UDID" ] || { echo "no connected device — plug in and unlock it"; exit 1; }
    DEST="platform=iOS,id=$UDID"
else
    UDID="${CONTERM_SIM:-$(xcrun simctl list devices available \
        | awk -F'[()]' '/iPhone .*Booted/ {print $2; exit}')}"
    [ -n "$UDID" ] || { echo "no booted simulator — open one first"; exit 1; }
    DEST="platform=iOS Simulator,id=$UDID"
fi

echo "==> building for $DEST"
xcodebuild -scheme Conterm -destination "$DEST" -configuration Debug build \
    2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true
APP=$(xcodebuild -scheme Conterm -destination "$DEST" -configuration Debug \
    -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')
[ -d "$APP/Conterm.app" ] || { echo "no app built"; exit 1; }

LOG=$(mktemp -t conterm-selftest)

if [ "$TARGET" = "device" ]; then
    xcrun devicectl device install app --device "$UDID" "$APP/Conterm.app" >/dev/null || exit 1
    # The key has to be readable *on the phone*, so it travels in the
    # environment rather than as a path. Everything else is the same.
    ENVJSON=$(python3 - "$CONTERM_SSHTEST_KEY" <<'PY'
import json, sys, os
key = open(sys.argv[1]).read()
pub = open(sys.argv[1] + ".pub").read()
env = {
    "CONTERM_SSHTEST": "1",
    "CONTERM_SSHTEST_HOST": os.environ["CONTERM_SSHTEST_HOST"],
    "CONTERM_SSHTEST_PORT": os.environ["CONTERM_SSHTEST_PORT"],
    "CONTERM_SSHTEST_USER": os.environ["CONTERM_SSHTEST_USER"],
    "CONTERM_SSHTEST_KEY_TEXT": key,
    "CONTERM_SSHTEST_PUB_TEXT": pub,
}
if os.environ.get("LIVE"):
    env["CONTERM_SSHTEST_LIVE"] = "1"
print(json.dumps(env))
PY
)
    LIVE="$LIVE" xcrun devicectl device process launch --device "$UDID" \
        --console --terminate-existing --environment-variables "$ENVJSON" \
        dev.conterm.ios > "$LOG" 2>&1 &
else
    xcrun simctl install "$UDID" "$APP/Conterm.app" || exit 1
    SIMCTL_CHILD_CONTERM_SSHTEST=1 \
    SIMCTL_CHILD_CONTERM_SSHTEST_HOST="$CONTERM_SSHTEST_HOST" \
    SIMCTL_CHILD_CONTERM_SSHTEST_PORT="$CONTERM_SSHTEST_PORT" \
    SIMCTL_CHILD_CONTERM_SSHTEST_USER="$CONTERM_SSHTEST_USER" \
    SIMCTL_CHILD_CONTERM_SSHTEST_KEY="$CONTERM_SSHTEST_KEY" \
    ${LIVE:+SIMCTL_CHILD_CONTERM_SSHTEST_LIVE=1} \
    xcrun simctl launch --console-pty --terminate-running-process \
        "$UDID" dev.conterm.ios > "$LOG" 2>&1 &
fi
RUNNER=$!

echo "==> running"
for _ in $(seq 1 90); do
    sleep 2
    grep -q "CONTERM-SSHTEST --- done ---" "$LOG" 2>/dev/null && break
done
kill $RUNNER 2>/dev/null

grep -E "CONTERM-(SSHTEST|TERMTEST)" "$LOG" \
    | sed -E 's/.*CONTERM-(SSHTEST|TERMTEST) //' || true

PASSED=$(grep -c "PASS " "$LOG" 2>/dev/null || echo 0)
FAILED=$(grep -c "FAIL " "$LOG" 2>/dev/null || echo 0)
echo
echo "==> $PASSED passed, $FAILED failed   (full log: $LOG)"
[ "$FAILED" -eq 0 ]
