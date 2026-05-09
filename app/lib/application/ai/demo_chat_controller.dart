import '../../domain/ai/llm_response.dart';
import '../../domain/ai/llm_runtime.dart';
import '../../domain/ai/model_install_progress.dart';
import '../../domain/ai/model_manifest_entry.dart';
import '../health/health_prompt_context_service.dart';
import 'generation_budget_policy.dart';
import 'local_coach_prompt_builder.dart';
import 'model/device_capabilities_reader.dart';
import 'model/model_catalog.dart';
import 'model/model_lifecycle_service.dart';
import 'model/model_selection_service.dart';

class DemoChatController {
  const DemoChatController({
    required ModelCatalog catalog,
    required DeviceCapabilitiesReader deviceCapabilitiesReader,
    required ModelSelectionService selectionService,
    required ModelLifecycleService lifecycleService,
    required LlmRuntime runtime,
    HealthPromptContextService? healthPromptContextService,
    LocalCoachPromptBuilder promptBuilder = const LocalCoachPromptBuilder(),
    GenerationBudgetPolicy generationBudgetPolicy =
        const GenerationBudgetPolicy(),
  }) : _catalog = catalog,
       _deviceCapabilitiesReader = deviceCapabilitiesReader,
       _selectionService = selectionService,
       _lifecycleService = lifecycleService,
       _runtime = runtime,
       _healthPromptContextService = healthPromptContextService,
       _promptBuilder = promptBuilder,
       _generationBudgetPolicy = generationBudgetPolicy;

  static const String defaultPrompt = 'What is the capital of France?';
  static const String defaultPreferredModelId = String.fromEnvironment(
    'GEMMA_MVP_MODEL_ID',
    defaultValue: 'gemma-4-e2b-it-coreml-ios',
  );

  static const String continuationPromptPrefix =
      'Continue the previous answer from exactly where it stopped. '
      'Do not restart.';
  static const Duration healthPromptContextTimeout = Duration(seconds: 10);

  final ModelCatalog _catalog;
  final DeviceCapabilitiesReader _deviceCapabilitiesReader;
  final ModelSelectionService _selectionService;
  final ModelLifecycleService _lifecycleService;
  final LlmRuntime _runtime;
  final HealthPromptContextService? _healthPromptContextService;
  final LocalCoachPromptBuilder _promptBuilder;
  final GenerationBudgetPolicy _generationBudgetPolicy;

  Future<ModelManifestEntry> _selectModel({
    String preferredModelId = defaultPreferredModelId,
  }) async {
    final capabilities = await _deviceCapabilitiesReader.read();
    final manifest = await _catalog.load();
    final model = _selectionService.select(
      manifest: manifest,
      capabilities: capabilities,
      preferredModelId: preferredModelId,
    );
    return model;
  }

  Stream<ModelInstallProgress> prepareModel({
    String preferredModelId = defaultPreferredModelId,
  }) {
    return _lifecycleService.prepareDemoModel(
      preferredModelId: preferredModelId,
    );
  }

  Future<LlmResponse> ask({
    required String prompt,
    GenerationIntent intent = GenerationIntent.chat,
    int conversationHistoryTokenEstimate = 0,
  }) async {
    final normalizedPrompt = prompt.trim();
    if (normalizedPrompt.isEmpty) {
      throw ArgumentError.value(prompt, 'prompt', 'Prompt must not be empty.');
    }

    final status = await _runtime.getStatus();
    if (status.state != 'ready') {
      throw StateError('Model is not ready. Prepare the model first.');
    }

    final finalPrompt = await _buildPrompt(normalizedPrompt);
    final model = await _selectModel();
    final config = _generationBudgetPolicy.buildConfig(
      model: model,
      prompt: finalPrompt,
      intent: intent,
      conversationHistoryTokenEstimate: conversationHistoryTokenEstimate,
    );
    final response = await _runtime.generateOnce(
      prompt: finalPrompt,
      config: config,
    );
    var text = _usableText(response.text);
    if (text.isEmpty) {
      final fallbackConfig = _generationBudgetPolicy.buildConfig(
        model: model,
        prompt: normalizedPrompt,
        intent: intent,
        conversationHistoryTokenEstimate: conversationHistoryTokenEstimate,
      );
      final fallbackResponse = await _runtime.generateOnce(
        prompt: normalizedPrompt,
        config: fallbackConfig,
      );
      text = _usableText(fallbackResponse.text);
      if (text.isEmpty) {
        throw StateError('Gemma returned no usable text.');
      }
    }

    final continuationLimit = _generationBudgetPolicy.continuationCountFor(
      intent,
    );
    var continuationCount = 0;
    while (continuationCount < continuationLimit &&
        _generationBudgetPolicy.looksTruncated(
          text: text,
          maxTokens: config.maxTokens,
        )) {
      continuationCount += 1;
      final continuation = await _runtime.generateOnce(
        prompt: _continuationPrompt(
          originalPrompt: finalPrompt,
          answerSoFar: text,
        ),
        config: config,
      );
      final continuationText = _usableText(continuation.text);
      if (continuationText.isEmpty) {
        break;
      }
      text = _mergeContinuation(text, continuationText);
    }

    if (_generationBudgetPolicy.looksTruncated(
      text: text,
      maxTokens: config.maxTokens,
    )) {
      text = '$text\n\nResponse may be incomplete.';
    }

    return LlmResponse(text: text, modelId: response.modelId);
  }

  Future<String> _buildPrompt(String userPrompt) async {
    final healthPromptContextService = _healthPromptContextService;
    final healthContext = healthPromptContextService == null
        ? LocalHealthPromptContext.noData()
        : await healthPromptContextService
              .buildForChat()
              .timeout(
                healthPromptContextTimeout,
                onTimeout: () =>
                    LocalHealthPromptContext.noData('health context timeout'),
              )
              .catchError(
                (_) => LocalHealthPromptContext.noData(
                  'health context unavailable',
                ),
              );
    return _promptBuilder.build(
      userMessage: userPrompt,
      healthContext: healthContext,
    );
  }

  String _usableText(String text) {
    return text.replaceAll('<pad>', '').trim();
  }

  String _continuationPrompt({
    required String originalPrompt,
    required String answerSoFar,
  }) {
    return '$continuationPromptPrefix\n\n'
        'User request:\n$originalPrompt\n\n'
        'Answer so far:\n$answerSoFar\n\n'
        'Continue:';
  }

  String _mergeContinuation(String first, String second) {
    final normalizedFirst = first.trimRight();
    final normalizedSecond = second.trimLeft();
    return '$normalizedFirst\n$normalizedSecond';
  }
}
