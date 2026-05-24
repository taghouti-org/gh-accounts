#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<USAGE
Usage: $0 [--dest DIR]

Create a symlink to gh-accounts.sh in a bin directory.

Options:
    --dest DIR   Directory where the symlink will be created (default: ./bin)
    -h, --help   Show this help and exit
USAGE
}

BIN_DIR="$(pwd)/bin"
SCRIPT="$(pwd)/gh-accounts.sh"

while [[ ${1:-} != "" ]]; do
    case "$1" in
        --dest)
            shift
            BIN_DIR="$1"
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage
            exit 2
            ;;
    esac
    shift
done

mkdir -p "$BIN_DIR"

# Ensure script is executable
if [ -f "$SCRIPT" ]; then
    chmod +x "$SCRIPT" || true
fi

LINK="$BIN_DIR/gh-accounts"
if [ -e "$LINK" ] || [ -L "$LINK" ]; then
    echo "Removing existing link: $LINK"
    rm -f "$LINK"
fi

ln -s "$SCRIPT" "$LINK"
echo "Symlink created: $LINK -> $SCRIPT"
echo "Add $BIN_DIR to your PATH to use 'gh-accounts' from anywhere."
