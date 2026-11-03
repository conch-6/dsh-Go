import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../notify/chat_alerts.dart';
import '../notify/answer_native_request.dart';
import '../notify/notify_channel.dart';
import '../phone/phone_channel.dart';
import '../phone/phone_approval.dart';
import '../pets/pet_signals.dart' show petHearAlert, petOnScreenProvider;
import 'app_info.dart';
import 'bots_state.dart';
import 'chat_state.dart';
import 'connection_state.dart';
import 'hosts_state.dart';
import 'phone_turn_end.dart';
import 'phone_state.dart' show phoneChannelProvider;
import 'sessions_state.dart';

export '../notify/chat_alerts.dart';
export '../notify/notify_channel.dart';

final notifyChannelProvider = Provider<NotifyChannel>((ref) => NotifyChannel());

// ── Settings ─────────────────────────────────────────────────────────────────

/// 设置 → 通知: a master switch plus one per kind of event.
class NotifyPrefs {
  const NotifyPrefs({
    this.enabled = true,
    this.done = true,
    this.failed = true,
    this.approval = true,
    this.question = true,
    this.live = true,
    this.loaded = false,
  });

  final bool enabled;

  /// 一轮正常完成.
  final bool done;

  /// 一轮出错或被停下.
  final bool failed;

  /// 等你确认（审批）.
  final bool approval;

  /// 向你提问.
  final bool question;

  /// 实时活动: the status bar chip / island while DSH works (lib/notify/live_activity.dart).
  final bool live;
  final bool loaded;

  bool allows(AlertKind kind) =>
      enabled &&
      switch (kind) {
        AlertKind.done => done,
        AlertKind.failed || AlertKind.stopped => failed,
        AlertKind.approval => approval,
        AlertKind.question => question,
      };

  NotifyPrefs copyWith({
    bool? enabled,
    bool? done,
    bool? failed,
    bool? approval,
    bool? question,
    bool? live,
    bool? loaded,
  }) => NotifyPrefs(
    enabled: enabled ?? this.enabled,
    done: done ?? this.done,
    failed: failed ?? this.failed,
    approval: approval ?? this.approval,
    question: question ?? this.question,
    live: live ?? this.live,
    loaded: loaded ?? this.loaded,
  );
}

class NotifyPrefsController extends Notifier<NotifyPrefs> {
  static const _keys = (
    enabled: 'notify_enabled',
    done: 'notify_done',
    failed: 'notify_failed',
    approval: 'notify_approval',
    question: 'notify_question',
    live: 'notify_live',
  );

  late Future<void> _loaded;

  @override
  NotifyPrefs build() {
    _loaded = _load();
    return const NotifyPrefs();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      state = NotifyPrefs(
        enabled: prefs.getBool(_keys.enabled) ?? true,
        done: prefs.getBool(_keys.done) ?? true,
        failed: prefs.getBool(_keys.failed) ?? true,
        approval: prefs.getBool(_keys.approval) ?? true,
        question: prefs.getBool(_keys.question) ?? true,
        live: prefs.getBool(_keys.live) ?? true,
        loaded: true,
      );
    } catch (_) {
      // No preferences backend (tests): defaults, all on.
      state = state.copyWith(loaded: true);
    }
  }

  /// Applies after the stored values are in, so a load finishing late can't
  /// undo a switch flipped right after launch.
  Future<void> _save(String key, bool value, NotifyPrefs Function(NotifyPrefs) apply) async {
    await _loaded;
    state = apply(state);
    try {
      await (await SharedPreferences.getInstance()).setBool(key, value);
    } catch (_) {
      // Kept for this run only.
    }
  }

  Future<void> setEnabled(bool v) => _save(_keys.enabled, v, (s) => s.copyWith(enabled: v));
  Future<void> setDone(bool v) => _save(_keys.done, v, (s) => s.copyWith(done: v));
  Future<void> setFailed(bool v) => _save(_keys.failed, v, (s) => s.copyWith(failed: v));
  Future<void> setApproval(bool v) => _save(_keys.approval, v, (s) => s.copyWith(approval: v));
  Future<void> setQuestion(bool v) => _save(_keys.question, v, (s) => s.copyWith(question: v));
  Future<void> setLive(bool v) => _save(_keys.live, v, (s) => s.copyWith(live: v));
}

final notifyPrefsProvider = NotifierProvider<NotifyPrefsController, NotifyPrefs>(NotifyPrefsController.new);

/// What the system allows; re-read with `ref.invalidate` (the settings page
/// does on resume, after the person may have changed it).
final notifySystemStatusProvider = FutureProvider<NotifySystemStatus>(
  (ref) => ref.watch(notifyChannelProvider).status(),
);

// ── Where the person is looking ──────────────────────────────────────────────

/// A simple settable flag (set by [ChatAlertHost] in the UI).
class FlagController extends Notifier<bool> {
  FlagController(this._initial);

  final bool _initial;

  @override
  bool build() => _initial;

  void set(bool value) {
    if (value != state) state = value;
  }
}

/// The app is on screen (resumed or briefly inactive, e.g. the notification
/// shade is down). Set from the app lifecycle by the alert host.
final appForegroundProvider = NotifierProvider<FlagController, bool>(() => FlagController(true));

/// The chat is the current route (no settings page or sheet pushed over it).
final chatOnScreenProvider = NotifierProvider<FlagController, bool>(() => FlagController(true));

/// Something asked for the person's attention unbidden in this launch (the
/// usage statistics toast, an update offer, the background running line):
/// the star prompt waits for another launch.
final launchNoticeShownProvider = NotifierProvider<FlagController, bool>(() => FlagController(false));

/// A conversation on a host.
typedef ChatTarget = ({HostRef host, String sessionId});

/// The conversation the person is looking at right now, or null.
final viewedChatProvider = Provider<ChatTarget?>((ref) {
  if (!ref.watch(appForegroundProvider) || !ref.watch(chatOnScreenProvider)) return null;
  final session = ref.watch(currentSessionProvider);
  if (session == null) return null;
  return (host: ref.watch(activeHostProvider), sessionId: session);
});

// ── Delivery ─────────────────────────────────────────────────────────────────

/// Where a connected host's alerts come from (tests swap in a fake).
final alertSourceFactoryProvider = Provider<AlertSource Function(HostConnection connection)>(
  (ref) =>
      (connection) => DshAlertSource(connection.client),
);

/// How long a request waits before alerting, and how long after a reconnect
/// the Host gets to redeliver what is still pending.
final alertTimingProvider = Provider<({Duration announce, Duration reconcile})>(
  (ref) => (announce: const Duration(milliseconds: 800), reconcile: const Duration(seconds: 3)),
);

enum AlertDelivery { none, banner, pet, system }

/// System notification in the background, a banner in the foreground — or
/// the pet's bubble when it is on screen ([petOnScreen]: one reminder, not
/// two) — and nothing for the conversation already on screen.
AlertDelivery deliveryFor(
  ChatAlert alert, {
  required NotifyPrefs prefs,
  required bool foreground,
  ChatTarget? viewed,
  bool petOnScreen = false,
}) {
  if (!prefs.allows(alert.kind)) return AlertDelivery.none;
  if (viewed != null && viewed.host == alert.host && viewed.sessionId == alert.sessionId) return AlertDelivery.none;
  if (!foreground) return AlertDelivery.system;
  return petOnScreen ? AlertDelivery.pet : AlertDelivery.banner;
}

NotifyPost postFor(ChatAlert alert) => NotifyPost(
  group: notifyGroup(alert.host, alert.sessionId),
  key: alert.key,
  attention: alert.kind.attention,
  title: alert.title,
  text: alert.text,
  publicText: alert.kind.publicText,
  sessionId: alert.sessionId,
  host: alert.host,
  kind: alert.kind.name,
  eventId: alert.eventId,
  canApprove: alert.canApprove,
  fullText: alert.fullText,
);

class _PhoneAlertPrompt {
  _PhoneAlertPrompt({
    required this.scope,
    required this.lifetime,
    required this.requestId,
    required this.alert,
    required this.client,
    required this.generation,
    required this.tracker,
    required this.requestScope,
    required this.channel,
  });

  final Ref scope;
  final Object lifetime;
  final String requestId;
  final ChatAlert alert;
  final DshClient client;
  final MuxGeneration? generation;
  final HostAlertTracker tracker;
  final Object requestScope;
  final PhoneChannel channel;
  StreamSubscription<DshConnectionState>? mux;
  StreamSubscription<PhoneStatus>? status;
  bool submitted = false;

  void retire() {
    unawaited(mux?.cancel());
    unawaited(status?.cancel());
    if (submitted) unawaited(channel.cancelPrompt(requestId));
  }
}

/// Watches the on-device engine and the active remote host for alerts, posts
/// system notifications or raises the in-app banner (the state: the banner on
/// screen, or null), and clears what the person has seen.
///
/// Remote hosts are best effort: alerts come only while the app process lives
/// and the link is up.
class ChatAlertsController extends Notifier<ChatAlert?> {
  final Map<HostRef, (HostConnection, HostAlertTracker)> _trackers = {};
  Object _lifetime = Object();
  _PhoneAlertPrompt? _phonePrompt;

  /// False while [build] runs (listeners fire immediately, before there is a
  /// state to read or replace).
  bool _built = false;
  StreamSubscription<NotifyAction>? _actions;

  NotifyChannel get _channel => ref.read(notifyChannelProvider);

  ChatAlert? get _banner => _built ? state : null;

  set _banner(ChatAlert? value) {
    if (_built) state = value;
  }

  @override
  ChatAlert? build() {
    _built = false;
    _lifetime = Object();
    final channel = _channel;
    unawaited(() async {
      if (!(await channel.status()).native || !ref.mounted) return;
      _actions = channel.actions.listen((action) async {
        await channel.completeAction(action, await respondAction(action));
      });
    }());
    ref.onDispose(() {
      _lifetime = Object();
      _cancelPhonePrompt();
      unawaited(_actions?.cancel());
      for (final (_, tracker) in _trackers.values) {
        unawaited(tracker.dispose());
      }
      _trackers.clear();
    });
    // Watching the phone task from the start, wherever alerts are (web mode too), so the turn
    // that drove the phone is known when it ends (_onAlert).
    ref.listen(phoneTurnEndProvider, (_, _) {});
    ref.listen(localConnectionProvider, (_, next) {
      _attach(HostRef.local, next.value);
    }, fireImmediately: true);
    ref.listen(activeConnectionProvider, (_, next) {
      final conn = next.value;
      final host = conn == null ? null : _remoteRef(conn);
      for (final other in [..._trackers.keys]) {
        if (!other.isLocal && other != host) _attach(other, null);
      }
      if (host != null) _attach(host, conn);
    }, fireImmediately: true);
    ref.listen(viewedChatProvider, (_, viewed) {
      if (viewed != null) _seen(viewed);
    }, fireImmediately: true);
    ref.listen(notifyPrefsProvider.select((p) => p.enabled), (was, enabled) {
      // Switched off: what is already in the shade goes too.
      if (was == true && !enabled) {
        _banner = null;
        unawaited(_channel.cancelAll());
      }
    });
    ref.listen(appForegroundProvider, (_, foreground) {
      // Leaving the app with a banner up: keep it as a notification.
      final banner = _banner;
      if (!foreground && banner != null) {
        _banner = null;
        if (!banner.kind.attention || !banner.host.isLocal) unawaited(_channel.show(postFor(banner)));
      }
      if (!foreground) {
        // An approval can already be visible in the chat when the person
        // leaves for another app. It still needs an operational prompt.
        final pending = _trackers[HostRef.local]?.$2.pendingAlerts.toList() ?? const <ChatAlert>[];
        for (final alert in pending) {
          if (!_offerPhonePrompt(alert)) _deliver(alert);
        }
      }
    });
    _built = true;
    return null;
  }

  /// Answers the approval behind a tapped notification button on its host.
  Future<NotifyActionResult> respondAction(NotifyAction action) async {
    final attached = _trackers[action.host];
    if (attached == null || !attached.$2.source.connected) return NotifyActionResult.failed;
    final request = attached.$2.approvalFor(action.eventId);
    if (request == null) return NotifyActionResult.gone;
    try {
      await attached.$1.client.respondApproval(request, action.decision);
      return NotifyActionResult.handled;
    } catch (_) {
      return NotifyActionResult.failed;
    }
  }

  /// Answers a request from the floating pet's bubble, the way the
  /// notification's buttons do: an approval only if the bubble showed all of
  /// it ([HostAlertTracker.petApprovalFor]) and only allow once / reject; a
  /// question only with one of its own choices ([petChoices]).
  Future<NotifyActionResult> answerFromPet(
    HostRef host,
    String eventId, {
    required String sessionId,
    required int token,
    ApprovalDecision? decision,
    String? choice,
  }) async {
    final attached = _trackers[host];
    if (attached == null || !attached.$2.source.connected) return NotifyActionResult.failed;
    final generation = attached.$1.client.mux.generation;
    final lifetime = _lifetime;
    bool current() =>
        ref.mounted &&
        identical(_lifetime, lifetime) &&
        identical(_trackers[host]?.$2, attached.$2) &&
        attached.$2.petRequestMatches(eventId, sessionId, token);
    if (!current()) return NotifyActionResult.gone;
    if (generation == null) return NotifyActionResult.failed;
    try {
      if (decision != null) {
        if (decision != ApprovalDecision.allowOnce && decision != ApprovalDecision.reject) {
          return NotifyActionResult.failed;
        }
        final request = attached.$2.petApprovalFor(eventId);
        if (request == null) {
          return attached.$2.approvalFor(eventId) == null ? NotifyActionResult.gone : NotifyActionResult.failed;
        }
        final sent = await answerPhoneApproval(
          client: attached.$1.client,
          generation: generation,
          request: request,
          decision: decision,
          current: current,
        );
        return sent ? NotifyActionResult.handled : NotifyActionResult.gone;
      }
      final request = attached.$2.questionFor(eventId);
      if (request == null) return NotifyActionResult.gone;
      final choices = petChoices(request);
      if (choice == null || choices == null || !choices.contains(choice)) return NotifyActionResult.failed;
      final sent = await answerNativeRequest(
        client: attached.$1.client,
        generation: generation,
        eventId: request.eventId,
        outcome: {
          'kind': 'result',
          'value': {
            'answers': [
              QuestionAnswer(request.questions.single.id, selected: [choice]).toJson(),
            ],
          },
        },
        current: current,
      );
      return sent ? NotifyActionResult.handled : NotifyActionResult.gone;
    } catch (_) {
      return NotifyActionResult.failed;
    }
  }

  /// The host a remote connection belongs to; null for 本机.
  HostRef? _remoteRef(HostConnection connection) {
    final id = connection.hostId;
    if (connection.isLocal || id == null) return null;
    final active = ref.read(activeHostProvider);
    return switch (connection.kind) {
      HostKind.local => null,
      HostKind.ssh => HostRef.ssh(id),
      HostKind.relay => HostRef.relay(id, name: active.id == id ? active.name : null),
    };
  }

  void _attach(HostRef host, HostConnection? connection) {
    final current = _trackers[host];
    if (current != null && identical(current.$1.client, connection?.client)) return;
    if (current != null) {
      _cancelPhonePrompt(host: host);
      _trackers.remove(host);
      unawaited(current.$2.dispose());
    }
    if (connection == null) return;
    final timing = ref.read(alertTimingProvider);
    final tracker = HostAlertTracker(
      host: host,
      source: ref.read(alertSourceFactoryProvider)(connection),
      onAlert: _onAlert,
      onWithdraw: _onWithdraw,
      onSessionGone: _onSessionGone,
      onReannounce: (alert) => _offerPhonePrompt(alert),
      onRequestEpochChanged: (host) => _cancelPhonePrompt(host: host),
      skipApproval: (sessionId) => ref.exists(chatProvider(sessionId)) && ref.read(chatProvider(sessionId)).autoApprove,
      announceDelay: timing.announce,
      reconcileDelay: timing.reconcile,
    );
    _trackers[host] = (connection, tracker);
    tracker.start();
  }

  void _onAlert(ChatAlert alert, {bool ownerWaited = false}) {
    final scope = ref;
    final lifetime = _lifetime;
    final attached = _trackers[alert.host];
    if (attached == null) return;
    final generation = attached.$1.client.mux.generation;
    bool current() =>
        scope.mounted &&
        identical(_lifetime, lifetime) &&
        identical(_trackers[alert.host]?.$2, attached.$2) &&
        identical(attached.$1.client.mux.generation, generation) &&
        attached.$2.source.connected;
    if (_offerPhonePrompt(alert)) return;
    // The turn that drove the phone: its overlay closes and the app may come
    // back to the conversation first (state/phone_turn_end.dart); the alert
    // follows, so it lands where the person is by then.
    final phoneController = ref.read(phoneTurnEndProvider.notifier);
    if (!ownerWaited &&
        phoneController.deferTurnEnd(alert, () {
          if (current()) _onAlert(alert, ownerWaited: true);
        })) {
      return;
    }
    final phone = phoneController.onTurnEnd(alert);
    if (phone == null) return _deliver(alert);
    unawaited(
      phone.then((result) {
        // Asked back and blocked (some vendors): the notification is the way there.
        if (current() && result.current && !result.notified) _deliver(alert);
      }),
    );
  }

  bool _phoneCurrent(_PhoneAlertPrompt prompt) =>
      prompt.scope.mounted &&
      identical(_lifetime, prompt.lifetime) &&
      identical(_phonePrompt, prompt) &&
      identical(_trackers[prompt.alert.host]?.$2, prompt.tracker) &&
      identical(_trackers[prompt.alert.host]?.$1.client, prompt.client) &&
      identical(prompt.client.mux.generation, prompt.generation) &&
      identical(prompt.tracker.requestScope(prompt.alert.eventId!), prompt.requestScope);

  void _cancelPhonePrompt({HostRef? host, String? sessionId, String? eventId}) {
    final prompt = _phonePrompt;
    if (prompt == null ||
        (host != null && prompt.alert.host != host) ||
        (sessionId != null && prompt.alert.sessionId != sessionId) ||
        (eventId != null && prompt.alert.eventId != eventId)) {
      return;
    }
    _phonePrompt = null;
    prompt.retire();
  }

  bool _offerPhonePrompt(ChatAlert alert) {
    if (!alert.host.isLocal ||
        !alert.kind.attention ||
        alert.eventId == null ||
        ref.read(appForegroundProvider) ||
        _phonePrompt != null ||
        ref.read(dsBotSessionFilterProvider)(alert.host, alert.sessionId)) {
      return false;
    }
    final attached = _trackers[alert.host];
    final requestScope = attached?.$2.requestScope(alert.eventId!);
    if (attached == null || requestScope == null) return false;
    final random = Random.secure();
    final prompt = _PhoneAlertPrompt(
      scope: ref,
      lifetime: _lifetime,
      requestId: base64UrlEncode(List.generate(24, (_) => random.nextInt(256))),
      alert: alert,
      client: attached.$1.client,
      generation: attached.$1.client.mux.generation,
      tracker: attached.$2,
      requestScope: requestScope,
      channel: ref.read(phoneChannelProvider),
    );
    _phonePrompt = prompt;
    prompt.mux = prompt.client.mux.states.listen((_) {
      if (identical(_phonePrompt, prompt)) _cancelPhonePrompt();
    });
    unawaited(_runPhonePrompt(prompt));
    return true;
  }

  Future<void> _phoneFallback(_PhoneAlertPrompt prompt) async {
    if (!_phoneCurrent(prompt)) return;
    if (prompt.scope.read(appForegroundProvider)) {
      // The native app fallback may already have brought the person here.
      final viewed = prompt.scope.read(viewedChatProvider);
      if (viewed?.host != prompt.alert.host || viewed?.sessionId != prompt.alert.sessionId) _banner = prompt.alert;
      return;
    }
    // A phone operation waiting on a person remains accessible even when
    // ordinary chat notifications are off. This last fallback only opens the
    // exact conversation; it never offers a truncated approval action.
    await prompt.scope
        .read(notifyChannelProvider)
        .tryShow(
          NotifyPost(
            group: notifyGroup(prompt.alert.host, prompt.alert.sessionId),
            key: prompt.alert.key,
            attention: true,
            title: AppInfo.name,
            text: prompt.alert.text,
            publicText: prompt.alert.kind.publicText,
            sessionId: prompt.alert.sessionId,
            host: prompt.alert.host,
            kind: prompt.alert.kind.name,
            eventId: prompt.alert.eventId,
          ),
          stillCurrent: () => _phoneCurrent(prompt) && !prompt.scope.read(appForegroundProvider),
        );
  }

  Future<void> _runPhonePrompt(_PhoneAlertPrompt prompt) async {
    var enabled = false;
    try {
      final status = await prompt.channel.status().timeout(const Duration(seconds: 2));
      if (!_phoneCurrent(prompt)) return;
      if (!status.ready || !status.enabled || status.task.stopped || prompt.scope.read(appForegroundProvider)) {
        _deliver(prompt.alert);
        return;
      }
      enabled = true;
      final taskId = status.task.active ? status.task.id : null;
      if (status.task.active && taskId == null) {
        await _phoneFallback(prompt);
        return;
      }
      prompt.status = prompt.channel.statusChanges.listen((next) {
        if (!identical(_phonePrompt, prompt)) return;
        if (!next.ready ||
            !next.enabled ||
            next.task.stopped ||
            (taskId == null ? next.task.active : !next.task.active || next.task.id != taskId)) {
          _cancelPhonePrompt();
        }
      }, onError: (_) => _cancelPhonePrompt());
      final approval = prompt.tracker.phoneApprovalFor(prompt.alert.eventId!);
      prompt.submitted = true;
      final result = await prompt.channel.presentPrompt(
        requestId: prompt.requestId,
        taskId: taskId,
        sessionId: prompt.alert.sessionId,
        host: prompt.alert.host.encode(),
        text: approval?.text ?? prompt.alert.fullText ?? prompt.alert.text,
        canApprove: approval != null,
      );
      if (!_phoneCurrent(prompt)) return;
      final decision = switch (result.decision) {
        PhonePromptDecision.allowOnce when result.presented != 'none' => ApprovalDecision.allowOnce,
        PhonePromptDecision.reject || PhonePromptDecision.timeout => ApprovalDecision.reject,
        _ => null,
      };
      if (approval != null &&
          decision != null &&
          identical(prompt.tracker.phoneApprovalFor(prompt.alert.eventId!)?.request, approval.request)) {
        // All ownership checks run immediately before the actual RPC. Engine
        // answers contain the original request, not UI text or a screen read.
        final generation = prompt.generation;
        if (generation == null) {
          await _phoneFallback(prompt);
          return;
        }
        await answerPhoneApproval(
          client: prompt.client,
          generation: generation,
          request: approval.request,
          decision: decision,
          current: () => _phoneCurrent(prompt),
        );
      } else if (result.decision != PhonePromptDecision.stopped) {
        // OPEN proves a navigation attempt, not that Android resumed the app.
        // If still in the background, retain the exact request's review entry.
        await _phoneFallback(prompt);
      }
    } catch (_) {
      if (_phoneCurrent(prompt)) {
        if (enabled) {
          await _phoneFallback(prompt);
        } else {
          _deliver(prompt.alert);
        }
      }
    } finally {
      prompt.retire();
      if (identical(_phonePrompt, prompt)) _phonePrompt = null;
    }
  }

  void _deliver(ChatAlert alert) {
    // DS Bot's own conversations: it sends its own notifications.
    if (ref.read(dsBotSessionFilterProvider)(alert.host, alert.sessionId)) return;
    final prefs = ref.read(notifyPrefsProvider);
    final foreground = ref.read(appForegroundProvider);
    final delivery = deliveryFor(
      alert,
      prefs: prefs,
      foreground: foreground,
      viewed: ref.read(viewedChatProvider),
      petOnScreen: ref.read(petOnScreenProvider),
    );
    // The pet hears every alert (it moves for the one on screen too); it
    // speaks up for those that would have reached the person.
    petHearAlert(ref, alert, bubble: delivery == AlertDelivery.pet || delivery == AlertDelivery.system);
    switch (delivery) {
      case AlertDelivery.none || AlertDelivery.pet:
        return;
      case AlertDelivery.banner:
        _banner = alert;
      case AlertDelivery.system:
        unawaited(_channel.show(postFor(alert)));
    }
  }

  void _onWithdraw(HostRef host, String sessionId, String key) {
    _cancelPhonePrompt(host: host, eventId: key);
    unawaited(_channel.cancel(notifyGroup(host, sessionId), key));
    final banner = _banner;
    if (banner != null && banner.host == host && banner.sessionId == sessionId && banner.key == key) _banner = null;
  }

  void _onSessionGone(HostRef host, String sessionId) {
    _cancelPhonePrompt(host: host, sessionId: sessionId);
    _clearSessionNotifications(host, sessionId);
  }

  void _clearSessionNotifications(HostRef host, String sessionId) {
    unawaited(_channel.cancelGroup(notifyGroup(host, sessionId)));
    final banner = _banner;
    if (banner != null && banner.host == host && banner.sessionId == sessionId) _banner = null;
  }

  /// The person is looking at [chat]: its notifications and banner are moot.
  void _seen(ChatTarget chat) => _clearSessionNotifications(chat.host, chat.sessionId);

  /// Hides [alert]'s banner (timeout or swipe); a newer banner stays.
  void dismissBanner(ChatAlert alert) {
    if (identical(_banner, alert)) _banner = null;
  }

  /// Opens [sessionId] on [host] (a tapped notification or banner).
  void open(HostRef host, String sessionId) {
    // Always select: it also stops a still-pending restore of the last host
    // from switching away again on a cold start.
    ref.read(activeHostProvider.notifier).select(host);
    ref.read(currentSessionProvider.notifier).select(sessionId);
  }
}

final chatAlertsProvider = NotifierProvider<ChatAlertsController, ChatAlert?>(ChatAlertsController.new);
