import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../companion/companion_float.dart' show companionFloatStoreProvider;
import '../pets/pet_library.dart';
import '../workshop/workshop_models.dart';
import '../workshop/workshop_preview.dart';
import '../workshop/workshop_repository.dart';
import 'workshop_dependencies.dart';
import 'workshop_preferences.dart';
import 'workshop_publication.dart';

class WorkshopPublishSource {
  const WorkshopPublishSource({required this.kind, required this.localId,
    this.name, this.author, this.license, this.source, this.preview});
  final String kind, localId;
  final String? name, author, license, source;
  final WorkshopPreviewInput? preview;
  String? get previewSource => preview?.source;

  WorkshopPublishSource withPreview(WorkshopPreviewInput? value) => WorkshopPublishSource(
    kind: kind, localId: localId, name: name, author: author, license: license, source: source, preview: value);

  WorkshopPublicationInput initialInput() {
    final candidate = kind == 'pet' && localId.startsWith(userPetPrefix)
        ? localId.substring(userPetPrefix.length) : '';
    return WorkshopPublicationInput(id: workshopId(candidate) ? candidate : '',
      titleZh: kind == 'pet' ? name ?? '' : '', titleEn: kind == 'pet' ? name ?? '' : '',
      author: author ?? '', license: license ?? '', source: source ?? '');
  }
}

class WorkshopPublishSources {
  WorkshopPublishSources({List<WorkshopPublishSource> values = const [],
    Map<String, WorkshopException> issues = const {}, this.loading = false, this.generation = 0})
    : values = List.unmodifiable(values), issues = Map.unmodifiable(issues);
  final List<WorkshopPublishSource> values;
  final Map<String, WorkshopException> issues;
  final bool loading;
  final int generation;
}

final workshopSourcesLoaderProvider = Provider<Future<WorkshopPublishSources> Function()>((ref) {
  final pets = ref.watch(petLibraryProvider);
  final companion = ref.watch(companionFloatStoreProvider);
  return () async {
    final values = <WorkshopPublishSource>[], issues = <String, WorkshopException>{};
    try {
      for (final pet in await pets.list()) {
        values.add(WorkshopPublishSource(kind: 'pet', localId: pet.id, name: pet.name,
          author: pet.author, license: pet.license, source: pet.source));
      }
    } on Object catch (error) {
      issues['pet'] = workshopLocalError(error);
    }
    try {
      final store = await companion();
      if (await store.installed()) {
        final character = await store.character();
        values.add(WorkshopPublishSource(kind: 'companion', localId: 'companion',
          author: character.author, license: character.license, source: character.source));
      } else {
        issues['companion'] = const WorkshopException('workshop_companion_unavailable');
      }
    } on Object catch (error) {
      issues['companion'] = workshopLocalError(error);
    }
    return WorkshopPublishSources(values: values, issues: issues);
  };
});

class WorkshopPublishSourcesController extends Notifier<WorkshopPublishSources> {
  int _generation = 0, _request = 0;
  late Future<WorkshopPublishSources> Function() _loader;

  @override
  WorkshopPublishSources build() {
    _loader = ref.watch(workshopSourcesLoaderProvider);
    final generation = ++_generation, request = ++_request;
    final loader = _loader;
    unawaited(Future<void>.microtask(() => _read(generation, request, loader)));
    return WorkshopPublishSources(loading: true, generation: generation);
  }

  Future<void> refresh() async {
    final current = state;
    state = WorkshopPublishSources(values: current.values, issues: current.issues,
      loading: true, generation: current.generation);
    await _read(current.generation, ++_request, _loader);
  }

  bool _current(int generation, int request) => ref.mounted &&
      state.generation == generation && _request == request;

  Future<void> _read(int generation, int request, Future<WorkshopPublishSources> Function() loader) async {
    try {
      final found = await loader();
      if (_current(generation, request)) {
        state = WorkshopPublishSources(values: found.values, issues: found.issues, generation: generation);
      }
    } on Object catch (error) {
      if (_current(generation, request)) {
        state = WorkshopPublishSources(values: state.values,
          issues: {'all': workshopLocalError(error)}, generation: generation);
      }
    }
  }
}

final workshopPublishSourcesProvider = NotifierProvider<WorkshopPublishSourcesController, WorkshopPublishSources>(
  WorkshopPublishSourcesController.new,
);

/// The cleanup callback owns only the private directory created for this draft.
/// A persisted pending request retains it across page/account/app replacement.
class WorkshopPreparedDraft {
  WorkshopPreparedDraft({required this.upload, required this.directoryName, required this.cleanup});
  final WorkshopPreparedUpload upload;
  final String directoryName;
  final Future<void> Function() cleanup;
  bool retained = false;
  bool _disposed = false;
  Future<void>? _disposal;
  Future<void> dispose() {
    final inProgress = _disposal;
    if (inProgress != null) return inProgress;
    if (_disposed || retained) return Future<void>.value();
    // Assign before a caller-supplied cleanup can synchronously fail. Its
    // finally must clear the assigned Future so a later retry can run.
    return _disposal = Future<void>.microtask(_clean);
  }
  Future<void> _clean() async {
    try {
      await cleanup();
      _disposed = true;
    } finally {
      _disposal = null;
    }
  }
}

typedef WorkshopPrepareDraft = Future<WorkshopPreparedDraft> Function(
  WorkshopPublishSource source, WorkshopPublication publication);
typedef WorkshopRestoreDraft = Future<WorkshopPreparedDraft> Function(WorkshopPendingSubmission pending);

final workshopPrepareDraftProvider = Provider<WorkshopPrepareDraft>((ref) {
  final repository = ref.watch(workshopRepositoryProvider.future);
  // The page can keep the prepare function before invoking it. Observe an
  // early factory failure now; invoking the function still reports that error.
  unawaited(repository.then<void>((_) {}, onError: (Object error, StackTrace stack) {}));
  final pets = ref.watch(petLibraryProvider);
  final companion = ref.watch(companionFloatStoreProvider);
  final directory = ref.watch(workshopDirectoryProvider);
  return (source, publication) async {
    Directory? owned;
    try {
      if (source.previewSource != publication.previewSource ||
          source.previewSource != null && source.previewSource != workshopPreviewSources[source.kind]) {
        workshopInvalid('workshop_bad_metadata');
      }
      final repo = await repository;
      final root = Directory('${(await directory()).path}/exports');
      await root.create(recursive: true);
      final draft = await root.createTemp('draft-');
      owned = draft;
      final file = File('${draft.path}/archive.zip');
      final WorkshopPreparedUpload upload;
      if (source.kind == 'pet') {
        upload = await repo.preparePet(pets, source.localId, file, publication);
      } else if (source.kind == 'companion' && source.localId == 'companion') {
        // No personal name, persona, runtime, or private preference is passed.
        upload = await repo.prepareCompanion(await companion(), file, publication, preview: source.preview);
      } else {
        throw const WorkshopException('workshop_unsupported_kind');
      }
      return WorkshopPreparedDraft(upload: upload,
        directoryName: draft.uri.pathSegments.where((part) => part.isNotEmpty).last,
        cleanup: () async { if (await draft.exists()) await draft.delete(recursive: true); });
    } on Object catch (error) {
      final failed = owned;
      if (failed != null) {
        try { if (await failed.exists()) await failed.delete(recursive: true); } on Object { /* Keep the preparation error. */ }
      }
      throw workshopLocalError(error);
    }
  };
});

final workshopRestoreDraftProvider = Provider<WorkshopRestoreDraft>((ref) {
  final directory = ref.watch(workshopDirectoryProvider);
  return (pending) async {
    // Revalidate before deriving a private path; no absolute path is persisted.
    final checked = WorkshopPendingSubmission.fromJson(pending.toJson());
    final root = await directory();
    final draft = Directory('${root.path}/exports/${checked.directoryName}');
    return WorkshopPreparedDraft(
      upload: WorkshopPreparedUpload(file: File('${draft.path}/archive.zip'),
        metadata: checked.metadata, files: checked.files),
      directoryName: checked.directoryName,
      cleanup: () async { if (await draft.exists()) await draft.delete(recursive: true); },
    )..retained = true;
  };
});
