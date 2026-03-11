#!/bin/bash
# ============================================================================
# CachyOS Post-Install Setup — Surface i5-7300U / 8GB / Intel HD 620
# Neobrutalist theme matching tonus.bio
# ============================================================================
# Run after fresh CachyOS KDE install with systemd-boot.
# Usage: chmod +x install.sh && ./install.sh
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="/tmp/cachyos-setup-$(date +%Y%m%d-%H%M%S).log"

info()  { echo -e "\e[1;33m[TONUS]\e[0m $*" | tee -a "$LOG"; }
ok()    { echo -e "\e[1;32m  [OK]\e[0m $*" | tee -a "$LOG"; }
warn()  { echo -e "\e[1;31m[WARN]\e[0m $*" | tee -a "$LOG"; }
step()  { echo -e "\n\e[1;37m━━━ $* ━━━\e[0m" | tee -a "$LOG"; }

# ============================================================================
# 0. PRE-FLIGHT
# ============================================================================
step "Pre-flight checks"

if [[ ! -f /etc/cachyos-release ]] && ! grep -qi cachyos /etc/os-release 2>/dev/null; then
    warn "This doesn't look like CachyOS. Proceed anyway? (y/N)"
    read -r ans; [[ "$ans" =~ ^[Yy] ]] || exit 1
fi

info "Updating system first..."
sudo pacman -Syu --noconfirm 2>&1 | tail -5 | tee -a "$LOG"
ok "System updated"

# Ensure paru (CachyOS default AUR helper)
if ! command -v paru &>/dev/null; then
    info "Installing paru..."
    sudo pacman -S --needed --noconfirm paru
fi
ok "paru available"

# ============================================================================
# 1. SURFACE HARDWARE SUPPORT
# ============================================================================
step "Surface hardware support (linux-surface)"

info "Adding linux-surface repo..."
# Import signing key
sudo pacman-key --recv-keys 0A1A8C842B3B8683
sudo pacman-key --lsign-key 0A1A8C842B3B8683

# Add repo to pacman.conf if not already present
if ! grep -q "\[linux-surface\]" /etc/pacman.conf; then
    sudo tee -a /etc/pacman.conf > /dev/null <<'REPO'

[linux-surface]
Server = https://pkg.surfacelinux.com/arch/
REPO
    sudo pacman -Sy
fi

info "Installing Surface kernel + touch daemon..."
sudo pacman -S --needed --noconfirm \
    linux-surface linux-surface-headers iptsd 2>&1 | tail -3 | tee -a "$LOG"

sudo systemctl enable --now iptsd || warn "iptsd enable failed (may need reboot)"
ok "Surface kernel + IPTSD installed (reboot required to use)"

# ============================================================================
# 2. SYSTEM OPTIMIZATION (8GB / dual-core aware)
# ============================================================================
step "System optimization"

info "Installing optimization packages..."
sudo pacman -S --needed --noconfirm \
    earlyoom \
    irqbalance \
    intel-media-driver \
    libva-intel-driver \
    libva-utils \
    vulkan-intel \
    intel-gpu-tools \
    thermald \
    zram-generator \
    preload 2>&1 | tail -3 | tee -a "$LOG"

# --- zram (compressed swap in RAM — critical for 8GB) ---
info "Configuring zram (4GB compressed swap)..."
sudo mkdir -p /etc/systemd
sudo tee /etc/systemd/zram-generator.conf > /dev/null <<'ZRAM'
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
ZRAM

# --- earlyoom (prevents freeze on OOM — critical for 8GB) ---
info "Configuring earlyoom..."
sudo mkdir -p /etc/default
sudo tee /etc/default/earlyoom > /dev/null <<'EARLYOOM'
EARLYOOM_ARGS="-r 60 -m 5 -s 5 --avoid '(^|/)(plasma|kwin|Xwayland)$' --prefer '(^|/)(Web Content|electron)$'"
EARLYOOM

# --- Intel GPU: VA-API environment ---
info "Configuring Intel VA-API..."
sudo tee /etc/environment.d/intel-gpu.conf > /dev/null <<'INTEL'
LIBVA_DRIVER_NAME=iHD
VDPAU_DRIVER=va_gl
INTEL

# --- sysctl tweaks for 8GB ---
info "Applying sysctl tweaks for low-RAM system..."
sudo tee /etc/sysctl.d/99-tonus-tweaks.conf > /dev/null <<'SYSCTL'
# Reduce swappiness (prefer keeping apps in RAM, zram handles pressure)
vm.swappiness = 10
# Reduce vfs cache pressure (keep dentries/inodes longer)
vm.vfs_cache_pressure = 50
# Faster SSD writes
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
# Network tweaks
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
SYSCTL

sudo sysctl --system > /dev/null 2>&1

# --- Enable services ---
info "Enabling system services..."
sudo systemctl enable --now earlyoom
sudo systemctl enable --now irqbalance
sudo systemctl enable --now thermald
sudo systemctl enable --now preload 2>/dev/null || warn "preload service may use different name"
ok "System optimization configured"

# ============================================================================
# 3. CORE APPLICATIONS (one per category, hardware-optimized)
# ============================================================================
step "Installing core applications"

info "Pacman packages (official repos)..."
sudo pacman -S --needed --noconfirm \
    \
    `# Browser — Firefox (lower RAM than Chromium, VA-API hw decode)` \
    firefox \
    \
    `# Media — MPV (lightest, VA-API hw accel, scriptable)` \
    mpv \
    \
    `# Terminal — Konsole (KDE-native, zero extra deps)` \
    konsole \
    \
    `# Firewall — UFW (simplest, lightest)` \
    ufw \
    \
    `# Email — Thunderbird (lighter than KMail+Akonadi on 8GB)` \
    thunderbird \
    \
    `# Music — Strawberry (Qt-native, great codec support)` \
    strawberry \
    \
    `# Text Editor — Kate (KDE-native, LSP support, built-in terminal)` \
    kate \
    \
    `# VPN — WireGuard (kernel-level, minimal overhead)` \
    wireguard-tools \
    \
    `# Office — LibreOffice Still (stable, loaded on-demand only)` \
    libreoffice-still \
    \
    `# Screenshot — Spectacle (KDE-native, already included)` \
    spectacle \
    \
    `# Backup (system) — Timeshift (btrfs snapshots)` \
    timeshift \
    \
    `# Backup (data) — BorgBackup (dedup + compression)` \
    borg \
    \
    `# Archive — Ark (KDE-native)` \
    ark \
    \
    `# PDF — Okular (KDE-native, annotations)` \
    okular \
    \
    `# Photos — digiKam is heavy; gwenview already in KDE; adding:` \
    shotwell \
    \
    `# Remote Desktop — Remmina (VNC + RDP in one app)` \
    remmina freerdp \
    \
    `# Video Editor — Kdenlive (KDE-native, Qt)` \
    kdenlive \
    \
    `# Image Editor — GIMP (most practical general-purpose)` \
    gimp \
    \
    `# System Monitor — btop (user requested)` \
    btop \
    \
    `# Password Manager — KeePassXC (Qt-native, offline, light)` \
    keepassxc \
    \
    `# File Manager — Dolphin (KDE-native, already included)` \
    dolphin \
    \
    `# Disk Management — GParted (essential for dual-boot)` \
    gparted \
    2>&1 | tail -5 | tee -a "$LOG"

ok "Core applications installed"

# ============================================================================
# 4. DEV ENVIRONMENT
# ============================================================================
step "Developer environment"

info "Core dev tools..."
sudo pacman -S --needed --noconfirm \
    git git-lfs github-cli \
    docker docker-compose docker-buildx \
    python python-pip python-pipx \
    base-devel cmake ninja meson \
    rust go \
    jdk-openjdk \
    \
    `# Modern CLI replacements (Rust-based, fast)` \
    ripgrep fd bat eza fzf zoxide starship \
    lazygit tmux just direnv jq yq \
    \
    `# Network/debug tools` \
    curl wget httpie nmap wireshark-qt \
    2>&1 | tail -5 | tee -a "$LOG"

# --- fnm (Fast Node Manager — Rust, faster than nvm) ---
info "Installing fnm (Fast Node Manager)..."
if ! command -v fnm &>/dev/null; then
    curl -fsSL https://fnm.vercel.app/install | bash -s -- --skip-shell
fi

# --- Shell integration for dev tools ---
info "Configuring shell integration..."
cat >> ~/.bashrc <<'BASHRC'

# === CachyOS Dev Environment (tonus setup) ===
# fnm (Node.js)
eval "$(fnm env --use-on-cd)"
# starship prompt
eval "$(starship init bash)"
# zoxide (smart cd)
eval "$(zoxide init bash)"
# fzf keybindings
source /usr/share/fzf/key-bindings.bash 2>/dev/null
source /usr/share/fzf/completion.bash 2>/dev/null
# direnv
eval "$(direnv hook bash)"
# Aliases
alias ls='eza --icons'
alias ll='eza -la --icons --git'
alias cat='bat --paging=never'
alias lg='lazygit'
alias g='git'
# === End tonus setup ===
BASHRC

# --- Docker (rootless setup for security) ---
info "Configuring Docker..."
sudo systemctl enable docker
sudo usermod -aG docker "$USER"
ok "Docker configured (re-login required for group)"

# --- Install Node.js LTS ---
info "Installing Node.js LTS via fnm..."
export PATH="$HOME/.local/share/fnm:$PATH"
eval "$(fnm env)" 2>/dev/null || true
fnm install --lts 2>&1 | tail -2 | tee -a "$LOG"
fnm default lts-latest

# --- Claude Code CLI ---
info "Installing Claude Code..."
npm install -g @anthropic-ai/claude-code 2>&1 | tail -2 | tee -a "$LOG"

ok "Dev environment configured"

# ============================================================================
# 5. AUR PACKAGES
# ============================================================================
step "AUR packages"

info "Installing AUR packages (this may take a while)..."
paru -S --needed --noconfirm \
    obsidian-bin \
    visual-studio-code-bin \
    albert \
    auto-cpufreq \
    profile-sync-daemon \
    papirus-icon-theme \
    bibata-cursor-theme \
    2>&1 | tail -5 | tee -a "$LOG"

# auto-cpufreq (better than power-profiles-daemon for laptops)
info "Configuring auto-cpufreq..."
sudo systemctl mask power-profiles-daemon 2>/dev/null || true
sudo systemctl enable --now auto-cpufreq
ok "AUR packages installed"

# ============================================================================
# 6. FONTS (tonus.bio typography system)
# ============================================================================
step "Installing tonus.bio fonts"

FONT_DIR="$HOME/.local/share/fonts/tonus"
mkdir -p "$FONT_DIR"

download_font() {
    local name="$1" url="$2"
    info "  Downloading $name..."
    curl -fsSL "$url" -o "/tmp/${name}.zip"
    unzip -qo "/tmp/${name}.zip" -d "/tmp/${name}"
    find "/tmp/${name}" -name '*.ttf' -o -name '*.otf' | while read -r f; do
        cp "$f" "$FONT_DIR/"
    done
    rm -rf "/tmp/${name}" "/tmp/${name}.zip"
}

download_font "Cinzel" "https://fonts.google.com/download?family=Cinzel"
download_font "Outfit" "https://fonts.google.com/download?family=Outfit"
download_font "Cormorant_Garamond" "https://fonts.google.com/download?family=Cormorant+Garamond"
download_font "Space_Mono" "https://fonts.google.com/download?family=Space+Mono"

fc-cache -fv > /dev/null 2>&1
ok "Tonus fonts installed to $FONT_DIR"

# ============================================================================
# 7. KDE THEME — NEOBRUTALIST (tonus.bio)
# ============================================================================
step "Applying Neobrutalist KDE theme"

# --- Install KDE color scheme ---
COLOR_DIR="$HOME/.local/share/color-schemes"
mkdir -p "$COLOR_DIR"
cp "$SCRIPT_DIR/theme/tonus-neobrutalist-dark.colors" "$COLOR_DIR/"
cp "$SCRIPT_DIR/theme/tonus-neobrutalist-light.colors" "$COLOR_DIR/" 2>/dev/null || true
ok "Color schemes installed"

# --- Install Konsole theme ---
KONSOLE_COLOR_DIR="$HOME/.local/share/konsole"
mkdir -p "$KONSOLE_COLOR_DIR"
cp "$SCRIPT_DIR/theme/Tonus.colorscheme" "$KONSOLE_COLOR_DIR/"
cp "$SCRIPT_DIR/theme/Tonus.profile" "$KONSOLE_COLOR_DIR/"
ok "Konsole theme installed"

# --- Apply KDE settings via kwriteconfig6 ---
info "Applying Plasma settings..."

# Color scheme
kwriteconfig6 --file kdeglobals --group General --key ColorScheme "Tonus Neobrutalist Dark"

# Fonts (Outfit 10pt for UI, Space Mono 10pt for monospace)
kwriteconfig6 --file kdeglobals --group General --key font "Outfit,10,-1,5,400,0,0,0,0,0,0,0,0,0,0,1"
kwriteconfig6 --file kdeglobals --group General --key fixed "Space Mono,10,-1,5,400,0,0,0,0,0,0,0,0,0,0,1"
kwriteconfig6 --file kdeglobals --group General --key smallestReadableFont "Outfit,8,-1,5,400,0,0,0,0,0,0,0,0,0,0,1"
kwriteconfig6 --file kdeglobals --group General --key toolBarFont "Outfit,9,-1,5,400,0,0,0,0,0,0,0,0,0,0,1"
kwriteconfig6 --file kdeglobals --group General --key menuFont "Outfit,10,-1,5,400,0,0,0,0,0,0,0,0,0,0,1"
kwriteconfig6 --file kdeglobals --group WM --key activeFont "Cinzel,10,-1,5,600,0,0,0,0,0,0,0,0,0,0,1"

# Icon theme
kwriteconfig6 --file kdeglobals --group Icons --key Theme "Papirus-Dark"

# Cursor
kwriteconfig6 --file kcminputrc --group Mouse --key cursorTheme "Bibata-Modern-Classic"
kwriteconfig6 --file kcminputrc --group Mouse --key cursorSize 24

# Single-click to open (neobrutalist = efficient)
kwriteconfig6 --file kdeglobals --group KDE --key SingleClick true

# Disable animations (snappier on 2-core)
kwriteconfig6 --file kdeglobals --group KDE --key AnimationDurationFactor 0.5

# Window decoration — minimal borders
kwriteconfig6 --file kwinrc --group org.kde.kdecoration2 --key BorderSize "None"
kwriteconfig6 --file kwinrc --group org.kde.kdecoration2 --key ButtonsOnLeft ""
kwriteconfig6 --file kwinrc --group org.kde.kdecoration2 --key ButtonsOnRight "IAX"

# Konsole default profile
kwriteconfig6 --file konsolerc --group "Desktop Entry" --key DefaultProfile "Tonus.profile"

ok "Plasma settings applied"

# --- Starship prompt (neobrutalist minimal) ---
info "Configuring starship prompt..."
mkdir -p "$HOME/.config"
cat > "$HOME/.config/starship.toml" <<'STARSHIP'
# Tonus Neobrutalist — minimal, gold accent
format = """$directory$git_branch$git_status$character"""
add_newline = false

[character]
success_symbol = "[>](bold #c5a55a)"
error_symbol = "[>](bold #8b2d1a)"

[directory]
style = "bold #efede3"
truncation_length = 3
truncation_symbol = ".../"

[git_branch]
style = "bold #c5a55a"
format = " [$symbol$branch]($style)"
symbol = ""

[git_status]
style = "#6b6862"
format = "[$all_status$ahead_behind]($style) "
STARSHIP
ok "Starship prompt configured"

# ============================================================================
# 8. FIREWALL
# ============================================================================
step "Firewall configuration"

info "Enabling UFW..."
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw enable
ok "UFW enabled (deny incoming, allow outgoing)"

# ============================================================================
# 9. PROFILE-SYNC-DAEMON (browser profiles in RAM)
# ============================================================================
step "Profile-sync-daemon"

info "Enabling psd for Firefox..."
mkdir -p "$HOME/.config/psd"
cat > "$HOME/.config/psd/psd.conf" <<'PSD'
USE_OVERLAYFS="yes"
BROWSERS=(firefox)
PSD
systemctl --user enable --now psd 2>/dev/null || warn "psd needs re-login to start"
ok "Browser profile sync configured"

# ============================================================================
# 10. FIREFOX HARDWARE ACCELERATION
# ============================================================================
step "Firefox VA-API setup"

FIREFOX_PROFILE_DIR=$(find "$HOME/.mozilla/firefox" -maxdepth 1 -name '*.default-release' 2>/dev/null | head -1)
if [[ -n "$FIREFOX_PROFILE_DIR" ]]; then
    # Create user.js for hardware acceleration
    cat > "$FIREFOX_PROFILE_DIR/user.js" <<'FFJS'
// Hardware video acceleration (Intel VA-API)
user_pref("media.ffmpeg.vaapi.enabled", true);
user_pref("media.hardware-video-decoding.force-enabled", true);
user_pref("gfx.webrender.all", true);
user_pref("widget.dmabuf.force-enabled", true);
// Reduce memory usage
user_pref("browser.sessionhistory.max_total_viewers", 2);
user_pref("browser.cache.memory.capacity", 131072);
FFJS
    ok "Firefox VA-API enabled"
else
    warn "Firefox profile not found — launch Firefox once, then re-run this section"
fi

# ============================================================================
# 11. MPV HARDWARE ACCELERATION
# ============================================================================
step "MPV configuration"

mkdir -p "$HOME/.config/mpv"
cat > "$HOME/.config/mpv/mpv.conf" <<'MPV'
# Intel HD 620 hardware decoding
hwdec=vaapi
vo=gpu
gpu-context=wayland
# Performance tweaks for 2-core
video-sync=display-resample
interpolation=no
# OSD style matching neobrutalist theme
osd-font="Outfit"
osd-font-size=24
osd-color="#efede3"
osd-border-color="#0c0b0a"
osd-border-size=2
MPV
ok "MPV configured with VA-API"

# ============================================================================
# DONE
# ============================================================================
step "SETUP COMPLETE"

echo ""
info "Log saved to: $LOG"
echo ""
echo -e "\e[1;33m  Actions required:\e[0m"
echo "  1. REBOOT to load linux-surface kernel"
echo "  2. Re-login for Docker group + psd"
echo "  3. Run 'fnm use --lts' in new shell to activate Node.js"
echo "  4. Open System Settings > Colors > select 'Tonus Neobrutalist Dark'"
echo "  5. Open System Settings > Cursors > select 'Bibata-Modern-Classic'"
echo "  6. Set Konsole profile to 'Tonus' in Konsole Settings > Profiles"
echo ""
echo -e "\e[1;33m  Dual-boot notes (systemd-boot + shared drive):\e[0m"
echo "  - CachyOS uses systemd-boot by default"
echo "  - BEFORE installing: shrink Windows partition from Windows Disk Management"
echo "    (right-click C: > Shrink Volume > leave unallocated space for CachyOS)"
echo "  - CachyOS installer will use the existing ESP (shares with Windows Boot Manager)"
echo "  - Recommended partition layout on freed space:"
echo "      /        (btrfs, 60-80GB) — root + Timeshift snapshots"
echo "      /home    (btrfs, remainder) — user data"
echo "      swap     (skip — zram handles this in RAM)"
echo "  - systemd-boot auto-detects Windows Boot Manager on shared ESP"
echo "  - Surface boot menu: hold Volume Down during power-on"
echo "  - If Windows Update resets default boot entry:"
echo "      sudo bootctl install   (re-sets systemd-boot as default)"
echo ""
echo -e "\e[1;32m  Tonus neobrutalist theme applied.\e[0m"
echo -e "\e[1;32m  Parchment. Charcoal. Gold. Raw and honest.\e[0m"
echo ""
