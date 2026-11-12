import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../forum/discourse_client.dart' show ForumCredentials;
import '../forum/forum_auth.dart';
import '../forum/forum_state.dart' show forumBaseUrlProvider;
import '../workshop/workshop_client.dart';
import '../workshop/workshop_models.dart';
import '../workshop/workshop_repository.dart' show workshopLocalError;
import 'workshop_dependencies.dart';
import 'workshop_preferences.dart';

/// Display both sources and return this exact object when confirming.
class WorkshopDisclosure {
  const WorkshopDisclosure._(this.worker, this.forum);
  final Uri worker, forum;
}

class WorkshopAccessState {
  const WorkshopAccessState({required this.session, this.loading = false,
    this.forumRestoring = false, this.signedIn = false, this.worker, this.forum, this.forumUserId,
    this.capabilities, this.disclosure, this.disclosureAccepted = false,
    this.disclosureSaved = false, this.savingDisclosure = false,
    this.error, this.preferenceError});

  /// In-memory account/deployment generation. It contains no credential.
  final Object session;
  final bool loading, forumRestoring, signedIn;
  final Uri? worker, forum;
  final int? forumUserId;
  final WorkshopCapabilities? capabilities;
  final WorkshopDisclosure? disclosure;
  final bool disclosureAccepted, disclosureSaved, savingDisclosure;
  final WorkshopException? error, preferenceError;

  bool get canAuthenticate => !loading && signedIn && error == null &&
      capabilities != null && disclosureAccepted;
  bool get uploadsEnabled => capabilities?.features.uploads ?? false;
  bool get companionEnabled => capabilities?.features.companion ?? false;
  bool canSubmit(String kind) => canAuthenticate && forumUserId != null && uploadsEnabled &&
      capabilities!.kinds.contains(kind) && (kind == 'pet' || kind == 'companion' && companionEnabled);

  WorkshopAccessState copyWith({bool? loading, bool? disclosureAccepted,
    bool? disclosureSaved, bool? savingDisclosure, WorkshopException? error,
    bool clearError = false, WorkshopException? preferenceError,
    bool clearPreferenceError = false}) => WorkshopAccessState(
    session: session, loading: loading ?? this.loading,
    forumRestoring: forumRestoring, signedIn: signedIn, worker: worker, forum: forum, forumUserId: forumUserId,
    capabilities: capabilities, disclosure: disclosure,
    disclosureAccepted: disclosureAccepted ?? this.disclosureAccepted,
    disclosureSaved: disclosureSaved ?? this.disclosureSaved,
    savingDisclosure: savingDisclosure ?? this.savingDisclosure,
    error: clearError ? null : error ?? this.error,
    preferenceError: clearPreferenceError ? null : preferenceError ?? this.preferenceError,
  );
}

/// One operation's captured context; never put this object in page state.
class WorkshopAuthorization {
  const WorkshopAuthorization({required this.session, required this.client,
    required this.credential, required this.requestScope, this.forumUserId});
  final Object session;
  final WorkshopClient client;
  final WorkshopCredential credential;
  /// Stable public account identity, available after the forum profile loads.
  /// A key rotation must not create a new idempotency scope.
  final String? requestScope;
  final int? forumUserId;
}

class _AccessContext {
  _AccessContext({required this.session, required this.client, required this.base, required this.credentials,
    required this.signedIn, required this.restoring, required this.preferences, required this.userId});
  final Object session;
  final Future<WorkshopClient> client;
  final String base;
  final ForumCredentials? credentials;
  final bool signedIn, restoring;
  final int? userId;
  final WorkshopPreferences preferences;
}

class WorkshopAccessController extends Notifier<WorkshopAccessState> {
  _AccessContext? _context;
  Future<void> _loaded = Future<void>.value();
  int _load = 0;
  int? _knownUserId;
  final _confirmedHere = <String>{};

  @override
  WorkshopAccessState build() {
    final base = ref.watch(forumBaseUrlProvider);
    final auth = ref.watch(forumAuthProvider.select((value) => (value.phase, value.credentials, value.user?.id)));
    final client = ref.watch(workshopClientProvider.future);
    final preferences = ref.watch(workshopPreferencesProvider);
    final profileId = auth.$3;
    final userId = profileId != null && profileId > 0 ? profileId : null;
    final previous = _context;
    final sameAccount = previous != null && previous.base == base &&
        identical(previous.credentials, auth.$2) && identical(previous.client, client) &&
        identical(previous.preferences, preferences) &&
        (_knownUserId == null || userId == null || _knownUserId == userId) &&
        previous.signedIn == (auth.$1 == ForumAuthPhase.signedIn && auth.$2 != null);
    _knownUserId = sameAccount ? userId ?? _knownUserId : userId;
    final context = _AccessContext(session: sameAccount ? previous.session : Object(),
      client: client, base: base, credentials: auth.$2,
      signedIn: auth.$1 == ForumAuthPhase.signedIn && auth.$2 != null,
      restoring: auth.$1 == ForumAuthPhase.restoring, preferences: preferences,
      userId: userId);
    _context = context;
    _loaded = _refresh(context, ++_load);
    return WorkshopAccessState(session: context.session, loading: true,
      forumRestoring: context.restoring, signedIn: context.signedIn, forumUserId: context.userId);
  }

  bool _current(_AccessContext context, [int? load]) {
    if (!ref.mounted) return false;
    final current = state;
    return identical(current.session, context.session) && identical(_context, context) &&
        (load == null || load == _load);
  }

  static String _pair(Uri worker, Uri forum) => jsonEncode([worker.toString(), forum.toString()]);

  Future<void> refresh() async {
    retryWorkshopDependencies(ref);
    final current = state;
    final context = _context!;
    state = current.copyWith(loading: true, clearError: true);
    _loaded = _refresh(context, ++_load);
    await _loaded;
  }

  Future<void> confirmDisclosure(WorkshopDisclosure offered) async {
    final current = state;
    final context = _context!;
    if (!identical(offered, current.disclosure) || current.loading || !current.signedIn) {
      state = state.copyWith(error: const WorkshopException('workshop_confirmation_stale'));
      return;
    }
    if (state.savingDisclosure) return;
    _confirmedHere.add(_pair(offered.worker, offered.forum));
    state = state.copyWith(disclosureAccepted: true, disclosureSaved: false,
      savingDisclosure: true, clearPreferenceError: true, clearError: true);
    try {
      await context.preferences.acceptDisclosure(offered.worker, offered.forum);
      if (_current(context) && identical(state.disclosure, offered)) {
        state = state.copyWith(disclosureSaved: true, savingDisclosure: false);
      }
    } on Object {
      if (_current(context) && identical(state.disclosure, offered)) {
        state = state.copyWith(savingDisclosure: false,
          preferenceError: const WorkshopException('workshop_preferences'));
      }
    }
  }

  /// Sign-in/sign-out remain in ForumAuthController. Capture this once and
  /// ignore its results after the account/deployment session is replaced.
  Future<WorkshopAuthorization> authorize() async {
    final session = state.session;
    final context = _context!;
    final load = _load;
    await _loaded;
    if (!identical(session, context.session) || !_current(context, load)) workshopInvalid('workshop_cancelled');
    final current = state;
    if (!context.signedIn || context.credentials == null) workshopInvalid('workshop_forum_auth_required');
    if (current.error case final error?) throw error;
    if (current.forum == null || current.capabilities == null) workshopInvalid('workshop_forum_origin');
    if (!current.disclosureAccepted) workshopInvalid('workshop_consent_required');
    final client = await context.client;
    if (!_current(context, load)) workshopInvalid('workshop_cancelled');
    final key = context.credentials!.key;
    final credential = WorkshopCredential.forConsentedWorker(worker: client.origin, forum: current.forum!,
      userApiKey: key, disclosureAccepted: true);
    final scope = context.userId == null ? null : jsonEncode([
      client.origin.toString(), current.forum.toString(), context.userId,
    ]);
    return WorkshopAuthorization(session: context.session, client: client,
      credential: credential, requestScope: scope, forumUserId: context.userId);
  }

  Future<void> _refresh(_AccessContext context, int load) async {
    try {
      final client = await context.client;
      if (!_current(context, load)) return;
      final capabilities = await client.capabilities();
      if (!_current(context, load)) return;
      final Uri forum;
      try {
        forum = workshopOrigin(Uri.parse(context.base));
      } on Object {
        throw const WorkshopException('workshop_forum_origin');
      }
      if (capabilities.forumOrigin != forum) workshopInvalid('workshop_forum_origin');
      var saved = false;
      WorkshopException? preferenceError;
      try {
        saved = await context.preferences.disclosureAccepted(client.origin, forum);
      } on Object {
        preferenceError = const WorkshopException('workshop_preferences');
      }
      if (!_current(context, load)) return;
      state = WorkshopAccessState(session: context.session, signedIn: context.signedIn,
        forumRestoring: context.restoring, worker: client.origin, forum: forum, forumUserId: context.userId,
        capabilities: capabilities,
        disclosure: context.signedIn ? WorkshopDisclosure._(client.origin, forum) : null,
        disclosureAccepted: saved || _confirmedHere.contains(_pair(client.origin, forum)),
        disclosureSaved: saved, preferenceError: preferenceError);
    } on Object catch (error) {
      if (_current(context, load)) {
        state = WorkshopAccessState(session: context.session, signedIn: context.signedIn,
          forumRestoring: context.restoring, forumUserId: context.userId, error: workshopLocalError(error));
      }
    }
  }
}

final workshopAccessProvider = NotifierProvider<WorkshopAccessController, WorkshopAccessState>(
  WorkshopAccessController.new,
);
