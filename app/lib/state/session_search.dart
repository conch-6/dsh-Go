// Portions derived from DeepSeek Harness (https://github.com/deepseek-ai/deepseek-harness), MIT, Copyright (c) 2026 DeepSeek. See THIRD_PARTY_NOTICES.md.
//
// Session search: local title matches merged with the Host's ranked content
// hits, as DSH Web's sidebar search does (`deriveSearchResults`). Every term
// must match, in any order, ignoring case and width; archived sessions come
// last (the app has no archive view).

import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/services.dart' show TextEditingValue;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'connection_state.dart';
import 'sessions_state.dart';

/// One Host content hit: the session and a plain-text excerpt around the match.
typedef ContentHit = ({String sessionId, String snippet});

/// A half-open UTF-16 range `[start, end)` in the original text.
typedef MatchRange = ({int start, int end});

// ── Matching ─────────────────────────────────────────────────────────────────

/// [text] folded for matching, **same UTF-16 length** so offsets index the
/// original: letters lower-cased, full-width ASCII (Chinese IMEs in full-width
/// mode) mapped to half-width, the ideographic space to a plain space.
String foldForSearch(String text) {
  final units = text.codeUnits;
  final out = List<int>.filled(units.length, 0);
  for (var i = 0; i < units.length; i++) {
    var c = units[i];
    if (c >= 0xD800 && c <= 0xDBFF && i + 1 < units.length) {
      final next = units[i + 1];
      if (next >= 0xDC00 && next <= 0xDFFF) {
        // Cased letters above the BMP must be folded as a complete pair.
        final lower = text.substring(i, i + 2).toLowerCase();
        out[i] = lower.length == 2 ? lower.codeUnitAt(0) : c;
        out[++i] = lower.length == 2 ? lower.codeUnitAt(1) : next;
        continue;
      }
    }
    if (c >= 0xFF01 && c <= 0xFF5E) {
      c -= 0xFEE0;
    } else if (c == 0x3000) {
      c = 0x20;
    }
    if (c >= 0x41 && c <= 0x5A) {
      c += 0x20;
    } else if (c >= 0x80 && (c < 0xD800 || c > 0xDFFF)) {
      final lower = String.fromCharCode(c).toLowerCase();
      if (lower.length == 1) c = lower.codeUnitAt(0);
    }
    out[i] = c;
  }
  return String.fromCharCodes(out);
}

/// The folded, whitespace-separated terms of [query], without repeats.
List<String> searchTerms(String query) {
  final terms = <String>[];
  for (final term in foldForSearch(query).split(RegExp(r'\s+'))) {
    if (term.isNotEmpty && !terms.contains(term)) terms.add(term);
  }
  return terms;
}

/// Where any of [terms] (from [searchTerms]) occurs in [text], sorted and
/// with overlapping or touching ranges merged.
List<MatchRange> matchRanges(String text, List<String> terms) {
  if (text.isEmpty || terms.isEmpty) return const [];
  final folded = foldForSearch(text);
  final found = <MatchRange>[];
  for (final term in terms) {
    var from = 0;
    while (true) {
      final at = folded.indexOf(term, from);
      if (at < 0) break;
      found.add((start: at, end: at + term.length));
      from = at + term.length;
    }
  }
  if (found.isEmpty) return const [];
  found.sort((a, b) => a.start != b.start ? a.start.compareTo(b.start) : b.end.compareTo(a.end));
  final merged = <MatchRange>[found.first];
  for (final r in found.skip(1)) {
    final last = merged.last;
    if (r.start <= last.end) {
      if (r.end > last.end) merged[merged.length - 1] = (start: last.start, end: r.end);
    } else {
      merged.add(r);
    }
  }
  return merged;
}

/// Re-windows a Host snippet so its first match shows within two phone lines:
/// the Host centres the match about 80 characters in, so text more than
/// [lead] code units before it is replaced by "…" (never splitting a
/// surrogate pair). [ranges] come back shifted to the new text.
({String text, List<MatchRange> ranges}) excerptAround(String text, List<MatchRange> ranges, {int lead = 14}) {
  if (ranges.isEmpty || ranges.first.start <= lead + 1) return (text: text, ranges: ranges);
  var cut = ranges.first.start - lead;
  final unit = text.codeUnitAt(cut);
  if (unit >= 0xDC00 && unit <= 0xDFFF) cut--;
  // Start on the next word boundary when one is close (Latin text), else
  // mid-run (CJK has no spaces to wait for).
  final space = text.indexOf(' ', cut);
  if (space >= 0 && space - cut <= 8 && space < ranges.first.start - 1) cut = space + 1;
  final shift = cut - 1;
  return (
    text: '…${text.substring(cut)}',
    ranges: [for (final r in ranges) (start: r.start - shift, end: r.end - shift)],
  );
}

/// Last path segment of a session's working directory (`/root/workspace` →
/// `workspace`), or null without one.
String? folderLabel(String? cwd) {
  if (cwd == null) return null;
  final trimmed = cwd.replaceAll(RegExp(r'[/\\]+$'), '');
  if (trimmed.isEmpty) return cwd.isEmpty ? null : '/';
  final cut = trimmed.lastIndexOf(RegExp(r'[/\\]'));
  return trimmed.substring(cut + 1);
}

/// Same Host phrase, ignoring case and whitespace runs. Unlike local matching,
/// the Host distinguishes width and repeated words, so keep both in its key.
bool sameSearchQuery(String a, String b) {
  String key(String query) => query.toLowerCase().split(RegExp(r'\s+')).where((term) => term.isNotEmpty).join(' ');
  return key(a) == key(b);
}

// ── Results ──────────────────────────────────────────────────────────────────

class SessionSearchResult {
  const SessionSearchResult({required this.session, required this.archived, required this.byTitle, this.snippet});

  final SessionSummary session;
  final bool archived;

  /// Matched locally on its title (or folder); false = only the Host's
  /// message-content search found it.
  final bool byTitle;

  /// The Host's excerpt around the best content match.
  final String? snippet;
}

class SessionSearchResults {
  const SessionSearchResults({
    this.terms = const [],
    this.active = const [],
    this.archived = const [],
    this.showFolders = false,
  });

  static const empty = SessionSearchResults();

  /// Folded query terms, for highlighting.
  final List<String> terms;

  /// Sessions in the list: title matches newest first, then content-only hits
  /// in the Host's rank order.
  final List<SessionSearchResult> active;

  /// Archived sessions, same order.
  final List<SessionSearchResult> archived;

  /// The host's sessions live in more than one folder, so the folder both
  /// matches and is worth showing.
  final bool showFolders;

  bool get isEmpty => active.isEmpty && archived.isEmpty;
  int get length => active.length + archived.length;
}

/// Merges local title (and folder) matches of [query] with the Host's content
/// [hits]. [sessions] are the visible ones and [archived] the archived ones;
/// [hits] only count when [contentQuery] is the same search as [query], and a
/// hit for a session in neither list (blank, subagent, gone) is dropped.
SessionSearchResults deriveSessionSearchResults({
  required String query,
  required List<SessionSummary> sessions,
  List<SessionSummary> archived = const [],
  String contentQuery = '',
  List<ContentHit> hits = const [],
}) {
  final terms = searchTerms(query);
  if (terms.isEmpty) return SessionSearchResults.empty;
  final folders = {
    for (final s in [...sessions, ...archived]) folderLabel(s.cwd),
  };
  final showFolders = folders.length > 1;
  final snippets = <String, String>{};
  if (hits.isNotEmpty && sameSearchQuery(contentQuery, query)) {
    for (final hit in hits) {
      snippets.putIfAbsent(hit.sessionId, () => hit.snippet);
    }
  }

  List<SessionSearchResult> section(List<SessionSummary> members, bool isArchived) {
    final byId = {for (final s in members) s.sessionId: s};
    final local = <SessionSummary>[];
    for (final s in members) {
      final title = s.title?.trim() ?? '';
      final folder = showFolders ? folderLabel(s.cwd) ?? '' : '';
      final haystack = foldForSearch('$title\n$folder');
      if (terms.every(haystack.contains)) local.add(s);
    }
    local.sort((a, b) {
      final byTime = b.updatedAt.compareTo(a.updatedAt);
      return byTime != 0 ? byTime : a.sessionId.compareTo(b.sessionId);
    });
    final results = [
      for (final s in local)
        SessionSearchResult(session: s, archived: isArchived, byTitle: true, snippet: snippets[s.sessionId]),
    ];
    final included = {for (final s in local) s.sessionId};
    for (final MapEntry(key: id, value: snippet) in snippets.entries) {
      final s = byId[id];
      if (s == null || included.contains(id)) continue;
      results.add(SessionSearchResult(session: s, archived: isArchived, byTitle: false, snippet: snippet));
    }
    return results;
  }

  return SessionSearchResults(
    terms: terms,
    active: section(sessions, false),
    archived: section(archived, true),
    showFolders: showFolders,
  );
}

// ── Host content search ──────────────────────────────────────────────────────

/// The Host's message-content search for the active connection.
abstract interface class SessionContentSearch {
  Future<({List<ContentHit> items, bool hasMore})> search(String query);

  /// This host already said it has no content index; don't ask again.
  bool get knownUnsupported;
  void markUnsupported();
}

/// `session/search` on a [DshClient]. "No index" is remembered per client, so
/// typing on a host without content search costs one failed call, not one per
/// keystroke; a reconnect (new client) asks again.
class HostContentSearch implements SessionContentSearch {
  HostContentSearch(this.client);

  final DshClient client;

  static final _unsupported = Expando<bool>('sessionContentSearchUnsupported');

  @override
  bool get knownUnsupported => _unsupported[client] ?? !client.supportsEndpoint('session/search');

  @override
  void markUnsupported() => _unsupported[client] = true;

  @override
  Future<({List<ContentHit> items, bool hasMore})> search(String query) => client.searchSessionsPage(query);
}

/// Whether [error] means the Host has no content search at all (index off,
/// query service not mounted, method missing) rather than a passing failure.
bool isContentSearchUnsupported(Object error) {
  if (error is! DshRemoteException) return false;
  const codes = {'gateway/method-unavailable', 'gateway/service-unavailable', 'gateway/lookup-unavailable'};
  if (codes.contains(error.code)) return true;
  final message = error.message.toLowerCase();
  return message.contains('search is disabled') ||
      message.contains('search is unavailable') ||
      message.contains('search_disabled');
}

final sessionContentSearchProvider = Provider<SessionContentSearch?>((ref) {
  final client = ref.watch(
    activeConnectionProvider.select(
      (connection) => connection.isLoading || connection.hasError ? null : connection.value?.client,
    ),
  );
  return client == null ? null : HostContentSearch(client);
});

// ── Controller ───────────────────────────────────────────────────────────────

enum ContentSearchStatus {
  /// Nothing asked (empty query, or not connected).
  idle,

  /// Waiting out the debounce or the Host's answer.
  pending,
  ready,

  /// The host has no content index: titles only.
  unsupported,
  failed,
}

class SessionSearchState {
  const SessionSearchState({
    this.text = '',
    this.committed = '',
    this.composing = false,
    this.contentQuery = '',
    this.content = ContentSearchStatus.idle,
    this.hits = const [],
    this.hasMore = false,
  });

  /// Field text, including an IME composition in progress.
  final String text;

  /// [text] without the composing region.
  final String committed;

  /// An IME composition (pinyin, a Gboard word) is in progress.
  final bool composing;

  /// The trimmed query [content] and [hits] belong to.
  final String contentQuery;
  final ContentSearchStatus content;
  final List<ContentHit> hits;

  /// The Host cut its hit list (20 sessions).
  final bool hasMore;

  SessionSearchState copyWith({
    String? text,
    String? committed,
    bool? composing,
    String? contentQuery,
    ContentSearchStatus? content,
    List<ContentHit>? hits,
    bool? hasMore,
  }) => SessionSearchState(
    text: text ?? this.text,
    committed: committed ?? this.committed,
    composing: composing ?? this.composing,
    contentQuery: contentQuery ?? this.contentQuery,
    content: content ?? this.content,
    hits: hits ?? this.hits,
    hasMore: hasMore ?? this.hasMore,
  );
}

/// Drives one search page: local matching is instant (derived in
/// [sessionSearchViewProvider]); the Host's content search waits for a
/// 250 ms pause, never runs on an unfinished IME composition, and a newer
/// query always wins over a late answer.
class SessionSearchController extends Notifier<SessionSearchState> {
  /// Same as DSH Web's sidebar search.
  static const debounce = Duration(milliseconds: 250);

  /// The first search on a big history builds the Host's index; past this the
  /// footer offers a retry instead of spinning forever.
  static const timeout = Duration(seconds: 20);

  /// The Host refuses longer queries (`gateway/bad-request`).
  static const maxContentQueryLength = 500;

  Timer? _timer;
  int _generation = 0;

  @override
  SessionSearchState build() {
    ref.onDispose(() => _timer?.cancel());
    ref.listen(sessionContentSearchProvider, (_, _) {
      state = state.copyWith(content: ContentSearchStatus.idle, hits: const [], hasMore: false);
      if (state.composing) {
        // Retire the old Host's answer without submitting unfinished IME text.
        _timer?.cancel();
        ++_generation;
      } else {
        _schedule(state.text.trim());
      }
    });
    return const SessionSearchState();
  }

  void setInput(TextEditingValue value) {
    final range = value.composing;
    final composing = range.isValid && !range.isCollapsed && range.end <= value.text.length;
    if (value.text == state.text && composing == state.composing) return; // cursor / selection only
    final committed = composing ? range.textBefore(value.text) + range.textAfter(value.text) : value.text;
    state = state.copyWith(text: value.text, committed: committed, composing: composing);
    // Pinyin (or a half-typed word) is not a query yet; a request already on
    // its way for the committed text stays valid.
    if (!composing) _schedule(value.text.trim());
  }

  /// Asks the Host again after a failure.
  void retry() {
    if (state.content == ContentSearchStatus.failed) _schedule(state.contentQuery, force: true);
  }

  void _schedule(String query, {bool force = false}) {
    if (!force && sameSearchQuery(query, state.contentQuery) && state.content != ContentSearchStatus.idle) return;
    _timer?.cancel();
    final generation = ++_generation;
    final backend = ref.read(sessionContentSearchProvider);
    if (query.isEmpty || backend == null) {
      state = state.copyWith(contentQuery: query, content: ContentSearchStatus.idle, hits: const [], hasMore: false);
      return;
    }
    if (backend.knownUnsupported) {
      state = state.copyWith(
        contentQuery: query,
        content: ContentSearchStatus.unsupported,
        hits: const [],
        hasMore: false,
      );
      return;
    }
    if (query.length > maxContentQueryLength) {
      state = state.copyWith(contentQuery: query, content: ContentSearchStatus.ready, hits: const [], hasMore: false);
      return;
    }
    state = state.copyWith(contentQuery: query, content: ContentSearchStatus.pending, hits: const [], hasMore: false);
    if (force) {
      unawaited(_run(backend, query, generation));
    } else {
      _timer = Timer(debounce, () => unawaited(_run(backend, query, generation)));
    }
  }

  Future<void> _run(SessionContentSearch backend, String query, int generation) async {
    try {
      final page = await backend.search(query).timeout(timeout);
      if (!ref.mounted || generation != _generation) return;
      state = state.copyWith(content: ContentSearchStatus.ready, hits: page.items, hasMore: page.hasMore);
    } catch (error) {
      if (!ref.mounted || generation != _generation) return;
      if (isContentSearchUnsupported(error)) {
        backend.markUnsupported();
        state = state.copyWith(content: ContentSearchStatus.unsupported);
      } else {
        state = state.copyWith(content: ContentSearchStatus.failed);
      }
    }
  }
}

final sessionSearchProvider = NotifierProvider.autoDispose<SessionSearchController, SessionSearchState>(
  SessionSearchController.new,
);

// ── View ─────────────────────────────────────────────────────────────────────

/// Everything the search page shows for the current input.
class SessionSearchView {
  const SessionSearchView({
    this.query = '',
    this.results = SessionSearchResults.empty,
    this.content = ContentSearchStatus.idle,
    this.hasMore = false,
  });

  /// The query [results] are for (trimmed); empty = nothing typed yet.
  final String query;
  final SessionSearchResults results;

  /// Content search state for [query].
  final ContentSearchStatus content;

  /// The Host had more content hits than it returned.
  final bool hasMore;
}

/// Results for [state]. While an IME composition is in progress the full text
/// is tried first (Latin keyboards compose whole words); when that finds
/// nothing the committed text stands in, so pinyin never flashes "no match".
SessionSearchView buildSessionSearchView(
  SessionSearchState state, {
  required List<SessionSummary> sessions,
  List<SessionSummary> archived = const [],
}) {
  SessionSearchView viewFor(String text) {
    final query = text.trim();
    final sameQuery = sameSearchQuery(query, state.contentQuery);
    final content = switch (state.content) {
      ContentSearchStatus.unsupported => ContentSearchStatus.unsupported,
      _ when query.isEmpty => ContentSearchStatus.idle,
      final status when sameQuery => status,
      // Typed past the last request: one is about to go out, unless the
      // newest text is still being composed.
      _ => state.composing ? ContentSearchStatus.idle : ContentSearchStatus.pending,
    };
    return SessionSearchView(
      query: query,
      results: deriveSessionSearchResults(
        query: query,
        sessions: sessions,
        archived: archived,
        contentQuery: state.contentQuery,
        hits: sameQuery ? state.hits : const [],
      ),
      content: content,
      hasMore: sameQuery && state.hasMore,
    );
  }

  final full = viewFor(state.text);
  if (!state.composing || !full.results.isEmpty) return full;
  return viewFor(state.committed);
}

final sessionSearchViewProvider = Provider.autoDispose<SessionSearchView>((ref) {
  final state = ref.watch(sessionSearchProvider);
  final sessions = ref.watch(sessionsProvider).value ?? const <SessionSummary>[];
  final archived = ref.read(sessionsProvider.notifier).archivedSessions;
  return buildSessionSearchView(state, sessions: sessions, archived: archived);
});

/// Restores an archived session on the active host (it comes back in the list
/// through the workspace stream; the refresh only makes that immediate).
Future<void> unarchiveSession(WidgetRef ref, String sessionId) async {
  await ref.read(sessionsProvider.notifier).unarchive(sessionId);
}
