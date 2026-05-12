#!/bin/bash
# omarchy-bg-spread.sh
#
# Copies every image from ~/Pictures (or a folder you pass as $1) into the
# user-backgrounds directory of every installed Omarchy theme, so a custom
# wallpaper survives theme switches.
#
# Usage:
#   omarchy-bg-spread.sh                  # uses ~/Pictures
#   omarchy-bg-spread.sh /path/to/folder  # uses given folder
#   omarchy-bg-spread.sh --clean          # remove previously spread images
#
# Idempotent. Safe to rerun.

set -uo pipefail

SRC_DIR="${1:-$HOME/Pictures}"
THEMES_DIR="$HOME/.config/omarchy/themes"
USER_BG_ROOT="$HOME/.config/omarchy/backgrounds"
MARKER=".bg-spread.marker"   # tag file marking spread copies for safe cleanup

log()  { echo "[bg-spread] $*"; }
warn() { echo "[bg-spread][WARN] $*" >&2; }
err()  { echo "[bg-spread][ERR] $*" >&2; }

if [[ "${1:-}" == "--clean" ]]; then
    log "Removing previously spread backgrounds..."
    if [[ -d "$USER_BG_ROOT" ]]; then
        find "$USER_BG_ROOT" -name "$MARKER" -print0 | while IFS= read -r -d '' marker; do
            dir="$(dirname "$marker")"
            if [[ -f "$dir/.bg-spread.list" ]]; then
                while IFS= read -r img; do
                    [[ -f "$dir/$img" ]] && rm -f "$dir/$img"
                done < "$dir/.bg-spread.list"
                rm -f "$dir/.bg-spread.list" "$marker"
                log "  Cleaned $dir"
            fi
        done
    fi
    log "Done."
    exit 0
fi

if [[ ! -d "$SRC_DIR" ]]; then
    err "Source folder does not exist: $SRC_DIR"
    exit 1
fi

if [[ ! -d "$THEMES_DIR" ]]; then
    err "Omarchy themes dir not found: $THEMES_DIR"
    err "Is Omarchy installed?"
    exit 1
fi

shopt -s nullglob nocaseglob
IMAGES=("$SRC_DIR"/*.{jpg,jpeg,png,webp})
shopt -u nullglob nocaseglob

if [[ ${#IMAGES[@]} -eq 0 ]]; then
    err "No images (jpg/jpeg/png/webp) found in $SRC_DIR"
    exit 1
fi

log "Found ${#IMAGES[@]} image(s) in $SRC_DIR"

COUNT_THEMES=0
for theme_path in "$THEMES_DIR"/*/; do
    [[ -d "$theme_path" ]] || continue
    THEME=$(basename "$theme_path")
    DEST="$USER_BG_ROOT/$THEME"
    mkdir -p "$DEST"

    # Track copies so --clean can remove only them, not user-curated extras
    LIST_FILE="$DEST/.bg-spread.list"
    : > "$LIST_FILE"

    for img in "${IMAGES[@]}"; do
        base=$(basename "$img")
        cp -u "$img" "$DEST/$base"
        echo "$base" >> "$LIST_FILE"
    done

    touch "$DEST/$MARKER"
    COUNT_THEMES=$((COUNT_THEMES + 1))
done

log "Spread images across $COUNT_THEMES theme(s) under $USER_BG_ROOT/"

# Trigger active-theme refresh so user sees a result without manually cycling
if command -v omarchy-theme-bg-next &>/dev/null; then
    log "Applying first new background to current theme..."
    omarchy-theme-bg-next >/dev/null 2>&1 || warn "bg-next failed (non-fatal)."
fi

log "Done. Cycle backgrounds with: omarchy-theme-bg-next"
log "Or pick one via: SUPER + Ctrl + Space"
log "Undo: $(basename "$0") --clean"
