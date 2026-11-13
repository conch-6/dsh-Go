part of 'engine.dart';

const _cardEventRuntimeKey = 'dshgoDirectorEventRuntime';

state_core.CardEventDefinition _cardEventDefinition(Map<String, Object?> data) {
  final own = _map(_map(data['extensions'])['dshgo']);
  return state_core.CardEventDefinition.parse(
    _map(own['director'])['eventRules'],
    version: own.containsKey('v') ? own['v'] : 1,
  );
}

/// This records the fixed card vocabulary seen by this helper. It does not
/// enable automatic execution: the main turn must still pass its current gate.
Map<String, Object?>? _cardEventCapability(Map<String, Object?> data, Map<String, Object?> settings) {
  final definition = _cardEventDefinition(data);
  if (!definition.executable) return null;
  final state = _stateDefinition(data);
  return {
    'version': 1,
    'mode': 'literal',
    'registryFingerprint': definition.fingerprint,
    'stateDefinitionFingerprint': state.hasSchema ? state.fingerprint : null,
    'handlerIds': definition.handlerIds,
    'automaticEnabledAtCapture': _map(settings['director'])['enabled'] == true,
  };
}

Map<String, Object?>? _cardEventSnapshot(
  TavernEngine engine,
  StoredChat chat,
  Map<String, Object?> data,
  Map<String, Object?> settings,
) {
  final definition = _cardEventDefinition(data);
  final leaf = chat.currentLeafId;
  final saved = leaf == null ? <String, Object?>{} : engine._stateAt(chat.id, leaf);
  if (!definition.defined && !saved.containsKey(_cardEventRuntimeKey)) return null;
  final snapshot = definition.inspect(
    runtimeExists: saved.containsKey(_cardEventRuntimeKey),
    runtime: saved[_cardEventRuntimeKey],
  );
  final own = leaf == null ? <String, Object?>{} : _map(engine._store.node(chat.id, leaf).extra['dshgo']);
  return {
    ...snapshot.toJson(),
    'nodeId': leaf,
    'automaticEnabled': _map(settings['director'])['enabled'] == true,
    'receipts': _stateRows(own['directorEventReceipts']),
    'effects': _stateRows(own['directorEventEffects']),
    'pendingConsumed': _strings(own['directorEventPendingConsumed']),
    'issues': [...snapshot.issues, ..._stateRows(own['directorEventIssues'])],
  };
}

void _prepareCardEventTurn(TavernEngine engine, _Turn turn, Map<String, Object?> data) {
  if (turn.kind == _TurnKind.impersonate) return;
  final definition = _cardEventDefinition(data);
  if (!definition.defined && !turn.state.containsKey(_cardEventRuntimeKey)) return;
  turn.cardEventDefinition = definition;
  final snapshot = definition.inspect(
    runtimeExists: turn.state.containsKey(_cardEventRuntimeKey),
    runtime: turn.state[_cardEventRuntimeKey],
  );
  turn.cardEventPreparationIssues.addAll(snapshot.issues);
  final prepared = turn.directorPrepared;
  if (prepared == null || !prepared.eligible || prepared.output == null) return;
  final stored = prepared.stored;
  final capability = stored.result['eventCapability'];
  final state = _stateDefinition(data);
  if (capability is! Map<String, Object?> ||
      capability['version'] != 1 ||
      capability['mode'] != 'literal' ||
      !definition.executable ||
      capability['registryFingerprint'] != definition.fingerprint ||
      !capability.containsKey('stateDefinitionFingerprint') ||
      capability['stateDefinitionFingerprint'] != (state.hasSchema ? state.fingerprint : null) ||
      !_stateJsonEqual(capability['handlerIds'], definition.handlerIds)) {
    turn.cardEventPreparationIssues.add(_directorIssue('director_event_capability_unavailable', id: stored.id));
    return;
  }
  turn.cardEventAuthorizedHandlers.addAll(definition.handlerIds);
  turn.cardEventSource = {
    'runId': stored.id,
    'sourceKind': stored.result['sourceKind'],
    'sourceNodeId': stored.result['sourceNodeId'],
    'sourceFingerprint': stored.result['sourceFingerprint'],
    'capability': _copy(capability),
  };
  final events = prepared.output!.events;
  for (var index = 0; index < events.length; index++) {
    final event = events[index];
    final id = '${stored.id}:event:$index';
    final proposal = engine._store.agentRunById(turn.chat.id, id);
    final raw = proposal?.result;
    final decoded = proposal == null ? null : engine._directors._event(proposal);
    // The original durable proposal is authority. Never synthesize it from
    // the output alone or substitute a newer run found during asynchronous IO.
    if (proposal == null ||
        proposal.kind != 'director.event' ||
        decoded == null ||
        !decoded.available ||
        raw == null ||
        raw['outputIndex'] != index ||
        decoded.runId != stored.id ||
        decoded.sourceKind != stored.result['sourceKind'] ||
        decoded.sourceNodeId != stored.result['sourceNodeId'] ||
        decoded.sourceFingerprint != stored.result['sourceFingerprint'] ||
        raw['createdAt'] != stored.result['finishedAt'] ||
        decoded.name != event['name'] ||
        decoded.data != event['data']) {
      turn.cardEventPreparationIssues.add(_directorIssue('director_event_proposal_unavailable', id: id));
      continue;
    }
    turn.cardEventProposals.add(
      state_core.CardEventProposal(eventId: id, runId: stored.id, name: decoded.name!, data: decoded.data!),
    );
  }
}

List<PromptInjection> _cardEventTurnInjections(_Turn turn) {
  final definition = turn.cardEventDefinition;
  if (definition == null || _map(turn.settings['director'])['enabled'] != true || turn.kind == _TurnKind.impersonate) {
    return [];
  }
  final snapshot = definition.inspect(
    runtimeExists: turn.state.containsKey(_cardEventRuntimeKey),
    runtime: turn.state[_cardEventRuntimeKey],
  );
  // Validate the entire ledger, not just plausible-looking prompt rows.
  if (!snapshot.valid) return [];
  final injections = <PromptInjection>[];
  for (final prompt in snapshot.pendingPrompts) {
    final id = prompt['id']! as String;
    final sourceId = 'dshgo.director.event.prompt:$id';
    turn.cardEventOfferedPrompts[sourceId] = id;
    injections.add(
      PromptInjection(
        fragment: PromptFragment(
          prompt['text']! as String,
          PromptSource('directorEventPrompt', sourceId, label: '事件提示'),
          trimOnOverflow: true,
          expandMacros: false,
        ),
        depth: 1,
        order: 202,
      ),
    );
  }
  return injections;
}

void _captureCardEventAssembly(_Turn turn, PromptAssembly assembly) {
  if (turn.cardEventOfferedPrompts.isEmpty) return;
  for (final segment in assembly.afterPostProcessing) {
    final content = segment.message['content'];
    if (content is! String || content.trim().isEmpty) continue;
    for (final source in segment.sources) {
      final ledgerId = turn.cardEventOfferedPrompts[source.id];
      if (source.kind == 'directorEventPrompt' && ledgerId != null) {
        turn.cardEventSentPrompts.add(ledgerId);
      }
    }
  }
}

state_core.CardEventInvocation? _cardEventInvocation(
  TavernEngine engine,
  _Turn turn,
  Map<String, Object?> before, {
  required bool normal,
  required bool sharedSession,
}) {
  final definition = turn.cardEventDefinition;
  if (definition == null) return null;
  final settings = engine._effectiveSettings(engine._store.chat(turn.chat.id));
  turn.cardEventTerminalEnabled = _map(settings['director'])['enabled'] == true;
  final secretReason = _secretDirectorTurnReason(engine, turn, before);
  if (secretReason != null) turn.cardEventPreparationIssues.add(_directorIssue(secretReason));
  final invocation = turn.cardEventInvocationId ??= turn.stateInvocationId ?? _newStateId();
  return state_core.CardEventInvocation(
    definition: definition,
    invocationId: invocation,
    capabilityFingerprint: definition.fingerprint,
    authorizedHandlerIds: normal && turn.cardEventTerminalEnabled && secretReason == null
        ? turn.cardEventAuthorizedHandlers
        : const [],
    proposals: turn.cardEventProposals,
    runtimeExists: before.containsKey(_cardEventRuntimeKey),
    runtime: before[_cardEventRuntimeKey],
    stateActionAllowed: normal && turn.cardEventTerminalEnabled && sharedSession && settings['stateEnabled'] != false,
  );
}

class _CardEventSettlement {
  _CardEventSettlement({
    required this.state,
    required this.runId,
    required this.result,
    required this.trace,
    this.ownAudit,
  });
  final Map<String, Object?> state;
  final String runId;
  final Map<String, Object?> result;
  final Map<String, Object?> trace;
  final Map<String, Object?>? ownAudit;
}

/// New ledger changes and literal effects require final shared-state validity.
/// Confirmation of an already-sent prompt is independent of a newly revoked
/// dispatch gate, but still requires a normal terminal and a valid old ledger.
_CardEventSettlement? _finishCardEventTurn(
  _Turn turn,
  Map<String, Object?> before,
  Map<String, Object?> stateAfter,
  state_core.CardEventResult? candidate,
  List<Map<String, Object?>> effects, {
  required bool normal,
  required bool sharedStateAccepted,
  List<Map<String, Object?>> conditionIssues = const [],
}) {
  final definition = turn.cardEventDefinition;
  if (definition == null) return null;
  final invocation = turn.cardEventInvocationId ??= turn.stateInvocationId ?? _newStateId();
  final accepted = normal && sharedStateAccepted && candidate != null && candidate.valid ? candidate : null;
  final snapshot = definition.inspect(
    runtimeExists: before.containsKey(_cardEventRuntimeKey),
    runtime: before[_cardEventRuntimeKey],
  );
  final consumed = normal && snapshot.valid
      ? {
          for (final prompt in snapshot.pendingPrompts)
            if (turn.cardEventSentPrompts.contains(prompt['id'])) prompt['id']! as String,
        }
      : <String>{};
  final eventEffects = accepted == null
      ? <Map<String, Object?>>[]
      : effects.where((effect) => effect['source'] == 'directorEvent').toList();
  final next = _copy(stateAfter);
  final acceptedRuntime = accepted != null && accepted.runtimeExists ? accepted.runtime : null;
  Map<String, Object?>? runtime = acceptedRuntime is Map<String, Object?>
      ? _copy(acceptedRuntime)
      : snapshot.valid && before[_cardEventRuntimeKey] is Map<String, Object?>
      ? _copy(before[_cardEventRuntimeKey]! as Map<String, Object?>)
      : null;
  final prompts = eventEffects.where((effect) => effect['type'] == 'prompt').toList();
  if (consumed.isNotEmpty || prompts.isNotEmpty) {
    runtime ??= {'version': 1};
    runtime['pendingPrompts'] = [
      for (final prompt in _stateRows(runtime['pendingPrompts']))
        if (!consumed.contains(prompt['id'])) prompt,
      for (final prompt in prompts)
        {
          'id': prompt['effectId'],
          'text': prompt['text'],
          'invocationId': prompt['invocationId'],
          'source': 'directorEvent',
          'eventId': prompt['eventId'],
          'runId': prompt['runId'],
          'handlerId': prompt['handlerId'],
          'actionIndex': prompt['actionIndex'],
        },
    ];
  }
  final changed =
      runtime != null &&
      (!before.containsKey(_cardEventRuntimeKey) || !_stateJsonEqual(before[_cardEventRuntimeKey], runtime));
  if (changed) next[_cardEventRuntimeKey] = runtime;
  final committed = normal && (changed || eventEffects.isNotEmpty);
  final receipts = candidate?.receipts ?? <Map<String, Object?>>[];
  final issues = <Map<String, Object?>>[
    ...turn.cardEventPreparationIssues,
    ...conditionIssues,
    if (candidate != null) ...candidate.issues,
    if (!sharedStateAccepted) _directorIssue('director_event_state_not_committed'),
    if (!normal) _directorIssue('director_event_terminal_not_normal'),
  ];
  final runId = '$invocation:events';
  final result = <String, Object?>{
    'version': 1, 'invocationId': invocation, 'registryFingerprint': definition.fingerprint,
    'committed': committed, 'changed': changed, 'handlerCandidateAccepted': accepted != null,
    'automaticEnabled': turn.cardEventTerminalEnabled, 'generationType': turn.generationType,
    'finishReason': turn.finishReason, if (turn.cardEventSource != null) 'source': _copy(turn.cardEventSource!),
    'receipts': receipts, 'effects': eventEffects, 'pendingConsumed': consumed.toList(),
    'issues': issues,
    // The portable node owns the historical ledger. Audit only this batch,
    // rather than duplicating its growing runtime in every run and inspection.
    if (candidate != null)
      'settlement': {
        'valid': candidate.valid,
        'runtimeExists': candidate.runtimeExists,
        'initialized': candidate.initialized,
        'changed': candidate.changed,
      },
  };
  return _CardEventSettlement(
    state: next,
    runId: runId,
    result: result,
    trace: {
      ..._copy(result),
      'runId': runId,
      'pendingOffered': turn.cardEventOfferedPrompts.values.toList(),
      'pendingIncluded': turn.cardEventSentPrompts.toList(),
    },
    ownAudit: committed
        ? {
            'directorEventInvocation': {'version': 1, 'id': invocation},
            'directorEventReceipts': receipts,
            'directorEventEffects': eventEffects,
            'directorEventPendingConsumed': consumed.toList(),
            'directorEventIssues': issues,
          }
        : null,
  );
}

_CardEventSettlement? _failedCardEventSettlement(
  _Turn turn,
  _CardEventSettlement? attempt,
  TavernTurnInspection inspection,
) {
  if (attempt == null) return null;
  final failed = <String, Object?>{
    ..._copy(attempt.result),
    'committed': false,
    'changed': false,
    'handlerCandidateAccepted': false,
    'outcome': 'not-committed',
    'failure': inspection.failure?.name,
    'detail': inspection.detail,
    'attemptedReceipts': attempt.result['receipts'],
    'attemptedEffects': attempt.result['effects'],
    'receipts': <Object?>[],
    'effects': <Object?>[],
    'pendingConsumed': <Object?>[],
  };
  return _CardEventSettlement(
    state: turn.currentState,
    runId: attempt.runId,
    result: failed,
    trace: {..._copy(attempt.trace), ...failed},
  );
}
