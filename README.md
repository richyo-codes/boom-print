# BoomPrint

[![Build Status](https://github.com/richyo-codes/bambu-lan-gui/actions/workflows/flutter-build.yml/badge.svg)](https://github.com/richyo-codes/bambu-lan-gui/actions/workflows/flutter-build.yml)
[![Latest Release](https://img.shields.io/github/v/release/richyo-codes/bambu-lan-gui?display_name=tag)](https://github.com/richyo-codes/bambu-lan-gui/releases)
[![License: MIT](https://img.shields.io/github/license/richyo-codes/bambu-lan-gui)](LICENSE)
[![Platforms](https://img.shields.io/badge/platforms-Android%20%7C%20Linux%20%7C%20Windows-blue)](#platforms)

BoomPrint is a LAN-first desktop and mobile companion for Bambu printers. It focuses on the parts that are useful on the same network:

- Live camera streaming with RTSP/RTSPS URL generation for supported printers
- Printer telemetry, status, and job context over MQTT
- FTP/FTPS browsing and print submission from local storage
- QR-based settings cloning between devices
- Import/export of settings as JSON
- Cross-platform support for Android, Linux, and Windows

## Highlights

- Fast setup for Bambu-style LAN stream URLs, including generic RTSP and custom URLs
- Settings can be saved locally, exported, imported, or cloned from a QR code
- Useful desktop tooling for managing printer access without depending on cloud workflows
- Supports current and evolving printer workflows, including stream, print, and status features

## Using BoomPrint

1. Open Settings from the gear icon.
2. Choose a URL format:
   - `Bambu X1C` / `Bambu P1S`: enter the printer special code, IP, and serial information as needed.
   - `Generic RTSP`: enter host, port, path, username, password, and optional secure RTSP settings.
   - `Custom`: provide a full RTSP/RTSPS URL.
3. Save, connect, export, or generate a QR code for another device.

The app previews the generated URL for the selected format and keeps the same settings available for later cloning.

### Settings Transport

- Import JSON from a file to restore a previously saved configuration.
- Export JSON to back up a device configuration.
- Show QR to encode the current settings for quick transfer to another device.
- Scan QR to apply settings from another device.

### Where Settings Are Stored

- SharedPreferences: basic key-value copy for compatibility.
- JSON file: `boomprint_settings.json` inside the platform application support directory on mobile and desktop.
- Backward compatibility: legacy `rtsp_settings.json` is still read and migrated automatically.

## Platforms

- Android
- Linux
- Windows

## Screenshots

### Stream & Status

![Stream view](screenshots/stream-view.png)

*Live camera stream with print status overlay and controls.*

### FTP Browser

![FTP Browser](screenshots/ftp-browser.png)

*Browse printer SD card files and submit prints.*

### Settings

![Settings](screenshots/settings.png)

*Configure printer connection, URL format, and import/export settings.*

## Development Notes

- GTK3/GTK4 runner selection and local SDK setup: `docs/LINUX_GTK_FVM.md`

## Printer Requirements

To access the camera stream from the LAN, one of the following must be true:

- Firmware `>= 01.08.05.00 (20250312)` with Developer Mode enabled on the printer, which reveals the LAN RTSP/RTSPS stream and a per-printer code shown on the touchscreen
- Or an older firmware that still exposes RTSP/RTSPS without Developer Mode

For additional firmware information see:
https://wiki.bambulab.com/en/x1/manual/X1-X1C-AMS-firmware-release-history

## Notes and Safety

BoomPrint is not an official Bambu Lab application.

This software targets LAN use only. Respect local laws, your device’s EULA and warranty terms, and your network security policies. You are responsible for any changes you make to your printer, including enabling Developer Mode, and for any consequences that follow.

Enabling Developer Mode relaxes some security protections intended for regular users. Typical risks include:

- Increased attack surface: extra services or ports may become accessible on the LAN
- Network exposure: anyone on the same LAN who knows or obtains the code and IP could attempt to access the stream
- Support implications: undocumented or developer features may not be supported by the vendor and could affect warranty or support responses
- Updates may change behavior: future firmware may alter, restrict, or remove these capabilities

Mitigations:

- Keep the printer on a trusted LAN or isolated VLAN and avoid exposing it to the internet
- Use strong Wi-Fi security and restrict who can join the network
- Disable Developer Mode when not in use

## License

Licensed under the MIT License. See the `LICENSE` file for details.
