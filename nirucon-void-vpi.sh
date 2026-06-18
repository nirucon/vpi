#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# =============================================================================
# NIRUCON Void Linux VPI v1.2.0 - Void Post Install for glibc base systems
# =============================================================================
#
# Target:
#   Void Linux glibc base install, x86_64, runit, XBPS
#
# Purpose:
#   Build a clean, minimal dwm/X11 desktop with SDDM, NIRU Noir terminal profile,
#   normal desktop audio playback through PipeWire, Bluetooth/storage helpers,
#   and practical desktop tools. This is intentionally NOT a DAW/studio script.
#
# What it does:
#   - Updates Void safely with XBPS
#   - Enables useful repositories when available
#   - Installs Xorg, SDDM, NetworkManager, PipeWire, fish, kitty and desktop tools
#   - Builds dwm, dmenu, st and slock from your suckless repository
#   - Installs your look-and-feel repo and NIRU Noir terminal/fish/starship setup
#   - Creates a clean dwm SDDM session and startx fallback
#   - Enables runit services correctly
#   - Configures Swedish keyboard, glibc locales and normal audio playback
#
# What it intentionally does NOT do:
#   - No REAPER/studio tuning
#   - No JACK/qjackctl realtime setup
#   - No Wine/yabridge/Toontrack/NAM stack
#   - No systemd assumptions
#
# Run:
#   chmod +x nirucon-void-vpi.sh
#   ./nirucon-void-vpi.sh
#
# Important:
#   Run as your normal user with sudo rights, not as root.
#
# =============================================================================

# -----------------------------------------------------------------------------
# Repositories
# -----------------------------------------------------------------------------

SUCKLESS_REPO="https://github.com/nirucon/suckless.git"
LOOKANDFEEL_REPO="https://github.com/nirucon/suckless_lookandfeel.git"
SDDM_THEME_REPO="https://github.com/nirucon/nirucon-sddm.git"
SDDM_THEME_ID="niru-noir"

# -----------------------------------------------------------------------------
# Paths
# -----------------------------------------------------------------------------

CACHE_DIR="$HOME/.cache/nirucon-vpi"
SUCKLESS_DIR="$HOME/.config/suckless"
LOOKANDFEEL_DIR="$CACHE_DIR/lookandfeel"
SDDM_THEME_CACHE="$CACHE_DIR/sddm-theme"

LOCAL_BIN="$HOME/.local/bin"
LOCAL_SHARE="$HOME/.local/share"
XINITRC_DIR="$HOME/.config/xinitrc.d"

SESSION_WRAPPER="/usr/local/bin/dwm-session"
SESSION_DESKTOP="/usr/share/xsessions/dwm.desktop"

# -----------------------------------------------------------------------------
# Output helpers
# -----------------------------------------------------------------------------

NC="\033[0m"
BOLD="\033[1m"
GRN="\033[1;32m"
RED="\033[1;31m"
YLW="\033[1;33m"
BLU="\033[1;34m"
MAG="\033[1;35m"
CYN="\033[1;36m"
DIM="\033[2m"

say()   { printf "${BLU}[info]${NC} %s\n" "$*"; }
phase() { printf "\n${MAG}==>${NC} ${BOLD}%s${NC}\n" "$*"; }
ok()    { printf "${GRN}[ ok ]${NC} %s\n" "$*"; }
warn()  { printf "${YLW}[warn]${NC} %s\n" "$*"; }
fail()  { printf "${RED}[fail]${NC} %s\n" "$*" >&2; }
note()  { printf "${CYN}[note]${NC} %s\n" "$*"; }
muted() { printf "${DIM}%s${NC}\n" "$*"; }

trap 'fail "Aborted at line $LINENO while running: ${BASH_COMMAND:-unknown}"' ERR

# -----------------------------------------------------------------------------
# Basic helpers
# -----------------------------------------------------------------------------

ask_yes_no() {
  local prompt="$1"
  local default="${2:-N}"
  local answer

  if [[ "$default" == "Y" ]]; then
    read -r -p "$prompt [Y/n] " answer
    [[ -z "$answer" || "$answer" =~ ^[Yy]$ ]]
  else
    read -r -p "$prompt [y/N] " answer
    [[ "$answer" =~ ^[Yy]$ ]]
  fi
}

backup_file() {
  local file="$1"
  if [[ -f "$file" ]]; then
    sudo cp -a "$file" "$file.bak.$(date +%Y%m%d-%H%M%S)"
  fi
}

backup_user_file() {
  local file="$1"
  if [[ -f "$file" ]]; then
    cp -a "$file" "$file.bak.$(date +%Y%m%d-%H%M%S)"
  fi
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

pkg_installed() {
  xbps-query -Rs "^$1$" >/dev/null 2>&1 || xbps-query -s "$1" >/dev/null 2>&1
}

install_pkg_list() {
  # Install packages one by one. This is slower than a single transaction, but it
  # makes the script resilient when a package name differs or is unavailable on a
  # specific Void snapshot/repository set.
  local pkg
  local -a missing=()

  for pkg in "$@"; do
    if xbps-query -p pkgver "$pkg" >/dev/null 2>&1; then
      muted "already installed: $pkg"
      continue
    fi

    say "Installing package: $pkg"
    if ! sudo xbps-install -Sy "$pkg"; then
      warn "Package unavailable or failed: $pkg"
      missing+=("$pkg")
    fi
  done

  if (( ${#missing[@]} > 0 )); then
    warn "Some packages were skipped. The script will continue. Skipped: ${missing[*]}"
  fi
}

enable_service() {
  # Void/runit service enablement. Symlinking /etc/sv/name to /var/service starts
  # the service automatically and enables it for future boots.
  local svc="$1"

  if [[ ! -d "/etc/sv/$svc" ]]; then
    warn "Service not found: /etc/sv/$svc"
    return 0
  fi

  if [[ ! -e "/var/service/$svc" ]]; then
    sudo ln -s "/etc/sv/$svc" "/var/service/$svc"
    ok "Service enabled: $svc"
  else
    ok "Service already enabled: $svc"
  fi

  # Bring the service up now when possible. This is safe if it is already running.
  sudo sv up "$svc" >/dev/null 2>&1 || warn "Service could not be started now: $svc"
}

disable_service() {
  # Disable a runit service without deleting the service definition in /etc/sv.
  local svc="$1"

  if [[ -e "/var/service/$svc" ]]; then
    sudo sv down "$svc" >/dev/null 2>&1 || true
    sudo rm -f "/var/service/$svc"
    ok "Service disabled: $svc"
  else
    ok "Service already disabled: $svc"
  fi
}

service_enabled() {
  [[ -e "/var/service/$1" ]]
}

service_running() {
  sv status "$1" 2>/dev/null | grep -q '^run:'
}

print_header() {
  clear || true
  echo
  echo "============================================================"
  echo "  NIRUCON Void Linux VPI"
  echo "  Void Post Install for glibc base + dwm"
  echo "============================================================"
  echo
  echo "This script installs:"
  echo "  - dwm, dmenu, st and slock from your suckless repo"
  echo "  - Xorg and SDDM"
  echo "  - network services using a safe selectable backend"
  echo "  - PipeWire desktop audio for music/video playback"
  echo "  - fish, kitty, starship, zoxide and NIRU Noir config"
  echo "  - common desktop tools, fonts and media applications"
  echo
  echo "It does not install DAW/studio, Wine, yabridge or JACK tuning."
  echo
}

# -----------------------------------------------------------------------------
# Safety checks
# -----------------------------------------------------------------------------

[[ "$EUID" -ne 0 ]] || {
  fail "Run this script as your normal user, not as root."
  exit 1
}

have_cmd sudo || {
  fail "sudo is missing. Install sudo and add your user to the wheel group first."
  echo
  echo "As root, usually:"
  echo "  xbps-install -S sudo"
  echo "  usermod -aG wheel $USER"
  echo "  visudo"
  echo
  exit 1
}

have_cmd xbps-install || {
  fail "xbps-install was not found. This does not look like Void Linux."
  exit 1
}

if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  if [[ "${ID:-}" != "void" ]]; then
    warn "This does not report itself as Void Linux. Continuing anyway."
  fi
fi

if ldd --version 2>&1 | grep -qi musl; then
  fail "This looks like a musl system. This VPI is intended for Void glibc."
  exit 1
fi

if ! ldd --version 2>&1 | grep -qi 'glibc\|GNU libc'; then
  warn "Could not clearly verify glibc from ldd output. Continuing, but check your Void variant."
fi

sudo -v

# Keep sudo alive while the script runs.
while true; do sudo -n true; sleep 60; kill -0 "$$" 2>/dev/null || exit; done 2>/dev/null &
SUDO_KEEPALIVE_PID=$!
trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true; fail "Aborted at line $LINENO while running: ${BASH_COMMAND:-unknown}"' ERR
trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT

# -----------------------------------------------------------------------------
# User choices
# -----------------------------------------------------------------------------

print_header

echo "Select machine type:"
echo "  1) Laptop"
echo "  2) Workstation / desktop"
echo
read -r -p "Choice [1/2, default 1]: " MACHINE_CHOICE
MACHINE_CHOICE="${MACHINE_CHOICE:-1}"

IS_LAPTOP=0
IS_WORKSTATION=0
case "$MACHINE_CHOICE" in
  1) IS_LAPTOP=1 ;;
  2) IS_WORKSTATION=1 ;;
  *) fail "Invalid machine choice."; exit 1 ;;
esac

INSTALL_NONFREE=1
INSTALL_BLUETOOTH=1
INSTALL_CUPS=0
INSTALL_SSH=0
INSTALL_FLATPAK=1
SET_FISH_DEFAULT=0
PATCH_STATUSBAR=1
INSTALL_MEDIA_APPS=1
INSTALL_NEXTCLOUD=1
INSTALL_TAILSCALE=0
INSTALL_HELIUM=1
NETWORK_BACKEND="preserve"

# Network handling is intentionally conservative. Fresh Void installs often use
# dhcpcd + wpa_supplicant, while desktop installs often use NetworkManager. Running
# both at the same time can cause changing IP addresses and dropped SSH sessions.
echo
echo "Select network backend:"
echo "  1) Preserve current active network services (safest, default)"
echo "  2) NetworkManager only (recommended for laptops after local access is confirmed)"
echo "  3) Classic Void: dhcpcd + wpa_supplicant only"
echo
read -r -p "Network choice [1/2/3, default 1]: " NETWORK_CHOICE
NETWORK_CHOICE="${NETWORK_CHOICE:-1}"
case "$NETWORK_CHOICE" in
  1) NETWORK_BACKEND="preserve" ;;
  2) NETWORK_BACKEND="networkmanager" ;;
  3) NETWORK_BACKEND="classic" ;;
  *) fail "Invalid network choice."; exit 1 ;;
esac

ask_yes_no "Enable/install Void nonfree repository packages if available?" "Y" && INSTALL_NONFREE=1 || INSTALL_NONFREE=0
ask_yes_no "Install Bluetooth support?" "Y" && INSTALL_BLUETOOTH=1 || INSTALL_BLUETOOTH=0
ask_yes_no "Install printer support with CUPS?" "N" && INSTALL_CUPS=1 || INSTALL_CUPS=0
ask_yes_no "Install OpenSSH server?" "N" && INSTALL_SSH=1 || INSTALL_SSH=0
ask_yes_no "Install Flatpak support?" "Y" && INSTALL_FLATPAK=1 || INSTALL_FLATPAK=0
ask_yes_no "Install media/music applications?" "Y" && INSTALL_MEDIA_APPS=1 || INSTALL_MEDIA_APPS=0
ask_yes_no "Install Nextcloud desktop client if available?" "Y" && INSTALL_NEXTCLOUD=1 || INSTALL_NEXTCLOUD=0
ask_yes_no "Install Tailscale if available?" "N" && INSTALL_TAILSCALE=1 || INSTALL_TAILSCALE=0
ask_yes_no "Install Helium Browser AppImage?" "Y" && INSTALL_HELIUM=1 || INSTALL_HELIUM=0
ask_yes_no "Set fish as default shell for $USER?" "N" && SET_FISH_DEFAULT=1 || SET_FISH_DEFAULT=0
ask_yes_no "Patch dwm-status.sh for Void/XBPS?" "Y" && PATCH_STATUSBAR=1 || PATCH_STATUSBAR=0

echo
phase "Selected configuration"
[[ "$IS_LAPTOP" -eq 1 ]] && echo "Machine type:      Laptop" || echo "Machine type:      Workstation"
echo "Network backend:   $NETWORK_BACKEND"
echo "Nonfree repo:      $([[ "$INSTALL_NONFREE" -eq 1 ]] && echo yes || echo no)"
echo "Bluetooth:         $([[ "$INSTALL_BLUETOOTH" -eq 1 ]] && echo yes || echo no)"
echo "CUPS printer:      $([[ "$INSTALL_CUPS" -eq 1 ]] && echo yes || echo no)"
echo "OpenSSH server:    $([[ "$INSTALL_SSH" -eq 1 ]] && echo yes || echo no)"
echo "Flatpak:           $([[ "$INSTALL_FLATPAK" -eq 1 ]] && echo yes || echo no)"
echo "Media apps:        $([[ "$INSTALL_MEDIA_APPS" -eq 1 ]] && echo yes || echo no)"
echo "Nextcloud:         $([[ "$INSTALL_NEXTCLOUD" -eq 1 ]] && echo yes || echo no)"
echo "Tailscale:         $([[ "$INSTALL_TAILSCALE" -eq 1 ]] && echo yes || echo no)"
echo "Helium AppImage:   $([[ "$INSTALL_HELIUM" -eq 1 ]] && echo yes || echo no)"
echo "fish default:      $([[ "$SET_FISH_DEFAULT" -eq 1 ]] && echo yes || echo no)"
echo "Patch statusbar:   $([[ "$PATCH_STATUSBAR" -eq 1 ]] && echo yes || echo no)"
echo

ask_yes_no "Continue with installation?" "Y" || {
  warn "Installation cancelled."
  exit 0
}

# -----------------------------------------------------------------------------
# XBPS update and repositories
# -----------------------------------------------------------------------------

phase "Updating Void Linux"

say "Refreshing repositories and updating system packages..."
sudo xbps-install -Syu || {
  warn "First update pass returned non-zero. Running xbps-install -Syu once more."
  sudo xbps-install -Syu
}

if [[ "$INSTALL_NONFREE" -eq 1 ]]; then
  phase "Installing optional repository packages"
  install_pkg_list void-repo-nonfree void-repo-multilib void-repo-multilib-nonfree
  sudo xbps-install -S || true
fi

# -----------------------------------------------------------------------------
# Base packages
# -----------------------------------------------------------------------------

phase "Installing core base packages"

CORE_PACKAGES=(
  base-devel gcc make pkg-config git curl wget rsync unzip zip tar tree
  findutils coreutils grep sed gawk diffutils file which shadow
  xdg-utils xdg-user-dirs dbus elogind polkit lxsession
  ca-certificates gnupg lsb-release
  socklog-void chrony
)

install_pkg_list "${CORE_PACKAGES[@]}"

# -----------------------------------------------------------------------------
# X11, SDDM and dwm build dependencies
# -----------------------------------------------------------------------------

phase "Installing X11, SDDM and dwm build dependencies"

DESKTOP_PACKAGES=(
  xorg xinit xauth xsetroot xrandr xrdb xclip xsel xprop xwininfo
  setxkbmap xkeyboard-config
  sddm
  NetworkManager network-manager-applet dhcpcd wpa_supplicant
  libX11-devel libXft-devel libXinerama-devel libXrandr-devel libXext-devel
  libXrender-devel libXfixes-devel harfbuzz-devel imlib2-devel freetype-devel fontconfig-devel
  fontconfig dejavu-fonts-ttf noto-fonts-ttf noto-fonts-emoji font-awesome
  feh picom rofi dunst libnotify
  kitty alacritty fish starship zoxide
  maim slop scrot flameshot brightnessctl playerctl pamixer pavucontrol
  pcmanfm gvfs udisks2 udiskie
  fastfetch btop htop ncdu duf jq fzf ripgrep fd eza bat pv sshfs ntfs-3g
  lm_sensors smartmontools pciutils usbutils
  neovim vim micro
  lxappearance papirus-icon-theme adwaita-icon-theme p7zip
  fuse fuse3
)

install_pkg_list "${DESKTOP_PACKAGES[@]}"

# -----------------------------------------------------------------------------
# Desktop audio playback
# -----------------------------------------------------------------------------

phase "Installing normal desktop audio playback"

AUDIO_PACKAGES=(
  pipewire wireplumber pipewire-pulse alsa-utils alsa-plugins
)

install_pkg_list "${AUDIO_PACKAGES[@]}"

say "Adding $USER to audio/video/input groups where present..."
for grp in audio video input plugdev wheel; do
  if getent group "$grp" >/dev/null 2>&1; then
    sudo usermod -aG "$grp" "$USER" || true
  fi
done

# -----------------------------------------------------------------------------
# Optional packages
# -----------------------------------------------------------------------------

if [[ "$INSTALL_BLUETOOTH" -eq 1 ]]; then
  phase "Installing Bluetooth support"
  install_pkg_list bluez blueman libspa-bluetooth
fi

if [[ "$INSTALL_CUPS" -eq 1 ]]; then
  phase "Installing CUPS printer support"
  install_pkg_list cups cups-filters gutenprint system-config-printer
  if getent group lpadmin >/dev/null 2>&1; then
    sudo usermod -aG lpadmin "$USER" || true
  fi
fi

if [[ "$INSTALL_SSH" -eq 1 ]]; then
  phase "Installing OpenSSH server"
  install_pkg_list openssh
fi

if [[ "$INSTALL_FLATPAK" -eq 1 ]]; then
  phase "Installing Flatpak support"
  install_pkg_list flatpak xdg-desktop-portal xdg-desktop-portal-gtk
  if have_cmd flatpak; then
    flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo || true
  fi
fi

if [[ "$INSTALL_MEDIA_APPS" -eq 1 ]]; then
  phase "Installing media/music applications"
  install_pkg_list mpv vlc cmus ffmpeg ffmpegthumbnailer sxiv imv gimp ImageMagick mediainfo
  # kew may not exist in all Void repositories. It is optional.
  install_pkg_list kew
fi

if [[ "$INSTALL_NEXTCLOUD" -eq 1 ]]; then
  phase "Installing Nextcloud desktop client if available"
  install_pkg_list nextcloud-client nextcloud-desktop
fi

if [[ "$INSTALL_TAILSCALE" -eq 1 ]]; then
  phase "Installing Tailscale if available"
  install_pkg_list tailscale
fi

install_helium_appimage() {
  phase "Installing Helium Browser AppImage"

  # Helium is not packaged in the official Void repositories. The safest Void
  # route is the upstream AppImage from imputnet/helium-linux releases.
  # This function is intentionally user-local: it does not place untracked files
  # in /usr/bin and it can be re-run to update Helium.
  local app_dir="$HOME/.local/bin"
  local app_path="$app_dir/helium"
  local desktop_dir="$HOME/.local/share/applications"
  local desktop_file="$desktop_dir/helium.desktop"
  local tmp_dir api_json url

  mkdir -p "$app_dir" "$desktop_dir"
  tmp_dir="$(mktemp -d)"

  # AppImages usually need FUSE/libfuse support. Install both package names
  # defensively because availability may vary by Void snapshot.
  install_pkg_list fuse fuse3

  say "Resolving latest Helium AppImage release from GitHub..."

  api_json="$tmp_dir/helium-release.json"
  if curl -fsSL "https://api.github.com/repos/imputnet/helium-linux/releases/latest" -o "$api_json"; then
    url="$(grep -E '"browser_download_url":' "$api_json" \
      | cut -d '"' -f4 \
      | grep -Ei 'helium.*x86_64.*\.AppImage$|helium.*\.AppImage$' \
      | head -n1 || true)"
  else
    url=""
  fi

  # Conservative fallback. If the project ever provides a stable latest asset
  # called helium.AppImage, this will work without the API parser.
  if [[ -z "${url:-}" ]]; then
    warn "Could not resolve AppImage through GitHub API. Trying stable latest/download fallback."
    url="https://github.com/imputnet/helium-linux/releases/latest/download/helium.AppImage"
  fi

  say "Downloading Helium AppImage: $url"
  if ! curl -fL --retry 3 --connect-timeout 20 -o "$tmp_dir/helium.AppImage" "$url"; then
    warn "Helium AppImage download failed. Leaving any existing local Helium installation untouched."
    rm -rf "$tmp_dir"
    return 0
  fi

  if [[ ! -s "$tmp_dir/helium.AppImage" ]]; then
    warn "Downloaded Helium AppImage is empty. Skipping installation."
    rm -rf "$tmp_dir"
    return 0
  fi

  chmod +x "$tmp_dir/helium.AppImage"

  # Keep a backup of the previous AppImage if present.
  if [[ -f "$app_path" ]]; then
    cp -a "$app_path" "$app_path.bak.$(date +%Y%m%d-%H%M%S)" || true
  fi

  mv "$tmp_dir/helium.AppImage" "$app_path"
  chmod +x "$app_path"

  cat > "$desktop_file" <<EOF
[Desktop Entry]
Name=Helium
Comment=Private Chromium-based browser
Exec=$app_path %U
Terminal=false
Type=Application
Categories=Network;WebBrowser;
MimeType=text/html;text/xml;application/xhtml+xml;x-scheme-handler/http;x-scheme-handler/https;
StartupNotify=true
EOF

  chmod 644 "$desktop_file"

  # Refresh desktop database when available. This is optional.
  if have_cmd update-desktop-database; then
    update-desktop-database "$desktop_dir" 2>/dev/null || true
  fi

  rm -rf "$tmp_dir"

  ok "Helium installed to $app_path"
  ok "Desktop launcher written to $desktop_file"
  note "Run Helium from rofi/dmenu with: helium"
}

if [[ "$INSTALL_HELIUM" -eq 1 ]]; then
  install_helium_appimage
fi

# -----------------------------------------------------------------------------
# Firmware and microcode
# -----------------------------------------------------------------------------

phase "Installing firmware and CPU microcode"

install_pkg_list linux-firmware

if lscpu 2>/dev/null | grep -qi intel; then
  install_pkg_list intel-ucode
elif lscpu 2>/dev/null | grep -qi amd; then
  install_pkg_list amd-ucode
else
  warn "Could not detect Intel or AMD CPU for microcode."
fi

# -----------------------------------------------------------------------------
# Locale, keyboard and user dirs
# -----------------------------------------------------------------------------

phase "Configuring locale and Swedish keyboard"

if [[ -f /etc/default/libc-locales ]]; then
  backup_file /etc/default/libc-locales
  sudo sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/default/libc-locales
  sudo sed -i 's/^# *sv_SE.UTF-8 UTF-8/sv_SE.UTF-8 UTF-8/' /etc/default/libc-locales
  sudo xbps-reconfigure -f glibc-locales || warn "glibc-locales reconfigure failed. Check /etc/default/libc-locales manually."
else
  warn "/etc/default/libc-locales not found. Is glibc-locales installed?"
  install_pkg_list glibc-locales
fi

sudo mkdir -p /etc/X11/xorg.conf.d
sudo tee /etc/X11/xorg.conf.d/00-keyboard.conf >/dev/null <<'KEYBOARD'
Section "InputClass"
    Identifier "system-keyboard"
    MatchIsKeyboard "on"
    Option "XkbLayout" "se"
EndSection
KEYBOARD

mkdir -p "$HOME/.config"
printf 'en_US\n' > "$HOME/.config/user-dirs.locale"
LANG=en_US.UTF-8 xdg-user-dirs-update --force 2>/dev/null || true

ok "Locale and keyboard phase completed."

# -----------------------------------------------------------------------------
# Machine profile tuning
# -----------------------------------------------------------------------------

phase "Applying simple machine profile tuning"

# Void base installations may not include /etc/sysctl.d by default.
# Create it before writing profile files.
sudo mkdir -p /etc/sysctl.d

if [[ "$IS_LAPTOP" -eq 1 ]]; then
  sudo tee /etc/sysctl.d/90-nirucon-vpi-laptop.conf >/dev/null <<'SYSCTL'
# NIRUCON VPI laptop profile.
vm.swappiness=20
fs.inotify.max_user_watches=524288
SYSCTL
  ok "Laptop sysctl profile written."
else
  sudo tee /etc/sysctl.d/90-nirucon-vpi-workstation.conf >/dev/null <<'SYSCTL'
# NIRUCON VPI workstation profile.
vm.swappiness=10
fs.inotify.max_user_watches=1048576
SYSCTL
  ok "Workstation sysctl profile written."
fi

sudo sysctl --system >/dev/null || true

# -----------------------------------------------------------------------------
# Services through runit
# -----------------------------------------------------------------------------

phase "Enabling runit services"

enable_service dbus
enable_service elogind
enable_service socklog-unix
enable_service nanoklogd
enable_service chronyd

phase "Configuring network services"
case "$NETWORK_BACKEND" in
  preserve)
    note "Preserving current network setup. No network service will be disabled."
    if service_enabled NetworkManager; then ok "NetworkManager is currently enabled."; fi
    if service_enabled dhcpcd; then ok "dhcpcd is currently enabled."; fi
    if service_enabled wpa_supplicant; then ok "wpa_supplicant is currently enabled."; fi
    warn "If both NetworkManager and dhcpcd/wpa_supplicant are enabled, choose one backend after local access is confirmed."
    ;;
  networkmanager)
    warn "Using NetworkManager only. Disabling dhcpcd and standalone wpa_supplicant to prevent IP changes and SSH drops."
    disable_service dhcpcd
    disable_service wpa_supplicant
    enable_service NetworkManager
    ;;
  classic)
    warn "Using classic Void networking. Disabling NetworkManager."
    disable_service NetworkManager
    enable_service wpa_supplicant
    enable_service dhcpcd
    ;;
esac

enable_service sddm

# PipeWire services may exist as system-level runit services on Void. If they are
# not present, the X session hook below will attempt user-level startup.
enable_service pipewire
enable_service pipewire-pulse
enable_service wireplumber

[[ "$INSTALL_BLUETOOTH" -eq 1 ]] && enable_service bluetoothd
[[ "$INSTALL_CUPS" -eq 1 ]] && enable_service cupsd
[[ "$INSTALL_SSH" -eq 1 ]] && enable_service sshd
[[ "$INSTALL_TAILSCALE" -eq 1 ]] && enable_service tailscaled

ok "Service phase completed."

# -----------------------------------------------------------------------------
# Clone and build suckless tools
# -----------------------------------------------------------------------------

phase "Cloning or updating suckless repository"

mkdir -p "$(dirname "$SUCKLESS_DIR")"

if [[ -d "$SUCKLESS_DIR/.git" ]]; then
  say "Updating existing suckless repository..."
  git -C "$SUCKLESS_DIR" fetch --all --prune
  git -C "$SUCKLESS_DIR" pull --ff-only || true
else
  say "Cloning suckless repository..."
  git clone "$SUCKLESS_REPO" "$SUCKLESS_DIR"
fi

phase "Applying Void slock group compatibility"

# Void normally has a 'nobody' group. Debian needed 'nogroup'. We gently restore
# the upstream-compatible setting when present.
for cfg in "$SUCKLESS_DIR/slock/config.h" "$SUCKLESS_DIR/slock/config.def.h"; do
  if [[ -f "$cfg" ]]; then
    if getent group nobody >/dev/null 2>&1; then
      sed -i 's/static const char \*group = "nogroup";/static const char *group = "nobody";/' "$cfg"
      sed -i 's/static const char \*group = "nobody";/static const char *group = "nobody";/' "$cfg"
      ok "Patched $cfg for group nobody"
    fi
  fi
done

phase "Building and installing dwm, dmenu, st and slock"

for app in dwm dmenu st slock; do
  if [[ -d "$SUCKLESS_DIR/$app" ]]; then
    say "Building $app..."
    make -C "$SUCKLESS_DIR/$app" clean || true
    make -C "$SUCKLESS_DIR/$app" -j"$(nproc)"
    sudo make -C "$SUCKLESS_DIR/$app" PREFIX=/usr/local install
    ok "$app installed."
  else
    warn "Missing component in suckless repo: $app"
  fi
done

# -----------------------------------------------------------------------------
# Look and feel
# -----------------------------------------------------------------------------

phase "Cloning or updating look and feel repository"

mkdir -p "$CACHE_DIR"

if [[ -d "$LOOKANDFEEL_DIR/.git" ]]; then
  say "Updating existing look and feel repository..."
  git -C "$LOOKANDFEEL_DIR" fetch --all --prune
  git -C "$LOOKANDFEEL_DIR" pull --ff-only || true
else
  say "Cloning look and feel repository..."
  git clone "$LOOKANDFEEL_REPO" "$LOOKANDFEEL_DIR"
fi

phase "Deploying look and feel files"

mkdir -p "$HOME/.config" "$LOCAL_BIN" "$LOCAL_SHARE"

[[ -d "$LOOKANDFEEL_DIR/config" ]] && rsync -a "$LOOKANDFEEL_DIR/config/" "$HOME/.config/"
[[ -d "$LOOKANDFEEL_DIR/local/bin" ]] && rsync -a "$LOOKANDFEEL_DIR/local/bin/" "$LOCAL_BIN/"
[[ -d "$LOOKANDFEEL_DIR/local/share" ]] && rsync -a "$LOOKANDFEEL_DIR/local/share/" "$LOCAL_SHARE/"

chmod +x "$LOCAL_BIN/"* 2>/dev/null || true

touch "$HOME/.profile"
grep -qxF 'export PATH="$HOME/.local/bin:$PATH"' "$HOME/.profile" || \
  echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.profile"

ok "Look and feel deployed."

# -----------------------------------------------------------------------------
# Remove distro-specific fish remnants from imported configs
# -----------------------------------------------------------------------------

phase "Removing non-Void fish remnants"

mkdir -p "$HOME/.config/fish"

if [[ -d "$HOME/.config/fish" ]]; then
  find "$HOME/.config/fish" -type f \
    \( -iname '*cachy*' -o -iname '*arch*' -o -iname '*paru*' -o -iname '*yay*' -o -iname '*apt*' \) \
    -print0 2>/dev/null | while IFS= read -r -d '' f; do
      cp "$f" "$f.bak.$(date +%Y%m%d-%H%M%S)"
      rm -f "$f"
      warn "Removed non-Void fish file: $f"
    done

  grep -RIlE 'cachyos|/usr/share/cachyos|paru|yay|pacman -|pacman[[:space:]]|apt install|apt update|apt full-upgrade' "$HOME/.config/fish" 2>/dev/null | while IFS= read -r f; do
    cp "$f" "$f.bak.$(date +%Y%m%d-%H%M%S)"
    sed -i -E '/cachyos|\/usr\/share\/cachyos|paru|yay|pacman -|pacman[[:space:]]|apt install|apt update|apt full-upgrade/d' "$f"
    warn "Sanitized non-Void references in: $f"
  done
fi

ok "Fish remnants cleaned."

# -----------------------------------------------------------------------------
# NIRU Noir fish and terminal configuration
# -----------------------------------------------------------------------------

phase "Writing integrated NIRU Noir fish and terminal configuration"

mkdir -p "$HOME/.config/fish" "$HOME/.config/alacritty" "$HOME/.config/kitty" "$HOME/.config/bat"

backup_user_file "$HOME/.config/fish/config.fish"
backup_user_file "$HOME/.config/starship.toml"
backup_user_file "$HOME/.config/kitty/kitty.conf"
backup_user_file "$HOME/.config/alacritty/alacritty.toml"
backup_user_file "$HOME/.config/bat/config"

cat > "$HOME/.config/fish/config.fish" <<'FISH'
# ~/.config/fish/config.fish
# NIRUCON Void Linux fish config with integrated NIRU Noir terminal profile.
# Void-safe: no Arch, CachyOS, Debian apt or systemd assumptions.

set -g fish_greeting ""

fish_add_path -g $HOME/.local/bin /usr/local/bin /usr/local/sbin /usr/bin /usr/sbin /bin /sbin

set -gx EDITOR nvim
set -gx VISUAL nvim
set -gx PAGER less
set -gx MANPAGER "less -R"
set -gx LESS "-R --use-color -Dd+r -Du+b"
set -gx BAT_THEME "TwoDark"

if status is-interactive
    set fish_color_normal d6d1c4
    set fish_color_command c8b46a
    set fish_color_keyword c8b46a
    set fish_color_param e0ddd2
    set fish_color_quote b8ad8a
    set fish_color_redirection a39a7a
    set fish_color_end 8f8f8f
    set fish_color_error 9a5a4f
    set fish_color_operator c8b46a
    set fish_color_escape d6c27a
    set fish_color_autosuggestion 666666
    set fish_color_comment 666666
    set fish_color_selection --background=35322a
    set fish_color_search_match --background=35322a
    set fish_color_valid_path --underline
end

set -gx EZA_COLORS "di=38;5;180:fi=38;5;252:ln=38;5;245:ex=38;5;222"

if command -q starship
    starship init fish | source
end

if command -q zoxide
    zoxide init fish | source
end

if command -q eza
    alias ls='eza --icons=auto --group-directories-first'
    alias ll='eza -lah --icons=auto --group-directories-first'
    alias la='eza -a --icons=auto --group-directories-first'
    alias lt='eza --tree --icons=auto --group-directories-first'
    alias tree='eza --tree --icons=auto --group-directories-first'
else
    alias ll='ls -lah --color=auto'
    alias la='ls -A --color=auto'
    alias l='ls -CF --color=auto'
end

if command -q bat
    alias cat='bat --style=plain --paging=never'
    alias batp='bat --paging=always'
end

alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'

alias grep='grep --color=auto'
if command -q rg
    alias rgg='rg'
end

alias gs='git status'
alias gp='git pull'
alias gl='git log --oneline --graph --decorate -20'
alias gcm='git commit -m'

alias c='clear'
alias update='sudo xbps-install -Syu'
alias install='sudo xbps-install -S'
alias search='xbps-query -Rs'
alias remove='sudo xbps-remove -R'
alias cleanup='sudo xbps-remove -Oo'
alias services='ls -la /var/service'
alias ports='ss -tulpn'
alias df='df -h'
alias free='free -h'
alias top='btop'

if command -q cmus
    alias music='cmus'
end

if command -q fastfetch
    alias ff='fastfetch'
end

if status is-interactive
    if command -q fzf
        fzf --fish | source 2>/dev/null
    end
end
FISH

cat > "$HOME/.config/starship.toml" <<'STARSHIP'
# NIRU Noir Starship prompt.
add_newline = true

format = """
$directory\
$git_branch\
$git_status\
$cmd_duration\
$line_break\
$character
"""

[directory]
style = "bold #c8b46a"
truncation_length = 4
truncate_to_repo = false

[git_branch]
format = "[$symbol$branch]($style) "
symbol = "◈ "
style = "#9c8a5b"

[git_status]
format = "[$all_status$ahead_behind]($style) "
style = "#7a7a7a"

[cmd_duration]
min_time = 2000
format = "[$duration]($style) "
style = "#8f8f8f"

[character]
success_symbol = "[❯](bold #d6d1c4)"
error_symbol = "[❯](bold #9a5a4f)"
STARSHIP

cat > "$HOME/.config/kitty/kitty.conf" <<'KITTY'
# ~/.config/kitty/kitty.conf
# NIRU Noir for Void Linux/dwm.

font_family JetBrainsMono Nerd Font
bold_font auto
italic_font auto
bold_italic_font auto
font_size 12.0

# Do not hardcode a shell here. Kitty should use the user's login shell.

background #0b0b0b
foreground #d6d1c4

selection_background #35322a
selection_foreground #f2ead3

cursor #c8b46a
cursor_text_color #0b0b0b
cursor_shape beam
cursor_blink_interval 0.5

url_color #c8b46a

color0  #0b0b0b
color1  #7a3f35
color2  #8a805f
color3  #c8b46a
color4  #8f8f8f
color5  #a39a7a
color6  #b8b8b8
color7  #d6d1c4
color8  #4a4a4a
color9  #9a5a4f
color10 #a8a080
color11 #d6c27a
color12 #b0b0b0
color13 #b8ad8a
color14 #cccccc
color15 #f2ead3

scrollback_lines 50000
enable_audio_bell no
visual_bell_duration 0
confirm_os_window_close 0

window_padding_width 10
background_opacity 0.96
dynamic_background_opacity yes

copy_on_select clipboard
strip_trailing_spaces smart

tab_bar_edge bottom
tab_bar_style hidden

map ctrl+shift+t new_tab
map ctrl+shift+w close_tab
map ctrl+shift+enter new_window
KITTY

cat > "$HOME/.config/alacritty/alacritty.toml" <<'ALACRITTY'
# NIRU Noir Alacritty fallback config.

[window]
padding = { x = 10, y = 10 }
dynamic_padding = true
opacity = 0.96

[font]
normal = { family = "JetBrainsMono Nerd Font", style = "Regular" }
bold = { family = "JetBrainsMono Nerd Font", style = "Bold" }
italic = { family = "JetBrainsMono Nerd Font", style = "Italic" }
size = 12.0

# Do not hardcode terminal.shell here. Alacritty should use the user's login shell.

[colors.primary]
background = "#0b0b0b"
foreground = "#d6d1c4"

[colors.cursor]
text = "#0b0b0b"
cursor = "#c8b46a"
ALACRITTY

cat > "$HOME/.config/bat/config" <<'BAT'
--theme=TwoDark
--style=plain
--paging=never
BAT

if have_cmd fish; then
  fish -c 'set -U fish_greeting ""' 2>/dev/null || true
fi

ok "NIRU Noir fish, Kitty, Alacritty, Starship and bat configuration written."

# -----------------------------------------------------------------------------
# Nerd Font
# -----------------------------------------------------------------------------

phase "Installing JetBrainsMono Nerd Font"

mkdir -p "$HOME/.local/share/fonts/JetBrainsMonoNerd"
TMPFONT="$(mktemp -d)"

if wget -q -O "$TMPFONT/JetBrainsMono.zip" "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/JetBrainsMono.zip"; then
  unzip -oq "$TMPFONT/JetBrainsMono.zip" -d "$HOME/.local/share/fonts/JetBrainsMonoNerd"
  fc-cache -fv >/dev/null || true
  ok "JetBrainsMono Nerd Font installed."
else
  warn "Could not download JetBrainsMono Nerd Font. Icons may be missing until installed manually."
fi

rm -rf "$TMPFONT"

# -----------------------------------------------------------------------------
# Optional statusbar patch
# -----------------------------------------------------------------------------

if [[ "$PATCH_STATUSBAR" -eq 1 && -f "$LOCAL_BIN/dwm-status.sh" ]]; then
  phase "Patching dwm-status.sh for Void"

  cp "$LOCAL_BIN/dwm-status.sh" "$LOCAL_BIN/dwm-status.sh.bak.$(date +%Y%m%d-%H%M%S)"

  sed -i 's|export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"|export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin"|' "$LOCAL_BIN/dwm-status.sh"
  sed -i 's/^SHOW_UPDATES=1/SHOW_UPDATES=0/' "$LOCAL_BIN/dwm-status.sh"
  sed -i 's/apt list --upgradable 2>\/dev\/null | wc -l/xbps-install -Sun 2>\/dev\/null | grep -c "^\\[\\*\\]"/' "$LOCAL_BIN/dwm-status.sh" || true

  chmod +x "$LOCAL_BIN/dwm-status.sh"

  ok "dwm-status.sh patched for Void where possible."
fi

# -----------------------------------------------------------------------------
# SDDM theme
# -----------------------------------------------------------------------------

phase "Installing NIRU Noir SDDM theme"

mkdir -p "$CACHE_DIR"

if [[ -d "$SDDM_THEME_CACHE/.git" ]]; then
  say "Updating existing SDDM theme repository..."
  git -C "$SDDM_THEME_CACHE" fetch --all --prune
  git -C "$SDDM_THEME_CACHE" pull --ff-only || true
else
  say "Cloning SDDM theme repository..."
  git clone "$SDDM_THEME_REPO" "$SDDM_THEME_CACHE"
fi

if [[ -d "$SDDM_THEME_CACHE/theme" ]]; then
  SDDM_THEME_SOURCE="$SDDM_THEME_CACHE/theme"
else
  SDDM_THEME_SOURCE="$SDDM_THEME_CACHE"
fi

if [[ ! -f "$SDDM_THEME_SOURCE/metadata.desktop" ]]; then
  fail "metadata.desktop is missing in the SDDM theme source: $SDDM_THEME_SOURCE"
  exit 1
fi

if [[ ! -f "$SDDM_THEME_SOURCE/Main.qml" ]]; then
  fail "Main.qml is missing in the SDDM theme source: $SDDM_THEME_SOURCE"
  exit 1
fi

sudo mkdir -p "/usr/share/sddm/themes/$SDDM_THEME_ID"
sudo rsync -a --delete "$SDDM_THEME_SOURCE/" "/usr/share/sddm/themes/$SDDM_THEME_ID/"
sudo chown -R root:root "/usr/share/sddm/themes/$SDDM_THEME_ID"

phase "Patching SDDM theme host label if needed"
# Older/local NIRU Noir theme builds could contain a hardcoded host label such as
# STUDIO. In QML, sddm.hostName exposes the real hostname from the system, so use
# that whenever a literal STUDIO label is found. This keeps the rune/noir look but
# prevents the login screen from showing the wrong machine name.
if sudo grep -RIl --include='*.qml' --include='*.conf' --include='*.desktop' 'STUDIO' "/usr/share/sddm/themes/$SDDM_THEME_ID" >/tmp/nirucon-vpi-sddm-studio-files 2>/dev/null; then
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    sudo cp -a "$f" "$f.bak.$(date +%Y%m%d-%H%M%S)"
    sudo sed -i -E 's/text:[[:space:]]*"STUDIO"/text: sddm.hostName/g; s/"STUDIO"/sddm.hostName/g' "$f" || true
    warn "Patched hardcoded SDDM host label in: $f"
  done < /tmp/nirucon-vpi-sddm-studio-files
  rm -f /tmp/nirucon-vpi-sddm-studio-files
else
  rm -f /tmp/nirucon-vpi-sddm-studio-files
  ok "No hardcoded STUDIO label found in SDDM theme."
fi

sudo mkdir -p /etc/sddm.conf.d
sudo tee /etc/sddm.conf.d/10-nirucon.conf >/dev/null <<SDDMCONF
[Theme]
Current=$SDDM_THEME_ID

[Users]
RememberLastUser=true

[General]
RememberLastSession=true
SDDMCONF

ok "SDDM theme installed and configured."

# -----------------------------------------------------------------------------
# dwm SDDM session
# -----------------------------------------------------------------------------

phase "Creating dwm SDDM session"

sudo tee "$SESSION_WRAPPER" >/dev/null <<'SESSION'
#!/usr/bin/env bash
set -Eeuo pipefail

export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin"
export XDG_CURRENT_DESKTOP=dwm
export DESKTOP_SESSION=dwm

[[ -r "$HOME/.profile" ]] && . "$HOME/.profile"

# Ensure a DBus session exists for tray apps, Polkit, notifications and portals.
if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]] && command -v dbus-run-session >/dev/null 2>&1 && [[ "${1:-}" != "--dbus-started" ]]; then
  exec dbus-run-session "$0" --dbus-started "$@"
fi
[[ "${1:-}" == "--dbus-started" ]] && shift || true

if command -v xrdb >/dev/null 2>&1 && [[ -r "$HOME/.Xresources" ]]; then
  xrdb -merge "$HOME/.Xresources"
fi

for f in "$HOME/.config/xinitrc.d/"*.sh; do
  [[ -r "$f" ]] && . "$f"
done

exec dwm
SESSION

sudo chmod +x "$SESSION_WRAPPER"

sudo mkdir -p /usr/share/xsessions
sudo tee "$SESSION_DESKTOP" >/dev/null <<DESKTOP
[Desktop Entry]
Name=dwm
Comment=Dynamic window manager
Exec=$SESSION_WRAPPER
TryExec=/usr/local/bin/dwm
Type=Application
DesktopNames=dwm
DESKTOP

ok "dwm SDDM session created."

# -----------------------------------------------------------------------------
# X session hooks
# -----------------------------------------------------------------------------

phase "Creating modular X session hooks"

mkdir -p "$XINITRC_DIR"

cat > "$XINITRC_DIR/10-env.sh" <<'HOOK'
#!/usr/bin/env bash

export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin"
export XDG_CURRENT_DESKTOP=dwm
export DESKTOP_SESSION=dwm

command -v setxkbmap >/dev/null 2>&1 && setxkbmap se
command -v xsetroot >/dev/null 2>&1 && xsetroot -solid "#111111"
HOOK

cat > "$XINITRC_DIR/20-lookandfeel.sh" <<'HOOK'
#!/usr/bin/env bash

command -v dunst >/dev/null 2>&1 && ! pgrep -x dunst >/dev/null 2>&1 && dunst &
command -v lxpolkit >/dev/null 2>&1 && ! pgrep -x lxpolkit >/dev/null 2>&1 && lxpolkit &

if command -v picom >/dev/null 2>&1 && ! pgrep -x picom >/dev/null 2>&1; then
  if [[ -f "$HOME/.config/picom/picom.conf" ]]; then
    picom --config "$HOME/.config/picom/picom.conf" --daemon 2>/dev/null || picom --daemon &
  else
    picom --daemon &
  fi
fi

command -v blueman-applet >/dev/null 2>&1 && ! pgrep -x blueman-applet >/dev/null 2>&1 && blueman-applet &
command -v udiskie >/dev/null 2>&1 && ! pgrep -x udiskie >/dev/null 2>&1 && udiskie --tray &
command -v nextcloud >/dev/null 2>&1 && ! pgrep -x nextcloud >/dev/null 2>&1 && nextcloud --background &
HOOK

cat > "$XINITRC_DIR/30-wallpaper.sh" <<'HOOK'
#!/usr/bin/env bash

if [[ -x "$HOME/.local/bin/wallrotate.sh" ]]; then
  "$HOME/.local/bin/wallrotate.sh" &
elif [[ -x "$HOME/.local/bin/wallpaperchange.sh" ]]; then
  "$HOME/.local/bin/wallpaperchange.sh" &
elif command -v feh >/dev/null 2>&1 && [[ -d "$HOME/Pictures" ]]; then
  feh --randomize --bg-fill "$HOME/Pictures" &
fi
HOOK

cat > "$XINITRC_DIR/40-statusbar.sh" <<'HOOK'
#!/usr/bin/env bash

if [[ -x "$HOME/.local/bin/dwm-status.sh" ]]; then
  pkill -u "$USER" -f "$HOME/.local/bin/dwm-status.sh" 2>/dev/null || true
  "$HOME/.local/bin/dwm-status.sh" &
fi
HOOK

cat > "$XINITRC_DIR/50-lock.sh" <<'HOOK'
#!/usr/bin/env bash

if command -v xss-lock >/dev/null 2>&1 && command -v slock >/dev/null 2>&1 && ! pgrep -x xss-lock >/dev/null 2>&1; then
  xss-lock slock &
fi
HOOK

cat > "$XINITRC_DIR/60-audio.sh" <<'HOOK'
#!/usr/bin/env bash

# Void systems may run PipeWire as runit services. If not, try a user-session
# startup so normal desktop audio still works in this minimal dwm session.
if command -v pipewire >/dev/null 2>&1 && ! pgrep -u "$USER" -x pipewire >/dev/null 2>&1; then
  pipewire &
fi

if command -v wireplumber >/dev/null 2>&1 && ! pgrep -u "$USER" -x wireplumber >/dev/null 2>&1; then
  wireplumber &
fi

if command -v pipewire-pulse >/dev/null 2>&1 && ! pgrep -u "$USER" -x pipewire-pulse >/dev/null 2>&1; then
  pipewire-pulse &
fi
HOOK

cat > "$XINITRC_DIR/90-local.sh" <<'HOOK'
#!/usr/bin/env bash

# Add local machine-specific startup commands here.
HOOK

chmod +x "$XINITRC_DIR/"*.sh

ok "X session hooks created."

# -----------------------------------------------------------------------------
# .xinitrc fallback
# -----------------------------------------------------------------------------

phase "Creating .xinitrc fallback"

cat > "$HOME/.xinitrc" <<'XINITRC'
#!/usr/bin/env bash
set -Eeuo pipefail

export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin"
export XDG_CURRENT_DESKTOP=dwm
export DESKTOP_SESSION=dwm

[[ -r "$HOME/.profile" ]] && . "$HOME/.profile"

# Ensure a DBus session exists for tray apps, Polkit, notifications and portals.
if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]] && command -v dbus-run-session >/dev/null 2>&1 && [[ "${1:-}" != "--dbus-started" ]]; then
  exec dbus-run-session "$0" --dbus-started "$@"
fi
[[ "${1:-}" == "--dbus-started" ]] && shift || true

if command -v xrdb >/dev/null 2>&1 && [[ -r "$HOME/.Xresources" ]]; then
  xrdb -merge "$HOME/.Xresources"
fi

for f in "$HOME/.config/xinitrc.d/"*.sh; do
  [[ -r "$f" ]] && . "$f"
done

exec dwm
XINITRC

chmod +x "$HOME/.xinitrc"

ok ".xinitrc fallback created."

# -----------------------------------------------------------------------------
# fish shell
# -----------------------------------------------------------------------------

if [[ "$SET_FISH_DEFAULT" -eq 1 ]]; then
  phase "Setting fish as default shell"

  FISH_PATH="$(command -v fish || true)"

  if [[ -z "$FISH_PATH" ]]; then
    warn "fish is not installed or not found in PATH. Default shell unchanged."
  else
    grep -qxF "$FISH_PATH" /etc/shells || echo "$FISH_PATH" | sudo tee -a /etc/shells >/dev/null
    sudo chsh -s "$FISH_PATH" "$USER"
    ok "fish set as default shell for $USER."
  fi
else
  note "fish installed, but default shell left unchanged."
fi

# -----------------------------------------------------------------------------
# Helper scripts
# -----------------------------------------------------------------------------

phase "Creating helper scripts"

mkdir -p "$LOCAL_BIN"

cat > "$LOCAL_BIN/audio-status.sh" <<'AUDIOSTATUS'
#!/usr/bin/env bash
set -euo pipefail

echo "== User / groups =="
id

echo
echo "== PipeWire processes =="
pgrep -a pipewire || true
pgrep -a wireplumber || true

echo
echo "== pactl info =="
pactl info 2>/dev/null || true

echo
echo "== Audio sinks =="
pactl list short sinks 2>/dev/null || true

echo
echo "== Audio sources =="
pactl list short sources 2>/dev/null || true

echo
echo "== ALSA playback devices =="
aplay -l 2>/dev/null || true

echo
echo "== ALSA capture devices =="
arecord -l 2>/dev/null || true
AUDIOSTATUS

cat > "$LOCAL_BIN/vpi-network-fix.sh" <<'NETFIX'
#!/usr/bin/env bash
set -euo pipefail

choice="${1:-status}"

status() {
  echo "== Network processes =="
  ps aux | grep -E 'NetworkManager|dhcpcd|wpa_supplicant' | grep -v grep || true
  echo
  echo "== Runit services =="
  for svc in NetworkManager dhcpcd wpa_supplicant; do
    if [[ -e "/var/service/$svc" ]]; then
      sudo sv status "$svc" || true
    else
      echo "$svc: disabled"
    fi
  done
  echo
  echo "== Addresses =="
  ip -4 addr || true
  echo
  if command -v nmcli >/dev/null 2>&1; then
    echo "== NetworkManager =="
    nmcli general status || true
    nmcli device status || true
  fi
}

case "$choice" in
  status)
    status
    ;;
  classic)
    echo "Switching to classic Void networking: dhcpcd + wpa_supplicant"
    sudo sv down NetworkManager 2>/dev/null || true
    sudo rm -f /var/service/NetworkManager
    sudo ln -sf /etc/sv/wpa_supplicant /var/service/wpa_supplicant
    sudo ln -sf /etc/sv/dhcpcd /var/service/dhcpcd
    sudo sv up wpa_supplicant 2>/dev/null || true
    sudo sv up dhcpcd 2>/dev/null || true
    status
    ;;
  nm|networkmanager)
    echo "Switching to NetworkManager only"
    sudo sv down dhcpcd 2>/dev/null || true
    sudo sv down wpa_supplicant 2>/dev/null || true
    sudo rm -f /var/service/dhcpcd /var/service/wpa_supplicant
    sudo ln -sf /etc/sv/NetworkManager /var/service/NetworkManager
    sudo sv up NetworkManager 2>/dev/null || true
    status
    echo
    echo "Connect WiFi with: nmcli device wifi connect 'SSID' password 'PASSWORD'"
    ;;
  *)
    echo "Usage: vpi-network-fix.sh [status|classic|nm]"
    exit 1
    ;;
esac
NETFIX

chmod +x "$LOCAL_BIN/vpi-network-fix.sh"

cat > "$LOCAL_BIN/vpi-services.sh" <<'SERVICES'
#!/usr/bin/env bash
set -euo pipefail

echo "== Enabled runit services =="
ls -la /var/service

echo
echo "== Service status =="
for svc in dbus elogind NetworkManager dhcpcd wpa_supplicant sddm pipewire pipewire-pulse wireplumber bluetoothd cupsd sshd tailscaled; do
  if [[ -e "/var/service/$svc" ]]; then
    echo
    echo "--- $svc ---"
    sudo sv status "$svc" || true
  fi
done
SERVICES

cat > "$LOCAL_BIN/vpi-check.sh" <<'CHECK'
#!/usr/bin/env bash
set -euo pipefail

echo "== Void system =="
cat /etc/os-release 2>/dev/null | sed -n '1,8p' || true
ldd --version 2>&1 | head -1 || true
uname -r

echo
echo "== Core binaries =="
for cmd in dwm dmenu st slock sddm fish kitty starship zoxide eza bat rofi picom dunst pipewire wireplumber pactl; do
  printf '%-18s ' "$cmd:"
  command -v "$cmd" || echo missing
done

echo
echo "== Services =="
for svc in dbus elogind NetworkManager dhcpcd wpa_supplicant sddm pipewire pipewire-pulse wireplumber; do
  if [[ -e "/var/service/$svc" ]]; then
    sudo sv status "$svc" || true
  else
    echo "$svc: not enabled or not installed"
  fi
done

echo
echo "== Audio =="
pactl info 2>/dev/null || echo "pactl did not connect yet. Reboot/log in to dwm and test again."
CHECK

chmod +x "$LOCAL_BIN/audio-status.sh" "$LOCAL_BIN/vpi-services.sh" "$LOCAL_BIN/vpi-check.sh" "$LOCAL_BIN/vpi-network-fix.sh"

ok "Helper scripts created."

# -----------------------------------------------------------------------------
# Final cleanup
# -----------------------------------------------------------------------------

phase "Final XBPS cleanup"

sudo xbps-remove -Oo || true

ok "XBPS cleanup completed."

# -----------------------------------------------------------------------------
# Verification
# -----------------------------------------------------------------------------

phase "Verification"

echo "System"
echo "  OS:              $(grep '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d= -f2- | tr -d '"' || echo unknown)"
echo "  libc:            $(ldd --version 2>&1 | head -1 || echo unknown)"
echo "  Kernel:          $(uname -r)"
echo "  User:            $USER"
echo "  Shell:           $(getent passwd "$USER" | cut -d: -f7)"
echo

echo "Core desktop"
echo "  dwm:             $(command -v dwm || echo missing)"
echo "  st:              $(command -v st || echo missing)"
echo "  dmenu:           $(command -v dmenu || echo missing)"
echo "  slock:           $(command -v slock || echo missing)"
echo "  SDDM:            $(command -v sddm || echo missing)"
echo "  SDDM service:    $([[ -e /var/service/sddm ]] && echo enabled || echo missing)"
echo "  SDDM theme:      $(grep -R '^Current=' /etc/sddm.conf.d 2>/dev/null | head -1 || echo missing)"
echo

echo "Desktop tools"
echo "  fish:            $(command -v fish || echo missing)"
echo "  kitty:           $(command -v kitty || echo missing)"
echo "  alacritty:       $(command -v alacritty || echo missing)"
echo "  rofi:            $(command -v rofi || echo missing)"
echo "  picom:           $(command -v picom || echo missing)"
echo "  dunst:           $(command -v dunst || echo missing)"
echo "  Network backend:   $NETWORK_BACKEND"
echo "  NetworkManager:  $([[ -e /var/service/NetworkManager ]] && echo enabled || echo disabled)"
echo "  dhcpcd:          $([[ -e /var/service/dhcpcd ]] && echo enabled || echo disabled)"
echo "  wpa_supplicant:  $([[ -e /var/service/wpa_supplicant ]] && echo enabled || echo disabled)"
echo

echo "Audio playback"
echo "  PipeWire:        $(command -v pipewire || echo missing)"
echo "  WirePlumber:     $(command -v wireplumber || echo missing)"
echo "  pactl:           $(command -v pactl || echo missing)"
echo "  pamixer:         $(command -v pamixer || echo missing)"
echo "  pavucontrol:     $(command -v pavucontrol || echo missing)"
echo "  audio-status:    $(command -v audio-status.sh || echo missing)"
echo

echo "Fonts / prompt"
echo "  Nerd Font:       $(fc-match 'JetBrainsMono Nerd Font' | head -1 2>/dev/null || echo missing)"
echo "  starship:        $(command -v starship || echo missing)"
echo "  zoxide:          $(command -v zoxide || echo missing)"
echo "  eza:             $(command -v eza || echo missing)"
echo "  bat:             $(command -v bat || echo missing)"
echo

if [[ -d "/usr/share/sddm/themes/$SDDM_THEME_ID" ]]; then
  ok "NIRU Noir SDDM theme exists: /usr/share/sddm/themes/$SDDM_THEME_ID"
else
  warn "NIRU Noir SDDM theme directory is missing."
fi

if [[ "$IS_LAPTOP" -eq 1 ]]; then
  ok "Laptop profile installed."
else
  ok "Workstation profile installed."
fi

# -----------------------------------------------------------------------------
# Final instructions
# -----------------------------------------------------------------------------

echo
phase "Void Post Install complete"

echo "Recommended next step:"
echo "  sudo reboot"
echo
echo "After reboot:"
echo "  1) Select dwm in SDDM."
echo "  2) Verify networking:"
echo "       nmcli device status"
echo "  3) Verify services:"
echo "       vpi-services.sh"
echo "  4) Verify audio playback:"
echo "       audio-status.sh"
echo "       pavucontrol"
echo "  5) Test lock screen:"
echo "       slock"
echo
echo "Useful commands:"
echo "  update          # sudo xbps-install -Syu"
echo "  install PKG     # sudo xbps-install -S PKG"
echo "  search TERM     # xbps-query -Rs TERM"
echo "  cleanup         # sudo xbps-remove -Oo"
echo "  ff              # fastfetch"
echo
warn "You must reboot before new group membership and display/audio services are fully active."
ok "Done."
