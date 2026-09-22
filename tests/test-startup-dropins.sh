#!/bin/bash
#
# Tests for the BOOT phase: ordered startup drop-ins (design §5.3). Two halves:
#
#   1. Launcher side — the ordered $CONFIG_DIR/startup-dropins list it writes
#      (skill container.startup entries by order then name, project startup.sh
#      last at equal order) and the CLAUDE_STARTUP_DROPINS env it injects, plus
#      the phase-2 wiring for the real tailnet skill.
#   2. Entrypoint side — run_overlay_startup iterating that list in order,
#      non-fatally (a failing/missing drop-in warns and does not block the next
#      hook or the command), while the legacy single-hook path still works.
#
# Self-contained: real launcher against a stub docker + no-op router under an
# isolated $HOME; the entrypoint is exercised in its root-mode path.
#
# Usage: tests/test-startup-dropins.sh

set -u

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAUNCHER="$REPO_DIR/bin/claude-container"
ENTRYPOINT="$REPO_DIR/claude-code/entrypoint.sh"
REF_SKILLS="$REPO_DIR/docs/design/reference-skills"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home"
mkdir -p "$HOME"
USER_SKILLS="$HOME/.config/claude-container/user-skills"
CONFIG="$HOME/.config/claude-container/config"

mkdir -p "$TMP/bin"
cat > "$TMP/bin/docker" <<EOF
#!/bin/bash
case "\$1" in
    info) exit 0 ;;
    image) exit 1 ;;
    build) echo "DOCKER-BUILD"; exit 0 ;;
    port) echo "127.0.0.1:45678"; exit 0 ;;
    ps) exit 0 ;;
    run) echo "DOCKER-RUN: \$*"; exit 0 ;;
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
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; echo "--- output ---"; echo "$2" | head -25; echo "---"; }
assert_contains() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (missing: $3)" "$2" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) fail "$1 (unexpected: $3)" "$2" ;; *) pass "$1" ;; esac; }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (got '$2' want '$3')" "$2"; fi; }

launch() { local ws="$1"; shift; bash "$TMP/bin/claude-container" -w "$ws" "$@" < /dev/null 2>&1; }
accept() { bash "$TMP/bin/claude-container" -w "$1" --skills-accept "$2" < /dev/null >/dev/null 2>&1; }
dropins() { cat "$CONFIG/startup-dropins" 2>/dev/null; }

skill_with_startup() { # name order scriptname
    local d="$USER_SKILLS/$1"
    mkdir -p "$d"
    printf -- '---\nname: %s\ndescription: t.\n---\nbody\n' "$1" > "$d/SKILL.md"
    printf '{"name":"%s","container":{"startup":"%s","order":%s}}\n' "$1" "$3" "$2" > "$d/skill.json"
    printf '#!/usr/bin/env bash\necho ran-%s\n' "$1" > "$d/$3"
}


echo "== launcher writes drop-ins in order: skill-order, then project last =="
WS1="$TMP/ws1"; mkdir -p "$WS1/.claude-container-overlay"
printf '#!/usr/bin/env bash\necho project-hook\n' > "$WS1/.claude-container-overlay/startup.sh"
skill_with_startup aaa 10 a.sh
skill_with_startup mmm 50 m.sh
skill_with_startup zzz 90 z.sh
accept "$WS1" aaa; accept "$WS1" mmm; accept "$WS1" zzz
OUT="$(launch "$WS1")"
GOT="$(dropins | tr '\n' ',')"
assert_eq "ordered by order then kind (skill<project)" "$GOT" \
    "/claude/skills/aaa/a.sh,/claude/skills/mmm/m.sh,/workspace/.claude-container-overlay/startup.sh,/claude/skills/zzz/z.sh,"
assert_contains "drop-in list is announced" "$OUT" "Startup drop-ins (in order):"
assert_contains "launcher injects the drop-in list env" "$OUT" "CLAUDE_STARTUP_DROPINS=/claude/startup-dropins"


echo "== a rejected skill's drop-in falls out of the list =="
bash "$TMP/bin/claude-container" -w "$WS1" --skills-reject mmm < /dev/null >/dev/null 2>&1
launch "$WS1" >/dev/null 2>&1
assert_not_contains "rejected skill's drop-in removed" "$(dropins)" "/claude/skills/mmm/m.sh"
assert_contains "others remain" "$(dropins)" "/claude/skills/aaa/a.sh"


echo "== no drop-ins clears any stale list and injects no env =="
WS2="$TMP/ws2"; mkdir -p "$WS2"
OUT="$(launch "$WS2")"
assert_not_contains "no env injected when there are no drop-ins" "$OUT" "CLAUDE_STARTUP_DROPINS"
if [ ! -f "$CONFIG/startup-dropins" ]; then
    # startup-dropins is keyed to one CONFIG dir shared across these workspaces;
    # ws2 has no drop-ins, so launching it must clear the file ws1 wrote.
    pass "stale drop-in list cleared when a project has none"
else
    # (ws1 shares this CONFIG; the file is rewritten each launch, so a project
    # with no drop-ins must remove it rather than inherit ws1's.)
    fail "stale drop-in list cleared" "$(dropins)"
fi


echo "== PHASE 2 wiring: adopting tailnet drops in its join script =="
WS3="$TMP/ws3"; mkdir -p "$WS3"
cp -a "$REF_SKILLS/tailnet" "$USER_SKILLS/tailnet"
accept "$WS3" tailnet
OUT="$(TS_AUTHKEY=tskey-xyz bash "$TMP/bin/claude-container" -w "$WS3" < /dev/null 2>&1)"
assert_contains "tailnet join is wired as a drop-in" "$(dropins)" "/claude/skills/tailnet/tailnet-up.sh"
assert_contains "and the entrypoint is pointed at the list" "$OUT" "CLAUDE_STARTUP_DROPINS=/claude/startup-dropins"


# --- entrypoint side ----------------------------------------------------------

run_entrypoint() { # dropins-file -> output   (root mode: no user mapping)
    env PATH="$TMP/bin:$PATH" USER_UID=0 CLAUDE_STARTUP_DROPINS="$1" \
        CLAUDE_STARTUP_TIMEOUT=3 bash "$ENTRYPOINT" echo COMMAND-RAN 2>&1
}

echo "== entrypoint runs drop-ins in listed order, non-fatally =="
D="$TMP/dropdir"; mkdir -p "$D"
printf '#!/usr/bin/env bash\necho HOOK-ONE\n' > "$D/one.sh"
printf '#!/usr/bin/env bash\nexit 3\n' > "$D/bad.sh"
printf '#!/usr/bin/env bash\necho HOOK-THREE\n' > "$D/three.sh"
LIST="$TMP/list"
printf '%s\n%s\n%s\n%s\n' "$D/one.sh" "$D/bad.sh" "$D/missing.sh" "$D/three.sh" > "$LIST"
OUT="$(run_entrypoint "$LIST")"
assert_contains "first drop-in ran" "$OUT" "HOOK-ONE"
assert_contains "a failing drop-in warns" "$OUT" "exited 3"
assert_contains "a missing drop-in is skipped, not fatal" "$OUT" "not found, skipping"
assert_contains "a later drop-in still runs after a failure" "$OUT" "HOOK-THREE"
assert_contains "and the command still runs" "$OUT" "COMMAND-RAN"
# Order: HOOK-ONE before HOOK-THREE.
if [ "$(printf '%s' "$OUT" | grep -n HOOK-ONE | head -1 | cut -d: -f1)" -lt \
     "$(printf '%s' "$OUT" | grep -n HOOK-THREE | head -1 | cut -d: -f1)" ]; then
    pass "drop-ins ran in list order"
else
    fail "drop-ins ran in list order" "$OUT"
fi


echo "== no-key tailnet drop-in returns 0 so the session still opens =="
printf '%s\n' "$REF_SKILLS/tailnet/tailnet-up.sh" > "$TMP/tn-list"
OUT="$(env PATH="$TMP/bin:$PATH" USER_UID=0 CLAUDE_STARTUP_DROPINS="$TMP/tn-list" \
    CLAUDE_STARTUP_TIMEOUT=5 bash "$ENTRYPOINT" echo COMMAND-RAN 2>&1)"
assert_contains "tailnet-up logs the missing key" "$OUT" "TS_AUTHKEY is not set"
assert_not_contains "and does not warn about a non-zero exit" "$OUT" "continuing without it"
assert_contains "so the command still runs" "$OUT" "COMMAND-RAN"


echo "== legacy single-hook path still works (no drop-in list) =="
printf '#!/usr/bin/env bash\necho LEGACY-HOOK\n' > "$TMP/legacy.sh"
OUT="$(env PATH="$TMP/bin:$PATH" USER_UID=0 CLAUDE_OVERLAY_STARTUP="$TMP/legacy.sh" \
    CLAUDE_STARTUP_TIMEOUT=3 bash "$ENTRYPOINT" echo COMMAND-RAN 2>&1)"
assert_contains "single legacy hook runs" "$OUT" "LEGACY-HOOK"
assert_contains "command runs after it" "$OUT" "COMMAND-RAN"


echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
