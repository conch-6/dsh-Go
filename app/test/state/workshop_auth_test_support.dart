import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/forum/discourse_client.dart';
import 'package:dsh_app/forum/forum_auth.dart';
import 'package:dsh_app/forum/forum_models.dart';
import 'package:dsh_app/forum/forum_state.dart';
import 'package:dsh_app/state/workshop_auth_state.dart';
import 'package:dsh_app/state/workshop_dependencies.dart';
import 'package:dsh_app/state/workshop_preferences.dart';
import 'package:dsh_app/workshop/workshop_client.dart';
import 'package:dsh_app/workshop/workshop_models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../workshop/support.dart' show FakeWorkshopHttp, workshopCaps;

final authWorker = Uri.parse('https://workshop.example');
final authForum = Uri.parse('https://forum.example');

Matcher authError(String code) => throwsA(isA<WorkshopException>().having((error) => error.code, 'code', code));

ForumAuthState authSignedIn({ForumCredentials? credentials, int? userId = 42}) => ForumAuthState(
  phase: ForumAuthPhase.signedIn,
  credentials: credentials ?? const ForumCredentials(key: 'TEST_ONLY_KEY_A', clientId: 'test-client'),
  user: userId == null ? null : ForumCurrentUser(id: userId, username: 'test-user'),
);

class AuthForumController extends ForumAuthController {
  AuthForumController(this.initial);
  final ForumAuthState initial;
  @override
  ForumAuthState build() => initial;
  void emit(ForumAuthState value) => state = value;
}

class AuthBaseController extends ForumBaseUrlController {
  AuthBaseController(this.initial);
  final String initial;
  @override
  String build() => initial;
  void select(Uri value) => state = value.toString();
}

class AuthPreferences implements WorkshopPreferences {
  final accepted = <String>{};
  int writes = 0;
  Future<bool> Function(Uri worker, Uri forum)? readDisclosure;
  Future<void> Function(Uri worker, Uri forum)? writeDisclosure;
  String pair(Uri worker, Uri forum) => jsonEncode([worker.toString(), forum.toString()]);

  @override
  Future<bool> disclosureAccepted(Uri worker, Uri forum) async =>
    readDisclosure == null ? accepted.contains(pair(worker, forum)) : await readDisclosure!(worker, forum);

  @override
  Future<void> acceptDisclosure(Uri worker, Uri forum) async {
    writes++;
    if (writeDisclosure != null) await writeDisclosure!(worker, forum);
    accepted.add(pair(worker, forum));
  }

  // Auth has no submission journal responsibility. These calls would be a
  // test failure instead of silently persisting credentials or creating work.
  @override
  Future<String> reserveSubmissionRequestId(String fingerprint, String proposed) async => throw StateError('Auth touched request ids');
  @override
  Future<void> retireSubmissionRequestId(String fingerprint, String expectedRequestId) async => throw StateError('Auth touched request ids');
  @override
  Future<WorkshopPendingSubmission?> pendingSubmission(String scope) async => throw StateError('Auth touched pending submissions');
  @override
  Future<void> savePendingSubmission(String scope, WorkshopPendingSubmission pending) async => throw StateError('Auth touched pending submissions');
  @override
  Future<void> clearPendingSubmission(String scope, String expectedRequestId) async => throw StateError('Auth touched pending submissions');
}

class AuthClient extends WorkshopClient {
  AuthClient({Uri? worker, Uri? forum}) : super(origin: worker ?? authWorker,
    cacheFile: File('unused-auth-state-cache.json'),
    http: FakeWorkshopHttp((method, url, headers, body) => throw StateError('Auth test attempted HTTP'))) {
    value = WorkshopCapabilities.fromJson(workshopCaps(forum: (forum ?? authForum).toString()));
  }
  late WorkshopCapabilities value;
  Future<WorkshopCapabilities> Function()? readCapabilities;
  int capabilityReads = 0;
  @override
  Future<WorkshopCapabilities> capabilities() async {
    capabilityReads++;
    return readCapabilities == null ? value : await readCapabilities!();
  }
}

final authClientChoiceProvider = NotifierProvider<AuthClientChoice, AuthClient>(AuthClientChoice.new);
class AuthClientChoice extends Notifier<AuthClient> {
  @override
  AuthClient build() => throw StateError('Auth client choice missing');
  void select(AuthClient value) => state = value;
}
class _InitialAuthClientChoice extends AuthClientChoice {
  _InitialAuthClientChoice(this.initial);
  final AuthClient initial;
  @override
  AuthClient build() => initial;
}

class AuthHarness {
  AuthHarness({AuthClient? client, AuthPreferences? preferences, ForumAuthState? initial,
    Future<WorkshopClient> Function(AuthClient)? loadClient})
    : client = client ?? AuthClient(), preferences = preferences ?? AuthPreferences(),
      forum = AuthForumController(initial ?? authSignedIn()), base = AuthBaseController(authForum.toString()) {
    container = ProviderContainer(overrides: [
      forumAuthProvider.overrideWith(() => forum),
      forumBaseUrlProvider.overrideWith(() => base),
      authClientChoiceProvider.overrideWith(() => _InitialAuthClientChoice(this.client)),
      workshopClientProvider.overrideWith((ref) async {
        final selected = ref.watch(authClientChoiceProvider);
        return loadClient == null ? selected : await loadClient(selected);
      }),
      workshopPreferencesProvider.overrideWithValue(this.preferences),
    ]);
  }
  final AuthClient client;
  final AuthPreferences preferences;
  final AuthForumController forum;
  final AuthBaseController base;
  late final ProviderContainer container;

  WorkshopAccessController get controller => container.read(workshopAccessProvider.notifier);
  WorkshopAccessState get state => container.read(workshopAccessProvider);
  void choose(AuthClient value) => container.read(authClientChoiceProvider.notifier).select(value);
  void dispose() => container.dispose();
}

Future<WorkshopAccessState> authReady(ProviderContainer container) {
  final done = Completer<WorkshopAccessState>();
  final subscription = container.listen(workshopAccessProvider, (previous, next) {
    if (!next.loading && !done.isCompleted) done.complete(next);
  }, fireImmediately: true, onError: (Object error, StackTrace stack) {
    if (!done.isCompleted) done.completeError(error, stack);
  });
  return done.future.whenComplete(subscription.close);
}

Future<void> authSettled<T>(Future<T> pending) => pending.then<void>((_) {}, onError: (Object error, StackTrace stack) {});

Future<void> authSignal<T>(Completer<void> signal, Future<T> pending) => Future.any([
  signal.future,
  pending.then<void>((_) {
    if (!signal.isCompleted) fail('Auth operation ended before the expected signal');
  }),
]);
