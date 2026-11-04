# Architecture

```
 ┌──────────────── macOS ─────────────────────────────────────────────┐
 │                                                                    │
 │  Launcher app / egw CLI ──► scripts/egw start ──► Android Emulator │
 │        │                                         (-no-window,      │
 │        ▼                                          -gpu host,       │
 │  egw-host game-view                               -grpc -grpc-use-jwt)
 │   ├─ RuntimeDiscovery: find the instance (discovery .ini + ps)     │
 │   ├─ StatusSession.validate: version, ports, owner, loopback       │
 │   ├─ SessionKey: in-memory ES256 key ─► public JWK in jwks dir     │
 │   ├─ StreamSpike.stream ◄── streamScreenshot (gRPC, 127.0.0.1)     │
 │   │     └─ MMAP fast path: frames land in a shared file            │
 │   ├─ FrameMailbox ─► Metal (CAMetalLayer) / CGImage layer          │
 │   ├─ InputCore (keys/mouse ─► contacts, joystick) ─► sendTouch     │
 │   └─ TextSender (setClipboard + Ctrl-V), AndroidKey (sendKey)      │
 └────────────────────────────────────────────────────────────────────┘
```

## Modules

| Target | Role |
| --- | --- |
| `InputCore` | Pure input logic: key/mouse events to touch contacts (IDs, holds, releases), the WASD joystick, mapping profiles. No AppKit, no gRPC; fully unit-tested. |
| `EGWHost` | The executable: CLI subcommands, launcher, game window, gRPC client, fast path, disk policy. |

## Finding and checking the emulator

The emulator writes `~/Library/Caches/TemporaryItems/avd/running/pid_<PID>.ini`.
`RuntimeDiscovery` reads only those files and the process table. A session
starts only if:

- exactly one live instance of the configured AVD exists;
- its `.ini` names that AVD under `<project>/.runtime/avd`, the configured gRPC
  port, JWT key directories, and Emulator `37.2.12.0`;
- the process command line contains `-avd <name>`, `-grpc <port>`,
  `-grpc-use-jwt` and `-gpu host`;
- the gRPC port listens on `127.0.0.1` only;
- the files are owned by the current user;
- there is enough free disk space.

These checks run again during the session; any change stops it.

## Authentication

With `-grpc-use-jwt` the emulator accepts ES256 JWTs whose public keys are in
its per-instance `jwks` directory. Its default access policy
(`emulator/lib/emulator_access.json`) lets the issuer
`gradle-utp-emulator-control` call the methods this app needs, when the
token carries an `aud` with the method names (`streamScreenshot`,
`sendTouch`, `sendKey`, `setClipboard`, `getStatus`). Per session:

1. Generate a P-256 key in memory (never written to disk).
2. Write only the public JWK to `jwks/<random>.jwk`, mode 0600.
3. Wait for the emulator to load it, then sign short-lived (120 s) tokens
   per request.
4. At the end, remove that one file and wait until the key is gone.

The access policy itself is never changed.

## Frames

- **gRPC path**: `streamScreenshot` with RGBA8888. Each message carries the
  pixels (about 3.7 MB at 1280×720) and becomes a `CGImage` off the main thread.
- **Fast path** (default): the client creates a private 0600 file, maps it,
  and passes `file://…` as `ImageTransport.MMAP`. The emulator writes pixels
  there and the stream carries only metadata. A `MTLBuffer` wraps the
  mapping without copying (`makeBuffer(bytesNoCopy:)`); a small shader
  rotates or flips it into a `CAMetalLayer` drawable.
- **Scheduling**: the receive task never waits for drawing. It replaces the
  newest frame in `FrameMailbox`. In the default `nosync3` mode (3 drawables,
  `displaySyncEnabled = false`), each frame is drawn on a background queue as
  soon as it arrives. The `standard`/`low` modes draw on the display link.
- The play report records fps, frame intervals, delivery latency,
  wait/present stage timings, superseded frames, CPU of both processes and
  the thermal state.

## Input

`InputReducer` turns key and mouse events into at most 5 touch contacts with
stable IDs. It holds a contact while its key is down, releases everything
when focus is lost or the window closes, and sends moves at most every 17 ms.
A binding maps a key to a point; the joystick maps WASD to a stick around a
center. `GameGeometry` converts window points to the emulator's display
coordinates and handles picture and stream rotation. Text goes through
`setClipboard` and an evdev Ctrl-V; Android keys go through `sendKey`.

## Disk policy

The AVD's data image only grows up to `disk.dataPartition.size`. The stop
line is "remaining growth + 8 GiB" and the warn line "+ 15 GiB". If the AVD
is unreadable, the lines are 20 / 27 GiB. Starting, playing and building
stop below the stop line. `egw clean` lists regenerable files: old app
bundles, build/test logs, old play reports and emulator logs, leftover frame
mappings, installer zips, and (with `--include-build`) `.build/arm64-apple-macosx`.
It moves them to the Trash only with `--apply` and a confirmation.
