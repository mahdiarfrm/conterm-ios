#!/bin/bash
# A throwaway SSH server to test against.
#
# The transport, the terminal and the Mac link all need a real sshd to mean
# anything, and "find a spare box" is enough friction to make tests not get
# run. This stands one up from nothing in about a second: its own host key,
# its own client key, its own config, nothing touched outside .test-host/.
#
# It runs as you, so a login is a login to your own account — no root, no
# system sshd, no changes to ~/.ssh.
#
#   bash scripts/test-host.sh start          listens on 127.0.0.1 only
#   bash scripts/test-host.sh start --lan    also reachable from your phone
#   bash scripts/test-host.sh stop
#   eval "$(bash scripts/test-host.sh env)"  exports the vars selftest.sh wants
#
# --lan opens a real listening port on your network. It accepts exactly one
# generated key and nothing else, but it is still a listening port: stop it
# when you are done, which `stop` and a reboot both do.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="$ROOT/.test-host"
PORT="${CONTERM_TEST_PORT:-2222}"

lan_address() {
    # The address the phone can actually reach, not the loopback one.
    ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo ""
}

case "${1:-start}" in
start)
    listen="127.0.0.1"
    host="127.0.0.1"
    if [ "${2:-}" = "--lan" ]; then
        listen="0.0.0.0"
        host="$(lan_address)"
        [ -n "$host" ] || { echo "no LAN address on en0/en1"; exit 1; }
    fi

    mkdir -p "$DIR"
    [ -f "$DIR/hostkey" ]   || ssh-keygen -q -t ed25519 -f "$DIR/hostkey" -N '' -C conterm-test-host
    [ -f "$DIR/clientkey" ] || ssh-keygen -q -t ed25519 -f "$DIR/clientkey" -N '' -C conterm-test-client
    cp "$DIR/clientkey.pub" "$DIR/authorized_keys"
    chmod 600 "$DIR/hostkey" "$DIR/clientkey" "$DIR/authorized_keys"

    cat > "$DIR/sshd_config" <<EOF
Port $PORT
ListenAddress $listen
HostKey $DIR/hostkey
PidFile $DIR/sshd.pid
AuthorizedKeysFile $DIR/authorized_keys
StrictModes no
UsePAM no
PasswordAuthentication no
PubkeyAuthentication yes
LogLevel INFO
EOF

    if [ -f "$DIR/sshd.pid" ] && kill -0 "$(cat "$DIR/sshd.pid")" 2>/dev/null; then
        echo "already running (pid $(cat "$DIR/sshd.pid"))"
    else
        # stdio detached, or the daemon inherits whatever pipe started it
        # and holds it open forever — a caller that pipes this script's
        # output then waits for an EOF that never comes.
        nohup /usr/sbin/sshd -D -f "$DIR/sshd_config" -E "$DIR/sshd.log" \
            </dev/null >/dev/null 2>&1 &
        disown 2>/dev/null || true
        sleep 1
    fi

    echo "$host" > "$DIR/host"
    echo "listening on $host:$PORT as $USER"
    echo "fingerprint: $(ssh-keygen -lf "$DIR/hostkey.pub" | awk '{print $2}')"
    ;;

stop)
    if [ -f "$DIR/sshd.pid" ]; then
        kill "$(cat "$DIR/sshd.pid")" 2>/dev/null || true
        rm -f "$DIR/sshd.pid"
    fi
    pkill -f "sshd -D -f $DIR/sshd_config" 2>/dev/null || true
    echo "stopped"
    ;;

env)
    host="$(cat "$DIR/host" 2>/dev/null || echo 127.0.0.1)"
    echo "export CONTERM_SSHTEST=1"
    echo "export CONTERM_SSHTEST_HOST=$host"
    echo "export CONTERM_SSHTEST_PORT=$PORT"
    echo "export CONTERM_SSHTEST_USER=$USER"
    echo "export CONTERM_SSHTEST_KEY=$DIR/clientkey"
    echo "export CONTERM_SSHTEST_FINGERPRINT=$(ssh-keygen -lf "$DIR/hostkey.pub" | awk '{print $2}')"
    ;;

check)
    host="$(cat "$DIR/host" 2>/dev/null || echo 127.0.0.1)"
    ssh -i "$DIR/clientkey" -p "$PORT" \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR "$USER@$host" 'echo LOGIN_OK; uname -sm'
    ;;

*)
    echo "usage: $0 {start [--lan]|stop|env|check}"
    exit 1
    ;;
esac
