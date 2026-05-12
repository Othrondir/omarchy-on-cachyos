# omarchy-on-cachyos

Hardened wrapper that installs DHH's [Omarchy](https://github.com/basecamp/omarchy)
on top of a fresh CachyOS install, with extra fixes for NVIDIA hardware,
CachyOS mirror staleness, and laptop/desktop profile differences.

This fork extends the upstream wrapper with:

- `nvidia.sh` that handles chwd version drift and Turing+ NVIDIA GPUs
  (verified on ThinkPad P14s Gen 3 with T550, RTX 40-series desktop).
- Up-front keyring + mirror refresh to avoid mid-install `failed retrieving
  file` errors from out-of-date CachyOS mirrors.
- Skip of Intel `thermald.sh` (CachyOS already manages thermals).
- `--profile=desktop` flag that drops laptop-only tweaks.
- `--dry-run` flag for safe verification before touching the system.
- `bin/resume-install.sh` for recovering from a failed/interrupted install.
- `bin/omarchy-bg-spread.sh` to push custom wallpapers across all Omarchy themes.

---

## 1. Prerequisites

Install CachyOS first with these choices (do **not** install GNOME or KDE):

| Setting | Value |
|---|---|
| File system | BTRFS + Snapper |
| Default shell | Fish |
| Desktop environment | Minimal **or** CachyOS Hyprland |
| NVIDIA drivers | Leave the installer's default — the wrapper handles them |

CachyOS install guide: https://wiki.cachyos.org/installation/installation/

---

## 2. Clone

```bash
sudo pacman -S --needed git
git clone https://github.com/Othrondir/omarchy-on-cachyos.git
cd omarchy-on-cachyos/bin
chmod +x install-omarchy-on-cachyos.sh resume-install.sh omarchy-bg-spread.sh
```

---

## 3. Run

**Laptop (default):**

```bash
./install-omarchy-on-cachyos.sh
```

**Desktop — see section 4 below:**

```bash
./install-omarchy-on-cachyos.sh --profile=desktop
```

**Dry-run first (no system changes — recommended on new hardware):**

```bash
./install-omarchy-on-cachyos.sh --dry-run --profile=desktop
```

The script will:

1. Refresh CachyOS keyrings, rerank mirrors, force `pacman -Syyu`.
2. Clone Omarchy upstream into `../omarchy`.
3. Patch its install scripts for CachyOS (nvidia, thermald skip, network, etc.).
4. Copy the patched tree to `~/.local/share/omarchy`.
5. Prompt for username/email, then run Omarchy's `install.sh`.

Reboot when it finishes.

### If install fails mid-way

```bash
./resume-install.sh
```

Refreshes mirrors again, then offers **resume** (re-run Omarchy's `install.sh`
in place with patches re-applied) or **clean** (wipe `../omarchy` and
`~/.local/share/omarchy`, re-run the full wrapper).

---

## 4. Desktop profile (`--profile=desktop`)

Use on **desktop builds** (wired ethernet, no battery, NVIDIA dGPU).
Verified target: Intel/AMD desktop + RTX 40-series.

**What the flag changes:**

| Tweak | laptop (default) | desktop |
|---|---|---|
| NVIDIA 580xx proprietary driver + chwd ID patch | applied | applied |
| Intel `thermald.sh` skip | applied | applied |
| `wpa_supplicant` disable + NetworkManager iwd backend | **applied** | **skipped** (wired ethernet) |
| `ignore-power-button.sh` | **applied** | **skipped** (power button keeps working) |
| Intel laptop scripts (`lpmd`, `ipu7-camera`, `ptl-kernel`, `fix-wifi7-eht`) | self-gate | self-gate |

**Why a separate profile:**

- Desktop has no WiFi → forcing NetworkManager to the iwd backend is pointless
  noise and can confuse network troubleshooting.
- Desktop users expect the power button on the case to power off the machine;
  Omarchy's `ignore-power-button.sh` masks that handler for laptop lid use.

**NVIDIA on RTX 40-series:**

The 4090 (`10de:2684`) is supported by NVIDIA 580.xx upstream but is **not**
in CachyOS's `nvidia-580.ids` file (which stops at Pascal). Our patched
`bin/nvidia.sh` auto-detects the GPU ID via `lspci`, patches the chwd ID
list, and explicitly installs the `nvidia-dkms-580xx` profile instead of
relying on `chwd -a` (which can pick the open driver via its wildcard
match). Falls back to `pacman -S nvidia-580xx-dkms` if chwd fails.

---

## 5. Custom wallpapers across all themes

Omarchy gates wallpapers per theme. To make wallpapers from `~/Pictures`
selectable from every theme:

```bash
./bin/omarchy-bg-spread.sh                  # uses ~/Pictures
./bin/omarchy-bg-spread.sh /other/folder    # custom source
./bin/omarchy-bg-spread.sh --clean          # remove what this script added
```

Then pick via `SUPER + Ctrl + Space` or cycle with `omarchy-theme-bg-next`.

---

## 6. Keyboard shortcuts (Omarchy / Hyprland defaults)

`SUPER` = Windows / Meta key. Press `SUPER + K` in-session for the full
searchable list.

### Apps

| Action | Binding |
|---|---|
| Terminal | `SUPER + Enter` |
| Browser | `SUPER + Shift + Enter` (or `SUPER + Shift + B`) |
| Browser (private) | `SUPER + Shift + Alt + B` |
| File manager (Nautilus) | `SUPER + Shift + F` |
| Editor (nvim) | `SUPER + Shift + N` |
| App launcher (walker) | `SUPER + Space` |
| Omarchy menu | `SUPER + Alt + Space` |
| System menu (logout/reboot) | `SUPER + Esc` |
| Lock screen | `SUPER + Ctrl + L` |
| Show keybindings | `SUPER + K` |

### Window management

| Action | Binding |
|---|---|
| Close window | `SUPER + W` |
| Close ALL windows | `Ctrl + Alt + Del` |
| Fullscreen | `SUPER + F` |
| Tiled fullscreen | `SUPER + Ctrl + F` |
| Full width | `SUPER + Alt + F` |
| Toggle floating | `SUPER + T` |
| Pop out (float + pin) | `SUPER + O` |
| Move focus | `SUPER + Arrows` |
| Swap window position | `SUPER + Shift + Arrows` |
| Move window (drag) | `SUPER + Left-click` |
| Resize window (drag) | `SUPER + Right-click` |
| Scratchpad | `SUPER + S` |

### Workspaces

| Action | Binding |
|---|---|
| Switch to workspace 1–10 | `SUPER + 1..0` |
| Move window to workspace 1–10 | `SUPER + Shift + 1..0` |
| Next / previous workspace | `SUPER + Tab` / `SUPER + Shift + Tab` |
| Cycle windows on workspace | `Alt + Tab` |

### Theming

| Action | Binding |
|---|---|
| Theme background menu | `SUPER + Ctrl + Space` |
| Theme menu | `SUPER + Shift + Ctrl + Space` |
| Toggle top bar | `SUPER + Shift + Space` |
| Toggle window transparency | `SUPER + Backspace` |

### Captures

| Action | Binding |
|---|---|
| Screenshot | `Print` |
| Screen recording | `Alt + Print` |
| Color picker | `SUPER + Print` |
| OCR from screenshot | `SUPER + Ctrl + Print` |

---

## 7. Disclaimer

Software provided "as is", no warranty. Use at your own risk. Back up first.
Original wrapper by [@mroboff](https://github.com/mroboff); this fork adds the
fixes described above.
