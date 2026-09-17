#!/bin/bash
#
# Installer for claude-container.
#
# Installs the launcher script and bash completions, and builds the container
# image from this repository's claude-code/ Dockerfile, tagged with the version
# the launcher expects (shadowing the Docker Hub image of the same name, since
# this repo's Ubuntu-based image differs from upstream).
#
# Idempotent: safe to re-run. Files are overwritten in place, and the image
# build is a cached no-op when nothing changed.
#
# Usage:
#   ./install.sh                    # user install (~/.local) + image build
#   ./install.sh --system           # install to /usr/local/bin (uses sudo)
#   ./install.sh --bin-dir <dir>    # custom launcher location
#   ./install.sh --no-build         # skip the docker image build
#   ./install.sh --no-completions   # skip bash completion install
#   ./install.sh --autostart        # keep the router running from login on
#   ./install.sh --tailnet          # reach services from other tailnet devices

set -e

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Color codes for output (match bin/claude-container)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

BIN_DIR="$HOME/.local/bin"
COMPLETIONS_DIR="$HOME/.local/share/bash-completion/completions"
SYSTEM_INSTALL=false
BUILD_IMAGE=true
INSTALL_COMPLETIONS=true
SUDO=""
# "" leaves the login service alone (but refreshes it if already installed);
# "install"/"remove" are the explicit opt-in and teardown.
AUTOSTART=""
TAILNET=""

show_help() {
    cat << EOF
claude-container installer

Installs the launcher and bash completions, and builds the container image from
this repository (tagged so the launcher's default image name resolves locally).

USAGE:
    ./install.sh [OPTIONS]

OPTIONS:
    --system                Install launcher to /usr/local/bin and completions
                            to /etc/bash_completion.d (uses sudo if needed)
    --bin-dir <dir>         Install launcher to <dir> (default: ~/.local/bin)
    --completions-dir <dir> Install completions to <dir>
                            (default: ~/.local/share/bash-completion/completions)
    --no-build              Skip building the docker image
    --no-completions        Skip installing bash completions
    --autostart             Install a per-user login service (launchd on macOS,
                            systemd --user on Linux) that keeps the service
                            router running, so named-service URLs work straight
                            after a reboot instead of only once a container has
                            been launched
    --remove-autostart      Remove that login service
    --tailnet               Put 'tailscale serve' in front of the router so other
                            devices on your tailnet can open its services over
                            HTTPS. Tailnet-only, never Funnel; the router itself
                            stays bound to loopback. Implies --autostart
    --remove-tailnet        Remove the tailscale serve configuration
    -h, --help              Show this help message

The script is idempotent — re-running it overwrites the installed files in
place and re-uses docker's build cache, so it is also the update path after
pulling new changes.
EOF
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        --system)
            SYSTEM_INSTALL=true
            BIN_DIR="/usr/local/bin"
            COMPLETIONS_DIR="/etc/bash_completion.d"
            shift
            ;;
        --bin-dir)
            if [ -z "${2:-}" ]; then
                echo -e "${RED}Error: --bin-dir requires a directory${NC}"
                exit 1
            fi
            BIN_DIR="$2"
            shift 2
            ;;
        --completions-dir)
            if [ -z "${2:-}" ]; then
                echo -e "${RED}Error: --completions-dir requires a directory${NC}"
                exit 1
            fi
            COMPLETIONS_DIR="$2"
            shift 2
            ;;
        --no-build)
            BUILD_IMAGE=false
            shift
            ;;
        --no-completions)
            INSTALL_COMPLETIONS=false
            shift
            ;;
        --autostart)
            AUTOSTART="install"
            shift
            ;;
        --remove-autostart)
            AUTOSTART="remove"
            shift
            ;;
        --tailnet)
            TAILNET="install"
            shift
            ;;
        --remove-tailnet)
            TAILNET="remove"
            shift
            ;;
        *)
            echo -e "${RED}Error: unknown option '$1'${NC}"
            echo "Run ./install.sh --help for usage."
            exit 1
            ;;
    esac
done

if [ ! -f "$REPO_DIR/bin/claude-container" ]; then
    echo -e "${RED}Error: bin/claude-container not found next to install.sh — run from a repo checkout.${NC}"
    exit 1
fi

# The launcher's VERSION determines the image tag it looks for; build under the
# same tag so no Docker Hub pull is needed (or wanted — this repo's image
# replaces the upstream one).
VERSION="$(sed -n 's/^VERSION="\(.*\)"/\1/p' "$REPO_DIR/bin/claude-container" | head -1)"
if [ -z "$VERSION" ]; then
    echo -e "${RED}Error: could not read VERSION from bin/claude-container${NC}"
    exit 1
fi
IMAGE="nezhar/claude-container:${VERSION}"

if [ "$SYSTEM_INSTALL" = true ] && [ "$(id -u)" -ne 0 ]; then
    SUDO="sudo"
fi

# --- Launcher -----------------------------------------------------------------
echo -e "${GREEN}Installing launcher to ${BIN_DIR}/claude-container${NC}"
$SUDO mkdir -p "$BIN_DIR"
$SUDO install -m 0755 "$REPO_DIR/bin/claude-container" "$BIN_DIR/claude-container"

# The service router backs the launcher's named-service features (--services,
# --service-port, --router-*); the launcher looks for it next to itself.
echo -e "${GREEN}Installing service router to ${BIN_DIR}/claude-container-router${NC}"
$SUDO install -m 0755 "$REPO_DIR/bin/claude-container-router" "$BIN_DIR/claude-container-router"

case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *)
        echo -e "${YELLOW}Note: $BIN_DIR is not in your PATH.${NC}"
        echo -e "${YELLOW}  bash/zsh: export PATH=\"$BIN_DIR:\$PATH\"${NC}"
        echo -e "${YELLOW}  fish:     fish_add_path $BIN_DIR${NC}"
        ;;
esac

# --- Completions ----------------------------------------------------------------
if [ "$INSTALL_COMPLETIONS" = true ]; then
    if [ -f "$REPO_DIR/completions/claude-container" ]; then
        echo -e "${GREEN}Installing bash completions to ${COMPLETIONS_DIR}/claude-container${NC}"
        $SUDO mkdir -p "$COMPLETIONS_DIR"
        $SUDO install -m 0644 "$REPO_DIR/completions/claude-container" "$COMPLETIONS_DIR/claude-container"
    else
        echo -e "${YELLOW}Warning: completions/claude-container not found; skipping completions.${NC}"
    fi
fi

# --- Image ----------------------------------------------------------------------
if [ "$BUILD_IMAGE" = true ]; then
    if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
        echo -e "${RED}Error: Docker is not running or not accessible.${NC}"
        echo -e "${YELLOW}Start Docker and re-run ./install.sh (or use --no-build to skip the image).${NC}"
        exit 1
    fi
    echo -e "${GREEN}Building container image ${IMAGE} from claude-code/ ...${NC}"
    docker build -t "$IMAGE" -t nezhar/claude-container:latest "$REPO_DIR/claude-code"
    echo -e "${BLUE}Note: this local image shadows the Docker Hub tag of the same name;${NC}"
    echo -e "${BLUE}'claude-container --pull' would replace it with the upstream image.${NC}"
    echo -e "${BLUE}To update after changing claude-code/, just re-run ./install.sh.${NC}"
else
    echo -e "${BLUE}Skipping image build (--no-build). The launcher expects ${IMAGE}.${NC}"
fi

# --- Router autostart and tailnet exposure ------------------------------------
#
# The router normally starts on demand: every container launch shells out to
# `claude-container-router ensure`. That is enough when you drive everything from
# this machine, but it leaves a gap if you want to reach a service from another
# device right after a reboot, before any container has run. --autostart closes
# it with a per-user login service; --tailnet puts `tailscale serve` in front of
# the router so other devices on your tailnet can reach it.

LAUNCHD_LABEL="com.claude-container.router"
SYSTEMD_UNIT="claude-container-router.service"
ROUTER_HTTP_PORT="${CLAUDE_ROUTER_HTTP_PORT:-8484}"

# The router keeps its state under the user's config dir, so the login service is
# per-user: `sudo ./install.sh --system` still installs it for the invoking user,
# not for root.
AUTOSTART_USER="$(id -un)"
AUTOSTART_HOME="$HOME"
if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    AUTOSTART_USER="$SUDO_USER"
    if command -v getent >/dev/null 2>&1; then
        AUTOSTART_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
    elif command -v dscl >/dev/null 2>&1; then
        AUTOSTART_HOME="$(dscl . -read "/Users/$SUDO_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
    fi
fi

# Overridable so the test suite can point them at a scratch dir.
HOST_OS="${CLAUDE_CONTAINER_OS:-$(uname -s)}"
LAUNCHAGENTS_DIR="${CLAUDE_CONTAINER_LAUNCHAGENTS_DIR:-$AUTOSTART_HOME/Library/LaunchAgents}"
SYSTEMD_USER_DIR="${CLAUDE_CONTAINER_SYSTEMD_USER_DIR:-$AUTOSTART_HOME/.config/systemd/user}"
ROUTER_CONFIG_BASE="${CLAUDE_CONTAINER_CONFIG_BASE:-$AUTOSTART_HOME/.config/claude-container}"
PLIST_PATH="$LAUNCHAGENTS_DIR/$LAUNCHD_LABEL.plist"
UNIT_PATH="$SYSTEMD_USER_DIR/$SYSTEMD_UNIT"

as_user() {
    if [ "$(id -un)" = "$AUTOSTART_USER" ]; then
        "$@"
    else
        sudo -u "$AUTOSTART_USER" "$@"
    fi
}

write_launchagent() {
    # The router is a `#!/usr/bin/env python3` script and launchd's default PATH
    # has no Homebrew, so pin the interpreter's directory at the front of it.
    local py_bin path_env
    py_bin="$(command -v python3 2>/dev/null || true)"
    path_env="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    if [ -n "$py_bin" ]; then
        path_env="$(dirname "$py_bin"):$path_env"
    fi

    mkdir -p "$LAUNCHAGENTS_DIR" "$ROUTER_CONFIG_BASE"
    cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LAUNCHD_LABEL</string>

    <key>ProgramArguments</key>
    <array>
        <string>$BIN_DIR/claude-container-router</string>
        <string>run</string>
    </array>

    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>$path_env</string>
    </dict>

    <key>RunAtLoad</key>
    <true/>

    <!-- Respawn after a crash, but let 'claude-container --router-stop'
         (SIGTERM, clean exit 0) stay stopped instead of fighting launchd. -->
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>

    <key>ThrottleInterval</key>
    <integer>10</integer>

    <!-- The same log 'claude-container --router-logs' reads. -->
    <key>StandardOutPath</key>
    <string>$ROUTER_CONFIG_BASE/router.log</string>
    <key>StandardErrorPath</key>
    <string>$ROUTER_CONFIG_BASE/router.log</string>

    <key>ProcessType</key>
    <string>Background</string>
</dict>
</plist>
PLIST
}

write_systemd_unit() {
    mkdir -p "$SYSTEMD_USER_DIR" "$ROUTER_CONFIG_BASE"
    cat > "$UNIT_PATH" <<UNIT
[Unit]
Description=claude-container service router
After=network.target

[Service]
ExecStart=$BIN_DIR/claude-container-router run
# Mirrors the launchd KeepAlive: respawn after a crash, but let
# 'claude-container --router-stop' (clean exit 0) stay stopped.
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
UNIT
}

autostart_install() {
    case "$HOST_OS" in
        Darwin)
            echo -e "${GREEN}Installing router login service to ${PLIST_PATH}${NC}"
            write_launchagent
            if [ "$(id -un)" != "$AUTOSTART_USER" ]; then
                chown "$AUTOSTART_USER" "$PLIST_PATH"
            fi
            local domain="gui/$(id -u "$AUTOSTART_USER")"
            # Unload any previous job, then drop an on-demand instance that would
            # otherwise still be holding the router's port.
            as_user launchctl bootout "$domain/$LAUNCHD_LABEL" >/dev/null 2>&1 || true
            as_user "$BIN_DIR/claude-container-router" stop >/dev/null 2>&1 || true
            if as_user launchctl bootstrap "$domain" "$PLIST_PATH"; then
                echo -e "${BLUE}Router starts at login. Restart it by hand with:${NC}"
                echo -e "${BLUE}  launchctl kickstart $domain/$LAUNCHD_LABEL${NC}"
            else
                echo -e "${YELLOW}Warning: launchctl bootstrap failed; the router will still${NC}"
                echo -e "${YELLOW}start on demand when you launch a container.${NC}"
            fi
            ;;
        Linux)
            if ! command -v systemctl >/dev/null 2>&1; then
                echo -e "${YELLOW}Warning: systemctl not found; skipping --autostart.${NC}"
                echo -e "${YELLOW}The router still starts on demand at container launch.${NC}"
                return 0
            fi
            echo -e "${GREEN}Installing router login service to ${UNIT_PATH}${NC}"
            write_systemd_unit
            if [ "$(id -un)" != "$AUTOSTART_USER" ]; then
                chown "$AUTOSTART_USER" "$UNIT_PATH"
            fi
            as_user systemctl --user daemon-reload || true
            as_user "$BIN_DIR/claude-container-router" stop >/dev/null 2>&1 || true
            if as_user systemctl --user enable --now "$SYSTEMD_UNIT"; then
                echo -e "${BLUE}Router starts at login.${NC}"
                echo -e "${BLUE}To keep it running while logged out:${NC}"
                echo -e "${BLUE}  sudo loginctl enable-linger $AUTOSTART_USER${NC}"
            else
                echo -e "${YELLOW}Warning: systemctl enable failed; the router will still${NC}"
                echo -e "${YELLOW}start on demand when you launch a container.${NC}"
            fi
            ;;
        *)
            echo -e "${YELLOW}Warning: --autostart supports macOS and Linux only (got $HOST_OS).${NC}"
            ;;
    esac
}

autostart_remove() {
    case "$HOST_OS" in
        Darwin)
            if [ ! -f "$PLIST_PATH" ]; then
                echo -e "${BLUE}No router login service installed.${NC}"
                return 0
            fi
            echo -e "${GREEN}Removing router login service ${PLIST_PATH}${NC}"
            as_user launchctl bootout "gui/$(id -u "$AUTOSTART_USER")/$LAUNCHD_LABEL" >/dev/null 2>&1 || true
            rm -f "$PLIST_PATH"
            ;;
        Linux)
            if [ ! -f "$UNIT_PATH" ]; then
                echo -e "${BLUE}No router login service installed.${NC}"
                return 0
            fi
            echo -e "${GREEN}Removing router login service ${UNIT_PATH}${NC}"
            if command -v systemctl >/dev/null 2>&1; then
                as_user systemctl --user disable --now "$SYSTEMD_UNIT" >/dev/null 2>&1 || true
            fi
            rm -f "$UNIT_PATH"
            if command -v systemctl >/dev/null 2>&1; then
                as_user systemctl --user daemon-reload || true
            fi
            ;;
    esac
    echo -e "${BLUE}The router still starts on demand at container launch.${NC}"
}

find_tailscale() {
    # An explicit override still has to exist: silently falling back to a
    # different binary than the one asked for would be worse than failing.
    if [ -n "${TAILSCALE_BIN:-}" ]; then
        if [ -x "$TAILSCALE_BIN" ]; then
            echo "$TAILSCALE_BIN"
        fi
        return 0
    fi
    if command -v tailscale >/dev/null 2>&1; then
        command -v tailscale
        return 0
    fi
    # The macOS builds ship the CLI inside the app bundle and often never put it
    # on PATH.
    local candidate
    for candidate in /Applications/Tailscale.app/Contents/MacOS/Tailscale \
                     /opt/homebrew/bin/tailscale /usr/local/bin/tailscale; do
        if [ -x "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    done
    return 0
}

tailnet_install() {
    local ts
    ts="$(find_tailscale)"
    if [ -z "$ts" ]; then
        echo -e "${RED}Error: the tailscale CLI was not found.${NC}"
        if [ -n "${TAILSCALE_BIN:-}" ]; then
            echo -e "${YELLOW}TAILSCALE_BIN=$TAILSCALE_BIN is not executable.${NC}"
        fi
        echo -e "${YELLOW}Install Tailscale, or re-run with TAILSCALE_BIN=/path/to/tailscale.${NC}"
        echo -e "${YELLOW}On macOS it lives inside the app bundle:${NC}"
        echo -e "${YELLOW}  /Applications/Tailscale.app/Contents/MacOS/Tailscale${NC}"
        return 1
    fi

    echo -e "${GREEN}Exposing the router on your tailnet (${ts} serve)${NC}"
    if ! as_user "$ts" serve --bg --https=443 --set-path=/ "http://127.0.0.1:${ROUTER_HTTP_PORT}"; then
        echo -e "${RED}Error: 'tailscale serve' failed.${NC}"
        echo -e "${YELLOW}Check that this machine is logged in ('tailscale status') and that${NC}"
        echo -e "${YELLOW}HTTPS certificates are enabled for the tailnet in the admin console.${NC}"
        return 1
    fi

    local dns=""
    if command -v python3 >/dev/null 2>&1; then
        dns="$(as_user "$ts" status --json 2>/dev/null | python3 -c \
            'import json,sys; print(json.load(sys.stdin).get("Self",{}).get("DNSName","").rstrip("."))' \
            2>/dev/null || true)"
    fi
    if [ -n "$dns" ]; then
        echo -e "${BLUE}  index:    https://${dns}/${NC}"
        echo -e "${BLUE}  services: https://${dns}/<instance>/<service>/${NC}"
    fi
    echo -e "${BLUE}Tailnet-only — this is 'serve', not 'funnel'; nothing is published to${NC}"
    echo -e "${BLUE}the internet, and the router itself stays bound to loopback.${NC}"
    echo -e "${BLUE}Other devices must use the path form above: the *.claude.localhost${NC}"
    echo -e "${BLUE}names resolve to the client's own loopback, not to this machine.${NC}"
}

tailnet_remove() {
    local ts
    ts="$(find_tailscale)"
    if [ -z "$ts" ]; then
        echo -e "${YELLOW}Warning: tailscale CLI not found; nothing to remove.${NC}"
        return 0
    fi
    echo -e "${GREEN}Removing the tailnet proxy (${ts} serve --https=443 off)${NC}"
    as_user "$ts" serve --https=443 off || true
}

# --tailnet without a running router would proxy to a dead port after a reboot.
if [ "$TAILNET" = "install" ] && [ -z "$AUTOSTART" ]; then
    AUTOSTART="install"
    echo -e "${BLUE}--tailnet implies --autostart (the proxy needs the router up).${NC}"
fi

# An already-installed login service is refreshed on every run, since BIN_DIR or
# the python interpreter may have moved — the same idempotent-update contract as
# the launcher itself. It is never installed implicitly.
if [ -z "$AUTOSTART" ]; then
    if [ "$HOST_OS" = "Darwin" ] && [ -f "$PLIST_PATH" ]; then
        AUTOSTART="install"
    elif [ "$HOST_OS" = "Linux" ] && [ -f "$UNIT_PATH" ]; then
        AUTOSTART="install"
    fi
fi

case "$AUTOSTART" in
    install) autostart_install ;;
    remove)  autostart_remove ;;
esac

case "$TAILNET" in
    install) tailnet_install ;;
    remove)  tailnet_remove ;;
esac


echo ""
echo -e "${GREEN}Done.${NC} Run '${YELLOW}claude-container${NC}' in a workspace to get started."
