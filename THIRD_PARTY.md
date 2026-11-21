# Third-party files in the release

The release assets contain binaries built from AGPL-3.0 projects. Corresponding sources:

| Asset | Source |
|---|---|
| `toolya-macos-arm64` | [grom-labs/toolya @ 62ad6ab](https://github.com/grom-labs/toolya/tree/62ad6ab50431ee711fc8c3356bfe6cfcd58458cf) + [toolya-serial.patch](patches/toolya-serial.patch) (pick the adb device by serial). Built with `cargo build --release -p toolya`. |
| `natartos-eyepiece-dist.tar.gz` | GitHub Actions build of [natartos PR #5 @ f51ba1d](https://github.com/grom-labs/natartos/tree/f51ba1de3c288e4bd931928750f281b464577c9e), with `hook_overlay.so` and `inject.sh` from the build of [PR #4 @ 1229cb2](https://github.com/grom-labs/natartos/tree/1229cb21b8ae450e41d8788baf88e835f971e825). `manifest.json` hashes updated, `dm_noverity` removed. |

Licenses: [toolya LICENSE](https://github.com/grom-labs/toolya/blob/main/LICENSE), [natartos LICENSE](https://github.com/grom-labs/natartos/blob/main/LICENSE).
`sckcap-macos-arm64` is built from `scripts/sckcap/main.swift` in this repo (MIT).
