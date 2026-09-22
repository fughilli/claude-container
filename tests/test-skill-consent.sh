#!/bin/bash
#
# Tests for the PREFLIGHT + CONSENT phase (design §5.5, §6): `requires`
# validation with clear launch-time diagnostics, and the privilege-diff consent
# gate at accept/adopt time and launch time.
#
# Self-contained: real launcher against a stub docker + no-op router under an
# isolated $HOME. The interactive tty prompt is exercised with `expect` when
# available and skipped otherwise (like the other suites).
#
# Usage: tests/test-skill-consent.sh

set -u

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAUNCHER="$REPO_DIR/bin/claude-container"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME"
USER_SKILLS="$HOME/.config/claude-container/user-skills"
CHOICES="$HOME/.config/claude-container/skill-choices"

mkdir -p "$TMP/bin"
touch "$TMP/built"
cat > "$TMP/bin/docker" <<EOF
#!/bin/bash
case "\$1" in
    info) exit 0 ;;
    image)
        ref="\${@: -1}"
        case "\$ref" in
            claude-container-overlay:*)
                if grep -qxF "\$ref" "$TMP/built"; then echo "sha256:fake"; exit 0; fi
                exit 1 ;;
            *) echo "sha256:baseimage"; exit 0 ;;
        esac ;;
    build)
        case " \$* " in
            *" -f - "*) cat > "$TMP/dockerfile-fed" 2>/dev/null ;;
            *) cp "\${@: -1}/Dockerfile" "$TMP/dockerfile-fed" 2>/dev/null ;;
        esac
        for a in \$*; do case "\$a" in claude-container-overlay:*) echo "\$a" >> "$TMP/built" ;; esac; done
        echo "DOCKER-BUILD: \$*"; exit 0 ;;
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

launch() { local ws="$1"; shift; bash "$TMP/bin/claude-container" -w "$ws" "$@" < /dev/null 2>&1; }
accept() { bash "$TMP/bin/claude-container" -w "$1" --skills-accept "$2" < /dev/null 2>&1; }
fed() { cat "$TMP/dockerfile-fed" 2>/dev/null; }
run_line() { printf '%s\n' "$1" | grep '^DOCKER-RUN:'; }
prose_skill() { mkdir -p "$USER_SKILLS/$1"; printf -- '---\nname: %s\ndescription: t.\n---\nbody\n' "$1" > "$USER_SKILLS/$1/SKILL.md"; }


echo "== accepting a privileged skill shows the diff and records consent =="
WS1="$TMP/ws1"; mkdir -p "$WS1"
prose_skill capskill
printf 'RUN echo cap-frag\n' > "$USER_SKILLS/capskill/Dockerfile.snippet"
cat > "$USER_SKILLS/capskill/skill.json" <<'EOF'
{ "name": "capskill",
  "image": { "dockerfile": "Dockerfile.snippet" },
  "runtime": { "capabilities": ["NET_ADMIN"], "devices": ["/dev/net/tun"], "env": ["CAP_KEY"] } }
EOF
OUT="$(accept "$WS1" capskill)"
assert_contains "accept announces the skill is privileged" "$OUT" "privileged skill"
assert_contains "diff lists the capability" "$OUT" "kernel capabilities: NET_ADMIN"
assert_contains "diff lists the device" "$OUT" "host devices: /dev/net/tun"
assert_contains "diff lists the root build layer" "$OUT" "RUNS AS ROOT"
assert_contains "consent is recorded" "$OUT" "Consent recorded"
CONSENT_FILE="$(ls "$CHOICES"/ws1-*.consent 2>/dev/null | head -1)"
assert_contains "consent digest stored for the skill" "$(cat "$CONSENT_FILE" 2>/dev/null)" "capskill="

echo "== a consented privileged skill launches quietly (no re-prompt/warn) =="
OUT="$(CAP_KEY=x launch "$WS1")"
assert_contains "skill's fragment is built" "$(fed)" "RUN echo cap-frag"
assert_contains "skill's capability is present" "$(run_line "$OUT")" "--cap-add NET_ADMIN"
assert_not_contains "no privilege-change warning" "$OUT" "CHANGED"
assert_not_contains "not disabled" "$OUT" "disabling 'capskill'"


echo "== a non-privileged skill records no consent and shows no diff =="
WS2="$TMP/ws2"; mkdir -p "$WS2"
prose_skill plainskill
OUT="$(accept "$WS2" plainskill)"
assert_not_contains "no privilege banner for prose skill" "$OUT" "privileged skill"
assert_not_contains "no consent file entry" "$(ls "$CHOICES"/ws2-*.consent 2>/dev/null || true)" "ws2"


echo "== a manifest privilege change re-opens consent (non-interactive proceeds, warns) =="
# Add a NEW capability to capskill after ws1 already consented.
cat > "$USER_SKILLS/capskill/skill.json" <<'EOF'
{ "name": "capskill",
  "image": { "dockerfile": "Dockerfile.snippet" },
  "runtime": { "capabilities": ["NET_ADMIN", "SYS_PTRACE"], "devices": ["/dev/net/tun"], "env": ["CAP_KEY"] } }
EOF
OUT="$(CAP_KEY=x launch "$WS1")"
assert_contains "changed privileges are flagged" "$OUT" "CHANGED its requested privileges"
assert_contains "the new capability is named in the diff" "$OUT" "SYS_PTRACE"
assert_contains "non-interactive still proceeds (container starts)" "$OUT" "DOCKER-RUN:"


echo "== requires.launcher newer than this launcher disables the skill =="
WS3="$TMP/ws3"; mkdir -p "$WS3"
prose_skill futureskill
printf 'RUN echo future-frag\n' > "$USER_SKILLS/futureskill/Dockerfile.snippet"
cat > "$USER_SKILLS/futureskill/skill.json" <<'EOF'
{ "name": "futureskill",
  "image": { "dockerfile": "Dockerfile.snippet" },
  "runtime": { "capabilities": ["NET_ADMIN"] },
  "requires": { "launcher": ">=99.0.0" } }
EOF
accept "$WS3" futureskill >/dev/null 2>&1
OUT="$(launch "$WS3")"
assert_contains "the version requirement is reported" "$OUT" "requires claude-container >= 99.0.0"
assert_not_contains "the disabled skill's fragment is not built" "$(fed)" "RUN echo future-frag"
assert_not_contains "the disabled skill's capability is absent" "$(run_line "$OUT")" "--cap-add NET_ADMIN"
assert_contains "but the session still launches" "$OUT" "DOCKER-RUN:"


echo "== requires.hostDevices missing warns but does not disable =="
WS4="$TMP/ws4"; mkdir -p "$WS4"
prose_skill devskill
printf 'RUN echo dev-frag\n' > "$USER_SKILLS/devskill/Dockerfile.snippet"
cat > "$USER_SKILLS/devskill/skill.json" <<'EOF'
{ "name": "devskill",
  "image": { "dockerfile": "Dockerfile.snippet" },
  "requires": { "hostDevices": ["/dev/cc-nonexistent-xyz"] } }
EOF
accept "$WS4" devskill >/dev/null 2>&1
OUT="$(launch "$WS4")"
assert_contains "missing host device is reported" "$OUT" "/dev/cc-nonexistent-xyz is not present"
assert_contains "but the skill is still enabled (fragment built)" "$(fed)" "RUN echo dev-frag"


echo "== requires.env unset warns; set is quiet =="
WS5="$TMP/ws5"; mkdir -p "$WS5"
prose_skill envskill
cat > "$USER_SKILLS/envskill/skill.json" <<'EOF'
{ "name": "envskill",
  "runtime": { "env": ["MY_ENV_XYZ"] },
  "requires": { "env": ["MY_ENV_XYZ"] } }
EOF
accept "$WS5" envskill >/dev/null 2>&1
OUT="$(launch "$WS5")"
assert_contains "unset required env is reported" "$OUT" "MY_ENV_XYZ is not set"
OUT="$(MY_ENV_XYZ=1 launch "$WS5")"
assert_not_contains "set required env is quiet" "$OUT" "MY_ENV_XYZ is not set"


echo "== interactive consent prompt (expect) =="
if command -v expect >/dev/null 2>&1; then
    WS6="$TMP/ws6"; mkdir -p "$WS6"
    prose_skill ttyskill
    printf 'RUN echo tty-frag\n' > "$USER_SKILLS/ttyskill/Dockerfile.snippet"
    cat > "$USER_SKILLS/ttyskill/skill.json" <<'EOF'
{ "name": "ttyskill", "image": { "dockerfile": "Dockerfile.snippet" },
  "runtime": { "capabilities": ["NET_ADMIN"] } }
EOF
    # Use the launcher to accept (records consent), then delete the consent file
    # so the launch must re-prompt for the privilege grant.
    bash "$TMP/bin/claude-container" -w "$WS6" --skills-accept ttyskill </dev/null >/dev/null 2>&1
    rm -f "$CHOICES"/ws6-*.consent

    # Granting a privileged skill for the first time produces TWO prompts in one
    # launch: the privilege-consent grant (phase 3), then the first-time image
    # rebuild confirmation (the pre-existing fragment-build gate). Drive both with
    # exp_continue, and reset the stub's captured Dockerfile before each launch so
    # `fed()` reflects only this launch (it is a workspace-global file).
    rm -f "$TMP/dockerfile-fed"
    OUT="$(expect -c "
set timeout 20
spawn env PATH=$TMP/bin:\$env(PATH) HOME=$HOME bash $TMP/bin/claude-container -w $WS6 --skills-ignore-new
expect {
  \"Grant these to this project?\" { send \"n\r\"; exp_continue }
  \"Rebuild the image now?\" { send \"y\r\"; exp_continue }
  eof
}
" 2>&1)"
    assert_contains "prompt shows the privilege diff" "$OUT" "requests these privileges"
    assert_contains "declining disables the skill" "$OUT" "disabling 'ttyskill'"
    assert_not_contains "declined skill's fragment not built" "$(fed)" "RUN echo tty-frag"

    rm -f "$TMP/dockerfile-fed"
    OUT="$(expect -c "
set timeout 20
spawn env PATH=$TMP/bin:\$env(PATH) HOME=$HOME bash $TMP/bin/claude-container -w $WS6 --skills-ignore-new
expect {
  \"Grant these to this project?\" { send \"y\r\"; exp_continue }
  \"Rebuild the image now?\" { send \"y\r\"; exp_continue }
  eof
}
" 2>&1)"
    assert_contains "granting records consent" "$OUT" "requests these privileges"
    assert_contains "granting builds the fragment" "$(fed)" "RUN echo tty-frag"
    OUT="$(launch "$WS6")"
    assert_not_contains "consent now sticky — no re-prompt" "$OUT" "requests these privileges"
else
    echo "  (skipped tty tests: expect not installed)"
fi


echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
