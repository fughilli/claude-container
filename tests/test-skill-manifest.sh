#!/bin/bash
#
# Tests for phase-aware skill manifests (skill.json): the IMAGE phase honouring
# a manifest-declared "image.dockerfile", and the RUNTIME phase folding each
# active skill's "runtime" block into the effective docker run flags with
# union + conflict semantics (design §5.1, §5.2). Also the phase-1 acceptance
# criterion: adopting the real `tailnet` skill with only TS_AUTHKEY exported
# yields a container with the client fragment and the caps/device/env present,
# with no manual overlay edits.
#
# Self-contained: runs the real launcher against a stub `docker` (no images
# built, no containers started) and a no-op router, under an isolated $HOME.
#
# Usage: tests/test-skill-manifest.sh

set -u

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAUNCHER="$REPO_DIR/bin/claude-container"
REF_SKILLS="$REPO_DIR/docs/design/reference-skills"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home"
mkdir -p "$HOME"
USER_SKILLS="$HOME/.config/claude-container/user-skills"

# Stub docker: capture the effective Dockerfile fed on stdin and echo the run
# argv so both the image contents and the runtime flags are observable.
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

# Run a launcher copy so the router lookup lands on a neutral no-op beside it.
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
accept() { bash "$TMP/bin/claude-container" -w "$1" --skills-accept "$2" < /dev/null >/dev/null 2>&1; }
fed() { cat "$TMP/dockerfile-fed" 2>/dev/null; }
docker_run_line() { printf '%s\n' "$1" | grep '^DOCKER-RUN:'; }

write_prose_skill() { # dir name
    mkdir -p "$1/$2"
    printf -- '---\nname: %s\ndescription: Test skill %s.\n---\n\nbody\n' "$2" "$2" > "$1/$2/SKILL.md"
}


echo "== manifest image.dockerfile folds a differently-named fragment =="
WS1="$TMP/ws1"; mkdir -p "$WS1"
write_prose_skill "$USER_SKILLS" imgskill
printf 'RUN echo manifest-frag-step\n' > "$USER_SKILLS/imgskill/custom.Dockerfile"
printf '{\n  "name": "imgskill",\n  "image": { "dockerfile": "custom.Dockerfile" }\n}\n' > "$USER_SKILLS/imgskill/skill.json"
accept "$WS1" imgskill
OUT="$(launch "$WS1")"
assert_contains "manifest fragment announced" "$OUT" "Skill image fragments"
assert_contains "manifest-named fragment folded into the image" "$(fed)" "RUN echo manifest-frag-step"
assert_contains "--skills marks it as image-building" "$(launch "$WS1" --skills)" "builds into the image"


echo "== a skill's runtime block merges into docker run flags =="
WS2="$TMP/ws2"; mkdir -p "$WS2"
write_prose_skill "$USER_SKILLS" rtskill
cat > "$USER_SKILLS/rtskill/skill.json" <<'EOF'
{
  "name": "rtskill",
  "runtime": {
    "capabilities": ["NET_ADMIN"],
    "devices": ["/dev/net/tun"],
    "env": ["RT_SKILL_KEY"]
  }
}
EOF
accept "$WS2" rtskill
OUT="$(RT_SKILL_KEY=secret bash "$TMP/bin/claude-container" -w "$WS2" < /dev/null 2>&1)"
line="$(docker_run_line "$OUT")"
assert_contains "skill capability becomes --cap-add" "$line" "--cap-add NET_ADMIN"
assert_contains "skill device becomes --device" "$line" "--device /dev/net/tun"
assert_contains "skill env forwarded by name" "$line" "-e RT_SKILL_KEY"
assert_not_contains "by-name env keeps the secret out of argv" "$line" "secret"


echo "== project overlay and a skill union without duplicating =="
WS3="$TMP/ws3"; mkdir -p "$WS3/.claude-container-overlay"
echo '{"capabilities": ["NET_ADMIN"], "env": ["PROJECT_ONLY"]}' > "$WS3/.claude-container-overlay/overlay.json"
write_prose_skill "$USER_SKILLS" capskill
printf '{"name":"capskill","runtime":{"capabilities":["NET_ADMIN","SYS_PTRACE"]}}\n' > "$USER_SKILLS/capskill/skill.json"
accept "$WS3" capskill
OUT="$(PROJECT_ONLY=1 bash "$TMP/bin/claude-container" -w "$WS3" < /dev/null 2>&1)"
line="$(docker_run_line "$OUT")"
caps_count="$(printf '%s' "$line" | grep -o -- '--cap-add NET_ADMIN' | wc -l | tr -d ' ')"
if [ "$caps_count" = "1" ]; then pass "NET_ADMIN from both is deduped to one --cap-add"; else fail "NET_ADMIN deduped ($caps_count times)" "$line"; fi
assert_contains "skill-only capability still added" "$line" "--cap-add SYS_PTRACE"
assert_contains "project-only env still forwarded" "$line" "-e PROJECT_ONLY"


echo "== a conflicting sysctl across two skills fails loudly =="
WS4="$TMP/ws4"; mkdir -p "$WS4"
write_prose_skill "$USER_SKILLS" sys-a
write_prose_skill "$USER_SKILLS" sys-b
printf '{"name":"sys-a","runtime":{"sysctls":{"net.ipv4.ip_forward":1}}}\n' > "$USER_SKILLS/sys-a/skill.json"
printf '{"name":"sys-b","runtime":{"sysctls":{"net.ipv4.ip_forward":0}}}\n' > "$USER_SKILLS/sys-b/skill.json"
accept "$WS4" sys-a; accept "$WS4" sys-b
OUT="$(launch "$WS4")"
assert_contains "sysctl conflict reported" "$OUT" 'net.ipv4.ip_forward'
assert_contains "sysctl conflict is fatal" "$OUT" "conflicting runtime declarations"
assert_not_contains "and the container is NOT started" "$OUT" "DOCKER-RUN:"


echo "== a host-port collision across two skills fails loudly =="
WS5="$TMP/ws5"; mkdir -p "$WS5"
write_prose_skill "$USER_SKILLS" port-a
write_prose_skill "$USER_SKILLS" port-b
printf '{"name":"port-a","runtime":{"ports":["8099:8099"]}}\n' > "$USER_SKILLS/port-a/skill.json"
printf '{"name":"port-b","runtime":{"ports":["8099:9000"]}}\n' > "$USER_SKILLS/port-b/skill.json"
accept "$WS5" port-a; accept "$WS5" port-b
OUT="$(launch "$WS5")"
assert_contains "port collision reported" "$OUT" "8099"
assert_not_contains "and the container is NOT started" "$OUT" "DOCKER-RUN:"


echo "== the same by-name env from two skills is not a conflict =="
WS6="$TMP/ws6"; mkdir -p "$WS6"
write_prose_skill "$USER_SKILLS" env-a
write_prose_skill "$USER_SKILLS" env-b
printf '{"name":"env-a","runtime":{"env":["SHARED_KEY"]}}\n' > "$USER_SKILLS/env-a/skill.json"
printf '{"name":"env-b","runtime":{"env":["SHARED_KEY"]}}\n' > "$USER_SKILLS/env-b/skill.json"
accept "$WS6" env-a; accept "$WS6" env-b
OUT="$(SHARED_KEY=x bash "$TMP/bin/claude-container" -w "$WS6" < /dev/null 2>&1)"
assert_contains "shared by-name env still launches" "$OUT" "DOCKER-RUN:"
line="$(docker_run_line "$OUT")"
n="$(printf '%s' "$line" | grep -o -- '-e SHARED_KEY' | wc -l | tr -d ' ')"
if [ "$n" = "1" ]; then pass "shared env forwarded exactly once"; else fail "shared env forwarded $n times" "$line"; fi


echo "== backward compat: a manifest-less overlay.Dockerfile still folds =="
WS7="$TMP/ws7"; mkdir -p "$WS7"
write_prose_skill "$USER_SKILLS" legacyskill
printf 'RUN echo legacy-frag\n' > "$USER_SKILLS/legacyskill/overlay.Dockerfile"
accept "$WS7" legacyskill
OUT="$(launch "$WS7")"
assert_contains "legacy overlay.Dockerfile still folds without a manifest" "$(fed)" "RUN echo legacy-frag"


echo "== PHASE 1 ACCEPTANCE: adopting real tailnet wires image + runtime =="
WS8="$TMP/ws8"; mkdir -p "$WS8"
cp -a "$REF_SKILLS/tailnet" "$USER_SKILLS/tailnet"
accept "$WS8" tailnet
OUT="$(TS_AUTHKEY=tskey-secret-xyz bash "$TMP/bin/claude-container" -w "$WS8" < /dev/null 2>&1)"
line="$(docker_run_line "$OUT")"
assert_contains "tailscale client fragment folded into the image" "$(fed)" "install -y --no-install-recommends tailscale"
assert_contains "NET_ADMIN capability present" "$line" "--cap-add NET_ADMIN"
assert_contains "/dev/net/tun device present" "$line" "--device /dev/net/tun"
assert_contains "TS_AUTHKEY forwarded by name" "$line" "-e TS_AUTHKEY"
assert_not_contains "the auth key value never reaches docker argv" "$line" "tskey-secret-xyz"


echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
