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
  private var activeGenerationId: UUID?
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
