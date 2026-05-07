# Gemma Local

Privacy-first Flutter app for local wellbeing insights with replaceable on-device
LLM runtimes.

## Windows Setup

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
.\scripts\setup-windows-dev.ps1
```

The Windows setup defaults toolchains and caches to
`D:\DevTools\foreverhealth` to avoid filling the C drive. Use
`.\scripts\setup-windows-dev.ps1 -ToolRoot "E:\DevTools\foreverhealth"` if a
different drive is preferred.

## macOS Setup

Xcode is handled separately. For Flutter/FVM/uv/Python setup:

```bash
chmod +x scripts/setup-macos-dev.sh
scripts/setup-macos-dev.sh
```

## Common Commands

```powershell
.\scripts\project.ps1 get
.\scripts\project.ps1 analyze
.\scripts\project.ps1 test
.\scripts\project.ps1 run-web
```

On macOS/Linux with `make`:

```bash
make get
make analyze
make test
make run-web
```

## iOS

iOS builds, signing, HealthKit, Keychain, CocoaPods, and TestFlight require
macOS and Xcode. Windows is used for shared Flutter/Dart and documentation work.

## Architecture Notes

- First demo target: iOS App prepares Gemma 4 E2B Core ML in-app, loads it
  through the unified `LlmRuntime`, runs a smoke test, and answers a local text
  prompt from the Flutter UI.
- First release direction: offline-only app. `server/` is future optional and not part of the current demo path.
- Current model-management foundation is implemented in Dart and covered by tests.
- Apple Health sample import, demographic/clinical import, diet/photo calorie
  analysis, chronic condition workflows, sleep management, active reminders, and
  daily/weekly reports are planned/future product capabilities, not part of the
  current iOS model MVP.
- [Agent Skills Architecture](docs/AGENT_SKILLS_ARCHITECTURE.md)
- [Model Management Implementation Plan](docs/MODEL_MANAGEMENT_IMPLEMENTATION_PLAN.md)
- [Environment Requirements](docs/ENVIRONMENT_REQUIREMENTS.md)

## Current Verification

```powershell
.\.fvm\flutter_sdk\bin\flutter.bat pub get --directory app
cd app
..\.fvm\flutter_sdk\bin\flutter.bat analyze
..\.fvm\flutter_sdk\bin\flutter.bat test
```

Current acceptance requires runtime evidence: a built iOS app must prepare the
Core ML bundle, mark the model registry ready, pass the `ready` smoke test, and
return a real model answer from the Flutter page. Local verification may require
a machine with FVM/Flutter and macOS/Xcode or the Codemagic iOS workflow.
