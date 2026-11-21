# DJI Goggles 3 as a PC display (Mac)

Stream your Mac screen to DJI Goggles 3 over the USB cable at 100 fps with about 10 ms from send to screen.
Good for FPV simulators, videos, or just a big private screen.

How it works: the Mac captures the screen with ScreenCaptureKit, encodes it with x264 (low-latency settings)
and sends it over adb to the goggles. On the goggles, the Eyepiece bridge from
[natartos](https://github.com/grom-labs/natartos) decodes it with the hardware video decoder and puts it straight
on the display. Root access comes from [toolya](https://github.com/grom-labs/toolya).

Tested: DJI Goggles 3, firmware 01.00.0900, MacBook Pro (Apple Silicon), macOS 15.

| | Result |
|---|---|
| Frame rate | 96-101 fps (the goggles panel runs at 100 Hz) |
| Send to screen | 8-10 ms |
| Decode on goggles | ~3 ms |

## Risks, read first

- This roots your goggles. It likely breaks DJI's terms. DJI could void the warranty or block your DJI account.
- Root and mods last only until the goggles reboot. After a reboot they are stock again.
- Never write anything to `/system` on the goggles. A changed `/system` bricks them on the next boot, and there is
  no known fix. These scripts never touch `/system`. Mod files go only to `/vendor/natartos/` and `/data/local/tmp/`.
- Your own goggles only. No warranty.

## What you need

- DJI Goggles 3 (firmware 01.00.0900 to 01.00.1600 are known to work with toolya)
- Mac with Apple Silicon and [Homebrew](https://brew.sh)
- A USB-C **data** cable. Many cables only charge. If the Mac does not see the goggles, try another cable.

## One-time install

```sh
git clone https://github.com/suhocki/dji-goggles3-pc-display
cd dji-goggles3-pc-display
./install.sh
```

It installs ffmpeg and adb, downloads the release files, roots the goggles and installs the mods.
When it asks, unplug the USB cable from the Mac and plug it back in, and click Allow if macOS asks
about the accessory. This replug is needed on macOS every time root is enabled.

On the first stream macOS asks to allow Screen Recording for Terminal. Allow it, close Terminal and start again.

## Every day

1. Turn the goggles on. Plug them into the Mac.
2. Double-click `goggles.command`.
3. If the goggles were rebooted since last time, it says "unplug and plug back in". Do it.
4. The goggles screen blinks once (mods start), then you see the Mac screen.

Stop: short press **Back** on the goggles, or close the Terminal window.

Turn off: stop the stream, then turn the goggles off with the power button as usual. Everything is reset to stock.
Next time just start again from step 1.

The goggles get warm when used for a long time, same as when flying. Turn them off when you do not use them.

## Tips

- The goggles show exactly 1920x1080. A 16:10 Mac screen gets black bars on the sides. For a full picture,
  set the Mac display to a 16:9 resolution, or use a 16:9 external display.
- `python3 scripts/eyepiece.py --start-bridge --bridge-opts=-b --screen 1` streams the second display.
- `--fps 60` if the Mac is too slow for 100 fps.

## Remove everything

```sh
export NATARTOS_ADB_HOST=127.0.0.1:5037 NATARTOS_ADB_SERIAL=$(adb devices -l | awk '/e3t_zv902/{print $1}')
./bin/toolya natartos uninstall --yes
```

Then reboot the goggles.

## What we learned (why it is fast)

- ffmpeg's avfoundation screen capture gives only ~20 fps on a Retina Mac. `bin/sckcap` uses ScreenCaptureKit
  and gets 60-120 fps, scaled on the GPU.
- The Mac hardware encoder (VideoToolbox through ffmpeg) holds ~110 ms of frames. x264 `ultrafast` + `zerolatency`
  with one slice per frame takes ~7-12 ms. With many slices the goggles showed a milky screen.
- The goggles panel is 100 Hz. 60 fps looks jerky on it (frames last 10, 20 or 30 ms). 100 fps is smooth.
- On firmware 0900 the overlay from natartos v0.1.0 cannot hide the goggles UI, so the video sits under an old frame.
  The release uses the overlay from natartos PR #4, which can.

## Credits and licenses

- [toolya](https://github.com/grom-labs/toolya) and [natartos](https://github.com/grom-labs/natartos) by grom-labs.
- Eyepiece bridge by zuim ([natartos PR #5](https://github.com/grom-labs/natartos/pull/5)), overlay fix from
  [PR #4](https://github.com/grom-labs/natartos/pull/4).
- The release files built from those projects are AGPL-3.0. Sources: see [THIRD_PARTY.md](THIRD_PARTY.md).
- Code in this repo (scripts, sckcap): MIT, see [LICENSE](LICENSE).

Not affiliated with DJI.
