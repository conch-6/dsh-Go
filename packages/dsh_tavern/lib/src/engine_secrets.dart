part of 'engine.dart';

const _secretRuntimeKey = 'dshgoSecretRuntime';

bool _secretsEnabled(Map<String, Object?> settings) =>
    settings['stateEnabled'] != false &&
    _map(settings['director'])['enabled'] == true &&
    _map(settings['director'])['secretsEnabled'] == true;

state_core.SecretDefinition _secretDefinition(Map<String, Object?> data) {
  final own = _map(_map(data['extensions'])['dshgo']);
  return state_core.SecretDefinition.parse(
    _map(own['director'])['secretSlots'],
    state: _stateDefinition(data),
    version: own.containsKey('v') ? own['v'] : 1,
  );
}

Object? _secretCopy(Object? value) => jsonDecode(jsonEncode(value));

Map<String, Object?> _currentSecretPersona(TavernEngine engine, StoredChat chat, Map<String, Object?> settings) {
  final selection = engine._personas.resolve(personaId: chat.personaId);
  return _directorPersona(selection, _personaSettings(settings, selection));
}

/// The portable ledger is evidence to check, never an instruction to execute.
/// Malformed or future data remains on disk and closes automatic carriers.
class _SecretLedger {
  _SecretLedger(Map<String, Object?> saved)
    : exists = saved.containsKey(_secretRuntimeKey),
      raw = _secretCopy(saved[_secretRuntimeKey]) {
    if (!exists) return;
    final object = raw;
    if (object is! Map<String, Object?> || object['version'] != 1 || object['bindings'] is! List<Object?>) {
      valid = false;
    } else {
      final keys = <String>{}, ids = <String>{};
      for (final item in object['bindings']! as List<Object?>) {
        if (item is! Map<String, Object?>) {
          valid = false;
          continue;
        }
        final path = item['path'];
        if (path is String) {
          try {
            if (_statePointerTokens(path).isNotEmpty) {
              paths.add(path);
            } else {
              valid = false;
            }
          } on FormatException {
            valid = false;
          }
        } else {
          valid = false;
        }
        const strings = [
          'bindingId',
          'bindingKey',
          'slotId',
          'entityId',
          'path',
          'definitionFingerprint',
          'valueHash',
          'sourceNodeId',
          'inputSourceFingerprint',
          'boundNodeId',
          'beforeStateFingerprint',
          'afterStateFingerprint',
          'generationInvocationId',
          'bindReceiptId',
          'proposalRunId',
          'characterId',
        ];
        if (strings.any((key) => item[key] is! String || (item[key]! as String).isEmpty) ||
            item['valueType'] != 'string' ||
            item['policyVersion'] != 1 ||
            item['proposalIndex'] is! int ||
            (item['proposalIndex']! as int) < 0) {
          valid = false;
          continue;
        }
        final key = item['bindingKey']! as String;
        if (key != state_core.secretBindingKey(item['slotId']! as String, item['entityId']! as String) ||
            !keys.add(key) ||
            !ids.add(item['bindingId']! as String)) {
          valid = false;
          continue;
        }
        bindings.add(_copy(item));
      }
    }
    if (!valid) issues.add(_directorIssue('secret_ledger_unavailable'));
  }
  final bool exists;
  final Object? raw;
  bool valid = true;
  final bindings = <Map<String, Object?>>[];
  final paths = <String>{};
  final issues = <Map<String, Object?>>[];
  List<String> get boundKeys => [for (final row in bindings) row['bindingKey']! as String];

  Map<String, Object?> adding(List<Map<String, Object?>> rows) {
    if (!valid) throw const FormatException('Cannot extend an unavailable secret ledger.');
    return {
      ...?(raw as Map<String, Object?>?),
      'version': 1,
      'bindings': [...bindings, ...rows],
    };
  }
}

class _SecretProtection {
  _SecretProtection(Map<String, Object?> data, Map<String, Object?> saved)
    : definition = _secretDefinition(data),
      ledger = _SecretLedger(saved) {
    paths.addAll(definition.protectedPaths);
    paths.addAll(ledger.paths);
    unknown = !ledger.valid || definition.issues.any((issue) => issue['code'] == 'secret_protection_unknown');
  }
  final state_core.SecretDefinition definition;
  final _SecretLedger ledger;
  final paths = <String>{};
  late final bool unknown;
  bool get active => definition.defined || ledger.exists;
  List<Map<String, Object?>> get issues => [...definition.issues, ...ledger.issues];

  Object? masked(Object? value) {
    if (unknown) return null;
    final next = _secretCopy(value);
    for (final path in paths) {
      final tokens = _statePointerTokens(path);
      if (tokens.isEmpty) return null;
      Object? parent = next;
      for (final token in tokens.take(tokens.length - 1)) {
        if (parent is List<Object?>) return null;
        parent = parent is Map<String, Object?> ? parent[token] : null;
      }
      if (parent is List<Object?>) return null;
      if (parent is Map<String, Object?>) parent.remove(tokens.last);
    }
    return next;
  }

  bool allowsTool(state_core.StateDefinition state, _StateInput input) {
    if (unknown) return false;
    final hidden = state.project(input.value, valueExists: input.valueExists).hiddenPaths;
    return paths.every(
      (path) => hidden.any((parent) => parent.isEmpty || path == parent || path.startsWith('$parent/')),
    );
  }
}

List<state_core.SecretRelease> _secretReleases(
  TavernEngine engine,
  String chatId,
  String characterId,
  Map<String, Object?> data,
  Map<String, Object?> settings,
  Map<String, Object?> saved,
  _SecretProtection protection,
) {
  if (!_secretsEnabled(settings) ||
      protection.unknown ||
      !protection.definition.executable ||
      _storyDefinition(data).defined) {
    return [];
  }
  final input = _StateInput(saved);
  if (!input.writable) return [];
  final result = <state_core.SecretRelease>[];
  for (final binding in protection.ledger.bindings) {
    if (binding['characterId'] != characterId ||
        binding['definitionFingerprint'] != protection.definition.fingerprint) {
      continue;
    }
    final release = protection.definition.releaseFor(
      slotId: binding['slotId']! as String,
      entityId: binding['entityId']! as String,
      characterId: characterId,
      value: input.value,
      valueExists: input.valueExists,
    );
    if (release == null || release.path != binding['path'] || release.valueHash != binding['valueHash']) continue;
    final proof = engine._store.agentRunById(chatId, binding['bindReceiptId']! as String);
    if (proof == null ||
        proof.kind != 'director.secret_bind' ||
        proof.result['version'] != 1 ||
        proof.result['committed'] != true ||
        !_stateRows(proof.result['bindings']).any((row) => _stateJsonEqual(row, binding))) {
      continue;
    }
    result.add(release);
  }
  return result;
}

/// What an ordinary helper actually knows is distinct from its full source
/// authentication. In particular old notes cannot survive a narrower release.
class _SecretInput {
  _SecretInput({
    required this.card,
    required this.state,
    required this.releases,
    required this.policy,
    required this.issues,
  });
  final Map<String, Object?> card;
  final Map<String, Object?> state;
  final List<state_core.SecretRelease> releases;
  final Map<String, Object?>? policy;
  final List<Map<String, Object?>> issues;
}

_SecretInput _ordinarySecretInput(
  TavernEngine engine,
  String chatId,
  String characterId,
  Map<String, Object?> data,
  Map<String, Object?> settings,
  Map<String, Object?> source, {
  Map<String, Object?>? authorizationSource,
}) {
  final state = _copy(_map(source['state']));
  final saved = <String, Object?>{
    'messageVariables': {if (state['valueExists'] == true) 'dshgo': state['value']},
    if (source.containsKey('secretRuntime')) _secretRuntimeKey: source['secretRuntime'],
  };
  final protection = _SecretProtection(data, saved);
  final authorization = authorizationSource ?? source;
  final authorizationState = _map(authorization['state']);
  final authorizationSaved = <String, Object?>{
    'messageVariables': {if (authorizationState['valueExists'] == true) 'dshgo': authorizationState['value']},
    if (authorization.containsKey('secretRuntime')) _secretRuntimeKey: authorization['secretRuntime'],
  };
  final currentProtection = _SecretProtection(data, authorizationSaved);
  protection.paths.addAll(currentProtection.paths);
  final card = _directorCard(data);
  if (!protection.active && !currentProtection.active) {
    return _SecretInput(card: card, state: state, releases: [], policy: null, issues: []);
  }
  final unavailable =
      protection.unknown ||
      currentProtection.unknown ||
      _stateRows(state['issues']).isNotEmpty ||
      _stateRows(authorizationState['issues']).isNotEmpty;
  card.remove('stateDefinition');
  if (card['director'] is Map<String, Object?>) {
    final director = _copy(card['director']! as Map<String, Object?>)..remove('secretSlots');
    card['director'] = director;
  }
  if (unavailable) {
    state.remove('value');
    state['valueExists'] = false;
  } else if (state['valueExists'] == true) {
    state['value'] = protection.masked(state['value']);
  }
  final currentReleases = unavailable
      ? <state_core.SecretRelease>[]
      : _secretReleases(engine, chatId, characterId, data, settings, authorizationSaved, currentProtection);
  final currentKnowledge = {for (final release in currentReleases) _directorHash(_secretKnowledge(release))};
  final releases = unavailable
      ? <state_core.SecretRelease>[]
      : [
          for (final release in _secretReleases(engine, chatId, characterId, data, settings, saved, protection))
            if (currentKnowledge.contains(_directorHash(_secretKnowledge(release)))) release,
        ];
  final paths = protection.paths.toList()..sort();
  final knowledge = [for (final release in releases) _secretKnowledge(release)]
    ..sort((a, b) => _directorHash(a).compareTo(_directorHash(b)));
  return _SecretInput(
    card: card,
    state: state,
    releases: releases,
    policy: {'version': 1, 'protectedPaths': paths, 'unavailable': unavailable, 'knowledge': knowledge},
    issues: [
      ...protection.issues,
      ...currentProtection.ledger.issues,
      if (unavailable) _directorIssue('secret_input_unavailable'),
    ],
  );
}

Map<String, Object?> _secretKnowledge(state_core.SecretRelease release) => {
  'slotId': release.slotId,
  'entityId': release.entityId,
  'path': release.path,
  'releaseId': release.releaseId,
  'characterId': release.characterId,
  'definitionFingerprint': release.definitionFingerprint,
  'valueHash': release.valueHash,
};

Map<String, Object?> _secretStateSource(Map<String, Object?> saved) {
  final input = _StateInput(saved);
  return {
    'state': {
      'valueExists': input.valueExists,
      if (input.valueExists) 'value': input.value,
      'variables': saved['variables'],
      'issues': input.issues,
    },
    if (saved.containsKey(_secretRuntimeKey)) 'secretRuntime': saved[_secretRuntimeKey],
  };
}

/// Current authorization needs the selected saved state, not unrelated later
/// ancestor bodies or their extra/original JSON. Source provenance is separate.
Map<String, Object?> _secretAuthorizationSource(TavernEngine engine, String chatId, String? nodeId) {
  final saved = nodeId == null
      ? _emptyChatState(engine._chatCodec.metadataForNode(engine._store, chatId))
      : engine._stateAt(chatId, nodeId);
  return _secretStateSource(saved);
}

String? _secretTurnContextReason(TavernEngine engine, _Turn turn, Map<String, Object?> settings) {
  if (turn.secretCardRevision != (engine._directors._cardRevisions[turn.chat.characterId] ?? 0)) {
    return 'secret_card_changed';
  }
  final chat = engine._store.chat(turn.chat.id);
  if (!_stateJsonEqual(
    _currentSecretPersona(engine, chat, settings),
    _directorPersona(turn.personaSelection, turn.settings),
  )) {
    return 'secret_persona_changed';
  }
  return null;
}

/// The full source was authenticated at admission. Later checks compare the
/// actual knowledge policy against this request's state, without treating our
/// own newly-created reply or macro writes as a new historical source.
String? _secretDirectorTurnReason(TavernEngine engine, _Turn turn, Map<String, Object?> saved) {
  final prepared = turn.directorPrepared;
  if (prepared == null || !prepared.eligible) return null;
  final prior = prepared.stored.result['secretPolicy'];
  if (prior == null && turn.secretProtection?.active != true) return null;
  final data = turn.directorCard;
  if (data == null) return 'secret_card_unavailable';
  final settings = engine._effectiveSettings(engine._store.chat(turn.chat.id));
  final reason = _secretTurnContextReason(engine, turn, settings);
  if (reason != null) return reason;
  final current = _ordinarySecretInput(
    engine,
    turn.chat.id,
    turn.chat.characterId,
    data,
    settings,
    _secretStateSource(saved),
  ).policy;
  if (current?['unavailable'] == true || !_stateJsonEqual(current, prior)) {
    return 'director_secret_knowledge_changed';
  }
  return null;
}

List<PromptInjection> _secretTurnInjections(TavernEngine engine, _Turn turn, Map<String, Object?> data) {
  if (turn.kind == _TurnKind.impersonate || !_secretsEnabled(turn.settings)) return [];
  final settings = engine._effectiveSettings(engine._store.chat(turn.chat.id));
  final reason = _secretTurnContextReason(engine, turn, settings);
  if (reason != null) {
    if (turn.secretProtection?.active == true) turn.secretIssues.add(_directorIssue(reason));
    return [];
  }
  final saved = turn.currentState;
  final protection = _SecretProtection(data, saved);
  final releases = _secretReleases(engine, turn.chat.id, turn.chat.characterId, data, settings, saved, protection);
  final result = <PromptInjection>[];
  for (final release in releases) {
    final sourceId = 'dshgo.secret.release:${_directorHash(_secretKnowledge(release))}';
    turn.secretOffered[sourceId] = {...release.toJson(), 'sourceId': sourceId, 'knowledge': _secretKnowledge(release)};
    if (release.text.isEmpty) continue;
    result.add(
      PromptInjection(
        fragment: PromptFragment(
          release.text,
          PromptSource('secretFact', sourceId, label: '公开事实'),
          trimOnOverflow: true,
          expandMacros: false,
        ),
        depth: 1,
        order: 203,
      ),
    );
  }
  return result;
}

void _captureSecretAssembly(_Turn turn, PromptAssembly assembly) {
  for (final segment in assembly.afterPostProcessing) {
    final content = segment.message['content'];
    if (content is! String || content.isEmpty) continue;
    for (final source in segment.sources) {
      if (source.kind == 'secretFact' && turn.secretOffered.containsKey(source.id)) {
        turn.secretIncluded.add(source.id);
      }
    }
  }
}

bool _hasSecretTrace(_Turn turn) =>
    turn.secretProtection?.active == true ||
    turn.secretAttempt != null ||
    turn.secretIssues.isNotEmpty ||
    turn.secretOffered.isNotEmpty;

Map<String, Object?> _secretTurnTrace(_Turn turn, {bool? attempted}) => {
  'version': 1,
  if (turn.secretAttempt != null) 'binding': _copy(turn.secretAttempt!),
  'protectedPaths': turn.secretProtection?.paths.toList() ?? <String>[],
  'protectionUnknown': turn.secretProtection?.unknown ?? false,
  'offered': [for (final item in turn.secretOffered.values) _copy(item)],
  'included': turn.secretIncluded.toList(),
  // This is an attempted client call, never proof of provider receipt or of
  // character knowledge. A crash before terminal persistence may leave no log.
  'attempted': (attempted ?? turn.secretRequestAttempted) ? turn.secretIncluded.toList() : <String>[],
  'issues': [for (final issue in turn.secretIssues) _copy(issue)],
};

/// Called after other request preparation, immediately before generate(). No
/// async gap is permitted between this check and that client-call attempt.
TavernTurnInspection? _prepareSecretRequest(TavernEngine engine, _Turn turn) {
  final director = turn.inspection.director;
  final directorIncluded =
      _map(director['beat'])['finalSourceObserved'] == true ||
      _stateRows(director['prefetch']).any((item) => item['finalSourceObserved'] == true);
  final directorReason = _secretDirectorTurnReason(engine, turn, turn.currentState);
  if (directorIncluded && directorReason != null) {
    turn.secretIssues.add(_directorIssue(directorReason));
    throw StateError('Director knowledge authorization changed before the request.');
  }
  if (turn.secretIncluded.isEmpty) return null;
  final data = turn.directorCard;
  final chat = engine._store.chat(turn.chat.id);
  final settings = engine._effectiveSettings(chat);
  final reason = _secretTurnContextReason(engine, turn, settings);
  if (data == null ||
      reason != null ||
      !_secretsEnabled(turn.settings) ||
      !_secretsEnabled(settings) ||
      turn.reply == null ||
      chat.currentLeafId != turn.reply!.nodeId) {
    turn.secretIssues.add(_directorIssue(reason ?? 'secret_release_revoked'));
    throw StateError('Secret release authorization changed before the request.');
  }
  final saved = engine._stateAt(chat.id, turn.reply!.nodeId);
  final current = _secretReleases(
    engine,
    chat.id,
    chat.characterId,
    data,
    settings,
    saved,
    _SecretProtection(data, saved),
  );
  final authorized = {for (final release in current) _directorHash(_secretKnowledge(release))};
  for (final id in turn.secretIncluded) {
    final offered = turn.secretOffered[id]!;
    if (!authorized.contains(_directorHash(offered['knowledge']))) {
      turn.secretIssues.add(_directorIssue('secret_release_revoked', id: id));
      throw StateError('An included secret fact is no longer authorized.');
    }
  }
  // Construct potentially fallible inspection data before marking attempted.
  return turn.inspection.copyWith(
    state: {..._statePreparationTrace(turn), 'secrets': _secretTurnTrace(turn, attempted: true)},
  );
}

String? _secretDirectorEligibility(
  TavernEngine engine,
  StoredAgentRun stored,
  Map<String, Object?> data,
  Map<String, Object?> settings,
  String? contextNodeId,
) {
  final chat = engine._store.chat(stored.chatId);
  final source = _secretAuthorizationSource(engine, chat.id, contextNodeId);
  final current = _ordinarySecretInput(engine, chat.id, chat.characterId, data, settings, source).policy;
  final prior = stored.result['secretPolicy'];
  if (current == null && prior == null) return null;
  if (current?['unavailable'] == true || prior is! Map<String, Object?> || !_stateJsonEqual(current, prior)) {
    return 'director_secret_knowledge_changed';
  }
  return null;
}

state_core.SecretCapability? _captureSecretCapability(_DirectorJob job) {
  final data = job.card;
  if (data == null || job.nodeId == null || !_secretsEnabled(job.settings) || _storyDefinition(data).defined) {
    return null;
  }
  final state = _map(job.source['state']);
  if (_stateRows(state['issues']).isNotEmpty || state['valueExists'] != true) return null;
  final saved = <String, Object?>{
    'messageVariables': {'dshgo': state['value']},
    if (job.source.containsKey('secretRuntime')) _secretRuntimeKey: job.source['secretRuntime'],
  };
  final protection = _SecretProtection(data, saved);
  if (protection.unknown || !protection.definition.executable) return null;
  final capability = protection.definition.capture(
    value: state['value'],
    valueExists: true,
    boundKeys: protection.ledger.boundKeys,
    characterId: job.characterId,
  );
  return capability.slotIds.isEmpty ? null : capability;
}

Map<String, Object?> _secretCapabilityJson(state_core.SecretCapability capability) => {
  'version': 1,
  'fingerprint': capability.fingerprint,
  'definitionFingerprint': capability.definitionFingerprint,
  'stateDefinitionFingerprint': capability.stateDefinitionFingerprint,
  'baselineFingerprint': capability.baselineFingerprint,
  'characterId': capability.characterId,
  'slotIds': capability.slotIds,
  'catalog': capability.catalog,
};

Future<void> _runSecretDirector(_DirectorCoordinator coordinator, _DirectorJob job) async {
  final engine = coordinator.engine;
  job.cancellation.check();
  final chat = engine._store.chat(job.chatId);
  final settings = engine._effectiveSettings(chat);
  if (!_secretsEnabled(settings)) throw const FormatException('Secret helper has been disabled.');
  if ((coordinator._cardRevisions[job.characterId] ?? 0) != job.cardRevision ||
      !_stateJsonEqual(_currentSecretPersona(engine, chat, settings), job.persona)) {
    throw const FormatException('Secret helper card or persona changed before the request.');
  }
  final capability = job.secretCapability;
  final data = job.card;
  if (capability == null || data == null) throw const FormatException('Secret capability is unavailable.');
  final card = _directorCard(data);
  job.fingerprint = _directorSourceFingerprint(job.source, card, job.persona);
  final path = (job.source['path']! as List<Object?>).cast<String>();
  final summaries = engine._store.directorSummaries(job.chatId, path, limit: 20);
  final input = jsonEncode({
    'card': card,
    'persona': job.persona,
    'summaries': summaries,
    'recent': job.source['recent'],
    'state': job.source['state'],
    'slots': capability.catalog,
  });
  if (utf8.encode(input).length > 1024 * 1024) throw const FormatException('Secret input exceeds 1 MiB.');
  final original = job.originalConfig;
  final config = TavernModelConfig(
    apiKey: original.apiKey,
    baseUrl: original.baseUrl,
    model: original.deepseek ? 'deepseek-flash' : original.model,
    deepseek: original.deepseek,
    thinking: false,
  );
  final tool = capability.strictTool();
  if (tool == null) throw const FormatException('No secret slot is available.');
  if (!config.deepseek) tool['function'] = _map(tool['function'])..remove('strict');
  final body = <String, Object?>{
    'messages': [
      {
        'role': 'system',
        'content':
            '你是故事的私密事实整理者。只通过 propose_secrets 提议尚未确定的固定槽值。'
            '依据提供的卡、最近剧情和实体身份保持一致；有疑问就省略该槽。不要写角色正文，不替用户行动。'
            '事实尚未提交，不在其他通道宣称已经成立或已经公开；notes 只供剧透审计。',
      },
      {'role': 'user', 'content': input},
    ],
    'stream': false,
    'max_tokens': 4096,
    if (config.deepseek) 'thinking': {'type': 'disabled'},
    'tools': [tool],
    'tool_choice': {
      'type': 'function',
      'function': {'name': 'propose_secrets'},
    },
  };
  final batch = await coordinator._receive(job, config, body);
  job.cancellation.check();
  if ((job.finishReason != 'stop' && job.finishReason != 'tool_calls') ||
      !batch.eligibleStructure ||
      batch.issues.isNotEmpty ||
      batch.calls.length != 1) {
    throw const FormatException('A secret proposal requires one complete normal tool call.');
  }
  final call = batch.calls.single;
  if (!call.valid || call.type != 'function' || call.name != 'propose_secrets' || call.parameters == null) {
    throw const FormatException('Invalid secret proposal tool call.');
  }
  final output = capability.parseProposal(call.parameters!);
  _publishSecretDirector(coordinator, job, output: output.toJson());
}

void _publishSecretDirector(
  _DirectorCoordinator coordinator,
  _DirectorJob job, {
  Map<String, Object?>? output,
  String? failure,
}) {
  final engine = coordinator.engine;
  if (job.discarded || engine._closed) return;
  DateTime now;
  try {
    now = engine._clock();
  } catch (_) {
    now = job.at;
  }
  final raw = <String, Object?>{
    'version': 1,
    'mode': 'secrets',
    'sourceKind': job.nodeId == null ? 'empty' : 'node',
    'sourceNodeId': job.nodeId,
    'sourceFingerprint': job.fingerprint,
    'characterId': job.characterId,
    'automatic': job.automatic,
    'startedAt': job.at.toUtc().toIso8601String(),
    'finishedAt': now.toUtc().toIso8601String(),
    'success': output != null && failure == null,
    'failure': failure,
    if (job.secretCapability != null) 'capability': _secretCapabilityJson(job.secretCapability!),
    'output': ?output,
    'issues': job.issues,
  };
  try {
    String? physical = job.nodeId;
    if (physical != null) {
      try {
        engine._store.node(job.chatId, physical);
      } catch (_) {
        physical = null;
      }
    }
    engine._store.writeAgentRun(
      StoredAgentRun(
        id: job.id,
        chatId: job.chatId,
        nodeId: physical,
        kind: output == null ? 'director.secret_failure' : 'director.secret_proposal',
        at: now,
        usage: _directorUsageJson(job.usage),
        result: raw,
      ),
    );
  } catch (_) {
    coordinator._transientIssues[job.chatId] = [_directorIssue('secret_result_not_persisted', id: job.id)];
  }
  coordinator.changed(job.chatId);
}

String? _secretBindingReason(
  TavernEngine engine,
  _Turn turn,
  Map<String, Object?> data,
  String? parent,
  StoredAgentRun proposal,
) {
  final chat = engine._store.chat(turn.chat.id);
  final settings = engine._effectiveSettings(chat);
  if (!_secretsEnabled(turn.settings) ||
      !_secretsEnabled(settings) ||
      turn.kind == _TurnKind.impersonate ||
      _storyDefinition(data).defined) {
    return 'secret_binding_disabled';
  }
  final contextReason = _secretTurnContextReason(engine, turn, settings);
  if (contextReason != null) return contextReason;
  if (parent == null ||
      parent != chat.currentLeafId ||
      parent != turn.chat.currentLeafId ||
      proposal.result['sourceNodeId'] != parent ||
      engine._store.hasPhysicalChildren(chat.id, parent)) {
    return 'secret_source_not_current_physical_leaf';
  }
  final raw = proposal.result;
  if (proposal.kind != 'director.secret_proposal' ||
      raw['version'] != 1 ||
      raw['mode'] != 'secrets' ||
      raw['success'] != true ||
      raw['sourceKind'] != 'node' ||
      raw['characterId'] != chat.characterId ||
      raw['capability'] is! Map<String, Object?> ||
      raw['output'] is! Map<String, Object?>) {
    return 'secret_proposal_unavailable';
  }
  final persisted = engine._store.agentRunById(chat.id, proposal.id);
  if (persisted == null || persisted.kind != proposal.kind || !_stateJsonEqual(persisted.result, raw)) {
    return 'secret_proposal_not_persisted';
  }
  final selection = engine._personas.resolve(personaId: chat.personaId);
  final persona = _directorPersona(selection, _personaSettings(settings, selection));
  if (!_stateJsonEqual(persona, _directorPersona(turn.personaSelection, turn.settings))) {
    return 'secret_persona_changed';
  }
  final source = _directorSource(engine, chat.id, parent);
  if (_directorSourceFingerprint(source, _directorCard(data), persona) != raw['sourceFingerprint']) {
    return 'secret_source_changed';
  }
  return null;
}

/// Only the proposal frozen by onListen is considered. Called synchronously
/// before history, macros, user-node creation or provider preparation.
void _bindSecretTurn(
  TavernEngine engine,
  _Turn turn,
  Map<String, Object?> data,
  String? parent,
  StoredNode? target,
  void Function(Map<String, Object?> state, StoredNode? target) adopt,
) {
  final proposal = turn.secretCaptured;
  if (proposal == null) return;
  final reason = _secretBindingReason(engine, turn, data, parent, proposal);
  if (reason != null) {
    turn.secretIssues.add(_directorIssue(reason, id: proposal.id));
    return;
  }
  turn.cancellation.check();
  final anchor = parent!;
  final saved = engine._stateAt(turn.chat.id, anchor);
  final input = _StateInput(saved);
  final protection = _SecretProtection(data, saved);
  if (!input.writable || !input.valueExists || protection.unknown || !protection.definition.executable) {
    turn.secretIssues.add(_directorIssue('secret_state_unavailable', id: proposal.id));
    return;
  }
  final rawExtra = engine._store.rawNodeExtra(turn.chat.id, anchor);
  if (rawExtra.containsKey('dshgo') && rawExtra['dshgo'] is! Map<String, Object?>) {
    turn.secretIssues.add(_directorIssue('secret_extra_unavailable', id: proposal.id));
    return;
  }
  final capability = protection.definition.capture(
    value: input.value,
    valueExists: true,
    boundKeys: protection.ledger.boundKeys,
    characterId: turn.chat.characterId,
  );
  if (!_stateJsonEqual(_secretCapabilityJson(capability), proposal.result['capability'])) {
    turn.secretIssues.add(_directorIssue('secret_capability_changed', id: proposal.id));
    return;
  }
  final invocation = turn.stateInvocationId ??= _newStateId();
  final state_core.StateSecretPlan plan;
  try {
    final output = capability.parseProposal(proposal.result['output']);
    if (output.facts.isEmpty) return;
    plan = capability.plan(output, id: '$invocation:secret:${proposal.id}');
  } on FormatException {
    turn.secretIssues.add(_directorIssue('secret_proposal_invalid', id: proposal.id));
    return;
  }
  final session = _stateDefinition(
    data,
  ).startSession(valueExists: true, value: input.value, runtimeExists: input.runtimeExists, runtime: input.runtime);
  final prepared = session.prepareSecretFacts(plan);
  turn.stateSession = session;
  turn.secretPrepared = prepared;
  turn.secretAttempt = {'version': 1, 'proposalRunId': proposal.id, 'committed': false, 'prepare': prepared.toJson()};
  if (!prepared.accepted) return;

  // Build all three detached descendants before COMMIT: persistent B,
  // continuation restoration B, and mutable generation G. A later error ends
  // this main turn and never opens a second session with a reset budget.
  final receiptId = '$invocation:secret_bind';
  final bindings = <Map<String, Object?>>[
    for (var index = 0; index < plan.facts.length; index++)
      {
        'bindingId': '$receiptId:$index',
        'bindingKey': state_core.secretBindingKey(plan.facts[index].slotId, plan.facts[index].entityId),
        'slotId': plan.facts[index].slotId, 'entityId': plan.facts[index].entityId, 'path': plan.facts[index].path,
        'definitionFingerprint': capability.definitionFingerprint,
        // A string has identical canonicalization in the two hash domains.
        'valueHash': _directorHash(plan.facts[index].value), 'valueType': 'string',
        'sourceNodeId': anchor, 'inputSourceFingerprint': proposal.result['sourceFingerprint'],
        'boundNodeId': anchor, 'beforeStateFingerprint': plan.baselineFingerprint,
        'afterStateFingerprint': prepared.valueFingerprint, 'generationInvocationId': invocation,
        'bindReceiptId': receiptId, 'proposalRunId': proposal.id, 'proposalIndex': index,
        'characterId': turn.chat.characterId, 'policyVersion': 1,
      },
  ];
  final persistent = _copy(saved);
  persistent['messageVariables'] = {..._map(persistent['messageVariables']), 'dshgo': prepared.value};
  if (prepared.runtimeExists) persistent['dshgoStateRuntime'] = prepared.runtime;
  persistent[_secretRuntimeKey] = protection.ledger.adding(bindings);
  final extra = _stateNodeExtra(rawExtra, persistent, {
    'secretBinding': {'version': 1, 'runId': receiptId, 'proposalRunId': proposal.id},
  });
  final generation = _copy(turn.state);
  generation['messageVariables'] = _copy(_map(persistent['messageVariables']));
  if (persistent.containsKey('dshgoStateRuntime')) {
    generation['dshgoStateRuntime'] = _secretCopy(persistent['dshgoStateRuntime']);
  }
  generation[_secretRuntimeKey] = _secretCopy(persistent[_secretRuntimeKey]);
  final restored = target == null
      ? null
      : StoredNode(
          message: target.message,
          depth: target.depth,
          extra: _copy(extra),
          original: _copy(target.original),
          selectedChildId: target.selectedChildId,
        );
  final audit = StoredAgentRun(
    id: receiptId,
    chatId: turn.chat.id,
    nodeId: anchor,
    kind: 'director.secret_bind',
    at: engine._clock(),
    result: {
      'version': 1,
      'committed': true,
      'proposalRunId': proposal.id,
      'generationInvocationId': invocation,
      'sourceNodeId': anchor,
      'sourceFingerprint': proposal.result['sourceFingerprint'],
      'capabilityFingerprint': capability.fingerprint,
      'bindings': bindings,
      'beforeStateFingerprint': plan.baselineFingerprint,
      'afterStateFingerprint': prepared.valueFingerprint,
      'changes': prepared.changes,
      'receipts': prepared.receipts,
      'issues': prepared.issues,
    },
  );
  final committedTrace = <String, Object?>{...turn.secretAttempt!, 'committed': true, 'bindReceiptId': receiptId};
  engine._store.transaction(
    () {
      turn.cancellation.check();
      if (_secretBindingReason(engine, turn, data, anchor, proposal) != null ||
          !_stateJsonEqual(engine._store.rawNodeExtra(turn.chat.id, anchor), rawExtra)) {
        throw StateError('Secret source changed after preparation.');
      }
      engine._store.updateMessage(turn.chat.id, anchor, extra: extra);
      engine._store.writeAgentRun(audit);
    },
    onCommitted: () {
      adopt(generation, restored);
      turn.secretAttempt = committedTrace;
    },
  );
}
