import 'dart:async';
import 'dart:typed_data';

import 'package:dsh_app/state/attachments.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/harness.dart';

/// A [DshClient] that records the calls [ChatController.send] and the queue
/// actions make, and plays back a scripted event stream.
class _FakeClient extends DshClient {
  _FakeClient() : super(DshConnection(Uri.parse('http://127.0.0.1:9')));

  final events = StreamController<DshEvent>.broadcast();
  final prompts = <({int images, List<String> receipts, String? requestId, PromptMode mode})>[];
  final uploads = <String?>[];
  final queue = <(String itemId, bool remove, bool steer)>[];
  var cancels = 0;

  /// Every call in order: `upload:<name>`, `prompt:<mode>:<text>`, `cancel`,
  /// `remove:<item>`, `steer:<item>`.
  final calls = <String>[];

  /// Refuse inline images like DSH does for a text-only model (V4 Pro).
  bool textOnlyModel = false;

  /// False like DSH Remote, which stages no files.
  bool uploadsAllowed = true;
  Object? promptError;
  Object? cancelError;
  Object? responseError;

  /// Holds the prompt's result until completed.
  Completer<String>? promptResult;

  @override
  bool supportsEndpoint(String endpoint) => endpoint != 'fileUploads/upload' || uploadsAllowed;

  @override
  Stream<DshEvent> watch(String sessionId, {WatchOptions options = const WatchOptions()}) => events.stream;

  @override
  Future<String> prompt(
    String sessionId,
    String text, {
    List<PromptImage> images = const [],
    List<String> fileReceiptIds = const [],
    String? requestId,
    PromptMode mode = PromptMode.queue,
    String? timeZone,
  }) async {
    calls.add('prompt:${mode.wire}:$text');
    prompts.add((images: images.length, receipts: [...fileReceiptIds], requestId: requestId, mode: mode));
    if (textOnlyModel && images.isNotEmpty) {
      throw const DshRemoteException(
        'session/attachment-invalid',
        'Model "deepseek-v4-pro" does not support image input.',
        {'reason': 'MODEL_DOES_NOT_SUPPORT_IMAGES'},
      );
    }
    if (promptError case final e?) throw e;
    if (promptResult case final result?) return result.future;
    return requestId ?? 'r';
  }

  @override
  Future<FileReceipt> uploadFile(String sessionId, List<int> bytes, {String? name}) async {
    calls.add('upload:$name');
    uploads.add(name);
    return FileReceipt('receipt-$name', FileAttachment(name: name, bytes: bytes.length));
  }

  @override
  Future<void> cancel(String sessionId) async {
    calls.add('cancel');
    cancels++;
    if (cancelError case final e?) throw e;
  }

  @override
  Future<void> respondApproval(ApprovalRequest request, ApprovalDecision decision) async {
    if (responseError case final e?) throw e;
  }

  @override
  Future<void> answerQuestion(UserQuestionRequest request, List<QuestionAnswer> answers) async {
    if (responseError case final e?) throw e;
  }

  @override
  Future<void> updateQueue(
    String sessionId,
    String itemId, {
    String? editText,
    bool remove = false,
    bool steer = false,
  }) async {
    calls.add('${remove ? 'remove' : 'steer'}:$itemId');
    queue.add((itemId, remove, steer));
    if (gone.contains(itemId)) {
      throw const DshRemoteException('session/queue-item-not-found', 'queued item is no longer pending');
    }
  }

  /// Inbox items the agent already took (`updateQueue` answers not-found).
  final gone = <String>{};
}

void main() {
  late _FakeClient client;
  late ProviderContainer container;

  ChatController chat() => container.read(chatProvider('s1').notifier);
  ChatState state() => container.read(chatProvider('s1'));
  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 60));

  setUp(() async {
    client = _FakeClient();
    container = ProviderContainer(
      overrides: [
        activeConnectionProvider.overrideWithValue(
          AsyncData<HostConnection?>(HostConnection(client: client, label: '本机', isLocal: true)),
        ),
      ],
    );
    // Keep the controller alive and listening for the whole test.
    container.listen(chatProvider('s1'), (_, _) {});
    // Real watch() always begins with a baseline. G54 now waits for it
    // before admitting sends; this fake must model the same contract.
    client.events.add(
      SessionSnapshotEvent.fromJson('s1', {
        'header': {'id': 's1'},
        'cursor': -1,
        'records': <Object?>[],
        'projections': {'asOfSeq': -1, 'values': <String, Object?>{}},
      }),
    );
    await container.pump();
    expect(state().controlReady, isTrue);
  });

  tearDown(() async {
    container.dispose();
    await client.events.close();
  });

  final image = DraftAttachment.sniff('cat.png', tinyPng);
  final file = DraftAttachment.sniff('notes.md', Uint8List.fromList('hi'.codeUnits));

  group('images and a text-only model', () {
    test('a refused image goes again as a file, same request, with a notice', () async {
      client.textOnlyModel = true;
      final ok = await chat().send('看看这张图', attachments: [file, image]);

      expect(ok, isTrue);
      expect(client.uploads, ['notes.md', 'cat.png']);
      expect(client.prompts, hasLength(2));
      expect(client.prompts[0].images, 1);
      expect(client.prompts[1].images, 0);
      expect(client.prompts[1].receipts, ['receipt-notes.md', 'receipt-cat.png']);
      expect(client.prompts[1].requestId, client.prompts[0].requestId);
      expect(state().notice, contains('已按文件发送'));
      expect(state().error, isNull);

      chat().dismissNotice();
      expect(state().notice, isNull);
    });

    test('a model that reads images gets them inline, no notice', () async {
      expect(await chat().send('看看', attachments: [image]), isTrue);
      expect(client.prompts.single.images, 1);
      expect(client.uploads, isEmpty);
      expect(state().notice, isNull);
    });

    test('other refusals still fail the send and drop the bubble', () async {
      client.promptError = const DshRemoteException('session/agent-busy', 'busy', {'reason': 'x'});
      expect(await chat().send('你好', attachments: [image]), isFalse);
      expect(client.prompts, hasLength(1));
      expect(state().error, '发送失败：AI 正忙，稍后再试');
      expect(state().pending, isEmpty);
    });
  });

  group('send modes', () {
    test('idle: a plain queue prompt, whatever was asked', () async {
      await chat().send('你好');
      expect(client.prompts.single.mode, PromptMode.queue);
      expect(client.cancels, 0);
    });

    test('running: "now" steers into the turn', () async {
      client.events.add(const SessionStatusEvent('s1', true));
      await settle();
      expect(state().running, isTrue);

      await chat().send('用 pnpm');
      expect(client.prompts.single.mode, PromptMode.steer);
      expect(state().pending.single.mode, SendMode.steer);
    });

    test('running: queue waits; interrupt stops first, then sends', () async {
      client.events.add(const SessionStatusEvent('s1', true));
      await settle();

      await chat().send('之后再说', mode: SendMode.queue);
      expect(client.calls, ['prompt:queue:之后再说']);

      // Only a prompt that arrives after the stop starts the next turn.
      client.calls.clear();
      await chat().send('停一下', mode: SendMode.interrupt, attachments: [file]);
      expect(client.calls, ['upload:notes.md', 'cancel', 'prompt:queue:停一下']);
      expect(state().stopping, isTrue);
      expect(state().error, isNull);
    });

    test('interrupt: a stop that fails sends it as an interjection', () async {
      client.events.add(const SessionStatusEvent('s1', true));
      await settle();
      client.cancelError = const DshCarrierLostException('gone');
      expect(await chat().send('停一下', mode: SendMode.interrupt), isTrue);
      expect(client.calls, ['cancel', 'prompt:steer:停一下']);
      final pending = state().pending.single;
      expect(pending.requestId, client.prompts.single.requestId);
      expect(pending.mode, SendMode.steer);
      expect(state().stopping, isFalse);
      expect(state().error, '没能停下本轮，已作为插话发送');
    });

    test('interrupt: stopped but not sent goes back to the caller', () async {
      client.events.add(const SessionStatusEvent('s1', true));
      await settle();
      client.promptError = const DshRemoteException('session/agent-busy', 'busy', {'reason': 'x'});
      expect(await chat().send('停一下', mode: SendMode.interrupt), isFalse);
      expect(client.calls, ['cancel', 'prompt:queue:停一下']);
      expect(state().pending, isEmpty);
      expect(state().error, '发送失败：AI 正忙，稍后再试');
    });
  });

  test('approval and answer failures never show an unknown reason', () async {
    client.responseError = const DshRemoteException('x', 'boom');
    await chat().respond(
      const ApprovalRequest(eventId: 'a', sessionId: 's1', toolName: 'bash'),
      ApprovalDecision.allowOnce,
    );
    expect(state().error, '审批提交失败');
    const question = UserQuestionRequest(eventId: 'q', sessionId: 's1', questions: []);
    expect(await chat().answer(question, const []), isFalse);
    expect(state().error, '回答提交失败');
  });

  group('stopping', () {
    test('shows at once, asks once, and ends with the turn', () async {
      client.events.add(const SessionStatusEvent('s1', true));
      await settle();
      final stop = chat().cancel();
      expect(state().stopping, isTrue);
      await chat().cancel();
      await stop;
      expect(client.cancels, 1);
      client.events.add(const SessionStatusEvent('s1', false));
      await settle();
      expect(state().running, isFalse);
      expect(state().stopping, isFalse);
    });

    test('a failed stop gives the key back with short copy', () async {
      client.events.add(const SessionStatusEvent('s1', true));
      await settle();
      client.cancelError = StateError('raw');
      await chat().cancel();
      expect(state().stopping, isFalse);
      expect(state().error, '没能停下，再试一次');
    });

    testWidgets('a turn still going after ten seconds gets the key back', (tester) async {
      // Its own client and container, on the tester's fake clock. The chat
      // controller watches the selected host, which reads saved preferences.
      SharedPreferences.setMockInitialValues({});
      final client = _FakeClient();
      final container = ProviderContainer(
        overrides: [
          activeConnectionProvider.overrideWithValue(
            AsyncData(HostConnection(client: client, label: '本机', isLocal: true)),
          ),
        ],
      );
      final sub = container.listen(chatProvider('s1'), (_, _) {});
      client.events.add(
        SessionSnapshotEvent.fromJson('s1', {
          'header': {'id': 's1'},
          'cursor': -1,
          'records': <Object?>[],
          'projections': {'asOfSeq': -1, 'values': <String, Object?>{}},
        }),
      );
      client.events.add(const SessionStatusEvent('s1', true));
      await tester.pump(const Duration(milliseconds: 40));
      unawaited(container.read(chatProvider('s1').notifier).cancel());
      await tester.pump();
      expect(sub.read().stopping, isTrue);
      await tester.pump(const Duration(seconds: 10));
      expect(sub.read().stopping, isFalse);
      expect(sub.read().error, isNull);
      sub.close();
      container.dispose();
      await client.events.close();
    });
  });

  test('DSH Remote: a text-only model asks for another model, no files', () async {
    client.uploadsAllowed = false;
    client.textOnlyModel = true;
    expect(await chat().send('图片', attachments: [image]), isFalse);
    expect(client.uploads, isEmpty);
    expect(client.prompts, hasLength(1));
    expect(state().pending, isEmpty);
    expect(state().error, '当前模型未声明支持图片。请换模型，或把自定义模型的输入类型设为「文本和图片」再发');
  });

  group('unknown outcome', () {
    test('sending the same content again reuses the request id', () async {
      client.promptError = const DshCarrierLostException('gone');
      expect(await chat().send('  你好  ', attachments: [image]), isFalse);
      expect(state().pending, isEmpty);
      final requestId = client.prompts.single.requestId;
      client.promptError = null;
      expect(await chat().send('你好', attachments: [image]), isTrue);
      expect(client.prompts.last.requestId, requestId);
      // Delivered: the next message is a new one.
      expect(await chat().send('你好', attachments: [image]), isTrue);
      expect(client.prompts.last.requestId, isNot(requestId));
    });

    test('changed content gets a new request id', () async {
      client.promptError = const DshTransportException('gone');
      expect(await chat().send('原文'), isFalse);
      final requestId = client.prompts.single.requestId;
      client.promptError = null;
      expect(await chat().send('新文字'), isTrue);
      expect(client.prompts.last.requestId, isNot(requestId));
    });

    test('an echo before the failure means it got there', () async {
      client.promptResult = Completer<String>();
      final result = chat().send('已送达');
      await settle();
      final requestId = client.prompts.single.requestId;
      client.events.add(
        SessionLogEvent.fromJson({
          'seq': 1,
          'time': 1792700000000,
          'type': 'user/message',
          'data': {
            'id': 'u1',
            'role': 'user',
            'content': [
              {'type': 'text', 'text': '已送达'},
            ],
            'source': {'kind': 'user', 'rpcId': requestId},
          },
        }),
      );
      await settle();
      expect(state().pending, isEmpty);
      client.promptResult!.completeError(const DshCarrierLostException('gone'));
      expect(await result, isTrue);
      expect(state().error, isNull);
    });
  });

  group('the inbox', () {
    Map<String, Object?> msg(String id, String text, String rpcId) => {
      'id': id,
      'role': 'user',
      'content': [
        {'type': 'text', 'text': text},
      ],
      'source': {'kind': 'user', 'rpcId': rpcId},
    };

    for (final terminal in ['live', 'resync', 'requeued']) {
      test('a claimed prompt settles without a user echo: $terminal', () async {
        var seq = 0;
        Map<String, Object?> event(String type, Map<String, Object?> data) => {
          'seq': ++seq,
          'time': 1792700000000 + seq,
          'type': type,
          'data': data,
        };
        void emit(String type, Map<String, Object?> data) =>
            client.events.add(SessionLogEvent.fromJson(event(type, data)));
        void splice({int removed = 0, List<Map<String, Object?>> inserted = const []}) => emit('agent/inbox/spliced', {
          'target': 'next-turn',
          'start': 0,
          'removedCount': removed,
          'inserted': inserted,
        });

        emit('turn/start', {'turn': 1});
        await settle();
        await chat().send('!pwd', mode: SendMode.queue);
        final claimed = client.prompts.last.requestId!;
        splice(inserted: [msg('claimed', '!pwd', claimed)]);
        splice(removed: 1);
        await settle();
        expect(state().pending.single.requestId, claimed, reason: 'Keep feedback while the hook is running.');

        // A replayed older ending cannot settle a later claim.
        client.events.add(
          SessionLogEvent.fromJson({
            'seq': 0,
            'time': 1792700000000,
            'type': 'turn/end',
            'data': {
              'turn': 0,
              'reason': {'kind': 'completed'},
            },
          }),
        );
        await settle();
        expect(state().pending.single.requestId, claimed);

        // Identical content is a distinct request. It may still be in flight
        // when the first prompt's plugin finishes without a user/message.
        await chat().send('!pwd', mode: SendMode.queue);
        final inFlight = client.prompts.last.requestId!;
        expect(inFlight, isNot(claimed));
        if (terminal == 'requeued') splice(inserted: [msg('returned', '!pwd', claimed)]);
        final ended = event('turn/end', {
          'turn': 1,
          'reason': {'kind': 'blocked'},
        });
        if (terminal == 'resync') {
          client.events.add(
            SessionSnapshotEvent.fromJson('s1', {
              'cursor': seq,
              'records': [
                {'type': 'event', 'event': ended},
              ],
            }, isResync: true),
          );
        } else {
          client.events.add(SessionLogEvent.fromJson(ended));
        }
        await settle();
        if (terminal == 'requeued') {
          expect(state().pending.map((p) => p.requestId), [claimed, inFlight]);
          emit('turn/start', {'turn': 2});
          splice(removed: 1);
          emit('turn/end', {
            'turn': 2,
            'reason': {'kind': 'completed'},
          });
          await settle();
        }
        expect(state().pending.map((p) => p.requestId), [inFlight]);
      });
    }

    for (final reason in ['error', 'aborted', 'interrupted']) {
      for (final terminal in ['live', 'resync', 'restored-before', 'restored-after']) {
        test('unadmitted $reason input stays recoverable: $terminal', () async {
          var seq = 0;
          Map<String, Object?> event(String type, Map<String, Object?> data) => {
            'seq': ++seq,
            'time': 1792700000000 + seq,
            'type': type,
            'data': data,
          };
          void emit(String type, Map<String, Object?> data) =>
              client.events.add(SessionLogEvent.fromJson(event(type, data)));
          void splice({int removed = 0, List<Map<String, Object?>> inserted = const []}) => emit(
            'agent/inbox/spliced',
            {'target': 'next-turn', 'start': 0, 'removedCount': removed, 'inserted': inserted},
          );

          expect(await chat().send('new input', attachments: [image, file]), isTrue);
          final requestId = client.prompts.single.requestId!;
          splice(inserted: [msg('original', 'new input', requestId)]);
          emit('turn/start', {'turn': 1});
          splice(removed: 1);
          if (terminal == 'restored-before') splice(inserted: [msg('original', 'new input', requestId)]);
          final end = event('turn/end', {
            'turn': 1,
            'reason': {'kind': reason},
          });
          if (terminal == 'resync') {
            client.events.add(
              SessionSnapshotEvent.fromJson('s1', {
                'cursor': seq,
                'records': [
                  {'type': 'event', 'event': end},
                ],
              }, isResync: true),
            );
          } else {
            client.events.add(SessionLogEvent.fromJson(end));
          }
          await settle();
          final pending = state().pending.single;
          expect(pending.requestId, requestId);
          expect(pending.text, 'new input');
          expect(pending.attachments, [image, file]);
          expect(pending.failed, terminal != 'restored-before');
          expect(state().running, isFalse);
          expect(client.prompts, hasLength(1), reason: 'Recovery never automatically resends.');
          if (terminal == 'restored-after') {
            splice(inserted: [msg('original', 'new input', requestId)]);
            await settle();
            expect(state().pending.single.failed, isFalse);
            expect(state().pending.single.inboxId, 'original');
            expect(state().pending.single.attachments, [image, file]);
          }
          if (terminal.startsWith('restored-')) {
            // Restored requests can later be consumed normally, without a
            // stale failed/claimed mark resurrecting the recovery card.
            emit('turn/start', {'turn': 2});
            splice(removed: 1);
            emit('turn/end', {
              'turn': 2,
              'reason': {'kind': 'blocked'},
            });
            await settle();
            expect(state().pending, isEmpty);
          }
        });
      }
    }

    for (final fate in ['claimed', 'canceled', 'echoed', 'restored']) {
      test('a snapshot reconstructs an entirely missed request outcome: $fate', () async {
        await chat().send('missed during disconnect', attachments: [image, file]);
        final requestId = client.prompts.single.requestId!;
        await chat().send('newer unclaimed input');
        final newerId = client.prompts.last.requestId!;
        var seq = 0;
        Map<String, Object?> record(String type, Map<String, Object?> data) => {
          'type': 'event',
          'event': {'seq': ++seq, 'time': 1792700000000 + seq, 'type': type, 'data': data},
        };
        final records = [
          // Replayed endings older than this request must not consume it.
          record('turn/end', {
            'turn': 0,
            'reason': {'kind': 'completed'},
          }),
          record('agent/inbox/spliced', {
            'target': 'next-turn',
            'start': 0,
            'removedCount': 0,
            'inserted': [msg('missed', 'missed during disconnect', requestId)],
          }),
          record('turn/start', {'turn': 1}),
          record('agent/inbox/spliced', {
            'target': 'next-turn',
            'start': 0,
            'removedCount': 1,
            'inserted': <Object?>[],
            if (fate == 'canceled') 'outcome': 'canceled',
          }),
          if (fate == 'echoed') record('user/message', msg('missed', 'missed during disconnect', requestId)),
          if (fate == 'restored')
            record('agent/inbox/spliced', {
              'target': 'next-turn',
              'start': 0,
              'removedCount': 0,
              'inserted': [msg('missed', 'missed during disconnect', requestId)],
            }),
          record('turn/end', {
            'turn': 1,
            'reason': {'kind': 'error'},
          }),
        ];
        client.events.add(SessionSnapshotEvent.fromJson('s1', {'cursor': seq, 'records': records}, isResync: true));
        await settle();
        final pending = state().pending;
        expect(pending.last.requestId, newerId);
        expect(pending.last.failed, isFalse, reason: 'An unrelated unclaimed request is not settled by turn/end.');
        if (fate == 'canceled' || fate == 'echoed') {
          expect(pending.map((p) => p.requestId), [newerId]);
        } else {
          expect(pending.first.requestId, requestId);
          expect(pending.first.failed, fate == 'claimed');
          expect(pending.first.attachments, [image, file]);
        }
        expect(client.prompts, hasLength(2), reason: 'Snapshot recovery does not trigger a retry.');
      });
    }

    Future<PendingPrompt> failedSubmission() async {
      await chat().send('original input', attachments: [image, file]);
      final requestId = client.prompts.single.requestId!;
      final records = [
        (
          'agent/inbox/spliced',
          <String, Object?>{
            'target': 'next-turn',
            'start': 0,
            'removedCount': 0,
            'inserted': [msg('original', 'original input', requestId)],
          },
        ),
        ('turn/start', <String, Object?>{'turn': 1}),
        (
          'agent/inbox/spliced',
          <String, Object?>{'target': 'next-turn', 'start': 0, 'removedCount': 1, 'inserted': <Object?>[]},
        ),
        (
          'turn/end',
          <String, Object?>{
            'turn': 1,
            'reason': {'kind': 'error'},
          },
        ),
      ];
      for (var i = 0; i < records.length; i++) {
        client.events.add(
          SessionLogEvent.fromJson({
            'seq': i + 1,
            'time': 1792700000000 + i,
            'type': records[i].$1,
            'data': records[i].$2,
          }),
        );
      }
      await settle();
      return state().pending.single;
    }

    test('editing a failed submission preserves attachments and uses a new identity', () async {
      final failed = await failedSubmission();
      expect(await chat().retryFailed(failed, 'edited input'), isTrue);
      expect(client.calls.last, 'prompt:queue:edited input');
      expect(client.prompts.last.requestId, isNot(failed.requestId));
      expect(client.prompts.last.images, 1);
      expect(client.prompts.last.receipts, ['receipt-notes.md']);
      expect(state().pending.single.text, 'edited input');
      expect(state().pending.single.attachments, [image, file]);
      expect(state().pending.single.failed, isFalse);
    });

    test('a failed manual resend keeps the edited text and attachments', () async {
      final failed = await failedSubmission();
      client.promptError = const DshCarrierLostException('offline');
      expect(await chat().retryFailed(failed, 'edited input'), isFalse);
      expect(state().pending.single.requestId, failed.requestId);
      expect(state().pending.single.text, 'edited input');
      expect(state().pending.single.attachments, [image, file]);
      expect(state().pending.single.failed, isTrue);
      final unsettled = client.prompts.last.requestId;
      client.promptError = null;
      expect(await chat().retryFailed(state().pending.single, 'edited input'), isTrue);
      expect(client.prompts.last.requestId, unsettled, reason: 'Unknown network outcomes retain normal dedup.');
    });

    test('a restored queue item retires an open failed editor without a duplicate send', () async {
      final failed = await failedSubmission();
      client.events.add(
        SessionLogEvent.fromJson({
          'seq': 5,
          'time': 1792700000005,
          'type': 'agent/inbox/spliced',
          'data': {
            'target': 'next-turn',
            'start': 0,
            'removedCount': 0,
            'inserted': [msg('original', 'original input', failed.requestId)],
          },
        }),
      );
      await settle();
      expect(await chat().retryFailed(failed, 'edited input'), isFalse);
      expect(client.prompts, hasLength(1));
      expect(state().pending.single.failed, isFalse);
      expect(state().pending.single.attachments, [image, file]);
    });

    test('a late echo retires an open failed editor without replaying an older prompt', () async {
      final failed = await failedSubmission();
      client.events.add(
        SessionLogEvent.fromJson({
          'seq': 5,
          'time': 1792700000005,
          'type': 'user/message',
          'data': msg('original', 'original input', failed.requestId),
        }),
      );
      await settle();
      expect(await chat().retryFailed(failed, 'edited input'), isFalse);
      expect(client.prompts, hasLength(1));
      expect(state().pending, isEmpty);
    });

    test('an explicitly cancelled queue item is not a failed claim', () async {
      await chat().send('cancel this', mode: SendMode.queue);
      final requestId = client.prompts.single.requestId!;
      client.events.add(
        SessionLogEvent.fromJson({
          'seq': 1,
          'time': 1792700000001,
          'type': 'agent/inbox/spliced',
          'data': {
            'target': 'next-turn',
            'start': 0,
            'removedCount': 0,
            'inserted': [msg('cancelled', 'cancel this', requestId)],
          },
        }),
      );
      client.events.add(
        SessionLogEvent.fromJson({
          'seq': 2,
          'time': 1792700000002,
          'type': 'agent/inbox/spliced',
          'data': {
            'target': 'next-turn',
            'start': 0,
            'removedCount': 1,
            'inserted': <Object?>[],
            'outcome': 'canceled',
          },
        }),
      );
      client.events.add(
        SessionLogEvent.fromJson({
          'seq': 3,
          'time': 1792700000003,
          'type': 'turn/end',
          'data': {
            'turn': 1,
            'reason': {'kind': 'aborted'},
          },
        }),
      );
      await settle();
      expect(state().pending, isEmpty);
    });

    test('pending prompts take their slot; prompts from elsewhere show too', () async {
      client.events.add(const SessionStatusEvent('s1', true));
      await settle();
      await chat().send('之后再说', mode: SendMode.queue);
      final mine = client.prompts.single.requestId!;

      client.events.add(
        SessionLogEvent.fromJson({
          'seq': 1,
          'time': 1792700000000,
          'type': 'agent/inbox/spliced',
          'data': {
            'target': 'next-turn',
            'start': 0,
            'removedCount': 0,
            'inserted': [msg('q1', '之后再说', mine), msg('q2', '电脑上发的', 'other-device')],
          },
        }),
      );
      await settle();

      final pending = state().pending;
      expect(
        [for (final p in pending) (p.text, p.inboxId, p.slot)],
        [('之后再说', 'q1', InboxSlot.nextTurn), ('电脑上发的', 'q2', InboxSlot.nextTurn)],
      );

      expect(await chat().steerQueued(pending.first), isTrue);
      expect(await chat().withdrawQueued(pending.last), isTrue);
      expect(client.queue, [('q1', false, true), ('q2', true, false)]);
    });

    // Withdrawn elsewhere (canceled), turned into a steer (canceled, then
    // re-added to next-step) or claimed by the agent (no outcome).
    for (final outcome in ['canceled', 'steered', 'claimed']) {
      test('an inbox $outcome keeps the bubble only while it is due', () async {
        client.events.add(const SessionStatusEvent('s1', true));
        await settle();
        await chat().send('图片', attachments: [image], mode: SendMode.queue);
        final id = client.prompts.single.requestId!;
        var seq = 0;
        void splice(
          String target, {
          int removed = 0,
          List<Map<String, Object?>> inserted = const [],
          bool canceled = false,
        }) => client.events.add(
          SessionLogEvent.fromJson({
            'seq': ++seq,
            'time': 1792700000000 + seq,
            'type': 'agent/inbox/spliced',
            'data': {
              'target': target,
              'start': 0,
              'removedCount': removed,
              'inserted': inserted,
              if (canceled) 'outcome': 'canceled',
            },
          }),
        );
        splice('next-turn', inserted: [msg('q1', '图片', id)]);
        await settle();
        splice('next-turn', removed: 1, canceled: outcome != 'claimed');
        if (outcome == 'steered') {
          splice('next-step', inserted: [msg('q1', '图片', id)]);
        }
        await settle();
        if (outcome == 'canceled') {
          expect(state().pending, isEmpty);
          return;
        }
        expect(state().pending.single.attachments, [image]);
        if (outcome == 'steered') {
          expect(state().pending.single.slot, InboxSlot.nextStep);
          splice('next-step', removed: 1);
        }
        client.events.add(
          SessionLogEvent.fromJson({
            'seq': ++seq,
            'time': 1792700000000 + seq,
            'type': 'user/message',
            'data': msg('u', '图片', id),
          }),
        );
        await settle();
        expect(state().pending, isEmpty);
      });
    }

    test('nothing to act on before the Host reports the item', () async {
      await chat().send('你好');
      final p = state().pending.single;
      expect(p.inboxId, isNull);
      expect(await chat().steerQueued(p), isFalse);
      expect(await chat().withdrawQueued(p), isFalse);
      expect(client.queue, isEmpty);
    });
  });

  // DSH keeps the inbox across a stop but starts no turn for it: what waits
  // goes again under its own request id, which wakes the agent.
  group('sending what waits right away', () {
    var seq = 0;
    Map<String, Object?> msg(String id, String text, String rpcId, {bool file = false}) => {
      'id': id,
      'role': 'user',
      'content': [
        {'type': 'text', 'text': text},
        if (file)
          {
            'type': 'file',
            'attachment': {'name': 'a.pdf'},
          },
      ],
      'source': {'kind': 'user', 'rpcId': rpcId},
    };
    void log(String type, Map<String, Object?> data) => client.events.add(
      SessionLogEvent.fromJson({'seq': ++seq, 'time': 1792700000000 + seq, 'type': type, 'data': data}),
    );
    void splice(
      String target, {
      int start = 0,
      int removed = 0,
      List<Map<String, Object?>> inserted = const [],
      bool canceled = false,
    }) => log('agent/inbox/spliced', {
      'target': target,
      'start': start,
      'removedCount': removed,
      'inserted': inserted,
      if (canceled) 'outcome': 'canceled',
    });
    PendingPrompt bubble(String text) => state().pending.firstWhere((p) => p.text == text);

    setUp(() => seq = 0);

    /// A running turn with [steps] (interjections) and [turns] (queued)
    /// sent from here and placed in the inbox as `i-<text>`; their request
    /// ids in that order.
    Future<List<String>> waiting(List<String> steps, [List<String> turns = const []]) async {
      client.events.add(const SessionStatusEvent('s1', true));
      await settle();
      final ids = <String, String>{};
      for (final text in [...steps, ...turns]) {
        await chat().send(text, mode: steps.contains(text) ? SendMode.now : SendMode.queue);
        ids[text] = client.prompts.last.requestId!;
      }
      splice('next-step', inserted: [for (final t in steps) msg('i-$t', t, ids[t]!)]);
      splice('next-turn', inserted: [for (final t in turns) msg('i-$t', t, ids[t]!)]);
      await settle();
      client.calls.clear();
      return ids.values.toList();
    }

    test('立即发送: out, stop, back under the same request id', () async {
      final ids = await waiting(['用中文']);
      expect(bubble('用中文').slot, InboxSlot.nextStep);
      expect(await chat().sendNow(bubble('用中文')), isEmpty);
      expect(client.calls, ['remove:i-用中文', 'cancel', 'prompt:steer:用中文']);
      expect(client.prompts.last.requestId, ids.single);
      expect(state().stopping, isTrue);
    });

    test('立即发送: the bubble stays put while it is out', () async {
      final ids = await waiting(['用中文']);
      client.promptResult = Completer<String>();
      final sending = chat().sendNow(bubble('用中文'));
      await settle();
      // The removal comes back as a canceled splice, like a withdrawal.
      splice('next-step', removed: 1, canceled: true);
      await settle();
      final out = state().pending.single;
      expect(out.requestId, ids.single);
      expect(out.inboxId, isNull);
      expect(out.mode, SendMode.now);
      // Back before the inbox says so: still there.
      client.promptResult!.complete(ids.single);
      expect(await sending, isEmpty);
      await settle();
      expect(state().pending.single.requestId, ids.single);
      splice('next-step', inserted: [msg('i2', '用中文', ids.single)]);
      await settle();
      expect(state().pending.single.inboxId, 'i2');
      expect(state().pending.single.slot, InboxSlot.nextStep);
    });

    test('立即发送: already read by the agent, nothing is stopped', () async {
      await waiting(['用中文']);
      client.gone.add('i-用中文');
      expect(await chat().sendNow(bubble('用中文')), isEmpty);
      expect(client.calls, ['remove:i-用中文']);
      expect(state().stopping, isFalse);
      expect(state().error, isNull);
      expect(state().pending.single.inboxId, 'i-用中文');
    });

    test('立即发送: files go up again, images inline', () async {
      client.events.add(const SessionStatusEvent('s1', true));
      await settle();
      await chat().send('看看这个', attachments: [file, image]);
      final id = client.prompts.single.requestId!;
      splice('next-step', inserted: [msg('i1', '看看这个', id)]);
      await settle();
      client.calls.clear();
      expect(await chat().sendNow(bubble('看看这个')), isEmpty);
      // Taking it out retired the receipt of the first upload.
      expect(client.calls, ['remove:i1', 'cancel', 'upload:notes.md', 'prompt:steer:看看这个']);
      expect(client.prompts.last.receipts, ['receipt-notes.md']);
      expect(client.prompts.last.images, 1);
      expect(client.prompts.last.requestId, id);
    });

    test('立即发送: the queue behind it goes back after it', () async {
      await waiting(['插话'], ['先排的', '后排的']);
      expect(await chat().sendNow(bubble('先排的')), isEmpty);
      expect(client.calls, ['remove:i-先排的', 'cancel', 'remove:i-后排的', 'prompt:queue:先排的', 'prompt:queue:后排的']);
    });

    test('立即发送 on an interjection: the whole queue goes after it', () async {
      await waiting(['插话一', '插话二'], ['排队']);
      expect(await chat().sendNow(bubble('插话一')), isEmpty);
      expect(client.calls, ['remove:i-插话一', 'cancel', 'remove:i-排队', 'prompt:steer:插话一', 'prompt:queue:排队']);
    });

    test('立即发送: a stop that fails still puts it back', () async {
      await waiting(['用中文']);
      client.cancelError = StateError('raw');
      expect(await chat().sendNow(bubble('用中文')), isEmpty);
      expect(client.calls, ['remove:i-用中文', 'cancel', 'prompt:steer:用中文']);
      expect(state().stopping, isFalse);
      expect(state().error, '没能停下，再试一次');
    });

    test('立即发送: not back in goes to the caller, bubble gone', () async {
      await waiting(['用中文']);
      client.promptError = const DshRemoteException('session/agent-busy', 'busy', {'reason': 'x'});
      final prompt = bubble('用中文');
      // What DSH reports for the removal.
      splice('next-step', removed: 1, canceled: true);
      final lost = await chat().sendNow(prompt);
      expect([for (final p in lost) p.text], ['用中文']);
      await settle();
      expect(state().pending, isEmpty);
      expect(state().error, '发送失败：AI 正忙，稍后再试');
    });

    test('立即发送: an unknown outcome keeps the request id for a retry', () async {
      final ids = await waiting(['用中文']);
      client.promptError = const DshCarrierLostException('gone');
      expect(await chat().sendNow(bubble('用中文')), hasLength(1));
      client.promptError = null;
      await chat().send('用中文');
      expect(client.prompts.last.requestId, ids.single);
    });

    test('plain text from elsewhere can go now; attachments cannot', () async {
      client.events.add(const SessionStatusEvent('s1', true));
      await settle();
      splice('next-turn', inserted: [msg('i1', '电脑上发的', 'other'), msg('i2', '带附件的', 'other-file', file: true)]);
      await settle();
      expect(bubble('电脑上发的').resendable, isTrue);
      expect(bubble('带附件的').resendable, isFalse);
      expect(await chat().sendNow(bubble('带附件的')), isEmpty);
      expect(client.calls, isEmpty);

      client.promptResult = Completer<String>();
      final sending = chat().sendNow(bubble('电脑上发的'));
      await settle();
      splice('next-turn', removed: 1, canceled: true);
      await settle();
      // Ours while it is out: the bubble stays.
      expect(bubble('电脑上发的').requestId, 'other');
      client.promptResult!.complete('other');
      await sending;
      expect(client.calls, ['remove:i1', 'cancel', 'prompt:queue:电脑上发的']);
      expect(client.prompts.last.requestId, 'other');
    });

    test('发送 with no turn running wakes it without a stop', () async {
      splice('next-turn', inserted: [msg('i1', '卡住的', 'r-old')]);
      await settle();
      expect(state().running, isFalse);
      expect(await chat().sendNow(bubble('卡住的')), isEmpty);
      expect(client.calls, ['remove:i1', 'prompt:queue:卡住的']);
    });

    test('stop: the last waiting prompt goes out and back, order kept', () async {
      final ids = await waiting(['插话一', '插话二'], ['排队一', '排队二']);
      expect(await chat().cancel(), isEmpty);
      expect(client.calls, ['cancel', 'remove:i-排队二', 'prompt:queue:排队二']);
      expect(client.prompts.last.requestId, ids.last);
    });

    test('stop: interjections only, the last one goes back as one', () async {
      await waiting(['插话一', '插话二']);
      await chat().cancel();
      expect(client.calls, ['cancel', 'remove:i-插话二', 'prompt:steer:插话二']);
    });

    test('stop: an empty inbox, or a failed stop, just stops', () async {
      client.events.add(const SessionStatusEvent('s1', true));
      await settle();
      await chat().cancel();
      expect(client.calls, ['cancel']);

      client.events.add(const SessionStatusEvent('s1', false));
      await settle();
      await waiting(['插话']);
      client.cancelError = StateError('raw');
      await chat().cancel();
      expect(client.calls, ['cancel']);
      expect(state().error, '没能停下，再试一次');
    });

    test('stop: a last prompt that cannot go again stays put', () async {
      client.events.add(const SessionStatusEvent('s1', true));
      await settle();
      splice('next-turn', inserted: [msg('i1', '带附件的', 'other', file: true)]);
      await settle();
      await chat().cancel();
      expect(client.calls, ['cancel']);
    });

    test('stopping ends with the turn, even when the next starts at once', () async {
      client.events.add(const SessionStatusEvent('s1', true));
      await settle();
      await chat().cancel();
      expect(state().stopping, isTrue);
      log('turn/end', {
        'turn': 1,
        'reason': {
          'kind': 'aborted',
          'reason': {'kind': 'user'},
        },
      });
      log('turn/start', {'turn': 2});
      await settle();
      expect(state().running, isTrue);
      expect(state().stopping, isFalse);
    });
  });
}
