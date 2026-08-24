#!/bin/bash
#
# Tests for skill-provided image-build fragments (overlay.Dockerfile beside a
# SKILL.md), the per-project append-only build order, and the confirm-before-
# rebuild prompt that fires when a shared skill's fragment changes.
#
# Self-contained: runs the real launcher against a stub `docker` and an isolated
# $HOME under a temp dir, so no images are built and no containers are started.
# The interactive-prompt tests need `expect` and are skipped if it isn't
# installed.
#
# Usage: tests/test-skill-fragments.sh

set -u

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAUNCHER="$REPO_DIR/bin/claude-container"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home"
mkdir -p "$HOME"
USER_SKILLS="$HOME/.config/claude-container/user-skills"
CHOICES="$HOME/.config/claude-container/skill-choices"

# Stub docker. `image inspect` misses for overlay tags unless the tag has been
# "built" (recorded in $TMP/built), so the confirm-before-rebuild path can be
# exercised realistically: a declined rebuild must fall back to a tag that
# really does exist.
mkdir -p "$TMP/bin"
touch "$TMP/built"
cat > "$TMP/bin/docker" <<EOF
#!/bin/bash
case "\$1" in
    info) exit 0 ;;
    image)
        # image inspect --format ... <ref>
        ref="\${@: -1}"
        case "\$ref" in
            claude-container-overlay:*)
                if grep -qxF "\$ref" "$TMP/built"; then echo "sha256:fake"; exit 0; fi
                exit 1
                ;;
            *) echo "sha256:baseimage"; exit 0 ;;
        esac
        ;;
    build)
        ctx="\${@: -1}"
        case " \$* " in
            *" -f - "*) cat > "$TMP/dockerfile-fed" 2>/dev/null ;;
            *) cp "\$ctx/Dockerfile" "$TMP/dockerfile-fed" 2>/dev/null ;;
        esac
        for a in \$*; do
            case "\$a" in claude-container-overlay:*) echo "\$a" >> "$TMP/built" ;; esac
        done
        echo "DOCKER-BUILD: \$*"
        exit 0
        ;;
    run) echo "DOCKER-RUN: \$*"; exit 0 ;;
    *) exit 0 ;;
esac
EOF
chmod +x "$TMP/bin/docker"
export PATH="$TMP/bin:$PATH"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

assert_contains() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (missing: $3)" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) fail "$1 (unexpected: $3)" ;; *) pass "$1" ;; esac; }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$3', got '$2')"; fi; }

write_skill() { # dir name
    mkdir -p "$1/$2"
    printf -- '---\nname: %s\ndescription: Test skill %s.\n---\n\n# %s\nbody\n' "$2" "$2" "$2" > "$1/$2/SKILL.md"
}

write_fragment() { # dir name text
    printf 'RUN echo %s\n' "$3" > "$1/$2/overlay.Dockerfile"
}

accept() { # workspace name
    bash "$LAUNCHER" -w "$1" --skills-accept "$2" < /dev/null >/dev/null 2>&1
}

launch() { # workspace [args...]
    local ws="$1"; shift
    bash "$LAUNCHER" -w "$ws" "$@" < /dev/null 2>&1
}

fed() { cat "$TMP/dockerfile-fed"; }
overlay_hash() { printf '%s' "$1" | grep -o 'claude-container-overlay:[a-f0-9]*' | head -1; }
order_file() { ls "$CHOICES"/"$1"-*.order 2>/dev/null | head -1; }


echo "== a skill fragment is baked into the image =="
WS1="$TMP/ws1"; mkdir -p "$WS1/.claude-container-overlay"
printf 'RUN echo workspace-step\n' > "$WS1/.claude-container-overlay/Dockerfile"
write_skill "$USER_SKILLS" nix-skill
write_fragment "$USER_SKILLS" nix-skill nix-step
accept "$WS1" nix-skill
OUT="$(launch "$WS1")"
assert_contains "fragment announced" "$OUT" "Skill image fragments"
assert_contains "fragment in effective Dockerfile" "$(fed)" "RUN echo nix-step"
assert_contains "attributed to its skill" "$(fed)" "fragment from skill 'nix-skill'"
assert_contains "workspace fragment still present" "$(fed)" "RUN echo workspace-step"
# Skill fragments must precede the workspace's own, so the project can build on them.
if [ "$(fed | grep -n 'nix-step' | cut -d: -f1)" -lt "$(fed | grep -n 'workspace-step' | cut -d: -f1)" ]; then
    pass "skill fragment ordered before the workspace fragment"
else
    fail "skill fragment ordered after the workspace fragment"
fi
assert_contains "order file records the skill" "$(cat "$(order_file ws1)")" "nix-skill"


echo "== a skill without a fragment adds nothing =="
write_skill "$USER_SKILLS" prose-only
accept "$WS1" prose-only
OUT="$(launch "$WS1")"
assert_contains "prose-only is still deployed as a skill" "$OUT" "prose-only"
assert_not_contains "prose-only contributes no fragment" "$(launch "$WS1" --skills-fragments)" "prose-only"
assert_not_contains "prose-only absent from order file" "$(cat "$(order_file ws1)")" "prose-only"


echo "== a rejected skill's fragment is excluded =="
WS2="$TMP/ws2"; mkdir -p "$WS2"
bash "$LAUNCHER" -w "$WS2" --skills-reject nix-skill < /dev/null >/dev/null 2>&1
OUT="$(launch "$WS2")"
assert_not_contains "rejected fragment not built" "$OUT" "Skill image fragments"


echo "== order is append-only, not alphabetical =="
WS3="$TMP/ws3"; mkdir -p "$WS3"
write_skill "$USER_SKILLS" zz-first
write_fragment "$USER_SKILLS" zz-first zz-step
accept "$WS3" zz-first
launch "$WS3" >/dev/null
assert_eq "first skill recorded" "$(cat "$(order_file ws3)")" "zz-first"
write_skill "$USER_SKILLS" aa-second
write_fragment "$USER_SKILLS" aa-second aa-step
accept "$WS3" aa-second
launch "$WS3" >/dev/null
assert_eq "second skill appended, not sorted ahead" "$(printf '%s' "$(cat "$(order_file ws3)")" | tr '\n' ',')" "zz-first,aa-second"
if [ "$(fed | grep -n 'zz-step' | cut -d: -f1)" -lt "$(fed | grep -n 'aa-step' | cut -d: -f1)" ]; then
    pass "build order follows the order file"
else
    fail "build order did not follow the order file"
fi


echo "== a rejected-then-reaccepted skill returns to its slot =="
HASH_BOTH="$(overlay_hash "$(launch "$WS3")")"
bash "$LAUNCHER" -w "$WS3" --skills-reject zz-first < /dev/null >/dev/null 2>&1
OUT="$(launch "$WS3")"
assert_not_contains "rejected fragment dropped from build" "$(launch "$WS3" --skills-fragments)" "zz-step"
HASH_REJECTED="$(overlay_hash "$OUT")"
if [ "$HASH_REJECTED" != "$HASH_BOTH" ]; then pass "rejecting changes the hash"; else fail "rejecting did not change the hash"; fi
accept "$WS3" zz-first
FRAGS="$(launch "$WS3" --skills-fragments)"
if [ "$(printf '%s' "$FRAGS" | grep -n 'zz-step' | cut -d: -f1)" -lt "$(printf '%s' "$FRAGS" | grep -n 'aa-step' | cut -d: -f1)" ]; then
    pass "re-accepted skill regained its original slot"
else
    fail "re-accepted skill was appended instead of restored"
fi
OUT="$(launch "$WS3")"
assert_eq "restored slot restores the original hash (no rebuild)" "$(overlay_hash "$OUT")" "$HASH_BOTH"
assert_not_contains "and therefore does not rebuild" "$OUT" "Building overlay image"


echo "== a fragment changes the image hash; prose does not =="
WS4="$TMP/ws4"; mkdir -p "$WS4"
write_skill "$USER_SKILLS" hash-skill
write_fragment "$USER_SKILLS" hash-skill hash-step
accept "$WS4" hash-skill
H1="$(overlay_hash "$(launch "$WS4")")"
printf -- '---\nname: hash-skill\ndescription: edited prose.\n---\n\nnew body\n' > "$USER_SKILLS/hash-skill/SKILL.md"
H2="$(overlay_hash "$(launch "$WS4")")"
assert_eq "editing SKILL.md prose keeps the hash" "$H2" "$H1"
write_fragment "$USER_SKILLS" hash-skill hash-step-v2
H3="$(overlay_hash "$(launch "$WS4")")"
if [ "$H3" != "$H1" ]; then pass "editing the fragment changes the hash"; else fail "fragment edit did not change the hash"; fi


echo "== a skill fragment alone builds an image with no workspace overlay =="
WS5="$TMP/ws5"; mkdir -p "$WS5"
write_skill "$USER_SKILLS" solo-skill
write_fragment "$USER_SKILLS" solo-skill solo-step
accept "$WS5" solo-skill
OUT="$(launch "$WS5")"
assert_contains "image built without a workspace overlay dir" "$OUT" "Building overlay image"
assert_contains "solo fragment fed to build" "$(fed)" "RUN echo solo-step"


echo "== build state is recorded =="
STATE="$(ls "$CHOICES"/ws5-*.build 2>/dev/null | head -1)"
assert_contains "state records the built image" "$(cat "$STATE")" "image=claude-container-overlay:"
assert_contains "state records the fragment digest" "$(cat "$STATE")" "fragments="


echo "== FROM/COPY in a fragment is warned about =="
WS6="$TMP/ws6"; mkdir -p "$WS6"
write_skill "$USER_SKILLS" bad-skill
printf 'COPY somefile /somefile\n' > "$USER_SKILLS/bad-skill/overlay.Dockerfile"
accept "$WS6" bad-skill
OUT="$(launch "$WS6")"
assert_contains "COPY warned about" "$OUT" "uses FROM/COPY/ADD"


echo "== a project with no fragments never prompts =="
WS9="$TMP/ws9"; mkdir -p "$WS9/.claude-container-overlay"
printf 'RUN echo plain-step\n' > "$WS9/.claude-container-overlay/Dockerfile"
OUT="$(launch "$WS9" --skills-ignore-new)"
assert_contains "plain overlay builds" "$OUT" "Building overlay image"
assert_not_contains "no first-time announcement" "$OUT" "for the first time"
assert_not_contains "no change announcement" "$OUT" "Skill image fragments changed"
printf 'RUN echo plain-step-v2\n' > "$WS9/.claude-container-overlay/Dockerfile"
OUT="$(launch "$WS9" --skills-ignore-new)"
assert_contains "editing its own overlay rebuilds" "$OUT" "Building overlay image"
assert_not_contains "and still does not prompt" "$OUT" "Rebuild the image now?"


echo "== --skills-fragments prints the effective text =="
OUT="$(launch "$WS1" --skills-fragments)"
assert_contains "prints the fragment body" "$OUT" "RUN echo nix-step"
assert_contains "prints the order file path" "$OUT" ".order"
OUT="$(launch "$WS2" --skills-fragments)"
assert_contains "reports when nothing contributes" "$OUT" "No skill active in this project"


echo "== --skills flags fragment-carrying skills =="
OUT="$(launch "$WS1" --skills)"
assert_contains "listing marks the image-building skill" "$OUT" "builds into the image"


echo "== changed fragments confirm before rebuilding =="
WS7="$TMP/ws7"; mkdir -p "$WS7"
write_skill "$USER_SKILLS" confirm-skill
write_fragment "$USER_SKILLS" confirm-skill confirm-v1
accept "$WS7" confirm-skill
OUT="$(launch "$WS7")"
assert_contains "first fragment-bearing build is announced too" "$OUT" "for the first time"
assert_not_contains "but not as a change" "$OUT" "Skill image fragments changed"
OLD_IMAGE="$(overlay_hash "$OUT")"
write_fragment "$USER_SKILLS" confirm-skill confirm-v2
OUT="$(launch "$WS7")"
assert_contains "changed fragment announces the change" "$OUT" "Skill image fragments changed"
assert_contains "non-interactive proceeds" "$OUT" "Non-interactive launch"

if command -v expect >/dev/null 2>&1; then
    WS8="$TMP/ws8"; mkdir -p "$WS8"
    write_skill "$USER_SKILLS" tty-skill
    write_fragment "$USER_SKILLS" tty-skill tty-v1
    accept "$WS8" tty-skill
    OUT="$(launch "$WS8")"
    BUILT_IMAGE="$(overlay_hash "$OUT")"
    write_fragment "$USER_SKILLS" tty-skill tty-v2
    OUT="$(expect -c "
set timeout 20
spawn env PATH=$TMP/bin:\$env(PATH) HOME=$HOME bash $LAUNCHER -w $WS8 --skills-ignore-new
expect \"Rebuild the image now?\" { send \"n\r\" }
expect eof
" 2>&1)"
    assert_contains "tty launch prompts" "$OUT" "Rebuild the image now?"
    assert_contains "declining keeps the previous image" "$OUT" "Keeping $BUILT_IMAGE"
    assert_contains "declining warns the fragments are absent" "$OUT" "are NOT in it"
    assert_contains "declining runs the old image" "$OUT" "DOCKER-RUN: run"
    assert_not_contains "declining does not build" "$OUT" "Building overlay image"

    OUT="$(expect -c "
set timeout 20
spawn env PATH=$TMP/bin:\$env(PATH) HOME=$HOME bash $LAUNCHER -w $WS8 --skills-ignore-new
expect \"Rebuild the image now?\" { send \"y\r\" }
expect eof
" 2>&1)"
    assert_contains "re-prompted after declining" "$OUT" "Rebuild the image now?"
    assert_contains "accepting rebuilds" "$OUT" "Building overlay image"
    OUT="$(launch "$WS8")"
    assert_not_contains "no prompt once the new fragments are built" "$OUT" "Skill image fragments changed"
else
    echo "  (skipped tty tests: expect not installed)"
fi


echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
