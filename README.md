# emu-gamewindow-mac

A small, native macOS "game window" for the **official Android Emulator** on
Apple Silicon: the emulator runs headless, and this app shows its screen in
its own window and turns your keyboard and mouse into multi-touch, like the
key mapping of desktop Android players, without installing anything inside
Android.

[繁體中文說明](README.zh-TW.md)

- **Frames**: gRPC `streamScreenshot` from the emulator. A fast path shares
  each frame through shared memory (MMAP) and draws it with Metal; on an
  M3 MacBook Air it keeps up with 60 fps games at about 5% CPU for the window.
- **Input**: left click and bound keys become touches through gRPC
  `sendTouch` (up to 5 at once), WASD can drive a virtual joystick. Bindings
  are edited inside the window (Cmd-E) and can be saved as named profiles.
- **Window**: aspect-fit resize, full screen, rotate, screenshot, Android
  Back/Home/Recents/volume buttons, and typing (including CJK) through the guest
  clipboard (Cmd-T).
- **Daily use**: a launcher app (start, play, shut down) and the `egw` CLI.
- **No ADB, root or guest agent.** USB debugging can stay OFF. The app needs
  no macOS privacy permission (no Accessibility, no Screen Recording).

> **Status**: personal project, tested on one Mac (MacBook Air M3, macOS 27)
> with Android Emulator 37.2.12 and an API 35 Google Play ARM64 image. The UI
> text is currently Traditional Chinese. Expect rough edges.

## Use responsibly

This tool only uses the emulator's public gRPC control API. It does not read
or modify any app's memory or files. Some games forbid emulators or input
tools in their terms of service; **you are responsible for following the
terms of whatever you run.** This project is not affiliated with Google or any
game publisher.

## Requirements

- Apple Silicon Mac, macOS 15 or later
- Xcode or the Command Line Tools with Swift 6.2
- Python 3 (ships with the Command Line Tools)
- Java 17, only for creating the AVD (`avdmanager`)
- Android Emulator **37.2.12** exactly: `egw-host` refuses other versions
  because the gRPC/JWT and shared-memory behaviour it relies on was verified
  there (`scripts/setup-runtime.sh` installs it)
- About 40 GB free disk space (SDK, system image, a 24 GiB AVD data partition)

## Quick start

```bash
git clone https://github.com/DraganLegend/emu-gamewindow-mac.git && cd emu-gamewindow-mac
cp egw.config.example.json egw.config.json && chmod 600 egw.config.json
scripts/setup-runtime.sh        # Android tools, Emulator 37.2.12, API 35 image (downloads from Google)
scripts/create-avd.sh           # 1280x720 landscape AVD named in egw.config.json
scripts/egw build               # first build downloads the Swift packages
scripts/egw start --window      # first boot: sign in to Google Play, install your app,
                                # and turn USB debugging OFF if you enabled it
scripts/egw play                # open the game window
scripts/egw stop                # quick shutdown (one SIGTERM)
```

After the first boot you can leave the emulator window hidden (`egw start`).
To get the launcher app:

```bash
scripts/egw app                 # packages .runtime/state/app/<appName>.app
scripts/egw install             # copies it to /Applications (find it with Spotlight)
```

## In the game window

| Key | Action |
| --- | --- |
| Left click / drag | touch |
| Cmd-E | edit bindings: click a spot, press a key; Cmd-J places a WASD joystick, Cmd-[ / Cmd-] resize it |
| Cmd-T | type text into Android (sent through the clipboard) |
| Cmd-R | rotate the picture 90° |
| Cmd-S | screenshot to `.runtime/screenshots` and the clipboard |
| Ctrl-Cmd-F | full screen |
| Cmd-Q | end playing (releases all touches first) |

## `egw` commands

| Command | What it does |
| --- | --- |
| `egw status` | emulator state from its discovery files (no key, no RPC) |
| `egw start [--audio] [--window]` | start the AVD; the emulator window is hidden unless `--window` |
| `egw play [--minutes N] [--present MODE] [--no-fast-path]` | open the game window; asks you to confirm USB debugging is OFF |
| `egw stop [--android]` | one SIGTERM and wait (default), or press the Android power key |
| `egw space` / `egw clean [--apply]` | disk overview / move old logs, reports and builds to the Trash |
| `egw build` / `egw app` / `egw install` | build, package, install to /Applications |

## Configuration

`egw.config.json` (owner-only, ignored by git) holds the machine-specific
values; every key is optional:

| Key | Default | Meaning |
| --- | --- | --- |
| `avd` | `egw_api35_arm64` | AVD name |
| `grpcPort` | 8554 | emulator gRPC port (`-grpc`) |
| `consolePort` | 5554 | emulator console port (`-ports`, even number) |
| `bundleIdentifier` | `local.egw-launcher` | bundle ID of the packaged app |
| `appName` | `EmuGameWindow` | app and window name |

If the file is unsafe (writable by others) or a value is invalid, the whole
file is ignored and the defaults are used.

## Safety rails

- Talks to the emulator only on `127.0.0.1`, after checking the discovery
  file, the process command line, the listening socket, the emulator version
  and file ownership.
- Each session creates a short-lived ES256 key in memory, registers only its
  public key with the emulator, and revokes it at the end.
- Never force-kills the emulator, never deletes files permanently, never
  empties the Trash. Stops below a free-space line derived from how much the
  AVD can still grow.

See [docs/architecture.md](docs/architecture.md) for how it works.

## Development

```bash
python3 -I scripts/build.py test          # Swift Testing suites
python3 -I scripts/test_space_policy.py   # disk thresholds (Python side)
```

## License

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
