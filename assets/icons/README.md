Icon variants for launcher generation

Files

- SVG sources: `assets/icons/*.svg`
- PNG renders (generated): `assets/icons/renders/*.png`

Exporting PNGs

- Requires `inkscape` or `rsvg-convert` installed locally.
- Run: `bash tools/export_icons.sh 1024`

Generating launcher icons (via flutter_launcher_icons)

1) Ensure PNGs exist (see exporting step above).
2) Install deps: `flutter pub get`
3) Generate launcher icons for all supported platforms:
   - `flutter pub run flutter_launcher_icons`

Source of truth

- Primary icon source: `assets/icons/icon_printer_home_shield.svg`
- Generated launcher input: `assets/icons/renders/printer_home_shield.png`

Notes

- You can change sizes by passing a different number to the export script.
- All supported platforms use the same `printer_home_shield` icon.
- If you prefer a different color palette or shape tweaks, edit the SVGs and re-export.
