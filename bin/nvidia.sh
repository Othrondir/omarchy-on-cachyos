#!/bin/bash
set -uo pipefail

log() { echo "[nvidia.sh] $*"; }
warn() { echo "[nvidia.sh][WARN] $*" >&2; }

# 1. Get GPU ID
GPU_ID=$(lspci -nn -d 10de: 2>/dev/null | grep -E "VGA|3D" | head -n1 | grep -oP '(?<=\[10de:)[0-9a-fA-F]{4}(?=\])' || true)

if [[ -z "$GPU_ID" ]]; then
    log "No NVIDIA GPU found. Skipping."
    exit 0
fi

log "Found NVIDIA ID: $GPU_ID"

# 2. Kill the conflicts
log "Removing conflicting open-driver packages..."
sudo pacman -Rdd --noconfirm libxnvctrl linux-cachyos-nvidia-open linux-cachyos-lts-nvidia-open nvidia-open-dkms 2>/dev/null || true

# 3. Patch the chwd ids file (autodetect filename — varies by chwd version)
IDS_DIR="/var/lib/chwd/ids"
IDS_FILE=""

if [[ -d "$IDS_DIR" ]]; then
    for candidate in \
        "$IDS_DIR/nvidia-580.ids" \
        "$IDS_DIR/nvidia-580xx.ids" \
        "$IDS_DIR/nvidia-dkms.ids" \
        "$IDS_DIR/nvidia.ids"; do
        if [[ -f "$candidate" ]]; then
            IDS_FILE="$candidate"
            break
        fi
    done

    if [[ -z "$IDS_FILE" ]]; then
        for f in "$IDS_DIR"/nvidia*.ids; do
            [[ -f "$f" ]] && IDS_FILE="$f" && break
        done
    fi
fi

if [[ -n "$IDS_FILE" ]]; then
    log "Using chwd ids file: $IDS_FILE"
    if ! sudo grep -qi "$GPU_ID" "$IDS_FILE"; then
        log "Patching chwd ID list with $GPU_ID..."
        if [[ -s "$IDS_FILE" ]] && [[ -n "$(sudo tail -c1 "$IDS_FILE")" ]]; then
            sudo sh -c "echo >> '$IDS_FILE'"
        fi
        sudo sh -c "printf '%s\n' '$GPU_ID' >> '$IDS_FILE'"
    else
        log "GPU ID already present in $(basename "$IDS_FILE")."
    fi
else
    warn "No chwd nvidia ids file found under $IDS_DIR — skipping patch."
fi

# 4. Detect actual chwd profile name for 580xx (varies by chwd version)
# Known names seen across chwd versions: nvidia-dkms-580xx, nvidia-580xx-dkms, nvidia-dkms
PROFILE_580=""
if command -v chwd >/dev/null 2>&1; then
    PROFILE_LIST=$(chwd -l 2>/dev/null || chwd --list 2>/dev/null || true)
    for cand in nvidia-dkms-580xx nvidia-580xx-dkms nvidia-dkms; do
        if echo "$PROFILE_LIST" | grep -q "$cand"; then
            PROFILE_580="$cand"
            break
        fi
    done
fi

# 5. Remove old open-driver profile (non-fatal)
log "Removing old chwd open-driver profile (if present)..."
for openp in nvidia-open-dkms nvidia-open; do
    sudo chwd -r "$openp" --noconfirm 2>/dev/null || true
done

# 6. Install the 580xx proprietary profile explicitly
# `chwd -a` may match nvidia-open-dkms first (device_ids="*"), so prefer explicit install
if [[ -n "$PROFILE_580" ]]; then
    log "Installing chwd profile: $PROFILE_580"
    if ! sudo chwd -i pci "$PROFILE_580" --noconfirm 2>/dev/null; then
        # Older chwd syntax fallback
        if ! sudo chwd -i "$PROFILE_580" --noconfirm 2>/dev/null; then
            warn "Explicit profile install failed for $PROFILE_580. Falling back to chwd -a."
            sudo chwd -a || warn "chwd -a also failed. Install nvidia-580xx-dkms manually."
        fi
    fi
else
    warn "Could not detect 580xx profile name from chwd. Falling back to chwd -a."
    sudo chwd -a || warn "chwd -a failed. Install nvidia-580xx-dkms manually."
fi

# 7. Sanity check — ensure proprietary driver package is installed
if ! pacman -Qq nvidia-580xx-dkms >/dev/null 2>&1 \
   && ! pacman -Qq nvidia-dkms     >/dev/null 2>&1; then
    log "No NVIDIA dkms package detected after chwd. Installing nvidia-580xx-dkms directly..."
    sudo pacman -S --needed --noconfirm nvidia-580xx-dkms nvidia-580xx-utils \
        || warn "Direct nvidia-580xx-dkms install failed. Check pacman/AUR sources."
fi

# 8. Install VA-API utils
sudo pacman -S --needed --noconfirm libva-utils || warn "libva-utils install failed."

# 9. Add NVIDIA environment variables for UWSM (idempotent)
UWSM_ENV_DIR="$HOME/.config/uwsm"
UWSM_ENV_FILE="$UWSM_ENV_DIR/env"
mkdir -p "$UWSM_ENV_DIR"
touch "$UWSM_ENV_FILE"

if ! grep -q "^export GBM_BACKEND=nvidia-drm" "$UWSM_ENV_FILE" 2>/dev/null; then
    log "Appending NVIDIA env vars to $UWSM_ENV_FILE"
    cat >>"$UWSM_ENV_FILE" <<'EOF'

# NVIDIA
export LIBVA_DRIVER_NAME=nvidia
export GBM_BACKEND=nvidia-drm
export __GLX_VENDOR_LIBRARY_NAME=nvidia
export NVD_BACKEND=direct
export MOZ_DISABLE_RDD_SANDBOX=1
export CUDA_DISABLE_PERF_BOOST=1
EOF
else
    log "NVIDIA env vars already present in uwsm/env — skipping."
fi

log "Done."
