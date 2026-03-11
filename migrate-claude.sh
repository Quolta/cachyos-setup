#!/bin/bash
# ============================================================================
# Claude Code Migration: Windows → CachyOS
# ============================================================================
# Transfers Claude Code config from Windows partition or backup tarball.
# Patches Windows paths to Linux, adapts PowerShell hooks to bash.
#
# Usage:
#   ./migrate-claude.sh --from-mount /mnt/windows    (mounted NTFS partition)
#   ./migrate-claude.sh --from-tarball ~/claude-backup.tar.gz
#   ./migrate-claude.sh --from-mount auto             (auto-detect Windows)
# ============================================================================
set -euo pipefail

info()  { echo -e "\e[1;33m[MIGRATE]\e[0m $*"; }
ok()    { echo -e "\e[1;32m     [OK]\e[0m $*"; }
warn()  { echo -e "\e[1;31m   [WARN]\e[0m $*"; }
die()   { echo -e "\e[1;31m  [FATAL]\e[0m $*"; exit 1; }

CLAUDE_DIR="$HOME/.claude"
MODE=""
SOURCE=""

# ── Parse args ──────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --from-mount)   MODE="mount";   SOURCE="$2"; shift 2 ;;
        --from-tarball) MODE="tarball"; SOURCE="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 --from-mount /mnt/windows | --from-tarball backup.tar.gz"
            exit 0 ;;
        *) die "Unknown arg: $1" ;;
    esac
done

[[ -z "$MODE" ]] && die "Specify --from-mount <path> or --from-tarball <path>"

# ── Auto-detect Windows partition ───────────────────────────────────────────
if [[ "$MODE" == "mount" && "$SOURCE" == "auto" ]]; then
    info "Auto-detecting Windows partition..."
    # Look for mounted NTFS with Users directory
    for mnt in /mnt/windows /mnt/c /media/*/Windows /run/media/*/Windows; do
        if [[ -d "$mnt/Users" ]]; then
            SOURCE="$mnt"
            ok "Found Windows at $SOURCE"
            break
        fi
    done
    [[ "$SOURCE" == "auto" ]] && die "Could not auto-detect Windows partition. Mount it first:
  sudo mkdir -p /mnt/windows
  sudo mount /dev/sdXN /mnt/windows -t ntfs3 -o ro"
fi

# ── Resolve source .claude directory ────────────────────────────────────────
if [[ "$MODE" == "mount" ]]; then
    # Find the Windows user directory
    WIN_USER=""
    for user_dir in "$SOURCE/Users/Ashtay2002" "$SOURCE/Users/"*; do
        if [[ -d "$user_dir/.claude" ]]; then
            WIN_USER="$user_dir"
            break
        fi
    done
    [[ -z "$WIN_USER" ]] && die "No .claude directory found under $SOURCE/Users/"
    SRC_CLAUDE="$WIN_USER/.claude"
    SRC_CLAUDEMD="$WIN_USER/CLAUDE.md"
    info "Source: $SRC_CLAUDE"

elif [[ "$MODE" == "tarball" ]]; then
    [[ -f "$SOURCE" ]] || die "Tarball not found: $SOURCE"
    info "Extracting tarball to temp dir..."
    TMPDIR=$(mktemp -d)
    tar xzf "$SOURCE" -C "$TMPDIR"
    SRC_CLAUDE="$TMPDIR/.claude"
    SRC_CLAUDEMD="$TMPDIR/CLAUDE.md"
    [[ -d "$SRC_CLAUDE" ]] || die "Tarball doesn't contain .claude directory"
    trap "rm -rf $TMPDIR" EXIT
fi

# ── Verify source ──────────────────────────────────────────────────────────
[[ -f "$SRC_CLAUDE/settings.json" ]] || warn "No settings.json found — partial migration"
info "Source verified. Starting migration..."

# ── Backup existing config if present ──────────────────────────────────────
if [[ -d "$CLAUDE_DIR" ]]; then
    BACKUP="$CLAUDE_DIR.backup-$(date +%Y%m%d-%H%M%S)"
    info "Backing up existing config to $BACKUP"
    mv "$CLAUDE_DIR" "$BACKUP"
fi
mkdir -p "$CLAUDE_DIR"

# ── Copy transferable directories ──────────────────────────────────────────
DIRS_TO_COPY=(
    "agents"
    "autonomous-kit"
    "commands"
    "get-shit-done"
    "hooks"
    "scripts"
    "mcp-bridge"
)

for dir in "${DIRS_TO_COPY[@]}"; do
    if [[ -d "$SRC_CLAUDE/$dir" ]]; then
        info "Copying $dir/"
        cp -r "$SRC_CLAUDE/$dir" "$CLAUDE_DIR/$dir"
        ok "$dir"
    else
        warn "Skipping $dir (not found)"
    fi
done

# ── Copy memory files ──────────────────────────────────────────────────────
info "Copying memory files..."
# Memory is stored under projects/<encoded-path>/memory/
# On Linux the path will be different, so we put it under a new project key
MEMORY_SRC=$(find "$SRC_CLAUDE/projects" -type d -name "memory" 2>/dev/null | head -1)
if [[ -n "$MEMORY_SRC" ]]; then
    # Create Linux-path project directory
    LINUX_PROJECT_KEY=$(echo "$HOME" | sed 's|/|--|g; s|^--||')
    LINUX_MEMORY_DIR="$CLAUDE_DIR/projects/$LINUX_PROJECT_KEY/memory"
    mkdir -p "$LINUX_MEMORY_DIR"
    cp "$MEMORY_SRC"/*.md "$LINUX_MEMORY_DIR/" 2>/dev/null
    ok "Memory files → $LINUX_MEMORY_DIR/"

    # Count what we got
    COUNT=$(ls "$LINUX_MEMORY_DIR"/*.md 2>/dev/null | wc -l)
    info "  Transferred $COUNT memory files"
else
    warn "No memory directory found in source"
fi

# ── Copy standalone files ──────────────────────────────────────────────────
for file in CLAUDE.md .credentials.json; do
    if [[ -f "$SRC_CLAUDE/$file" ]]; then
        cp "$SRC_CLAUDE/$file" "$CLAUDE_DIR/$file"
        ok "$file"
    fi
done

# Copy home-level CLAUDE.md
if [[ -f "$SRC_CLAUDEMD" ]]; then
    cp "$SRC_CLAUDEMD" "$HOME/CLAUDE.md"
    ok "~/CLAUDE.md (master instructions)"
fi

# ── Patch settings.json for Linux ──────────────────────────────────────────
info "Patching settings.json for Linux..."

if [[ -f "$SRC_CLAUDE/settings.json" ]]; then
    # Start with the original
    cp "$SRC_CLAUDE/settings.json" "$CLAUDE_DIR/settings.json"

    SETTINGS="$CLAUDE_DIR/settings.json"

    # Python does the heavy lifting for JSON manipulation
    python3 << 'PYEOF' "$SETTINGS" "$HOME"
import json, sys, re

settings_path = sys.argv[1]
home = sys.argv[2]

with open(settings_path, 'r') as f:
    settings = json.load(f)

# ── Path replacements ──────────────────────────────────────────────────
def fix_path(s):
    """Replace Windows paths with Linux equivalents."""
    if not isinstance(s, str):
        return s
    # C:/Users/Ashtay2002/ → $HOME/
    s = s.replace('C:/Users/Ashtay2002/', home + '/')
    s = s.replace('C:\\Users\\Ashtay2002\\', home + '/')
    s = s.replace('/c/Users/Ashtay2002/', home + '/')
    return s

def fix_paths_recursive(obj):
    if isinstance(obj, str):
        return fix_path(obj)
    elif isinstance(obj, list):
        return [fix_paths_recursive(item) for item in obj]
    elif isinstance(obj, dict):
        return {k: fix_paths_recursive(v) for k, v in obj.items()}
    return obj

# ── Replace PowerShell hooks with bash equivalents ─────────────────────
def patch_hooks(hooks_dict):
    if not isinstance(hooks_dict, dict):
        return hooks_dict

    for event_name, hook_list in hooks_dict.items():
        if not isinstance(hook_list, list):
            continue
        for hook_entry in hook_list:
            if not isinstance(hook_entry, dict) or 'hooks' not in hook_entry:
                continue
            new_hooks = []
            for hook in hook_entry['hooks']:
                cmd = hook.get('command', '')

                # Replace PowerShell peon-ping with bash equivalent
                if 'peon-ping' in cmd and 'powershell' in cmd.lower():
                    # Convert to bash notification (notify-send on Linux)
                    hook['command'] = f'bash "{home}/.claude/hooks/peon-ping/peon.sh" 2>/dev/null || true'

                # Replace powershell.exe references generically
                elif 'powershell.exe' in cmd.lower():
                    # Extract the script path and convert
                    ps_match = re.search(r'-File\s+"?([^"]+)"?', cmd)
                    if ps_match:
                        ps_path = fix_path(ps_match.group(1))
                        # Try to find a .sh equivalent
                        sh_path = re.sub(r'\.ps1$', '.sh', ps_path)
                        hook['command'] = f'bash "{sh_path}" 2>/dev/null || true'
                    else:
                        hook['command'] = 'true  # PowerShell hook removed (no Linux equivalent)'

                # Fix python3 (works on Linux, unlike MINGW64)
                elif 'python3' in cmd:
                    pass  # python3 works natively on Linux — no change needed

                # Fix generic paths in all commands
                hook['command'] = fix_path(hook.get('command', ''))
                new_hooks.append(hook)

            hook_entry['hooks'] = new_hooks

    return hooks_dict

# Apply fixes
settings = fix_paths_recursive(settings)
if 'hooks' in settings:
    settings['hooks'] = patch_hooks(settings['hooks'])

# Fix statusLine
if 'statusLine' in settings:
    settings['statusLine'] = fix_paths_recursive(settings['statusLine'])

with open(settings_path, 'w') as f:
    json.dump(settings, f, indent=2)

print(f"  Patched {settings_path}")
PYEOF

    ok "settings.json patched for Linux paths"
else
    warn "No settings.json to patch"
fi

# ── Patch CLAUDE.md for Linux ──────────────────────────────────────────────
if [[ -f "$HOME/CLAUDE.md" ]]; then
    info "Patching ~/CLAUDE.md for Linux environment..."
    sed -i \
        -e 's|MINGW64 / Git Bash (MSYS2) on Windows 10|CachyOS (Arch Linux) with KDE Plasma|g' \
        -e 's|MINGW64|CachyOS|g' \
        -e 's|NOT WSL2|Linux native|g' \
        -e 's|winget.*Use `npm`|`pacman` and `paru` for AUR. Also `npm`|g' \
        -e 's|python3.*NOT aliased.*Use `python`|`python3` works natively|g' \
        -e 's|Platform: Windows with MINGW64/Git Bash|Platform: CachyOS (Arch Linux) with KDE Plasma|g' \
        "$HOME/CLAUDE.md"
    ok "CLAUDE.md patched for CachyOS"
fi

# ── Patch memory MEMORY.md ─────────────────────────────────────────────────
LINUX_MEMORY="$CLAUDE_DIR/projects/$LINUX_PROJECT_KEY/memory/MEMORY.md"
if [[ -f "$LINUX_MEMORY" ]]; then
    info "Patching MEMORY.md environment references..."
    sed -i \
        -e 's|Windows 10 build 19045|CachyOS (Arch Linux) on same hardware|g' \
        "$LINUX_MEMORY"
    ok "MEMORY.md patched"
fi

# ── Create peon-ping bash equivalent ───────────────────────────────────────
info "Creating peon-ping bash equivalent..."
mkdir -p "$CLAUDE_DIR/hooks/peon-ping"
cat > "$CLAUDE_DIR/hooks/peon-ping/peon.sh" << 'PEON'
#!/bin/bash
# Peon-ping notification — Linux version (notify-send)
# Replaces PowerShell toast notification
if command -v notify-send &>/dev/null; then
    notify-send "Claude Code" "Task requires attention" -i dialog-information -t 5000
elif command -v kdialog &>/dev/null; then
    kdialog --passivepopup "Task requires attention" 5 --title "Claude Code"
fi
PEON
chmod +x "$CLAUDE_DIR/hooks/peon-ping/peon.sh"
ok "peon-ping.sh (notify-send/kdialog)"

# ── Rebuild mcp-bridge if present ──────────────────────────────────────────
if [[ -d "$CLAUDE_DIR/mcp-bridge" && -f "$CLAUDE_DIR/mcp-bridge/package.json" ]]; then
    info "Rebuilding mcp-bridge dependencies..."
    rm -rf "$CLAUDE_DIR/mcp-bridge/node_modules"
    (cd "$CLAUDE_DIR/mcp-bridge" && npm install --silent 2>&1 | tail -2)
    ok "mcp-bridge rebuilt"
fi

# ── Summary ────────────────────────────────────────────────────────────────
echo ""
echo -e "\e[1;37m━━━ MIGRATION COMPLETE ━━━\e[0m"
echo ""
echo "  Transferred:"
echo "    - agents/ ($(ls "$CLAUDE_DIR/agents/" 2>/dev/null | wc -l) agents)"
echo "    - commands/ ($(find "$CLAUDE_DIR/commands/" -name '*.md' 2>/dev/null | wc -l) commands)"
echo "    - memory/ ($COUNT memory files)"
echo "    - settings.json (patched for Linux)"
echo "    - hooks/ (PowerShell → bash)"
echo "    - ~/CLAUDE.md (patched for CachyOS)"
echo ""
echo -e "\e[1;33m  Remaining steps:\e[0m"
echo "    1. Run 'claude login' to authenticate (or credentials transferred)"
echo "    2. Verify: 'claude' and check settings load"
echo "    3. Test a slash command: /checkpoint or /plan"
echo ""

# ── Verify credentials ────────────────────────────────────────────────────
if [[ -f "$CLAUDE_DIR/.credentials.json" ]]; then
    ok "Credentials file found — may still need 'claude login' to refresh token"
else
    warn "No credentials — run 'claude login' to authenticate"
fi
