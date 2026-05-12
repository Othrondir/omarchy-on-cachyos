#!/bin/bash
# install-omarchy-on-cachyos.sh
#
# Wrapper that installs DHH's Omarchy on top of CachyOS.
#
# Options:
#   --dry-run            Log destructive system actions without executing them.
#                        Still clones Omarchy into ../omarchy and runs the local
#                        sed patches so syntax can be validated, but does not
#                        touch pacman, /etc/, or actually launch install.sh.
#   --profile=laptop     Default. Applies all laptop-oriented tweaks
#                        (iwd wifi backend, kept ignore-power-button, etc).
#   --profile=desktop    Skips laptop-only tweaks (iwd backend patch,
#                        ignore-power-button.sh). Intel laptop scripts that
#                        self-gate on battery/CPU are left in place.
#   -h, --help           Show this message and exit.

DRY_RUN=0
PROFILE="laptop"

usage() {
    sed -n '1,/^DRY_RUN=0/p' "$0" | sed '$d' | sed -n '/^# Options:/,/^$/p'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)        DRY_RUN=1; shift ;;
        --profile=*)      PROFILE="${1#*=}"; shift ;;
        --profile)        PROFILE="${2:-}"; shift 2 ;;
        -h|--help)        usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
    esac
done

if [[ "$PROFILE" != "laptop" && "$PROFILE" != "desktop" ]]; then
    echo "Invalid --profile=$PROFILE (must be 'laptop' or 'desktop')." >&2
    exit 1
fi

echo "================================================================"
echo " profile = $PROFILE"
echo " dry-run = $DRY_RUN"
echo "================================================================"

# Run command live, or just print it in dry-run mode.
# Use ONLY for self-contained simple commands. For blocks with redirects or
# heredocs, gate them with `if (( ! DRY_RUN )); then ... fi`.
live() {
    if (( DRY_RUN )); then
        printf '[DRY-RUN] '
        printf '%q ' "$@"
        printf '\n'
        return 0
    fi
    "$@"
}

# Check if git is installed
if ! command -v git &> /dev/null; then
    echo "Error: git is not installed. Please install git before running this script."
    exit 1
fi

# Clone omarchy from repo (idempotent — script keeps going if dir exists)
echo "Clone Omarchy from repo..."
if ! git clone https://www.github.com/basecamp/omarchy ../omarchy; then
    echo "Error: Failed to clone Omarchy repo (continuing if already cloned)."
fi

echo "Successfully extracted omarchy archive."

# Check if yay is installed
if ! command -v yay &> /dev/null; then
    echo "yay is not installed. Installing yay..."

    if (( ! DRY_RUN )); then
        sudo pacman -S --needed --noconfirm git base-devel
        git clone https://aur.archlinux.org/yay.git /tmp/yay
        cd /tmp/yay || { echo "Cannot cd /tmp/yay"; exit 1; }
        makepkg -si --noconfirm
        cd - >/dev/null || exit 1
        rm -rf /tmp/yay

        if ! command -v yay &> /dev/null; then
            echo "Error: Failed to install yay."
            exit 1
        fi
        echo "yay has been successfully installed."
    else
        echo "[DRY-RUN] would install yay via base-devel + makepkg"
    fi
else
    echo "yay is already installed."
fi

# Receive + locally sign the Omarchy signing key
live sudo pacman-key --recv-keys F0134EE680CAC571
live sudo pacman-key --lsign-key F0134EE680CAC571

# Add omarchy repository to pacman.conf (skip if already present)
if ! grep -q '^\[omarchy\]' /etc/pacman.conf; then
    if (( ! DRY_RUN )); then
        echo -e "\n[omarchy]\nSigLevel = Optional TrustedOnly\nServer = https://pkgs.omarchy.org/\$arch" \
            | sudo tee -a /etc/pacman.conf > /dev/null
    else
        echo "[DRY-RUN] would append [omarchy] repo block to /etc/pacman.conf"
    fi
else
    echo "Omarchy repository already present in pacman.conf, skipping."
fi

# Refresh keyrings and mirror rankings before the big sync. CachyOS mirrors can
# fall behind on freshly published package revisions; running the rate-mirrors
# script and refreshing keyrings up front avoids "failed retrieving file" errors
# mid-install (e.g. thermald, dbus-glib).
echo ""
echo "Refreshing keyrings and CachyOS mirror rankings..."
if (( ! DRY_RUN )); then
    sudo pacman -Sy --needed --noconfirm archlinux-keyring cachyos-keyring \
        || echo "WARN: keyring refresh failed — continuing anyway."

    if command -v cachyos-rate-mirrors &>/dev/null; then
        sudo cachyos-rate-mirrors || echo "WARN: cachyos-rate-mirrors failed — continuing."
    fi

    if command -v reflector &>/dev/null; then
        sudo reflector --latest 15 --sort rate --protocol https \
            --save /etc/pacman.d/mirrorlist || echo "WARN: reflector failed — continuing."
    fi

    sudo pacman -Syyu --noconfirm
else
    echo "[DRY-RUN] would refresh keyrings, rerank mirrors, and run pacman -Syyu"
fi

# Remove CachyOS SDDM config
if [ -f /etc/sddm.conf ]; then
    echo "Removing /etc/sddm.conf"
    live sudo rm /etc/sddm.conf
fi

# Prompt user for username
echo ""
echo "Please enter your username:"
read -r OMARCHY_USER_NAME
export OMARCHY_USER_NAME

# Prompt user for email address
echo ""
echo "Please enter your email address:"
read -r OMARCHY_USER_EMAIL
export OMARCHY_USER_EMAIL

# Make adjustments to Omarchy install scripts to support CachyOS
echo ""
echo "Making adjustments to Omarchy install scripts to support CachyOS..."

# Navigate to Omarchy install scripts
cd ../omarchy || { echo "Error: ../omarchy directory missing — clone likely failed."; exit 1; }

# Remove tldr installation to prevent conflict with tealdeer install.
sed -i '/tldr/d' install/omarchy-base.packages

# Update restart-needed for kernel updates to use cachyos instead of arch
sed -i "s/ | sed 's\/-arch\/\\\.arch\/'//" bin/omarchy-update-restart
sed -i "s/'{print \$2}'/'{print \$2 \"-\" \$1}' | sed 's\/-linux\/\/'/" bin/omarchy-update-restart
sed -i '/linux-cachyos/ ! s/pacman -Q linux/pacman -Q linux-cachyos/' bin/omarchy-update-restart

# Remove pacman.sh from preflight/all.sh to prevent conflict with cachyos packages
sed -i '/run_logged \$OMARCHY_INSTALL\/preflight\/pacman\.sh/d' install/preflight/all.sh

# Replace nvidia.sh with custom CachyOS 580xx Driver Logic
cp ../bin/nvidia.sh install/config/hardware/nvidia.sh
chmod +x install/config/hardware/nvidia.sh

# Fix omarchy-ai-skill.sh symlink to be idempotent on re-runs
sed -i 's/ln -s/ln -sf/' install/config/omarchy-ai-skill.sh

# Remove plymouth.sh source line from install.sh
sed -i '/run_logged \$OMARCHY_INSTALL\/login\/plymouth\.sh/d' install/login/all.sh

# Remove limine-snapper.sh source line from install.sh
sed -i '/run_logged \$OMARCHY_INSTALL\/login\/limine-snapper\.sh/d' install/login/all.sh

# Remove alt-bootloaders.sh source line from install.sh
sed -i '/run_logged \$OMARCHY_INSTALL\/login\/alt-bootloaders\.sh/d' install/login/all.sh

# Remove pacman.sh from post-install/all.sh to prevent conflict with cachyos packages
sed -i '/run_logged \$OMARCHY_INSTALL\/post-install\/pacman\.sh/d' install/post-install/all.sh

# Skip Intel thermald.sh on CachyOS. CachyOS ships its own thermal management
# (power-profiles-daemon / cachyos-settings), so installing thermald is
# redundant and the script fails on `omarchy-pkg-add thermald` or
# `systemctl enable thermald` on some Alder Lake+ ThinkPads.
sed -i '/run_logged \$OMARCHY_INSTALL\/config\/hardware\/intel\/thermald\.sh/d' install/config/all.sh

# ---------------------------------------------------------------------------
# Profile-specific tweaks
# ---------------------------------------------------------------------------
if [[ "$PROFILE" == "laptop" ]]; then
    # Disable wpa_supplicant and configure NetworkManager to use iwd backend.
    # CachyOS enables wpa_supplicant by default, which conflicts with omarchy's iwd,
    # causing WiFi to appear connected but have no IP or connectivity.
    cat >> install/config/hardware/network.sh << 'NETEOF'

# Disable wpa_supplicant to prevent conflict with iwd
sudo systemctl disable --now wpa_supplicant.service 2>/dev/null

# Configure NetworkManager to use iwd as its WiFi backend
if ! grep -q "wifi.backend=iwd" /etc/NetworkManager/NetworkManager.conf 2>/dev/null; then
  sudo tee -a /etc/NetworkManager/NetworkManager.conf > /dev/null << EOF

[device]
wifi.backend=iwd
EOF
fi
NETEOF
fi

if [[ "$PROFILE" == "desktop" ]]; then
    # On desktops the power button should still power off the machine. Omarchy's
    # ignore-power-button.sh masks that handler for laptop use. Remove the
    # run_logged invocation so the handler stays default.
    sed -i '/run_logged \$OMARCHY_INSTALL\/config\/hardware\/ignore-power-button\.sh/d' install/config/all.sh
fi

# Pin walker to the omarchy repo so CachyOS doesn't override it with an
# incompatible version that breaks compatibility with elephant.
sed -i '1a\
# Pin walker to omarchy repo to prevent CachyOS version conflict\
if ! grep -q "^IgnorePkg.*walker" /etc/pacman.conf 2>/dev/null; then\
  if grep -q "^IgnorePkg" /etc/pacman.conf; then\
    sudo sed -i '"'"'s/^IgnorePkg = \\(.*\\)/IgnorePkg = \\1 walker/'"'"' /etc/pacman.conf\
  else\
    sudo sed -i '"'"'/^\\[options\\]/a IgnorePkg = walker'"'"' /etc/pacman.conf\
  fi\
fi\
' install/config/walker-elephant.sh

# Update mise activation to support both bash and fish
sed -i 's/omarchy-cmd-present mise && eval "\$(mise activate bash)"/if [ "\$SHELL" = "\/bin\/bash" ] \&\& command -v mise \&> \/dev\/null; then\n  eval "\$(mise activate bash)"\nelif [ "\$SHELL" = "\/bin\/fish" ] \&\& command -v mise \&> \/dev\/null; then\n  mise activate fish | source\nfi/' config/uwsm/env

# Copy omarchy installation files to ~/.local/share/omarchy
mkdir -p ~/.local/share/omarchy
cp -r . ~/.local/share/omarchy
cd ~/.local/share/omarchy || { echo "Cannot cd into ~/.local/share/omarchy"; exit 1; }

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "The following adjustments have been completed (profile=$PROFILE)."
echo " 1. Added Omarchy repo to pacman.conf"
echo " 2. Removed tldr from packages.sh to avoid conflict with tealdeer on CachyOS."
echo " 3. Disabled further Omarchy changes to pacman.conf, preserving CachyOS settings."
echo " 4. Replaced nvidia.sh with custom CachyOS 580xx Driver Logic."
echo " 5. Removed plymouth.sh from install.sh to avoid conflict with CachyOS login display manager installation."
echo " 6. Removed limine-snapper.sh from install.sh to avoid conflict with CachyOS boot loader installation."
echo " 7. Removed alt-bootloaders.sh from install.sh to avoid conflict with CachyOS boot loader installation."
echo " 8. Removed /etc/sddm.conf to avoid conflict with Omarchy UWSM session autologin."
if [[ "$PROFILE" == "laptop" ]]; then
    echo " 9. Disabled wpa_supplicant and configured NetworkManager to use iwd backend."
fi
echo "10. Pinned walker to omarchy repo to prevent CachyOS version conflict."
echo "11. Skipped Intel thermald.sh (redundant with CachyOS thermal management)."
if [[ "$PROFILE" == "desktop" ]]; then
    echo "12. Desktop profile: skipped ignore-power-button.sh and laptop wifi backend tweaks."
fi
echo ""
echo "IMPORTANT: If you installed CachyOS without a deskop environment, you will not have a display manager installed."
echo "If this is the case, you will need to run the following command after this installation script is complete:"
echo " 1.) ~/.local/share/omarchy/install/login/plymouth.sh"
echo ""
echo "The aboves script will modify your boot to start Omarchy's Hyprland desktop automatically."
echo ""

if (( DRY_RUN )); then
    echo "================================================================"
    echo " DRY-RUN complete. All patches applied to ~/.local/share/omarchy."
    echo " Omarchy's own install.sh was NOT executed."
    echo " To proceed for real, re-run this script without --dry-run."
    echo "================================================================"
    exit 0
fi

echo "Press Enter to begin the installation of Omarchy..."
read -r

# Run the modified install.sh script
chmod +x install.sh
./install.sh
