/// 伙伴小屋's state on the Host, through the dsh-go bridge
/// (runtime/bridge/dsh-go-bridge/lib/companion/, contract in
/// docs/design/companion.md):
///
/// * `GET  /dsh-go/v1/companion`: identity, versions and her state now;
/// * `POST /dsh-go/v1/companion/events`: `visit` / `pet` / `snack` / `play` /
///   `rest`, with the store id and revision as read;
/// * `GET  /dsh-go/v1/companion/memories`, `POST .../memories` (add or replace
///   one, by a client-made id), `POST .../memories/delete`, `.../clear`.
///
/// Writes carry `storeId` + `expectedRevision`; a 409 means someone else wrote
/// first: read again, never replay with the new revision. Only HTTP carriers
/// reach the bridge (not the relay); a 404 without a code means an older
/// bridge. Refusals throw [DshRemoteException] `companion/<code>`.
library;

import 'carrier.dart';
import 'connection.dart';
import 'dsh_go_api.dart';
import 'errors.dart';
import 'json.dart';
import 'session_api.dart';

const dshGoCompanionPath = '/dsh-go/v1/companion';

/// Her state as the Host projects it at [asOf].
class CompanionVitals {
  const CompanionVitals({
    required this.valence,
    required this.energy,
    required this.closeness,
    required this.activity,
    this.activityUntil,
    this.lastVisitAt,
    this.lastInteractionAt,
    this.thought,
  });

  factory CompanionVitals.fromJson(Object? json) {
    final map = asMapOrEmpty(json);
    double unit(String key, double fallback) => (asNum(map[key])?.toDouble() ?? fallback).clamp(0, 1);
    return CompanionVitals(
      valence: unit('valence', 0.25),
      energy: unit('energy', 0.75),
      closeness: unit('closeness', 0),
      activity: asString(map['activity']) ?? 'idle',
      activityUntil: _time(map['activityUntil']),
      lastVisitAt: _time(map['lastVisitAt']),
      lastInteractionAt: _time(map['lastInteractionAt']),
      thought: asString(map['thought']),
    );
  }

  /// 0–1: how pleased she is right now (rule variable, not a measurement).
  final double valence;

  /// 0–1: how lively.
  final double energy;

  /// 0–1: how well she knows the person; never decays with absence.
  final double closeness;

  /// `idle` / `snack` / `play` / `rest`; unknown names read as idle.
  final String activity;
  final DateTime? activityUntil;
  final DateTime? lastVisitAt;
  final DateTime? lastInteractionAt;
  final String? thought;
}

class CompanionSnapshot {
  const CompanionSnapshot({
    required this.storeId,
    required this.revision,
    required this.memoryRevision,
    required this.vitals,
    this.asOf,
    this.memories = false,
    this.automaticRecall = false,
  });

  static CompanionSnapshot? fromJson(Object? json) {
    final map = asMap(json);
    final storeId = asString(map?['storeId']);
    final revision = asInt(map?['revision']);
    if (map == null || storeId == null || revision == null) return null;
    final capabilities = asMapOrEmpty(map['capabilities']);
    return CompanionSnapshot(
      storeId: storeId,
      revision: revision,
      memoryRevision: asInt(map['memoryRevision']) ?? 0,
      vitals: CompanionVitals.fromJson(map['state']),
      asOf: _time(map['asOf']),
      memories: capabilities['memories'] == true,
      automaticRecall: capabilities['automaticRecall'] == true,
    );
  }

  final String storeId;
  final int revision;
  final int memoryRevision;
  final CompanionVitals vitals;

  /// The Host's clock when it projected [vitals].
  final DateTime? asOf;

  /// How long her current activity has left, on the Host's own clock (never
  /// the phone's: the two can disagree).
  Duration get activityLeft {
    final until = vitals.activityUntil;
    final now = asOf;
    if (vitals.activity == 'idle' || until == null || now == null) return Duration.zero;
    final left = until.difference(now);
    return left.isNegative ? Duration.zero : left;
  }

  /// The Host keeps confirmed memories.
  final bool memories;

  /// The Host puts them in front of her by itself (not yet: false).
  final bool automaticRecall;
}

/// Provenance supplied by the confirming UI, not proof of user approval.
class CompanionMemorySource {
  const CompanionMemorySource({this.kind = 'manual', this.sessionId, this.messageId});

  factory CompanionMemorySource.fromJson(Object? json) {
    final map = asMapOrEmpty(json);
    return CompanionMemorySource(
      kind: asString(map['kind']) ?? 'manual',
      sessionId: asString(map['sessionId']),
      messageId: asString(map['messageId']),
    );
  }

  final String kind;
  final String? sessionId;
  final String? messageId;
  Map<String, Object?> toJson() => {
    'kind': kind,
    if (sessionId != null) 'sessionId': sessionId,
    if (messageId != null) 'messageId': messageId,
  };
}

/// One thing she remembers, as the person confirmed it.
class CompanionMemory {
  const CompanionMemory({
    required this.id,
    required this.text,
    this.kind = 'fact',
    this.keywords = const [],
    this.pinned = false,
    this.source = const CompanionMemorySource(),
    this.expiresAt,
    this.createdAt,
    this.updatedAt,
  });

  static CompanionMemory? fromJson(Object? json) {
    final map = asMap(json);
    final id = asString(map?['id']);
    final text = asString(map?['text']);
    if (map == null || id == null || text == null) return null;
    return CompanionMemory(
      id: id,
      text: text,
      kind: asString(map['kind']) ?? 'fact',
      keywords: asStringList(map['keywords']),
      pinned: map['pinned'] == true,
      source: CompanionMemorySource.fromJson(map['source']),
      expiresAt: _time(map['expiresAt']),
      createdAt: _time(map['createdAt']),
      updatedAt: _time(map['updatedAt']),
    );
  }

  final String id;
  final String text;

  /// `fact` / `preference` / `episode`.
  final String kind;
  final List<String> keywords;
  final bool pinned;
  final CompanionMemorySource source;
  final DateTime? expiresAt;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// What a write sends: the server owns the timestamps.
  Map<String, Object?> toWrite() => {
    'id': id,
    'kind': kind,
    'text': text,
    'keywords': keywords,
    'pinned': pinned,
    'source': source.toJson(),
    'expiresAt': expiresAt?.millisecondsSinceEpoch,
  };
}

class CompanionMemories {
  const CompanionMemories({
    required this.storeId,
    required this.revision,
    required this.memories,
    this.memoryRevision = 0,
  });

  final String storeId;
  final int revision;
  final int memoryRevision;
  final List<CompanionMemory> memories;
}

DateTime? _time(Object? value) {
  final ms = asInt(value);
  return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
}

extension CompanionApi on DshClient {
  DshConnection get _bridge => (carrier as DshHttpCarrier).connection;

  /// `GET /dsh-go/v1/companion`. Null when this Host can't keep her state:
  /// the relay, or a bridge without these routes.
  Future<CompanionSnapshot?> companionSnapshot({Duration timeout = const Duration(seconds: 8)}) async {
    if (!canReachDshGo) return null;
    final response = await _bridge.get(dshGoCompanionPath, timeout: timeout);
    if (response.statusCode == 404 && _codeOf(response) == null) return null;
    return _snapshot(dshGoCompanionPath, response);
  }

  /// `POST /dsh-go/v1/companion/events`.
  Future<CompanionSnapshot> companionEvent(
    CompanionSnapshot read,
    String type, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    const path = '$dshGoCompanionPath/events';
    final response = await _bridge.postJson(path, {
      'storeId': read.storeId,
      'expectedRevision': read.revision,
      'type': type,
    }, timeout: timeout);
    return _snapshot(path, response);
  }

  Future<CompanionMemories> companionMemories({Duration timeout = const Duration(seconds: 8)}) async {
    const path = '$dshGoCompanionPath/memories';
    final response = await _bridge.get(path, timeout: timeout);
    return _memories(path, response);
  }

  /// Adds [memory], or replaces the one with its id. Returns the new revision.
  Future<int> saveCompanionMemory(String storeId, int revision, CompanionMemory memory) async {
    const path = '$dshGoCompanionPath/memories';
    final response = await _bridge.postJson(path, {
      'storeId': storeId,
      'expectedRevision': revision,
      'memory': memory.toWrite(),
    }, timeout: const Duration(seconds: 8));
    return _revision(path, response);
  }

  Future<int> deleteCompanionMemory(String storeId, int revision, String id) async {
    const path = '$dshGoCompanionPath/memories/delete';
    final response = await _bridge.postJson(path, {
      'storeId': storeId,
      'expectedRevision': revision,
      'id': id,
    }, timeout: const Duration(seconds: 8));
    return _revision(path, response);
  }

  CompanionSnapshot _snapshot(String path, DshHttpResponse response) {
    if (response.statusCode != 200) throw companionHttpError(path, response);
    final snapshot = CompanionSnapshot.fromJson(tryDecodeJson(response.text));
    if (snapshot == null) throw DshProtocolException('$path: not a companion snapshot');
    return snapshot;
  }

  CompanionMemories _memories(String path, DshHttpResponse response) {
    if (response.statusCode != 200) throw companionHttpError(path, response);
    final map = asMap(tryDecodeJson(response.text));
    final storeId = asString(map?['storeId']);
    final revision = asInt(map?['revision']);
    if (map == null || storeId == null || revision == null) throw DshProtocolException('$path: not a memory list');
    return CompanionMemories(
      storeId: storeId,
      revision: revision,
      memoryRevision: asInt(map['memoryRevision']) ?? 0,
      memories: [for (final m in asListOrEmpty(map['memories'])) ?CompanionMemory.fromJson(m)],
    );
  }

  int _revision(String path, DshHttpResponse response) {
    if (response.statusCode != 200) throw companionHttpError(path, response);
    final revision = asInt(asMap(tryDecodeJson(response.text))?['revision']);
    if (revision == null) throw DshProtocolException('$path: no revision');
    return revision;
  }
}

String? _codeOf(DshHttpResponse response) => asString(asMap(asMap(tryDecodeJson(response.text))?['error'])?['code']);

/// A refusal as its `companion/<code>` (`companion/http-<status>` without one).
DshRemoteException companionHttpError(String path, DshHttpResponse response) {
  final error = asMap(asMap(tryDecodeJson(response.text))?['error']);
  final code = asString(error?['code']);
  return DshRemoteException(
    code ?? 'companion/http-${response.statusCode}',
    asString(error?['message']) ?? '$path: HTTP ${response.statusCode}',
    {'route': path, 'status': response.statusCode},
  );
}
