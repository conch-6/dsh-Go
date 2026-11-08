import 'dart:convert';

final _draftId = RegExp(r'^[a-f0-9]{32}$');
final _skillName = RegExp(r'^phone-task-[a-f0-9]{32}$');

/// Completed native trace candidate; the person still has to confirm the goal succeeded.
class PhoneSkillCandidate {
  const PhoneSkillCandidate({required this.taskId, required this.generation, required this.steps});
  final int taskId;
  final int generation;
  final int steps;

  static PhoneSkillCandidate? parse(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['taskId'], generation = raw['generation'], steps = raw['steps'];
    if (id is! int || id <= 0 || generation is! int || generation <= 0 || steps is! int || steps < 1 || steps > 60) return null;
    return PhoneSkillCandidate(taskId: id, generation: generation, steps: steps);
  }
}

class PhoneSkillStatus {
  const PhoneSkillStatus({this.available = false, this.askAfterSuccess = false, this.candidates = const []});
  final bool available;
  final bool askAfterSuccess;
  final List<PhoneSkillCandidate> candidates;

  factory PhoneSkillStatus.parse(Object? raw) {
    if (raw is! Map || raw['v'] is! int || raw['v'] != 1) return const PhoneSkillStatus();
    final values = raw['candidates'];
    return PhoneSkillStatus(
      available: true,
      askAfterSuccess: raw['askAfterSuccess'] == true,
      candidates: List.unmodifiable([
        if (values is List)
          for (final value in values.take(8))
            ?PhoneSkillCandidate.parse(value),
      ]),
    );
  }
}

/// The exact native revision shown to the person. Only this revision can be saved.
class PhoneSkillDraftView {
  const PhoneSkillDraftView({required this.draftId, required this.taskId, required this.generation,
    required this.revision, required this.skillName, required this.markdown, required this.stepOrder,
    required this.parameterizedFields, this.phase});
  final String draftId;
  final int taskId;
  final int generation;
  final int revision;
  final String skillName;
  final String markdown;
  final List<int> stepOrder;
  final List<String> parameterizedFields;
  final String? phase;

  static PhoneSkillDraftView? parse(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['draftId'], task = raw['taskId'], generation = raw['generation'], revision = raw['revision'];
    final name = raw['skillName'], markdown = raw['markdown'], order = raw['stepOrder'], fields = raw['parameterizedFields'];
    final phase = raw['phase'];
    if (id is! String || !_draftId.hasMatch(id) || task is! int || task <= 0 ||
        generation is! int || generation <= 0 || revision is! int || revision <= 0 ||
        name is! String || !_skillName.hasMatch(name) || markdown is! String ||
        markdown.length > 32768 || utf8.encode(markdown).length > 32768 ||
        order is! List || order.isEmpty || order.length > 60 ||
        order.any((v) => v is! int || v < 0 || v >= 60) || order.toSet().length != order.length ||
        fields is! List || fields.length > 62 || fields.any((v) => v is! String || v.length > 32) ||
        phase != null && !const {'staging', 'committing', 'finished', 'cancelled'}.contains(phase)) {
      return null;
    }
    return PhoneSkillDraftView(draftId: id, taskId: task, generation: generation, revision: revision,
      skillName: name, markdown: markdown, stepOrder: List<int>.unmodifiable(order),
      parameterizedFields: List<String>.unmodifiable(fields), phase: phase as String?);
  }
}

enum PhoneSkillReplyKind { shown, saved, discarded, rejected, saving }

class PhoneSkillReply {
  const PhoneSkillReply._(this.kind, {this.draft, this.code, this.name, this.relativePath, this.phase});
  const PhoneSkillReply.unavailable() : this._(PhoneSkillReplyKind.rejected, code: 'unavailable');
  final PhoneSkillReplyKind kind;
  final PhoneSkillDraftView? draft;
  final String? code;
  final String? name;
  final String? relativePath;
  final String? phase;

  static const _codes = {'stale', 'busy', 'confirmation_required', 'unavailable', 'invalid', 'sensitive',
    'too_large', 'no_home', 'conflict', 'io', 'cannot_cancel'};

  factory PhoneSkillReply.parse(Object? raw) {
    if (raw is! Map) return const PhoneSkillReply.unavailable();
    switch (raw['kind']) {
      case 'shown':
        final draft = PhoneSkillDraftView.parse(raw['draft']);
        return draft == null ? const PhoneSkillReply.unavailable() : PhoneSkillReply._(PhoneSkillReplyKind.shown, draft: draft);
      case 'saved':
        final name = raw['name'], path = raw['relativePath'];
        if (name is! String || !_skillName.hasMatch(name) || path != 'skills/$name/SKILL.md') return const PhoneSkillReply.unavailable();
        return PhoneSkillReply._(PhoneSkillReplyKind.saved, name: name, relativePath: path as String);
      case 'discarded':
        return const PhoneSkillReply._(PhoneSkillReplyKind.discarded);
      case 'saving':
        final phase = raw['phase'];
        if (phase != 'staging' && phase != 'committing') return const PhoneSkillReply.unavailable();
        return PhoneSkillReply._(PhoneSkillReplyKind.saving, phase: phase as String);
      case 'rejected':
        final code = raw['code'];
        return PhoneSkillReply._(PhoneSkillReplyKind.rejected, code: code is String && _codes.contains(code) ? code : 'unavailable');
      default:
        return const PhoneSkillReply.unavailable();
    }
  }
}
