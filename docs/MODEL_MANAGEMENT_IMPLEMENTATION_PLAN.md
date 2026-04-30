# Model Management Implementation Plan

目标：第一版跑通一个 offline-only 本地模型闭环。Flutter 业务层只依赖统一
`LlmRuntime`，模型管理层按平台选择 runtime artifact；iOS 默认走 Core ML / ANE，
Android 继续走 `.litertlm` / LiteRT-LM。

第一版不做健康数据、不做 agent skills、不做云端分析、不做云端同步。`server/`
仅作为 future optional 预留，不参与当前 demo 闭环。

## 1. 第一版闭环

```text
manifest
  -> 选择 platform runtime artifact
  -> 检查内存/磁盘
  -> 下载或准备 artifact bundle
  -> 校验或 readiness check
  -> 写 model_registry.json
  -> LlmRuntime.initialize
  -> smoke test
  -> demo chat
```

统一由 Dart/Flutter 编排。平台只实现必要能力：

```text
DeviceCapabilitiesApi
LlmRuntimeHostApi
```

## 2. Runtime Matrix

| Platform | First runtime | Artifact type | Default model | Notes |
| --- | --- | --- | --- | --- |
| iOS | `coreml_llm` | `coreml_bundle` | Gemma 4 E2B CoreML | 通过 `john-rocky/CoreML-LLM` Swift Package，优先 ANE/Core ML |
| iOS optional | `coreml_llm` | `coreml_bundle` | Gemma 4 E4B CoreML | 高质量手动档，设备满足内存/磁盘后可选 |
| Android | `litert_lm` | `litertlm_file` | Gemma 4 E4B `.litertlm` | Kotlin adapter 调 LiteRT-LM Android API |
| iOS future fallback | `litert_lm` | `litertlm_file` | TBD | 保留能力，不作为第一版首选 |

Flutter 业务层不得直接感知 Core ML、LiteRT-LM、SPM、Kotlin、Swift runtime 或
具体 artifact 格式。

## 3. Manifest

Manifest 从单文件模型扩展为 artifact-based schema。每个 entry 必须声明：

```json
{
  "id": "gemma-4-e2b-it-coreml-ios",
  "display_name": "Gemma 4 E2B Core ML",
  "provider": "mlboydaisuke",
  "model_id": "mlboydaisuke/gemma-4-E2B-coreml",
  "repo_id": "mlboydaisuke/gemma-4-E2B-coreml",
  "runtime": "coreml_llm",
  "artifact_type": "coreml_bundle",
  "revision": "n1024",
  "allow_patterns": ["*.json", "*.mlmodelc/**", "*.bin", "*.txt"],
  "sha256": "BUNDLE_READINESS_CHECK",
  "size_bytes": 2583085056,
  "min_memory_gb": 8,
  "min_free_disk_bytes": 5166170112,
  "modalities": ["text"],
  "supports_thinking": true,
  "max_context_tokens": 32000,
  "default": true,
  "platforms": ["ios"],
  "selection_priority": 10
}
```

Rules:

- iOS default entry is `gemma-4-e2b-it-coreml-ios`.
- iOS optional high-quality entry is `gemma-4-e4b-it-coreml-ios`.
- Android `.litertlm` E2B/E4B entries remain in the manifest.
- `runtime` controls the native adapter family.
- `artifact_type` controls storage and verification semantics.
- `revision` is used for versioned local storage.
- Single-file artifacts use `file_name`, `download_url`, and `sha256`.
- Bundle artifacts use `repo_id`, `revision`, `allow_patterns`, and first-pass readiness checks.

## 4. Storage And Registry

Artifact storage:

```text
Application Support/models/{model_id}/{revision}/
```

Single-file artifacts:

```text
Application Support/models/{model_id}/{revision}/{file_name}
```

Bundle artifacts:

```text
Application Support/models/{model_id}/{revision}/
```

Registry remains JSON in first version:

```text
Application Support/model_registry.json
```

`ModelRegistryStore` records:

```text
modelId
displayName
runtime
artifactType
revision
localPath
sha256
sizeBytes
status
createdAt
updatedAt
failureReason
errorMessage
```

No SQLCipher `model_registry` table is required for the first model demo.

## 5. Selection Rules

`ModelSelectionService` filters by:

```text
platform
memory
free disk
preferred model id, if compatible
default flag
selection priority
```

Expected behavior:

- iOS fresh install recommends CoreML E2B.
- iOS can manually select CoreML E4B when memory/disk are sufficient.
- Android defaults to LiteRT-LM E4B when supported, otherwise E2B.
- Incompatible platform entries are never selected.

## 6. Download And Verification

Android `.litertlm`:

```text
background_downloader
  -> chunked SHA-256
  -> compare manifest sha256
```

iOS CoreML bundle first version:

```text
CoreML-LLM native downloader or prepared local bundle
  -> bundle readiness check
  -> registry installed
```

First-pass bundle readiness check:

```text
required directory exists
model_config.json or equivalent config is readable
compiled .mlmodelc and sidecar files are present
```

Per-file hash manifest should be added later, but it does not block the first
local demo.

## 7. Native Runtime Plan

### Android

Phase E remains Kotlin + LiteRT-LM:

```text
LlmRuntimeHostApi
  -> LiteRtLmRuntimeAdapter
  -> LiteRT-LM Android/Kotlin API
```

### iOS

Phase F changes to Core ML:

```text
SPM: https://github.com/john-rocky/CoreML-LLM
LlmRuntimeHostApi
  -> CoreMlLlmRuntimeHostApiAdapter
  -> CoreML-LLM Swift API
  -> Core ML / ANE
```

`initialize` receives the local bundle path and model metadata from Dart.
`generateOnce` and later streaming are hidden behind `LlmRuntime`. The smoke
test remains:

```text
Prompt: Reply with the single word: ready
Expected: output contains "ready"
Timeout: 30 seconds
```

## 8. Phases

### Phase A: Dart Foundation

Current status: started.

Done:

- Manifest loader and domain models.
- Selection service.
- JSON registry store.
- Application Support storage paths.
- Single-file downloader/verifier.
- Device capability reader and iOS adapter.

Updated scope:

- `ModelManifestEntry` includes `runtime`, `artifactType`, `revision`,
  `repoId`, and `allowPatterns`.
- `ModelRegistryStore` persists runtime/artifact metadata.
- Storage paths support bundle directories.
- Tests cover CoreML bundle and LiteRT-LM file entries.

### Phase B: Android Single-File Install

Keep current `.litertlm` download, SHA-256 verification, registry write, load,
smoke test flow.

### Phase C: iOS CoreML Bundle Preparation

Add CoreML-LLM Swift Package and native bundle preparation path. First version
may use CoreML-LLM downloader or a manually prepared bundle to reach the demo
fast.

### Phase D: Demo UI

Model demo screen should show:

- recommended model for current platform,
- memory and free disk,
- install/prepare status,
- load/smoke test status,
- minimal chat once ready.

### Phase E: Android LiteRT-LM Runtime

Implement real Kotlin adapter for `LlmRuntimeHostApi`.

### Phase F: iOS CoreML Runtime

Implement `CoreMlLlmRuntimeHostApiAdapter` using CoreML-LLM. LiteRT-LM C++ on
iOS is kept only as a future fallback path.

## 9. Test Plan

Dart unit tests:

```text
manifest parses coreml_bundle and litertlm_file
iOS default selection returns CoreML E2B
iOS preferred selection can return CoreML E4B
Android selection returns LiteRT-LM entries
incompatible platform entries are ignored
registry persists runtime and artifact metadata
single-file lifecycle still reaches ready with fake runtime
```

iOS build/runtime tests:

```text
flutter analyze
flutter test
flutter build ios --simulator --debug
flutter build ios --debug --no-codesign
real-device CoreML E2B: prepare bundle -> initialize -> generateOnce -> ready
DeviceCapabilitiesApi returns memory/disk and affects selection
```

Known iOS build compatibility issue:

```text
CoreML-LLM v1.7.0 builds for iphoneos on the current Intel Mac environment.
CoreML-LLM v1.7.0 fails for x86_64 iOS Simulator because Accelerate's
vDSP.convertElements(Float16 -> Float) overload is unavailable in the
x86_64-apple-ios-simulator SDK slice.
Apple Silicon simulator is expected to use the arm64 simulator SDK, where the
overload is present, but this still needs teammate verification.
```

Manual demo scenarios:

```text
fresh install shows E2B CoreML as iOS recommendation
E4B is visible as manual iOS quality option
registry marks installed after bundle preparation
load runs smoke test and enters chat
Android route still uses .litertlm entries
```

## 10. Definition Of Done

```text
1. Manifest can parse both artifact types.
2. iOS defaults to Gemma 4 E2B CoreML.
3. Android keeps Gemma 4 .litertlm selection.
4. Registry persists runtime/artifact metadata.
5. Bundle storage path resolves to a versioned directory.
6. LlmRuntime.initialize loads at least one real model on one platform.
7. Smoke test passes.
8. Demo chat gets a model response.
9. UI does not call Pigeon, CoreML-LLM, LiteRT-LM, hash, or registry directly.
10. flutter analyze and flutter test pass.
```

## 11. Implementation Log

### 2026-04-28

CoreML integration work completed:

- Added iOS CoreML-LLM Swift Package integration path.
- Raised iOS deployment target to iOS 18 for CoreML-LLM compatibility.
- Implemented Swift runtime adapter path behind existing `LlmRuntimeHostApi`.
- `initialize` expects a local CoreML bundle path and validates bundle readiness
  before loading.
- `generateOnce` calls CoreML-LLM behind `LlmRuntime`; Flutter business logic
  remains runtime-agnostic.
- Streaming is still intentionally deferred.

Verification completed:

```text
flutter analyze
Result: pass

flutter test
Result: pass

flutter build ios --debug --no-codesign
Result: pass with CoreML-LLM v1.7.0

flutter build ios --simulator --debug
Result: fail on Intel Mac x86_64 simulator with CoreML-LLM v1.7.0
```

Build issue root cause:

```text
CoreML-LLM v0.8.0 failed simulator builds because ModelDownloader used
Process() under targetEnvironment(simulator). Upstream fixed this in later
versions by restricting Process() to os(macOS).

CoreML-LLM v1.7.0 fixes the Process() issue, but has a separate Intel simulator
compatibility problem in ChunkedEngine.swift:

vDSP.convertElements(of: [Float16], to: inout [Float])

The overload exists for iphoneos arm64e and arm64 iOS simulator SDK slices, but
not for x86_64 iOS simulator. This blocks Intel Mac simulator builds while
allowing real iPhone builds.
```

Fork/PR decision:

- Keep official CoreML-LLM v1.7.0 as the target runtime version.
- Create a fork branch for a minimal x86_64 simulator compatibility patch.
- Patch only the `Float16 -> Float` conversion path, using a manual conversion
  fallback for `targetEnvironment(simulator) && arch(x86_64)`.
- Submit the same patch upstream as a PR.
- Point this app to the fork branch until the upstream PR is merged and tagged.
- Switch back to the official upstream tag after merge/release.

## 12. Next Work

Immediate next steps:

1. Create or regain access to the team/user fork of
   `https://github.com/john-rocky/CoreML-LLM`.
2. Add a branch such as `fix/x86_64-simulator-float16-conversion`.
3. Apply the minimal fallback around `vDSP.convertElements(Float16 -> Float)`.
4. Validate:

```text
Intel Mac:
flutter build ios --simulator --debug
flutter build ios --debug --no-codesign

Apple Silicon Mac:
flutter build ios --simulator --debug
flutter build ios --debug --no-codesign

Shared:
flutter analyze
flutter test
```

5. Update this app's SPM dependency to the fork branch.
6. Open the upstream CoreML-LLM PR.
7. Run true iPhone smoke test after model bundle preparation:

```text
prepare Gemma 4 E2B CoreML bundle
LlmRuntime.initialize
generateOnce("Reply with the single word: ready")
expected output contains "ready"
```

## 13. Execution Update

### 2026-04-29

Fork branch work completed:

- Created fork: `https://github.com/caozeze/CoreML-LLM`.
- Created fork branch: `fix/x86_64-simulator-float16-conversion`.
- Applied the minimal `Float16 -> Float` fallback in
  `Sources/CoreMLLLM/ChunkedEngine.swift`.
- Pushed commit:
  `e95c10e343736570134bd690a5a9cd4c579e17c8`.
- Opened upstream PR:
  `https://github.com/john-rocky/CoreML-LLM/pull/153`.
- Updated this app's Swift Package dependency to point at the fork branch.

Remaining verification:

```text
Intel Mac:
flutter build ios --simulator --debug
flutter build ios --debug --no-codesign

Apple Silicon Mac:
flutter build ios --simulator --debug
flutter build ios --debug --no-codesign

Shared:
flutter analyze
flutter test

Real iPhone:
prepare Gemma 4 E2B CoreML bundle
LlmRuntime.initialize
generateOnce("Reply with the single word: ready")
expected output contains "ready"
```
