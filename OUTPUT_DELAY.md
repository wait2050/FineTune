# FineTune: manual output-delay edition

This branch adds opt-in, per-output delay to FineTune (upstream base `2285279`, v1.9.0), with synchronized test playback and [microphone-based calibration](CALIBRATION.zh-CN.md). Acoustic calibration requires a wired/USB microphone that can hear both outputs; continuous acoustic drift correction is not implemented.

## Build and use

Requires the upstream Xcode/Swift build environment and macOS 15.4+ (the deployment target in the checked-out project).

```sh
./scripts/build-delay-edition.sh
open "build/FineTune Delay.app"
```

The local build registers `finetune-delay://` (leaving official `finetune://` links alone), has a separate bundle identifier, `com.finetuneapp.FineTune.Delay`, and stores settings in `~/Library/Application Support/FineTune Delay`. It does not install over `/Applications/FineTune.app` or read/write the official app's settings. Automatic official-release updates are disabled in this edition so they cannot replace the custom functionality. It refuses to open while the official app is running; quit the official app yourself before launching the local build. Use only one version at a time.

1. Open Settings → Audio → Output Synchronization.
2. Turn on **Manual Delay Compensation**. Off is the default.
3. In the app's output picker, select multiple available outputs (for example built-in speakers, USB headphones, and a Bluetooth speaker).
4. Leave the slowest device at **0 ms**. Add delay to each faster device until transients such as clicks or drum hits coincide. Example only: Bluetooth `0`, built-in `220`, USB headphones `205` ms.
5. Sliders and numeric fields accept 0–2000 ms, with 1 ms slider steps. Values are remembered by device UID, even when compensation is off or a device disconnects.

Edits apply while audio plays. Delay changes crossfade the read positions over 10 ms; enabling/disabling the mode briefly restarts routes. To return to the original routing architecture, turn the mode off. When using the local edition's isolated settings for the first time, recreate your preferred app routes and volumes there.

Bluetooth buffering can change after reconnects, codec/profile changes, and pause/resume. Recheck by ear. Manual offsets do not measure or continuously correct acoustic drift. Delaying audio also increases video lip-sync lag; this feature is best suited to music playback. Only outputs macOS exposes as usable devices can participate.

## Implementation

- With the mode **off**, `OutputDelayTapController` delegates to one unmodified-route `ProcessTapController`, preserving the existing multi-output aggregate and device-switch crossfade.
- With the mode **on**, it creates one existing controller per selected output. This keeps the original CoreAudio setup, preferred-channel mapping, gain, EQ, limiter, and rate-change recovery. One output can wait while another plays immediately. Independent taps cost additional CPU/memory compared with a stacked aggregate.
- Each IOProc closure owns its preallocated delay history and scratch input list. Primary and secondary callbacks never share sample history. Teardown keeps that memory alive until CoreAudio releases the callback.
- Delay targets are lock-free atomic values shared by device UID. Only the audio thread mutates a history; no allocation, locks, logging, HAL queries, or settings access occurs in its sample loop.
- Delay is applied **before** gain/EQ/gating. Volume, limiter, and mute remain effective immediately. Mute and stale/force-silenced callbacks invalidate history, preventing pre-mute audio from resurfacing. The soft-start gate follows delayed audio, including its tail.
- Route changes are serialized. Unchanged outputs keep their existing controllers/history when another output joins or leaves. Mode changes prepare muted replacements first, so a setup error keeps the old route alive. The engine rolls back the requested mode if setup fails.
- Missing keys in older settings decode to mode off and zero delays. No migration rewrites existing app settings.
- The local edition uses a distinct aggregate-name prefix for startup cleanup. Hosted unit tests skip audio capture, orphan cleanup, permissions, hotkeys, and use temporary settings.

The extension inherits FineTune's existing processing choices: for a multi-output app, its app EQ and the primary output's AutoEQ/loudness state are shared across outputs. It does not add independent per-output EQ or change the existing multi-output software-volume policy. Layouts requiring more than 64 MiB of delay/scratch memory per IOProc are rejected instead of allocating unbounded memory.

## Verification

```sh
xcodebuild test -project FineTune.xcodeproj -scheme FineTune \
  -configuration Debug -derivedDataPath build/DerivedData \
  -IDEPackageEnablePrebuilts=NO \
  -skip-testing:FineTuneUITests \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO \
  PRODUCT_BUNDLE_IDENTIFIER=com.finetuneapp.FineTune.DelayTestHost \
  FINETUNE_URL_SCHEME=finetune-delay-test \
  'OTHER_SWIFT_FLAGS=$(inherited) -D ENABLE_TCC_SPI -D FINETUNE_TEST_HOST'
```

`FINETUNE_TEST_HOST` prevents a hosted test run from controlling the audio devices of a concurrently running official FineTune. It must not be used for a runnable application build.

The added tests cover impulse offsets at 44.1/48/96 kHz, exact zero-delay passthrough, maximum delay/ring wrap, channel separation, smooth edits, history reset, settings compatibility, original-route delegation, live UID controls, preserving existing outputs on joins, and failure cleanup.

A real three-output acoustic check is still necessary before calling a device combination qualified. Check start/pause/resume, app and device mute/volume, EQ/boost, device disconnect/reconnect, Bluetooth call-profile/sample-rate transitions, sleep/wake, and a 30-minute music session. Automated tests do not establish hardware synchronization precision.

### Local verification record — 2026-11-03

- Final regression: **774 passed, 0 failed, 0 skipped**, including 16 new output-delay tests.
- Result bundle: `build/OutputDelayRegressionFinal.xcresult`; compact summary: `build/verification-summary.json`.
- Release build succeeded; local artifact is arm64 and requires macOS 15.4+.
- `codesign --verify --deep --strict` passed; ZIP integrity passed.
- Bundle identifier and URL scheme were checked against the installed official build and are distinct.
- No physical three-output acoustic test was performed. The installed official FineTune remained running throughout verification.

### Launch packaging fix — 2026-11-03

The initial ad-hoc Release package passed static signature verification but failed at launch: hardened-runtime library validation rejected the vendor-signed Sparkle framework because its Team ID differs from the ad-hoc executable. The local build script now sets `ENABLE_HARDENED_RUNTIME=NO` for this ad-hoc edition only. No machine-wide security settings or upstream build defaults were changed.

The rebuilt application was actually launched, remained running, and its Settings → Audio screen was verified through the native accessibility tree, including the independent delay fields for the built-in speaker, monitor, and AirPods. The ZIP was regenerated and checked. This validates application startup and UI availability, not acoustic synchronization.

### Fine adjustment UI

Output Synchronization is now the first section in Audio settings. Each device card combines a native numeric field, continuous slider with integer-ms binding, reset, and −50/−10/+10/+50 ms buttons. The numeric field's AppKit editing delegate handles Left/Right while the field editor is active: 1 ms normally, 10 with Shift, 50 with Option. Command/Control combinations retain their native behavior. No global key monitor is installed. The native slider omits tick marks to prevent the previous 2001-tick black stripe. Five new tests cover adjustment bounds, modifier rules, actual text-editor updates, invalid drafts and preserved editing shortcuts; final regression: 779 passed.

The device cards were additionally rendered offscreen in native AppKit/SwiftUI at the actual settings content width in light and dark appearances; the layout test passed, and both images were inspected for clipping, legibility and slider artifacts. Render fixtures are previews, not live device configurations. The running menu-bar app could not be reconnected through the UI automation bridge after restart; keyboard behavior was verified in the native field-editor unit tests rather than through synthetic keystrokes in the live app.

### Simplified Chinese edition

The fork includes standard String Catalogs with 379 UI entries plus localized permission descriptions. Runtime-only labels are localized at presentation boundaries; raw settings/UIDs and user preset names remain unchanged. English remains the development language and fallback. The compiled Chinese/English resources and substitution tokens are tested; local regression now passes 808 tests, including independent live test levels, the microphone callback on a background executor and filtering temporary AVAudioEngine aggregates. See `UPSTREAM_SYNC.zh-CN.md` for the public fork's review-based upstream synchronization and release pipeline.
