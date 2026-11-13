import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'support/t24_engine_harness.dart';

typedef _Json = Map<String, Object?>;
typedef _Bound = ({String characterId, String chatId, String bindId, String fact});
typedef _Active = ({T24Call call, T24Events events});

const _fact = '\uFEFFSECRET-{{incvar::secretLeak}}{{getglobalvar::secretVault}}\uFEFF';
const _template = 'RELEASE-FIXED[{{fact}}] {{user}}';
_Json _map(Object? value) => value! as _Json;
List<_Json> _maps(Object? value) => (value! as List<Object?>).map(_map).toList();
String _text(T24Call call) => _maps(call.body!['messages']).map((row) => row['content']).whereType<String>().join('\n');

Future<T24Harness> _open() async {
  final h = await T24Harness.open(thinking: false);
  addTearDown(h.dispose);
  return h;
}

Future<_Active> _start(TavernEngine engine, T24Model model, String chat) async {
  final call = model.prepare();
  final events = T24Events(engine.send(chat, ''));
  await Future.any<void>([
    call.listening.future,
    events.done.future.then<void>((_) {
      throw TestFailure('Main ended before provider entry: ${events.values}');
    }),
  ]);
  return (call: call, events: events);
}

Future<void> _finish(_Active active, {String reason = 'stop'}) async {
  active.call.add(const ModelText('main body without the secret'));
  await active.call.finish(reason);
  await active.events.done.future;
  expect(active.events.values.whereType<TavernTurnFailed>(), isEmpty);
  expect(active.events.values.whereType<TavernTurnDone>(), hasLength(1));
}

Future<_Active> _reply(T24Harness h, String chat, {String reason = 'stop'}) async {
  final active = await _start(h.engine, h.model, chat);
  await _finish(active, reason: reason);
  return active;
}

_Json _directOutput() => {
  'notes': 'ordinary notes before binding',
  'beat': '',
  'prefetch': <Object?>[],
  'suggestions': [
    for (var i = 0; i < 3; i++) {'text': 'choice-$i', 'risk': ''},
  ],
  'events': <Object?>[],
};

Future<_Bound> _bound(T24Harness h, {bool revealed = true, String template = _template}) async {
  final raw = _map(jsonDecode(utf8.decode(t24Card())));
  _map(raw['data'])['extensions'] = {
    'dshgo': {
      'v': 1,
      'state': {
        'schema': {
          'type': 'object',
          'additionalProperties': false,
          'required': ['entity', 'secret', 'revealed', 'count'],
          'properties': {
            'entity': {'type': 'string'},
            'secret': {
              'type': ['string', 'null'],
              'x-dsh-hidden': true,
              'x-dsh-by': ['rules', 'user'],
            },
            'revealed': {'type': 'boolean'},
            'count': {'type': 'integer'},
          },
        },
        'init': {'entity': 'entity-A', 'secret': null, 'revealed': revealed, 'count': 0},
      },
      'director': {
        'secretSlots': {
          'v': 1,
          'slots': [
            {
              'id': 'identity',
              'path': '/secret',
              'entityPath': '/entity',
              'unbound': {'exists': true, 'value': null},
              'bindWhen': true,
              'release': {
                'id': 'tell',
                'audience': 'currentCharacter',
                'when': {'var': 'revealed'},
                'template': template,
              },
            },
          ],
        },
      },
    },
  };
  final card = await h.engine.importCard(Uint8List.fromList(utf8.encode(jsonEncode(raw))));
  final chat = await h.engine.createChat(card.id);
  await h.engine.setSettings({
    'director': {'enabled': true, 'secretsEnabled': true, 'every': 1},
  });

  // Queue controlled calls before finishing the real main: automatic jobs
  // can enter immediately after its committed terminal.
  final mainCall = h.model.prepare();
  final ordinary = h.model.prepare();
  final secret = h.model.prepare();
  final events = T24Events(h.engine.send(chat, ''));
  await Future.any<void>([
    mainCall.listening.future,
    events.done.future.then<void>((_) => throw TestFailure('Initial main failed: ${events.values}')),
  ]);
  mainCall.add(const ModelText('source main'));
  await mainCall.finish();
  await events.done.future;
  expect(events.values.whereType<TavernTurnFailed>(), isEmpty);
  await ordinary.listening.future.timeout(const Duration(seconds: 10));
  expect(_map(_map(ordinary.body!['tool_choice'])['function'])['name'], 'direct');
  ordinary.add(
    ModelToolFragment(
      index: 0,
      id: 'ordinary-before-secret',
      type: 'function',
      name: 'direct',
      arguments: jsonEncode(_directOutput()),
    ),
  );
  await ordinary.finish('tool_calls');
  await secret.listening.future.timeout(const Duration(seconds: 10));
  expect(_map(_map(secret.body!['tool_choice'])['function'])['name'], 'propose_secrets');
  secret.add(
    ModelToolFragment(
      index: 0,
      id: 'secret-proposal',
      type: 'function',
      name: 'propose_secrets',
      arguments: jsonEncode({
        'notes': 'private proposal notes',
        'facts': [
          {'slotId': 'identity', 'value': _fact},
        ],
      }),
    ),
  );
  await secret.finish('tool_calls');
  await h.engine
      .watchDirector(chat)
      .firstWhere((snapshot) => snapshot.pendingJobs == 0)
      .timeout(const Duration(seconds: 10));
  expect(
    _map((await h.engine.readState(chat)).values)['secret'],
    isNull,
    reason: 'Publishing a proposal must not bind a fact.',
  );
  expect(
    (await h.engine.readAgentRuns(chat, limit: 1000)).where((run) => run.kind == 'director.secret_proposal'),
    hasLength(1),
  );
  await h.engine.setSettings({
    'director': {'every': 1000},
  });
  await _reply(h, chat);
  final bind = (await h.engine.readAgentRuns(
    chat,
    limit: 1000,
  )).singleWhere((run) => run.kind == 'director.secret_bind');
  expect(bind.result['committed'], isTrue);
  expect(_map((await h.engine.readState(chat)).values)['secret'], _fact);
  return (characterId: card.id, chatId: chat, bindId: bind.id, fact: _fact);
}

Future<_Json> _saved(TavernEngine engine, String chat) async {
  final files = await engine.exportChat(chat);
  final document = StChatDocument.decode(files.first.fileName, files.first.bytes);
  final saved = _map(_map(_map(document.messages.last['extra'])['dshgo'])['tavernState']);
  // The document is deeply read-only; mutation fixtures need detached JSON.
  return _map(jsonDecode(jsonEncode(saved)));
}

T _db<T>(T24Harness h, T Function(Database) action) {
  final database = sqlite3.open('${h.root.path}/tavern.sqlite3');
  try {
    return action(database);
  } finally {
    database.close();
  }
}

Future<void> _replaceSaved(T24Harness h, String chat, _Json saved) async {
  final leaf = (await h.engine.path(chat)).last.nodeId;
  _db(h, (database) {
    final extra = _map(
      jsonDecode(database.select('SELECT extra FROM nodes WHERE id = ?', [leaf]).single['extra']! as String),
    );
    extra['dshgo'] = {..._map(extra['dshgo']), 'tavernState': saved};
    database.execute('UPDATE nodes SET extra = ? WHERE id = ?', [jsonEncode(extra), leaf]);
  });
}

Future<_Json> _trace(TavernEngine engine, String chat) async =>
    _map((await engine.inspectTurn(chat))!.state['secrets']);

void main() {
  test('literal release preserves BOM and macros and records offered included attempted without knownBy', () async {
    final h = await _open();
    await h.engine.setGlobalVariables({'secretVault': 'GLOBAL-MUST-NOT-EXPAND'});
    final bound = await _bound(h);
    final ledger = (await _saved(h.engine, bound.chatId))['dshgoSecretRuntime'];
    final active = await _reply(h, bound.chatId, reason: 'length');
    expect(_text(active.call), contains(_template.replaceAll('{{fact}}', _fact)));
    expect(_text(active.call), isNot(contains('GLOBAL-MUST-NOT-EXPAND')));
    expect(h.engine.variables(bound.chatId).containsKey('secretLeak'), isFalse);
    expect(jsonEncode(active.call.body!['tools']), isNot(contains(_fact)));
    expect(jsonEncode(active.call.body!['tools']), isNot(contains('"/secret"')));
    final trace = await _trace(h.engine, bound.chatId);
    final offered = _maps(trace['offered']).single;
    expect(offered['text'], _template.replaceAll('{{fact}}', _fact));
    expect(trace['included'], [offered['sourceId']]);
    expect(trace['attempted'], trace['included']);
    expect((await _saved(h.engine, bound.chatId))['dshgoSecretRuntime'], ledger);
    expect(jsonEncode(ledger), isNot(contains('knownBy')));
    expect(_map((await h.engine.readState(bound.chatId)).values)['secret'], _fact);
  });

  test('real prompt budget exclusion is offered only and does not alter the fact ledger', () async {
    final h = await _open();
    final template = 'BUDGET-SECRET-${List.filled(40000, 'x').join()}{{fact}}';
    final bound = await _bound(h, template: template);
    final before = (await _saved(h.engine, bound.chatId))['dshgoSecretRuntime'];
    final active = await _reply(h, bound.chatId);
    expect(_text(active.call), isNot(contains('BUDGET-SECRET-')));
    expect(_text(active.call), isNot(contains(_fact)));
    final trace = await _trace(h.engine, bound.chatId);
    expect(trace['offered'], hasLength(1));
    expect(trace['included'], isEmpty);
    expect(trace['attempted'], isEmpty);
    expect((await _saved(h.engine, bound.chatId))['dshgoSecretRuntime'], before);
  });

  test('release condition is reevaluated from current persisted state and user reads keep the private value', () async {
    final h = await _open();
    final bound = await _bound(h, revealed: false);
    final hidden = await _reply(h, bound.chatId);
    expect(_text(hidden.call), isNot(contains(_fact)));
    expect((await _trace(h.engine, bound.chatId))['offered'], isEmpty);
    final edit = await h.engine.setStateValue(bound.chatId, '/revealed', true);
    expect(edit.applied, isTrue);
    final released = await _reply(h, bound.chatId);
    expect(_text(released.call), contains(_fact));
    expect((await h.engine.readState(bound.chatId)).hiddenPaths, contains('/secret'));
    expect(_map((await h.engine.readState(bound.chatId)).values)['secret'], _fact);
  });

  for (final path in ['/secret', '/entity']) {
    test('editing $path revokes the old value or entity proof while retaining protection', () async {
      final h = await _open();
      final bound = await _bound(h);
      const replacement = 'REPLACED-PRIVATE-IDENTITY';
      expect((await h.engine.setStateValue(bound.chatId, path, replacement)).applied, isTrue);
      final active = await _reply(h, bound.chatId);
      expect(_text(active.call), isNot(contains(_fact)));
      if (path == '/secret') expect(_text(active.call), isNot(contains(replacement)));
      expect((await _trace(h.engine, bound.chatId))['offered'], isEmpty);
      expect((await _saved(h.engine, bound.chatId))['dshgoSecretRuntime'], isNotNull);
    });
  }

  for (final carrier in ['dshgoSecretRuntime', 'dshgoStateRuntime']) {
    test('unavailable $carrier is preserved and cannot authorize release', () async {
      final h = await _open();
      final bound = await _bound(h);
      final saved = await _saved(h.engine, bound.chatId);
      final broken = <String, Object?>{
        'version': 999,
        'opaque': ['preserve exact content'],
      };
      saved[carrier] = broken;
      await _replaceSaved(h, bound.chatId, saved);
      final active = await _reply(h, bound.chatId);
      expect(_text(active.call), isNot(contains(_fact)));
      expect((await _trace(h.engine, bound.chatId))['offered'], isEmpty);
      expect((await _saved(h.engine, bound.chatId))[carrier], broken);
      expect(active.call.body!['tools'], isNull);
    });
  }

  test(
    'removing declaration and hidden metadata leaves ledger paths protected and disables the automatic tool',
    () async {
      final h = await _open();
      final bound = await _bound(h);
      await h.engine.close();
      final file = File('${h.root.path}/characters/${bound.characterId}/card.json');
      final raw = _map(jsonDecode(await file.readAsString()));
      final own = _map(_map(_map(raw['data'])['extensions'])['dshgo']);
      _map(own['director']).remove('secretSlots');
      _map(_map(_map(_map(own['state'])['schema'])['properties'])['secret']).remove('x-dsh-hidden');
      await file.writeAsString(jsonEncode(raw), flush: true);
      await h.reopen();
      final active = await _reply(h, bound.chatId);
      expect(_text(active.call), isNot(contains(_fact)));
      expect(active.call.body!['tools'], isNull);
      final snapshot = await h.engine.readState(bound.chatId);
      expect(snapshot.hiddenPaths, contains('/secret'));
      expect(_map(snapshot.values)['secret'], _fact);
      final trace = await _trace(h.engine, bound.chatId);
      expect(_maps(trace['issues']).map((issue) => issue['code']), contains('secret_state_tool_unavailable'));
      expect(trace['offered'], isEmpty);
    },
  );

  test('JSONL preserves the ledger but lacks same-chat bind evidence and cannot release', () async {
    final h = await _open();
    final bound = await _bound(h);
    final files = await h.engine.exportChat(bound.chatId);
    final imported = (await h.engine.importChats(bound.characterId, files)).chatIds.single;
    expect(
      (await _saved(h.engine, imported))['dshgoSecretRuntime'],
      (await _saved(h.engine, bound.chatId))['dshgoSecretRuntime'],
    );
    expect(
      (await h.engine.readAgentRuns(imported, limit: 1000)).where((run) => run.kind == 'director.secret_bind'),
      isEmpty,
    );
    final active = await _reply(h, imported);
    expect(_text(active.call), isNot(contains(_fact)));
    expect((await _trace(h.engine, imported))['offered'], isEmpty);
    expect(_map((await h.engine.readState(imported)).values)['secret'], _fact);
  });

  test('full backup restores the same-chat durable proof and literal release', () async {
    final h = await _open();
    final bound = await _bound(h);
    final work = await Directory.systemTemp.createTemp('dsh-t18-secret-backup-');
    TavernEngine? restored;
    addTearDown(() async {
      await restored?.close();
      await work.delete(recursive: true);
    });
    final archive = File('${work.path}/secrets.zip');
    await h.engine.backup(archive.path);
    final target = Directory('${work.path}/restored');
    await restoreTavernDirectory(archive.path, target.path);
    final model = T24Model();
    final engine = restored = await TavernEngine.openDirectory(
      target,
      config: h.config,
      modelClient: model,
      clock: () => T24Harness.at,
      random: () => 0.25,
    );
    final proof = (await engine.readAgentRuns(bound.chatId, limit: 1000)).singleWhere((run) => run.id == bound.bindId);
    expect(proof.kind, 'director.secret_bind');
    expect(proof.result['committed'], isTrue);
    final active = await _start(engine, model, bound.chatId);
    expect(_text(active.call), contains(_fact));
    await _finish(active);
    expect((await _trace(engine, bound.chatId))['attempted'], hasLength(1));
  });

  test('read watch and export do not advance binding or release knowledge', () async {
    final h = await _open();
    final bound = await _bound(h);
    final before = _db(
      h,
      (database) => {
        for (final table in ['chats', 'nodes', 'node_states', 'agent_runs'])
          table: [
            for (final row in database.select('SELECT * FROM $table ORDER BY rowid')) Map<String, Object?>.from(row),
          ],
      },
    );
    final calls = h.model.generated;
    await h.engine.readState(bound.chatId);
    await h.engine.readDirector(bound.chatId);
    await h.engine.watchDirector(bound.chatId).first;
    await h.engine.readAgentRuns(bound.chatId, limit: 1000);
    await h.engine.exportChat(bound.chatId);
    expect(
      _db(
        h,
        (database) => {
          for (final table in ['chats', 'nodes', 'node_states', 'agent_runs'])
            table: [
              for (final row in database.select('SELECT * FROM $table ORDER BY rowid')) Map<String, Object?>.from(row),
            ],
        },
      ),
      before,
    );
    expect(h.model.generated, calls);
  });

  test('proof revoked after offering but during real assembly prevents the provider attempt', () async {
    final h = await _open();
    final bound = await _bound(h);
    await h.engine.close();
    var revoked = false;
    const estimated = EstimatedTokenCounter();
    void revoke(String text) {
      if (revoked || !text.contains('RELEASE-FIXED[')) return;
      revoked = true;
      _db(h, (database) => database.execute('DELETE FROM agent_runs WHERE id = ?', [bound.bindId]));
    }

    h.engine = await TavernEngine.openDirectory(
      h.root,
      config: h.config,
      modelClient: h.model,
      clock: () => T24Harness.at,
      random: () => 0.25,
      counter: CallbackTokenCounter(
        name: 'real budget with proof revocation',
        exact: false,
        message: (message) {
          revoke(jsonEncode(message));
          return estimated.countMessage(message);
        },
        text: (text) {
          revoke(text);
          return estimated.countText(text);
        },
      ),
    );
    final before = h.model.generated;
    final values = await h.engine.send(bound.chatId, '').toList();
    expect(revoked, isTrue, reason: 'The real assembler must have offered the release before revocation.');
    expect(values.whereType<TavernTurnFailed>(), hasLength(1));
    expect(values.whereType<TavernTurnDone>(), isEmpty);
    expect(h.model.generated, before, reason: 'An old assembly authorization cannot reach generate().');
    final trace = await _trace(h.engine, bound.chatId);
    expect(trace['offered'], hasLength(1));
    expect(trace['included'], hasLength(1));
    expect(trace['attempted'], isEmpty);
    expect(_maps(trace['issues']).map((issue) => issue['code']), contains('secret_release_revoked'));
    expect(_map((await h.engine.readState(bound.chatId)).values)['secret'], _fact);
  });
}
