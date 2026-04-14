#!/bin/sh
# Install egghead — a personal knowledge base with AI agents that live inside it
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/mwunsch/egghead/main/install.sh | sh
#
# Options (via environment):
#   VERSION=0.1.0    Install a specific version (default: latest)
#   INSTALL_DIR=...  Install location (default: ~/.local/bin)
#   MAN_DIR=...      Man page location (default: ~/.local/share/man)

set -e

REPO="mwunsch/egghead"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"
MAN_DIR="${MAN_DIR:-$HOME/.local/share/man}"

# --- Platform detection ---

OS="$(uname -s)"
case "$OS" in
  Linux)  OS="linux" ;;
  Darwin) OS="macos" ;;
  *) echo "error: unsupported OS: $OS" >&2; exit 1 ;;
esac

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64)         ARCH="x86_64" ;;
  aarch64|arm64)  ARCH="aarch64" ;;
  *) echo "error: unsupported architecture: $ARCH" >&2; exit 1 ;;
esac

# --- Version resolution ---

if [ -n "${VERSION:-}" ]; then
  TAG="v$VERSION"
else
  TAG="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
    | grep '"tag_name"' | cut -d'"' -f4)"
  if [ -z "$TAG" ]; then
    echo "error: could not determine latest version" >&2
    exit 1
  fi
fi
VERSION="${TAG#v}"

# --- Download ---

NAME="egghead-${ARCH}-${OS}"
URL="https://github.com/$REPO/releases/download/$TAG/$NAME.tar.gz"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

echo "Downloading egghead $VERSION for $OS/$ARCH..."
if ! curl -fsSL "$URL" -o "$TMPDIR/$NAME.tar.gz"; then
  echo "error: download failed. Check that version $VERSION exists for $OS/$ARCH" >&2
  echo "  $URL" >&2
  exit 1
fi

tar xzf "$TMPDIR/$NAME.tar.gz" -C "$TMPDIR"

# --- Install binary ---

mkdir -p "$INSTALL_DIR"
install -m 755 "$TMPDIR/$NAME/egghead" "$INSTALL_DIR/egghead"
echo "Installed egghead to $INSTALL_DIR/egghead"

# --- Install man pages ---

for page in "$TMPDIR/$NAME"/man/*; do
  [ -f "$page" ] || continue
  section="${page##*.}"
  dest="$MAN_DIR/man$section"
  mkdir -p "$dest"
  install -m 644 "$page" "$dest/$(basename "$page")"
done

# --- PATH check ---

case ":$PATH:" in
  *":$INSTALL_DIR:"*) ;;
  *)
    echo ""
    echo "Warning: $INSTALL_DIR is not in your PATH."
    echo "Add this to your shell profile:"
    echo "  export PATH=\"$INSTALL_DIR:\$PATH\""
    ;;
esac

echo ""
echo "Get started:"
echo "  egghead init    # First-time setup"
echo "  egghead         # Launch the TUI"
