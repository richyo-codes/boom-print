# Linux GTK Builds With FVM

BoomPrint uses FVM for the Flutter SDK and selects the Linux runner variant
separately. GTK3 remains the default build; CI also builds GTK4 with the
`richyo-codes/flutter` branch `3.48.0-gtk4.issue94804.test`.

## Project Pin

The committed `.fvmrc` pins the exact commit currently at the GTK4 branch tip:
`richyo-codes/ace060af685790142a6078e172bd1d9da7c4cefb`.

The branch name is a valid SemVer prerelease, so FVM interprets it as a
release version and clones the fork's default branch instead of checking out
the named branch. Pinning the SHA avoids that ambiguity. CI verifies that the
SHA is still the branch tip before installing it.

Verify the setup from the repository root:

```bash
fvm doctor
fvm flutter --version
```

`fvm flutter --version` must report the pinned fork checkout, not another SDK
from `PATH`.

## Local Setup For The Custom GTK4 SDK

FVM needs the fork alias before it can install the pinned SHA. Run this once
after cloning BoomPrint:

```bash
fvm fork add richyo-codes https://github.com/richyo-codes/flutter.git
fvm install --skip-pub-get
fvm use --skip-setup --skip-pub-get
```

If the fork alias already exists, do not add it again. Confirm it with:

```bash
fvm fork list
```

## Updating The Flutter Checkout

Do not run `flutter upgrade` through FVM. When the GTK4 branch advances, update
the SHA in `.fvmrc`, `.github/workflows/flutter-build.yml`, and this document
together. Obtain the new SHA with:

```bash
git ls-remote https://github.com/richyo-codes/flutter.git \
  refs/heads/3.48.0-gtk4.issue94804.test
```

Check `fvm flutter --version` before building and ensure its framework revision
matches `.fvmrc`.

## CI

The `linux_gtk4` job in `.github/workflows/flutter-build.yml` installs FVM,
registers the GitHub fork, verifies the branch tip, installs the pinned SHA,
selects the GTK4 runner, and uploads a separate GTK4 bundle. The existing
`linux` job continues to use the normal Flutter action and GTK3 by default.

## GTK3 And GTK4 Selection

FVM does not select GTK. The following values must agree for every Linux run:

- Runner configuration: `linux/.gtk_variant.cmake`
- Tool argument: `--linux-gtk=gtk3` or `--linux-gtk=gtk4`
- Dart define: `--dart-define=FLUTTER_LINUX_GTK=gtk3` or `gtk4`

The helper scripts set the runner configuration:

```bash
tools/use_gtk3_runner.sh
tools/use_gtk4_runner.sh
```

Run GTK3:

```bash
tools/gtk3_build.sh
tools/gtk3_build_release.sh
```

The first command runs a debug session; the second builds a release bundle
without launching it, matching the GTK4 wrappers. To run GTK3 in release mode,
use `tools/gtk3_build.sh --release`.

Run GTK4 using a local engine:

```bash
export LOCAL_ENGINE_SRC=/path/to/flutter/engine/src
tools/gtk4_build.sh
```

VS Code launch configurations use the same GTK-specific arguments. Its
`dart.flutterSdkPath` points to the FVM version symlink, so restart the Dart
analysis server after changing `.fvmrc`.
`.vscode/launch.json` is local-only and ignored by Git. For a local-engine
configuration, use `--local-engine-src-path=${env:LOCAL_ENGINE_SRC}` and set
`LOCAL_ENGINE_SRC` before starting VS Code.

## Shared GTK Build Scripts

The GTK3 and GTK4 scripts share `tools/flutter_linux.sh`, following the launcher pattern
in `rnd_pcalc_ng_public`. They select GTK for one invocation without changing
the persisted runner preference. SDK selection uses `FLUTTER_BIN` when set,
then `.fvm/flutter_sdk/bin/flutter`, then `flutter` on PATH.

For local engines, set the engine source directory explicitly:

```bash
export LOCAL_ENGINE_SRC=/path/to/flutter/engine/src
tools/gtk4_build.sh
tools/gtk4_build_release.sh
```

The first command runs a debug session; the second builds a release bundle.
Debug, profile, and release use `host_debug_unopt`, `host_profile_unopt`, and
`host_release` respectively. Override these with `LOCAL_ENGINE` and
`LOCAL_ENGINE_HOST` if your output names differ. The launcher checks for
`libflutter_linux_gtk4.so` before starting Flutter.

For prebuilt engines, unset `LOCAL_ENGINE_SRC` and set
`FLUTTER_PREBUILT_ENGINE_VERSION` plus `FLUTTER_ENGINE_STORAGE_BASE_URL`
(or `FLUTTER_STORAGE_BASE_URL`) to your artifact origin. Use a matching
GTK4-enabled Flutter SDK.

The GTK4 launcher defaults to the published engine artifacts
`ffd16dd1cbc92510632687343958b952a705945f` using
`tools/gtk4_artifacts.env` when no local engine is selected. Load the same
settings before installing the fork with FVM:

```bash
source tools/gtk4_artifacts.env
fvm install --setup --skip-pub-get
bash tools/install_gtk4_prebuilt_engine.sh .fvm/flutter_sdk
```

The artifact prefix is
`flutter_infra_release/flutter/ffd16dd1cbc92510632687343958b952a705945f`.
The R2 origin also provides Flutter's font archive at
`flutter_infra_release/flutter/fonts/3012db47f3130e62f7cc0beabff968a33cbec8d8/fonts.zip`.
Explicit environment values override the launcher defaults.

```bash
bash tools/flutter_linux.sh gtk4 build --profile
MEDIA_KIT_GTK4_TEXTURE_INTEROP=egl-image tools/gtk4_build.sh
```

Texture interop defaults to `direct`; `egl-image` is also accepted. Debug
logging is opt-in through `MEDIA_KIT_GTK4_DEBUG`. Every invocation records
output in a log named with its GTK variant, action, and build mode under `logs/`.
