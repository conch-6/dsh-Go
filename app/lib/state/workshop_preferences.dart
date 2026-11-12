import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../workshop/workshop_models.dart';

class WorkshopPendingSubmission {
  WorkshopPendingSubmission({required this.requestId, required this.fingerprint,
    required this.directoryName, required this.metadata, required List<String> files})
    : files = List.unmodifiable(files);
  final String requestId, fingerprint, directoryName;
  final WorkshopMetadata metadata;
  final List<String> files;

  factory WorkshopPendingSubmission.fromJson(Object? value) {
    try {
      final map = workshopMap(value);
      final id = map['requestId'], fingerprint = map['fingerprint'];
      final directory = map['directoryName'], files = map['files'];
      if (id is! String || !RegExp(r'^[a-f0-9]{32}$').hasMatch(id) ||
          !workshopHash(fingerprint) || directory is! String ||
          !RegExp(r'^draft-[A-Za-z0-9_-]{1,100}$').hasMatch(directory) ||
          files is! List || files.any((file) => file is! String)) {
        workshopInvalid('workshop_preferences');
      }
      return WorkshopPendingSubmission(requestId: id, fingerprint: fingerprint as String,
        directoryName: directory, metadata: WorkshopMetadata.fromJson(map['metadata']),
        files: files.cast<String>());
    } on Object {
      throw const WorkshopException('workshop_preferences');
    }
  }

  Map<String, Object?> toJson() => {'requestId': requestId, 'fingerprint': fingerprint,
    'directoryName': directoryName, 'metadata': metadata.toJson(), 'files': files};
}

/// Only disclosure acknowledgements and non-secret idempotency identifiers.
/// Forum keys remain exclusively in the existing ForumAuthController/store.
abstract interface class WorkshopPreferences {
  Future<bool> disclosureAccepted(Uri worker, Uri forum);
  Future<void> acceptDisclosure(Uri worker, Uri forum);
  /// Atomically keeps the first identifier for these exact account/metadata
  /// bytes. A replacement controller gets the same identifier before sending.
  Future<String> reserveSubmissionRequestId(String fingerprint, String proposed);
  Future<void> retireSubmissionRequestId(String fingerprint, String expectedRequestId);
  Future<WorkshopPendingSubmission?> pendingSubmission(String scope);
  Future<void> savePendingSubmission(String scope, WorkshopPendingSubmission pending);
  Future<void> clearPendingSubmission(String scope, String expectedRequestId);
}

class PrefsWorkshopPreferences implements WorkshopPreferences {
  const PrefsWorkshopPreferences();

  static const _disclosuresKey = 'workshop.disclosures.v1';
  static const _requestsKey = 'workshop.request_ids.v1';
  static const _pendingKey = 'workshop.pending.v1';
  static Future<void> _tail = Future<void>.value();

  static Future<T> _exclusive<T>(Future<T> Function(SharedPreferences) body) {
    final result = _tail.then((_) async {
      try {
        final preferences = await SharedPreferences.getInstance();
        // Legacy setters update their memory cache before the platform write.
        // Reload on every operation so a failed write cannot masquerade as a
        // persisted acknowledgement/id in this or a replacement instance.
        await preferences.reload();
        return await body(preferences);
      } on WorkshopException {
        rethrow;
      } on Object {
        throw const WorkshopException('workshop_preferences');
      }
    });
    _tail = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  static String _pair(Uri worker, Uri forum) =>
      jsonEncode([workshopOrigin(worker).toString(), workshopOrigin(forum).toString()]);

  @override
  Future<bool> disclosureAccepted(Uri worker, Uri forum) {
    final pair = _pair(worker, forum);
    return _exclusive((prefs) async => prefs.getStringList(_disclosuresKey)?.contains(pair) ?? false);
  }

  @override
  Future<void> acceptDisclosure(Uri worker, Uri forum) {
    final pair = _pair(worker, forum);
    return _exclusive((prefs) async {
      final pairs = {...?prefs.getStringList(_disclosuresKey), pair}.toList()..sort();
      if (!await prefs.setStringList(_disclosuresKey, pairs)) {
        throw const WorkshopException('workshop_preferences');
      }
    });
  }

  static Map<String, String> _requests(SharedPreferences prefs) {
    final text = prefs.getString(_requestsKey);
    if (text == null) return {};
    final decoded = jsonDecode(text);
    if (decoded is! Map<String, Object?> || decoded.entries.any((entry) {
      final value = entry.value;
      return !RegExp(r'^[a-f0-9]{64}$').hasMatch(entry.key) ||
          value is! String || !RegExp(r'^[a-f0-9]{32}$').hasMatch(value);
    })) {
      throw const WorkshopException('workshop_preferences');
    }
    return decoded.cast<String, String>();
  }

  static void _fingerprint(String value) {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(value)) workshopInvalid('workshop_bad_request_id');
  }

  @override
  Future<String> reserveSubmissionRequestId(String fingerprint, String proposed) {
    _fingerprint(fingerprint);
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(proposed)) workshopInvalid('workshop_bad_request_id');
    return _exclusive((prefs) async {
      final requests = _requests(prefs);
      final existing = requests[fingerprint];
      if (existing != null) return existing;
      requests[fingerprint] = proposed;
      if (!await prefs.setString(_requestsKey, jsonEncode(requests))) {
        throw const WorkshopException('workshop_preferences');
      }
      return proposed;
    });
  }

  @override
  Future<void> retireSubmissionRequestId(String fingerprint, String expectedRequestId) {
    _fingerprint(fingerprint);
    return _exclusive((prefs) async {
      final requests = _requests(prefs);
      if (requests[fingerprint] != expectedRequestId) return;
      requests.remove(fingerprint);
      if (!await prefs.setString(_requestsKey, jsonEncode(requests))) {
        throw const WorkshopException('workshop_preferences');
      }
    });
  }

  static Map<String, Object?> _pending(SharedPreferences prefs) {
    final raw = prefs.getString(_pendingKey);
    if (raw == null) return {};
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, Object?>) workshopInvalid('workshop_preferences');
    return decoded;
  }

  @override
  Future<WorkshopPendingSubmission?> pendingSubmission(String scope) {
    _fingerprint(scope);
    return _exclusive((prefs) async {
      final all = _pending(prefs);
      return !all.containsKey(scope) ? null : WorkshopPendingSubmission.fromJson(all[scope]);
    });
  }

  @override
  Future<void> savePendingSubmission(String scope, WorkshopPendingSubmission pending) {
    _fingerprint(scope);
    final checked = WorkshopPendingSubmission.fromJson(pending.toJson());
    return _exclusive((prefs) async {
      final all = _pending(prefs);
      if (all.containsKey(scope)) {
        final old = WorkshopPendingSubmission.fromJson(all[scope]);
        if (old.requestId != checked.requestId) workshopInvalid('workshop_pending_submission');
        if (jsonEncode(old.metadata.toJson()) != jsonEncode(checked.metadata.toJson())) {
          workshopInvalid('workshop_request_id_reused');
        }
      }
      all[scope] = checked.toJson();
      if (!await prefs.setString(_pendingKey, jsonEncode(all))) workshopInvalid('workshop_preferences');
    });
  }

  @override
  Future<void> clearPendingSubmission(String scope, String expectedRequestId) {
    _fingerprint(scope);
    return _exclusive((prefs) async {
      final all = _pending(prefs);
      if (!all.containsKey(scope) || WorkshopPendingSubmission.fromJson(all[scope]).requestId != expectedRequestId) return;
      all.remove(scope);
      if (!await prefs.setString(_pendingKey, jsonEncode(all))) workshopInvalid('workshop_preferences');
    });
  }
}

final workshopPreferencesProvider = Provider<WorkshopPreferences>((ref) => const PrefsWorkshopPreferences());
