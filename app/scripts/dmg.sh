#!/bin/sh
# Builds dist/Crateyard.dmg: Crateyard.app next to an Applications link, the usual drag-to-install layout.
set -eu
cd "$(dirname "$0")/.."
./scripts/bundle.sh
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
cp -R dist/Crateyard.app "$stage/"
ln -s /Applications "$stage/Applications"
hdiutil create -volname Crateyard -srcfolder "$stage" -ov -format UDZO dist/Crateyard.dmg >/dev/null
echo "dist/Crateyard.dmg"
