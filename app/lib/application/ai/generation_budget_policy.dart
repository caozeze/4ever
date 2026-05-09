import '../../domain/ai/llm_generation_config.dart';
import '../../domain/ai/model_manifest_entry.dart';

enum GenerationIntent { shortChat, chat, detailed, report }

class GenerationBudget {
  const GenerationBudget({
    required this.maxTokens,
    required this.estimatedInputTokens,
    required this.reason,
  });

  final int maxTokens;
  final int estimatedInputTokens;
  final String reason;
}

class GenerationBudgetPolicy {
  const GenerationBudgetPolicy({
    this.safetyMarginTokens = 128,
    this.minimumOutputTokens = 8,
  });

  final int safetyMarginTokens;
  final int minimumOutputTokens;

  GenerationBudget buildBudget({
    required ModelManifestEntry model,
    required String prompt,
    required GenerationIntent intent,
    int conversationHistoryTokenEstimate = 0,
  }) {
    final promptTokens = estimateTokens(prompt);
    final estimatedInputTokens =
        promptTokens + conversationHistoryTokenEstimate;
    final manifestMaxOutput = model.defaultGenerationConfig.maxTokens;
    final availableOutput =
        model.maxContextTokens - estimatedInputTokens - safetyMarginTokens;
    if (availableOutput < minimumOutputTokens) {
      throw StateError(
        'Not enough context window for generation. '
        'available_output_tokens=$availableOutput',
      );
    }

    final baseBudget = switch (intent) {
      GenerationIntent.shortChat => _clampInt(8 + promptTokens, 8, 16),
      _ => manifestMaxOutput,
    };

    final maxTokens = <int>[
      baseBudget,
      manifestMaxOutput,
      availableOutput,
    ].reduce((a, b) => a < b ? a : b);

    if (maxTokens < minimumOutputTokens) {
      throw StateError(
        'Generation budget is below minimum. max_tokens=$maxTokens',
      );
    }

    return GenerationBudget(
      maxTokens: maxTokens,
      estimatedInputTokens: estimatedInputTokens,
      reason:
          '${intent.name}: base=$baseBudget manifest_cap=$manifestMaxOutput '
          'available=$availableOutput',
    );
  }

  LlmGenerationConfig buildConfig({
    required ModelManifestEntry model,
    required String prompt,
    required GenerationIntent intent,
    int conversationHistoryTokenEstimate = 0,
  }) {
    final budget = buildBudget(
      model: model,
      prompt: prompt,
      intent: intent,
      conversationHistoryTokenEstimate: conversationHistoryTokenEstimate,
    );
    final defaults = model.defaultGenerationConfig;
    return LlmGenerationConfig(
      temperature: defaults.temperature,
      topK: defaults.topK,
      topP: defaults.topP,
      maxTokens: budget.maxTokens,
      enableThinking: intent == GenerationIntent.shortChat
          ? false
          : defaults.enableThinking,
    );
  }

  bool looksTruncated({required String text, required int maxTokens}) {
    final normalized = text.trim();
    if (normalized.isEmpty) {
      return false;
    }

    final estimatedOutputTokens = estimateTokens(normalized);
    final nearLimit = estimatedOutputTokens >= (maxTokens * 0.82).floor();
    if (!nearLimit) {
      return false;
    }

    if (_hasUnclosedMarkdownFence(normalized)) {
      return true;
    }

    if (RegExp(r'[\.\?!。？！\)]$').hasMatch(normalized)) {
      return false;
    }

    return true;
  }

  int continuationCountFor(GenerationIntent intent) {
    return switch (intent) {
      GenerationIntent.shortChat => 0,
      GenerationIntent.report => 2,
      _ => 1,
    };
  }

  int estimateTokens(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      return 0;
    }
    return (trimmed.length / 4).ceil();
  }

  int _clampInt(int value, int min, int max) {
    if (value < min) {
      return min;
    }
    if (value > max) {
      return max;
    }
    return value;
  }

  bool _hasUnclosedMarkdownFence(String text) {
    return RegExp(r'```').allMatches(text).length.isOdd;
  }
}
