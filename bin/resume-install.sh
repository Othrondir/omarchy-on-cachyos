#!/bin/bash
# resume-install.sh
#
# Recovers a failed/interrupted Omarchy-on-CachyOS installation.
#
# What it does:
#   1. Refreshes pacman keyrings and mirror rankings (most common failure cause
#      is stale CachyOS mirrors returning 404 for fresh package revisions).
#   2. Forces a full DB sync.
#   3. Detects how far the previous install got and offers two recovery paths:
#       - resume: re-run Omarchy's install.sh from ~/.local/share/omarchy
#                 (skips repo clone + patching steps)
#       - clean:  wipe ../omarchy and ~/.local/share/omarchy and re-run the
#                 full install-omarchy-on-cachyos.sh from scratch
#
# Idempotent. Safe to run multiple times.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="$SCRIPT_DIR/install-omarchy-on-cachyos.sh"

log()  { echo "[resume] $*"; }
warn() { echo "[resume][WARN] $*" >&2; }
err()  { echo "[resume][ERR] $*" >&2; }

if [[ "$EUID" -eq 0 ]]; then
    err "Do not run this script as root. It calls sudo itself."
    exit 1
fi

# ---------------------------------------------------------------------------
# 1. Mirror & keyring refresh
# ---------------------------------------------------------------------------
log "Refreshing pacman keyrings..."
sudo pacman -Sy --needed --noconfirm archlinux-keyring cachyos-keyring \
    || warn "Keyring refresh failed — continuing."

if command -v cachyos-rate-mirrors &>/dev/null; then
    log "Re-rating CachyOS mirrors (this can take a minute)..."
    sudo cachyos-rate-mirrors || warn "cachyos-rate-mirrors failed."
else
    warn "cachyos-rate-mirrors not found — skipping CachyOS mirror rerank."
fi

if ! command -v reflector &>/dev/null; then
    log "Installing reflector..."
    sudo pacman -S --needed --noconfirm reflector || warn "reflector install failed."
fi

if command -v reflector &>/dev/null; then
    log "Re-ranking Arch mirrors via reflector..."
    sudo reflector --latest 15 --sort rate --protocol https \
        --save /etc/pacman.d/mirrorlist || warn "reflector failed."
fi

log "Forcing full DB sync (pacman -Syyu)..."
if ! sudo pacman -Syyu --noconfirm; then
    err "pacman -Syyu still failing. Wait a few minutes and rerun this script."
    err "If errors persist, edit /etc/pacman.d/mirrorlist manually."
    exit 1
fi

# ---------------------------------------------------------------------------
# 2. Detect install state
# ---------------------------------------------------------------------------
OMARCHY_HOME="$HOME/.local/share/omarchy"
OMARCHY_CLONE="$(cd "$SCRIPT_DIR/.." && pwd)/../omarchy"

STATE="fresh"
if [[ -d "$OMARCHY_HOME" && -f "$OMARCHY_HOME/install.sh" ]]; then
    STATE="partial"
fi

log "Detected install state: $STATE"
echo ""

# ---------------------------------------------------------------------------
# 3. Choose recovery path
# ---------------------------------------------------------------------------
if [[ "$STATE" == "partial" ]]; then
    cat <<EOF
A previous Omarchy install was found at:
    $OMARCHY_HOME

Recovery options:
  [r] Resume — re-run Omarchy's install.sh in-place (fast, recommended).
  [c] Clean  — wipe ../omarchy and $OMARCHY_HOME, then re-run the full
              wrapper from scratch.
  [q] Quit   — exit without changes.

EOF
    read -r -p "Choice [r/c/q]: " CHOICE
else
    cat <<EOF
No partial Omarchy install detected. The wrapper will run from scratch.

  [r] Run install-omarchy-on-cachyos.sh now.
  [q] Quit.

EOF
    read -r -p "Choice [r/q]: " CHOICE
fi

case "${CHOICE,,}" in
    r)
        if [[ "$STATE" == "partial" ]]; then
            log "Re-applying CachyOS patches to $OMARCHY_HOME before resume..."
            # Patches must be idempotent — sed -i with grep guards handles re-runs.
            ALL_SH="$OMARCHY_HOME/install/config/all.sh"
            LOGIN_ALL="$OMARCHY_HOME/install/login/all.sh"
            POST_ALL="$OMARCHY_HOME/install/post-install/all.sh"

            [[ -f "$ALL_SH" ]] && \
                sed -i '/run_logged \$OMARCHY_INSTALL\/config\/hardware\/intel\/thermald\.sh/d' "$ALL_SH"

            [[ -f "$LOGIN_ALL" ]] && {
                sed -i '/run_logged \$OMARCHY_INSTALL\/login\/plymouth\.sh/d' "$LOGIN_ALL"
                sed -i '/run_logged \$OMARCHY_INSTALL\/login\/limine-snapper\.sh/d' "$LOGIN_ALL"
                sed -i '/run_logged \$OMARCHY_INSTALL\/login\/alt-bootloaders\.sh/d' "$LOGIN_ALL"
            }

            [[ -f "$POST_ALL" ]] && \
                sed -i '/run_logged \$OMARCHY_INSTALL\/post-install\/pacman\.sh/d' "$POST_ALL"

            # Re-copy custom nvidia.sh (in case it was overwritten by a prior reset)
            if [[ -f "$SCRIPT_DIR/nvidia.sh" && -d "$OMARCHY_HOME/install/config/hardware" ]]; then
                cp "$SCRIPT_DIR/nvidia.sh" "$OMARCHY_HOME/install/config/hardware/nvidia.sh"
                chmod +x "$OMARCHY_HOME/install/config/hardware/nvidia.sh"
            fi

            log "Resuming: re-running $OMARCHY_HOME/install.sh ..."
            cd "$OMARCHY_HOME" || { err "Cannot cd into $OMARCHY_HOME"; exit 1; }
            chmod +x install.sh
            exec ./install.sh
        else
            log "Running fresh wrapper: $WRAPPER"
            if [[ ! -x "$WRAPPER" ]]; then
                chmod +x "$WRAPPER"
            fi
            exec "$WRAPPER"
        fi
        ;;
    c)
        log "Cleaning previous install artifacts..."
        if [[ -d "$OMARCHY_HOME" ]]; then
            log "  rm -rf $OMARCHY_HOME"
            rm -rf "$OMARCHY_HOME"
        fi
        if [[ -d "$OMARCHY_CLONE" ]]; then
            log "  rm -rf $OMARCHY_CLONE"
            rm -rf "$OMARCHY_CLONE"
        fi
        log "Running fresh wrapper: $WRAPPER"
        if [[ ! -x "$WRAPPER" ]]; then
            chmod +x "$WRAPPER"
        fi
        exec "$WRAPPER"
        ;;
    q|"")
        log "Quit. No changes beyond mirror refresh."
        exit 0
        ;;
    *)
        err "Unknown choice: $CHOICE"
        exit 1
        ;;
esac
