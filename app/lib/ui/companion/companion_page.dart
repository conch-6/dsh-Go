// 伙伴小屋: a whole page for the companion (docs/design/companion.md). She fills
// the screen in a WebView; on top of it, in Flutter, her words and a small input.
// Touches are answered on the spot without a model call. Talking goes, in full
// mode, through an ordinary session on the active host (companion_state.dart);
// in light mode, straight from the phone to the model (companion_light.dart).

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:dsh_client/dsh_client.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../companion/companion_adapt.dart';
import '../../companion/companion_bond.dart';
import '../../companion/companion_initiative.dart';
import '../../companion/companion_initiative_owner.dart';
import '../../companion/companion_keeper.dart';
import '../../companion/companion_moves.dart';
import '../../companion/companion_light.dart';
import '../../companion/companion_pack.dart';
import '../../companion/companion_reply.dart';
import '../../companion/companion_state.dart';
import '../../companion/companion_voice.dart';
import '../../companion/companion_voice_source.dart';
import '../../companion/companion_widget.dart';
import '../../l10n/l10n.dart';
import '../../pets/pet_mood.dart' show PetEvent, PetEventKind;
import '../../pets/pet_signals.dart' show petEventBusProvider;
import '../../pets/pet_state.dart';
import '../../state/chat_state.dart';
import '../../state/connection_state.dart';
import '../../state/hosts_state.dart';
import '../../state/sessions_state.dart';
import '../../state/settings_state.dart';
import '../../state/voice_model_state.dart';
import '../../state/voice_settings.dart';
import '../../state/voice_state.dart';
import '../chat/voice/voice_controller.dart';
import '../common/app_dialog.dart';
import '../common/app_sheet.dart';
import '../common/sheet_title_bar.dart';
import '../settings/settings_widgets.dart';
import '../theme/app_icons.dart';
import '../theme/app_theme.dart';
import '../theme/surfaces.dart';
import 'companion_ask.dart';
import 'companion_chrome.dart';
import 'companion_log.dart';
import 'companion_memory_page.dart';
import 'companion_persona_page.dart';
import 'companion_voice_page.dart';
import 'companion_stage.dart';

/// The person removed her pack: the one inside the app waits to be asked for.
const _packRemovedKey = 'companion_pack_removed';
const _hintDoneKey = 'companion_touch_hint_done';
const _homeHintDoneKey = 'companion_home_hint_done';

final _sentenceEnd = RegExp(r'[。！？!?…~～]');

enum _Phase { checking, setup, stage, failed }

typedef CompanionStageBuilder = Widget Function(CompanionStageController controller, CompanionStageEvents events);
typedef _ReplyPart = ({AssistantChatItem item, int? retry});

class CompanionPage extends ConsumerStatefulWidget {
  const CompanionPage({super.key, this.storeOverride, this.stageBuilder, this.stageController, this.bundledPack});

  /// Tests point this at a temporary folder.
  final CompanionPackStore? storeOverride;

  /// The pack inside the app. Tests bring their own; with a test folder and
  /// none given, there is none.
  final Future<Uint8List?> Function()? bundledPack;

  /// Tests have no WebView.
  final CompanionStageBuilder? stageBuilder;
  final CompanionStageController? stageController;

  @override
  ConsumerState<CompanionPage> createState() => _CompanionPageState();
}

class _CompanionPageState extends ConsumerState<CompanionPage> implements CompanionInitiativeRoom {
  late final _stage = widget.stageController ?? CompanionStageController();
  final _input = TextEditingController();
  final _focus = FocusNode();
  final _random = Random();
  late final VoiceInputController _voice;

  CompanionPackStore? _store;
  CompanionCharacter _character = const CompanionCharacter();
  _Phase _phase = _Phase.checking;
  String? _failure;
  bool _stageReady = false;
  bool _greetingPending = true;
  bool _installing = false;

  /// This app carries a pack, and the first one is unpacking while she arrives.
  bool _bundledHere = false;
  bool _arriving = false;
  String? _installError;
  bool _showTouchHint = false;

  /// After the first touch: her shell, bubble and cushion can be tapped too.
  bool _showHomeHint = false;
  bool _homeHintDone = true;

  // The conversation.
  String? _sessionId;
  ProviderSubscription<ChatState>? _chat;
  late HostRef _bindingHost;
  DshClient? _bindingClient;
  int _bindingEpoch = 0;

  /// Light or full when the page last bound (see _bindingChanged).
  late bool _boundLight;
  bool _sending = false;
  bool _running = false;
  bool _needsAttention = false;
  bool _asleep = false;

  /// What her session waits on the person for (an approval or a question),
  /// already looked up at: she reacts once to each.
  String? _askingSeen;

  /// The backlog is over her (companion_log.dart).
  bool _logOpen = false;

  /// What she's doing in her corner (the stage's word for it).
  String _home = 'idle';
  String? _baselineUser;
  bool _baselineSet = false;
  int _marksHandled = 0;
  int _wordsSpoken = 0;
  List<_ReplyPart> _replyParts = const [];
  String _replyWords = '';
  final List<String> _notes = [];

  // Light mode: her conversation on this phone, and the reply on its way.
  CompanionLightHistory? _lightHistory;
  StreamSubscription<String>? _lightReply;
  http.Client? _lightClient;
  String _lightTurn = '';
  String _lightText = '';
  String _lightAsked = '';
  int _lightTurns = 0;

  // Her state on the Host (null: this host can't keep it).
  CompanionSnapshot? _vitals;
  CompanionKeeper? _keeper;

  /// Light mode's keeper: her state and memories on this phone.
  CompanionKeeper? _phone;
  CompanionKeeper get _phoneKeeper => _phone ??= ref.read(companionPhoneKeeperProvider)(_store!.root);
  Future<void> _vitalsQueue = Future.value();

  // What's on screen.
  String? _bubble;
  bool _bubbleIsError = false;
  String? _myLine;
  String? _lastLine;
  Timer? _bubbleTimer;
  Timer? _settleTimer;
  Timer? _objectTimer;

  /// What this model brings of its own (companion_moves.dart), once it has loaded.
  CompanionMoves _moves = const CompanionMoves();

  /// What the model is (companion_adapt.dart), from the stage.
  CompanionProbe? _probe;

  /// Her own AI is fitting the model to her.
  bool _adapting = false;

  /// Whose moves these are: their names and choices are kept per character.
  /// Whose moves the saved labels and AI switches are: this very model (its
  /// moc3), so another model that happens to share a name never inherits them.
  String _movesKey = 'default';
  int _movesEpoch = 0;

  /// A fitting offered for this model, waiting for the person's yes (the first
  /// time anything would be sent on its own).
  CompanionProbe? _adaptOffer;

  // Her other work: conversations on the hosts that finish, fail or wait on
  // the person while they're here.
  StreamSubscription<PetEvent>? _agentEvents;
  ({String sessionId, String label})? _agentPill;
  Timer? _agentPillTimer;
  DateTime? _agentSaidAt;

  // Her voice (companion_voice.dart): what is queued, and how far into the
  // current reply she has read aloud. Her mouth follows the engine when it
  // reports what it is reading, else the text's own rhythm.
  late final CompanionSpeaker _speaker;
  StreamSubscription<CompanionVoiceEvent>? _ttsEvents;
  String? _voiceNotice;
  Timer? _voiceNoticeTimer;
  bool _fallbackNoted = false;
  bool _ttsReady = false;
  bool _ttsRanges = false;
  int _ttsSerial = 0;
  int _spokenTo = 0;
  final Map<String, int> _ttsPending = {};

  // Her invitation to rest (Pro C451/C452): the installation's owner decides,
  // this page shows it and says what the person really does.
  static int _pages = 0;
  final int _page = ++_pages;
  late final CompanionInitiative _initiative;
  late final AppLifecycleListener _lifecycle;
  int _stageEpoch = 0;
  CompanionInitiativeDisplay? _invite;
  int? _inviteEnds;

  /// The invitation shown, until it is answered or the page moves on.
  String? _inviteOpen;
  bool _routeShown = true;
  bool _accessible = false;
  bool _entered = false;
  bool _leaving = false;
  bool _observeQueued = false;

  @override
  void initState() {
    super.initState();
    _initiative = ref.read(companionInitiativeProvider);
    _lifecycle = AppLifecycleListener(onStateChange: (_) => _observeInitiative());
    _bindingHost = ref.read(activeHostProvider);
    _bindingClient = ref.read(activeConnectionProvider).value?.client;
    _boundLight = _light;
    _voice = VoiceInputController(
      input: _input,
      bridge: ref.read(voiceBridgeProvider),
      mode: () => ref.read(voiceSettingsProvider.notifier).ready(),
      modelReady: () =>
          mounted &&
          (ref.read(activeConnectionProvider).value?.isLocal ?? false) &&
          ref.read(voiceModelProvider).status == VoiceModelStatus.ready,
      client: () => mounted ? ref.read(activeConnectionProvider).value?.client : null,
      onRecognized: () {
        final current = _currentRoom();
        scheduleMicrotask(() {
          if (current() && _input.text.trim().isNotEmpty) unawaited(_send());
        });
      },
    );
    _voice.addListener(_voiceChanged);
    _agentEvents = ref.read(petEventBusProvider).events.listen(_onAgentEvent);
    _speaker = ref.read(companionSpeakerProvider);
    _ttsEvents = _speaker.events.listen(_onTts);
    ref.listenManual(companionVoiceSettingsProvider, (_, settings) {
      if (settings != null) unawaited(_prepareVoice(settings));
    }, fireImmediately: true);
    _focus.addListener(_refreshMood);
    _input.addListener(_inputChanged);
    unawaited(_prepare());
  }

  Future<void> _prepare() async {
    final store =
        widget.storeOverride ??
        CompanionPackStore(Directory('${(await getApplicationSupportDirectory()).path}/companion'));
    final installed = await store.installed();
    final character = installed ? await store.character() : const CompanionCharacter();
    final bundled = await _hasBundled();
    final removed = (await SharedPreferences.getInstance()).getBool(_packRemovedKey) ?? false;
    if (!mounted) return;
    setState(() {
      _store = store;
      _character = character;
      _bundledHere = bundled;
      _phase = installed ? _Phase.stage : _Phase.setup;
    });
    // The first time, the pack inside the app is unpacked while she swims over.
    // After the person removed it, it waits on the setup screen to be asked for.
    if (!installed && bundled && !removed) await _installBundled(arriving: true);
  }

  Future<bool> _hasBundled() async {
    final own = widget.bundledPack;
    if (own != null) return await own() != null;
    return widget.storeOverride == null && await hasBundledCompanionPack();
  }

  Future<Uint8List?> _bundled() =>
      widget.bundledPack?.call() ??
      (widget.storeOverride == null ? loadBundledCompanionPack() : Future<Uint8List?>.value());

  @override
  void dispose() {
    // Leaving her: no invitation follows, and nothing comes back to this page.
    _leaving = true;
    _initiative.leave(this);
    _lifecycle.dispose();
    unawaited(companionMarkSeen(DateTime.now()));
    // Leaving: drop the light request without touching the page any more.
    _lightClient?.close();
    unawaited(_lightReply?.cancel().catchError((Object _) {}));
    _chat?.close();
    _bubbleTimer?.cancel();
    _settleTimer?.cancel();
    _objectTimer?.cancel();
    unawaited(_agentEvents?.cancel());
    unawaited(_ttsEvents?.cancel());
    if (_ttsPending.isNotEmpty) _speaker.stop();
    _voiceNoticeTimer?.cancel();
    _agentPillTimer?.cancel();
    _voice.removeListener(_voiceChanged);
    _voice.dispose();
    _focus.dispose();
    _input.dispose();
    super.dispose();
  }

  // ── Stage events ─────────────────────────────────────────────────────────

  void _onReady() {
    setState(() {
      _stageReady = true;
      // A new view of her: nothing shown on the last one carries over.
      _stageEpoch++;
    });
    unawaited(_arrive());
    unawaited(_loadHint());
    if (!_light) {
      final binding = ref.read(companionSessionsProvider.notifier).of(ref.read(activeHostProvider));
      if (binding != null) _bind(binding.sessionId);
    }
  }

  /// Light or full (docs/design/companion.md §7). Until the person picks one:
  /// full when a host is connected, light otherwise.
  bool get _light {
    final mode = ref.read(companionModeProvider);
    return mode == CompanionMode.light || (mode == null && ref.read(activeConnectionProvider).value == null);
  }

  Future<void> _loadHint() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final touchDone = prefs.getBool(_hintDoneKey) ?? false;
    _homeHintDone = prefs.getBool(_homeHintDoneKey) ?? false;
    setState(() {
      _showTouchHint = !touchDone;
      _showHomeHint = touchDone && !_homeHintDone;
    });
  }

  /// Her state first (it knows when the person was last here, on any phone),
  /// then the greeting, then this visit.
  Future<void> _arrive({bool greet = true}) async {
    final current = _currentRoom();
    // Light mode keeps her on this phone and asks no host for anything.
    final client = ref.read(activeConnectionProvider).value?.client;
    final CompanionKeeper? keeper = _light ? _phoneKeeper : (client == null ? null : HostKeeper(client));
    CompanionSnapshot? snapshot;
    if (keeper != null) {
      try {
        snapshot = await keeper.snapshot().timeout(const Duration(seconds: 3));
      } on Object {
        // Not this host, or not now: she's still here, just without memory of it.
      }
    }
    if (!current()) return;
    if (snapshot != null) {
      _keeper = keeper;
      _applyVitals(snapshot);
    }
    if (greet) await _greet(snapshot?.vitals.lastVisitAt, current);
    if (current() && snapshot != null) _event('visit');
  }

  void _applyVitals(CompanionSnapshot snapshot) {
    final before = _vitals;
    _vitals = snapshot;
    final v = snapshot.vitals;
    _stage.command('vitals', {'valence': v.valence, 'energy': v.energy, 'closeness': v.closeness});
    _stage.command('activity', {'name': v.activity, 'remainingMs': snapshot.activityLeft.inMilliseconds});
    _widgetUpdate();
    // A step closer while the person is here: a small moment, once, as it
    // happens. Arriving with it already reached is not news.
    if (before != null && before.storeId == snapshot.storeId) {
      final step = companionBond(v.closeness);
      if (step > companionBond(before.vitals.closeness)) _closer(step);
    }
  }

  void _closer(int step) {
    _stage.command('emotion', {'name': 'happy', 'hold': 3200});
    _stage.command('action', {'name': 'hop'});
    _remember('你觉得和对方又亲近了一些');
    if (!mounted || _running || _sending) return;
    final l10n = context.l10n;
    _say(switch (step) {
      1 => l10n.companionCloser1,
      2 => l10n.companionCloser2,
      _ => l10n.companionCloser3,
    });
  }

  /// One event at a time, against the state last read. A conflict reads again;
  /// it never sends the same event twice.
  void _event(String type) {
    final keeper = _keeper;
    if (keeper == null) return;
    final current = _currentRoom();
    _vitalsQueue = _vitalsQueue.then((_) async {
      if (!current() || !identical(keeper, _keeper)) return;
      final read = _vitals;
      if (read == null) return;
      try {
        try {
          final next = await keeper.event(read, type);
          if (current()) _applyVitals(next);
        } on DshRemoteException catch (error) {
          if (!current() || (!error.code.endsWith('conflict') && !error.code.endsWith('store-changed'))) return;
          final again = await keeper.snapshot();
          if (current() && again != null) _applyVitals(again);
        }
      } on Object {
        // The refresh can fail too. Keep the queue usable; never retry a write.
      }
    });
  }

  /// A later intent owns this visit's response, even before it has words.
  void _retireGreeting() => _greetingPending = false;

  bool _takeGreeting(bool Function() current) {
    if (!current() || !_greetingPending) return false;
    _greetingPending = false;
    return !_running && !_sending;
  }

  Future<void> _greet(DateTime? lastVisit, bool Function() current) async {
    final now = DateTime.now();
    final greeting = companionGreeting(now, lastVisit ?? await companionLastSeen());
    unawaited(companionMarkSeen(now));
    if (!mounted || !_takeGreeting(current)) return;
    final l10n = context.l10n;
    final (line, emotion, action) = switch (greeting) {
      CompanionGreeting.firstTime => (_firstHello(l10n), 'shy', 'wave'),
      CompanionGreeting.morning => (l10n.companionGreetMorning, 'happy', 'wave'),
      CompanionGreeting.noon => (l10n.companionGreetNoon, 'calm', 'tilt'),
      CompanionGreeting.afternoon => (l10n.companionGreetAfternoon, 'calm', 'nodSmall'),
      CompanionGreeting.evening => (l10n.companionGreetEvening, 'happy', 'wave'),
      CompanionGreeting.lateNight => (l10n.companionGreetLate, 'worried', 'tilt'),
      CompanionGreeting.longAbsence => (l10n.companionGreetLong, 'surprised', 'hop'),
      CompanionGreeting.justNow => (l10n.companionGreetBack, 'calm', 'nodSmall'),
    };
    _stage.command('emotion', {'name': emotion, 'hold': 3200});
    _stage.command('action', {'name': action});
    _say(line);
  }

  void _onTouch(String zone, String kind) {
    _initiative.activate(this);
    _retireGreeting();
    if (_showTouchHint) {
      setState(() {
        _showTouchHint = false;
        _showHomeHint = !_homeHintDone;
      });
      unawaited(SharedPreferences.getInstance().then((p) => p.setBool(_hintDoneKey, true)));
    }
    final l10n = context.l10n;
    // Once they're close she has a fonder word too.
    final close = companionBond(_vitals?.vitals.closeness ?? 0) >= 2;
    final lines = switch ((zone, kind)) {
      (_, 'hug') => [l10n.companionHug1, l10n.companionHug2, l10n.companionHug3, if (close) l10n.companionHugClose],
      (_, 'tease') => [l10n.companionTease1, l10n.companionTease2, l10n.companionTease3],
      (_, 'pat') => [l10n.companionPat1, l10n.companionPat2, l10n.companionPat3, if (close) l10n.companionPatClose],
      ('head', _) => [l10n.companionTapHead1, l10n.companionTapHead2],
      ('face', _) => [l10n.companionTapFace1, l10n.companionTapFace2, l10n.companionTapFace3],
      ('tail', _) => [l10n.companionTapTail1, l10n.companionTapTail2, l10n.companionTapTail3],
      ('legs', _) => [l10n.companionTapLegs1, l10n.companionTapLegs2],
      _ => [l10n.companionTapBody1, l10n.companionTapBody2, l10n.companionTapBody3],
    };
    // A hug is affection the way a pat is: the same event for her state.
    if (kind == 'pat' || kind == 'hug') _event('pet');
    _remember(switch ((zone, kind)) {
      (_, 'hug') => '对方刚才抱了抱你',
      (_, 'tease') => '对方刚才连着戳你',
      (_, 'pat') => '对方刚才摸了摸你的头',
      ('tail', _) => '对方刚才碰了你的尾巴',
      ('face', _) => '对方刚才戳了戳你的脸',
      _ => null,
    });
    if (_running || _sending) return; // Her words first.
    final choices = lines.where((l) => l != _lastLine).toList();
    final line = choices[_random.nextInt(choices.length)];
    _lastLine = line;
    _say(line);
  }

  /// How long an activity lasts when this host can't keep it (the bridge's
  /// own durations, docs/design/companion.md).
  static const _localActivity = {
    'snack': Duration(seconds: 45),
    'play': Duration(seconds: 90),
    'rest': Duration(minutes: 15),
  };

  /// A tap on one of her things.
  void _onObject(String id) {
    _initiative.activate(this);
    _useObject(id);
  }

  /// One of her things, from a tap or because she asked and the person said
  /// yes ([invited]): the same entry, so the cushion is the cushion either way.
  void _useObject(String id, {bool invited = false}) {
    _retireGreeting();
    if (!_homeHintDone) {
      _homeHintDone = true;
      setState(() => _showHomeHint = false);
      unawaited(SharedPreferences.getInstance().then((p) => p.setBool(_homeHintDoneKey, true)));
    }
    if (_vitals != null) {
      _event(id);
    } else {
      // No host to keep it: the page's own guess, so her corner still answers.
      _stage.command('activity', {'name': id, 'remainingMs': _localActivity[id]!.inMilliseconds});
    }
    _remember(switch (id) {
      _ when invited => '你邀请对方陪你在海草软垫上歇一会儿，对方答应了',
      'snack' => '对方刚才给你吃了一块点心',
      'play' => '对方刚才陪你玩了泡泡球',
      _ => '对方刚才让你在海草软垫上歇一会儿',
    });
    if (_running || _sending) return;
    final l10n = context.l10n;
    final lines = switch (id) {
      _ when invited => [l10n.companionInviteYes1, l10n.companionInviteYes2],
      'snack' => [l10n.companionSnack1, l10n.companionSnack2, l10n.companionSnack3],
      'play' => [l10n.companionPlay1, l10n.companionPlay2, l10n.companionPlay3],
      _ => [l10n.companionRest1, l10n.companionRest2],
    };
    final choices = lines.where((l) => l != _lastLine).toList();
    final line = choices[_random.nextInt(choices.length)];
    _lastLine = line;
    // After the snack has reached her, not before.
    _objectTimer?.cancel();
    _objectTimer = Timer(Duration(milliseconds: id == 'snack' ? 1700 : 900), () {
      if (mounted && !_running && !_sending) _say(line);
    });
  }

  /// A conversation of the person's (not hers) ended its turn, failed, or waits
  /// on them. She says so in a line, and offers the way there when it is on the
  /// host in front. Not something the person did: it doesn't count as activity.
  /// (Phone events and notifications: Pro ADDENDUM-06 #2.)
  void _onAgentEvent(PetEvent event) {
    if (!mounted || _leaving || !_stageReady || event.sessionId == _sessionId) return;
    // Stopped is the person's own doing.
    if (event.kind == PetEventKind.stopped) return;
    final l10n = context.l10n;
    final title = _shortTitle(event.title);
    final String line;
    final String emotion;
    final String action;
    final String note;
    switch (event.kind) {
      case PetEventKind.failed:
        line = title == null ? l10n.companionTaskFailedUntitled : l10n.companionTaskFailed(title);
        (emotion, action, note) = ('worried', 'tilt', '出错了');
      case PetEventKind.approval:
        line = title == null ? l10n.companionTaskApprovalUntitled : l10n.companionTaskApproval(title);
        (emotion, action, note) = ('surprised', 'lookUp', '在等对方批准');
      case PetEventKind.question:
        line = title == null ? l10n.companionTaskQuestionUntitled : l10n.companionTaskQuestion(title);
        (emotion, action, note) = ('confused', 'tilt', '有问题要问对方');
      case PetEventKind.done || PetEventKind.stopped:
        line = title == null ? l10n.companionTaskDoneUntitled : l10n.companionTaskDone(title);
        (emotion, action, note) = ('happy', 'nodSmall', '跑完了');
    }
    _remember('对方的另一个对话${title == null ? '' : '「$title」'}刚刚$note');
    if (event.host == ref.read(activeHostProvider)) {
      _agentPillTimer?.cancel();
      setState(() {
        _agentPill = (
          sessionId: event.sessionId,
          label: title == null ? l10n.companionTaskOpen : '${l10n.companionTaskOpen} · $title',
        );
      });
      _agentPillTimer = Timer(const Duration(seconds: 15), () {
        if (mounted) setState(() => _agentPill = null);
      });
    }
    // Her own words come first; and a burst of them gets one line, not five.
    final now = DateTime.now();
    if (_running || _sending || (_agentSaidAt != null && now.difference(_agentSaidAt!) < const Duration(seconds: 4))) {
      return;
    }
    _agentSaidAt = now;
    _stage.command('emotion', {'name': emotion, 'hold': 2600});
    _stage.command('action', {'name': action});
    _say(line);
  }

  static String? _shortTitle(String? title) {
    final text = title?.trim();
    if (text == null || text.isEmpty) return null;
    return text.characters.length > 14 ? '${text.characters.take(13)}…' : text;
  }

  void _openAgent(String sessionId) {
    _agentPillTimer?.cancel();
    setState(() => _agentPill = null);
    ref.read(currentSessionProvider.notifier).select(sessionId);
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  void _onActivity(String name) {
    if (mounted && name != _home) setState(() => _home = name);
  }

  void _onMood(String mood) {
    final asleep = mood == 'sleeping';
    if (asleep != _asleep && mounted) setState(() => _asleep = asleep);
  }

  void _remember(String? note) {
    if (note == null) return;
    _notes
      ..remove(note)
      ..add(note);
    if (_notes.length > 3) _notes.removeAt(0);
  }

  /// A short line without the model.
  void _say(String line) {
    _objectTimer?.cancel();
    if (!_speakAloud(line, flush: true)) _stage.command('say', {'chars': line.length});
    _showBubble(line, hold: Duration(milliseconds: 2400 + line.length * 90));
    _widgetUpdate(line: line);
  }

  /// The home-screen widget: who she is, what she's doing, how well she knows
  /// the person, and [line] when she has just said something.
  void _widgetUpdate({String? line}) {
    if (!mounted) return;
    final l10n = context.l10n;
    final snapshot = _vitals;
    final activity = snapshot?.vitals.activity ?? _home;
    unawaited(
      ref.read(companionWidgetProvider).update({
        'name': _name(l10n),
        'activity': activity,
        'status': switch (activity) {
          'snack' => l10n.companionStatusSnacking,
          'play' => l10n.companionStatusPlaying,
          'rest' => l10n.companionStatusResting,
          _ => l10n.companionStatusIdle,
        },
        'untilMs': snapshot == null
            ? null
            : DateTime.now().millisecondsSinceEpoch + snapshot.activityLeft.inMilliseconds,
        'statusAsleep': l10n.companionStatusSleeping,
        'statusWaiting': l10n.companionWidgetWaiting,
        'bond': snapshot == null ? null : companionBond(snapshot.vitals.closeness),
        if (line != null) ...{'line': line, 'saidAt': DateTime.now().millisecondsSinceEpoch},
      }),
    );
  }

  /// Her name: the one the person gave her, else her pack's, else just "her".
  String _name(L10n l10n) => ref.read(companionNameProvider) ?? _character.name ?? l10n.companionDefaultName;

  /// Introducing herself, by the name she goes by (if she has one).
  String _firstHello(L10n l10n) => switch (ref.read(companionNameProvider) ?? _character.name) {
    final name? => l10n.companionGreetFirst(name),
    null => l10n.companionGreetFirstNameless,
  };

  /// Her persona as the person has it, under the name she goes by.
  String _persona() {
    final persona = ref.read(companionPersonaProvider);
    return companionPersona(
      custom: persona.custom,
      name: ref.read(companionNameProvider) ?? _character.name,
      callMe: persona.callMe,
      moves: _moves.rules(),
    );
  }

  /// A model that still needs judgement gets fitted once, on its own, with
  /// the person's model; after that only when they ask (menu).
  void _onProbe(CompanionProbe probe) {
    // An offer for the model she had before goes with it.
    if (_adaptOffer != null && _adaptOffer!.moc != probe.moc) setState(() => _adaptOffer = null);
    _probe = probe;
    if (probe.adapted) unawaited(_checkAdapter(probe));
    if (_adapting || companionAdaptWanted(probe).isEmpty) return;
    unawaited(_autoAdapt(probe));
  }

  Future<void> _autoAdapt(CompanionProbe probe) async {
    final store = _store;
    if (store == null || !await companionAdaptAuto()) return;
    // Nothing to ask with: the menu says how to get it.
    if (ref.read(settingsProvider).apiKey.trim().isEmpty) return;
    final fingerprint = await companionMocFingerprint(store.pack, probe) ?? probe.moc;
    if (await companionAdaptTried(fingerprint)) return;
    // Nothing goes out on its own until the person has said yes once.
    if (!await companionAdaptConsented()) {
      if (mounted && _probe == probe) setState(() => _adaptOffer = probe);
      return;
    }
    await companionAdaptMarkTried(fingerprint);
    if (!mounted || _probe != probe) return;
    await _adapt();
  }

  /// The adapter she wears says which model it was written for (its moc3
  /// fingerprint): one written for another model is taken off, and this one
  /// is looked at afresh.
  Future<void> _checkAdapter(CompanionProbe probe) async {
    final store = _store;
    if (store == null) return;
    final adapter = await companionAdapterRead(store.pack);
    final meant = adapter?['moc'];
    if (meant is! String || meant.isEmpty) return;
    final actual = await companionMocFingerprint(store.pack, probe);
    if (actual == null || actual == meant || !mounted || _probe != probe) return;
    await companionAdapterRemove(store.pack);
    if (mounted) _stage.command('adapter');
  }

  Future<void> _answerAdaptOffer({required bool yes}) async {
    final probe = _adaptOffer;
    final store = _store;
    if (probe == null || store == null) return;
    _acted();
    setState(() => _adaptOffer = null);
    await companionAdaptMarkTried(await companionMocFingerprint(store.pack, probe) ?? probe.moc);
    if (!yes) return;
    await companionAdaptSetConsented(true);
    if (mounted && _probe == probe) await _adapt();
  }

  /// Asks her own AI for an adapter, checks it, and she wears it at once.
  /// [note]: what the person said is off, for another go.
  Future<void> _adapt({String? note}) async {
    final store = _store;
    final probe = _probe;
    if (store == null || probe == null || _adapting) return;
    final l10n = context.l10n;
    final key = ref.read(settingsProvider).apiKey.trim();
    if (key.isEmpty) {
      _say(l10n.companionAdaptNoKey);
      return;
    }
    setState(() => _adapting = true);
    _say(l10n.companionAdaptStart);
    _stage.command('mood', {'mood': 'thinking'});
    final client = ref.read(companionLightClientProvider)();
    try {
      final adapter = await companionAdaptAsk(
        client: client,
        apiKey: key,
        probe: probe,
        note: note,
        current: probe.adapted ? await companionAdapterRead(store.pack) : null,
      );
      await companionAdapterWrite(store.pack, probe, adapter);
      if (!mounted) return;
      _stage.command('adapter');
      _stage.command('mood', {'mood': 'idle'});
      _stage.command('emotion', {'name': 'happy', 'hold': 3200});
      _stage.command('action', {'name': 'hop'});
      final notes = adapter['notes'];
      _say(notes is String && notes.isNotEmpty ? l10n.companionAdaptDoneNote(notes) : l10n.companionAdaptDone);
    } on Object catch (error) {
      if (!mounted) return;
      _stage.command('mood', {'mood': 'idle'});
      _say(switch (error) {
        CompanionLightError(failure: CompanionLightFailure.noKey) => l10n.companionAdaptNoKey,
        CompanionLightError(failure: CompanionLightFailure.badKey) => l10n.companionLightBadKey,
        CompanionLightError(failure: CompanionLightFailure.busy) => l10n.companionLightBusy,
        CompanionAdaptError(reason: 'empty') => l10n.companionAdaptFailed(l10n.companionAdaptEmpty),
        CompanionAdaptError() => l10n.companionAdaptFailed(l10n.companionAdaptUnreadable),
        _ => l10n.companionAdaptFailed(l10n.companionAdaptNetwork),
      });
    } finally {
      client.close();
      if (mounted) setState(() => _adapting = false);
    }
  }

  Future<void> _undoAdapt() async {
    final store = _store;
    if (store == null) return;
    if (_probe case final probe?) {
      await companionAdaptMarkTried(await companionMocFingerprint(store.pack, probe) ?? probe.moc);
    }
    await companionAdapterRemove(store.pack);
    if (!mounted) return;
    _stage.command('adapter');
    _say(context.l10n.companionAdaptUndone);
  }

  void _openAdapt() {
    unawaited(
      showAppSheet<void>(
        context,
        isScrollControlled: true,
        builder: (sheet) => _AdaptSheet(
          adapted: _probe?.adapted ?? false,
          onRun: (note) {
            Navigator.of(sheet).pop();
            setState(() => _adaptOffer = null);
            unawaited(companionAdaptSetConsented(true));
            unawaited(_adapt(note: note));
          },
          onUndo: () {
            Navigator.of(sheet).pop();
            unawaited(_undoAdapt());
          },
        ),
      ),
    );
  }

  Future<void> _onModel(CompanionModelInfo info) async {
    final epoch = ++_movesEpoch;
    final store = _store;
    final probe = _probe;
    final fingerprint = store == null || probe == null ? null : await companionMocFingerprint(store.pack, probe);
    final key = fingerprint == null ? (_character.name ?? 'default') : 'moc:$fingerprint';
    final saved = await companionMovesSaved(key);
    if (!mounted || epoch != _movesEpoch) return;
    _movesKey = key;
    setState(() {
      _moves = CompanionMoves.from(info, saved);
      _rebaseMarks();
    });
  }

  /// Her own moves just became known: marks already in the reply on screen
  /// that only now read as marks were said before, not news to play.
  void _rebaseMarks() {
    if (!_baselineSet) return;
    final text = _light ? _lightText : _replyParts.map((part) => part.item.text).join('\n');
    final reply = parseCompanionReply(
      text,
      streaming: _running,
      emotions: _moves.emotionLabels,
      actions: _moves.actionLabels,
    );
    _marksHandled = reply.marks.length;
  }

  void _changeMove(CompanionMove next) {
    setState(() => _moves = _moves.replaced(next));
    unawaited(companionMovesSave(_movesKey, _moves));
  }

  /// Renamed in 她的设定: back in the room, she answers to it.
  void _renamedTo(String name) {
    if (!mounted || !_stageReady) return;
    final l10n = context.l10n;
    _remember('对方刚给你起了新名字「$name」');
    _stage.command('emotion', {'name': 'happy', 'hold': 3200});
    _stage.command('action', {'name': 'hop'});
    _say(l10n.companionRenamed(name));
  }

  /// Her model's own expressions and motions: try one on her, rename it, and
  /// say whether the AI may use it. A sheet, so she stays in view and plays them.
  void _openMoves() {
    unawaited(
      showAppSheet<void>(
        context,
        builder: (sheet) => StatefulBuilder(
          builder: (sheet, setSheet) {
            final l10n = sheet.l10n;
            void change(CompanionMove next) {
              _changeMove(next);
              setSheet(() {});
            }

            Widget row(CompanionMove move) => SettingsTile(
              tinted: false,
              title: move.label,
              subtitle: move.label == move.raw ? null : move.raw,
              chevron: false,
              onTap: () async {
                final label = await showAppDialog<String>(
                  context: sheet,
                  builder: (_) => _LabelDialog(initial: move.label, hint: companionMoveLabel(move.raw)),
                );
                if (label != null && label.trim().isNotEmpty) change(move.copyWith(label: label.trim()));
              },
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: l10n.companionMovesTry,
                    icon: const Icon(AppIcons.play, size: 20),
                    onPressed: () => move.kind == CompanionMoveKind.expression
                        ? _stage.command('emotion', {'name': move.raw, 'hold': 2600, 'native': true})
                        : _stage.command('action', {'name': move.raw, 'native': true}),
                  ),
                  Switch(
                    value: move.ai,
                    onChanged: (ai) => change(move.copyWith(ai: ai)),
                  ),
                ],
              ),
            );

            return SafeArea(
              top: false,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SheetTitleBar(l10n.companionMenuMoves),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(SheetTitleBar.inset + 8, 0, SheetTitleBar.inset + 8, 12),
                      child: Text(
                        _moves.isEmpty ? l10n.companionMovesNone : l10n.companionMovesHint,
                        style: Theme.of(sheet).textTheme.bodySmall,
                      ),
                    ),
                    if (_moves.expressions.isNotEmpty)
                      SheetGroup(
                        margin: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 0, SheetTitleBar.inset, 12),
                        children: [for (final move in _moves.expressions) row(move)],
                      ),
                    if (_moves.motions.isNotEmpty)
                      SheetGroup(
                        margin: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 0, SheetTitleBar.inset, 12),
                        children: [for (final move in _moves.motions) row(move)],
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  // ── Voice ────────────────────────────────────────────────────────────────

  bool get _voiceOn => _ttsReady && (ref.read(companionVoiceSettingsProvider)?.on ?? false);

  /// Ready to speak with [settings] (or silent when they are off).
  Future<void> _prepareVoice(CompanionVoiceSettings settings) async {
    if (!settings.on) {
      _ttsReady = false;
      _hush();
      return;
    }
    final ready = await _speaker.ready(settings);
    if (mounted) _ttsReady = ready;
  }

  /// Reads [text] aloud when her voice is on; false when it isn't (then her
  /// mouth keeps the text's rhythm). [flush] replaces whatever she is saying.
  bool _speakAloud(String text, {bool flush = false}) {
    if (!_voiceOn || text.trim().isEmpty) return false;
    if (flush) _ttsPending.clear();
    final id = 'v${++_ttsSerial}';
    _ttsPending[id] = text.length;
    _speaker.speak(id, text, flush: flush);
    return true;
  }

  /// She stops talking at once: the person is typing, talking, stopping her or leaving.
  void _hush() {
    if (_ttsPending.isEmpty) return;
    _ttsPending.clear();
    _speaker.stop();
    _stage.command('quiet');
  }

  void _onTts(CompanionVoiceEvent event) {
    if (!mounted || !_ttsPending.containsKey(event.id)) return;
    switch (event.type) {
      case CompanionVoiceEventType.start:
        final external = ref.read(companionVoiceSettingsProvider)?.source != CompanionVoiceSource.system;
        if (event.loudness case final levels?) {
          // Fetched WAV: her mouth opens with the voice's own loudness.
          _stage.command('loudness', {'levels': levels, 'frameMs': 40});
        } else if (!_ttsRanges || external) {
          // Engines that don't say what they're reading: the whole line's rhythm.
          _stage.command('say', {'chars': _ttsPending[event.id]});
        }
      case CompanionVoiceEventType.fallback:
        // Once per visit: the external voice didn't answer, the phone's stood in.
        if (_fallbackNoted) return;
        _fallbackNoted = true;
        _voiceNoticeTimer?.cancel();
        setState(() => _voiceNotice = context.l10n.companionVoiceFallback);
        _voiceNoticeTimer = Timer(const Duration(seconds: 6), () {
          if (mounted) setState(() => _voiceNotice = null);
        });
      case CompanionVoiceEventType.range:
        _ttsRanges = true;
        _stage.command('say', {'chars': max(1, (event.end ?? 0) - (event.start ?? 0))});
      case CompanionVoiceEventType.done || CompanionVoiceEventType.stopped || CompanionVoiceEventType.error:
        setState(() => _ttsPending.remove(event.id));
    }
  }

  void _showBubble(String text, {Duration? hold, bool error = false}) {
    _retireGreeting();
    _bubbleTimer?.cancel();
    setState(() {
      _bubble = text;
      _bubbleIsError = error;
    });
    if (hold != null) {
      _bubbleTimer = Timer(hold, () {
        if (mounted) setState(() => _bubble = null);
      });
    }
  }

  // ── Mood ─────────────────────────────────────────────────────────────────

  void _refreshMood() {
    if (_running || _sending) return;
    _stage.command('mood', {'mood': _focus.hasFocus || _voice.active ? 'listening' : 'idle'});
    if (mounted) setState(() {});
  }

  void _voiceChanged() {
    if (!mounted) return;
    setState(() {});
    _refreshMood();
  }

  void _inputChanged() {
    if (mounted) setState(() {});
  }

  CompanionActivity get _activity {
    if (_asleep) return CompanionActivity.sleeping;
    if (_sending || (_running && _bubble == null)) return CompanionActivity.thinking;
    if (_running) return CompanionActivity.speaking;
    if (_focus.hasFocus || _voice.active) return CompanionActivity.listening;
    return switch (_home) {
      'snack' => CompanionActivity.snacking,
      'play' => CompanionActivity.playing,
      'rest' => CompanionActivity.resting,
      _ => CompanionActivity.idle,
    };
  }

  // ── Invitations (Pro C451/C452) ──────────────────────────────────────────

  /// This page, this mode and binding, this view of her. A change retires
  /// whatever was shown for the one before (C452 §3).
  String get _initiativeContext => '$_page/${_boundLight ? 'light' : 'full'}/$_bindingEpoch/$_stageEpoch';

  /// Everything that decides whether she may ask now. Anything unsure blocks.
  CompanionInitiativeView _initiativeView() => CompanionInitiativeView.room(
    routeVisible: _routeShown,
    stageReady: _stageReady && _phase == _Phase.stage,
    resumed: WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed,
    inputBusy: _focus.hasFocus || _input.text.trim().isNotEmpty,
    generating: _sending || _running || _lightReply != null,
    // Her mouth still settling counts: the words may still be on their way out.
    audioBusy: _voice.active || (_settleTimer?.isActive ?? false) || _ttsPending.isNotEmpty,
    activityBusy: _home != 'idle' || _asleep || (_objectTimer?.isActive ?? false),
    approvalPending: _needsAttention,
    externalPromptBusy: _bubble != null || _myLine != null || _agentPill != null || _logOpen || _adaptOffer != null,
    quietHoursBlocked: false,
    enabled: ref.read(companionInitiativeEnabledProvider) ?? false,
    accessible: _accessible,
    contextKey: _initiativeContext,
  );

  bool _presentable(CompanionInitiativeView view) => view.visible && view.resumed && !view.blocked && view.enabled;

  /// After this frame: the owner hears what the page now looks like.
  void _queueObserve() {
    if (_observeQueued) return;
    _observeQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _observeQueued = false;
      _observeInitiative();
    });
  }

  void _observeInitiative() {
    if (!mounted || _leaving) return;
    final view = _initiativeView();
    if (_entered) {
      _initiative.observe(this, view);
    } else {
      _entered = true;
      _initiative.enter(this, view);
    }
  }

  /// Something the person really did here: no invitation this visit.
  void _acted() => _initiative.activate(this);

  @override
  bool canPresent(CompanionInitiativeTicket ticket) =>
      mounted &&
      !_leaving &&
      // She greets in her own words when the person arrives; only invitations come here.
      ticket.kind == CompanionPromptKind.invite &&
      ticket.contextKey == _initiativeContext &&
      _presentable(_initiativeView());

  @override
  void show(CompanionInitiativeDisplay display) {
    if (!mounted || _leaving) return;
    setState(() {
      _invite = display;
      _inviteEnds = display.expiresAtMono;
      _inviteOpen = display.ticket.id;
    });
    // She looks over at the cushion, and a few bubbles rise from it. No words.
    _stage.command('glance', {'prop': 'rest', 'ms': 1800});
    _stage.command('beckon', {'prop': 'rest'});
  }

  @override
  void hide(String ticketId) {
    if (!mounted || _leaving || _invite?.ticket.id != ticketId) return;
    setState(() => _invite = null);
    _stage.command('beckon', {'prop': null});
  }

  @override
  void retime(String ticketId, int? expiresAtMono) {
    if (!mounted || _leaving || _invite?.ticket.id != ticketId) return;
    setState(() => _inviteEnds = expiresAtMono);
  }

  @override
  void rest(CompanionInitiativeEffect intent) {
    // Only the invitation this page showed, in the room it showed it in, once.
    if (!mounted || _leaving || intent.ticketId != _inviteOpen || intent.contextKey != _initiativeContext) return;
    _inviteOpen = null;
    // The cushion gives under her as if tapped; what lasts is the rest itself.
    _stage.command('prop', {'name': 'rest'});
    _useObject('rest', invited: true);
  }

  void _answerInvite({required bool yes}) {
    final invite = _invite;
    if (invite == null) return;
    final view = _initiativeView();
    final id = invite.ticket.id;
    if (yes) {
      _initiative.accept(this, id, view);
    } else if (_initiative.decline(this, id, view) && mounted) {
      // Fine by her: a small nod, nothing said.
      _stage.command('action', {'name': 'nodSmall'});
    }
  }

  // ── Talking ──────────────────────────────────────────────────────────────

  /// Work belongs to this visit to this host and client, even after A→B→A.
  bool Function() _currentRoom() {
    final epoch = _bindingEpoch;
    // A light conversation belongs to no host: only leaving the page or
    // switching modes (an unbind) ends what it started.
    if (_light) return () => mounted && epoch == _bindingEpoch;
    final host = ref.read(activeHostProvider);
    final client = ref.read(activeConnectionProvider).value?.client;
    return () =>
        mounted &&
        epoch == _bindingEpoch &&
        host == ref.read(activeHostProvider) &&
        identical(client, ref.read(activeConnectionProvider).value?.client);
  }

  void _bindingChanged() {
    final host = ref.read(activeHostProvider);
    final client = ref.read(activeConnectionProvider).value?.client;
    if (host == _bindingHost && identical(client, _bindingClient)) return;
    _bindingHost = host;
    _bindingClient = client;
    // With no mode picked, a host coming or going turns her light or full.
    final light = _light;
    if (light != _boundLight) {
      _modeChanged();
      return;
    }
    // A light conversation isn't on any host: nothing to rebind.
    if (light) return;
    setState(_unbind);
    final binding = ref.read(companionSessionsProvider.notifier).of(host);
    if (binding != null && _stageReady) _bind(binding.sessionId);
    if (_stageReady) unawaited(_arrive());
  }

  void _bind(String sessionId) {
    if (_sessionId == sessionId && _chat != null) return;
    _chat?.close();
    _sessionId = sessionId;
    _baselineSet = false;
    _chat = ref.listenManual(chatProvider(sessionId), (_, next) => _onChat(next), fireImmediately: true);
  }

  void _unbind() {
    _bindingEpoch++;
    _greetingPending = true;
    _hush();
    if (_voice.active) unawaited(_voice.cancel());
    _bubbleTimer?.cancel();
    _settleTimer?.cancel();
    _objectTimer?.cancel();
    _vitals = null;
    _keeper = null;
    _vitalsQueue = Future.value();
    _chat?.close();
    _chat = null;
    _sessionId = null;
    _sending = false;
    _running = false;
    _needsAttention = false;
    _askingSeen = null;
    _baselineSet = false;
    _marksHandled = 0;
    _wordsSpoken = 0;
    _replyParts = const [];
    _replyWords = '';
    _notes.clear();
    _bubble = null;
    _myLine = null;
    _home = 'idle';
    _asleep = false;
    _stage.command('quiet');
    _stage.command('activity', {'name': 'idle', 'remainingMs': 0});
    _stage.command('vitals', {'valence': 0.25, 'energy': 0.75, 'closeness': 0});
    _refreshMood();
  }

  /// The words after the latest thing the person said.
  (String?, List<_ReplyPart>) _latestReply(ChatState state) {
    final tail = <ChatItem>[];
    String? user;
    for (final item in state.items.reversed) {
      if (item is UserChatItem) {
        user = item.key;
        break;
      }
      tail.add(item);
    }
    final parts = <_ReplyPart>[];
    int? retry;
    for (final item in tail.reversed) {
      if (item is NoticeChatItem && item.kind == 'retry') retry = item.seq;
      if (item is AssistantChatItem && item.text.isNotEmpty) parts.add((item: item, retry: retry));
    }
    return (user, parts);
  }

  void _onChat(ChatState state) {
    if (!mounted) return;
    final asking = state.openApproval?.eventId ?? state.questions.firstOrNull?.eventId;
    if (asking != _askingSeen) {
      // Something already waiting when the page opened is not news.
      if (asking != null && _baselineSet) {
        _stage.command('emotion', {'name': 'surprised', 'hold': 1600});
        _stage.command('action', {'name': 'lookUp'});
      }
      _askingSeen = asking;
    }
    final (user, parts) = _latestReply(state);
    _onReply(
      user,
      parts.map((part) => part.item.text).join('\n'),
      parts: parts,
      running: state.running || state.pending.isNotEmpty,
      attention: state.openApproval != null || state.questions.isNotEmpty,
      error: state.error,
      loading: state.loading,
    );
  }

  /// Keep progress only for the same full-mode assistant segments. A retry
  /// can replace a draft without publishing its empty interval to this page.
  void _retainReplyProgress(List<_ReplyPart> next) {
    final prefix = <String>[];
    for (var i = 0; i < min(_replyParts.length, next.length); i++) {
      final old = _replyParts[i];
      final current = next[i];
      // FinishChunk makes a draft nonstreaming too; only seq identifies a
      // durable message. Its row key is shared with the draft it commits.
      final commitsDraft = old.item.seq == null && current.item.seq != null && old.item.key == current.item.key;
      if (old.retry != current.retry || (old.item.id != current.item.id && !commitsDraft)) break;
      final before = old.item.text;
      final after = current.item.text;
      if (before == after) {
        prefix.add(before);
        continue;
      }
      var end = 0;
      while (end < min(before.length, after.length) && before.codeUnitAt(end) == after.codeUnitAt(end)) {
        end++;
      }
      prefix.add(before.substring(0, end));
      break;
    }
    final retainedText = prefix.join('\n');
    if (retainedText != _replyParts.map((part) => part.item.text).join('\n')) {
      final retained = parseCompanionReply(
        retainedText,
        streaming: true,
        emotions: _moves.emotionLabels,
        actions: _moves.actionLabels,
      );
      _marksHandled = min(_marksHandled, retained.marks.length);
      _wordsSpoken = min(_wordsSpoken, retained.words.length);
    }
    _replyParts = next;
  }

  /// The current text owns the subtitle, even when a failed attempt is
  /// replaced by fewer words. Fresh progress also permits a later identical line.
  void _showReplyWords(String words, int fresh) {
    if (fresh <= 0 && words == _replyWords) return;
    _replyWords = words;
    if (words.isEmpty) {
      _bubbleTimer?.cancel();
      _bubble = null;
      _bubbleIsError = false;
    } else {
      _myLine = null;
      _showBubble(words);
    }
  }

  /// Her reply so far to the person's latest line [user] (any key that changes
  /// with each line), in either mode: marks once each, words into the bubble
  /// and her mouth, the mood while it runs and after.
  void _onReply(
    String? user,
    String text, {
    required bool running,
    bool attention = false,
    String? error,
    bool loading = false,
    List<_ReplyPart>? parts,
  }) {
    if (!_baselineSet) {
      // What's already in the conversation has been said; only news moves her.
      if (loading) return;
      _baselineSet = true;
      _baselineUser = user;
      final old = parseCompanionReply(text, emotions: _moves.emotionLabels, actions: _moves.actionLabels);
      _marksHandled = old.marks.length;
      _wordsSpoken = old.words.length;
      _spokenTo = old.words.length;
      _replyParts = parts ?? const [];
      _replyWords = old.words;
      if (!running) {
        setState(() => _needsAttention = attention);
        return;
      }
    }

    if (user != _baselineUser) {
      _retireGreeting();
      _baselineUser = user;
      _marksHandled = 0;
      _wordsSpoken = 0;
      _spokenTo = 0;
      _replyParts = const [];
    }

    if (parts != null) _retainReplyProgress(parts);
    final reply = parseCompanionReply(
      text,
      streaming: running,
      emotions: _moves.emotionLabels,
      actions: _moves.actionLabels,
    );
    for (final mark in reply.marks.skip(_marksHandled)) {
      _retireGreeting();
      switch (mark.kind) {
        case CompanionMarkKind.emotion:
          _stage.command('emotion', {'name': mark.name, if (mark.native) 'native': true});
        case CompanionMarkKind.action:
          _stage.command('action', {'name': mark.name, if (mark.native) 'native': true});
      }
    }
    _marksHandled = reply.marks.length;

    final fresh = reply.words.length - _wordsSpoken;
    final aloud = _voiceOn && error == null;
    if (fresh > 0) {
      // Read aloud, her mouth follows the voice instead of the text.
      if (!aloud) _stage.command('say', {'chars': fresh});
      if (_sentenceEnd.hasMatch(reply.words.substring(_wordsSpoken))) _stage.command('beat');
    }
    _wordsSpoken = reply.words.length;
    if (aloud) {
      // Whole sentences as they complete, the rest once the reply is in. A
      // retry can take words back; what was said stays said.
      if (_spokenTo > reply.words.length) _spokenTo = reply.words.length;
      final (sentences, to) = companionSpeakable(reply.words, _spokenTo, final_: !running);
      _spokenTo = to;
      if (sentences.isNotEmpty) _speakAloud(sentences);
    }
    _showReplyWords(reply.words, fresh);

    if (running) {
      _retireGreeting();
      _settleTimer?.cancel();
      _stage.command('mood', {'mood': reply.words.isEmpty ? 'thinking' : 'speaking'});
    } else if (_running) {
      // Her mouth keeps going for a moment after the text is in.
      _settleTimer?.cancel();
      _settleTimer = Timer(Duration(milliseconds: min(4000, 600 + max(fresh, 0) * 90)), _refreshMood);
      _myLine = null;
      if (error != null) {
        _showBubble(error, hold: const Duration(seconds: 6), error: true);
      } else if (reply.words.isNotEmpty) {
        _widgetUpdate(line: reply.words.length > 80 ? '${reply.words.substring(0, 79)}…' : reply.words);
        _bubbleTimer?.cancel();
        _bubbleTimer = Timer(Duration(milliseconds: 9000 + reply.words.length * 60), () {
          if (mounted) setState(() => _bubble = null);
        });
      }
    }

    setState(() {
      _running = running;
      _needsAttention = attention;
    });
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending || _lightReply != null) return;
    _acted();
    _hush();
    _retireGreeting();
    if (_voice.active) unawaited(_voice.cancel());
    final current = _currentRoom();
    _input.clear();
    _bubbleTimer?.cancel();
    _objectTimer?.cancel();
    setState(() {
      _sending = true;
      _bubble = null;
      _myLine = text;
    });
    _stage.command('mood', {'mood': 'thinking'});
    try {
      if (_light) {
        await _sendLight(text, current);
        return;
      }
      final binding = await ref.read(companionSessionsProvider.notifier).ensure();
      if (!current()) return;
      _bind(binding.sessionId);
      final chat = ref.read(chatProvider(binding.sessionId).notifier);
      if (!await chat.waitForSync(isCurrent: current)) throw const DshClosedException('not synced');
      if (!current()) return;
      final firstInline = binding.inlinePersona && ref.read(chatProvider(binding.sessionId)).items.isEmpty;
      final persona = ref.read(companionPersonaProvider);
      final movesRules = _moves.rules();
      final before = await companionPersonaToldAs(binding.sessionId);
      final hadMoves = before != null && before.split('|').last != CompanionMoves.noneFingerprint;
      final told = [
        ?companionPersonaUpdate(custom: persona.custom, callMe: persona.callMe),
        if (movesRules != null) '（$movesRules）' else if (hadMoves) '（这个角色自己的表情和动作现在都不用了，只用你原来的那些标记。）',
      ];
      final update = told.isEmpty ? null : told.join('\n');
      final fingerprint = '${persona.fingerprint}|${_moves.fingerprint}';
      final tell = update != null && !firstInline && !await companionPersonaTold(binding.sessionId, fingerprint);
      if (!current()) return;
      final aside = companionAside(now: DateTime.now(), notes: List.of(_notes));
      final named = companionNameNote(ref.read(companionNameProvider));
      final message = [
        if (firstInline) '（从现在起请扮演下面的角色，直接开始，不要复述这段设定。）\n${_persona()}',
        if (tell) update,
        ?named,
        ?aside,
        text,
      ].join('\n');
      final sent = await chat.send(message);
      if (sent && (tell || (firstInline && update != null))) {
        unawaited(companionPersonaMarkTold(binding.sessionId, fingerprint));
      }
      if (!current()) return;
      if (sent) {
        _notes.clear();
      } else {
        throw StateError(ref.read(chatProvider(binding.sessionId)).error ?? 'send');
      }
    } on Object catch (error) {
      if (!current()) return;
      if (_input.text.isEmpty) _input.text = text;
      _stage.command('emotion', {'name': 'worried', 'hold': 3000});
      setState(() => _myLine = null);
      _showBubble(_failureText(error), hold: const Duration(seconds: 6), error: true);
    } finally {
      if (current()) {
        setState(() => _sending = false);
        _refreshMood();
      }
    }
  }

  String _failureText(Object error) {
    final l10n = context.l10n;
    return switch (error) {
      CompanionLightError(failure: CompanionLightFailure.noKey) => l10n.companionLightNoKey,
      CompanionLightError(failure: CompanionLightFailure.badKey) => l10n.companionLightBadKey,
      CompanionLightError(failure: CompanionLightFailure.busy) => l10n.companionLightBusy,
      // Full mode only because nobody picked a mode yet: light would work without a host.
      DshClosedException() when ref.read(companionModeProvider) == null => l10n.companionNotConnectedTryLight,
      DshClosedException() => l10n.companionNotConnected,
      _ => l10n.companionSendFailed,
    };
  }

  /// Light mode: the reply comes straight from the model, and the conversation
  /// stays on this phone.
  Future<void> _sendLight(String text, bool Function() current) async {
    final key = ref.read(settingsProvider).apiKey.trim();
    if (key.isEmpty) throw const CompanionLightError(CompanionLightFailure.noKey);
    final history = _lightHistory ??= CompanionLightHistory.at(_store!.root);
    await history.load();
    // What she has been asked to remember, kept on this phone. Unreadable
    // memories only mean she talks without them this time.
    var memories = const <CompanionMemory>[];
    try {
      memories = (await _phoneKeeper.memories().timeout(const Duration(seconds: 2))).memories;
    } on Object {
      // Nothing to bring up this time.
    }
    // Switched to full (or away) while the history was read: this line is not
    // light mode's any more.
    if (!current()) return;
    final aside = companionAside(now: DateTime.now(), notes: List.of(_notes));
    history.add(CompanionLine.user([?aside, text].join('\n')));
    _notes.clear();
    // Nothing said before this page counts as news.
    _baselineSet = true;
    final turn = _lightTurn = 'light-${++_lightTurns}';
    _lightText = '';
    _lightAsked = text;
    final client = _lightClient = ref.read(companionLightClientProvider)();
    _lightReply =
        streamCompanionReply(
          client: client,
          apiKey: key,
          system: companionLightSystem(memories, persona: _persona()),
          lines: history.context(),
        ).listen(
          (delta) {
            if (!mounted || turn != _lightTurn) return;
            _lightText += delta;
            _onReply(turn, _lightText, running: true);
          },
          onError: (Object error) => _endLight(turn, error: error),
          onDone: () => _endLight(turn),
          cancelOnError: true,
        );
    _onReply(turn, '', running: true);
  }

  /// The light reply [turn] is over: finished, failed or stopped. What she
  /// said is kept; a line she never answered goes back into the input.
  void _endLight(String turn, {Object? error}) {
    if (turn != _lightTurn || _lightReply == null) return;
    _lightReply = null;
    _lightTurn = '';
    _lightClient?.close();
    _lightClient = null;
    final history = _lightHistory;
    final answered = _lightText.trim().isNotEmpty;
    if (answered) {
      history?.add(CompanionLine.her(_lightText));
    } else if (error != null) {
      history?.dropUnanswered();
    }
    if (history != null) unawaited(history.save());
    if (!mounted) return;
    if (!answered && error != null) {
      if (_input.text.isEmpty) _input.text = _lightAsked;
      _stage.command('emotion', {'name': 'worried', 'hold': 3000});
    }
    _onReply(turn, _lightText, running: false, error: error == null ? null : _failureText(error));
  }

  /// Ends the light reply on its way, at once: what she has said so far is
  /// kept, the request is dropped (its client closed first), and nothing it
  /// does later reaches the page. Cancelling can itself fail late (a timeout
  /// already under way); that is swallowed, not let loose.
  void _retireLight() {
    final reply = _lightReply;
    if (reply == null) return;
    _endLight(_lightTurn);
    unawaited(reply.cancel().catchError((Object _) {}));
  }

  Future<void> _stop() async {
    _acted();
    _hush();
    if (_lightReply != null) {
      _retireLight();
      return;
    }
    final id = _sessionId;
    if (id == null) return;
    await ref.read(chatProvider(id).notifier).cancel();
  }

  /// Switching modes on the page: drop the reply on its way and the other
  /// mode's conversation, then arrive again.
  void _modeChanged() {
    _boundLight = _light;
    _retireLight();
    setState(_unbind);
    if (!_stageReady) return;
    if (!_light) {
      final binding = ref.read(companionSessionsProvider.notifier).of(ref.read(activeHostProvider));
      if (binding != null) _bind(binding.sessionId);
    }
    // She is already here: no second hello.
    unawaited(_arrive(greet: false));
  }

  /// The backlog over her: this room's whole conversation, in either mode.
  Future<void> _openLog() async {
    _acted();
    if (_light && _store != null) {
      final history = _lightHistory ??= CompanionLightHistory.at(_store!.root);
      await history.load();
    }
    if (!mounted) return;
    _focus.unfocus();
    setState(() => _logOpen = true);
  }

  void _closeLog() {
    if (mounted && _logOpen) setState(() => _logOpen = false);
  }

  Widget _log(String name) {
    final sessionId = _sessionId;
    if (_light) {
      return CompanionLog(
        key: const ValueKey('log-light'),
        entries: companionLogFromLight(
          _lightHistory?.lines ?? const [],
          emotions: _moves.emotionLabels,
          actions: _moves.actionLabels,
          // What she is saying right now, already in her bubble.
          speaking: _lightReply != null && _lightText.isNotEmpty ? _lightText : null,
        ),
        name: name,
        onClose: _closeLog,
      );
    }
    // Full mode before her conversation there has begun: nothing said yet.
    if (sessionId == null) {
      return CompanionLog(key: const ValueKey('log-none'), entries: const [], name: name, onClose: _closeLog);
    }
    return Consumer(
      key: ValueKey('log-$sessionId'),
      builder: (context, ref, _) {
        final chat = ref.watch(
          chatProvider(sessionId).select((s) => (items: s.items, more: s.hasMoreHistory, loading: s.loadingOlder)),
        );
        return CompanionLog(
          entries: companionLogFromChat(chat.items, emotions: _moves.emotionLabels, actions: _moves.actionLabels),
          name: name,
          onClose: _closeLog,
          loadingOlder: chat.loading,
          history: chat.items.length,
          onLoadOlder: chat.more ? ref.read(chatProvider(sessionId).notifier).loadOlder : null,
          onOpenChat: () {
            _closeLog();
            _openFullChat();
          },
        );
      },
    );
  }

  void _openFullChat() {
    final id = _sessionId;
    if (id == null) return;
    ref.read(currentSessionProvider.notifier).select(id);
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  // ── Setup ────────────────────────────────────────────────────────────────

  /// A pack the person picks.
  Future<void> _import() => _installFrom((claim) async {
    final picked = await FilePicker.pickFile();
    if (picked == null) return null;
    // Picks may be content URIs: bring it somewhere the unzipper can seek.
    final temp = claim(
      '${(await getTemporaryDirectory()).path}/companion-import-${DateTime.now().microsecondsSinceEpoch}.zip',
    );
    final sink = temp.openWrite();
    try {
      await sink.addStream(picked.readAsByteStream());
    } finally {
      await sink.close();
    }
    return temp;
  });

  /// The pack inside the app, through the same checks as any other.
  /// [arriving]: the first time, she swims over while it unpacks.
  Future<void> _installBundled({bool arriving = false}) => _installFrom((claim) async {
    final bytes = await _bundled();
    if (bytes == null) throw const CompanionPackException(CompanionPackProblem.notAPack);
    final zip = claim('${_store!.root.parent.path}/companion-bundled-${DateTime.now().microsecondsSinceEpoch}.zip');
    await zip.writeAsBytes(bytes, flush: true);
    return zip;
  }, arriving: arriving);

  /// [bring] makes the zip to install, through `claim` for its temporary
  /// file: claimed before anything is written, so a write that fails halfway
  /// is cleaned up too (Pro C542).
  Future<void> _installFrom(
    Future<File?> Function(File Function(String path) claim) bring, {
    bool arriving = false,
  }) async {
    final store = _store;
    if (store == null || _installing) return;
    setState(() {
      _installing = true;
      _arriving = arriving;
      _installError = null;
    });
    File? temp;
    try {
      final zip = await bring((path) => temp = File(path));
      if (zip == null) return;
      try {
        await store.install(zip.path);
      } on CompanionPackException catch (error) {
        // A model on its own needs the runtime, which the pack inside the app
        // brings: unpack that first, then the model over it.
        final bundled = error.problem == CompanionPackProblem.noRuntime ? await _bundled() : null;
        if (bundled == null) rethrow;
        final runtime = File(
          '${store.root.parent.path}/companion-runtime-${DateTime.now().microsecondsSinceEpoch}.zip',
        );
        try {
          await runtime.writeAsBytes(bundled, flush: true);
          await store.install(runtime.path);
        } finally {
          if (await runtime.exists()) await runtime.delete();
        }
        await store.install(zip.path);
      }
      final character = await store.character();
      // She's back: the pack inside the app may come by itself again.
      unawaited(SharedPreferences.getInstance().then((p) => p.remove(_packRemovedKey)));
      if (!mounted) return;
      setState(() {
        _character = character;
        _failure = null;
        _stageReady = false;
        _phase = _Phase.stage;
      });
    } on CompanionPackException catch (error) {
      if (mounted) setState(() => _installError = _problemText(error.problem));
    } on Object {
      if (mounted) setState(() => _installError = context.l10n.companionPackBroken);
    } finally {
      try {
        await temp?.delete();
      } on FileSystemException {
        // Temp folder; the system clears it.
      }
      if (mounted) {
        setState(() {
          _installing = false;
          _arriving = false;
        });
      }
    }
  }

  /// Why she couldn't load, in words: a model too new for the runtime says so.
  String _loadFailureText(L10n l10n) {
    final why = _failure ?? '';
    final version = RegExp(r'moc-version (\d+)/(\d+)').firstMatch(why);
    if (version != null) return l10n.companionFailedMocVersion(version[1]!, version[2]!);
    return l10n.companionFailedBody(why);
  }

  String _problemText(CompanionPackProblem problem) {
    final l10n = context.l10n;
    return switch (problem) {
      CompanionPackProblem.runtimeMismatch => l10n.companionPackRuntimeMismatch,
      CompanionPackProblem.noRuntime => l10n.companionPackNoRuntime,
      CompanionPackProblem.noModel => l10n.companionPackNoModel,
      CompanionPackProblem.legacyModel => l10n.companionPackLegacyModel,
      CompanionPackProblem.forbiddenFile || CompanionPackProblem.unsafePath => l10n.companionPackUnsafe,
      CompanionPackProblem.tooLarge => l10n.companionPackTooLarge,
      CompanionPackProblem.storage => l10n.companionPackStorage,
      CompanionPackProblem.notAPack => l10n.companionPackBroken,
    };
  }

  // ── Menu ─────────────────────────────────────────────────────────────────

  void _chooseMode() {
    final l10n = context.l10n;
    final light = _light;
    unawaited(
      showAppSheet<void>(
        context,
        builder: (sheet) => SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SheetTitleBar(l10n.companionMenuMode),
              SheetGroup(
                margin: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 0, SheetTitleBar.inset, 12),
                children: [
                  for (final (mode, icon, title, hint) in [
                    (
                      CompanionMode.light,
                      AppIcons.engineStarting,
                      l10n.companionModeLight,
                      l10n.companionModeLightHint,
                    ),
                    (CompanionMode.full, AppIcons.engine, l10n.companionModeFull, l10n.companionModeFullHint),
                  ])
                    SettingsTile(
                      icon: icon,
                      tinted: false,
                      title: title,
                      subtitle: hint,
                      chevron: false,
                      trailing: (mode == CompanionMode.light) == light ? const Icon(AppIcons.selected, size: 20) : null,
                      onTap: () {
                        Navigator.of(sheet).pop();
                        unawaited(ref.read(companionModeProvider.notifier).choose(mode));
                      },
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openMenu() {
    _acted();
    final l10n = context.l10n;
    final light = _light;
    final credit = [
      if (_character.author case final author?) l10n.companionCreditAuthor(author),
      ?_character.license,
      ?_character.source,
    ].join(' · ');
    unawaited(
      showAppSheet<void>(
        context,
        // Scrolls on a short screen instead of overflowing.
        builder: (sheet) => SafeArea(
          top: false,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SheetTitleBar(ref.read(companionNameProvider) ?? _character.name ?? l10n.companionTitle),
                SheetGroup(
                  margin: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 0, SheetTitleBar.inset, 12),
                  children: [
                    SettingsTile(
                      icon: AppIcons.edit,
                      tinted: false,
                      title: l10n.companionMenuPersona,
                      value: Text(_name(l10n)),
                      onTap: () {
                        Navigator.of(sheet).pop();
                        unawaited(
                          Navigator.of(context).push(
                            MaterialPageRoute<void>(builder: (_) => CompanionPersonaPage(packName: _character.name)),
                          ),
                        );
                      },
                    ),
                    SettingsTile(
                      icon: AppIcons.configure,
                      tinted: false,
                      title: l10n.companionMenuAdapt,
                      value: _adapting
                          ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                          : null,
                      onTap: () {
                        Navigator.of(sheet).pop();
                        _openAdapt();
                      },
                    ),
                    SettingsTile(
                      icon: AppIcons.generating,
                      tinted: false,
                      title: l10n.companionMenuMoves,
                      value: Text('${_moves.expressions.length + _moves.motions.length}'),
                      onTap: () {
                        Navigator.of(sheet).pop();
                        _openMoves();
                      },
                    ),
                    // Only where her state is kept: otherwise there is nothing to show.
                    if (_vitals case final vitals?)
                      SettingsTile(
                        icon: AppIcons.postLike,
                        tinted: false,
                        title: l10n.companionBondTitle,
                        value: CompanionBondMeter(
                          step: companionBond(vitals.vitals.closeness),
                          label: switch (companionBond(vitals.vitals.closeness)) {
                            0 => l10n.companionBond0,
                            1 => l10n.companionBond1,
                            2 => l10n.companionBond2,
                            _ => l10n.companionBond3,
                          },
                        ),
                      ),
                    SettingsTile(
                      icon: light ? AppIcons.engineStarting : AppIcons.engine,
                      tinted: false,
                      title: l10n.companionMenuMode,
                      value: Text(light ? l10n.companionModeLight : l10n.companionModeFull),
                      onTap: () {
                        Navigator.of(sheet).pop();
                        _chooseMode();
                      },
                    ),
                    SettingsTile(
                      icon: AppIcons.bookmark,
                      tinted: false,
                      title: l10n.companionMemoryTitle,
                      onTap: () {
                        Navigator.of(sheet).pop();
                        unawaited(
                          Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => CompanionMemoryPage(phone: light ? _phoneKeeper : null),
                            ),
                          ),
                        );
                      },
                    ),
                    Consumer(
                      // The page's own context pushes the voice page, not the sheet's.
                      builder: (_, ref, _) {
                        final voice = ref.watch(companionVoiceSettingsProvider);
                        return SettingsTile(
                          icon: AppIcons.companionVoice,
                          tinted: false,
                          title: l10n.companionMenuVoice,
                          value: Text(switch (voice) {
                            CompanionVoiceSettings(on: true, source: CompanionVoiceSource.system) =>
                              l10n.companionVoiceSystem,
                            CompanionVoiceSettings(on: true, source: CompanionVoiceSource.preset) =>
                              voice.presetInfo.name,
                            CompanionVoiceSettings(on: true, source: CompanionVoiceSource.openai) =>
                              l10n.companionVoiceOpenai,
                            CompanionVoiceSettings(on: true, source: CompanionVoiceSource.custom) =>
                              l10n.companionVoiceCustom,
                            _ => l10n.companionVoiceOff,
                          }),
                          onTap: () {
                            Navigator.of(sheet).pop();
                            unawaited(
                              Navigator.of(context)
                                  .push(MaterialPageRoute<void>(builder: (_) => const CompanionVoicePage())),
                            );
                          },
                        );
                      },
                    ),
                    Consumer(
                      builder: (context, ref, _) => SettingsSwitchTile(
                        icon: AppIcons.companionInvite,
                        tinted: false,
                        title: l10n.companionMenuInvite,
                        subtitle: l10n.companionMenuInviteHint,
                        value: ref.watch(companionInitiativeEnabledProvider) ?? false,
                        onChanged: (on) => unawaited(ref.read(companionInitiativeEnabledProvider.notifier).set(on)),
                      ),
                    ),
                    if (light && (_lightHistory?.lines.isNotEmpty ?? false))
                      SettingsTile(
                        icon: AppIcons.newChat,
                        tinted: false,
                        title: l10n.companionMenuRestart,
                        subtitle: l10n.companionMenuRestartLightHint,
                        onTap: () {
                          Navigator.of(sheet).pop();
                          unawaited(_restart());
                        },
                      ),
                    if (_sessionId != null || (light && (_lightHistory?.lines.isNotEmpty ?? false)))
                      SettingsTile(
                        icon: AppIcons.history,
                        tinted: false,
                        title: l10n.companionMenuHistory,
                        onTap: () {
                          Navigator.of(sheet).pop();
                          unawaited(_openLog());
                        },
                      ),
                    if (_sessionId != null)
                      SettingsTile(
                        icon: AppIcons.newChat,
                        tinted: false,
                        title: l10n.companionMenuRestart,
                        subtitle: l10n.companionMenuRestartHint,
                        onTap: () {
                          Navigator.of(sheet).pop();
                          unawaited(_restart());
                        },
                      ),
                    SettingsTile(
                      icon: AppIcons.delete,
                      tinted: false,
                      title: l10n.companionMenuRemovePack,
                      onTap: () {
                        Navigator.of(sheet).pop();
                        unawaited(_removePack());
                      },
                    ),
                  ],
                ),
                if (credit.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(SheetTitleBar.inset + 8, 0, SheetTitleBar.inset + 8, 12),
                    child: Text(credit, style: Theme.of(sheet).textTheme.bodySmall),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<bool> _confirm(String action, String message) async {
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(action),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(dialog.l10n.commonCancel)),
          FilledButton(onPressed: () => Navigator.pop(dialog, true), child: Text(action)),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<void> _restart() async {
    final l10n = context.l10n;
    final light = _light;
    final ok = await _confirm(
      l10n.companionMenuRestart,
      light ? l10n.companionMenuRestartLightConfirm : l10n.companionMenuRestartConfirm,
    );
    if (!ok || !mounted) return;
    if (light) {
      // The reply still on its way would otherwise write itself back after the clear.
      _retireLight();
      await _lightHistory?.clear();
      if (!mounted) return;
      _say(_firstHello(l10n));
      return;
    }
    await ref.read(companionSessionsProvider.notifier).forget();
    if (!mounted) return;
    setState(_unbind);
    _say(_firstHello(l10n));
  }

  Future<void> _removePack() async {
    final l10n = context.l10n;
    final ok = await _confirm(
      l10n.companionMenuRemovePack,
      _bundledHere ? l10n.companionMenuRemoveConfirmBundled : l10n.companionMenuRemoveConfirm,
    );
    if (!ok || !mounted) return;
    // Removed on purpose: the pack inside the app doesn't come back by itself.
    unawaited(SharedPreferences.getInstance().then((p) => p.setBool(_packRemovedKey, true)));
    setState(() {
      _phase = _Phase.setup;
      _stageReady = false;
      _adaptOffer = null;
      _probe = null;
    });
    await _store?.remove();
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // Changing host while here: her conversation is per host.
    ref.listen(activeHostProvider, (_, _) => _bindingChanged());
    ref.listen(activeConnectionProvider.select((value) => value.value?.client), (_, _) => _bindingChanged());
    ref.listen(companionModeProvider, (before, now) {
      // The saved pick arriving after the page opened changes nothing if it is what she already does.
      bool light(CompanionMode? mode) =>
          mode == CompanionMode.light || (mode == null && ref.read(activeConnectionProvider).value == null);
      if (light(before) != light(now)) _modeChanged();
    });
    // What her invitation depends on that only a build can see: this page in
    // front (a sheet or another page over her isn't), a screen reader, the switch.
    _routeShown = TickerMode.valuesOf(context).enabled && (ModalRoute.isCurrentOf(context) ?? true);
    _accessible = MediaQuery.accessibleNavigationOf(context);
    ref.watch(companionInitiativeEnabledProvider);
    ref.watch(companionNameProvider);
    ref.listen(companionRenamedProvider, (_, name) {
      if (name == null) return;
      ref.read(companionRenamedProvider.notifier).set(null);
      // After the page over her has gone.
      Timer(const Duration(milliseconds: 450), () => _renamedTo(name));
    });
    _queueObserve();
    final surfaces = DshSurfaces.of(context);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
      // The water is dark at every hour, whatever the app's own theme.
      child: Theme(
        data: buildDarkTheme(accent: surfaces.accent, glassBlur: surfaces.blurEnabled),
        child: PopScope(
          canPop: !_logOpen,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) _closeLog();
          },
          child: Builder(builder: _buildPage),
        ),
      ),
    );
  }

  Widget _buildPage(BuildContext context) {
    final l10n = context.l10n;
    final insets = MediaQuery.viewInsetsOf(context).bottom;
    final padding = MediaQuery.paddingOf(context);
    final store = _store;
    final showStage = _phase == _Phase.stage && store != null;
    final name = _name(l10n);
    // Shown only while it still belongs here and nothing else has the floor,
    // in this very frame (the owner hears about it right after).
    final invite = _invite;
    final inviting =
        invite != null && invite.ticket.contextKey == _initiativeContext && _presentable(_initiativeView());
    final inviteLeft = switch (_inviteEnds) {
      final ends? when inviting => Duration(
        milliseconds: max(0, ends - ref.read(companionInitiativeClockProvider)().monoMs),
      ),
      _ => null,
    };
    final events = CompanionStageEvents(
      onReady: _onReady,
      onFailed: (why) {
        if (!mounted) return;
        setState(() {
          _phase = _Phase.failed;
          _failure = why;
        });
      },
      onTouch: _onTouch,
      onWake: () => _say(l10n.companionWake),
      onMood: _onMood,
      onObject: _onObject,
      onActivity: _onActivity,
      onModel: (info) => unawaited(_onModel(info)),
      onProbe: _onProbe,
    );
    return Scaffold(
      backgroundColor: const Color(0xFF0D2F55),
      resizeToAvoidBottomInset: false,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (showStage)
            // A finger landing on her already counts, before the stage knows
            // whether it was a tap, a pat or nothing (C452 §5.1).
            Listener(
              onPointerDown: (_) => _acted(),
              child: ExcludeSemantics(
                child:
                    widget.stageBuilder?.call(_stage, events) ??
                    CompanionStage(store: store, controller: _stage, events: events),
              ),
            ),
          if ((showStage && !_stageReady) || (_phase == _Phase.setup && _arriving))
            const CompanionWater(child: CompanionArriving())
          else if (_phase == _Phase.setup)
            CompanionWelcome(
              title: l10n.companionSetupTitle,
              message: _bundledHere ? l10n.companionSetupBodyBundled : l10n.companionSetupBody,
              action: _bundledHere ? l10n.companionSetupBundled : l10n.companionSetupImport,
              busy: _installing,
              error: _installError,
              onAction: _bundledHere ? _installBundled : _import,
              secondary: _bundledHere ? l10n.companionSetupImportOther : null,
              onSecondary: _import,
            ),
          if (_phase == _Phase.failed)
            CompanionWelcome(
              title: l10n.companionFailedTitle,
              message: _loadFailureText(l10n),
              action: l10n.companionSetupImport,
              state: PetStateName.error,
              busy: _installing,
              error: _installError,
              onAction: _import,
            ),
          Positioned(
            top: padding.top + 8,
            left: companionEdge,
            right: companionEdge,
            child: Row(
              children: [
                CompanionRoundButton(
                  icon: AppIcons.back,
                  label: MaterialLocalizations.of(context).backButtonTooltip,
                  onTap: () {
                    _acted();
                    unawaited(Navigator.of(context).maybePop());
                  },
                ),
                const SizedBox(width: 52),
                Expanded(
                  child: Center(
                    child: _stageReady ? CompanionNamePlate(name: name, activity: _activity) : const SizedBox.shrink(),
                  ),
                ),
                if (_stageReady) ...[
                  CompanionRoundButton(icon: AppIcons.history, label: l10n.companionLogTitle, onTap: _openLog),
                  const SizedBox(width: 8),
                  CompanionRoundButton(icon: AppIcons.more, label: l10n.companionMenu, onTap: _openMenu),
                ] else
                  const SizedBox(width: 96),
              ],
            ),
          ),
          if (showStage && _stageReady)
            Positioned(
              left: companionEdge,
              right: companionEdge,
              bottom: max(insets, padding.bottom) + companionEdge,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Her invitation takes the hint's place while it's there.
                  if (_showTouchHint && _bubble == null && !inviting)
                    CompanionPill(icon: AppIcons.tip, label: l10n.companionTouchHint)
                  else if (_showHomeHint && _bubble == null && !inviting)
                    CompanionPill(icon: AppIcons.tip, label: l10n.companionTouchHintHome),
                  if (_voiceNotice case final notice?) CompanionPill(icon: AppIcons.tip, label: notice),
                  if (_agentPill case final pill?)
                    CompanionPill(
                      icon: AppIcons.conversations,
                      label: pill.label,
                      tone: const Color(0xFF9FD8F2),
                      onTap: () {
                        _acted();
                        _openAgent(pill.sessionId);
                      },
                    ),
                  if (!_light && _sessionId != null) CompanionAsk(sessionId: _sessionId!),
                  CompanionMyLine(text: _myLine),
                  CompanionSpeech(
                    text: _bubble,
                    error: _bubbleIsError,
                    thinking: _sending || (_running && _bubble == null),
                    onPullBack: _openLog,
                  ),
                  CompanionInvite(
                    ticket: _adaptOffer == null || inviting ? null : 'adapt-${_adaptOffer!.moc}',
                    mark: const Icon(AppIcons.configure, size: 20, color: Color(0xFFFFD27A)),
                    text: l10n.companionAdaptOffer,
                    accept: l10n.companionAdaptOfferYes,
                    decline: l10n.companionAdaptOfferNo,
                    onAccept: () => unawaited(_answerAdaptOffer(yes: true)),
                    onDecline: () => unawaited(_answerAdaptOffer(yes: false)),
                  ),
                  CompanionInvite(
                    ticket: inviting ? invite.ticket.id : null,
                    text: l10n.companionInviteRest,
                    accept: l10n.companionInviteAccept,
                    decline: l10n.companionInviteDecline,
                    remaining: inviteLeft,
                    total: const Duration(milliseconds: CompanionInitiativeRules.promptMs),
                    onAccept: () => _answerInvite(yes: true),
                    onDecline: () => _answerInvite(yes: false),
                  ),
                  const SizedBox(height: 10),
                  CompanionComposer(
                    onUserInput: () {
                      _acted();
                      _hush();
                    },
                    input: _input,
                    focus: _focus,
                    hint: l10n.companionInputHint(name),
                    running: _running,
                    busy: _sending,
                    listening: _voice.active,
                    voiceAvailable: _voice.available,
                    onSend: _send,
                    onStop: _stop,
                    onVoice: () {
                      // Reaching for the microphone is already doing something.
                      _acted();
                      // Her voice off before the microphone opens.
                      _hush();
                      _voice.active ? _voice.stop() : _voice.start();
                    },
                  ),
                ],
              ),
            ),
          Positioned.fill(child: CompanionLogTransition(child: _logOpen && showStage ? _log(name) : null)),
        ],
      ),
    );
  }
}

/// A new name for one of her moves: the dialog owns its field.
class _LabelDialog extends StatefulWidget {
  const _LabelDialog({required this.initial, required this.hint});

  final String initial;
  final String hint;

  @override
  State<_LabelDialog> createState() => _LabelDialogState();
}

class _LabelDialogState extends State<_LabelDialog> {
  late final _field = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.companionMovesRename),
      content: TextField(
        controller: _field,
        autofocus: true,
        maxLength: 16,
        decoration: InputDecoration(hintText: widget.hint),
        onSubmitted: (value) => Navigator.pop(context, value),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l10n.commonCancel)),
        FilledButton(onPressed: () => Navigator.pop(context, _field.text), child: Text(l10n.commonSave)),
      ],
    );
  }
}

/// 适配这个模型: what to tell her AI, and whether new models are fitted on
/// their own. The sheet owns its field.
class _AdaptSheet extends StatefulWidget {
  const _AdaptSheet({required this.adapted, required this.onRun, required this.onUndo});

  final bool adapted;
  final ValueChanged<String> onRun;
  final VoidCallback onUndo;

  @override
  State<_AdaptSheet> createState() => _AdaptSheetState();
}

class _AdaptSheetState extends State<_AdaptSheet> {
  final _note = TextEditingController();
  bool? _auto;

  @override
  void initState() {
    super.initState();
    unawaited(
      companionAdaptAuto().then((on) {
        if (mounted) setState(() => _auto = on);
      }),
    );
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    const inset = EdgeInsets.fromLTRB(SheetTitleBar.inset + 8, 0, SheetTitleBar.inset + 8, 12);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SheetTitleBar(l10n.companionMenuAdapt),
              Padding(
                padding: inset,
                child: Text(l10n.companionAdaptHint, style: Theme.of(context).textTheme.bodySmall),
              ),
              Padding(
                padding: inset,
                child: TextField(
                  controller: _note,
                  minLines: 1,
                  maxLines: 3,
                  maxLength: 200,
                  decoration: InputDecoration(
                    labelText: l10n.companionAdaptNote,
                    hintText: l10n.companionAdaptNoteHint,
                  ),
                ),
              ),
              SheetGroup(
                margin: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 0, SheetTitleBar.inset, 12),
                children: [
                  SettingsTile(
                    tinted: false,
                    title: l10n.companionAdaptAuto,
                    chevron: false,
                    trailing: Switch(
                      value: _auto ?? true,
                      onChanged: _auto == null
                          ? null
                          : (on) {
                              setState(() => _auto = on);
                              unawaited(companionAdaptSetAuto(on));
                            },
                    ),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 0, SheetTitleBar.inset, 16),
                child: Row(
                  children: [
                    if (widget.adapted) TextButton(onPressed: widget.onUndo, child: Text(l10n.companionAdaptUndo)),
                    const Spacer(),
                    FilledButton(onPressed: () => widget.onRun(_note.text), child: Text(l10n.companionAdaptRun)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
