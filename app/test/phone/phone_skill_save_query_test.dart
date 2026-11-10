import 'dart:async';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/phone/phone_channel.dart';
import 'package:dsh_app/ui/phone/phone_skill_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _methods = MethodChannel('dsh/phone');
const _draft = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _bundle = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _name = 'phone-task-cccccccccccccccccccccccccccccccc';
Map<String, Object?> _record({String kind = 'unverified', String publication = 'published'}) => {
  'taskId': 7, 'draftId': _draft, 'name': _name, 'bundleRevision': _bundle, 'kind': kind,
  if (kind == 'saving') 'phase': 'committing',
  if (kind == 'unverified') ...{'publication': publication, 'code': 'verification_unavailable'},
};
Map<String, Object?> _reply({String kind = 'saved'}) => {
  ..._record(kind: kind), 'relativePath': 'skills/$_name/SKILL.md',
};
Future<void> _mount(WidgetTester tester, PhoneSkillSaveResult result) =>
  tester.pumpWidget(MaterialApp(home: PhoneSkillEditor.result(channel: PhoneChannel(), result: result)));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(_methods, null));

  test('saveResults are bounded immutable native handles and never editable drafts', () {
    final status = PhoneSkillStatus.parse({'v': 1, 'saveResults': [for (var i = 0; i < 10; i++) _record()]});
    expect(status.saveResults.length, 8);
    expect(() => status.saveResults.clear(), throwsUnsupportedError);
    expect(status.candidates, isEmpty);
    expect(status.saveResults.first.reply.draft, isNull);
    expect(status.saveResults.first.handle.query, {'action': 'check_save', 'taskId': 7,
      'draftId': _draft, 'name': _name, 'bundleRevision': _bundle});
    for (final change in <Map<String, Object?>>[
      {'taskId': 7.0}, {'taskId': 0}, {'draftId': null}, {'name': '../other'},
      {'bundleRevision': null}, {'kind': 'shown'}, {'publication': 'not_written'}, {'code': 'private'},
    ]) {
      expect(PhoneSkillSaveResult.parse({..._record(), ...change}), isNull);
    }
    expect(PhoneSkillStatus.parse({'v': 1}).saveResults, isEmpty);
  });

  for (final publication in ['published', 'unknown']) {
    testWidgets('native status $publication result opens readonly and checks exact original identity', (tester) async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(_methods, (call) async {
        calls.add(call);
        if (call.method == 'status') return {'ready': true, 'skills': {'v': 1, 'saveResults': [_record(publication: publication)]}};
        return _reply();
      });
      final channel = PhoneChannel();
      final status = await channel.status();
      final result = status.skills.saveResults.single;
      await _mount(tester, result);
      await tester.pumpAndSettle();
      expect(calls.map((c) => c.method), ['status']);
      expect(find.byType(TextField), findsNothing);
      expect(find.byType(CheckboxListTile), findsNothing);
      expect(find.widgetWithText(FilledButton, appL10n.commonSave), findsNothing);
      expect(find.text(publication == 'published' ? appL10n.phoneSkillBundlePublishedUnverified : appL10n.phoneSkillBundleUnknown), findsOneWidget);
      await tester.tap(find.text(appL10n.phoneSkillCheckWrite));
      await tester.pumpAndSettle();
      expect(calls.length, 2);
      expect(calls.last.method, 'skillDraft');
      expect(calls.last.arguments, result.handle.query);
      expect(find.text(appL10n.phoneSkillSavedBody), findsOneWidget);
      expect(find.text(appL10n.phoneSkillCheckWrite), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(calls.length, 2); // No editor open, save, or discard even on disposal.
    });
  }

  testWidgets('saved historical receipt is readonly and is not reread automatically', (tester) async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(_methods, (call) async { calls.add(call); return _reply(); });
    await _mount(tester, PhoneSkillSaveResult.parse(_record(kind: 'saved'))!);
    await tester.pumpAndSettle();
    expect(find.text(appL10n.phoneSkillSavedBody), findsOneWidget);
    expect(find.text(appL10n.phoneSkillCheckWrite), findsNothing);
    expect(find.byType(TextField), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(calls, isEmpty);
  });

  testWidgets('query in flight disables duplicate UI request and late reply cannot reopen closed editor', (tester) async {
    final response = Completer<Object?>();
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(_methods, (call) { calls.add(call); return response.future; });
    try {
      await _mount(tester, PhoneSkillSaveResult.parse(_record())!);
      await tester.pumpAndSettle();
      await tester.tap(find.text(appL10n.phoneSkillCheckWrite));
      await tester.pump();
      expect(tester.widget<TextButton>(find.widgetWithText(TextButton, appL10n.phoneSkillCheckWrite)).onPressed, isNull);
      expect(calls.length, 1);
      await tester.pumpWidget(const SizedBox());
      response.complete(_reply());
      await tester.pumpAndSettle();
      expect(find.text(appL10n.phoneSkillSavedBody), findsNothing);
      expect(calls.length, 1);
      expect(tester.takeException(), isNull);
    } finally {
      if (!response.isCompleted) response.complete(_reply());
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    }
  });

  testWidgets('definite bundle save refusal releases query identity before editing into a plain template', (tester) async {
    final calls = <MethodCall>[];
    var saves = 0;
    Map<String, Object?> view({required bool bundle}) => {
      'kind': 'shown', 'draft': {
        'draftId': _draft, 'taskId': 7, 'generation': 3, 'revision': bundle ? 1 : 2,
        'skillName': _name, 'markdown': '# Safe local template\n',
        'stepOrder': [0], 'parameterizedFields': ['goal'], 'phase': null,
        if (bundle) 'bundleRevision': _bundle,
      },
    };
    messenger.setMockMethodCallHandler(_methods, (call) async {
      calls.add(call);
      if (call.method == 'saveSkillDraft') {
        saves++;
        return saves == 1 ? {'kind': 'rejected', 'code': 'io'} : {'kind': 'saving', 'phase': 'staging'};
      }
      if (call.method == 'discardSkillDraft') { return {'kind': 'discarded'}; }
      final action = (call.arguments as Map)['action'];
      if (action == 'open') { return view(bundle: true); }
      if (action == 'edit') { return view(bundle: false); }
      if (action == 'view') { return {'kind': 'saved', 'name': _name, 'relativePath': 'skills/$_name/SKILL.md'}; }
      fail('Unexpected phase-one query action: $action');
    });
    try {
      await tester.pumpWidget(MaterialApp(home: PhoneSkillEditor(channel: PhoneChannel(),
        candidate: const PhoneSkillCandidate(taskId: 7, generation: 3, steps: 1))));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byType(CheckboxListTile));
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, appL10n.commonSave));
      await tester.pumpAndSettle();
      expect(saves, 1);
      expect(find.text(appL10n.phoneSkillWriteFailed), findsOneWidget);
      await tester.ensureVisible(find.byType(TextField).first);
      await tester.enterText(find.byType(TextField).first, 'Change this local template');
      await tester.pump();
      await tester.ensureVisible(find.text(appL10n.phoneSkillUpdatePreview));
      await tester.tap(find.text(appL10n.phoneSkillUpdatePreview));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byType(CheckboxListTile));
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, appL10n.commonSave));
      await tester.pumpAndSettle();
      expect(saves, 2);
      // The old phase-two handle used to reject this real phase-one saving reply.
      expect(find.text(appL10n.phoneSkillCheckWrite), findsOneWidget);
      expect(tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).onChanged, isNull);
      await tester.tap(find.text(appL10n.phoneSkillCheckWrite));
      await tester.pumpAndSettle();
      expect(calls.last.method, 'skillDraft');
      expect(calls.last.arguments, {'action': 'view', 'taskId': 7, 'draftId': _draft});
      expect(find.text(appL10n.phoneSkillSavedBody), findsOneWidget);
      expect(find.text(appL10n.phoneSkillStale), findsNothing);
      expect(calls.where((call) => call.method == 'saveSkillDraft').map((call) => call.arguments), [
        {'taskId': 7, 'draftId': _draft, 'revision': 1, 'confirmed': true},
        {'taskId': 7, 'draftId': _draft, 'revision': 2, 'confirmed': true},
      ]);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    }
  });

  for (final response in <Map<String, Object?>>[
    {..._reply(), 'bundleRevision': 'd' * 32},
    {..._reply(), 'name': 'phone-task-${'e' * 32}', 'relativePath': 'skills/phone-task-${'e' * 32}/SKILL.md'},
    {'kind': 'rejected', 'code': 'stale'},
    {'kind': 'rejected', 'code': 'io'},
  ]) {
    testWidgets('query cannot replace original published fact with $response', (tester) async {
      var queries = 0;
      messenger.setMockMethodCallHandler(_methods, (call) async { queries++; return response; });
      await _mount(tester, PhoneSkillSaveResult.parse(_record())!);
      await tester.pumpAndSettle();
      await tester.tap(find.text(appL10n.phoneSkillCheckWrite));
      await tester.pumpAndSettle();
      expect(find.text(appL10n.phoneSkillBundlePublishedUnverified), findsOneWidget);
      expect(find.text(appL10n.phoneSkillSavedBody), findsNothing);
      expect(find.text(appL10n.phoneSkillWriteFailed), findsNothing);
      expect(find.widgetWithText(FilledButton, appL10n.commonSave), findsNothing);
      expect(find.text('skills/$_name/SKILL.md'), findsOneWidget);
      expect(queries, 1);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(queries, 1);
    });
  }
}
