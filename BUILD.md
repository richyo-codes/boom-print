# Build & Development Guide

This document explains how to set up, run, test, and build the app across supported platforms. It consolidates common workflows so you can be productive quickly.

## Overview
- App type: Flutter desktop + mobile app (LAN-only features for Bambu Lab printers)
- Entry point: `lib/main.dart`
- UI pages: `lib/main.dart`, `lib/settings_page.dart`
- Helpers: `lib/bambu_lan.dart`, `lib/bambu_mqtt.dart`, `lib/printer_stream_manager.dart`, `lib/printer_url_formats.dart`, `lib/settings_manager.dart`
- Tests: `test/`

## Prerequisites
- Flutter SDK with a Dart SDK compatible with `environment.sdk: ^3.9.0-15.0.dev` (use Flutter beta/dev channel as needed).
- Platform tooling:
  - Linux: GTK/desktop toolchain; system `libmpv` for video playback (see Linux notes below).
  - Windows: Visual Studio 2022 with “Desktop development with C++” workload; Windows 10/11 SDK for MSIX packaging.
  - Android: Android Studio + SDK/NDK; a device or emulator.
  - macOS: Xcode; CocoaPods; a signed developer profile for distribution builds.

## First‑Time Setup
1) Fetch dependencies
   - `flutter pub get`

2) Select a device (examples)
   - Desktop: `flutter devices` then `flutter run -d linux|windows|macos`
   - Mobile: `flutter run -d android|ios`

3) Optional: Copy a local env file (for `.env` via `flutter_dotenv` if used)
   - Place at project root as `.env` (values are read only at runtime; avoid committing real secrets).

## Development
- Run the app (choose a device): `flutter run -d linux|windows|android|ios|macos`
- Hot reload: press `r` in the flutter run console; hot restart: `R`.
- Analyze lints: `flutter analyze`
- Format (optional): `dart format .`

## Testing
- Run all tests: `flutter test`
- With coverage: `flutter test --coverage`
- Place new tests under `test/` and mirror `lib/` structure where practical.

## Build (Release)
- Android (APK): `flutter build apk`
- Android (AppBundle): `flutter build appbundle`
- Linux: `flutter build linux`
- Windows: `flutter build windows`
- macOS: `flutter build macos`

Artifacts will be placed under `build/` with platform‑specific subfolders.

## Platform‑Specific Notes

### Linux (media_kit / mpv)
This app uses `media_kit` for video. On Linux, install system `libmpv` runtime for playback:
- Debian/Ubuntu: `sudo apt install mpv libmpv1` (or `libmpv2` on newer releases)
- Fedora: `sudo dnf install mpv mpv-libs`
- Arch: `sudo pacman -S mpv`

If video is black or playback fails, verify `libmpv` is present and on the library path, then rebuild: `flutter clean && flutter pub get && flutter run`.

### Windows (EXE + MSI + MSIX)
- EXE bundle: `flutter build windows` (output under `build/windows/x64/runner/Release/`)
- MSI installer: `pwsh -NoProfile -ExecutionPolicy Bypass -File tools/build_msi.ps1 -Configuration Release`
- MSIX packaging is configured via `msix_config` in `pubspec.yaml`.
  - Create MSIX: `flutter pub run msix:create`
- Requirements: Visual Studio 2022, Windows 10/11 SDK, and for MSI packaging either WiX v4 (`wix`) or `.NET SDK` (the script auto-installs `wix` tool).

### Android
- Ensure an API level supported by your Flutter SDK and device. Connect a device or start an emulator, then `flutter run -d android`.
- For release signing, configure `key.properties` and `build.gradle` per standard Flutter/Android guidance.

### macOS / iOS
- Use Xcode for signing and distribution profiles. After `flutter build macos` or `flutter build ios`, finalize signing in Xcode as required.

## LAN & Security Guidance
- This app is intended for LAN‑only usage. Do not expose printer services or MQTT/FTP ports to the internet.
- Store any printer IPs, access codes, or tokens only in local settings; do not commit real values.
- If using printer CA certificates for RTSPS/TLS pinning, consider bundling a PEM asset and update `pubspec.yaml` assets accordingly (see commented example there).

## Troubleshooting
- Flutter channel/Dart version issues: ensure your Flutter SDK provides Dart `^3.9.0-15.0.dev` or adjust the `environment` constraint to match your installed SDK.
- Missing video on Linux: install `libmpv` (see Linux notes above).
- Desktop build errors: verify platform toolchains (GTK on Linux, VS on Windows, Xcode on macOS).
- Stale artifacts: try `flutter clean && flutter pub get` before rebuilding.
- Device selection: run `flutter devices` and specify with `-d <id>`.

## Useful Commands (Quick Reference)
- Install deps: `flutter pub get`
- Run: `flutter run -d linux|windows|android|ios|macos`
- Analyze: `flutter analyze`
- Test: `flutter test` (coverage: `flutter test --coverage`)
- Build: `flutter build apk|appbundle|linux|windows|macos`
- Windows MSI: `pwsh -NoProfile -ExecutionPolicy Bypass -File tools/build_msi.ps1 -Configuration Release`
- Windows MSIX: `flutter pub run msix:create`

## Project Layout
- Source: `lib/`
- Tests: `test/`
- Platform folders: `android/`, `ios/`, `linux/`, `macos/`, `web/`, `windows/`
- Config: `pubspec.yaml`, `analysis_options.yaml`, `.vscode/`

If anything is unclear or you need a platform‑specific recipe not covered here, open an issue or PR with details about your environment.

