#!/usr/bin/env bash
#
# install.sh - local installer/uninstaller for update-anything.sh.
#
# Copies update-anything.sh next to this installer into a bin directory on
# PATH, plus shell completions into whichever completion directories are
# actually detected (bash-completion, zsh $fpath dir, fish). No network
# access, no remote URL: this only works against a local checkout/copy of
# the project. (A 'curl | bash' remote installer can be added once this
# project has a real public repository to fetch from -- fabricating that
# URL ahead of time would just be a dead link.)
#
# Usage:
#   ./install.sh              install the binary + any detected completions
#   ./install.sh --uninstall  remove them again

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${SCRIPT_DIR}/update-anything.sh"
DEST_DIR="${PREFIX:-$HOME/.local/bin}"
DEST="${DEST_DIR}/update-anything"

# Candidate completion install paths, one per shell. Kept as a flat list
# (not arrays keyed by shell) so uninstall can just iterate and check each
# path directly, without re-deriving "is this shell installed" logic.
BASH_COMPLETION_DEST="$HOME/.local/share/bash-completion/completions/update-anything"
ZSH_COMPLETION_DEST=""
FISH_COMPLETION_DEST="$HOME/.config/fish/completions/update-anything.fish"

find_zsh_completion_dir() {
    local d
    for d in "$HOME/.zsh/completions" "$HOME/.zsh/completion" "$HOME/.config/zsh/completions"; do
        [[ -d "$d" ]] && { echo "$d"; return; }
    done
}
ZSH_COMPLETION_DEST="$(find_zsh_completion_dir)"
[[ -n "$ZSH_COMPLETION_DEST" ]] && ZSH_COMPLETION_DEST="${ZSH_COMPLETION_DEST}/_update-anything"

uninstall() {
    if [[ -f "$DEST" ]]; then
        rm -f "$DEST"
        echo "[OK] Removed: $DEST"
    else
        echo "[!] $DEST is not installed."
    fi

    local f
    for f in "$BASH_COMPLETION_DEST" "$ZSH_COMPLETION_DEST" "$FISH_COMPLETION_DEST" \
             "$HOME/.zsh/completions/_update-anything" "$HOME/.zsh/completion/_update-anything" \
             "$HOME/.config/zsh/completions/_update-anything"; do
        [[ -n "$f" && -f "$f" ]] && { rm -f "$f"; echo "[OK] Removed: $f"; }
    done
    exit 0
}

[[ "${1:-}" == "--uninstall" ]] && uninstall

if [[ ! -f "$SRC" ]]; then
    echo "[ERROR] update-anything.sh not found next to install.sh ($SRC)" >&2
    exit 1
fi

mkdir -p "$DEST_DIR"
cp "$SRC" "$DEST"
chmod +x "$DEST"
echo "[OK] Installed: $DEST"

case ":$PATH:" in
    *":$DEST_DIR:"*)
        echo "[OK] $DEST_DIR is already on your PATH. Run: update-anything --help"
        ;;
    *)
        echo "[!] $DEST_DIR is not on your PATH."
        echo "    Add it in your shell's startup file, e.g.:"
        echo "      bash/zsh: export PATH=\"$DEST_DIR:\$PATH\""
        echo "      fish:     fish_add_path $DEST_DIR"
        ;;
esac

# --- Shell completions: only installed into directories that already
# indicate the shell is in use (an existing zsh $fpath dir) or that are
# safe/standard to create on demand (bash-completion, fish). Nothing is
# assumed present that wasn't actually detected. ---

installed_any_completion=0

if [[ -d /usr/share/bash-completion || -d "$(dirname "$BASH_COMPLETION_DEST")" ]]; then
    mkdir -p "$(dirname "$BASH_COMPLETION_DEST")"
    cp "${SCRIPT_DIR}/completions/update-anything.bash" "$BASH_COMPLETION_DEST"
    echo "[OK] Bash completion installed: $BASH_COMPLETION_DEST"
    installed_any_completion=1
fi

if [[ -n "$ZSH_COMPLETION_DEST" ]]; then
    cp "${SCRIPT_DIR}/completions/_update-anything" "$ZSH_COMPLETION_DEST"
    echo "[OK] Zsh completion installed: $ZSH_COMPLETION_DEST (restart your shell or run 'compinit')"
    installed_any_completion=1
fi

if command -v fish >/dev/null 2>&1 || [[ -d "$HOME/.config/fish" ]]; then
    mkdir -p "$(dirname "$FISH_COMPLETION_DEST")"
    cp "${SCRIPT_DIR}/completions/update-anything.fish" "$FISH_COMPLETION_DEST"
    echo "[OK] Fish completion installed: $FISH_COMPLETION_DEST"
    installed_any_completion=1
fi

if [[ "$installed_any_completion" -eq 0 ]]; then
    echo "[*] No known shell-completion directory detected; skipping (see completions/ to copy one manually)."
fi
