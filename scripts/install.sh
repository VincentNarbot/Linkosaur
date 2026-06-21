#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
SOURCE="$ROOT/dist/Linkosaur.app"
DESTINATION="$HOME/Applications/Linkosaur.app"

if [[ ! -d "$SOURCE" ]]; then
    "$ROOT/scripts/build.sh"
fi

mkdir -p "$HOME/Applications"
rm -rf "$DESTINATION"
cp -R "$SOURCE" "$DESTINATION"
open "$DESTINATION"

echo "Installed to $DESTINATION"
