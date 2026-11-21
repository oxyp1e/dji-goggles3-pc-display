#!/bin/zsh
# One-time setup on a Mac (Apple Silicon). Installs tools, downloads the release files
# and installs the natartos mods with Eyepiece onto DJI Goggles 3.
set -e
cd "$(dirname "$0")"
REPO=suhocki/dji-goggles3-pc-display
TAG=${TAG:-v1.0}
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH

command -v brew >/dev/null || { echo "Install Homebrew first: https://brew.sh"; exit 1; }
command -v swiftc >/dev/null || { echo "Install Xcode Command Line Tools first: xcode-select --install"; exit 1; }
command -v ffmpeg >/dev/null || brew install ffmpeg
command -v adb >/dev/null || brew install --cask android-platform-tools

echo "Downloading release $TAG..."
mkdir -p bin dist
base=https://github.com/$REPO/releases/download/$TAG
curl -fL -o bin/toolya "$base/toolya-macos-arm64"
curl -fL -o bin/sckcap "$base/sckcap-macos-arm64"
curl -fL -o dist.tar.gz "$base/natartos-eyepiece-dist.tar.gz"
tar -xzf dist.tar.gz -C dist && rm dist.tar.gz
swiftc -O -o bin/sckenc scripts/sckenc/main.swift
chmod +x bin/toolya bin/sckcap goggles.command

# toolya telemetry off
mkdir -p ~/.config/toolya && echo '{"enabled": false, "devices": []}' > ~/.config/toolya/telemetry.json

serial() { adb devices -l 2>/dev/null | awk '/e3t_zv902/{print $1; exit}'; }
S=$(serial)
if [ -z "$S" ]; then
  echo "Turn the goggles on and plug them into the Mac with a USB-C DATA cable. Press Enter."; read
  ./bin/toolya adb --yes --no-telemetry
  echo ">>> Unplug the USB cable from the Mac and plug it back in (click Allow if asked)."
  for i in {1..120}; do sleep 1; S=$(serial); [ -n "$S" ] && break; done
  [ -z "$S" ] && { echo "Goggles not found in adb mode."; exit 1; }
fi
export NATARTOS_ADB_HOST=127.0.0.1:5037 NATARTOS_ADB_SERIAL=$S
./bin/toolya natartos install --local dist --mods overlay,popen,menu,stream,zuim_eyepiece --yes
echo
echo "Done. Next time just double-click goggles.command."
echo "macOS will ask to allow Screen Recording for Terminal on the first stream: allow it, then run goggles.command again."
