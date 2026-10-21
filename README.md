# Plume

> Repository folder may still be named `ai-rekord` — the product is **Plume**.

Native **macOS** app (SwiftUI) that records **system audio + microphone** during meetings using Apple's **ScreenCaptureKit**, with optional **on-device** transcription via Apple's **Speech framework**. No virtual audio drivers, no cloud.

## Features

- Record system audio + microphone mixed into M4A or WAV
- Menu bar controls and floating recording pill
- Recordings library with playback, rename, delete
- Speaker diarization — transcripts are labeled per speaker, and voices are remembered across meetings (all on-device)
- Local transcription (Apple Speech framework) — audio and text stay on your Mac
- Themes: system / light / dark

## Requirements

- macOS **26.0+**, Apple Silicon (arm64)
- **Xcode 26+** (full app, not only Command Line Tools)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

## Quick start

```bash
# 1. Generate the Xcode project
cd Plume && xcodegen generate && open Plume.xcodeproj

# 2. In Xcode: select the Plume scheme → Run
# Grant Screen Recording + Microphone when prompted.
```

Or from the repo root (requires Xcode selected via `xcode-select`):

```bash
bash scripts/build-plume.sh Release
open build/DerivedData/Build/Products/Release/Plume.app
```

### First-run checklist

1. Install Xcode + `xcodegen`
2. `cd Plume && xcodegen generate && open Plume.xcodeproj`
3. Grant **Screen Recording** and **Microphone** to **Plume**
4. Optional: Settings → Transcription → pick a language; install language assets if prompted

### Local code signing (free, stable privacy grants)

Ad-hoc signing (`codesign -s -`) changes the app's code hash on every build, so macOS treats each rebuild as a brand-new app and you have to re-approve microphone/screen-recording permissions. To keep permissions stable while testing locally without an Apple Developer account, sign with a local self-signed certificate:

```bash
# Create a long-lived cert in your login keychain
bash scripts/create-local-signing-cert.sh
# Follow the printed steps to set Code Signing → Always Trust in Keychain Access.

# Build with that identity instead of ad-hoc
PLUME_CODE_SIGN_IDENTITY="Plume Local Signing" bash scripts/build-plume.sh Release
open build/DerivedData/Build/Products/Release/Plume.app
```

After the first grant, rebuilt Plume.app keeps its Screen Recording / Microphone permissions because the designated requirement is anchored to the same certificate.

## Building a DMG

```bash
bash scripts/package-plume-dmg.sh Release  # dist/Plume-<version>-arm64.dmg
```

### Scripts

| Command | Purpose |
|---------|---------|
| `cd Plume && xcodegen generate` | Regenerate `Plume.xcodeproj` |
| `bash scripts/build-plume.sh` | `xcodebuild` Release (bundles diarization models) |
| `bash scripts/fetch-sherpa.sh` | Download sherpa-onnx libs + diarization models (one-time) |
| `bash scripts/package-plume-dmg.sh` | Build app + UDZO DMG |
| `bash scripts/test-plume.sh` | Run Plume unit tests |
| `bash scripts/clean.sh` | Remove local build artifacts |
| `bash scripts/create-local-signing-cert.sh` | Create a self-signed cert for stable local signing |

## Configuration

Preferences use `UserDefaults` (app suite). Defaults:

| Key | Default | Description |
|-----|---------|-------------|
| `saveFolder` | `~/Documents/Plume` | Recordings directory |
| `format` | `m4a` | `m4a` or `wav` |
| `launchAtLogin` | `false` | `SMAppService` login item |
| `showFloatingPill` | `true` | Floating timer panel |
| `openInFinderAfter` | `false` | Reveal file after stop |
| `autoTranscribe` | `false` | Transcribe when recording stops |
| `transcriptionLanguage` | `en-US` | BCP-47 locale for on-device transcription |
| `theme` | `system` | `system` / `light` / `dark` |

## Architecture

```
SwiftUI (Home / Recordings / Settings / MenuBarExtra / Pill)
    ├── RecordingService → SystemAudioCapture (ScreenCaptureKit) + MicCapture → AudioFileWriter (AVAssetWriter, stereo L=speaker R=mic)
    ├── TranscriptionService → Speech framework (SpeechAnalyzer, on-device) + sherpa-onnx diarization (speaker labels)
    └── SpeakerLibrary → voice profiles remembered across recordings (local)
    ├── RecordingLibrary → folder watch, rename/delete + transcript sidecars
    ├── TranscriptionService → Speech framework (SpeechAnalyzer, on-device)
    └── PreferencesStore → UserDefaults
```

| Resource | Dev | Packaged |
|----------|-----|----------|
| App | Xcode Run / `build/DerivedData/.../Plume.app` | `Plume.app` |

## Transcription

Fully local: transcripts via Apple's **Speech framework**, speaker labels via **sherpa-onnx** (bundled models, runs on-device). (`SpeechAnalyzer` + `SpeechTranscriber`, macOS 26+). Transcripts are written as `.txt` sidecars next to recordings (`Recording ….txt`). Language models are system-managed on-device assets — the app downloads the selected language's asset via `AssetInventory` when needed; nothing is sent off your Mac.

Supported locales (on-device): English (en-US), German (de-DE), Spanish (es-419), French (fr-FR), Italian (it-IT), Japanese (ja-JP), Korean (ko-KR), Portuguese (pt-BR), Chinese (zh-CN). Check Settings → Transcription for the live list on your Mac.

## Permissions

1. **Screen Recording** — System Settings → Privacy & Security → Screen Recording → **Plume**
2. **Microphone** — same under Microphone

## Project layout

```
Plume/                    Native SwiftUI app (xcodegen)
  Plume/                  Sources
  PlumeTests/             Unit tests
  project.yml             XcodeGen spec
scripts/                  build, DMG, test, clean
```

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `xcodebuild` requires Xcode | Install Xcode from the App Store; `sudo xcode-select -s /Applications/Xcode.app` |
| Screen Recording denied | Enable Plume in System Settings, restart app |
| Empty recording | Grant Screen Recording, then record again |
| "Speech transcription is not available" | On-device transcription needs a supported Mac; check Settings → Transcription |
| "Language not supported" | Pick a different language in Settings → Transcription, or install its assets first |

## License

MIT — see [LICENSE](LICENSE).