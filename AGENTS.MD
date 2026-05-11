# 端侧 AI App 技术栈

版本：0.3

项目形态：iOS / Android 双端 Flutter App，当前分支是 **iOS-first / offline-only / 本地优先** 的实机验证与模型管理产品化阶段。端侧 AI、本地 HealthKit 聚合读取、本地健康 Agent 编排、隐私边界、本地模型下载/加载/切换是当前主线；Android、SQLCipher 健康数据持久化、完整隐私审计和云端分析仍作为后续能力，默认不参与当前 demo。

## 0. 背景与技术判断

本项目选择 **Flutter** 作为跨平台 App 主框架，使用 **Dart** 实现 UI、业务编排、健康画像、隐私脱敏和本地状态管理。Android 与 iOS 端的系统级能力通过原生插件接入：Android 使用 **Kotlin**，iOS 使用 **Swift**。

当前分支已进入 `codex-feature-gemma` 阶段，最新提交 `c9aa121`（2026-05-11 02:11:36 +0800）记录为“本地 Gemma 健康 Agent 阶段状态”。本阶段已经完成 iPhone 17 实机路径验证：Flutter Chat UI -> 本地 Gemma 4 E2B Core ML bundle -> CoreML-LLM Swift adapter -> HealthKit 聚合工具 -> 中文健康问答。当前工作区在此基础上新增了 iOS 模型选择页和 Core ML bundle 下载流程，入口从直接进入 Chat 调整为先进入 `/models`。Android 端仍待确认。

```
Gemma 4 是默认目标模型族。
当前 iOS 默认实机模型是 Gemma 4 E2B Core ML n1024 bundle。
Gemma 4 E4B 是高内存/高质量档位，已接入 iOS 选择与下载流程，但还未完成完整下载和实机初始化验证。
Gemma 4 不直接暴露给业务层。
业务层只依赖统一的 LlmRuntime 接口。
Android / iOS 各自实现原生 runtime adapter。
iOS 当前 adapter 是 Swift + CoreML-LLM + Core ML / ANE。
Android 计划 adapter 仍是 Kotlin + LiteRT-LM。
Gemma 4 E4B / E2B 档位和 runtime adapter 必须可替换，用户必须能在 Chat 前显式选择、下载、加载和切换。
当前阶段不做 server、不做云端分析、不做云端同步。
任何云端能力必须后续单独设计、默认关闭、用户显式 opt-in。
```

## 当前分支实现状态

当前分支不是最初的空壳规划，而是已经跑通的新阶段代码。后续 agent 修改前必须按以下事实理解仓库：

```
当前主线：
  iOS Flutter app
  /models 模型选择页
  Gemma 4 E2B / E4B Core ML bundle manifest
  HuggingFace Core ML bundle 下载
  CoreML-LLM Swift Package
  MethodChannel LlmRuntime adapter
  HealthKit 聚合读取
  本地 Health Agent planner / prompt builder / tool routing
  Chat 页面实机问答 demo

已实现入口：
  app/lib/app.dart
  app/lib/presentation/model/model_setup_page.dart
  app/lib/presentation/chat/chat_page.dart
  app/lib/presentation/health/health_permissions_page.dart
  app/lib/application/ai/demo_chat_controller.dart
  app/lib/application/ai/local_health_agent_service.dart
  app/lib/application/ai/health_agent_planner.dart
  app/lib/application/ai/compact_health_prompt_builder.dart
  app/lib/application/ai/model/model_connection_controller.dart
  app/lib/application/ai/model/model_lifecycle_service.dart
  app/lib/data/model/model_artifact_preparers.dart
  app/ios/Runner/NativeBridge/LlmRuntimeHostApiAdapter.swift
  app/ios/Runner/NativeBridge/HealthKitHostApiAdapter.swift
  app/tooling/download_coreml_bundle.dart

当前限制：
  Android runtime provider 尚未实现，不能声称双端已跑通。
  iOS token streaming 尚未接通，generateOnce 是当前实机路径。
  iOS CoreML bundle 下载已接入 Dart 模型生命周期，但完整性仍采用 readiness check，不是完整 per-file hash manifest。
  E2B Core ML n1024 已完成完整本地下载验证；E4B 已接入流程和 readiness 规则，但尚未完成完整下载/实机初始化验证。
  当前下载器使用 HuggingFace tree/resolve API、Dio 下载和 HttpClient fallback，尚未接入 background_downloader 的断点续传 UI。
  model_registry 仍为 Application Support/model_registry.json。
  server/ 仍是 future optional 预留，不属于当前离线 demo。
```

## 1. 总体架构

```
Flutter App
│
├── Presentation Layer
│   ├── Onboarding
│   ├── Health Dashboard
│   ├── AI Companion Chat
│   ├── Daily Check-in
│   ├── Insight Cards
│   ├── Privacy Review
│   ├── Model Status
│   └── Settings
│
├── Application Layer
│   ├── HealthImportService
│   ├── HealthSummaryService
│   ├── LocalCoachService
│   ├── PrivacyFilterService
│   ├── ModelLifecycleService
│   └── RiskBoundaryService
│
├── Domain Layer
│   ├── HealthSignal
│   ├── HealthSample
│   ├── MoodLog
│   ├── BehaviorEvent
│   ├── DailySummary
│   ├── UserHealthProfile
│   └── WellbeingInsight
│
├── Data Layer
│   ├── EncryptedLocalDatabase
│   ├── HealthRepository
│   ├── MoodRepository
│   ├── ModelRepository
│   └── SecureKeyRepository
│
├── Native Bridge Layer
│   ├── LlmRuntimeApi
│   ├── HealthDataApi
│   ├── CryptoApi
│   ├── ModelStorageApi
│   └── BackgroundTaskApi
│
├── Android Native Layer
│   ├── Kotlin
│   ├── Gemma 4 Runtime Adapter
│   ├── Health Connect Adapter
│   ├── Android Keystore Adapter
│   └── WorkManager Adapter
│
└── iOS Native Layer
    ├── Swift
    ├── Gemma 4 Runtime Adapter
    ├── HealthKit Adapter
    ├── Keychain / CryptoKit Adapter
    └── BackgroundTasks Adapter

Future Optional Cloud Extension
  ├── Disabled by default
  ├── Requires explicit user opt-in
  ├── Receives only reviewed anonymized structured summaries
  └── Must not receive raw health data, raw chat, raw journal, or identifiers
```

Flutter 官方支持通过 platform channel 调用 Android Kotlin / Java 和 iOS Swift / Objective-C 原生代码；Pigeon 可生成类型安全的宿主 API，减少 Dart 与平台端手写字符串协议不一致的问题。([Flutter 文档](https://docs.flutter.dev/platform-integration/platform-channels?sid=TMUlf1&utm_source=chatgpt.com))

默认采用 **Pigeon 优先，手写 MethodChannel 例外** 的桥接策略。

## 2. 技术栈总表

| 模块 | 选型 | 说明 |
| --- | --- | --- |
| App 框架 | Flutter | 双端 UI、业务编排、页面导航 |
| 主语言 | Dart | Flutter 业务层、领域模型、隐私处理 |
| Android 原生 | Kotlin | Gemma runtime、Health Connect、Keystore、后台任务 |
| iOS 原生 | Swift | Flutter MethodChannel/Pigeon 入口、CoreML-LLM adapter、HealthKit、Keychain、BackgroundTasks |
| 状态管理 | Riverpod | 异步状态、依赖注入、测试友好 |
| 路由 | go_router | 声明式路由、deep link、ShellRoute |
| 数据模型 | freezed + json_serializable | 不可变模型、序列化、copyWith |
| Native Bridge | Pigeon 优先；当前 iOS runtime/HealthKit 用 MethodChannel | 类型安全接口仍是目标；实机 MVP 允许保留已验证 MethodChannel adapter |
| 本地数据库 | SQLCipher SQLite | 文件级加密数据库 |
| Flutter DB 包 | sqflite_sqlcipher | Android / iOS / macOS 支持，openDatabase 支持 password 参数；包文档要求 release 混淆时保留 SQLCipher 类。([Dart packages](https://pub.dev/packages/sqflite_sqlcipher?utm_source=chatgpt.com)) |
| 密钥存储 | flutter_secure_storage + 原生 Keychain / Keystore | Flutter 层存储小型敏感数据；关键密钥应由原生层生成和保护 |
| 健康数据 | HealthKit + Health Connect | iOS 与 Android 系统健康数据源 |
| 健康数据 Flutter 包 | health | 可作为早期 adapter；该包是 Apple HealthKit 与 Google Health Connect 的 wrapper。([Dart packages](https://pub.dev/packages/health?utm_source=chatgpt.com)) |
| 端侧模型 | Gemma 4 E2B / E4B | 当前 iOS 默认 Gemma 4 E2B Core ML n1024；E4B 作为高内存/高质量档位 |
| 模型运行时 | iOS CoreML-LLM；Android LiteRT-LM planned | iOS 用 Swift + CoreML-LLM + Core ML/ANE；Android 计划用 Kotlin + LiteRT-LM；平台端封装，不暴露给业务层 |
| 云端服务 | Future optional | 第一版不启用；后续如加入，只能接收用户确认后的脱敏结构化摘要 |
| 云端 AI | Future optional | 第一版不启用；不得接收原始健康数据、聊天、日记或身份标识 |
| CI/CD | GitHub Actions + Fastlane | 静态检查、测试、构建、发布 |
| 版本管理 | FVM + lockfile | 固定 Flutter SDK 与依赖版本 |

## 3. Flutter 工程规范

### 3.1 Flutter SDK

使用 FVM 固定 Flutter 版本。

```bash
fvm install stable
fvm use stable
```

如果使用 `sqflite_sqlcipher 3.4.0`，需注意其 changelog 标注最低 Flutter 版本更新到 3.35 以支持 Android SDK 36。([Dart packages](https://pub.dev/packages/sqflite_sqlcipher/changelog?utm_source=chatgpt.com))

仓库必须提交：

```
.fvmrc
pubspec.lock
analysis_options.yaml
```

AI agent 不得随意升级 Flutter SDK 或大版本依赖。升级必须单独 PR，并包含：

```
依赖变更说明
flutter analyze 结果
flutter test 结果
Android build 结果
iOS build 结果
回滚方式
```

### 3.2 推荐依赖

`pubspec.yaml` 初始依赖建议如下。实际版本以创建项目时 `pub.dev` 最新稳定版本为准，但必须锁定 `pubspec.lock`。

```yaml
dependencies:
  flutter:
    sdk: flutter

  # State management
  flutter_riverpod: ^3.3.1
  riverpod_annotation: ^3.0.0

  # Routing
  go_router: ^17.2.2

  # Data model and serialization
  freezed_annotation: ^3.0.0
  json_annotation: ^4.9.0

  # Native bridge
  pigeon: ^26.0.0

  # Network
  dio: ^5.0.0
  retrofit: ^4.0.0

  # Local encrypted database
  sqflite_sqlcipher: ^3.4.0
  path_provider: ^2.1.0
  path: ^1.9.0

  # Secure storage
  flutter_secure_storage: ^10.0.0
  cryptography: ^2.7.0

  # Health data
  health: ^13.3.1
  permission_handler: ^12.0.0

  # Device and system
  device_info_plus: ^12.0.0
  package_info_plus: ^9.0.0
  connectivity_plus: ^7.0.0

  # Background and downloads
  background_downloader: ^9.0.0
  workmanager: ^0.9.0

  # UI
  fl_chart: ^1.0.0
  flutter_markdown: ^0.7.0
  shimmer: ^3.0.0
  intl: ^0.20.0

  # Notifications
  flutter_local_notifications: ^19.0.0

dev_dependencies:
  flutter_test:
    sdk: flutter

  integration_test:
    sdk: flutter

  build_runner: ^2.5.0
  freezed: ^3.0.0
  json_serializable: ^6.9.0
  retrofit_generator: ^10.0.0
  riverpod_generator: ^3.0.0

  flutter_lints: ^6.0.0
  very_good_analysis: ^9.0.0

  mocktail: ^1.0.0
  golden_toolkit: ^0.15.0
```

Riverpod 当前包说明强调其适合异步代码、错误/加载状态处理，以及将逻辑与 UI 分离；这与本项目大量异步健康数据、模型加载和本地 AI 编排任务匹配。([Dart packages](https://pub.dev/packages/flutter_riverpod?utm_source=chatgpt.com))

go_router 是 Flutter 团队发布的声明式路由包，支持 deep link、路径参数、重定向、ShellRoute 和多 Navigator。([Dart packages](https://pub.dev/packages/go_router?utm_source=chatgpt.com))

flutter_secure_storage 当前文档说明其在 iOS 使用 Keychain，在 Android 使用加密存储，并提供 Android KeyStore / AES-GCM 等选项；本项目可用它保存小型敏感配置，但数据库主密钥建议由原生层生成和保护。([Dart packages](https://pub.dev/packages/flutter_secure_storage?utm_source=chatgpt.com))

### 3.3 目录结构

```
app/
  lib/
    main.dart
    bootstrap.dart
    app.dart

    core/
      config/
        app_config.dart
        flavor.dart
        environment.dart

      errors/
        app_error.dart
        error_code.dart
        error_mapper.dart

      logging/
        redacted_logger.dart
        log_event.dart

      security/
        secure_key_store.dart
        encryption_service.dart
        pii_detector.dart

      native/
        generated/
          llm_runtime_api.g.dart
          health_data_api.g.dart
          crypto_api.g.dart
        llm_runtime_api.dart
        health_data_api.dart
        crypto_api.dart

      privacy/
        privacy_filter.dart
        anonymization_policy.dart
        sensitivity_classifier.dart
        upload_policy.dart

      utils/
        clock.dart
        result.dart
        uuid.dart
        date_range.dart

    domain/
      health/
        health_metric_type.dart
        health_sample.dart
        health_signal.dart
        daily_health_snapshot.dart
        weekly_health_snapshot.dart
        sleep_summary.dart
        workout_summary.dart
        heart_rate_summary.dart

      mood/
        mood_log.dart
        mood_score.dart

      behavior/
        behavior_event.dart
        behavior_event_type.dart

      ai/
        llm_model_config.dart
        llm_generation_config.dart
        llm_response.dart
        llm_token_event.dart
        llm_runtime_status.dart
        prompt_context.dart

      insight/
        daily_summary.dart
        weekly_insight.dart
        recommendation.dart
        risk_flag.dart

      privacy/
        anonymized_cloud_payload.dart
        sensitivity_level.dart
        redaction_report.dart

    data/
      db/
        encrypted_database.dart
        database_key_provider.dart
        migrations/
          migration_001.dart
          migration_002.dart
        dao/
          health_sample_dao.dart
          mood_log_dao.dart
          daily_summary_dao.dart
          json_model_registry_store.dart
          cloud_job_dao.dart

      repositories/
        health_repository_impl.dart
        mood_repository_impl.dart
        model_repository_impl.dart
        cloud_repository_impl.dart
        user_profile_repository_impl.dart

      api/
        cloud_api_client.dart
        dto/
          analyze_request_dto.dart
          analyze_response_dto.dart

    application/
      health/
        health_import_service.dart
        health_normalization_service.dart
        health_snapshot_service.dart

      ai/
        agent/
          agent_runtime.dart
          agent_tool_registry.dart
        local_summary_service.dart
        wellbeing_coach_service.dart
        model_lifecycle_service.dart
        prompt_builder.dart
        prompt_templates.dart

      privacy/
        local_redaction_service.dart
        upload_review_service.dart
        privacy_audit_service.dart

      sync/
        cloud_analysis_service.dart
        sync_queue_service.dart

      safety/
        risk_boundary_service.dart
        medical_safety_guard.dart

    presentation/
      onboarding/
      dashboard/
      checkin/
      chat/
      insights/
      privacy_review/
      model_status/
      settings/

  pigeon/
    llm_runtime_api.dart
    health_data_api.dart
    crypto_api.dart
    background_task_api.dart

  android/
    app/src/main/kotlin/com/company/app/
      LlmRuntimeHostApi.kt
      HealthConnectHostApi.kt
      CryptoHostApi.kt
      BackgroundTaskHostApi.kt

  ios/
    Runner/
      LlmRuntimeHostApi.swift
      HealthKitHostApi.swift
      CryptoHostApi.swift
      BackgroundTaskHostApi.swift
```

### 3.4 分层依赖规则

```
presentation 可以依赖 application 和 domain。
application 可以依赖 domain 和 repository interface。
domain 不得依赖 Flutter、数据库、网络、原生桥接。
data 实现 repository interface。
native bridge 只能通过 application 或 data adapter 被调用。
UI 不得直接调用 Pigeon 生成 API。
UI 不得直接访问数据库。
UI 不得直接访问 HealthKit / Health Connect。
UI 不得直接访问 Gemma runtime。
```

## 4. Native Bridge 规范

### 4.1 Pigeon 优先，实机 MVP 保留已验证 MethodChannel

本项目使用 Pigeon 定义跨平台接口。手写 `MethodChannel` 仅用于：

```
token streaming
高频事件流
Pigeon 不支持或实现成本明显过高的特殊场景
已经完成实机验证且迁移 Pigeon 会增加当前阶段风险的 runtime / HealthKit adapter
```

Flutter 文档说明，Pigeon 可生成结构化、类型安全的平台消息代码，避免 host 与 client 手动匹配字符串、参数名和数据类型。([Flutter 文档](https://docs.flutter.dev/platform-integration/platform-channels?sid=TMUlf1&utm_source=chatgpt.com))

当前分支的 iOS `LlmRuntime`、`HealthDataApi`、`DeviceCapabilitiesApi` 已通过
`MethodChannel` 跑通实机路径。后续重构到 Pigeon 必须是单独任务，并保持以下
业务接口不变：

```
LlmRuntime
HealthDataGateway
DeviceCapabilitiesReader
ModelLifecycleService
DemoChatController
```

禁止为了“纯 Pigeon 化”破坏当前 iPhone 17 已验证路径。

### 4.2 LLM Runtime Host API

`app/pigeon/llm_runtime_api.dart`

```dart
import 'package:pigeon/pigeon.dart';

class NativeLlmModelConfig {
  String modelId;
  String localPath;
  String sha256;
  int sizeBytes;
  int minMemoryGb;
  bool supportsText;
  bool supportsImage;
  bool supportsAudio;
  bool supportsThinking;
  int maxContextTokens;

  NativeLlmModelConfig({
    required this.modelId,
    required this.localPath,
    required this.sha256,
    required this.sizeBytes,
    required this.minMemoryGb,
    required this.supportsText,
    required this.supportsImage,
    required this.supportsAudio,
    required this.supportsThinking,
    required this.maxContextTokens,
  });
}

class NativeGenerationConfig {
  double temperature;
  int topK;
  double topP;
  int maxTokens;
  bool enableThinking;

  NativeGenerationConfig({
    required this.temperature,
    required this.topK,
    required this.topP,
    required this.maxTokens,
    required this.enableThinking,
  });
}

class NativeLlmStatus {
  String state;
  String? errorCode;
  String? errorMessage;
  int? usedMemoryMb;
  String? loadedModelId;

  NativeLlmStatus({
    required this.state,
    this.errorCode,
    this.errorMessage,
    this.usedMemoryMb,
    this.loadedModelId,
  });
}

@HostApi()
abstract class LlmRuntimeHostApi {
  @async
  void initialize(NativeLlmModelConfig config);

  @async
  String generateOnce(String prompt, NativeGenerationConfig config);

  @async
  void cancel();

  @async
  void unload();

  @async
  NativeLlmStatus getStatus();
}
```

Streaming 使用独立 EventChannel：

```
channel: com.company.app/llm_token_stream
event payload:
{
  "request_id": "...",
  "type": "token|thinking|done|error",
  "text": "...",
  "error_code": null
}
```

### 4.3 错误归一化

原生层必须把 SDK 错误转换为统一错误码：

```
MODEL_FILE_NOT_FOUND
MODEL_HASH_MISMATCH
MODEL_LOAD_FAILED
MODEL_UNSUPPORTED_DEVICE
MODEL_OUT_OF_MEMORY
MODEL_RUNTIME_INTERNAL
GENERATION_CANCELLED
GENERATION_TIMEOUT
GENERATION_EMPTY_OUTPUT
NATIVE_PERMISSION_DENIED
UNKNOWN
```

Dart 层不得解析原生 SDK 原始错误字符串作为业务逻辑依据。

## 5. Gemma 4 与本地模型运行时

### 5.1 模型策略

当前 iOS 实机默认目标模型：

```
gemma-4-e2b-it-coreml-ios
Gemma 4 E2B Core ML
revision: n1024
runtime: coreml_llm
artifact_type: coreml_bundle
repo: mlboydaisuke/gemma-4-E2B-coreml
```

当前 iOS 高质量档位：

```
gemma-4-e4b-it-coreml-ios
Gemma 4 E4B Core ML
revision: main
runtime: coreml_llm
artifact_type: coreml_bundle
repo: mlboydaisuke/gemma-4-E4B-coreml
```

Android 计划目标：

```
gemma-4-e4b-it-litert-android
gemma-4-e2b-it-litert-android
runtime: litert_lm
artifact_type: litertlm_file
```

Edge Gallery 的 Android allowlist 中，Gemma 4 E2B 模型文件约 2.58GB，最低设备内存 8GB，支持图像、音频、thinking、32K context；Gemma 4 E4B 约 3.65GB，最低设备内存 12GB，同样支持图像、音频、thinking、32K context。当前 iOS Core ML n1024 实机路径以文本问答为主，`max_context_tokens` 以 manifest 中平台 entry 为准。

当前阶段 demo 已从“模型 smoke test”推进到“本地健康 Agent 实机问答”，并新增 Chat 前模型选择/下载/切换页。目标闭环是：

```
manifest
-> 选择 platform runtime artifact
-> 检查内存/磁盘
-> /models 页面选择 Gemma 4 E2B 或 E4B
-> 下载/准备本地 CoreML bundle 或 Android .litertlm 文件
-> readiness check 或 SHA-256 校验
-> 写 model_registry.json
-> LlmRuntime.initialize
-> smoke test
-> demo chat
-> health prompt planner
-> HealthKit aggregate tool
-> local Gemma answer
```

双端共用 Dart/Flutter 模型管理流程、artifact manifest、model registry 和
`LlmRuntime` 抽象。Android 与 iOS 不共用 Kotlin/Swift 代码，也不要求共用
artifact 格式：

```
iOS:
  CoreML bundle
  Swift CoreML-LLM adapter
  Core ML / ANE 优先
  当前 E2B 下载地址来自 HuggingFace tree/resolve API:
    https://huggingface.co/api/models/mlboydaisuke/gemma-4-E2B-coreml/tree/n1024?recursive=1
    https://huggingface.co/mlboydaisuke/gemma-4-E2B-coreml/resolve/n1024/{path}?download=true
  当前 E4B 下载地址来自 HuggingFace tree/resolve API:
    https://huggingface.co/api/models/mlboydaisuke/gemma-4-E4B-coreml/tree/main?recursive=1
    https://huggingface.co/mlboydaisuke/gemma-4-E4B-coreml/resolve/main/{path}?download=true

Android:
  .litertlm single file
  Kotlin LiteRT-LM adapter
```

业务层不得依赖 CoreML-LLM、LiteRT-LM、SPM、Kotlin、Swift runtime 或具体
artifact 格式。

### 5.2 Runtime 抽象

Dart interface：

```dart
abstract interface class LlmRuntime {
  Future<void> initialize(LlmModelConfig config);

  Stream<LlmTokenEvent> generateStream({
    required String prompt,
    List<LlmAttachment> attachments = const [],
    LlmGenerationConfig config = const LlmGenerationConfig(),
  });

  Future<LlmResponse> generateOnce({
    required String prompt,
    List<LlmAttachment> attachments = const [],
    LlmGenerationConfig config = const LlmGenerationConfig(),
  });

  Future<LlmRuntimeStatus> getStatus();

  Future<void> cancel();

  Future<void> unload();
}
```

业务层只接触该接口。禁止：

```dart
// 禁止
Gemma4Runtime().generate(...);
LiteRtLmSession().generate(...);
MediaPipeLlmInference().run(...);
```

允许：

```dart
final response = await ref.read(llmRuntimeProvider).generateOnce(
  prompt: prompt,
  config: generationConfig,
);
```

### 5.3 模型 manifest

`app/assets/model_manifest.json`

当前 manifest 是 artifact-based schema，不再是单一 `.litertlm` schema。必须保留
`runtime`、`artifact_type`、`revision`、`selection_priority` 等字段。

```json
{
  "schema_version": "1.0",
  "models": [
    {
      "id": "gemma-4-e2b-it-coreml-ios",
      "display_name": "Gemma 4 E2B Core ML",
      "provider": "mlboydaisuke",
      "model_id": "mlboydaisuke/gemma-4-E2B-coreml",
      "repo_id": "mlboydaisuke/gemma-4-E2B-coreml",
      "runtime": "coreml_llm",
      "artifact_type": "coreml_bundle",
      "revision": "n1024",
      "source_commit": "n1024",
      "allow_patterns": [
        "model_config.json",
        "hf_model/config.json",
        "hf_model/tokenizer.json",
        "hf_model/tokenizer_config.json",
        "swa/chunk1.mlmodelc/**",
        "swa/chunk2_3way.mlmodelc/**",
        "swa/chunk3_3way.mlmodelc/**",
        "*.bin",
        "*.npy"
      ],
      "sha256": "BUNDLE_READINESS_CHECK",
      "size_bytes": 2583085056,
      "min_memory_gb": 8,
      "min_free_disk_bytes": 5166170112,
      "modalities": ["text"],
      "supports_thinking": true,
      "max_context_tokens": 2048,
      "default": true,
      "platforms": ["ios"],
      "selection_priority": 10
    },
    {
      "id": "gemma-4-e4b-it-coreml-ios",
      "display_name": "Gemma 4 E4B Core ML",
      "provider": "mlboydaisuke",
      "model_id": "mlboydaisuke/gemma-4-E4B-coreml",
      "repo_id": "mlboydaisuke/gemma-4-E4B-coreml",
      "runtime": "coreml_llm",
      "artifact_type": "coreml_bundle",
      "revision": "main",
      "source_commit": "main",
      "allow_patterns": [
        "*.json",
        "*.mlmodelc/**",
        "*.mlpackage/**",
        "*.bin",
        "*.npy",
        "*.txt",
        "hf_model/**"
      ],
      "sha256": "BUNDLE_READINESS_CHECK",
      "size_bytes": 3654467584,
      "min_memory_gb": 12,
      "min_free_disk_bytes": 7308935168,
      "modalities": ["text"],
      "supports_thinking": true,
      "max_context_tokens": 32000,
      "default": false,
      "platforms": ["ios"],
      "selection_priority": 20
    }
  ]
}
```

### 5.4 模型生命周期

详细实现方案见：

```
docs/MODEL_MANAGEMENT_IMPLEMENTATION_PLAN.md
```

```
not_installed
downloading
verifying
installed
loading
ready
failed
unloaded
```

当前 iOS 模型安装流程：

```
1. 检查设备内存与磁盘空间。
2. 若本地 bundle 不完整，进入 downloading。
3. 通过 HuggingFace tree API 获取 allow_patterns 匹配文件列表。
4. 通过 HuggingFace resolve URL 逐文件下载，先写入 .download 临时文件，再 rename。
5. Dio 下载失败时使用 dart:io HttpClient fallback，最多重试 3 次。
6. 下载后进入 verifying，按 CoreML bundle 必要文件做 readiness check。
7. 写入 Application Support/model_registry.json。
8. 如果当前 runtime 已加载其他模型，先 unload。
9. 调用 LlmRuntime.initialize。
10. 标记 ready。
```

当前实现说明：

```
E2B 必要 chunk:
  chunk1.mlmodelc/coremldata.bin
  chunk2_3way.mlmodelc/coremldata.bin
  chunk3_3way.mlmodelc/coremldata.bin

E4B 必要 chunk:
  chunk1.mlmodelc/coremldata.bin
  chunk2.mlmodelc/coremldata.bin
  chunk3.mlmodelc/coremldata.bin
  chunk4.mlmodelc/coremldata.bin

shared sidecar:
  model_config.json
  hf_model/config.json
  hf_model/tokenizer.json
  hf_model/tokenizer_config.json
  embed_tokens*.bin
  per_layer*.bin
  cos_*.npy
  sin_*.npy
```

### 5.5 模型部署注意事项

生产环境不建议把 2GB+ 模型直接放进 App 初始包：

```
首次启动后按需下载。
用户明确确认模型大小。
支持 Wi-Fi only 下载。
支持断点续传。
支持删除模型。
支持 Gemma 4 E2B / E4B 档位切换。
支持模型完整性校验。
```

当前代码已支持：

```
/models 作为 App 初始入口。
用户在 Chat 前选择 E2B 或 E4B。
E2B / E4B 均可进入同一下载、校验、加载、切换流程。
E2B Core ML n1024 已在本地完整下载验证通过。
切换模型时，如果 runtime 已 ready 且 loadedModelId 不同，会先 unload 再 initialize。
```

当前代码尚未支持或尚未验证：

```
background_downloader 断点续传 UI。
per-file SHA-256 manifest。
模型删除 UI。
E4B 完整下载和实机 initialize 验证。
Android runtime adapter 实机验证。
```

如果必须内置模型，需评估：

```
App Store / Play Store 包大小限制
初次安装成功率
热更新策略
模型许可证
设备存储空间
审核材料
```

## 6. 健康数据层

### 6.1 iOS HealthKit

HealthKit 数据属于高敏感数据。Apple 文档说明，HealthKit 要求用户对每个数据类型显式授权；用户可按类型分别允许或拒绝读写。App 请求 HealthKit 权限时必须包含 `NSHealthShareUsageDescription` 和 `NSHealthUpdateUsageDescription`，否则会崩溃。([Apple Developer](https://developer.apple.com/documentation/healthkit/protecting-user-privacy?utm_source=chatgpt.com))

iOS 原生层职责：

```
请求 HealthKit 权限。
读取用户授权的健康数据。
把 HealthKit 类型映射到统一 HealthMetricType。
不得把原始 HealthKit 数据直接上传。
不得在日志中打印 HealthKit 原始样本。
```

`Info.plist` 必须包含：

```xml
<key>NSHealthShareUsageDescription</key>
<string>We use your health data locally to generate private wellbeing insights.</string>

<key>NSHealthUpdateUsageDescription</key>
<string>We may write wellbeing records only if you explicitly enable this feature.</string>
```

第一版默认只读，不写 HealthKit。只有用户明确开启“写入正念记录 / 运动计划”等功能时，才申请写权限。

### 6.2 Android Health Connect

Health Connect 使用数据类型与权限声明模型。Android 官方文档说明，发布到 Play Store 前必须声明应用使用的 Health Connect 数据类型，否则用户可能无法授权访问对应类型。文档还说明后台读取、读取 30 天以前历史数据需要额外权限声明。([Android Developers](https://developer.android.com/health-and-fitness/health-connect/data-types?utm_source=chatgpt.com))

Android 原生层职责：

```
检查 Health Connect 可用性。
声明所需 Health Connect 权限。
请求用户授权。
读取用户授权的数据类型。
处理后台读取与历史读取权限。
把 Health Connect records 映射为统一 HealthSample。
```

### 6.3 默认读取数据类型

第一阶段允许读取：

```
步数
睡眠
运动分钟 / Apple Exercise Time
站立时间
运动记录
活动能量
基础能量
步行 + 跑步距离
爬楼层数
心率
静息心率
步行平均心率
HRV
体重
正念分钟
用户主动输入的 mood / stress / energy
```

默认不读取：

```
病历
用药
生殖健康
血糖
血压
精确运动路线
精确位置
联系人
原始日记全文
营养摄入
呼吸指标
环境 / 耳机音频暴露
高心率 / 低心率 / 心律不齐事件
```

若后续引入高敏感医疗数据，必须单独设计权限页、隐私页、数据生命周期和云端策略。

当前 iOS `HealthKitHostApiAdapter` 已实现聚合读取，但权限请求必须持续收敛到
`HealthMetricType` 实际使用集合。不得为了“以后可能用到”扩大 HealthKit
授权范围。每新增一个 HealthKit 类型，必须同步更新：

```
HealthMetricType
HealthAgentPlanner
HealthSummaryService period 支持规则
HealthKitHostApiAdapter.SummaryDescriptor
权限页文案
单元测试
```

### 6.4 Domain Model

```dart
enum HealthMetricType {
  steps,
  sleepSession,
  workoutSession,
  activeEnergy,
  basalEnergy,
  exerciseTime,
  standTime,
  distanceWalkingRunning,
  flightsClimbed,
  heartRate,
  restingHeartRate,
  walkingHeartRateAverage,
  hrv,
  weight,
  mindfulMinutes,
}

enum SensitivityLevel {
  low,
  medium,
  high,
  restricted,
}

class HealthSample {
  final String id;
  final HealthMetricType type;
  final double? numericValue;
  final String? textValue;
  final String unit;
  final DateTime startTime;
  final DateTime endTime;
  final String source;
  final SensitivityLevel sensitivity;
  final Map<String, Object?> metadata;
}
```

敏感等级规则：

```
low:
  steps, active minutes, generic exercise duration

medium:
  sleep, heart rate, resting heart rate, HRV, weight

high:
  mood, stress, journal-derived summary, inferred burnout signals

restricted:
  medical records, medication, reproductive health, precise location, raw journal, raw chat transcript
```

## 7. 本地数据库与加密

### 7.1 数据库选型

使用：

```
sqflite_sqlcipher + SQLCipher
```

sqflite_sqlcipher 是 sqflite 的 SQLCipher fork，文档说明它在 iOS 和 Android 上使用 SQLCipher，本体 API 接近 sqflite，但 `openDatabase` 增加 `password` 参数。([Dart packages](https://pub.dev/packages/sqflite_sqlcipher?utm_source=chatgpt.com))

SQLCipher 是 SQLite 的加密 fork，提供数据库文件 256-bit AES 加密、tamper detection、memory sanitization、key derivation 等能力。([GitHub](https://github.com/sqlcipher/sqlcipher?utm_source=chatgpt.com))

### 7.2 密钥策略

```
每次安装生成一个 256-bit databaseKey。
databaseKey 不写入数据库。
iOS 使用 Keychain 保存或包装密钥。
Android 使用 Keystore 保存或包装密钥。
数据库使用 SQLCipher 文件级加密。
restricted / high 字段再做字段级加密。
日志永远不输出 databaseKey、明文健康数据、prompt、LLM response。
```

### 7.3 数据库 schema

第一版模型 demo 不创建 `model_registry` 数据库表，模型安装状态先写入：

```
Application Support/model_registry.json
```

等健康数据 SQLCipher 数据库稳定后，再评估是否把模型 registry 迁入数据库。

```sql
CREATE TABLE health_samples (
  id TEXT PRIMARY KEY,
  type TEXT NOT NULL,
  numeric_value REAL,
  text_value_encrypted BLOB,
  unit TEXT NOT NULL,
  start_time INTEGER NOT NULL,
  end_time INTEGER NOT NULL,
  source TEXT NOT NULL,
  sensitivity TEXT NOT NULL,
  metadata_encrypted BLOB,
  created_at INTEGER NOT NULL
);

CREATE INDEX idx_health_samples_type_time
ON health_samples(type, start_time, end_time);

CREATE TABLE mood_logs (
  id TEXT PRIMARY KEY,
  mood_score INTEGER NOT NULL,
  stress_score INTEGER,
  energy_score INTEGER,
  note_encrypted BLOB,
  created_at INTEGER NOT NULL
);

CREATE TABLE behavior_events (
  id TEXT PRIMARY KEY,
  event_type TEXT NOT NULL,
  metadata_encrypted BLOB,
  created_at INTEGER NOT NULL
);

CREATE TABLE daily_summaries (
  date TEXT PRIMARY KEY,
  local_summary_encrypted BLOB NOT NULL,
  structured_json_encrypted BLOB NOT NULL,
  model_id TEXT,
  prompt_version TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE TABLE user_health_profile (
  key TEXT PRIMARY KEY,
  value_encrypted BLOB NOT NULL,
  confidence REAL NOT NULL,
  source TEXT NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE TABLE cloud_analysis_jobs (
  id TEXT PRIMARY KEY,
  payload_hash TEXT NOT NULL,
  anonymized_payload_encrypted BLOB NOT NULL,
  result_encrypted BLOB,
  status TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  completed_at INTEGER
);

CREATE TABLE model_registry (
  model_id TEXT PRIMARY KEY,
  display_name TEXT NOT NULL,
  local_path TEXT,
  sha256 TEXT NOT NULL,
  size_bytes INTEGER NOT NULL,
  min_memory_gb INTEGER,
  supports_text INTEGER NOT NULL,
  supports_image INTEGER NOT NULL,
  supports_audio INTEGER NOT NULL,
  supports_thinking INTEGER NOT NULL,
  status TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE TABLE privacy_audit_log (
  id TEXT PRIMARY KEY,
  event_type TEXT NOT NULL,
  payload_hash TEXT,
  redaction_version TEXT,
  created_at INTEGER NOT NULL
);
```

### 7.4 Migration 规则

```
任何 schema 变更必须新增 migration 文件。
不得直接修改历史 migration。
migration 必须有单元测试。
migration 必须支持从前两个 release 版本升级。
migration 失败时不得删除数据库。
```

## 8. 本地隐私、脱敏与可选外发边界

### 8.1 核心原则

```
原始健康数据不出端。
原始聊天不出端。
原始日记不出端。
第一版不做上传、不做云端分析、不做云端同步。
PrivacyFilter 第一版用于本地 prompt 上下文裁剪和敏感度控制。
RedactionReport 第一版用于本地审计和后续可解释隐私预览。
任何后续外发能力必须默认关闭，用户显式 opt-in，并经过单独设计和测试。
```

### 8.2 永远不得外发

```
姓名
邮箱
手机号
精确生日
精确地址
精确经纬度
联系人
设备唯一 ID
广告 ID
原始 HealthKit / Health Connect 样本
原始心率时间线
原始睡眠阶段时间线
原始聊天全文
原始日记全文
病历原文
用药原文
运动路线
任何可逆身份标识
```

### 8.3 Future Optional 外发白名单

第一版没有外发白名单。后续如果引入云端或导出能力，允许离开设备的内容只能是用户确认后的脱敏结构化摘要：

```json
{
  "schema_version": "1.0",
  "period_days": 7,
  "timezone_region": "Asia",
  "age_bucket": "25-34",
  "sleep_avg_hours": 6.4,
  "sleep_variability": "high",
  "step_avg": 6800,
  "exercise_minutes_total": 95,
  "resting_heart_rate_trend": "slightly_up",
  "mood_trend": "declining",
  "stress_signals": [
    "short_sleep",
    "low_activity",
    "negative_checkin"
  ],
  "goal": "improve_sleep_consistency"
}
```

### 8.4 PrivacyFilter 处理流程

```
Raw Local Data
  ↓
Normalize
  ↓
Aggregate
  ↓
Remove direct identifiers
  ↓
Generalize time
  ↓
Generalize age
  ↓
Remove exact location
  ↓
Remove raw text
  ↓
Sensitivity filtering
  ↓
Generate RedactionReport
  ↓
Local Privacy Review
  ↓
Local prompt context / optional future reviewed export
```

### 8.5 RedactionReport

```dart
class RedactionReport {
  final String redactionVersion;
  final List<String> removedFields;
  final List<String> generalizedFields;
  final List<String> retainedFields;
  final bool containsDirectIdentifiers;
  final bool containsRawHealthSamples;
  final bool containsRawJournalText;
  final bool containsPreciseLocation;
}
```

后续外发条件：

```
containsDirectIdentifiers == false
containsRawHealthSamples == false
containsRawJournalText == false
containsPreciseLocation == false
```

不满足即阻断外发。第一版没有外发入口。

## 9. Future Optional 云端 API 规范

本节不是第一版实施目标。`server/` 仅作为 future optional 预留，不参与当前离线 App demo、不参与默认产品闭环。

### 9.1 云端定位

如果后续引入云端，云端只做：

```
长期趋势分析
复杂归纳
非诊断性 wellbeing insight
结构化建议生成
多周趋势解释
```

云端不做：

```
诊断
治疗
处方
用药建议
急救判断
接收原始健康数据
接收原始聊天
接收原始日记
```

### 9.2 后端技术栈（Future Optional）

```
Python 3.12+
FastAPI
Pydantic
Uvicorn
httpx
structlog
pytest
ruff
mypy
```

部署优先级：

```
Cloud Run
Fly.io
Render
Cloudflare Workers, if TypeScript backend is preferred
```

### 9.3 后端目录（Future Optional）

```
server/
  app/
    main.py
    config.py

    api/
      routes/
        analyze.py
        health.py

    schemas/
      cloud_payload.py
      insight.py
      safety.py

    services/
      llm_client.py
      safety_guard.py
      recommendation_engine.py
      redaction_validator.py

    observability/
      logging.py
      request_id.py

  tests/
    test_redaction_validator.py
    test_analyze.py
    test_safety_guard.py

  pyproject.toml
  Dockerfile
```

### 9.4 API（Future Optional）

`POST /v1/analyze/weekly`

Request：

```json
{
  "schema_version": "1.0",
  "client_generated_id": "uuid",
  "period": {
    "start_date": "2026-04-18",
    "end_date": "2026-04-24",
    "timezone_region": "Asia"
  },
  "health_summary": {
    "sleep_avg_hours": 6.4,
    "sleep_variability": "high",
    "step_avg": 6800,
    "exercise_minutes_total": 95,
    "mood_trend": "declining",
    "stress_signals": ["short_sleep", "low_activity"]
  },
  "privacy": {
    "contains_raw_health_data": false,
    "contains_direct_identifiers": false,
    "contains_raw_journal": false,
    "contains_precise_location": false,
    "local_redaction_version": "2026.04.25"
  }
}
```

Response：

```json
{
  "schema_version": "1.0",
  "summary": "Your sleep pattern was less consistent this week, and lower activity may be contributing to reduced energy.",
  "insights": [
    {
      "category": "sleep",
      "severity": "medium",
      "title": "Sleep schedule variability",
      "explanation": "Your average sleep duration was acceptable, but the timing varied across the week.",
      "suggestion": "Try setting a consistent wind-down time for the next three nights."
    }
  ],
  "non_medical_disclaimer": "This is wellbeing guidance, not a diagnosis or medical treatment."
}
```

### 9.5 云端日志规则（Future Optional）

```
不得记录 request body。
不得记录 prompt 明文。
不得记录 LLM response 明文。
日志只记录 request_id、schema_version、error_code、latency_ms。
调试环境也不得绕过该规则。
```

## 10. AI 工作流与 Prompt 规范

### 10.1 本地 Daily Summary

用途：把本地健康数据转换为用户可读的每日摘要。

```
System:
You are a privacy-first wellbeing assistant.
You do not diagnose, prescribe, or provide medical treatment.
You summarize local health and behavior signals into non-medical wellbeing insights.
Do not mention raw identifiers.
Keep the output structured.

Input:
- sleep duration
- sleep schedule consistency
- steps
- exercise minutes
- heart rate trend
- mood check-in
- user goal

Output JSON:
{
  "summary": "...",
  "signals": [],
  "possible_factors": [],
  "suggested_actions": [],
  "risk_level": "low|medium|high",
  "needs_professional_help": false
}
```

### 10.2 本地 Wellbeing Coach

```
System:
You are a wellbeing coach, not a doctor.
Use supportive, practical, non-diagnostic language.
Do not diagnose disease.
Do not prescribe medication.
Do not advise the user to stop medication.
If the user asks for medical diagnosis, medication, or urgent care advice, redirect them to a qualified professional.

Context:
{local_health_profile}
{recent_daily_summaries}

User:
{message}
```

### 10.3 Privacy Filter Prompt

```
System:
You are a local privacy filter.
Your task is to transform sensitive local health context into a de-identified, structured summary.
Remove all direct identifiers, exact timestamps, exact locations, raw journal text, raw chat content, and raw health samples.
Return only JSON.

Input:
{local_summary}

Output:
{
  "safe_to_upload": true,
  "removed_fields": [],
  "generalized_fields": [],
  "payload": {}
}
```

### 10.4 Prompt 版本管理

```
当前阶段 prompt 集中在 application/ai/compact_health_prompt_builder.dart。
后续产品化 prompt 应迁移到 application/ai/prompts。
每个稳定 prompt 必须有 prompt_version。
daily_summaries 或持久化 insight 必须记录生成时使用的 prompt_version。
prompt 更新必须附带 regression test。
prompt 不得硬编码用户原始敏感数据离开本机。
```

### 10.5 Agent Skills 规范

本项目借鉴 Google AI Edge Gallery 的 Agent Skills 设计，但必须改造成隐私优先、受控工具系统。当前分支没有通用动态 skill runtime；已实机验证的是受控的一阶本地工具编排：

```
HealthAgentPlanner
  -> HealthSummaryService.getHealthSummary
  -> HealthKit aggregate read
  -> CompactHealthPromptBuilder
  -> LlmRuntime.generateOnce
```

核心原则：

```
AgentRuntime / LocalHealthAgentService 只依赖 LlmRuntime 和 application service。
AgentTool 只调用 application service 或 repository interface。
UI 不得直接执行 tool。
tool 不得直接调用 Pigeon、数据库、HealthKit、Health Connect、LiteRT-LM、Gemma runtime。
tool result 返回给模型前必须经过敏感度判断。
高敏或 restricted 结果不得原样进入 prompt。
需要改变数据、删除数据、上传数据、调用外部服务的 tool 必须用户确认。
```

当前阶段已允许且已实现的 first-party tool：

```
get_health_summary
```

后续第一方 skills 候选：

```
get_recent_health_summary
get_recent_mood_summary
search_local_wellbeing_memory
explain_privacy_redaction
get_model_status
suggest_non_medical_habit_plan
```

禁止默认启用：

```
任意远程 skill
任意 JS skill
任意系统 intent / app automation
任意未审查网络请求
上传原始健康样本、原始聊天、原始日记的 tool
绕过 PrivacyFilter 或 RedactionReport 的 tool
```

对应架构文档：

```
docs/AGENT_SKILLS_ARCHITECTURE.md
```

后续若引入 `dartantic_ai` 的通用 tool calling，必须保持当前 planner-first
路径可回退。模型输出的 tool call 不可信，必须经过本地 schema 解析、工具白名单
和参数校验后才允许执行。

## 11. 医疗与安全边界

### 11.1 产品定位

使用：

```
wellbeing assistant
lifestyle insight
health trend summary
self-reflection companion
privacy-first personal health companion
```

避免：

```
medical diagnosis
treatment
therapy replacement
clinical decision support
prescription
disease prediction
emergency triage
```

### 11.2 禁止输出

```
疾病诊断
药物剂量建议
停药建议
处方建议
心理疾病定性诊断
自伤鼓励
极端节食建议
严重症状延误就医建议
```

### 11.3 必须触发兜底

```
胸痛
呼吸困难
昏厥
严重出血
自杀意图
伤害他人意图
严重过敏反应
疑似中风症状
```

兜底文案：

```
我不能判断这是否属于医疗紧急情况。请立即联系当地紧急服务，或联系可信任的人陪你获得帮助。
```

### 11.4 免责声明

```
This app provides general wellbeing insights based on data you choose to process locally. It does not provide medical diagnosis, treatment, prescription, or emergency support. For medical concerns, consult a qualified healthcare professional.
```

## 12. UI 页面规范

必须具备：

```
Model Setup
  - 当前 App 初始入口为 /models
  - 用户先选择 Gemma 4 E2B 或 E4B，再进入 Chat
  - 显示模型大小、内存要求、磁盘要求和本地连接状态
  - 支持 Download and Load
  - 支持已 ready 后 Open Chat
  - 支持切换模型时重新加载选中模型
  - 下载或加载失败时显示错误并允许 Retry

Onboarding
  - 说明端侧 AI
  - 说明健康数据权限
  - 说明本地加密
  - 说明第一版离线运行，不做云端分析

Health Permission
  - 按数据类型说明用途
  - 不一次性请求所有高敏权限
  - 明确哪些数据只在本地处理

Model Status
  - 当前模型由 Model Setup 页面承载
  - 后续如保留独立 Model Status 页面，必须复用同一 model lifecycle/controller 状态，不得另写一套下载逻辑

Dashboard
  - 睡眠
  - 活动
  - 心率趋势
  - mood check-in
  - 本地 AI 摘要

Privacy Review
  - 显示本地 AI 将使用的字段
  - 显示本地 AI 不会使用的字段
  - 显示 redaction report
  - 后续如加入外发能力，必须用户确认后才允许

Insights
  - 本地 insight
  - 明确标记来源

Chat
  - 本地 wellbeing coach
  - 非诊断边界
  - 本地模型状态
```

## 13. Android 原生规范

### 13.1 技术栈

```
Kotlin
Flutter Android embedding
Pigeon generated HostApi
Gemma 4 runtime adapter
Health Connect Jetpack SDK
Android Keystore
WorkManager
```

### 13.2 Android Gradle 要求

```
minSdk: 28 或更高
targetSdk: 当前 Play Store 要求版本
compileSdk: 当前稳定 Android SDK
Kotlin: 当前稳定版本
```

如果 Gemma 4 runtime 要求更高系统版本，以 runtime 实测结果为准。

### 13.3 Android 权限

```xml
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />

<!-- Health Connect permissions: only declare what is used -->
<uses-permission android:name="android.permission.health.READ_STEPS" />
<uses-permission android:name="android.permission.health.READ_SLEEP" />
<uses-permission android:name="android.permission.health.READ_HEART_RATE" />
<uses-permission android:name="android.permission.health.READ_EXERCISE" />

<!-- Optional background / historical read -->
<uses-permission android:name="android.permission.health.READ_HEALTH_DATA_IN_BACKGROUND" />
<uses-permission android:name="android.permission.health.READ_HEALTH_DATA_HISTORY" />
```

不得声明未使用的 Health Connect 权限。

### 13.4 ProGuard

使用 SQLCipher 时，`android/app/proguard-rules.pro` 必须包含：

```
-keep class net.sqlcipher.** { *; }
```

sqflite_sqlcipher 文档明确要求 release code shrinking 下添加该规则。([Dart packages](https://pub.dev/packages/sqflite_sqlcipher?utm_source=chatgpt.com))

## 14. iOS 原生规范

### 14.1 技术栈

```
Swift
Flutter iOS embedding
MethodChannel adapter for current verified device path; Pigeon remains target for later typed bridge
CoreML-LLM Swift Package
Gemma 4 Core ML runtime adapter
HealthKit
Keychain
CryptoKit
BackgroundTasks
```

### 14.2 iOS Deployment Target

建议：

```
iOS 17.0+
```

端侧 AI 和 HealthKit 的目标用户群体通常使用较新设备。为了降低模型运行时和系统 API 兼容成本，不建议支持过低 iOS 版本。

### 14.3 Info.plist

```xml
<key>NSHealthShareUsageDescription</key>
<string>We use your health data locally to generate private wellbeing insights.</string>

<key>NSHealthUpdateUsageDescription</key>
<string>We write health records only when you explicitly enable this feature.</string>

<key>NSMicrophoneUsageDescription</key>
<string>Voice input is processed locally if you enable voice features.</string>
```

若当前版本不做语音输入，不要申请麦克风权限。

### 14.4 当前 iOS 实机路径保护

当前 iOS runtime 入口是：

```
app/lib/core/native/ios_llm_runtime.dart
app/ios/Runner/NativeBridge/LlmRuntimeHostApiAdapter.swift
```

当前 HealthKit 入口是：

```
app/lib/data/health/ios_health_data_gateway.dart
app/ios/Runner/NativeBridge/HealthKitHostApiAdapter.swift
```

后续 agent 不得把 iOS runtime 改回 LiteRT-LM / ObjC++ / C++ bridge 方案，除非用户明确要求做 fallback。CoreML-LLM adapter 的 compute units、timeout、bundle readiness 规则属于实机验证路径的一部分，修改必须附带设备验证说明。

## 15. AI Coding Agent 规则

本节是给 Codex / Claude 读取的约束。Agent 必须遵守。

### 15.1 禁止事项

```
不得绕过 PrivacyFilter 让敏感数据进入 prompt 或离开本机。
不得在日志中打印健康数据、prompt、response、数据库密钥。
不得让 UI 直接调用 native API。
不得让 UI 直接访问数据库。
不得硬编码模型文件路径。
不得硬编码用户隐私字段。
不得修改 generated 文件。
不得删除 migration。
不得在未更新测试的情况下修改 prompt。
当前阶段不得引入云端依赖；后续云端能力必须单独设计、默认关闭并经用户 opt-in。
不得引入广告、analytics SDK 读取健康数据。
不得把已实机验证的 iOS CoreML-LLM 路径改回旧 LiteRT-LM iOS 方案。
不得扩大 HealthKit 权限范围，除非同步更新产品文案、隐私边界和测试。
```

### 15.2 修改 native bridge 的流程

当前实机路径允许保留 MethodChannel。若修改的是当前 MethodChannel adapter：

```
1. 保持 Dart 业务接口不变。
2. 更新 MethodChannel payload schema。
3. 更新 Swift / Kotlin adapter。
4. 添加 adapter 单元测试或实机 smoke test。
5. 更新本文件或相关 docs。
```

若是新建或迁移 Pigeon bridge：

```
1. 修改 app/pigeon/*.dart。
2. 执行 make gen。
3. 更新 Dart adapter。
4. 更新 Kotlin HostApi。
5. 更新 Swift HostApi。
6. 添加 bridge 单元测试或 smoke test。
7. 更新 ARCHITECTURE.md。
```

### 15.3 新增健康数据类型的流程

```
1. 在 HealthMetricType 添加类型。
2. 添加 sensitivity classification。
3. 添加 HealthKit 映射。
4. 如该类型进入 Android 范围，添加 Health Connect 映射。
5. 添加 permission 文案。
6. 添加数据库 migration 如有必要。
7. 添加 PrivacyFilter 测试。
8. 更新用户隐私说明。
9. 确认 HealthKitHostApiAdapter.allReadTypes 没有包含未使用类型。
```

### 15.4 新增 Future Optional 外发字段的流程

```
1. 明确该字段不属于第一版离线主线。
2. 设计用户 opt-in 和本地隐私预览。
3. 修改 future export payload。
2. 修改 RedactionReport。
3. 添加 PrivacyFilter 测试。
4. 如存在 server，再修改 server Pydantic schema。
5. 添加 redaction validator 测试。
6. 确认字段不包含直接标识符、原始健康样本、原始文本。
```

## 16. 工具链

### 16.1 本地开发工具 （需要时间配置）

```
Flutter stable via FVM
Dart SDK from Flutter
Android Studio
Xcode
CocoaPods
Ruby + Bundler for Fastlane
Python 3.12+
uv for future optional backend dependency management
GitHub CLI
Make
```

### 16.2 Makefile

iOS build 使用 macOS runner，成本较高。正式环境应增加：

```
ios-build
android-release-build
fastlane-deploy-internal
```

## 17. 测试规范

### 17.1 必测模块

```
PrivacyFilter
RedactionReport
HealthNormalizationService
PromptBuilder
LocalSummaryService
ModelLifecycleService
EncryptedDatabase migrations
MedicalSafetyGuard
```

### 17.2 Golden Test

覆盖：

```
Privacy Review 页面
Dashboard 页面
Model Status 页面
Health Permission 页面
```

### 17.3 Integration Test

覆盖：

```
首次启动
健康权限授权
导入健康数据
创建 mood log
生成本地 summary
进入 privacy review
显示 insight
取消模型生成
模型 unload
```

### 17.4 Native Smoke Test

Android / iOS 均需：

```
模型文件存在
SHA-256 正确
runtime initialize 成功
ready prompt 成功
generateOnce 成功
cancel 成功
unload 成功
健康权限请求成功
健康数据读取返回空集时不崩溃
```

## 18. 后续升级路线

### Phase 1：基础产品化

```
完善模型管理器剩余能力。
已支持 iOS E2B / E4B 选择、下载流程、加载和切换。
补齐 background_downloader 断点续传 UI。
补齐模型删除。
补齐 per-file hash 校验。
完成 E4B 完整下载和实机 initialize 验证。
完成本地加密数据库。
完成 HealthKit / Health Connect 原生 adapter。
完成隐私预览。
```

### Phase 2：长期健康画像

```
每日摘要。
每周摘要。
趋势检测。
目标追踪。
用户偏好记忆。
本地健康画像版本化。
```

### Phase 3：本地 RAG 与记忆

```
本地 embedding 模型。
daily summary embedding。
本地向量检索。
长期情绪和睡眠触发因素记忆。
可删除、可导出、可重建的 memory store。
```

早期可用：

```
SQLite + cosine scan
```

后续可升级为：

```
ObjectBox vector
SQLite vector extension
自定义 HNSW index
Rust local retrieval core
```

### Phase 4：多模态与语音

```
语音 check-in
本地 STT
本地 TTS
VAD
图片输入
健康截图理解
运动姿态或饮食图像分析
```

候选技术：

```
STT: sherpa-onnx / whisper.cpp
TTS: Piper / Kokoro / platform TTS
VAD: Silero VAD / WebRTC VAD
Vision: Gemma 4 multimodal / MediaPipe Tasks Vision
```

### Phase 5：核心模块跨端复用升级

Flutter 可以长期保留。若后续要提升核心逻辑复用与性能，可引入：

```
Rust Core
  - PrivacyFilter
  - local vector retrieval
  - crypto helper
  - health trend engine

或 KMP Shared Core
  - PromptBuilder
  - ModelRegistry
  - HealthSummaryEngine
  - FutureExportPayloadBuilder
  - AgentRuntime
```

不建议第一阶段重写 Flutter UI。升级应从核心算法模块开始，而不是 UI。

## 19. 文档清单

仓库必须包含：

```
README.md
TECH_STACK.md
ARCHITECTURE.md
AI_CODING_GUIDE.md
PRIVACY_MODEL.md
MODEL_RUNTIME.md
HEALTH_DATA_SCHEMA.md
API_SPEC.md (future optional cloud only)
PROMPT_REGISTRY.md
SAFETY_BOUNDARY.md
RELEASE_CHECKLIST.md
```

`AI_CODING_GUIDE.md` 必须包含本文第 15 节的 agent 规则。

## 20. 最终约束

本项目的核心不是“能调用模型”，而是以下闭环：

```
用户健康数据在本地读取。
本地模型生成个性化健康理解。
敏感数据本地加密。
本地 prompt 前进行隐私过滤。
第一版不做云端分析、不做上传、不做云端同步。
后续任何外发能力都必须默认关闭、用户显式 opt-in、且只能发送已审查的匿名结构化摘要。
所有模型 runtime 可替换。
所有隐私规则可测试。
所有安全边界可回归。
```

实施团队和 AI agent 在任何改动中必须优先保证：

```
隐私边界
数据加密
本地优先
模型可替换
健康建议非诊断
可测试性
可回滚性
```
