#!/bin/sh
# Installs Crateyard.app into /Applications from the latest GitHub release, after checking its SHA-256.
# curl does not set macOS's quarantine flag, so the app opens without a Gatekeeper prompt.
set -eu

# Everything runs from main, called on the last line, so a download cut off mid-script runs nothing.
main() {
base="https://github.com/Malaydewangan09/crateyard/releases/latest/download"

[ "$(uname -s)" = Darwin ] || { echo "Crateyard runs on macOS only." >&2; exit 1; }
[ "$(uname -m)" = arm64 ] || { echo "Crateyard needs an Apple silicon Mac." >&2; exit 1; }
if pgrep -xq Crateyard; then
  echo "Crateyard is running. Quit it from the menu bar, then run this again." >&2
  exit 1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "Downloading Crateyard..."
curl -fsSL -o "$tmp/Crateyard.zip" "$base/Crateyard.zip"
curl -fsSL -o "$tmp/SHA256SUMS" "$base/SHA256SUMS"

expected=$(awk '$2 == "Crateyard.zip" { print $1 }' "$tmp/SHA256SUMS")
actual=$(shasum -a 256 "$tmp/Crateyard.zip" | awk '{ print $1 }')
if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
  echo "The download does not match its published checksum. Nothing was installed." >&2
  exit 1
fi

# The checksum only catches a broken download. With gh installed, also check the zip was built by this repo's release workflow.
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  if ! gh attestation verify "$tmp/Crateyard.zip" -R Malaydewangan09/crateyard >/dev/null; then
    echo "The download has no valid build attestation from Malaydewangan09/crateyard. Nothing was installed." >&2
    exit 1
  fi
  echo "Verified the build attestation."
fi

ditto -x -k "$tmp/Crateyard.zip" "$tmp/unpacked"
if [ ! -d "$tmp/unpacked/Crateyard.app" ]; then
  echo "The download has no Crateyard.app inside. Nothing was installed." >&2
  exit 1
fi
sudo=""
[ -w /Applications ] || sudo=sudo
$sudo rm -rf /Applications/Crateyard.app
$sudo ditto "$tmp/unpacked/Crateyard.app" /Applications/Crateyard.app

echo "Installed /Applications/Crateyard.app. Open it with: open -a Crateyard"
}

main "$@"
