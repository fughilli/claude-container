#!/bin/bash
#
# Tests for the HOST SERVICES primitive (design §5.4, §6): launcher-supervised
# host processes with the host-exec allowlist, `requires` preflight, name
# collision detection, and — the phase-4 acceptance — the real host-deploy
# (mount transport) watcher started and supervised automatically, driven end to
# end over the shared mailbox with no manual host step, then torn down on exit.
#
# Self-contained: real launcher against a stub docker whose `run` lingers (so the
# supervised watcher stays up while the test drives it) and a no-op router.
#
# Usage: tests/test-host-services.sh

set -u

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAUNCHER="$REPO_DIR/bin/claude-container"
REF_SKILLS="$REPO_DIR/docs/design/reference-skills"

TMP="$(mktemp -d)"
PIDS=()
cleanup() { local p; for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null; done; rm -rf "$TMP"; }
trap cleanup EXIT

export HOME="$TMP/home"
USER_SKILLS="$HOME/.config/claude-container/user-skills"
mkdir -p "$HOME" "$USER_SKILLS"

mkdir -p "$TMP/bin"
# `run` lingers so a supervised host service stays up while we drive it. RUN_SLEEP
# lets a test shorten it; default keeps the "session" alive long enough to drive
# the mailbox.
cat > "$TMP/bin/docker" <<EOF
#!/bin/bash
case "\$1" in
    info) exit 0 ;;
    image) exit 1 ;;
    build) echo "DOCKER-BUILD"; exit 0 ;;
    port) echo "127.0.0.1:45678"; exit 0 ;;
    ps) exit 0 ;;
    run) echo "DOCKER-RUN: \$*"; sleep "\${RUN_SLEEP:-10}"; exit 0 ;;
    *) exit 0 ;;
esac
EOF
chmod +x "$TMP/bin/docker"
cp "$LAUNCHER" "$TMP/bin/claude-container"
printf '#!/bin/bash\nexit 0\n' > "$TMP/bin/claude-container-router"
chmod +x "$TMP/bin/claude-container-router"
export PATH="$TMP/bin:$PATH"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; echo "--- output ---"; echo "${2:-}" | head -25; echo "---"; }
assert_contains() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (missing: $3)" "$2" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) fail "$1 (unexpected: $3)" "$2" ;; *) pass "$1" ;; esac; }

# Foreground launch (RUN returns fast).
launch_fast() { local ws="$1"; shift; RUN_SLEEP=0 bash "$TMP/bin/claude-container" -w "$ws" "$@" < /dev/null 2>&1; }
accept() { bash "$TMP/bin/claude-container" -w "$1" --skills-accept "$2" < /dev/null 2>&1; }
prose_skill() { mkdir -p "$USER_SKILLS/$1"; printf -- '---\nname: %s\ndescription: t.\n---\nbody\n' "$1" > "$USER_SKILLS/$1/SKILL.md"; }
wait_file() { local f="$1" i; for i in $(seq 1 "${2:-80}"); do [ -e "$f" ] && return 0; sleep 0.1; done; return 1; }


echo "== accepting host-deploy shows the host process in the consent diff =="
WS0="$TMP/ws0"; mkdir -p "$WS0"
cp -a "$REF_SKILLS/host-deploy" "$USER_SKILLS/host-deploy"
OUT="$(accept "$WS0" host-deploy)"
assert_contains "consent diff names the host process" "$OUT" "a HOST process 'hostdeploy'"
assert_contains "and its start command" "$OUT" "python3"


echo "== a program outside the host-exec allowlist is refused =="
WS1="$TMP/ws1"; mkdir -p "$WS1"
prose_skill badhost
cat > "$USER_SKILLS/badhost/skill.json" <<'EOF'
{ "name": "badhost",
  "hostServices": { "evil": { "start": "definitely-not-allowed --do-it", "transport": "mount" } } }
EOF
accept "$WS1" badhost >/dev/null 2>&1
OUT="$(launch_fast "$WS1")"
assert_contains "disallowed program is refused" "$OUT" "not in the host-exec allowlist"
assert_contains "the container still launches" "$OUT" "DOCKER-RUN:"


echo "== a host service missing a required host tool is not started =="
WS2="$TMP/ws2"; mkdir -p "$WS2"
prose_skill needtool
cat > "$USER_SKILLS/needtool/skill.json" <<'EOF'
{ "name": "needtool",
  "hostServices": { "svc": { "start": "python3 -c pass", "requires": ["cc-no-such-tool-xyz"], "transport": "mount" } } }
EOF
accept "$WS2" needtool >/dev/null 2>&1
OUT="$(launch_fast "$WS2")"
assert_contains "missing host tool reported" "$OUT" "missing host tool(s): cc-no-such-tool-xyz"


echo "== two skills claiming the same host service name fail loudly =="
WS3="$TMP/ws3"; mkdir -p "$WS3"
prose_skill dupa; prose_skill dupb
printf '{"name":"dupa","hostServices":{"shared":{"start":"python3 -c pass"}}}\n' > "$USER_SKILLS/dupa/skill.json"
printf '{"name":"dupb","hostServices":{"shared":{"start":"python3 -c pass"}}}\n' > "$USER_SKILLS/dupb/skill.json"
accept "$WS3" dupa >/dev/null 2>&1; accept "$WS3" dupb >/dev/null 2>&1
OUT="$(launch_fast "$WS3")"
assert_contains "host service name collision reported" "$OUT" 'host service "shared" declared by two sources'
assert_not_contains "and the container is NOT started" "$OUT" "DOCKER-RUN:"


echo "== PHASE 4 ACCEPTANCE: host-deploy watcher started, driven, torn down =="
WS="$TMP/wsd"; mkdir -p "$WS"
# host-deploy already adopted+consented above (ws0 recorded consent per-project;
# each project keys its own consent, so accept it here too).
accept "$WS" host-deploy >/dev/null 2>&1
LOG="$TMP/launch.log"
( bash "$TMP/bin/claude-container" -w "$WS" true < /dev/null > "$LOG" 2>&1 ) &
LPID=$!
PIDS+=("$LPID")

if wait_file "$WS/.hostdeploy/alive" 100; then
    pass "launcher started the host watcher automatically (heartbeat appeared)"
else
    fail "host watcher heartbeat never appeared" "$(cat "$LOG" 2>/dev/null)"
fi

# Drive it like the container would: submit an allowlisted command over the
# mailbox (no manual host step), then read back the real rc.
printf '{"id":"t1","argv":["git","--version"]}' > "$WS/.hostdeploy/request.json"
if wait_file "$WS/.hostdeploy/t1.status" 100; then
    RC="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["rc"])' "$WS/.hostdeploy/t1.status" 2>/dev/null)"
    if [ "$RC" = "0" ]; then pass "watcher ran the submitted host command (rc=0)"; else fail "watcher command rc=$RC" "$(cat "$WS/.hostdeploy/t1.log" 2>/dev/null)"; fi
    assert_contains "the command actually ran on the host" "$(cat "$WS/.hostdeploy/t1.log" 2>/dev/null)" "git version"
else
    fail "watcher never produced a status for the submitted command" "$(cat "$LOG" 2>/dev/null)"
fi

assert_contains "launch announced the host service" "$(cat "$LOG")" "Host service:"
assert_contains "and reported it healthy" "$(cat "$LOG")" "'hostdeploy' is up"

# Let the "session" (stub docker run) end; the launcher's cleanup tears the
# watcher down. The heartbeat must then go stale (no new writes).
wait "$LPID" 2>/dev/null
sleep 1
before="$(cat "$WS/.hostdeploy/alive" 2>/dev/null || echo 0)"
sleep 1.5
after="$(cat "$WS/.hostdeploy/alive" 2>/dev/null || echo 0)"
if [ "$before" = "$after" ]; then
    pass "watcher torn down on exit (heartbeat stopped advancing)"
else
    fail "watcher still running after launch exit (heartbeat advanced $before -> $after)" ""
fi


echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
