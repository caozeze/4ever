import Flutter
import Foundation
import CoreML
import CoreMLLLM

final class LlmRuntimeHostApiAdapter: NSObject {
  private var llm: CoreMLLLM?
  private var loadedModelId: String?
  private var state = "unloaded"
  private var lastErrorCode: String?
  private var lastErrorMessage: String?
  private var initializationTask: Task<Void, Never>?
  private var activeInitializationId: UUID?
  private var activeInitializationResult: FlutterResult?
  private var generationTask: Task<Void, Never>?
  private var activeGenerationId: UUID?
  private var initializationTimeoutNanoseconds: UInt64 {
    return 90_000_000_000
  }
  private var generationTimeoutNanoseconds: UInt64 {
    return 300_000_000_000
  }

  func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "com.gemmalocal.native/llm_runtime",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler(handle)
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "initialize":
      initialize(call.arguments, result: result)
    case "generateOnce":
      generateOnce(call.arguments, result: result)
    case "startStream":
      result(nativeFlutterError(.modelRuntimeInternal, message: "Token streaming is not wired yet."))
    case "getStatus":
      result(statusPayload())
    case "cancel":
      generationTask?.cancel()
      generationTask = nil
      activeGenerationId = nil
      result(nil)
    case "unload":
      if let activeInitializationId, let activeInitializationResult {
        completeInitialization(
          activeInitializationId,
          result: activeInitializationResult,
          payload: nativeFlutterError(.modelLoadFailed, message: "Model initialization was cancelled.")
        )
      }
      initializationTask?.cancel()
      initializationTask = nil
      generationTask?.cancel()
      generationTask = nil
      activeGenerationId = nil
      llm = nil
      loadedModelId = nil
      state = "unloaded"
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func initialize(_ arguments: Any?, result: @escaping FlutterResult) {
    guard let payload = arguments as? [String: Any],
          let modelId = payload["model_id"] as? String,
          let localPath = payload["local_path"] as? String,
          let runtime = payload["runtime"] as? String,
          let artifactType = payload["artifact_type"] as? String else {
      result(nativeFlutterError(.unknown, message: "Invalid model config."))
      return
    }

    guard runtime == "coreml_llm", artifactType == "coreml_bundle" else {
      state = "failed"
      lastErrorCode = NativeErrorCode.modelUnsupportedDevice.rawValue
      lastErrorMessage = "iOS Core ML adapter only supports coreml_llm/coreml_bundle."
      result(nativeFlutterError(.modelUnsupportedDevice, message: lastErrorMessage!))
      return
    }

    state = "loading"
    lastErrorCode = nil
    lastErrorMessage = nil
    if let activeInitializationId, let activeInitializationResult {
      completeInitialization(
        activeInitializationId,
        result: activeInitializationResult,
        payload: nativeFlutterError(.modelLoadFailed, message: "Model initialization was replaced.")
      )
    }
    initializationTask?.cancel()
    activeInitializationId = nil
    activeInitializationResult = nil
    let initializationId = UUID()
    activeInitializationId = initializationId
    activeInitializationResult = result
    NSLog("[CoreMLLLM] event=model_initialize_start model_id=%@", modelId)

    initializationTask = Task { [weak self] in
      let loadTask = Task<CoreMLLLM, Error> { [weak self] in
        guard let self else {
          throw CancellationError()
        }
        let directory = try await self.resolveModelDirectory(
          modelId: modelId,
          localPath: localPath
        )
        let computeUnits = self.selectedComputeUnits()
        NSLog("[CoreMLLLM] initialize modelId=%@ path=%@ computeUnits=%@", modelId, directory.path, String(describing: computeUnits))
        let loaded = try await CoreMLLLM.load(from: directory, computeUnits: computeUnits) { status in
          NSLog("[CoreMLLLM] %@", status)
        }
        loaded.mtpEnabled = false
        loaded.drafterUnionEnabled = false
        loaded.crossVocabEnabled = false
        loaded.lookaheadEnabled = false
        NSLog("[CoreMLLLM] speculative paths disabled for MVP serial decode")
        return loaded
      }
      let timeoutTask = Task { [weak self] in
        try? await Task.sleep(nanoseconds: self?.initializationTimeoutNanoseconds ?? 300_000_000_000)
        guard !Task.isCancelled else {
          return
        }
        loadTask.cancel()
        DispatchQueue.main.async {
          guard let self, self.activeInitializationId == initializationId else {
            return
          }
          self.llm = nil
          self.loadedModelId = nil
          self.state = "failed"
          self.lastErrorCode = NativeErrorCode.modelLoadFailed.rawValue
          self.lastErrorMessage = "Model initialization timed out."
          NSLog("[CoreMLLLM] event=model_initialize_timeout model_id=%@ error_code=%@", modelId, NativeErrorCode.modelLoadFailed.rawValue)
          self.completeInitialization(
            initializationId,
            result: result,
            payload: nativeFlutterError(.modelLoadFailed, message: self.lastErrorMessage!)
          )
        }
      }
      do {
        let loaded = try await loadTask.value
        timeoutTask.cancel()
        DispatchQueue.main.async {
          guard let self, self.activeInitializationId == initializationId else {
            return
          }
          self.llm = loaded
          self.loadedModelId = modelId
          self.state = "ready"
          NSLog("[CoreMLLLM] event=model_initialize_ready model_id=%@", modelId)
          self.completeInitialization(initializationId, result: result, payload: nil)
        }
      } catch is CancellationError {
        timeoutTask.cancel()
        DispatchQueue.main.async {
          guard let self, self.activeInitializationId == initializationId else {
            return
          }
          self.state = "failed"
          self.lastErrorCode = NativeErrorCode.modelLoadFailed.rawValue
          self.lastErrorMessage = "Model initialization was cancelled."
          NSLog("[CoreMLLLM] event=model_initialize_failed model_id=%@ error_code=%@", modelId, NativeErrorCode.modelLoadFailed.rawValue)
          self.completeInitialization(
            initializationId,
            result: result,
            payload: nativeFlutterError(.modelLoadFailed, message: "Model initialization was cancelled.")
          )
        }
      } catch {
        timeoutTask.cancel()
        DispatchQueue.main.async {
          guard let self, self.activeInitializationId == initializationId else {
            return
          }
          self.llm = nil
          self.loadedModelId = nil
          self.state = "failed"
          self.lastErrorCode = NativeErrorCode.modelLoadFailed.rawValue
          self.lastErrorMessage = String(describing: error)
          NSLog("[CoreMLLLM] event=model_initialize_failed model_id=%@ error_code=%@", modelId, NativeErrorCode.modelLoadFailed.rawValue)
          self.completeInitialization(
            initializationId,
            result: result,
            payload: nativeFlutterError(.modelLoadFailed, message: String(describing: error))
          )
        }
      }
    }
  }

  private func generateOnce(_ arguments: Any?, result: @escaping FlutterResult) {
    guard state == "ready", let modelId = loadedModelId, let llm else {
      result(nativeFlutterError(.modelLoadFailed, message: "No local model is loaded."))
      return
    }

    guard let payload = arguments as? [String: Any],
          let prompt = payload["prompt"] as? String else {
      result(nativeFlutterError(.unknown, message: "Invalid generation request."))
      return
    }

    let config = payload["config"] as? [String: Any]
    let maxTokens = config?["max_tokens"] as? Int ?? 2048

    generationTask?.cancel()
    let generationId = UUID()
    activeGenerationId = generationId
    generationTask = Task { [weak self] in
      let decodeTask = Task<String, Error> {
        return try await llm.generate(prompt, maxTokens: maxTokens)
      }
      let timeoutTask = Task { [weak self] in
        try? await Task.sleep(nanoseconds: self?.generationTimeoutNanoseconds ?? 120_000_000_000)
        guard !Task.isCancelled else {
          return
        }
        decodeTask.cancel()
        NSLog("[CoreMLLLM] generateOnce timeout reached; cancelling decode")
      }
      do {
        NSLog("[CoreMLLLM] generateOnce modelId=%@ promptLength=%ld maxTokens=%ld", modelId, prompt.count, maxTokens)
        let text = try await decodeTask.value
        timeoutTask.cancel()
        let wasCancelled = Task.isCancelled
        DispatchQueue.main.async {
          guard !wasCancelled else {
            self?.completeGeneration(
              generationId,
              result: result,
              payload: nativeFlutterError(.generationCancelled, message: "Generation was cancelled.")
            )
            return
          }
          NSLog("[CoreMLLLM] generateOnce outputLength=%ld", text.count)
          guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            self?.lastErrorCode = NativeErrorCode.generationEmptyOutput.rawValue
            self?.lastErrorMessage = "CoreML-LLM returned empty output."
            self?.completeGeneration(
              generationId,
              result: result,
              payload: nativeFlutterError(.generationEmptyOutput, message: "CoreML-LLM returned empty output.")
            )
            return
          }
          self?.completeGeneration(
            generationId,
            result: result,
            payload: [
              "text": text,
              "model_id": modelId
            ]
          )
        }
      } catch is CancellationError {
        timeoutTask.cancel()
        DispatchQueue.main.async {
          self?.completeGeneration(
            generationId,
            result: result,
            payload: nativeFlutterError(.generationTimeout, message: "Generation timed out before producing text.")
          )
        }
      } catch {
        timeoutTask.cancel()
        DispatchQueue.main.async {
          self?.lastErrorCode = NativeErrorCode.modelRuntimeInternal.rawValue
          self?.lastErrorMessage = String(describing: error)
          self?.completeGeneration(
            generationId,
            result: result,
            payload: nativeFlutterError(.modelRuntimeInternal, message: String(describing: error))
          )
        }
      }
    }
  }

  private func completeGeneration(_ generationId: UUID, result: FlutterResult, payload: Any) {
    guard activeGenerationId == generationId else {
      return
    }
    activeGenerationId = nil
    generationTask = nil
    result(payload)
  }

  private func completeInitialization(_ initializationId: UUID, result: FlutterResult, payload: Any?) {
    guard activeInitializationId == initializationId else {
      return
    }
    activeInitializationId = nil
    activeInitializationResult = nil
    initializationTask = nil
    result(payload)
  }

  private func statusPayload() -> [String: Any?] {
    [
      "state": state,
      "error_code": lastErrorCode,
      "error_message": lastErrorMessage,
      "used_memory_mb": nil,
      "loaded_model_id": loadedModelId
    ]
  }

  private func resolveModelDirectory(modelId: String, localPath: String) async throws -> URL {
    let localDirectory = URL(fileURLWithPath: localPath, isDirectory: true)
    if isCoreMlBundleReady(at: localDirectory) {
      return localDirectory
    }

    throw NSError(
      domain: "GemmaLocalLlmRuntime",
      code: 1,
      userInfo: [
        NSLocalizedDescriptionKey: "Local CoreML bundle is not ready at \(localPath)."
      ]
    )
  }

  private func selectedComputeUnits() -> MLComputeUnits {
    let value = ProcessInfo.processInfo.environment["GEMMA_MVP_COMPUTE_UNITS"]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    switch value {
    case "cpu", "cpuonly":
      return .cpuOnly
    case "gpu":
      NSLog("[CoreMLLLM] GEMMA_MVP_COMPUTE_UNITS=gpu is not a supported CoreML mode for this bundle; using cpuAndNeuralEngine")
      return .cpuAndNeuralEngine
    case "cpuandgpu":
      return .cpuAndGPU
    case "all":
      return .all
    case "cpuane", "cpuandneuralengine":
      return .cpuAndNeuralEngine
    default:
      return .cpuAndNeuralEngine
    }
  }

  private func isCoreMlBundleReady(at directory: URL) -> Bool {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
          isDirectory.boolValue else {
      return false
    }

    let requiredRelativePaths = [
      "model_config.json",
      "hf_model/config.json",
      "hf_model/tokenizer.json",
      "hf_model/tokenizer_config.json",
      "chunk1.mlmodelc/coremldata.bin",
      "chunk2_3way.mlmodelc/coremldata.bin",
      "chunk3_3way.mlmodelc/coremldata.bin",
      "embed_tokens_q8.bin",
      "embed_tokens_scales.bin",
      "embed_tokens_per_layer_q8.bin",
      "embed_tokens_per_layer_scales.bin",
      "per_layer_projection.bin",
      "per_layer_norm_weight.bin",
      "cos_sliding.npy",
      "sin_sliding.npy",
      "cos_full.npy",
      "sin_full.npy"
    ]

    for relativePath in requiredRelativePaths {
      let file = directory.appendingPathComponent(relativePath)
      guard FileManager.default.fileExists(atPath: file.path) else {
        NSLog("[CoreMLLLM] missing required local model file %@", relativePath)
        return false
      }
    }
    return true
  }
}
