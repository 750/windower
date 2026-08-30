#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"     # always build relative to the project/repo root

echo "Building windower (release)…"
swift build -c release

# Put the binary in the current working directory (the repo root) so the project
# is self-contained and easy to try locally. A Homebrew formula will do its own
# install to the formula's prefix, so we don't hardcode a system path here.
DEST="$(pwd)/windower"
cp .build/release/windower "$DEST"
chmod +x "$DEST"

echo
echo "Built: $DEST"
echo
echo "Try:"
echo "  ./windower list          # list on-screen windows"
echo "  ./windower focus Safari  # focus a window by text"
echo "  ./windower               # show the manual"
echo
echo "To put it on your PATH yourself (optional):"
echo "  ln -s \"$DEST\" /usr/local/bin/windower   # root, needs sudo"
echo "  ln -s \"$DEST\" \"$HOME/.local/bin/windower\"   # user-only, no sudo"
echo
echo "Permissions you'll want once (System Settings > Privacy & Security):"
echo "  • Accessibility       — required to focus a SPECIFIC window (and read titles"
echo "                          when Screen Recording is not granted)."
echo "  • Screen Recording    — optional; makes 'list' titles instant (fast path)."
echo
echo "The binary '$DEST' is a build artifact — add it to .gitignore, don't commit it."
echo "For a Homebrew tap, a formula would run 'swift build -c release' and install"
echo ".build/release/windower into its own prefix."
