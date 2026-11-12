// The v1 wire contract is services/share-worker/docs/workshop-api.md.
// Nothing here reads credentials, local preferences or a widget tree.

const workshopArchiveBytes = 20 * 1024 * 1024;
const workshopExpandedBytes = 64 * 1024 * 1024;
const workshopLicenses = {
  'CC0-1.0', 'CC-BY-4.0', 'CC-BY-SA-4.0', 'MIT', 'Apache-2.0',
  'BSD-2-Clause', 'BSD-3-Clause', 'LicenseRef-Author-Permission',
};

/// Stable codes only: never put a key, server body or local path in an error.
class WorkshopException implements Exception {
  const WorkshopException(this.code, {this.status, this.retryAfter, this.resultUnknown = false});
  final String code;
  final int? status;
  final Duration? retryAfter;
  /// A write may have reached the server. Reconcile before claiming failure.
  final bool resultUnknown;
  @override
  String toString() => 'WorkshopException($code)';
}

Never workshopInvalid([String code = 'workshop_bad_response']) => throw WorkshopException(code);

bool workshopId(Object? value) => value is String && value.length <= 40 &&
    RegExp(r'^[a-z0-9]+(?:-[a-z0-9]+)*$').hasMatch(value);
bool workshopHash(Object? value) => value is String && RegExp(r'^[a-f0-9]{64}$').hasMatch(value);
bool workshopText(Object? value, int cap) => value is String && value.trim().isNotEmpty &&
    value.runes.length <= cap && !value.runes.any((r) => r < 32 || r >= 0xd800 && r <= 0xdfff);

Uri workshopOrigin(Uri value) {
  if (value.scheme != 'https' || value.host.isEmpty || value.userInfo.isNotEmpty ||
      value.hasQuery || value.hasFragment || value.path.isNotEmpty && value.path != '/') {
    workshopInvalid('workshop_untrusted_origin');
  }
  return Uri(scheme: 'https', host: _workshopOriginHost(value.host), port: value.hasPort ? value.port : null);
}

String _workshopOriginHost(String host) {
  // Uri already validated the host. Normalize ordinary IPv6 by value; zone
  // identifiers and IPvFuture keep their existing handling and support limits.
  if (!host.contains(':') || host.contains('%') || host.startsWith('[')) {
    return host;
  }
  final bytes = Uri.parseIPv6Address(host);
  final pieces = List<int>.generate(8, (i) => (bytes[i * 2] << 8) | bytes[i * 2 + 1], growable: false);
  var longestStart = -1, longestLength = 1;
  for (var i = 0; i < pieces.length;) {
    if (pieces[i] != 0) {
      i++;
      continue;
    }
    final start = i;
    while (i < pieces.length && pieces[i] == 0) {
      i++;
    }
    if (i - start > longestLength) {
      longestStart = start;
      longestLength = i - start;
    }
  }
  final words = pieces.map((piece) => piece.toRadixString(16)).toList(growable: false);
  if (longestStart < 0) {
    return words.join(':');
  }
  return '${words.take(longestStart).join(':')}::${words.skip(longestStart + longestLength).join(':')}';
}

bool workshopSource(Object? value) {
  if (!workshopText(value, 2048)) return false;
  final source = value as String;
  if (RegExp(r'\s').hasMatch(source)) return false;
  final uri = Uri.tryParse(source);
  return uri != null && uri.scheme == 'https' && uri.host.isNotEmpty && uri.userInfo.isEmpty;
}

/// The server permits 80-character SemVer, including numeric identifiers
/// larger than int64. Compare their digit strings without losing precision.
class WorkshopVersion implements Comparable<WorkshopVersion> {
  WorkshopVersion._(this.value, this.core, this.pre);
  final String value;
  final List<String> core;
  final List<String> pre;
  static final _syntax = RegExp(
    r'^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-((?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*))?$',
  );
  static WorkshopVersion? tryParse(Object? value) {
    if (value is! String || value.length > 80) return null;
    final match = _syntax.firstMatch(value);
    if (match == null) return null;
    return WorkshopVersion._(value, [match[1]!, match[2]!, match[3]!], match[4]?.split('.') ?? const []);
  }
  static int _digits(String a, String b) => a.length == b.length ? a.compareTo(b) : a.length.compareTo(b.length);
  @override
  int compareTo(WorkshopVersion other) {
    for (var i = 0; i < 3; i++) {
      final n = _digits(core[i], other.core[i]);
      if (n != 0) return n;
    }
    if (pre.isEmpty || other.pre.isEmpty) {
      return pre.isEmpty == other.pre.isEmpty ? 0 : (pre.isEmpty ? 1 : -1);
    }
    for (var i = 0; i < pre.length && i < other.pre.length; i++) {
      final a = pre[i], b = other.pre[i];
      final an = RegExp(r'^[0-9]+$').hasMatch(a), bn = RegExp(r'^[0-9]+$').hasMatch(b);
      final n = an && bn ? _digits(a, b) : an != bn ? (an ? -1 : 1) : a.compareTo(b);
      if (n != 0) return n;
    }
    return pre.length.compareTo(other.pre.length);
  }
}

Map<String, Object?> workshopMap(Object? value) {
  if (value is! Map<String, Object?>) workshopInvalid();
  return value;
}

DateTime workshopTime(Object? value) {
  if (value is! String || !RegExp(r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{3})?Z$').hasMatch(value)) {
    workshopInvalid();
  }
  final time = DateTime.tryParse(value);
  if (time == null || time.toUtc().toIso8601String() != (value.contains('.') ? value : value.replaceFirst('Z', '.000Z'))) {
    workshopInvalid();
  }
  return time;
}

class WorkshopFeatures {
  const WorkshopFeatures({required this.uploads, required this.companion});
  factory WorkshopFeatures.fromJson(Object? value) {
    final map = workshopMap(value);
    if (map['uploads'] is! bool || map['companion'] is! bool) workshopInvalid();
    return WorkshopFeatures(uploads: map['uploads'] as bool, companion: map['companion'] as bool);
  }
  final bool uploads;
  final bool companion;
  Map<String, Object?> toJson() => {'uploads': uploads, 'companion': companion};
}

class WorkshopMetadata {
  WorkshopMetadata._(Map<String, Object?> value)
    : kind = value['kind'] as String, id = value['id'] as String, version = value['version'] as String,
      minApp = value['minApp'] as String, title = Map.unmodifiable((value['title'] as Map).cast<String, String>()),
      author = value['author'] as String, license = value['license'] as String, source = value['source'] as String,
      sha256 = value['sha256'] as String, size = value['size'] as int, description = value['description'] as String,
      tags = List.unmodifiable((value['tags'] as List).cast<String>());

  factory WorkshopMetadata.fromJson(Object? value, {bool submission = true}) {
    final m = workshopMap(value), title = m['title'];
    final description = m.containsKey('description') ? m['description'] : '';
    final tags = m.containsKey('tags') ? m['tags'] : const <String>[];
    final supported = const {'pet', 'companion'}.contains(m['kind']);
    if (!workshopId(m['kind']) || !workshopId(m['id']) || WorkshopVersion.tryParse(m['version']) == null ||
        WorkshopVersion.tryParse(m['minApp']) == null || title is! Map ||
        !workshopText(title['zh'], 120) || !workshopText(title['en'], 120) ||
        !workshopText(m['author'], 256) || !workshopText(m['license'], 100) || !workshopSource(m['source']) ||
        !workshopHash(m['sha256']) || m['size'] is! int || (m['size'] as int) < 1 ||
        (m['size'] as int) > 9007199254740991 || supported &&
        (!workshopLicenses.contains(m['license']) || (m['size'] as int) > workshopArchiveBytes) || submission &&
        (m['rightsConfirmed'] != true || !supported) ||
        description != '' && !workshopText(description, 512) || tags is! List || tags.length > 8 ||
        tags.any((tag) => !workshopText(tag, 32)) || tags.toSet().length != tags.length) {
      workshopInvalid(submission ? 'workshop_bad_metadata' : 'workshop_bad_catalog');
    }
    return WorkshopMetadata._({...m, 'title': {'zh': title['zh'], 'en': title['en']}, 'description': description, 'tags': tags});
  }
  final String kind, id, version, minApp, author, license, source, sha256, description;
  final Map<String, String> title;
  final List<String> tags;
  final int size;
  String get identity => '$kind/$id';
  String get release => '$identity/$version';
  bool get supported => kind == 'pet' || kind == 'companion';
  String get archivePath => '/market/workshop/$release/$sha256.zip';
  Map<String, Object?> toJson({bool submission = true}) => {
    'kind': kind, 'id': id, 'version': version, 'minApp': minApp, 'title': title,
    'author': author, 'license': license, 'source': source, 'sha256': sha256, 'size': size,
    if (description.isNotEmpty) 'description': description,
    if (tags.isNotEmpty) 'tags': tags,
    if (submission) 'rightsConfirmed': true,
  };
}

class WorkshopEntry {
  WorkshopEntry._(this.metadata, this.blockedVersions);
  factory WorkshopEntry.fromJson(Object? value) {
    final m = workshopMap(value), meta = WorkshopMetadata.fromJson(value, submission: false), blocked = m['blockedVersions'];
    if (m['url'] != meta.archivePath || blocked is! List || blocked.length > 4000 ||
        blocked.any((v) => WorkshopVersion.tryParse(v) == null) || blocked.toSet().length != blocked.length) {
      workshopInvalid('workshop_bad_catalog');
    }
    return WorkshopEntry._(meta, Set.unmodifiable(blocked.cast<String>()));
  }
  final WorkshopMetadata metadata;
  final Set<String> blockedVersions;
  Map<String, Object?> toJson() => {...metadata.toJson(submission: false), 'url': metadata.archivePath, 'blockedVersions': blockedVersions.toList()};
}

class WorkshopWithdrawal {
  WorkshopWithdrawal._(this.kind, this.id, this.version, this.reason, this.at);
  factory WorkshopWithdrawal.fromJson(Object? value) {
    final m = workshopMap(value);
    if (!workshopId(m['kind']) || !workshopId(m['id']) || WorkshopVersion.tryParse(m['version']) == null || !workshopText(m['reason'], 2000)) {
      workshopInvalid('workshop_bad_catalog');
    }
    return WorkshopWithdrawal._(m['kind'] as String, m['id'] as String, m['version'] as String, m['reason'] as String, workshopTime(m['at']));
  }
  final String kind, id, version, reason;
  final DateTime at;
  String get release => '$kind/$id/$version';
  Map<String, Object?> toJson() => {'kind': kind, 'id': id, 'version': version, 'reason': reason, 'at': at.toUtc().toIso8601String()};
}

class WorkshopCatalog {
  WorkshopCatalog._(this.generatedAt, this.features, this.entries, this.withdrawn);
  factory WorkshopCatalog.fromJson(Object? value) {
    final m = workshopMap(value), rows = m['entries'], gone = m['withdrawn'];
    if (m['schema'] != 1 || rows is! List || rows.length > 1000 || gone is! List || gone.length > 4000) {
      workshopInvalid('workshop_bad_catalog');
    }
    final entries = rows.map(WorkshopEntry.fromJson).toList(), withdrawals = gone.map(WorkshopWithdrawal.fromJson).toList();
    if (entries.map((e) => e.metadata.identity).toSet().length != entries.length ||
        withdrawals.map((e) => e.release).toSet().length != withdrawals.length) {
      workshopInvalid('workshop_bad_catalog');
    }
    return WorkshopCatalog._(workshopTime(m['generatedAt']), WorkshopFeatures.fromJson(m['features']), List.unmodifiable(entries), List.unmodifiable(withdrawals));
  }
  final DateTime generatedAt;
  final WorkshopFeatures features;
  final List<WorkshopEntry> entries;
  final List<WorkshopWithdrawal> withdrawn;
  WorkshopEntry? find(String kind, String id) => entries.where((e) => e.metadata.kind == kind && e.metadata.id == id).firstOrNull;
  bool blocked(String kind, String id, String version) => withdrawn.any((e) => e.release == '$kind/$id/$version') || (find(kind, id)?.blockedVersions.contains(version) ?? false);
  String? unavailable(WorkshopEntry entry, String appVersion) {
    final m = entry.metadata;
    if (!m.supported) return 'workshop_unsupported_kind';
    if (m.kind == 'companion' && !features.companion) return 'workshop_companion_disabled';
    if (blocked(m.kind, m.id, m.version)) return 'workshop_version_withdrawn';
    final installedApp = WorkshopVersion.tryParse(appVersion.split('+').first);
    if (installedApp == null) return 'workshop_app_version_unknown';
    if (installedApp.compareTo(WorkshopVersion.tryParse(m.minApp)!) < 0) return 'workshop_min_app';
    return null;
  }
  Map<String, Object?> toJson() => {'schema': 1, 'generatedAt': generatedAt.toUtc().toIso8601String(), 'features': features.toJson(), 'entries': entries.map((e) => e.toJson()).toList(), 'withdrawn': withdrawn.map((e) => e.toJson()).toList()};
}

class WorkshopCapabilities {
  WorkshopCapabilities._(this.features, this.kinds, this.licenses, this.forumOrigin, this.archiveBytes, this.expandedBytes, this.maxMocVersion);
  factory WorkshopCapabilities.fromJson(Object? value) {
    final m = workshopMap(value), limits = workshopMap(m['limits']);
    final kinds = m['kinds'], licenses = m['licenses'], origin = m['forumOrigin'];
    if (m['schema'] != 1 || kinds is! List || kinds.any((k) => !workshopId(k)) || licenses is! List ||
        licenses.any((k) => !workshopText(k, 100)) || origin is! String || limits['archiveBytes'] is! int ||
        (limits['archiveBytes'] as int) < 1 || limits['expandedBytes'] is! int || (limits['expandedBytes'] as int) < 1 ||
        m['maxMocVersion'] is! int || (m['maxMocVersion'] as int) < 1) {
      workshopInvalid();
    }
    final parsedOrigin = Uri.tryParse(origin);
    if (parsedOrigin == null) workshopInvalid();
    return WorkshopCapabilities._(WorkshopFeatures.fromJson(m['features']), Set.unmodifiable(kinds.cast<String>()), Set.unmodifiable(licenses.cast<String>()),
      workshopOrigin(parsedOrigin), limits['archiveBytes'] as int, limits['expandedBytes'] as int, m['maxMocVersion'] as int);
  }
  final WorkshopFeatures features;
  final Set<String> kinds, licenses;
  final Uri forumOrigin;
  final int archiveBytes, expandedBytes, maxMocVersion;
}

enum WorkshopSubmissionStatus { draft, pending, approved, rejected, withdrawn }

class WorkshopSubmission {
  WorkshopSubmission._(this.id, this.metadata, this.status, this.createdAt, this.updatedAt, this.ownerOrigin,
      this.ownerId, this.username, this.reviewReason, this.withdrawalReason);
  factory WorkshopSubmission.fromJson(Object? value) {
    final m = workshopMap(value), owner = workshopMap(m['owner']);
    final id = m['submissionId'], status = WorkshopSubmissionStatus.values.asNameMap()[m['status']];
    if (id is! String || !RegExp(r'^[a-f0-9]{32}$').hasMatch(id) || status == null ||
        owner['forumUserId'] is! int || (owner['forumUserId'] as int) < 1 || !workshopText(owner['username'], 256) || owner['forumOrigin'] is! String) {
      workshopInvalid();
    }
    String? reason(Object? v) {
      if (v == null) return null;
      final r = workshopMap(v)['reason'];
      if (!workshopText(r, 2000)) workshopInvalid();
      return r as String;
    }
    final origin = Uri.tryParse(owner['forumOrigin'] as String);
    if (origin == null) workshopInvalid();
    return WorkshopSubmission._(id, WorkshopMetadata.fromJson(m['metadata']), status, workshopTime(m['createdAt']), workshopTime(m['updatedAt']),
      workshopOrigin(origin), owner['forumUserId'] as int, owner['username'] as String, reason(m['review']), reason(m['withdrawal']));
  }
  final String id;
  final WorkshopMetadata metadata;
  final WorkshopSubmissionStatus status;
  final DateTime createdAt, updatedAt;
  final Uri ownerOrigin;
  final int ownerId;
  final String username;
  final String? reviewReason, withdrawalReason;
}

class WorkshopSubmissionPage {
  const WorkshopSubmissionPage(this.submissions, this.nextCursor);
  final List<WorkshopSubmission> submissions;
  final String? nextCursor;
}
