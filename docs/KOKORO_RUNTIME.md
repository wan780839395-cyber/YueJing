# Chinese Kokoro: build input vs installed data

## Build host (never the phone)

The YueJing application target links static libraries from the official [v1.12.20 release](https://github.com/k2-fsa/sherpa-onnx/releases/tag/v1.12.20). Use **`sherpa-onnx-v1.12.20-ios.tar.bz2`**, not `ios-no-tts`. SHA-256, checked against both the GitHub asset digest and downloaded bytes: `1afdc4175326411522c575b6774a62b8fd37201cdb8a9850af2faff459b9b145`.

| In the archive under `build-ios/` | Actual link input |
| --- | --- |
| `sherpa-onnx.xcframework/<slice>/` | `libsherpa-onnx.a` and `Headers/sherpa-onnx/c-api/c-api.h` |
| `ios-onnxruntime/1.17.1/onnxruntime.xcframework/<slice>/` | `onnxruntime.a` (not a separate latest ORT) |

Both Info.plists identify `ios-arm64` for device and `ios-arm64_x86_64-simulator` for simulator. Mach-O members inspected: iOS arm64 min 13.0; simulator x86_64 min 13.0 and arm64 min 14.0. Both simulator architectures and the device archive define `SherpaOnnxCreateOfflineTts` and `SherpaOnnxOfflineTtsGenerateWithCallbackWithArg`. Do not use the macOS ORT slice for simulator or exclude arm64. App target remains iOS 16.6 / Swift 6.

Generate from `project.yml` normally with XcodeGen 2.46.0. The app-only pre-build phase uses Python 3 and curl, verifies the **whole compressed file before extraction**, and copies three named regular files into `$(DERIVED_FILE_DIR)/Kokoro-v1.12.20-$(PLATFORM_NAME)`. Xcode uses the declared outputs on incremental builds. Neither library is an embedded framework, Swift module, phone download or repo resource. `Sources/CKokoro/KokoroBridge.cpp` is compiled against the header from that very slice; its C interface and local module map hide sherpa struct layouts and C++ ABI from Swift. No precompiled Swift module or unchecked Sendable pointer is required.

For a disconnected build host, pre-stage the exact release tarball outside the checkout and set the **xcodebuild setting** `KOKORO_IOS_ARCHIVE=/absolute/path/to/sherpa-onnx-v1.12.20-ios.tar.bz2`. To check the preparation independently, e.g. on macOS:

```sh
python3 scripts/prepare_kokoro.py iphoneos "$TMPDIR/kokoro-device" --archive "$archive"
python3 scripts/prepare_kokoro.py iphonesimulator "$TMPDIR/kokoro-sim" --archive "$archive"
```

There is **no Package.swift at the v1.12.20 pin**. Newer [upstream master has a direct Swift package](https://github.com/k2-fsa/sherpa-onnx/blob/master/Package.swift) (static `sherpa-onnx` and shared `sherpa-onnx-shared`, ORT dependency). That's not a package for this tarball. Using the pinned prebuilt avoids changing the repo's exact two-package allowlist in `scripts/workflow_tools.py`; do not track master, add a guessed binary target, bypass `Package.resolved` checks, or substitute a no-op renderer on link failure.

## Pack and caller contract

Use the [official int8 data archive](https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/kokoro-int8-multi-lang-v1_1.tar.bz2), SHA-256 **`259c9c8bc906d6078e4e0570421885dabb68b539c2f970fcbb890a58eeaf3e9c`** (verified downloaded bytes). The caller/installer must authenticate the archive, extract safely into private storage, retain the complete `espeak-ng-data/` tree, and publish the directory atomically. Pass the **`kokoro-int8-multi-lang-v1_1/` directory itself**, not its parent. Do not pass imported arbitrary models: the renderer's file-size/readiness checks are not authentication and upstream native loaders are not a sandbox.

* `model.int8.onnx` is the actual 114,203,914-byte graph; `model.onnx` is accepted only as a local name for the same installed int8 bytes. Graph SHA-256 `05d793700b0b507f760c183c0e39bdd6a97b43d32fdc7bf7b54a5179f1b11222`.
* `voices.bin`, `tokens.txt`, `lexicon-zh.txt,lexicon-us-en.txt`, `espeak-ng-data/`; no separate jieba `dict_dir` at this runtime version. The [upstream v1.1-zh sample generator](https://github.com/k2-fsa/sherpa-onnx/blob/v1.12.20/scripts/kokoro/v1.1-zh/generate_samples.py) uses `phone-zh.fst,date-zh.fst,number-zh.fst` in that order. These are mandatory here, with full paths. No forced eSpeak language override.
* Fixed Mandarin voice **`zf_001` = sid 3**. The [original model card](https://huggingface.co/hexgrad/Kokoro-82M-v1.1-zh) demonstrates this voice; the [sherpa voice table generator](https://github.com/k2-fsa/sherpa-onnx/blob/v1.12.20/scripts/kokoro/v1.1-zh/generate_voices_bin.py) and the downloaded graph's speaker metadata put `af_maple,af_sol,bf_vale` before `zf_001`. Do not reuse sid numbering from Kokoro v1.0.

Keep one `KokoroRenderer` per reading service. Call `try await renderer.render(text:speed:directory:)` on short sentence chunks (at most 280 UTF-16 units and 840 UTF-8 bytes; speed 0.5–2). No suspension during native inference; concurrent calls on the actor serialize. Returns owned mono Float samples in [-1,1] at 24 kHz. Rejects nonfinite PCM; checks a 90-second cumulative budget per native sentence callback and before the Swift copy. This does not cap ORT working memory or interrupt a sentence in flight. `await renderer.reset()` before replacing/removing files at the same URL; reset queues behind an active render. Discard late audio when playback is cancelled. On pack/init/generation failure the caller must surface unavailability or explicitly use its system TTS fallback; renderer doesn't impersonate success. Data installation and playback/UI are outside this runtime change.

## Redistribution gate

Sherpa-onnx and the Kokoro model/pack top-level LICENSE are Apache-2.0; ONNX Runtime is MIT and includes third-party components. Those licenses **do not cover the entire linked application**. The tag's [iOS build recipe](https://github.com/k2-fsa/sherpa-onnx/blob/v1.12.20/build-ios.sh) merges, among other libraries, `libpiper_phonemize.a` and **`libespeak-ng.a`**. The pinned eSpeak NG fork is a GPLv3-family component (see [dependency pin](https://github.com/k2-fsa/sherpa-onnx/blob/v1.12.20/cmake/espeak-ng-for-piper.cmake)); the TTS-enabled archive actually defines `espeak_Initialize`. Static linking is not merely distributing separately licensed voice files. Downloading the data after install does not remove copyleft obligations on the executable.

**Do not redistribute an IPA on the strength of the Apache model card alone.** Review the combined-work and corresponding-source requirements, App Store terms/DRM, licenses and notices for the exact ORT, phonemizer, transitive libraries, lexicons, rules and eSpeak data. Supply the required texts/notices and source under compatible terms or obtain suitable alternative rights/implementation before distribution. This document is not a notice bundle or distribution clearance. A `no-tts` library is not a functionally equivalent workaround.

## Remaining Apple-host acceptance

Preparation, hashes, sliced headers/libraries and model layout were checked; not an iOS build or an acoustic test. With Xcode 16.4, generate the project and build scheme `YueJing` for `generic/platform=iOS Simulator` (Debug) and `generic/platform=iOS` (Release). Retain the normal project validation and unsigned dependency checks. With the verified pack installed, call render twice at the same URL with synthetic `你好，今天是2025年6月18号。`, check nonempty finite non-silent 24 kHz PCM, listen for Mandarin and number normalization, reset and reload. Exercise missing rules, invalid speed and oversized text. A passing link alone does not verify speech or iPhone memory use.
