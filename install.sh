#!/bin/sh
# install.sh — installer and uninstaller for every-cli (Linux & macOS)
set -e

PREFIX="${PREFIX:-/usr/local}"
BIN_DIR="$PREFIX/bin"
DATA_DIR="$PREFIX/share/every-cli"
MAN_DIR="$PREFIX/share/man/man1"
BASH_COMP="$PREFIX/share/bash-completion/completions"
ZSH_COMP="$PREFIX/share/zsh/site-functions"
FISH_COMP="$PREFIX/share/fish/vendor_completions.d"

if [ "$1" = "--uninstall" ] || [ "$1" = "-u" ]; then
  echo "Uninstalling every-cli from $PREFIX..."
  rm -f "$BIN_DIR/every-cli"
  rm -rf "$DATA_DIR"
  rm -f "$MAN_DIR/every-cli.1"
  rm -f "$BASH_COMP/every-cli"
  rm -f "$ZSH_COMP/_every-cli"
  rm -f "$FISH_COMP/every-cli.fish"
  echo "every-cli uninstalled successfully."
  exit 0
fi

echo "Installing every-cli to $PREFIX..."

# Check dependencies
for dep in curl fzf mpv yt-dlp; do
  if ! command -v "$dep" >/dev/null 2>&1; then
    echo "Notice: '$dep' not found on PATH. Install it via your package manager."
  fi
done

# Install binary
mkdir -p "$BIN_DIR"
install -m 755 every-cli "$BIN_DIR/every-cli"

# Install libraries
mkdir -p "$DATA_DIR/lib/scrapers" "$DATA_DIR/lib/providers"
install -m 644 lib/core.sh "$DATA_DIR/lib/core.sh"
for s in lib/scrapers/*.sh; do
  install -m 644 "$s" "$DATA_DIR/lib/scrapers/"
done
for p in lib/providers/*.sh; do
  install -m 644 "$p" "$DATA_DIR/lib/providers/"
done

# Install manual page
if [ -f man/every-cli.1 ]; then
  mkdir -p "$MAN_DIR"
  install -m 644 man/every-cli.1 "$MAN_DIR/every-cli.1"
fi

# Install shell completions
if [ -f completions/every-cli.bash ]; then
  mkdir -p "$BASH_COMP" 2>/dev/null || true
  install -m 644 completions/every-cli.bash "$BASH_COMP/every-cli" 2>/dev/null || true
fi
if [ -f completions/every-cli.zsh ]; then
  mkdir -p "$ZSH_COMP" 2>/dev/null || true
  install -m 644 completions/every-cli.zsh "$ZSH_COMP/_every-cli" 2>/dev/null || true
fi
if [ -f completions/every-cli.fish ]; then
  mkdir -p "$FISH_COMP" 2>/dev/null || true
  install -m 644 completions/every-cli.fish "$FISH_COMP/every-cli.fish" 2>/dev/null || true
fi

echo "every-cli installed successfully to $BIN_DIR/every-cli"
echo "Run 'every-cli --help' or 'man every-cli' to get started."
