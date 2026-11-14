part of 'engine.dart';

extension _ScriptRegexBridge on _ScriptCoordinator {
  Future<List<TavernScriptRegex>> queryTavernRegexes(String contextId, TavernScriptRegexQuery query) async {
    final context = _context(contextId);
    final chatId = context.value.chatId;
    final chat = chatId == null ? null : engine._store.chat(chatId);
    final metadata = chat == null ? null : engine._chatCodec.metadataForNode(engine._store, chat.id);
    final settings = _runtimeCopy(engine._effectiveSettings(chat, metadata));
    final selection = engine._resolvePreset(chat);
    final selectedPreset = query.presetId == null ? selection.preset : engine._requirePreset(query.presetId!);
    final presetRaw = query.presetId == null ? _map(settings['preset']) : selectedPreset!.raw;
    final presetSettings = (presetRaw.isEmpty ? ChatPreset.stDefault() : ChatPreset(presetRaw)).settings;
    final managed = engine._regexLibrary.scripts;
    final group = chat == null ? null : engine._store.groupChat(chat.id);
    final actorId = query.characterId ?? context.value.characterId ?? (group == null ? chat?.characterId : null);
    final result = <TavernScriptRegex>[];
    final enabledGlobally = settings['regexEnabled'] != false;

    void addArray(
      Object? value,
      TavernScriptRegexSource source,
      Map<String, Object?> location, {
      required bool sourceEnabled,
    }) {
      if (value is! List<Object?>) return;
      final version = _scriptRegexVersion(value);
      for (final (index, item) in value.indexed) {
        // This is the same execution projection as RegexEngine.readScripts.
        // A non-object member is not an executable rule and has no rule DTO.
        if (item is! Map<String, Object?>) continue;
        final raw = _captureScriptObject(item);
        final execution = RegexScript.fromJson(raw);
        final effective = enabledGlobally && sourceEnabled && !execution.disabled;
        if (query.effectiveOnly && !effective) continue;
        result.add(
          TavernScriptRegex(
            source: source,
            sourceRef: {...location, 'index': index, 'version': version},
            raw: raw,
            stId: execution.id,
            execution: execution,
            enabled: !execution.disabled,
            effective: effective,
            diagnostics: _scriptRegexShapeDiagnostics(raw, index),
          ),
        );
      }
    }

    if (query.sources.contains(TavernScriptRegexSource.global)) {
      addArray(settings['globalRegexScripts'] ?? settings['regex'], TavernScriptRegexSource.global, {
        'kind': 'inlineGlobal',
      }, sourceEnabled: true);
      for (final (index, item) in managed.indexed) {
        final raw = item.raw;
        final execution = RegexScript.fromJson({...raw, if (!item.compatible) 'disabled': true});
        final effective = enabledGlobally && !execution.disabled;
        if (query.effectiveOnly && !effective) continue;
        result.add(
          TavernScriptRegex(
            source: TavernScriptRegexSource.global,
            sourceRef: {
              'kind': 'managedGlobal',
              'resourceId': item.id,
              'index': index,
              'version': _scriptRegexVersion({
                'raw': raw,
                'diagnostics': [for (final diagnostic in item.diagnostics) diagnostic.toJson()],
              }),
            },
            raw: raw,
            engineId: item.id,
            stId: execution.id,
            execution: execution,
            enabled: item.enabled,
            effective: effective,
            diagnostics: item.diagnostics,
          ),
        );
      }
    }
    if (query.sources.contains(TavernScriptRegexSource.preset)) {
      addArray(_map(presetSettings['extensions'])['regex_scripts'], TavernScriptRegexSource.preset, {
        'kind': 'preset',
        'resourceId': selectedPreset?.id,
        'selection': query.presetId == null ? selection.selection.source.name : 'explicit',
      }, sourceEnabled: settings['presetRegexEnabled'] != false);
    }
    if (query.sources.contains(TavernScriptRegexSource.character) && actorId != null) {
      final actor = await engine._record(actorId);
      _context(contextId);
      if (actor == null) {
        throw _scriptError(
          TavernScriptErrorCode.notFound,
          'getTavernRegexes',
          'The selected character is unavailable.',
          contextId: contextId,
        );
      }
      final card = _effectiveCard(actor.card.data, settings);
      addArray(
        _map(card['extensions'])['regex_scripts'],
        TavernScriptRegexSource.character,
        {'kind': 'character', 'resourceId': actorId},
        sourceEnabled:
            settings['characterRegexEnabled'] != false &&
            !_strings(settings['disabledCharacterRegex']).contains(actorId),
      );
    }
    return List.unmodifiable(result);
  }

  Future<TavernDisplayResult> formatScriptText(
    String contextId,
    String text, {
    required int source,
    required RegexPhase destination,
    num? depth,
    String? characterId,
  }) async {
    final context = _context(contextId);
    if (!const {
      RegexPlacement.userInput,
      RegexPlacement.aiOutput,
      RegexPlacement.slashCommand,
      RegexPlacement.worldInfo,
      RegexPlacement.reasoning,
    }.contains(source)) {
      throw _scriptError(
        TavernScriptErrorCode.invalidArgument,
        'formatAsTavernRegexedString',
        'The regex source must be a supported numeric placement.',
        contextId: contextId,
      );
    }
    if (destination != RegexPhase.prompt && destination != RegexPhase.display) {
      throw _scriptError(
        TavernScriptErrorCode.unsupportedOption,
        'formatAsTavernRegexedString',
        'This formatter supports prompt and display destinations.',
        contextId: contextId,
      );
    }
    if ((depth != null && !depth.isFinite) || characterId == '') {
      throw _scriptError(
        TavernScriptErrorCode.invalidArgument,
        'formatAsTavernRegexedString',
        'Depth must be finite and an explicit character id must be nonempty.',
        contextId: contextId,
      );
    }
    final chatId = context.value.chatId;
    final chat = chatId == null ? null : engine._store.chat(chatId);
    final anchor = chat?.currentLeafId;
    final group = chat == null ? null : engine._store.groupChat(chat.id);
    final metadata = chat == null
        ? <String, Object?>{}
        : _runtimeCopy(engine._chatCodec.metadataForNode(engine._store, chat.id));
    final state = chat == null
        ? <String, Object?>{}
        : anchor == null && group == null
        ? _emptyChatState(metadata)
        : engine._stateAt(chat.id, anchor);
    final history = chat == null ? <StoredNode>[] : engine._historyTo(chat.id, anchor);
    final live = chat == null ? null : engine._liveVariables[chat.id];
    final local = _runtimeCopy(
      live != null && live.leaf == anchor
          ? live.values
          : state.containsKey('variables')
          ? _map(state['variables'])
          : chat?.variables ?? <String, Object?>{},
    );
    final global = _runtimeCopy(engine._globalVariables);
    final settings = _runtimeCopy(
      _personaSettings(engine._effectiveSettings(chat, metadata), engine._personas.resolve(personaId: chat?.personaId)),
    );
    final config = engine._config;
    final at = engine._clock();
    final actorId = characterId ?? context.value.characterId ?? (group == null ? chat?.characterId : null);
    final actor = actorId == null ? null : await engine._record(actorId);
    if (actorId != null && actor == null) {
      throw _scriptError(
        TavernScriptErrorCode.notFound,
        'formatAsTavernRegexedString',
        'The selected character is unavailable.',
        contextId: contextId,
      );
    }
    final groupView = group == null ? null : await engine._groups.capture(group);
    _context(contextId);
    final random = Random(_displaySeed(jsonEncode([chatId, context.value.nodeId, source, destination.name])));
    final environment = _MacroEnvironment(
      actor == null ? <String, Object?>{} : _effectiveCard(actor.card.data, settings),
      settings,
      local,
      global,
      history,
      config,
      at,
      random.nextDouble,
      chat == null
          ? ''
          : _macroChatIdentity(
              chat,
              state,
              metadata,
              state['chatJsonlSourceFile'] as String?,
              node: history.lastOrNull,
            ),
      '',
      'normal',
      chatIdHash: _finiteNumber(metadata['chat_id_hash']),
      pickRerollSeed: metadata['pick_reroll_seed'],
      characterId: actorId ?? '',
      groupNames: groupView?.names,
      groupNotMuted: groupView?.enabledNames,
    );
    final RegexDisplayResult rendered;
    if (destination == RegexPhase.display) {
      rendered = await environment.regex.applyDisplay(
        text,
        placement: source,
        worker: engine._regexWorker,
        depth: depth,
        expand: environment.regexExpand,
        characterOverride: source == RegexPlacement.userInput ? environment.userName : null,
        isCancelled: () => context.closed || _closed || engine._closing,
      );
    } else {
      rendered = environment.regex.applyWithDiagnostics(
        text,
        placement: source,
        phase: RegexPhase.prompt,
        depth: depth,
        expand: environment.regexExpand,
        characterOverride: source == RegexPlacement.userInput ? environment.userName : null,
      );
    }
    // Both phases are detached: no live variable/hash, SQL or generation receipt.
    return TavernDisplayResult(
      text: rendered.text,
      warnings: rendered.warnings,
      replacements: rendered.replacements,
      superseded: rendered.cancelled || context.closed || _closed || engine._closing,
    );
  }
}

String _scriptRegexVersion(Object? raw) => crypto.sha256.convert(utf8.encode(jsonEncode(raw))).toString();

List<TavernRegexDiagnostic> _scriptRegexShapeDiagnostics(Map<String, Object?> raw, int index) {
  final trims = raw['trimStrings'];
  if (raw['findRegex'] is String &&
      raw['replaceString'] is String &&
      (trims == null || (trims is List<Object?> && trims.every((item) => item is String)))) {
    return const [];
  }
  return [
    TavernRegexDiagnostic(
      path: '[$index]',
      status: TavernRegexCompatibility.incompatible,
      code: 'invalid-script',
      message: 'Known regex string fields have an incompatible shape.',
    ),
  ];
}
