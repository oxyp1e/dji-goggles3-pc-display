#!/bin/zsh
# Daily start: double-click this file. It roots the goggles if needed, starts the mods
# and streams the Mac screen to the goggles. Close the window or press Back on the goggles to stop.
cd "$(dirname "$0")"
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
TOOLYA=./bin/toolya

serial() { adb devices -l 2>/dev/null | awk '/e3t_zv902/{print $1; exit}'; }

S=$(serial)
if [ -z "$S" ]; then
  echo "Enabling adb/root on the goggles (turn them on and plug the USB cable into the Mac)..."
  $TOOLYA adb --yes --no-telemetry || { echo "Failed. Are the goggles on and connected with a data cable?"; read; exit 1; }
  echo
  echo ">>> Now UNPLUG the USB cable from the Mac and PLUG IT BACK IN."
  echo ">>> If macOS asks to allow the accessory, click Allow."
  for i in {1..120}; do sleep 1; S=$(serial); [ -n "$S" ] && break; done
  [ -z "$S" ] && { echo "Goggles did not show up in adb mode. Try again."; read; exit 1; }
fi
echo "Goggles: $S"
export NATARTOS_ADB_HOST=127.0.0.1:5037 NATARTOS_ADB_SERIAL=$S EYEPIECE_SERIAL=$S

if ! adb -s $S shell 'grep -q natartos_loader /proc/$(pidof dji_glasses)/maps' 2>/dev/null; then
  echo "Starting mods (the goggles screen will blink)..."
  $TOOLYA natartos start || { echo "Mod start failed."; read; exit 1; }
  sleep 6
fi

echo "Streaming. Press Back on the goggles or close this window to stop."
python3 -I -u scripts/eyepiece.py --start-bridge --bridge-opts=-b 2>&1 | grep --line-buffered -v -E 'WARNING|objc|DUSS'
