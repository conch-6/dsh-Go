import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../workshop/workshop_client.dart';
import '../workshop/workshop_models.dart';
import '../workshop/workshop_repository.dart' show workshopLocalError;
import 'workshop_auth_state.dart';
import 'workshop_preferences.dart';
import 'workshop_publication.dart';
import 'workshop_publish_sources.dart';

enum WorkshopPublishPhase { idle, checking, preparing, ready, creating, uploading, awaitingResponse, complete, failed }

/// Page state deliberately excludes credentials, authorization objects, files,
/// private directory names, and absolute paths. A completed upload is not a
/// completed submission until the server response has been checked.
class WorkshopPublishState {
  WorkshopPublishState({required this.session, this.source, WorkshopPublicationInput? input,
    this.phase = WorkshopPublishPhase.idle, this.busy = false,
    this.waitingForPreviousOperation = false, this.pendingChecked = false,
    this.hasPending = false, this.preparedMetadata, List<String> files = const [],
    Map<String, String> fieldErrors = const {}, this.sent = 0, this.total = 0,
    this.result, this.error, this.preferenceError, this.cleanupError})
    : input = input ?? WorkshopPublicationInput(), files = List.unmodifiable(files),
      fieldErrors = Map.unmodifiable(fieldErrors);

  final Object session;
  final WorkshopPublishSource? source;
  final WorkshopPublicationInput input;
  final WorkshopPublishPhase phase;
  final bool busy, waitingForPreviousOperation, pendingChecked, hasPending;
  final WorkshopMetadata? preparedMetadata;
  final List<String> files;
  final Map<String, String> fieldErrors;
  final int sent, total;
  final WorkshopSubmission? result;
  final WorkshopException? error, preferenceError, cleanupError;
  bool get working => busy || waitingForPreviousOperation;
  bool get canEditMetadata => pendingChecked && !working && !hasPending;
  bool get canStartNewSubmission => !working && !hasPending &&
      (result?.status == WorkshopSubmissionStatus.rejected || result?.status == WorkshopSubmissionStatus.withdrawn);

  WorkshopPublishState copyWith({WorkshopPublishSource? source, bool clearSource = false,
    WorkshopPublicationInput? input, WorkshopPublishPhase? phase, bool? busy,
    bool? waitingForPreviousOperation, bool? pendingChecked, bool? hasPending,
    WorkshopMetadata? preparedMetadata, bool clearPrepared = false,
    List<String>? files, Map<String, String>? fieldErrors, int? sent, int? total,
    WorkshopSubmission? result, bool clearResult = false, WorkshopException? error,
    bool clearError = false, WorkshopException? preferenceError, bool clearPreferenceError = false,
    WorkshopException? cleanupError, bool clearCleanupError = false}) => WorkshopPublishState(
      session: session, source: clearSource ? null : source ?? this.source,
      input: input ?? this.input, phase: phase ?? this.phase, busy: busy ?? this.busy,
      waitingForPreviousOperation: waitingForPreviousOperation ?? this.waitingForPreviousOperation,
      pendingChecked: pendingChecked ?? this.pendingChecked, hasPending: hasPending ?? this.hasPending,
      preparedMetadata: clearPrepared ? null : preparedMetadata ?? this.preparedMetadata,
      files: clearPrepared ? const [] : files ?? this.files, fieldErrors: fieldErrors ?? this.fieldErrors,
      sent: sent ?? this.sent, total: total ?? this.total,
      result: clearResult ? null : result ?? this.result,
      error: clearError ? null : error ?? this.error,
      preferenceError: clearPreferenceError ? null : preferenceError ?? this.preferenceError,
      cleanupError: clearCleanupError ? null : cleanupError ?? this.cleanupError,
    );
}

final workshopRequestIdProvider = Provider<String Function()>((ref) => WorkshopClient.newRequestId);

class _DraftLease {
  _DraftLease(this.draft);
  final WorkshopPreparedDraft draft;
  int borrowers = 0;
  bool retired = false;
  Future<WorkshopException?>? _cleaning;

  Future<WorkshopException?> clean() {
    if (!retired || borrowers != 0 || draft.retained) return Future<WorkshopException?>.value();
    return _cleaning ??= Future<WorkshopException?>.microtask(() async {
      try {
        await draft.dispose();
        return null;
      } on Object {
        return const WorkshopException('workshop_draft_cleanup');
      } finally {
        _cleaning = null;
      }
    });
  }
}

class _PublishIntent {
  _PublishIntent({required this.scope, required this.pending, required this.lease, this.saved = false});
  final String scope;
  final WorkshopPendingSubmission pending;
  final _DraftLease lease;
  bool saved, cleared = false;
  String? submissionId;
  WorkshopSubmission? result;
}

class _PublishContext {
  _PublishContext(this.session);
  final Object session;
  String? scope;
  bool checked = false, closed = false;
  _DraftLease? prepared;
  _PublishIntent? intent;
  final retired = <_DraftLease>{};
}

Object? _canonical(Object? value) {
  if (value is Map<String, Object?>) {
    final keys = value.keys.toList()..sort();
    return {for (final key in keys) key: _canonical(value[key])};
  }
  if (value is List) return value.map(_canonical).toList();
  return value;
}

String _digest(Object? value) => sha256.convert(utf8.encode(jsonEncode(_canonical(value)))).toString();
bool _sameMetadata(WorkshopMetadata left, WorkshopMetadata right) =>
    jsonEncode(_canonical(left.toJson())) == jsonEncode(_canonical(right.toJson()));
String _fingerprint(String scope, WorkshopMetadata metadata) => _digest([scope, metadata.toJson()]);

/// One publisher per container. The operation gate survives account rebuilds:
/// a replacement session cannot restore/borrow an old operation's draft until
/// that operation has settled. It does not claim cross-process coordination.
class WorkshopPublishController extends Notifier<WorkshopPublishState> {
  _PublishContext? _context;
  Object? _operation;

  @override
  WorkshopPublishState build() {
    final session = ref.watch(workshopAccessProvider.select((value) => value.session));
    final context = _PublishContext(session);
    _context = context;
    ref.onDispose(() {
      context.closed = true;
      final prepared = context.prepared;
      if (prepared != null) _retire(context, prepared);
      for (final lease in context.retired.toList()) {
        unawaited(lease.clean());
      }
    });
    return WorkshopPublishState(session: session, waitingForPreviousOperation: _operation != null);
  }

  bool _current(_PublishContext context) {
    if (!ref.mounted || context.closed) return false;
    final current = state; // Flush Riverpod's possibly pending session rebuild.
    return identical(_context, context) && identical(current.session, context.session);
  }

  void _requireCurrent(_PublishContext context) {
    if (!_current(context)) workshopInvalid('workshop_cancelled');
  }

  Object? _begin(_PublishContext context, WorkshopPublishPhase phase) {
    if (!_current(context)) return null;
    if (_operation != null) {
      state = state.copyWith(error: const WorkshopException('workshop_busy'));
      return null;
    }
    final token = Object();
    _operation = token;
    state = state.copyWith(busy: true, waitingForPreviousOperation: false, phase: phase,
      clearError: true);
    return token;
  }

  void _end(Object token) {
    if (!identical(_operation, token)) return;
    _operation = null;
    if (!ref.mounted) return;
    // Even an old session may release the gate, but none of its form/result
    // fields are copied into the replacement session.
    state = state.copyWith(busy: false, waitingForPreviousOperation: false);
  }

  bool _editorReady(_PublishContext context, {bool requireProfile = true}) {
    if (!_current(context)) return false;
    final access = ref.read(workshopAccessProvider);
    final code = state.working ? 'workshop_busy'
        : requireProfile && access.forumUserId == null ? 'workshop_profile_required'
        : !context.checked ? 'workshop_pending_check_required' : null;
    if (code == null) return true;
    state = state.copyWith(error: WorkshopException(code));
    return false;
  }

  Future<WorkshopAuthorization> _authorize(_PublishContext context) async {
    final authorization = await ref.read(workshopAccessProvider.notifier).authorize();
    _requireCurrent(context);
    if (!identical(authorization.session, context.session)) workshopInvalid('workshop_cancelled');
    if (authorization.requestScope == null || authorization.forumUserId == null) {
      workshopInvalid('workshop_profile_required');
    }
    final scope = _digest([authorization.client.origin.toString(),
      authorization.credential.forum.toString(), authorization.forumUserId]);
    if (context.scope != null && context.scope != scope) workshopInvalid('workshop_cancelled');
    context.scope = scope;
    return authorization;
  }

  void _retire(_PublishContext context, _DraftLease lease) {
    lease.retired = true;
    context.retired.add(lease);
    unawaited(_clean(context, lease));
  }

  Future<bool> _clean(_PublishContext context, _DraftLease lease) async {
    // A skipped cleanup is not evidence that disposal succeeded. In
    // particular, do not remove the retry entry merely because a borrower
    // happened to finish while this async caller was yielding.
    if (!lease.retired || lease.borrowers != 0 || lease.draft.retained) return true;
    final error = await lease.clean();
    if (lease.borrowers != 0 || lease.draft.retained) return true;
    if (error == null) context.retired.remove(lease);
    if (_current(context) && error != null) state = state.copyWith(cleanupError: error);
    return error == null;
  }

  Future<bool> _cleanRetired(_PublishContext context) async {
    var cleaned = true;
    for (final lease in context.retired.toList()) {
      if (!await _clean(context, lease)) cleaned = false;
    }
    if (cleaned && _current(context)) state = state.copyWith(clearCleanupError: true);
    return cleaned;
  }

  /// Read-only, explicit initialization/recovery. No create or upload is sent.
  /// A successful check is reused for subsequent synchronous form edits.
  Future<void> restorePending() async {
    final current = state;
    final context = _context!;
    if (context.checked && !current.working) return;
    final token = _begin(context, WorkshopPublishPhase.checking);
    if (token == null) return;
    try {
      await _authorize(context);
      final preferences = ref.read(workshopPreferencesProvider);
      final restore = ref.read(workshopRestoreDraftProvider);
      final pending = await preferences.pendingSubmission(context.scope!);
      _requireCurrent(context);
      if (pending != null) {
        if (_fingerprint(context.scope!, pending.metadata) != pending.fingerprint) {
          workshopInvalid('workshop_preferences');
        }
        final draft = await restore(pending);
        draft.retained = true;
        final lease = _DraftLease(draft);
        if (!_current(context)) {
          _retire(context, lease);
          return;
        }
        context.prepared = lease;
        context.intent = _PublishIntent(scope: context.scope!, pending: pending, lease: lease, saved: true);
        state = state.copyWith(input: WorkshopPublicationInput.fromMetadata(pending.metadata),
          preparedMetadata: pending.metadata, files: pending.files, hasPending: true,
          phase: WorkshopPublishPhase.ready, fieldErrors: const {});
      } else {
        state = state.copyWith(phase: WorkshopPublishPhase.idle);
      }
      context.checked = true;
      state = state.copyWith(pendingChecked: true, clearError: true, clearPreferenceError: true);
    } on Object catch (error) {
      if (_current(context)) {
        final mapped = workshopLocalError(error);
        state = state.copyWith(phase: WorkshopPublishPhase.failed,
          error: mapped, preferenceError: mapped.code == 'workshop_preferences' ? mapped : null);
      }
    } finally {
      _end(token);
    }
  }

  bool selectSource(WorkshopPublishSource source) {
    final current = state;
    final context = _context!;
    if (!_editorReady(context)) return false;
    if (current.hasPending) {
      state = state.copyWith(error: const WorkshopException('workshop_pending_submission'));
      return false;
    }
    if ((source.kind != 'pet' && source.kind != 'companion') || source.localId.isEmpty) {
      state = state.copyWith(error: const WorkshopException('workshop_unsupported_kind'));
      return false;
    }
    final old = context.prepared;
    context.prepared = null;
    context.intent = null;
    if (old != null) _retire(context, old);
    state = state.copyWith(source: source, input: source.initialInput(), clearPrepared: true,
      clearResult: true, fieldErrors: const {}, sent: 0, total: 0,
      phase: WorkshopPublishPhase.idle, clearError: true, clearPreferenceError: true);
    return true;
  }

  bool setInput(WorkshopPublicationInput input) {
    final current = state;
    final context = _context!;
    if (!_editorReady(context)) return false;
    final kind = current.source?.kind ?? context.intent?.pending.metadata.kind;
    if (kind == null) {
      state = state.copyWith(error: const WorkshopException('workshop_source_required'));
      return false;
    }
    final changed = jsonEncode(_canonical(current.input.declaration(kind))) !=
        jsonEncode(_canonical(input.declaration(kind)));
    if (changed && current.hasPending) {
      state = state.copyWith(error: const WorkshopException('workshop_pending_submission'));
      return false;
    }
    if (changed) {
      final old = context.prepared;
      context.prepared = null;
      context.intent = null;
      if (old != null) _retire(context, old);
    }
    state = state.copyWith(input: input, clearPrepared: changed, clearResult: changed,
      fieldErrors: const {}, clearError: true,
      phase: changed ? WorkshopPublishPhase.idle : current.phase,
      sent: changed ? 0 : current.sent, total: changed ? 0 : current.total);
    return true;
  }

  Future<void> prepare() async {
    final current = state;
    final context = _context!;
    if (!_editorReady(context)) return;
    if (current.hasPending) {
      state = state.copyWith(error: const WorkshopException('workshop_pending_submission'));
      return;
    }
    final source = current.source;
    if (source == null) {
      state = state.copyWith(error: const WorkshopException('workshop_source_required'));
      return;
    }
    final errors = current.input.errors(includeRights: false);
    if (errors.isNotEmpty) {
      state = state.copyWith(fieldErrors: errors, error: const WorkshopException('workshop_invalid_publication'));
      return;
    }
    final token = _begin(context, WorkshopPublishPhase.preparing);
    if (token == null) return;
    try {
      final prepareDraft = ref.read(workshopPrepareDraftProvider);
      final old = context.prepared;
      context.prepared = null;
      context.intent = null;
      if (old != null) _retire(context, old);
      state = state.copyWith(clearPrepared: true, clearResult: true, fieldErrors: const {}, sent: 0, total: 0);
      if (!await _cleanRetired(context)) {
        if (_current(context)) state = state.copyWith(phase: WorkshopPublishPhase.failed);
        return;
      }
      _requireCurrent(context);
      final publication = current.input.publication(source.kind);
      final draft = await prepareDraft(source, publication);
      final lease = _DraftLease(draft);
      if (!_current(context)) {
        _retire(context, lease);
        await _clean(context, lease);
        return;
      }
      final metadata = draft.upload.metadata;
      if (!_sameMetadata(metadata, publication.withArchive(metadata.sha256, metadata.size))) {
        _retire(context, lease);
        await _clean(context, lease);
        workshopInvalid('workshop_prepared_mismatch');
      }
      context.prepared = lease;
      state = state.copyWith(preparedMetadata: metadata, files: draft.upload.files,
        phase: WorkshopPublishPhase.ready, clearError: true);
    } on Object catch (error) {
      if (_current(context)) state = state.copyWith(error: workshopLocalError(error), phase: WorkshopPublishPhase.failed);
    } finally {
      _end(token);
    }
  }

  void _checkSubmission(WorkshopSubmission result, _PublishIntent intent, WorkshopAuthorization authorization) {
    if (intent.submissionId != null && result.id != intent.submissionId ||
        !_sameMetadata(result.metadata, intent.pending.metadata) ||
        result.ownerOrigin != authorization.credential.forum || result.ownerId != authorization.forumUserId) {
      throw const WorkshopException('workshop_bad_response', resultUnknown: true);
    }
    // A request id is the client's idempotency token, not a submission id.
    intent.submissionId = result.id;
  }

  Future<void> _finishKnown(_PublishContext context, _PublishIntent intent,
    WorkshopSubmission result, WorkshopPreferences preferences) async {
    intent.result = result;
    if (_current(context)) state = state.copyWith(result: result, phase: WorkshopPublishPhase.complete, clearError: true);
    try {
      await preferences.clearPendingSubmission(intent.scope, intent.pending.requestId);
    } on Object {
      if (_current(context)) state = state.copyWith(preferenceError: const WorkshopException('workshop_preferences'));
      return;
    }
    intent.cleared = true;
    intent.lease.draft.retained = false;
    _retire(context, intent.lease);
    if (_current(context)) state = state.copyWith(hasPending: false, clearPreferenceError: true);
  }

  /// Every retry uses the same persisted metadata/request id. In particular,
  /// create precedes opening the archive when recovering an unknown result.
  Future<void> submit() async {
    final current = state;
    final context = _context!;
    final known = context.intent?.result != null;
    if (!_editorReady(context, requireProfile: !known)) return;
    final errors = known ? const <String, String>{} : current.input.errors();
    if (errors.isNotEmpty) {
      state = state.copyWith(fieldErrors: errors, error: const WorkshopException('workshop_invalid_publication'));
      return;
    }
    final lease = context.intent?.lease ?? context.prepared;
    if (lease == null) {
      state = state.copyWith(error: const WorkshopException('workshop_prepare_required'));
      return;
    }
    final token = _begin(context, WorkshopPublishPhase.creating);
    if (token == null) return;
    lease.borrowers++;
    try {
      final preferences = ref.read(workshopPreferencesProvider);
      var intent = context.intent;
      // A known result needs only local journal/cleanup work. Revoking the
      // checkbox cannot undo it, and this branch never requests credentials
      // or sends another create/upload.
      final completed = intent;
      if (completed != null && completed.result != null) {
        final result = completed.result!;
        if (!completed.cleared) {
          await _finishKnown(context, completed, result, preferences);
        } else {
          state = state.copyWith(result: result, phase: WorkshopPublishPhase.complete);
        }
        return;
      }
      final requestId = ref.read(workshopRequestIdProvider);
      final authorization = await _authorize(context);
      if (intent == null) {
        final metadata = lease.draft.upload.metadata;
        final fingerprint = _fingerprint(context.scope!, metadata);
        final id = await preferences.reserveSubmissionRequestId(fingerprint, requestId());
        _requireCurrent(context);
        final pending = WorkshopPendingSubmission.fromJson(WorkshopPendingSubmission(
          requestId: id, fingerprint: fingerprint, directoryName: lease.draft.directoryName,
          metadata: metadata, files: lease.draft.upload.files).toJson());
        intent = _PublishIntent(scope: context.scope!, pending: pending, lease: lease);
        context.intent = intent;
      }
      if (!intent.saved) {
        // A platform setter can report failure after a write reached disk.
        // Retention is deliberately conservative before the first attempt.
        lease.draft.retained = true;
        state = state.copyWith(hasPending: true);
        try {
          await preferences.savePendingSubmission(intent.scope, intent.pending);
          intent.saved = true;
        } on Object {
          if (_current(context)) {
            state = state.copyWith(preferenceError: const WorkshopException('workshop_preferences'),
              phase: WorkshopPublishPhase.failed);
          }
          return;
        }
      }
      _requireCurrent(context);
      state = state.copyWith(clearPreferenceError: true);
      var result = await authorization.client.createSubmission(intent.pending.metadata,
        requestId: intent.pending.requestId, rightsConfirmed: true, credential: authorization.credential);
      _checkSubmission(result, intent, authorization);
      _requireCurrent(context);
      if (result.status == WorkshopSubmissionStatus.draft) {
        state = state.copyWith(phase: WorkshopPublishPhase.uploading, sent: 0, total: intent.pending.metadata.size);
        result = await authorization.client.upload(result, lease.draft.upload.file,
          credential: authorization.credential, onProgress: (sent, total) {
            if (!_current(context) || !identical(_operation, token)) return;
            final current = state;
            if (current.phase != WorkshopPublishPhase.uploading &&
                current.phase != WorkshopPublishPhase.awaitingResponse) {
              return;
            }
            state = current.copyWith(sent: sent, total: total,
              phase: sent == total ? WorkshopPublishPhase.awaitingResponse : WorkshopPublishPhase.uploading);
          });
        _checkSubmission(result, intent, authorization);
        _requireCurrent(context);
        if (result.status == WorkshopSubmissionStatus.draft) {
          throw const WorkshopException('workshop_bad_response', resultUnknown: true);
        }
      }
      await _finishKnown(context, intent, result, preferences);
    } on Object catch (error) {
      if (_current(context)) {
        final mapped = workshopLocalError(error);
        state = state.copyWith(error: mapped,
          preferenceError: mapped.code == 'workshop_preferences' ? mapped : null,
          phase: WorkshopPublishPhase.failed);
      }
    } finally {
      lease.borrowers--;
      try { await _clean(context, lease); } finally { _end(token); }
    }
  }

  Future<void> retrySubmission() => submit();

  /// A new id for identical metadata is an explicit action, available only
  /// after a known rejected/withdrawn result and successful journal removal.
  Future<void> startNewSubmission() async {
    final current = state;
    final context = _context!;
    if (!_editorReady(context)) return;
    final intent = context.intent;
    if (!current.canStartNewSubmission || intent == null || !intent.cleared) {
      state = state.copyWith(error: const WorkshopException('workshop_new_submission_unavailable'));
      return;
    }
    final token = _begin(context, WorkshopPublishPhase.checking);
    if (token == null) return;
    try {
      await _authorize(context);
      await ref.read(workshopPreferencesProvider).retireSubmissionRequestId(
        intent.pending.fingerprint, intent.pending.requestId);
      _requireCurrent(context);
      state = state.copyWith(clearPreferenceError: true);
      if (!await _cleanRetired(context)) {
        if (_current(context)) state = state.copyWith(phase: WorkshopPublishPhase.complete);
        return;
      }
      _requireCurrent(context);
      context.intent = null;
      context.prepared = null;
      state = state.copyWith(input: current.input.copyWith(rightsConfirmed: false), clearPrepared: true,
        clearResult: true, hasPending: false, sent: 0, total: 0, fieldErrors: const {},
        phase: WorkshopPublishPhase.idle, clearError: true, clearPreferenceError: true);
    } on Object catch (error) {
      if (_current(context)) {
        final mapped = workshopLocalError(error);
        state = state.copyWith(error: mapped,
          preferenceError: mapped.code == 'workshop_preferences' ? mapped : null,
          phase: WorkshopPublishPhase.complete);
      }
    } finally {
      _end(token);
    }
  }

  Future<void> retryCleanup() async {
    final current = state;
    final context = _context!;
    if (current.working) return;
    final token = _begin(context, current.phase);
    if (token == null) return;
    try { await _cleanRetired(context); } finally { _end(token); }
  }
}

final workshopPublishProvider = NotifierProvider<WorkshopPublishController, WorkshopPublishState>(
  WorkshopPublishController.new,
);
