// The class below is @Deprecated but must keep constructing itself in its own
// factory. Self-references inside the declaring library are not a misuse.
// ignore_for_file: deprecated_member_use_from_same_package

/// Represents the result of a completed or dismissed survey.
///
/// Nothing in the SDK produces this type. The survey delegate reports completion
/// as `onSurveyCompleted(String surveyId, List<Map<String, dynamic>> responses)`,
/// which is the native shape on every platform. This model is kept only so hosts
/// that already reference it keep compiling.
///
/// Its `fromMap` previously read a `'answers'` key while the platform channel
/// sends `'responses'`, so `answers` was always null — and the unit test fed the
/// model its own keys, so it never caught that.
@Deprecated(
  'Nothing produces SurveyResult. Use AppDNASurveyDelegate.onSurveyCompleted '
  '(surveyId, responses) instead. Removed in a future major release.',
)
class SurveyResult {
  /// The survey ID.
  final String surveyId;

  /// Whether the survey was completed (true) or dismissed (false).
  final bool completed;

  /// Number of questions answered.
  final int questionsAnswered;

  /// Survey answers (only present when completed).
  final List<SurveyAnswer>? answers;

  const SurveyResult({
    required this.surveyId,
    required this.completed,
    required this.questionsAnswered,
    this.answers,
  });

  /// Parses the shape the platform channel actually sends:
  /// `{'surveyId': String, 'responses': [{'questionId': String, 'answer': dynamic}]}`.
  ///
  /// `'answers'` is still accepted as a legacy alias. `completed` and
  /// `questionsAnswered` have no wire representation and are derived: a payload
  /// carrying responses represents a completion.
  factory SurveyResult.fromMap(Map<String, dynamic> map) {
    final raw = (map['responses'] ?? map['answers']) as List<dynamic>?;
    final parsed = raw
        ?.map((a) => SurveyAnswer.fromMap((a as Map).cast<String, dynamic>()))
        .toList();
    return SurveyResult(
      surveyId: map['surveyId'] as String? ?? '',
      completed: map['completed'] as bool? ?? (parsed != null && parsed.isNotEmpty),
      questionsAnswered: map['questionsAnswered'] as int? ?? (parsed?.length ?? 0),
      answers: parsed,
    );
  }

  Map<String, dynamic> toMap() => {
        'surveyId': surveyId,
        'completed': completed,
        'questionsAnswered': questionsAnswered,
        if (answers != null) 'answers': answers!.map((a) => a.toMap()).toList(),
      };
}

/// A single survey answer.
class SurveyAnswer {
  /// The question ID.
  final String questionId;

  /// The answer value (can be int, String, List, etc.).
  final dynamic answer;

  const SurveyAnswer({required this.questionId, required this.answer});

  factory SurveyAnswer.fromMap(Map<String, dynamic> map) {
    // The survey delegate emits camelCase `questionId` (matching
    // the native forwarder). Read/write camelCase so this public model stays
    // consistent with the runtime shape.
    return SurveyAnswer(
      questionId: map['questionId'] as String? ?? '',
      answer: map['answer'],
    );
  }

  Map<String, dynamic> toMap() => {
        'questionId': questionId,
        'answer': answer,
      };
}
