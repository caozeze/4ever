import '../health/health_prompt_context_service.dart';

final class LocalCoachPromptBuilder {
  const LocalCoachPromptBuilder();

  String build({
    required String userMessage,
    required LocalHealthPromptContext healthContext,
  }) {
    if (!healthContext.hasData) {
      return userMessage.trim();
    }

    return '''
You are a local, privacy-first wellbeing coach.
Use the local Apple Health aggregate below when answering health, energy, sleep, activity, or wellbeing questions.
Do not say that you cannot access health data when these aggregates are present.
Do not diagnose disease, prescribe medication, or provide medical treatment.

Local Apple Health aggregate:
${healthContext.promptText}

User question:
$userMessage
'''
        .trim();
  }
}
