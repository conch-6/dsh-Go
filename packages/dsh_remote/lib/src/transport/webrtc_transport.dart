// Portions derived from ds-harness-remote (https://github.com/liguobao/ds-harness-remote), MIT, Copyright (c) 2026 DSH Remote contributors. See THIRD_PARTY_NOTICES.md.
// Direct data plane (LAN / P2P / TURN): the client side of upstream
// packages/webrtc/src/adaptive-transport.ts (tryWebRtc, negotiate) and
// rtc-data-channel.ts (initiator), over a platform [RemotePeerConnection].
library;

import 'dart:async';
import 'dart:typed_data';

import '../protocol/control.dart';
import '../util/bytes.dart';
import 'peer_connection.dart';
import 'relay_transport.dart';
import 'rtc_chunking.dart';
import 'transport.dart';

/// WebRTC could not open a DataChannel (ICE or DTLS failed, timed out, or
/// the path is not one both sides negotiated). The attempt's connection is
/// closed; the caller falls back to the Relay on a new one.
class WebRtcUnavailable implements Exception {
  const WebRtcUnavailable(this.message, {this.timedOut = false, this.turnUnavailable = false});
  final String message;
  final bool timedOut;
  final bool turnUnavailable;

  @override
  String toString() => 'WebRtcUnavailable: $message';
}

/// Noise ciphertext over an ordered DataChannel `dsh` to the Host, with the
/// Control socket of [RelayTransport] for signaling, the Noise handshake and
/// the Server heartbeat.
///
/// Order, as upstream: `connect.accepted` → ICE servers → `signal.offer` →
/// `signal.answer` / `signal.ice` both ways → DataChannel open →
/// `transport.selected` (`lan` / `p2p` / `turn`) → Noise handshake on the
/// Control socket → ciphertext as binary DataChannel messages (`RTCH`
/// chunks above 8 KiB). The DataChannel or the Control socket closing ends
/// the connection; a reconnect negotiates a new one with a new Noise session.
class WebRtcTransport implements SecureHandshakeTransport {
  WebRtcTransport._(this._control);

  /// Negotiates a DataChannel for [control], which must have returned from
  /// [RelayTransport.connect] with non-empty [RelayTransport.directTransports].
  ///
  /// [iceServers] fetches the connection's STUN / TURN servers; when it fails
  /// or exceeds [iceServersTimeout] (10 s by default), direct candidates are
  /// still tried. Each new attempt fetches its own credentials. TURN is
  /// dropped unless `transport.turn` was negotiated. [timeout] is the local
  /// negotiation deadline; the Server's `webrtcFallbackTimeoutMs` wins when
  /// longer, within a 15 s safety ceiling.
  ///
  /// Throws [WebRtcUnavailable] when no DataChannel opened, and the
  /// [RemoteTransportException] of the Control socket when that one failed;
  /// either way [control] is closed.
  static Future<WebRtcTransport> negotiate({
    required RelayTransport control,
    required RemotePeerConnector connector,
    required Future<List<RemoteIceServer>> Function(String connectionId) iceServers,
    Duration timeout = const Duration(seconds: 8),
    Duration iceServersTimeout = const Duration(seconds: 10),
    bool relayOnly = false,
  }) async {
    final transport = WebRtcTransport._(control).._relayOnly = relayOnly;
    try {
      await transport._negotiate(connector, iceServers, timeout, iceServersTimeout);
      return transport;
    } on Object catch (error) {
      await transport._abort();
      if (error is RemoteTransportException || error is WebRtcUnavailable) rethrow;
      // The platform stack refused (no WebRTC, bad configuration, ...).
      throw WebRtcUnavailable('$error');
    }
  }

  final RelayTransport _control;
  RemotePeerConnection? _peer;
  RemoteTransportMode _mode = RemoteTransportMode.p2p;
  RemoteTransportMode? _actualMode;
  Duration? _roundTripTime;
  bool _relayOnly = false;
  bool _answering = false;
  final RtcChunkCodec _outgoing = RtcChunkCodec();
  final RtcChunkCodec _incoming = RtcChunkCodec();
  Completer<void>? _opening;
  bool _answered = false;
  final List<JsonMap> _remoteCandidates = [];

  /// Local candidates the stack produced before the offer went out: the Host
  /// drops ICE for a connection it has no offer for.
  List<JsonMap>? _earlyCandidates = [];
  bool _closed = false;
  bool _closedNotified = false;

  TransportDataHandler? _onData;
  TransportHandshakeHandler? _onHandshake;
  TransportClosedHandler? _onClosed;
  final List<void Function()> _backlog = [];
  RemoteTransportClosed? _pendingClose;

  @override
  RemoteTransportMode get mode => _mode;

  RemoteTransportMode? get actualMode => _actualMode;
  Duration? get roundTripTime => _roundTripTime;

  /// Reads native stats only; no network probe, and a stalled platform call
  /// cannot hold up the caller. Stats after close are never consulted.
  Future<void> inspectNetwork() async {
    final peer = _peer;
    if (_closed || peer == null) return;
    try {
      final stats = await peer.stats().timeout(const Duration(milliseconds: 250));
      if (_closed) return;
      _actualMode = selectedPeerPath(stats);
      _roundTripTime = selectedPeerRoundTripTime(stats);
    } on Object {
      _actualMode = null;
      _roundTripTime = null;
    }
  }

  @override
  RemoteConnectionInfo get info => _control.info;

  Future<void> _negotiate(
    RemotePeerConnector connector,
    Future<List<RemoteIceServer>> Function(String connectionId) fetchIceServers,
    Duration localTimeout,
    Duration iceServersTimeout,
  ) async {
    final opening = _opening = Completer<void>();
    // Awaited below; failures may land before that.
    opening.future.ignore();
    _control
      ..onSignal = _onSignal
      ..listen(
        // A Host bound to WebRTC sends nothing on the Relay; stray frames
        // must not enter the Noise receive order.
        onData: (_, _) {},
        onHandshake: (step, data) => _deliver(() => _onHandshake!(step, data)),
        onClosed: _onControlClosed,
      );
    final connectionId = _control.info.connectionId;
    var servers = const <RemoteIceServer>[];
    try {
      servers = await fetchIceServers(connectionId).timeout(iceServersTimeout);
    } on Object {
      // No STUN / TURN: host candidates can still reach a Host on the LAN.
    }
    // Preserve authorization/Control failures that arrived during the REST
    // request before a missing TURN configuration can trigger fallback.
    _check();
    // The first attempt must give direct ICE its own window. Even a remote
    // relay candidate could otherwise make TURN win before P2P was tried.
    if (!_relayOnly) servers = stunOnlyIceServers(servers);
    if (_relayOnly &&
        (!_control.directTransports.contains('turn') ||
            !servers.any((s) => s.urls.any((u) => RegExp(r'^turns?:', caseSensitive: false).hasMatch(u.trim()))))) {
      throw const WebRtcUnavailable('No negotiated TURN server is available.', turnUnavailable: true);
    }
    final server = _control.webrtcFallbackTimeout;
    // Honor the Server budget only within a finite local safety ceiling.
    final requested = server != null && server > localTimeout ? server : localTimeout;
    final timeout = requested > const Duration(seconds: 15) ? const Duration(seconds: 15) : requested;
    final RemotePeerConnection peer;
    try {
      // The deadline includes native creation and offer generation: either
      // platform call can stall before there is a DataChannel to wait for.
      final creating = _openPeer(connector, servers, opening);
      peer = await Future.any<RemotePeerConnection>([
        creating,
        // Surface Control/auth/ICE failures even while the platform has not
        // returned from creation or createOffer. Successful open still waits
        // for the ordinary native setup sequence to finish.
        opening.future.then((_) => creating),
      ]).timeout(timeout);
    } on TimeoutException {
      // A terminal Control error can arrive while native creation or offer
      // generation is stalled. It must not be relabeled as an ICE timeout
      // and accidentally bypass authorization through transport fallback.
      _check();
      throw WebRtcUnavailable('No DataChannel within ${timeout.inMilliseconds} ms.', timedOut: true);
    }
    _check();
    final path = await _selectedPath(peer);
    _check();
    _actualMode = path;
    if (!_relayOnly && path == RemoteTransportMode.turn) {
      throw const WebRtcUnavailable('TURN was selected during a direct-only attempt.');
    }
    if (_relayOnly && path != null && path != RemoteTransportMode.turn) {
      throw const WebRtcUnavailable('A non-relay pair was selected during the TURN attempt.');
    }
    final direct = _control.directTransports;
    // A Host on an older Server that only knows p2p still gets a LAN path.
    final selected = path ?? (_relayOnly ? RemoteTransportMode.turn : RemoteTransportMode.p2p);
    final wire = selected == RemoteTransportMode.lan && !direct.contains('lan') ? RemoteTransportMode.p2p : selected;
    if (!direct.contains(wire.name)) throw WebRtcUnavailable('WebRTC selected unnegotiated transport ${wire.name}.');
    _mode = wire;
    // Before the handshake: the Host binds the Noise channel to the data
    // plane this names.
    _control.sendSignal('transport.selected', {'transport': wire.name});
    _opening = null;
  }

  Future<RemotePeerConnection> _openPeer(
    RemotePeerConnector connector,
    List<RemoteIceServer> servers,
    Completer<void> opening,
  ) async {
    final peer = await connector(
      servers,
      RemotePeerHandlers(
        iceTransportPolicy: _relayOnly ? RemoteIceTransportPolicy.relay : RemoteIceTransportPolicy.all,
        onIceCandidate: (candidate) {
          if (_closed) return;
          if (!_relayOnly && _isRelayCandidate(candidate)) return;
          final early = _earlyCandidates;
          if (early != null) {
            early.add(candidate);
          } else {
            _signal('signal.ice', {'candidate': candidate});
          }
        },
        onOpen: () {
          if (!opening.isCompleted) opening.complete();
        },
        onMessage: _receive,
        onClosed: (reason) {
          if (!opening.isCompleted) {
            opening.completeError(WebRtcUnavailable(reason));
          } else {
            _fail(RemoteTransportClosed('CONNECTION_FAILED', 'The direct connection closed: $reason'));
          }
        },
      ),
    );
    // A native creation can finish after the deadline closed this attempt.
    if (_closed) {
      unawaited(peer.close().catchError((Object _) {}));
      _check();
    }
    _peer = peer;
    _check();
    final offer = await peer.createOffer(remoteDataChannelLabel);
    _check();
    _control.sendSignal('signal.offer', {'sdp': _relayOnly ? offer : _withoutRelayCandidates(offer)});
    final early = _earlyCandidates!;
    _earlyCandidates = null;
    for (final candidate in early) {
      _control.sendSignal('signal.ice', {'candidate': candidate});
    }
    await opening.future;
    return peer;
  }

  /// Sends unless the connection already ended (stack callbacks can trail).
  void _signal(String type, JsonMap payload) {
    if (!_closed && _pendingClose == null) _control.sendSignal(type, payload);
  }

  /// Throws when the Control socket failed meanwhile.
  void _check() {
    if (_closed) throw const WebRtcUnavailable('The direct connection closed during negotiation.');
    if (_pendingClose case final reason?) {
      throw RemoteTransportException(
        reason.code,
        reason.message,
        retryable: reason.retryable,
        closeCode: reason.closeCode,
      );
    }
  }

  /// Native stacks can open the DataChannel a moment before the selected
  /// pair shows up in the stats; ask a few times before settling on `p2p`.
  Future<RemoteTransportMode?> _selectedPath(RemotePeerConnection peer) async {
    RemoteTransportMode? path;
    for (var attempt = 0; attempt < 6; attempt++) {
      if (attempt > 0) await Future<void>.delayed(const Duration(milliseconds: 50));
      try {
        // A native getStats() that stalls must not hold up the connect.
        final stats = await peer.stats().timeout(const Duration(milliseconds: 250));
        path = selectedPeerPath(stats) ?? path;
        _roundTripTime = selectedPeerRoundTripTime(stats);
      } on Object {
        // Stats are diagnostics: the path still works without them.
      }
      if (path != null && path != RemoteTransportMode.p2p) break;
    }
    return path;
  }

  void _onSignal(ControlFrame frame) {
    final peer = _peer;
    if (_closed || peer == null) return;
    final p = frame.payload;
    switch (frame.type) {
      case 'signal.answer':
        if (_answered || _answering) return;
        _answering = true;
        final answer = p['sdp']! as String;
        unawaited(_applyAnswer(peer, _relayOnly ? answer : _withoutRelayCandidates(answer)));
      case 'signal.ice':
        final candidate = asMap(p['candidate'])!;
        if (!_relayOnly && _isRelayCandidate(candidate)) return;
        if (_answered) {
          unawaited(peer.addIceCandidate(candidate).catchError((Object _) {}));
        } else {
          _remoteCandidates.add(candidate);
        }
      default:
        // The Host's own transport.selected confirms what we chose.
        break;
    }
  }

  static bool _isRelayCandidate(JsonMap candidate) =>
      RegExp(r'(?:^|\s)typ\s+relay(?:\s|$)', caseSensitive: false).hasMatch('${candidate['candidate'] ?? ''}');

  static String _withoutRelayCandidates(String sdp) => sdp
      .split('\n')
      .where((line) => !line.trimLeft().startsWith('a=candidate:') || !_isRelayCandidate({'candidate': line}))
      .join('\n');

  Future<void> _applyAnswer(RemotePeerConnection peer, String sdp) async {
    try {
      await peer.setAnswer(sdp);
    } on Object catch (error) {
      final opening = _opening;
      if (opening != null && !opening.isCompleted) opening.completeError(WebRtcUnavailable('Invalid answer: $error'));
      return;
    }
    if (_closed) return;
    _answered = true;
    final buffered = [..._remoteCandidates];
    _remoteCandidates.clear();
    for (final candidate in buffered) {
      // A candidate the stack refuses is skipped; ICE uses the others.
      await peer.addIceCandidate(candidate).catchError((Object _) {});
    }
  }

  void _onControlClosed(RemoteTransportClosed reason) {
    final opening = _opening;
    if (opening != null) {
      _pendingClose = reason;
      if (!opening.isCompleted) {
        opening.completeError(
          RemoteTransportException(
            reason.code,
            reason.message,
            retryable: reason.retryable,
            closeCode: reason.closeCode,
          ),
        );
      }
      return;
    }
    _fail(reason);
  }

  void _receive(Uint8List frame) {
    if (_closed) return;
    final Uint8List? message;
    try {
      message = _incoming.decode(frame);
    } on RtcChunkError catch (error) {
      _fail(RemoteTransportClosed('SECURE_CHANNEL_FAILED', error.message));
      return;
    }
    if (message case final whole?) _deliver(() => _onData!(whole, null));
  }

  void _deliver(void Function() action) {
    if (_onData == null) {
      _backlog.add(action);
    } else {
      action();
    }
  }

  @override
  void listen({
    required TransportDataHandler onData,
    required TransportHandshakeHandler onHandshake,
    required TransportClosedHandler onClosed,
  }) {
    _onData = onData;
    _onHandshake = onHandshake;
    _onClosed = onClosed;
    final backlog = [..._backlog];
    _backlog.clear();
    for (final action in backlog) {
      action();
    }
    final pending = _pendingClose;
    if (pending != null && !_closedNotified) {
      _closedNotified = true;
      onClosed(pending);
    }
  }

  @override
  Future<void> sendHandshake(int step, Uint8List data) => _control.sendHandshake(step, data);

  /// [counter] only matters to the Relay: the DataChannel is ordered and
  /// the Host reads Noise nonces in arrival order.
  @override
  Future<void> send(Uint8List ciphertext, {required int counter}) async {
    final peer = _peer;
    if (_closed || peer == null) {
      throw const RemoteTransportException('CONNECTION_FAILED', 'The direct connection is not open.');
    }
    for (final frame in _outgoing.encode(ciphertext)) {
      await peer.send(frame);
    }
  }

  void _fail(RemoteTransportClosed reason) {
    if (_closed) return;
    _closed = true;
    _release();
    if (_onClosed != null) {
      if (!_closedNotified) {
        _closedNotified = true;
        _onClosed!(reason);
      }
    } else {
      _pendingClose = reason;
    }
  }

  void _release() {
    _control.onSignal = null;
    _incoming.reset();
    _outgoing.reset();
    unawaited(_peer?.close().catchError((Object _) {}));
    unawaited(_control.close());
  }

  Future<void> _abort() async {
    _closed = true;
    // Native teardown must not hold up the fresh Relay connection either.
    _release();
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _closedNotified = true;
    _release();
  }
}
