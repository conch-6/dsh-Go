import 'dart:async';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/phone/phone_channel.dart';
import 'package:dsh_app/ui/phone/phone_skill_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _id = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _name = 'phone-task-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _candidate = PhoneSkillCandidate(taskId: 7, generation: 3, steps: 1);
const _methods = MethodChannel('dsh/phone');

Map<String, Object?> _view({int revision = 1, int taskId = 7, String id = _id}) => {
  'kind': 'shown',
  'draft': {
    'draftId': id, 'taskId': taskId, 'generation': 3, 'revision': revision,
    'skillName': _name, 'markdown': '# Safe parameterized template\n',
    'stepOrder': [0], 'parameterizedFields': ['goal'], 'phase': null,
  },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(_methods, null));

  test('optional status is absent on an old native module and bounded on v1', () {
    expect(PhoneSkillStatus.parse(null).available, isFalse);
    expect(PhoneSkillStatus.parse({'v': 1.0}).available, isFalse);
    final status = PhoneSkillStatus.parse({'v': 1, 'candidates': [
      {'taskId': 0, 'generation': 3, 'steps': 1},
      for (var i = 1; i <= 12; i++) {'taskId': i, 'generation': 3, 'steps': 1},
    ]});
    expect(status.available, isTrue);
    expect(status.askAfterSuccess, isFalse);
    expect(status.candidates.length, 7);
    expect(() => status.candidates.clear(), throwsUnsupportedError);
  });

  test('the shown revision keeps exact identity and rejects malformed arrays or large UTF8', () {
    final raw = _view()['draft'] as Map<String, Object?>;
    final view = PhoneSkillDraftView.parse(raw)!;
    expect((view.taskId, view.generation, view.revision, view.draftId), (7, 3, 1, _id));
    expect(PhoneSkillDraftView.parse({...raw, 'stepOrder': [0, 0]}), isNull);
    expect(PhoneSkillDraftView.parse({...raw, 'stepOrder': [0.0]}), isNull);
    expect(PhoneSkillDraftView.parse({...raw, 'markdown': List.filled(12000, '字').join()}), isNull);
    expect(PhoneSkillDraftView.parse({...raw, 'phase': 'made_up'}), isNull);
  });

  test('a saved reply is only accepted for the native fixed relative path', () {
    expect(PhoneSkillReply.parse({'kind': 'saved', 'name': _name,
      'relativePath': 'skills/$_name/SKILL.md'}).kind, PhoneSkillReplyKind.saved);
    expect(PhoneSkillReply.parse({'kind': 'saved', 'name': _name,
      'relativePath': '../outside/SKILL.md'}).kind, PhoneSkillReplyKind.rejected);
    expect(PhoneSkillReply.parse({'kind': 'rejected', 'code': 'raw private error'}).code, 'unavailable');
  });

  test('all editor requests use captured native identities and never submit markdown or paths', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(_methods, (call) async {
      calls.add(call);
      return call.method == 'setSkillSavePrompt' ? true : _view();
    });
    final channel = PhoneChannel();
    final draft = (await channel.openSkillDraft(_candidate, confirmed: true)).draft!;
    await channel.editSkillDraft(draft, goal: 'goal', prerequisites: '', checkpoints: [''], stepOrder: [0]);
    await channel.saveSkillDraft(draft, confirmed: true);
    await channel.discardSkillDraft(draft);
    expect(calls[0].arguments, {'action': 'open', 'taskId': 7, 'generation': 3, 'confirmed': true});
    expect(calls[2].arguments, {'taskId': 7, 'draftId': _id, 'revision': 1, 'confirmed': true});
    expect(calls[3].arguments, {'taskId': 7, 'draftId': _id});
    for (final call in calls) {
      expect((call.arguments as Map).keys, isNot(contains('markdown')));
      expect((call.arguments as Map).keys, isNot(contains('relativePath')));
    }
  });

  test('platform errors expose a fixed unavailable code without the exception text', () async {
    messenger.setMockMethodCallHandler(_methods, (_) async {
      throw PlatformException(code: 'PRIVATE', message: 'secret path and message');
    });
    final reply = await PhoneChannel().openSkillDraft(_candidate, confirmed: true);
    expect(reply.code, 'unavailable');
    expect(reply.draft, isNull);
  });

  testWidgets('a late open after dispose cancels only its returned draft', (tester) async {
    final opened = Completer<Map<String, Object?>>();
    final discarded = <Object?>[];
    messenger.setMockMethodCallHandler(_methods, (call) async {
      if (call.method == 'skillDraft') return opened.future;
      if (call.method == 'discardSkillDraft') discarded.add(call.arguments);
      return {'kind': 'discarded'};
    });
    await tester.pumpWidget(MaterialApp(home: PhoneSkillEditor(channel: PhoneChannel(), candidate: _candidate)));
    await tester.pumpWidget(const SizedBox());
    opened.complete(_view());
    await tester.pump();
    await tester.pump();
    expect(discarded, [{'taskId': 7, 'draftId': _id}]);
  });

  testWidgets('editing revokes confirmation and only a newly reviewed revision is saved', (tester) async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(_methods, (call) async {
      calls.add(call);
      if (call.method == 'saveSkillDraft') return {'kind': 'saving', 'phase': 'staging'};
      if (call.method == 'discardSkillDraft') return {'kind': 'discarded'};
      return _view(revision: (call.arguments as Map)['action'] == 'edit' ? 2 : 1);
    });
    await tester.pumpWidget(MaterialApp(home: PhoneSkillEditor(channel: PhoneChannel(), candidate: _candidate)));
    await tester.pumpAndSettle();
    final save = find.widgetWithText(FilledButton, appL10n.commonSave);
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
    await tester.ensureVisible(find.byType(CheckboxListTile));
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();
    expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
    await tester.ensureVisible(find.byType(TextField).first);
    await tester.enterText(find.byType(TextField).first, 'A local private note');
    await tester.pump();
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
    final update = find.text(appL10n.phoneSkillUpdatePreview);
    await tester.ensureVisible(update);
    await tester.tap(update);
    await tester.pumpAndSettle();
    expect(tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value, isFalse);
    await tester.ensureVisible(find.byType(CheckboxListTile));
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();
    await tester.tap(save);
    await tester.pumpAndSettle();
    final writes = calls.where((call) => call.method == 'saveSkillDraft').toList();
    expect(writes.length, 1);
    expect((writes.single.arguments as Map)['revision'], 2);
    expect(find.text(appL10n.phoneSkillCheckWrite), findsOneWidget);
    expect(find.text(appL10n.phoneSkillSavedBody), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('a shown draft for another task never enables saving', (tester) async {
    messenger.setMockMethodCallHandler(_methods, (_) async => _view(taskId: 8));
    await tester.pumpWidget(MaterialApp(home: PhoneSkillEditor(channel: PhoneChannel(), candidate: _candidate)));
    await tester.pumpAndSettle();
    expect(find.text(appL10n.phoneSkillStale), findsOneWidget);
    expect(find.byType(CheckboxListTile), findsNothing);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, appL10n.commonSave)).onPressed, isNull);
  });
}
