// The tavern's surface for the app (docs/design/roleplay.md §4): what the
// screens read and call. The engine behind it — card IO, the chat store, the
// prompt assembler, the model client — implements [Tavern]; the app holds one
// and never reaches past it.
//
// Pure Dart, no Flutter. Everything here is value types and one interface, so
// the app can be built against a fake before the engine lands.

import 'dart:typed_data';

import 'backup.dart';
import 'director.dart';
import 'import_report.dart';
import 'inspection.dart';
import 'lorebook_library.dart';
import 'persona.dart';
import 'preset_library.dart';
import 'regex_library.dart';
import 'state.dart';
import 'worldinfo/world_info.dart' show WorldInfoSource;

enum PresetSelectionSource { chat, chatInline, globalDefault, globalInline, stDefault }

/// Selection for a newly admitted turn. Missing legacy ids fall through to
/// the next complete preset without rewriting the stored chat binding.
class TavernPresetSelection {
  const TavernPresetSelection({
    required this.source,
    required this.boundPresetId,
    required this.defaultPresetId,
    required this.effectivePresetId,
    this.missingPresetIds = const [],
  });
  final PresetSelectionSource source;
  final String? boundPresetId;
  final String? defaultPresetId;
  final String? effectivePresetId;
  final List<String> missingPresetIds;
}

/// One character in the library: the card's V3 `data` plus what the library
/// knows about it.
class TavernCharacter {
  const TavernCharacter({
    required this.id,
    required this.name,
    this.nickname,
    this.creator,
    this.tags = const [],
    this.avatarPath,
    this.theme,
    this.assets = const [],
    this.description = '',
    this.creatorNotes = '',
    this.greetings = const [],
    this.regexCount = 0,
    this.scriptCount = 0,
    this.hasLorebook = false,
    this.chatCount = 0,
    this.lastChatAt,
    this.importedAt,
    this.regexDiagnostics = const [],
  });

  final String id;
  final String name;
  final String? nickname;
  final String? creator;
  final List<String> tags;

  /// The card picture on this phone (the PNG it came in, or the `main` icon).
  final String? avatarPath;

  /// Detached extensions.dshgo.theme on complete details. Missing/null stays
  /// null; list summaries omit it. The app interprets this raw JSON value.
  final Object? theme;

  /// Declared V3 asset objects in original order on complete details. Summary
  /// lists leave this empty; call character(id) for appearance and local paths.
  /// Non-object declarations stay in characterFields, but not this view.
  final List<TavernCharacterAsset> assets;
  final String description;

  /// May carry HTML; the canvas renders it.
  final String creatorNotes;

  /// `first_mes` first, then `alternate_greetings`.
  final List<String> greetings;

  /// The card's own regex scripts and 酒馆助手 scripts (roleplay-compat.md §6.1).
  final int regexCount;
  final int scriptCount;
  final bool hasLorebook;

  final int chatCount;
  final DateTime? lastChatAt;
  final DateTime? importedAt;

  /// Checks returned by a new import. Unified persistent intake reports are
  /// separate; reading an older library entry need not populate this.
  final List<TavernRegexDiagnostic> regexDiagnostics;
}

/// One declared V3 asset. Missing or non-string fields are null in this view;
/// the original card JSON is retained unchanged by the library.
class TavernCharacterAsset {
  const TavernCharacterAsset({this.type, this.name, this.uri, this.ext, this.localPath});

  final String? type;
  final String? name;

  /// The original URI, including an unchanged remote URL or embedded reference.
  final String? uri;
  final String? ext;

  /// A resolved local file path when the library has materialized this asset.
  /// A missing reference or remote URL has no local path; URI reads never
  /// download remote resources or rewrite the stored declaration.
  final String? localPath;
}

/// A conversation in the list.
class TavernChatSummary {
  const TavernChatSummary({
    required this.id,
    required this.characterId,
    required this.title,
    required this.updatedAt,
    this.lastText,
    this.messageCount = 0,
  });

  final String id;
  final String characterId;
  final String title;
  final DateTime updatedAt;

  /// The last message on the current path, plain text, for a preview line.
  final String? lastText;
  final int messageCount;
}

enum TavernRole { user, character, narrator, system }

/// One message on the current path. Alternatives are siblings in the tree
/// (roleplay.md §5.2): [siblingIndex] of [siblingCount].
class TavernMessage {
  const TavernMessage({
    required this.nodeId,
    required this.role,
    required this.speaker,
    required this.text,
    required this.at,
    this.parentId,
    this.reasoning,
    this.siblingIndex = 0,
    this.siblingCount = 1,
    this.hidden = false,
    this.usage,
    this.reportedUsage,
  });

  final String nodeId;
  final String? parentId;
  final TavernRole role;

  /// Display name: the character's or the persona's.
  final String speaker;

  /// The stored text (after write-back regex). Use displayText for an ephemeral
  /// display-regex copy; Markdown rendering remains the caller's responsibility.
  final String text;
  final String? reasoning;
  final DateTime at;
  final int siblingIndex;
  final int siblingCount;

  /// Kept out of the prompt (ST `/hide`).
  final bool hidden;
  final TavernUsage? usage;

  /// Provider usage for this node's latest recorded generation, without
  /// rebuilding its full inspection. Null means that call reported none;
  /// it is not replaced with estimates or a continued message's older usage.
  /// A live path/snapshot uses the current call's report, if already received.
  final TavernUsage? reportedUsage;
}

/// One stored node in the complete message tree, including inactive branches.
/// Soft-deleted nodes are excluded; ST-hidden nodes remain in the tree.
/// Values are detached from storage; reading them never evaluates macros.
class TavernTreeNode {
  const TavernTreeNode({
    required this.nodeId,
    required this.role,
    required this.speaker,
    required this.preview,
    required this.at,
    required this.isCurrentPath,
    this.parentId,
    this.siblingIndex = 0,
    this.siblingCount = 1,
    this.hidden = false,
    this.branchName,
  });

  final String nodeId;
  final String? parentId;
  final TavernRole role;
  final String speaker;

  /// The first 64 Unicode code points of the stored text, without stripping
  /// whitespace, Markdown or macros. This never splits a surrogate pair.
  final String preview;
  final DateTime at;

  /// Whether this node is an ancestor of, or is, the current selected leaf.
  /// Hidden messages may still belong to the current path.
  final bool isCurrentPath;
  final int siblingIndex;
  final int siblingCount;
  final bool hidden;

  /// An optional label for the branch starting at this node.
  final String? branchName;
}

/// What one model call cost, as the API reported it.
class TavernUsage {
  const TavernUsage({this.promptTokens = 0, this.cacheHitTokens = 0, this.completionTokens = 0, this.model});

  final int promptTokens;
  final int cacheHitTokens;
  final int completionTokens;
  final String? model;
}

/// A turn as it streams. A turn always ends with exactly one [TavernTurnDone]
/// or [TavernTurnFailed].
sealed class TavernEvent {
  const TavernEvent();
}

/// First event when reconnecting to an active turn. This is the complete
/// in-memory body at subscription time, including uncheckpointed text.
class TavernTurnSnapshot extends TavernEvent {
  const TavernTurnSnapshot({required this.chatId, required this.generationType, required this.startedAt, this.message});

  final String chatId;
  final String generationType;
  final DateTime startedAt;

  /// Null while preparing the request, before a reply node exists. Later
  /// TavernTurnStarted supplies it. Impersonation has a temporary user node.
  final TavernMessage? message;
}

/// The node the reply is written into exists (a new one, or a new sibling).
class TavernTurnStarted extends TavernEvent {
  const TavernTurnStarted(this.message);

  /// Empty for a new reply; continuation retains its existing body. Carries
  /// the node id and its place among siblings.
  final TavernMessage message;
}

class TavernTextDelta extends TavernEvent {
  const TavernTextDelta(this.nodeId, this.text);
  final String nodeId;
  final String text;
}

class TavernReasoningDelta extends TavernEvent {
  const TavernReasoningDelta(this.nodeId, this.text);
  final String nodeId;
  final String text;
}

class TavernTurnDone extends TavernEvent {
  const TavernTurnDone(this.message, {this.finishReason});

  /// As stored: write-back regex applied, usage filled in.
  final TavernMessage message;

  /// The provider's finish_reason, including length or content_filter. Null
  /// means the transport did not report one; unknown future values are kept.
  final String? finishReason;
}

enum TavernFailure {
  noKey,
  badKey,
  busy,
  network,
  server,
  contextTooLong,
  cancelled,
  invalidCard,
  insufficientBalance,
  invalidParameters,
}

class TavernTurnFailed extends TavernEvent {
  const TavernTurnFailed(this.kind, {this.detail, this.partial});
  final TavernFailure kind;

  /// For 「详情」: a status code, the first part of an error body.
  final String? detail;

  /// Whatever arrived before it failed or was stopped; null when nothing was
  /// stored (the user's line goes back into the composer).
  final TavernMessage? partial;
}

enum TavernCardFormat { png, json, charx }

/// A named ST JSONL document. The filename is a label, never a path to read.
/// Bytes are copied at construction and cannot be changed through this value.
final class TavernChatFile {
  TavernChatFile({required this.fileName, required Uint8List bytes})
    : bytes = Uint8List.fromList(bytes).asUnmodifiableView();

  final String fileName;
  final Uint8List bytes;
}

/// One atomic batch may contain several independent chats and their branches.
final class TavernChatImportResult {
  TavernChatImportResult({
    required List<String> chatIds,
    required Map<String, String> chatsByFile,
    required List<String> notices,
  }) : chatIds = List<String>.unmodifiable(chatIds),
       chatsByFile = Map<String, String>.unmodifiable(chatsByFile),
       notices = List<String>.unmodifiable(notices);

  final List<String> chatIds;
  final Map<String, String> chatsByFile;
  final List<String> notices;
}

/// Where the model calls go. The key is read through [apiKey] each call, so
/// the app keeps it in secure storage and the engine never stores it.
class TavernModelConfig {
  const TavernModelConfig({
    required this.apiKey,
    this.baseUrl = 'https://api.deepseek.com',
    this.model = 'deepseek-flash',
    this.deepseek = true,
    this.thinking = false,
  });

  final Future<String?> Function() apiKey;
  final String baseUrl;
  final String model;

  /// DeepSeek's own API: ST's DeepSeek post-processing and `/beta` prefix
  /// continuation (roleplay-compat.md §3.4). False: a plain OpenAI-compatible
  /// endpoint.
  final bool deepseek;
  final bool thinking;
}

/// The tavern. One per app; [open] it on the app's support directory.
abstract interface class Tavern {
  // Library ------------------------------------------------------------------

  /// The saved capability snapshot, or null for a missing/legacy asset.
  /// Reading compares the current inspection-input fingerprint with the saved
  /// fingerprint. Restoring a match can make stale false; checkedAt and findings
  /// still describe the saved snapshot. Explicit rechecking and
  /// updateRegexScript refresh it; reading does not run compatibility work.
  Future<TavernImportReport?> readImportReport(TavernImportKind kind, String assetId);

  /// Explicitly inspects the current asset, including legacy imports, and
  /// atomically replaces its report. No macros or embedded scripts execute.
  /// Regex rechecks also refresh compatibility diagnostics used by subsequent
  /// executions; the user's original data and disabled flag are not changed.
  Future<TavernImportReport> recheckImport(TavernImportKind kind, String assetId);

  /// Character summaries, newest chat first, then newest import. Emits the
  /// current list first. Reads the library index, not card bodies or assets.
  /// Name, nickname, creator, tags, avatar path, counts and dates are included;
  /// description, greetings, creatorNotes and regexDiagnostics are empty.
  /// Use [character] for full card details.
  Stream<List<TavernCharacter>> watchCharacters();

  /// Loads one character's full details, including greetings and creatorNotes.
  Future<TavernCharacter?> character(String id);

  /// The complete V3 `data` object, including read-only unknown fields. The
  /// returned map is detached: editing it does not change the stored card.
  /// Optional fields may be absent. Null means the character does not exist.
  Future<Map<String, Object?>?> characterFields(String characterId);

  /// Saves only the supplied fields, retaining the rest of the card and all
  /// original assets. Editable strings: `name`, `nickname`, `description`,
  /// `personality`, `scenario`, `first_mes`, `mes_example`, `system_prompt`,
  /// `post_history_instructions`, `creator_notes`, `creator`,
  /// `character_version`. `alternate_greetings` and `tags` are string lists.
  ///
  /// Empty strings/lists clear a field; null and other keys/types throw
  /// [ArgumentError]. A nonempty patch updates V3 `modification_date` in Unix
  /// seconds. An empty patch is a read. Missing characters throw
  /// [TavernImportError]. Existing messages keep their text and speaker names.
  Future<TavernCharacter> updateCharacterFields(String characterId, Map<String, Object?> fields);

  /// Appends an entry to the card's V3 character_book, creating the book when
  /// absent. The library assigns an unused id; supplying an id is rejected.
  /// Unknown stored fields and original assets remain intact. Input JSON is
  /// captured before waiting. Existing missing/null ids are fixed to their
  /// fallback index; normalizing a null id can invalidate that entry's timers.
  Future<TavernCharacter> addCharacterBookEntry(String characterId, Map<String, Object?> entry);

  /// Patches the entry at its original entries-array [index], not its sorted
  /// display position or id. Extensions merge recursively; an id patch is
  /// rejected. Invalid indices throw [RangeError]. An empty patch is a read;
  /// real edits normalize missing/null ids as [addCharacterBookEntry] does.
  Future<TavernCharacter> updateCharacterBookEntry(String characterId, int index, Map<String, Object?> fields);

  /// Removes only this entry from the original entries array. Missing/null ids are
  /// fixed to their pre-edit fallback indices so later entries keep identity.
  /// Native ST entries objects remain readable but are not edited by this API.
  Future<TavernCharacter> deleteCharacterBookEntry(String characterId, int index);

  /// Tests this card's embedded book against [text], optionally following the
  /// current path of this character's [chatId]. Returns a detached WI trace
  /// with scope, stage, seed and context identifiers; no model is called.
  ///
  /// Macros, regex, probability and normal timer/decorator rules evaluate on
  /// copied state with an independent seeded RNG. Nothing is stored, including
  /// variables and inspections. Other bound books and full-prompt trimming are
  /// outside this preview, so it is not a promise about the next real request.
  Future<Map<String, Object?>> previewCharacterBook(String characterId, String text, {String? chatId, int seed = 0});

  /// A PNG / JSON / CHARX card (sniffed from the bytes, not the name), or an
  /// ST lorebook JSON (then it throws [TavernImportError] with
  /// [TavernImportError.isLorebook]; use importLorebook for those files).
  Future<TavernCharacter> importCard(Uint8List bytes, {String? fileName});

  Future<Uint8List> exportCard(String characterId, {TavernCardFormat format = TavernCardFormat.png});

  /// Its chats go with it.
  Future<void> deleteCharacter(String characterId);

  // User personas ------------------------------------------------------------

  /// Saved personas, with the current committed list emitted first. Default
  /// and chat-binding changes also notify selectors through this stream.
  Stream<List<TavernPersona>> watchPersonas();

  Future<TavernPersona?> persona(String personaId);

  /// The optional avatar is a caller-owned file reference. Persona text is
  /// saved as entered; macros run only in the normal generation pipeline.
  /// Only position 0 currently injects the personaDescription prompt marker.
  Future<TavernPersona> createPersona({
    required String name,
    String description = '',
    String? avatarPath,
    int descriptionPosition = PersonaDescriptionPosition.inPrompt,
  });

  /// Null means unchanged; empty text is a real change. Use [clearAvatar] to
  /// remove an avatar reference. Active turns retain their captured persona.
  Future<TavernPersona> updatePersona(
    String personaId, {
    String? name,
    String? description,
    String? avatarPath,
    bool clearAvatar = false,
    int? descriptionPosition,
  });

  /// Cancels affected turns before removing the profile, default and matching
  /// chat bindings. Partial output and old messages remain; avatar files stay.
  Future<void> deletePersona(String personaId);

  /// Without [chatId], selects the global default. With it: chat binding,
  /// then global default, then no profile. This read never runs macros.
  Future<PersonaSelection> personaSelection({String? chatId});

  /// Null clears the default. Changes take effect on the next turn.
  Future<void> setDefaultPersona(String? personaId);

  /// Null restores inheritance from the global default. Cancels and waits for
  /// this chat's current turn before changing its binding.
  Future<void> bindPersona(String chatId, String? personaId);

  // Chats --------------------------------------------------------------------

  /// Newest first; all characters when [characterId] is null.
  Stream<List<TavernChatSummary>> watchChats({String? characterId});

  /// A new chat whose first message is greeting [greeting] (0 = `first_mes`).
  Future<String> createChat(String characterId, {int greeting = 0});

  /// Imports a same-character batch without adding greetings or evaluating
  /// macros. Related main_chat files become branches; unrelated files remain
  /// separate chats. A malformed document rejects the whole batch.
  ///
  /// [lorebookIds] maps ST world_info names to existing local lorebook IDs.
  /// Unmapped names remain in the exported header and produce a notice.
  Future<TavernChatImportResult> importChats(
    String characterId,
    List<TavernChatFile> files, {
    Map<String, String> lorebookIds = const {},
  });

  /// Exports the current path first, then the other stored branches. Each
  /// document has a fresh integrity UUID. Reading during a turn does not stop
  /// generation; only the state already committed to storage is included.
  Future<List<TavernChatFile>> exportChat(String chatId, {String? fileName});

  Future<void> deleteChat(String chatId);

  /// The current path, oldest first: the last [limit] messages, or the
  /// [limit] before [beforeNodeId] when paging back.
  Future<List<TavernMessage>> path(String chatId, {int limit = 60, String? beforeNodeId});

  /// Every visible stored node in insertion order, including inactive
  /// descendants and ST-hidden messages. Soft-deleted nodes are excluded.
  /// Previews use the saved body/checkpoint, not uncheckpointed live buffers;
  /// this read does not cancel an active turn.
  Future<List<TavernTreeNode>> tree(String chatId);

  /// A detached copy of the current leaf's saved local variables. An empty
  /// selected path has an empty snapshot. Does not expose uncommitted live
  /// macro effects, mutate state, or cancel a turn; global variables are separate.
  Future<Map<String, Object?>> readVariables(String chatId);

  /// The selected leaf's saved DSH state and raw schema, or saved ST local
  /// variables for cards without a schema. Reading has no state side effects.
  Future<TavernStateSnapshot> readState(String chatId);

  /// Sets a JSON Pointer on the selected leaf through user permissions and
  /// the same validator/rules as model updates. An empty pointer means root.
  /// An empty selected chat path is rejected. [expectedNodeId], when supplied,
  /// protects an editor against a changed selection after cancelling a turn.
  Future<TavernStateEditResult> setStateValue(String chatId, String path, Object? value, {String? expectedNodeId});

  /// Most recent persistent state/agent execution records, newest first.
  /// An explicit node filter excludes records whose node was permanently deleted.
  Future<List<TavernAgentRun>> readAgentRuns(String chatId, {String? nodeId, int limit = 50});

  /// Fires whenever the current path changes (a turn, a swipe, an edit) so the
  /// screen re-reads [path].
  Stream<void> pathChanges(String chatId);

  /// The recorded request for a node, or the chat's latest admitted attempt
  /// when [nodeId] is omitted. Reading never repeats macros, WI or assembly.
  /// Missing/deleted records return null. Branch selection does not change
  /// which attempt is latest. Ephemeral/empty failed attempts have no node.
  /// Estimates and this call's provider-reported usage are separate fields.
  Future<TavernTurnInspection?> inspectTurn(String chatId, {String? nodeId});

  /// Recomputes from original text or a stored node. No display result, macro
  /// variable or random state is persisted. A node plus text supplies the latest
  /// complete stream. With no node this is the chat's single live-text channel
  /// for each reasoning flag. Ignore results marked superseded by a newer call.
  /// Hidden messages still run display regex, but do not count toward automatic
  /// depth. Only system messages named "SillyTavern System" bypass; this is the
  /// default speaker for raw system text. Raw text has no inferred depth. Supply
  /// a speaker for custom raw narration so trim macros receive its display name.
  Future<TavernDisplayResult> displayText(
    String chatId, {
    String? nodeId,
    String? text,
    TavernRole? role,
    String? speaker,
    num? depth,
    bool reasoning = false,
  });

  // Turns --------------------------------------------------------------------

  /// Appends [text] as the user's message and streams the character's reply.
  /// Empty [text]: the character speaks next without a new user line.
  /// Listening admits the turn. Cancelling a turn-stream subscription only
  /// detaches that observer; generation continues until completion or [stop].
  Stream<TavernEvent> send(String chatId, String text);

  /// Appends a visible user message without requesting a reply. Applies input
  /// write-back regex and then macros, preserving leading/trailing whitespace
  /// and an empty result. The speaker is the selected persona's user name.
  ///
  /// Cancels and awaits this chat's active turn first. Runs only the input
  /// stage, without separate card-field/WI/prompt preparation or a model
  /// request, and keeps the previous turn inspection. Legacy macro evaluation
  /// retains its existing eager card-field reads. Local variables commit with
  /// the message.
  /// Changed global variables save before that atomic commit; preparation
  /// failure still saves global effects that already occurred. A failed
  /// global save does not append this message.
  Future<TavernMessage> sendOnly(String chatId, String text);

  /// Appends a visible narrator message using JavaScript trim and then macros,
  /// without slash-command regex. Explicit [speaker], including an empty
  /// string, wins; otherwise uses a nonempty metadata narrator_name or System.
  /// Uses [sendOnly]'s cancellation, state and persistence rules.
  ///
  /// This is the direct narrator handler's text stage, not a slash parser:
  /// bias, insertion-position, compact and avatar arguments are not evaluated.
  Future<TavernMessage> narrate(String chatId, String text, {String? speaker});

  /// A new reply as a sibling of [nodeId] (a character message), which becomes
  /// current.
  Stream<TavernEvent> regenerate(String chatId, String nodeId);

  /// More text at the end of [nodeId] (ST 「继续」).
  Stream<TavernEvent> continueReply(String chatId, String nodeId);

  /// Writes the user's next line for them (ST impersonate); not stored.
  Stream<TavernEvent> impersonate(String chatId);

  /// Observes the turn active when this stream is listened to. The first
  /// event is a [TavernTurnSnapshot], followed by only subsequent deltas and
  /// its single terminal event. Snapshot and observer registration have no
  /// asynchronous gap. Multiple observers are independent; cancellation
  /// never stops the turn. There is no event-history buffer.
  ///
  /// If no turn is active, closes without events; read [path]/[inspectTurn]
  /// for persisted results. Reconnection is within this engine's lifetime,
  /// not a resumable HTTP request after process termination.
  Stream<TavernEvent> resumeTurn(String chatId);

  /// Stops whatever turn [chatId] is running. Its stream ends with
  /// [TavernTurnFailed] `cancelled`, keeping what arrived.
  void stop(String chatId);

  // Editing the tree -----------------------------------------------------------

  /// Makes sibling [index] of [nodeId] current (and its subtree's remembered
  /// path below it).
  Future<void> selectSibling(String chatId, String nodeId, int index);

  /// Selects any visible node in this chat, cancelling and awaiting its active
  /// turn first. By default the path stops exactly at [nodeId]: its first
  /// selected child edge is persistently cleared, without deleting descendants.
  /// With [restoreDescendants], follows the path currently remembered beneath
  /// the node; this does not reconstruct an edge cleared by an earlier stop.
  /// Selection and restoration of the chosen leaf's variables are atomic.
  /// ST-hidden messages remain selectable; soft-deleted messages do not.
  Future<void> selectNode(String chatId, String nodeId, {bool restoreDescendants = false});

  /// Labels a visible branch root in extra.dshgo.branchName. Trims the name;
  /// null/empty clears it. Cancels and awaits this chat's active turn before
  /// merging the latest extra. Does not rewrite text or selected edges.
  Future<void> nameBranch(String chatId, String nodeId, String? name);

  /// Permanently removes only this visible node and reparents all its children,
  /// including pending soft-deleted children. Their identities and snapshots
  /// survive. Unlike deleteFrom this does not delete a subtree or return an
  /// undo token. Cancels and awaits the chat's active turn first.
  Future<void> deleteMessage(String chatId, String nodeId);

  Future<void> edit(String chatId, String nodeId, String text);

  /// Hides [nodeId] and its whole subtree, returning an undo token. Data is
  /// physically removed the next time the store is opened. Existing callers
  /// may ignore the token; implementations must forward the returned String.
  Future<String> deleteFrom(String chatId, String nodeId);

  /// Restores this deletion during the same open-store lifetime. Restores
  /// the old selection only if no later tree operation has changed it;
  /// otherwise restores the branch without replacing the current path.
  /// False means unknown/consumed token or an ancestor is still soft-deleted.
  Future<bool> undoDeleteFrom(String chatId, String deletionId);

  /// Literal substring search across this chat's visible branches, newest
  /// first. Matches body/speaker, including Chinese; %, _ and backslash are
  /// literal. Pending streaming bodies and soft-deleted nodes are excluded.
  Future<List<TavernMessage>> searchChat(String chatId, String query, {int limit = 50});

  Future<void> setHidden(String chatId, String nodeId, bool hidden);

  // Presets ------------------------------------------------------------------

  Future<List<TavernPresetSummary>> listPresets();
  Stream<List<TavernPresetSummary>> watchPresets();
  Future<TavernPreset?> preset(String presetId);

  /// Saves without selecting. Original text and unknown fields are retained;
  /// validation issues identify the precise prompt and JSON path.
  Future<TavernPresetImportResult> importPreset(String text, {String? fileName});

  /// Merges objects and replaces arrays/scalars in the current ST document.
  /// Sampling keys use their native ST names. The original source is unchanged.
  /// Name is a library label; package metadata is synchronized when present.
  /// For plain ST exports the caller chooses the corresponding file name.
  /// extensions.dshgo.presetEnvelope is an export-owned carrier; edits that
  /// change it are rejected, so an opaque wrapper cannot be silently lost.
  Future<TavernPresetImportResult> updatePreset(String presetId, Map<String, Object?> patch, {String? name});
  Future<TavernPresetImportResult> updatePresetPrompt(String presetId, String identifier, Map<String, Object?> patch);

  /// Reorders the first 100001 group's complete list. Existing entry fields
  /// survive; new entries start enabled. Omitted identifiers leave this group.
  Future<TavernPresetImportResult> setPresetOrder(String presetId, List<String> identifiers);
  Future<TavernPresetImportResult> setPresetPromptEnabled(String presetId, String identifier, bool enabled);

  /// Native ST JSON, with preserved project data under extensions.dshgo.
  Future<String> exportPreset(String presetId);
  Future<TavernPresetSelection> presetSelection({String? chatId});
  Future<void> setDefaultPreset(String? presetId);

  /// Clears the legacy inline chat preset. Null restores default inheritance;
  /// this differs from setSettings({'preset': null}), which selects ST defaults.
  Future<void> bindPreset(String chatId, String? presetId);

  /// Deletes the library record and clears its bindings/default atomically.
  /// Independently stored legacy inline settings remain a fallback; deletion
  /// of a generated legacy record does not erase that separate configuration.
  Future<void> deletePreset(String presetId);

  // Managed global regex scripts --------------------------------------------

  /// This imported collection follows legacy inline global rules in settings,
  /// and precedes preset and character scripts.
  Future<List<TavernRegexScript>> listRegexScripts();
  Future<TavernRegexImportResult> importRegexScripts(String text);

  /// Edits the current ST raw object in place, retaining its internal id, order,
  /// original sourceText and importedAt. The payload's raw id remains editable.
  /// Captures a JSON deep copy of patch at call time, then merges into the latest
  /// committed raw in the library queue. Objects merge recursively; arrays,
  /// scalars and null replace, while omitted fields remain.
  /// Refreshes compatibility diagnostics and the import report without expanding
  /// macros. Incompatible raw remains saved but is disabled in execution views.
  /// Await publication before starting work that must use the edited rules;
  /// existing messages and already captured execution views are unchanged.
  Future<TavernRegexScript> updateRegexScript(String regexId, Map<String, Object?> patch);
  Future<TavernRegexScript> setRegexEnabled(String regexId, bool enabled);
  Future<void> deleteRegex(String regexId);

  /// One native ST object when id is given; otherwise the ordered array.
  Future<String> exportRegex({String? regexId});

  // Independent world books -------------------------------------------------

  Future<List<TavernLorebookSummary>> listLorebooks();

  /// Keeps a supplied filename (without .json) as native timer identity,
  /// separately from the raw display title. An active imported chat mapping
  /// can supply its own exact ST name. Raw read/export omit local metadata.
  Future<TavernLorebookImportResult> importLorebook(String text, {String? fileName});
  Future<Map<String, Object?>?> lorebook(String id);
  Future<void> putLorebook(String id, Map<String, Object?> json);
  Future<String> exportLorebook(String id);

  /// Retains source bindings. Future turns diagnose and skip the missing id;
  /// an already captured book remains usable.
  Future<void> deleteLorebook(String id);

  /// Empty ids clears this binding. Character/persona identity scopes use their
  /// matching source. chatId can also override a legacy global source. Missing
  /// ids remain and are diagnosed when a turn loads them.
  Future<void> bindLorebooks(
    List<String> ids, {
    WorldInfoSource source = WorldInfoSource.global,
    String? chatId,
    String? characterId,
    String? personaId,
  });

  // Settings -----------------------------------------------------------------

  /// Where model calls go from now on.
  void configure(TavernModelConfig config);

  /// A detached effective settings snapshot: global, imported source, then
  /// explicit chat settings. Reading does not evaluate macros or world info.
  /// managedRegexScripts is a read-only library projection; settings cannot
  /// override it or add a second copy of the imported collection.
  Future<Map<String, Object?>> readSettings({String? chatId});

  /// Recursively merges objects; arrays/scalars replace their previous values.
  /// Null is a stored value, not a deletion. Chat changes cancel and await its
  /// active turn. Global changes apply to turns admitted after this call.
  /// presetOverrides overlays only temperature/top_p/presence_penalty/
  /// frequency_penalty/openai_max_tokens/openai_max_context after selection.
  /// Legacy global patches containing preset write settings.json before the
  /// SQLite selection; a second-step failure leaves the file change committed.
  Future<void> setSettings(Map<String, Object?> patch, {String? chatId});

  /// Latest successful director output and the latest attempt are separate.
  /// Notes are marked spoilers; stale branch results remain readable but are
  /// not injected into a main turn. The optional story view reads the selected
  /// branch's saved progress independently of the helper. Optional eventRules
  /// exposes that branch's fixed-card event ledger and literal prompt queue.
  /// Reading never calls a model, executes handlers or advances chapters.
  Future<TavernDirectorSnapshot> readDirector(String chatId);

  /// Initial snapshot, then independent background completion/failure updates.
  /// Cancelling this subscription does not stop a helper or a main turn.
  Stream<TavernDirectorSnapshot> watchDirector(String chatId);

  /// One explicit helper invocation, even when automatic directing is off.
  /// Returns busy during a main generation or tree mutation, without cancelling
  /// or waiting for it. The source is saved context, never streaming buffers.
  Future<TavernDirectorRun> runDirector(String chatId);

  /// Pending proposals, newest first by publication order. Pass the last id
  /// as beforeEventId for the next page. A proposal remains globally pending;
  /// branch-local fixed-card execution is recorded separately in eventRules.
  /// A malformed/unsupported row retains its id with available=false and null
  /// payload, so it neither invents a proposal nor hides valid neighboring rows.
  Future<List<TavernDirectorEvent>> readDirectorEvents(String chatId, {int limit = 50, String? beforeEventId});

  /// Creates a complete ZIP at [destinationPath], outside this data root.
  /// Active turns or another backup return busy. New operations are rejected
  /// only while the stable database/files snapshot is being captured; normal
  /// work may resume while that independent snapshot is compressed.
  /// Restore uses restoreTavernDirectory after closing the target engine.
  Future<TavernBackupInfo> backup(String destinationPath);

  Future<void> close();
}

class TavernImportError implements Exception {
  const TavernImportError(this.message, {this.isLorebook = false});
  final String message;
  final bool isLorebook;

  @override
  String toString() => 'TavernImportError: $message';
}
