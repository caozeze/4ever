# Development Environment Requirements

This project prioritizes iOS first, but Windows can still be used for Flutter,
Dart, documentation, and shared application logic.

## Windows Development Machine

Windows is suitable for:

- Flutter/Dart business logic and UI development.
- Domain, application, data, privacy, prompt, and safety modules.
- Pigeon API definitions.
- Future optional FastAPI backend development. The first release path is offline-only and does not require server work.
- Flutter web preview.
- Git and GitHub collaboration.

Windows cannot independently perform:

- iOS Simulator runs.
- iPhone device debugging.
- `flutter build ios`.
- Xcode archive/signing.
- CocoaPods iOS native build verification.
- TestFlight or App Store upload.

## Required Windows Tools

Minimum:

- Windows 11.
- Git.
- VS Code.
- Dart SDK.
- FVM 4.0.5.
- Flutter 3.41.7 via FVM.
- GitHub CLI 2.91.0.
- uv, only for future optional backend work.
- Python 3.12.9, only for future optional backend work.
- Chrome for Flutter web preview.

Already expected by `scripts/setup-windows-dev.ps1`:

- `winget` from Microsoft App Installer.
- VS Code `code` command, if installing extensions automatically.

Optional:

- Android Studio and Android SDK, only if Android testing is needed on Windows.

## iOS Development Machine

iOS development must be handled on macOS.

Required:

- Apple Silicon Mac recommended.
- macOS version compatible with the target Xcode release.
- Xcode.
- Xcode command-line tools.
- iOS platform support.
- CocoaPods.
- Apple Developer account for signing, TestFlight, and App Store distribution.

Recommended Mac hardware:

- Minimum: 16 GB RAM, 512 GB SSD.
- Better: 24 GB or 32 GB RAM, 1 TB SSD.

Intel Mac compatibility note:

- Intel Macs remain supported for Flutter/Dart work and should support iOS
  simulator builds for shared development.
- CoreML-LLM PR 153 was merged upstream, and this app now pins the official
  `john-rocky/CoreML-LLM` package at `v1.9.0`, which includes the x86_64
  simulator Float16 conversion fallback.
- Intel and Apple Silicon simulator paths still need Codemagic or macOS/Xcode
  verification after Swift Package resolution.

The iOS owner should verify:

```bash
flutter doctor -v
flutter pub get
cd ios
pod install
cd ..
flutter run -d "iPhone Simulator"
```

## Install On macOS

Xcode setup is intentionally separate. To install the shared project toolchain
on macOS, run from the repository root:

```bash
chmod +x scripts/setup-macos-dev.sh
scripts/setup-macos-dev.sh
```

The script installs/configures:

- FVM 4.0.5.
- Flutter 3.41.7 through FVM.
- uv, for future optional backend work.
- Python 3.12.9 through uv, for future optional backend work.
- CocoaPods.
- Flutter package dependencies.
- Future optional backend uv environment.
- Recommended VS Code extensions, if the `code` command is available.

If Homebrew directories are not writable, the script asks for sudo once and
repairs Homebrew ownership before installing tools.

Optional Android tooling:

```bash
scripts/setup-macos-dev.sh --install-android-toolchain
```

This optional mode installs Android command line tools, Android Studio,
platform-tools, Android SDK 36, and build-tools 36.0.0, then accepts SDK
licenses.

## Install On Windows

From the repository root:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
.\scripts\setup-windows-dev.ps1
```

By default, the Windows setup stores the project toolchain and caches under:

```text
D:\DevTools\foreverhealth
```

This keeps Dart, pub cache, FVM cache, Flutter SDKs, and uv-managed Python
installs off the C drive. To use another drive or directory:

```powershell
.\scripts\setup-windows-dev.ps1 -ToolRoot "E:\DevTools\foreverhealth"
```

To also install Android Studio:

```powershell
.\scripts\setup-windows-dev.ps1 -InstallAndroidToolchain
```

After the script finishes, open a new PowerShell window and verify:

```powershell
dart --version
fvm --version
fvm flutter doctor
```

Expected Windows-only `flutter doctor` status:

- Flutter: pass.
- Windows version: pass.
- Chrome: pass.
- Android toolchain: may fail unless Android Studio/SDK is installed.
- iOS toolchain: not available on Windows by design.

## Repository Version Pinning

The repository uses FVM:

```json
{
  "flutter": "3.41.7"
}
```

Do not casually upgrade Flutter SDK or major package versions. SDK and major
dependency upgrades should be separate changes with analysis, tests, platform
build results, and rollback notes.

VS Code is configured to use the project FVM SDK:

```json
{
  "dart.flutterSdkPath": ".fvm/flutter_sdk",
  "dart.sdkPath": ".fvm/flutter_sdk/bin/cache/dart-sdk"
}
```

## Common Commands

Use FVM for Flutter commands:

```powershell
fvm flutter doctor
fvm flutter pub get
fvm flutter test
fvm flutter analyze
fvm flutter run -d chrome
```

Future optional backend commands should use uv. These are not required for the
offline-only first release:

```powershell
uv python install 3.12.9
uv venv --python 3.12.9
uv pip install --python .venv\Scripts\python.exe -r requirements.txt
```

If the backend uses `pyproject.toml`, prefer:

```powershell
uv sync
```

## Codemagic iOS CI

The repository includes `codemagic.yaml` at the repository root. The first
workflow is intentionally unsigned:

```text
ios-unsigned-ci
```

Purpose:

- verify Flutter dependencies, analysis, and tests on Codemagic;
- resolve Swift Package dependencies on macOS/Xcode;
- verify the iOS simulator build;
- verify an iOS device build without signing.

This workflow does not require Apple Developer signing assets. It is the first
CI gate for the official CoreML-LLM package pin and iOS project configuration.

After an Apple Developer Program account is available, add a second signed
workflow for TestFlight or Ad Hoc distribution. That workflow should configure
Codemagic iOS code signing with an App Store Connect API key, certificate, and
provisioning profile for the app bundle identifier.
