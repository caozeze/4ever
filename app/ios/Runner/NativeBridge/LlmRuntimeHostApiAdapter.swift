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
  private var generationTask: Task<Void, Never>?

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
      result(nil)
    case "unload":
      generationTask?.cancel()
      generationTask = nil
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

    Task {
      do {
        let directory = try await resolveModelDirectory(
          modelId: modelId,
          localPath: localPath
        )
        let computeUnits = selectedComputeUnits()
        NSLog("[CoreMLLLM] initialize modelId=%@ path=%@ computeUnits=%@", modelId, directory.path, String(describing: computeUnits))
        let loaded = try await CoreMLLLM.load(from: directory, computeUnits: computeUnits) { status in
          NSLog("[CoreMLLLM] %@", status)
        }
        loaded.mtpEnabled = false
        loaded.drafterUnionEnabled = false
        loaded.crossVocabEnabled = false
        loaded.lookaheadEnabled = false
        NSLog("[CoreMLLLM] speculative paths disabled for MVP serial decode")
        DispatchQueue.main.async {
          self.llm = loaded
          self.loadedModelId = modelId
          self.state = "ready"
          result(nil)
        }
      } catch {
        DispatchQueue.main.async {
          self.llm = nil
          self.loadedModelId = nil
          self.state = "failed"
          self.lastErrorCode = NativeErrorCode.modelLoadFailed.rawValue
          self.lastErrorMessage = String(describing: error)
          result(nativeFlutterError(.modelLoadFailed, message: String(describing: error)))
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
    generationTask = Task { [weak self] in
      do {
        NSLog("[CoreMLLLM] generateOnce modelId=%@ promptLength=%ld maxTokens=%ld promptPrefix=%@", modelId, prompt.count, maxTokens, String(prompt.prefix(96)))
        let text = try await llm.generate(prompt, maxTokens: maxTokens)
        let wasCancelled = Task.isCancelled
        DispatchQueue.main.async {
          guard !wasCancelled else {
            result(nativeFlutterError(.generationCancelled, message: "Generation was cancelled."))
            return
          }
          NSLog("[CoreMLLLM] generateOnce outputLength=%ld outputPrefix=%@", text.count, String(text.prefix(160)))
          guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            result(nativeFlutterError(.generationEmptyOutput, message: "CoreML-LLM returned empty output."))
            return
          }
          result([
            "text": text,
            "model_id": modelId
          ])
          self?.generationTask = nil
        }
      } catch is CancellationError {
        DispatchQueue.main.async {
          result(nativeFlutterError(.generationCancelled, message: "Generation was cancelled."))
          self?.generationTask = nil
        }
      } catch {
        DispatchQueue.main.async {
          self?.lastErrorCode = NativeErrorCode.modelRuntimeInternal.rawValue
          self?.lastErrorMessage = String(describing: error)
          result(nativeFlutterError(.modelRuntimeInternal, message: String(describing: error)))
          self?.generationTask = nil
        }
      }
    }
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

    guard let modelInfo = coreMlModelInfo(for: modelId) else {
      throw NSError(
        domain: "GemmaLocalLlmRuntime",
        code: 1,
        userInfo: [
          NSLocalizedDescriptionKey: "No CoreML downloader mapping for model id \(modelId)."
        ]
      )
    }

    DispatchQueue.main.async {
      self.state = "downloading"
    }
    if modelId == "gemma-4-e2b-it-coreml-ios" {
      UserDefaults.standard.set(false, forKey: ModelDownloader.includeMultimodalKey)
    }

    let modelURL = try await ModelDownloader.shared.download(modelInfo)
    let directory = modelURL.deletingLastPathComponent()
    guard isCoreMlBundleReady(at: directory) else {
      throw NSError(
        domain: "GemmaLocalLlmRuntime",
        code: 2,
        userInfo: [
          NSLocalizedDescriptionKey: "Downloaded CoreML bundle is missing required model files."
        ]
      )
    }
    DispatchQueue.main.async {
      self.state = "loading"
    }
    return directory
  }

  private func coreMlModelInfo(for modelId: String) -> ModelDownloader.ModelInfo? {
    switch modelId {
    case "gemma-4-e2b-it-coreml-ios":
      return ModelDownloader.ModelInfo.gemma4e2b3way
    case "gemma-4-e4b-it-coreml-ios":
      return ModelDownloader.ModelInfo.gemma4e4b
    default:
      return nil
    }
  }

  private func selectedComputeUnits() -> MLComputeUnits {
    let value = ProcessInfo.processInfo.environment["GEMMA_MVP_COMPUTE_UNITS"]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    switch value {
    case "cpu", "cpuonly":
      return .cpuOnly
    case "gpu", "cpuandgpu":
      return .cpuAndGPU
    case "all":
      return .all
    default:
      return .cpuAndNeuralEngine
    }
  }

  private func isCoreMlBundleReady(at directory: URL) -> Bool {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
          isDirectory.boolValue,
          FileManager.default.fileExists(atPath: directory.appendingPathComponent("model_config.json").path) else {
      return false
    }

    let chunk1 = directory.appendingPathComponent("chunk1.mlmodelc/coremldata.bin")
    let chunk2 = directory.appendingPathComponent("chunk2_3way.mlmodelc/coremldata.bin")
    let chunk3 = directory.appendingPathComponent("chunk3_3way.mlmodelc/coremldata.bin")
    let model = directory.appendingPathComponent("model.mlmodelc")
    let package = directory.appendingPathComponent("model.mlpackage")
    let tokenizer = directory.appendingPathComponent("hf_model")
    let hasChunkedModel = FileManager.default.fileExists(atPath: chunk1.path)
      && FileManager.default.fileExists(atPath: chunk2.path)
      && FileManager.default.fileExists(atPath: chunk3.path)
    let hasModel = hasChunkedModel
      || FileManager.default.fileExists(atPath: model.path)
      || FileManager.default.fileExists(atPath: package.path)
    return hasModel && FileManager.default.fileExists(atPath: tokenizer.path)
  }
}
