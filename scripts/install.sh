#!/usr/bin/env bash
# Symlinks cc-up/cc-remote/cc-switch into ~/.local/bin (already on PATH by
# default on Ubuntu) so they're runnable as bare commands from any
# directory -- no `cd` into this repo or `./scripts/` prefix needed.
#
# Usage: ./scripts/install.sh
set -euo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
REPO_DIR="$(cd "$(dirname "$SCRIPT_PATH")/.." && pwd)"
BIN_DIR="${HOME}/.local/bin"

mkdir -p "$BIN_DIR"

for name in claude-nim cc-up cc-remote cc-switch; do
  ln -sf "$REPO_DIR/scripts/${name}.sh" "$BIN_DIR/$name"
  echo "INFO: linked $BIN_DIR/$name -> $REPO_DIR/scripts/${name}.sh" >&2
done

case ":${PATH}:" in
  *":${BIN_DIR}:"*) ;;
  *)
    echo "WARN: $BIN_DIR is not on your PATH. Add this to ~/.bashrc (or ~/.zshrc) and restart your shell:" >&2
    echo "  export PATH=\"\$HOME/.local/bin:\$PATH\"" >&2
    ;;
esac

echo "INFO: done. Try: cc-up demo glm" >&2
