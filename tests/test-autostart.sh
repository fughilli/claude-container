#!/bin/bash
#
# Tests for install.sh --autostart / --tailnet: the generated launchd plist and
# systemd unit, the commands used to load them, the tailscale serve invocation,
# refresh-on-rerun, the --tailnet => --autostart implication, and teardown.
#
# Nothing here touches the real launchd/systemd/tailscale: launchctl, systemctl
# and tailscale are stubbed on PATH and log their arguments, and the agent
# directories are redirected into a temp dir. Both OS branches are exercised on
# whichever platform runs the suite via CLAUDE_CONTAINER_OS.
#
# Usage: tests/test-autostart.sh

set -u

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="$REPO_DIR/install.sh"

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

assert_contains() { # desc haystack needle
    case "$2" in
        *"$3"*) pass "$1" ;;
        *) fail "$1 (needle '$3' not found)"; echo "---"; echo "$2" | head -20; echo "---" ;;
    esac
}

assert_not_contains() { # desc haystack needle
    case "$2" in
        *"$3"*) fail "$1 (unexpected '$3')" ;;
        *) pass "$1" ;;
    esac
}

assert_file() { # desc path
    if [ -f "$2" ]; then pass "$1"; else fail "$1 (missing $2)"; fi
}

assert_no_file() { # desc path
    if [ -f "$2" ]; then fail "$1 (still present: $2)"; else pass "$1"; fi
}

# --- Stubs --------------------------------------------------------------------

STUB_BIN="$TMP/stubbin"
mkdir -p "$STUB_BIN"
CALLS="$TMP/calls.log"

for tool in launchctl systemctl tailscale; do
    cat > "$STUB_BIN/$tool" <<STUB
#!/bin/bash
echo "$tool \$*" >> "$CALLS"
# 'tailscale status --json' feeds the URL the installer prints.
if [ "$tool" = tailscale ] && [ "\${1:-}" = status ]; then
    echo '{"Self":{"DNSName":"test-host.example-tailnet.ts.net."}}'
fi
exit 0
STUB
    chmod +x "$STUB_BIN/$tool"
done

FAKE_HOME="$TMP/home"
BIN_DIR="$TMP/bin"
mkdir -p "$FAKE_HOME" "$BIN_DIR"

run_install() { # os extra-args...
    local os="$1"; shift
    : > "$CALLS"
    PATH="$STUB_BIN:$PATH" \
    CLAUDE_CONTAINER_OS="$os" \
    CLAUDE_CONTAINER_LAUNCHAGENTS_DIR="$FAKE_HOME/LaunchAgents" \
    CLAUDE_CONTAINER_SYSTEMD_USER_DIR="$FAKE_HOME/systemd" \
    CLAUDE_CONTAINER_CONFIG_BASE="$FAKE_HOME/config" \
        bash "$INSTALL" --no-build --no-completions --bin-dir "$BIN_DIR" "$@" 2>&1
}

PLIST="$FAKE_HOME/LaunchAgents/com.claude-container.router.plist"
UNIT="$FAKE_HOME/systemd/claude-container-router.service"

# --- Default: no login service ------------------------------------------------

echo "default (no flags)"
out="$(run_install Darwin)"
assert_no_file "no plist is installed without --autostart" "$PLIST"
assert_not_contains "no serve call without --tailnet" "$(cat "$CALLS" 2>/dev/null || true)" "tailscale serve"

# --- macOS --autostart --------------------------------------------------------

echo "macOS --autostart"
out="$(run_install Darwin --autostart)"
assert_file "plist is installed" "$PLIST"
plist="$(cat "$PLIST")"
assert_contains "plist runs the installed router" "$plist" "$BIN_DIR/claude-container-router"
assert_contains "plist passes the run subcommand" "$plist" "<string>run</string>"
assert_contains "plist starts at load" "$plist" "<key>RunAtLoad</key>"
assert_contains "plist keeps a crashed router alive" "$plist" "<key>SuccessfulExit</key>"
assert_contains "plist lets a clean stop stay stopped" "$plist" "<key>SuccessfulExit</key>
        <false/>"
assert_contains "plist logs where --router-logs reads" "$plist" "$FAKE_HOME/config/router.log"
assert_contains "plist pins an interpreter directory on PATH" "$plist" "$(dirname "$(command -v python3)")"
if command -v plutil >/dev/null 2>&1; then
    if plutil -lint "$PLIST" >/dev/null 2>&1; then
        pass "plist is well-formed"
    else
        fail "plist is well-formed"
    fi
fi
calls="$(cat "$CALLS")"
assert_contains "old job is unloaded first" "$calls" "launchctl bootout"
assert_contains "new job is bootstrapped" "$calls" "launchctl bootstrap"
assert_contains "bootstrap targets the plist" "$calls" "$PLIST"

# --- Refresh on re-run --------------------------------------------------------

echo "refresh on re-run"
rm -f "$PLIST"
printf 'stale\n' > "$PLIST"
out="$(run_install Darwin)"
assert_contains "an existing plist is refreshed without the flag" "$(cat "$PLIST")" "<key>Label</key>"

# --- macOS --remove-autostart -------------------------------------------------

echo "macOS --remove-autostart"
out="$(run_install Darwin --remove-autostart)"
assert_no_file "plist is removed" "$PLIST"
assert_contains "job is unloaded on removal" "$(cat "$CALLS")" "launchctl bootout"

# --- Linux --autostart --------------------------------------------------------

echo "Linux --autostart"
out="$(run_install Linux --autostart)"
assert_file "systemd unit is installed" "$UNIT"
unit="$(cat "$UNIT")"
assert_contains "unit runs the installed router" "$unit" "ExecStart=$BIN_DIR/claude-container-router run"
assert_contains "unit respawns only on failure" "$unit" "Restart=on-failure"
assert_contains "unit installs into the user target" "$unit" "WantedBy=default.target"
calls="$(cat "$CALLS")"
assert_contains "systemd is reloaded" "$calls" "systemctl --user daemon-reload"
assert_contains "unit is enabled and started" "$calls" "systemctl --user enable --now claude-container-router.service"

echo "Linux --remove-autostart"
out="$(run_install Linux --remove-autostart)"
assert_no_file "unit is removed" "$UNIT"
assert_contains "unit is disabled on removal" "$(cat "$CALLS")" "systemctl --user disable --now"

# --- --tailnet ----------------------------------------------------------------

echo "--tailnet"
out="$(run_install Darwin --tailnet)"
calls="$(cat "$CALLS")"
assert_contains "serve is configured in the background" "$calls" "tailscale serve --bg --https=443 --set-path=/ http://127.0.0.1:8484"
assert_contains "--tailnet implies --autostart" "$out" "--tailnet implies --autostart"
assert_file "--tailnet installs the login service too" "$PLIST"
assert_contains "the tailnet URL is printed" "$out" "https://test-host.example-tailnet.ts.net/"
assert_contains "the path form is spelled out" "$out" "/<instance>/<service>/"
assert_contains "it says tailnet-only, not funnel" "$out" "not 'funnel'"
assert_not_contains "funnel is never enabled" "$calls" "tailscale funnel"

echo "--tailnet honours CLAUDE_ROUTER_HTTP_PORT"
: > "$CALLS"
out="$(PATH="$STUB_BIN:$PATH" CLAUDE_ROUTER_HTTP_PORT=9999 \
    CLAUDE_CONTAINER_OS=Darwin \
    CLAUDE_CONTAINER_LAUNCHAGENTS_DIR="$FAKE_HOME/LaunchAgents" \
    CLAUDE_CONTAINER_SYSTEMD_USER_DIR="$FAKE_HOME/systemd" \
    CLAUDE_CONTAINER_CONFIG_BASE="$FAKE_HOME/config" \
    bash "$INSTALL" --no-build --no-completions --bin-dir "$BIN_DIR" --tailnet 2>&1)"
assert_contains "serve points at the configured port" "$(cat "$CALLS")" "http://127.0.0.1:9999"

echo "--remove-tailnet"
out="$(run_install Darwin --remove-tailnet)"
assert_contains "serve is turned off" "$(cat "$CALLS")" "tailscale serve --https=443 off"

# --- Missing tailscale --------------------------------------------------------

# TAILSCALE_BIN (not just removing the stub) so the bundle-path fallback can
# never reach a real Tailscale install on the machine running the suite.
echo "missing tailscale CLI"
rm -f "$STUB_BIN/tailscale"
out="$(TAILSCALE_BIN="$TMP/no-such-tailscale" run_install Darwin --tailnet || true)"
assert_contains "a missing CLI is reported" "$out" "tailscale CLI was not found"
assert_contains "the macOS bundle path is suggested" "$out" "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
assert_contains "a bad TAILSCALE_BIN is called out" "$out" "is not executable"
assert_not_contains "no serve is attempted without a CLI" "$(cat "$CALLS" 2>/dev/null || true)" "serve"

echo ""
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
