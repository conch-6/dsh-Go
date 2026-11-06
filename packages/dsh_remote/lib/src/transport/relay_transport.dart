// Portions derived from ds-harness-remote (https://github.com/liguobao/ds-harness-remote), MIT, Copyright (c) 2026 DSH Remote contributors. See THIRD_PARTY_NOTICES.md.
// Client Control transport: the Server Control WebSocket, plus the
// assigned Relay node data WebSocket when the Server offers one. With
// `offerDirect` it also negotiates WebRTC and carries its signaling
// ([WebRtcTransport] then takes over the data plane).
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../protocol/control.dart';
import '../util/bytes.dart';
import 'transport.dart';

/// Opens the Control WebSocket (`wss://<server>/ws/v1/connect`); injectable
/// for tests.
typedef ControlSocketConnector = Future<WebSocket> Function(Uri url, Duration timeout);

Future<WebSocket> _defaultConnector(Uri url, Duration timeout) {
  var expired = false;
  // timeout does not cancel the opening Future. Keep ownership of a socket
  // that arrives after the caller has already received the timeout.
  final opening = WebSocket.connect(url.toString()).then((socket) {
    if (expired) unawaited(socket.close(WebSocketStatus.normalClosure).catchError((Object _) {}));
    return socket;
  });
  return opening.timeout(
    timeout,
    onTimeout: () {
      expired = true;
      throw TimeoutException('Future not completed', timeout);
    },
  );
}

/// Diagnostic hook: every Control frame in or out, and Relay data frames as
/// `data-in` / `data-out` (tokens, tickets and ciphertext redacted).
typedef ControlTracer = void Function(String direction, JsonMap frame);

/// Relay transport: `hello` → `hello.ack` → `connect.request` →
/// `connect.accepted`, then Noise handshake and ciphertext in `relay`
/// frames. Answers Server `ping` with `pong`; treats a silent socket
/// (no frame for 3 heartbeats) as dead.
///
/// `transport.relay.attach`: when `connect.accepted` carries a Relay
/// assignment (`relayEndpoint`, `relayTicket`, `relayNodeId`, `relayEpoch`),
/// the client opens that data WebSocket, sends `relay.attach` with the
/// ticket (the ticket never goes on the Control socket), waits for
/// `relay.ready`, then announces `transport.selected` (`relay`). The Noise
/// handshake stays on the Control socket; `relay` frames and the node's
/// heartbeats move to the data socket. `relay.detach` or a dropped data
/// socket ends the connection: Noise state is never carried over, the
/// caller opens a new one. Without an assignment (older Server or Host)
/// everything stays on the Control socket.
///
/// Direct paths (`offerDirect`): the client also offers `transport.lan`,
/// `transport.p2p` and `transport.turn`. When the Server negotiates any of
/// them (and does not send `webrtcEnabled: false`), `connect.request` lists
/// them before `relay` and [connect] returns at `connect.accepted` with the
/// data plane still open: [directTransports] is non-empty, nothing is
/// attached and no `transport.selected` was sent. The caller then
/// negotiates WebRTC over [sendSignal] / [onSignal] ([WebRtcTransport]).
///
/// One Control WebSocket per device: the Server closes an older socket of
/// the same device (`CONNECTION_REPLACED`, close code 4003), and a new
/// `connect.request` replaces the device's previous Host connection.
class RelayTransport implements SecureHandshakeTransport {
  RelayTransport._(
    this._socket,
    this._deviceId,
    this._hostDeviceId,
    this._tracer,
    this._connector,
    this._timeout,
    this._offered,
    this._preferredTransports,
  );

  /// Connects and waits for `connect.accepted`.
  ///
  /// Throws [RemoteTransportException]: `CONNECTION_FAILED` (socket, timeout),
  /// `AUTH_INVALID` / `TOKEN_EXPIRED` (access token refused — refresh and
  /// retry once), `HOST_OFFLINE`, `MEMBERSHIP_REQUIRED`,
  /// `CAPABILITY_NOT_SUPPORTED`, `CONNECTION_REJECTED` (Host refused),
  /// `INVALID_MESSAGE` (protocol violation).
  static Future<RelayTransport> connect({
    required Uri url,
    required String deviceId,
    required String accessToken,
    required String hostDeviceId,
    String? clientVersion,
    Duration timeout = const Duration(seconds: 10),
    ControlSocketConnector? connector,
    ControlTracer? tracer,
    bool offerDirect = false,
    List<RemoteTransportMode>? preferredTransports,
  }) async {
    final connect = connector ?? _defaultConnector;
    final WebSocket socket;
    try {
      socket = await connect(url, timeout);
    } on WebSocketException catch (error) {
      final status = error.httpStatusCode;
      throw RemoteTransportException(
        status == 401 || status == 403 ? 'AUTH_INVALID' : 'CONNECTION_FAILED',
        'Control WebSocket failed: ${error.message}${status == null ? '' : ' (HTTP $status)'}',
      );
    } on TimeoutException {
      throw const RemoteTransportException('CONNECTION_FAILED', 'Control WebSocket connect timed out.');
    } on SocketException catch (error) {
      throw RemoteTransportException('CONNECTION_FAILED', 'Control WebSocket connect failed: ${error.message}');
    } on HttpException catch (error) {
      throw RemoteTransportException('CONNECTION_FAILED', 'Control WebSocket connect failed: ${error.message}');
    } on HandshakeException catch (error) {
      throw RemoteTransportException('CONNECTION_FAILED', 'TLS handshake failed: ${error.message}');
    }
    final transport = RelayTransport._(
      socket,
      deviceId,
      hostDeviceId,
      tracer,
      connect,
      timeout,
      offerDirect ? _directOffered : _relayOffered,
      preferredTransports,
    );
    try {
      await transport._open(accessToken, clientVersion).timeout(timeout);
      return transport;
    } on TimeoutException {
      await transport._abort();
      throw const RemoteTransportException('CONNECTION_FAILED', 'Relay control handshake timed out.');
    } on Object {
      await transport._abort();
      rethrow;
    }
  }

  static const List<String> _relayOffered = ['transport.relay', 'transport.relay.attach'];
  static const List<String> _directOffered = [
    'transport.lan',
    'transport.p2p',
    'transport.turn',
    'transport.relay',
    'transport.relay.attach',
  ];

  final WebSocket _socket;
  final String _deviceId;
  final String _hostDeviceId;
  final ControlTracer? _tracer;
  final ControlSocketConnector _connector;
  final Duration _timeout;
  final List<String> _offered;
  final List<RemoteTransportMode>? _preferredTransports;
  ControlFrameLimits _limits = const ControlFrameLimits();
  String? _connectionId;
  List<String> _direct = const [];
  int? _webrtcFallbackMs;

  /// Relay node data socket, once assigned.
  WebSocket? _data;
  int? _relayEpoch;
  Completer<void>? _ready;
  int _heartbeatMs = 25000;
  DateTime _lastReceived = DateTime.now();
  Timer? _watchdog;
  bool _closed = false;
  bool _closedNotified = false;

  TransportDataHandler? _onData;
  TransportHandshakeHandler? _onHandshake;
  TransportClosedHandler? _onClosed;
  final List<void Function()> _backlog = [];
  RemoteTransportClosed? _pendingClose;

  /// Negotiated `hello.ack` heartbeat.
  Duration get heartbeatInterval => Duration(milliseconds: _heartbeatMs);

  /// Direct paths both sides negotiated, in the configured preference order;
  /// empty when this connection uses the Relay.
  List<String> get directTransports => _direct;

  /// `hello.ack.webrtcFallbackTimeoutMs`, when the Server sets one.
  Duration? get webrtcFallbackTimeout => _webrtcFallbackMs == null ? null : Duration(milliseconds: _webrtcFallbackMs!);

  /// Receives this connection's `signal.answer`, `signal.ice` and
  /// `transport.selected` frames (WebRTC negotiation).
  void Function(ControlFrame frame)? onSignal;

  @override
  RemoteTransportMode get mode => RemoteTransportMode.relay;

  @override
  RemoteConnectionInfo get info {
    final id = _connectionId;
    if (id == null) throw StateError('relay connection has not been authorized');
    return RemoteConnectionInfo(connectionId: id, localDeviceId: _deviceId, remoteDeviceId: _hostDeviceId);
  }

  Future<void> _open(String accessToken, String? clientVersion) {
    final ready = _ready = Completer<void>();
    _socket.listen(
      _onMessage,
      onError: (Object error) => _fail(RemoteTransportClosed('CONNECTION_FAILED', 'Control socket error: $error')),
      onDone: () => _fail(_closeReason()),
      cancelOnError: true,
    );
    _sendControl('hello', {
      'role': 'client',
      'deviceId': _deviceId,
      'accessToken': accessToken,
      'protocols': [protocolVersion],
      'capabilities': _offered,
      'clientVersion': ?clientVersion,
    });
    return ready.future;
  }

  RemoteTransportClosed _closeReason() {
    final code = _socket.closeCode;
    final reason = _socket.closeReason ?? '';
    final known = RegExp(r'^[A-Z][A-Z0-9_]+$').hasMatch(reason) ? reason : null;
    if (code == 4003) {
      return RemoteTransportClosed(
        'CONNECTION_REPLACED',
        'Another connection of this device replaced the Control channel.',
        retryable: false,
        closeCode: code,
      );
    }
    return RemoteTransportClosed(
      known ?? 'CONNECTION_FAILED',
      'Control channel closed (${code ?? 'no code'} $reason)'.trim(),
      retryable: known == null || _retryableCodes.contains(known),
      closeCode: code,
    );
  }

  static const Set<String> _retryableCodes = {
    'CONNECTION_FAILED',
    'HOST_OFFLINE',
    'RATE_LIMITED',
    'SLOW_CONSUMER',
    'RELAY_UNAVAILABLE',
    'TOKEN_EXPIRED',
    'AUTH_INVALID',
  };

  void _onMessage(Object? raw) {
    if (_closed) return;
    _lastReceived = DateTime.now();
    final ControlFrame frame;
    try {
      if (raw is! String) throw const ProtocolError('Relay control frames must be text JSON.');
      frame = decodeControlFrame(raw, _limits);
    } on ProtocolError catch (error) {
      // A frame this client cannot parse (unknown type, bad field, newer
      // protocol version, oversize) fails the same way on every attempt:
      // stop rather than reconnect forever. Retrying is left to the person.
      // PROTOCOL_MISMATCH tells it apart from a REST reply that was not JSON
      // (a captive portal or proxy), which shares INVALID_MESSAGE.
      final code = error.code == 'INVALID_MESSAGE' ? 'PROTOCOL_MISMATCH' : error.code;
      _fail(RemoteTransportClosed(code, error.message, retryable: false));
      return;
    }
    _trace('in', frame.toJson());
    try {
      _handle(frame);
    } on ProtocolError catch (error) {
      // A well-formed frame out of turn (a race around a reconnect) is worth
      // another attempt; a refused capability or version is not.
      _fail(RemoteTransportClosed(error.code, error.message, retryable: !_incompatibleCodes.contains(error.code)));
    }
  }

  /// [ProtocolError] codes that say the two sides do not speak the same protocol.
  static const Set<String> _incompatibleCodes = {'UNSUPPORTED_VERSION', 'CAPABILITY_NOT_SUPPORTED', 'FRAME_TOO_LARGE'};

  void _handle(ControlFrame frame) {
    final p = frame.payload;
    switch (frame.type) {
      case 'hello.ack':
        if (_ready == null || _ready!.isCompleted) {
          throw const ProtocolError('Unexpected hello.ack.');
        }
        final caps = p['capabilities'];
        final List<String> negotiated;
        try {
          negotiated = acceptNegotiatedCapabilities(_offered, caps is List ? caps.cast<String>() : null);
        } on ProtocolError catch (error) {
          throw ProtocolError(error.message, 'CAPABILITY_NOT_SUPPORTED');
        }
        if (!negotiated.contains('transport.relay')) {
          throw const ProtocolError(
            'Server did not negotiate the required Relay capability.',
            'CAPABILITY_NOT_SUPPORTED',
          );
        }
        _limits = ControlFrameLimits(
          maxControlFrameBytes: asInt(p['maxControlFrameBytes']),
          maxRelayFrameBytes: asInt(p['maxRelayFrameBytes']),
        );
        _heartbeatMs = asInt(p['heartbeatIntervalMs']) ?? _heartbeatMs;
        if (p['webrtcEnabled'] != false) {
          _direct = [
            for (final t in (_preferredTransports?.map((t) => t.name) ?? const ['lan', 'p2p', 'turn']))
              if (t != 'relay')
                if (negotiated.contains('transport.$t')) t,
          ];
          _webrtcFallbackMs = asInt(p['webrtcFallbackTimeoutMs']);
        }
        _sendControl('connect.request', {
          'hostDeviceId': _hostDeviceId,
          'preferredTransports': [..._direct, 'relay'],
        });
      case 'connect.accepted':
        final ready = _ready;
        if (ready == null || ready.isCompleted || _connectionId != null) {
          throw const ProtocolError('Unexpected connect.accepted.');
        }
        _connectionId = p['connectionId']! as String;
        _startWatchdog();
        final endpoint = asString(p['relayEndpoint']);
        final ticket = asString(p['relayTicket']);
        // A direct attempt picks its data plane next; a failed one falls back
        // on a new connection, so this one never attaches.
        if (endpoint == null || ticket == null || _direct.isNotEmpty) {
          ready.complete();
          return;
        }
        _relayEpoch = asInt(p['relayEpoch']);
        unawaited(_attach(Uri.parse(endpoint), ticket));
      case 'connect.rejected':
        if (_connectionId != null && p['connectionId'] != _connectionId) return;
        final code = asString(p['code']) ?? 'CONNECTION_REJECTED';
        _fail(
          RemoteTransportClosed(
            code,
            asString(p['message']) ?? 'The Host rejected the connection.',
            // The Server rejects with HOST_OFFLINE while a Host sleeps: keep
            // backing off so it reconnects once the Host is back.
            retryable: _retryableCodes.contains(code),
          ),
        );
      case 'error':
        final connectionId = asString(p['connectionId']);
        if (connectionId != null && _connectionId != null && connectionId != _connectionId) return;
        final code = p['code']! as String;
        _fail(
          RemoteTransportClosed(
            code,
            p['message']! as String,
            retryable: p['retryable'] == true || _retryableCodes.contains(code),
          ),
        );
      case 'relay':
        // Ciphertext belongs to the data socket once the node assigned one.
        if (_data != null) return;
        _receiveRelay(p);
      case 'secure.handshake':
        _receiveHandshake(p);
      case 'signal.answer' || 'signal.ice' || 'transport.selected':
        if (p['connectionId'] == _connectionId && p['targetDeviceId'] == _deviceId) onSignal?.call(frame);
      case 'ping':
        _sendControl('pong', {'nonce': p['nonce']});
      default:
        // pong, offers and Host-only frames are not for a client.
        break;
    }
  }

  void _receiveRelay(JsonMap p) {
    if (p['connectionId'] != _connectionId || p['targetDeviceId'] != _deviceId) {
      throw const ProtocolError('Received a relay frame for an unknown connection.');
    }
    final data = fromBase64Url(p['ciphertext']! as String);
    final counter = p['counter']! as int;
    _deliver(() => _onData!(data, counter));
  }

  void _receiveHandshake(JsonMap p) {
    if (p['connectionId'] != _connectionId || p['targetDeviceId'] != _deviceId) {
      throw const ProtocolError('Received a secure handshake frame for an unknown connection.');
    }
    final data = fromBase64Url(p['data']! as String);
    final step = p['step']! as int;
    _deliver(() => _onHandshake!(step, data));
  }

  // ---------------------------------------------------------------------------
  // Relay node data socket

  Future<void> _attach(Uri endpoint, String ticket) async {
    final WebSocket socket;
    try {
      socket = await _connector(endpoint, _timeout);
    } on Object catch (error) {
      _fail(RemoteTransportClosed('CONNECTION_FAILED', 'Relay data socket failed: $error'));
      return;
    }
    if (_closed) {
      unawaited(socket.close(1000).catchError((Object _) {}));
      return;
    }
    _data = socket;
    socket.listen(
      _onDataMessage,
      onError: (Object error) => _fail(RemoteTransportClosed('CONNECTION_FAILED', 'Relay data socket error: $error')),
      onDone: () => _fail(
        RemoteTransportClosed(
          'CONNECTION_FAILED',
          'Relay data socket closed (${socket.closeCode ?? 'no code'} ${socket.closeReason ?? ''})'.trim(),
          closeCode: socket.closeCode,
        ),
      ),
      cancelOnError: true,
    );
    _sendData('relay.attach', {
      'connectionId': _connectionId,
      'deviceId': _deviceId,
      'peerDeviceId': _hostDeviceId,
      'ticket': ticket,
    });
  }

  void _onDataMessage(Object? raw) {
    if (_closed) return;
    final ControlFrame frame;
    try {
      if (raw is! String) throw const ProtocolError('Relay data frames must be text JSON.');
      frame = decodeRelayDataFrame(raw, _limits);
    } on ProtocolError catch (error) {
      final code = error.code == 'INVALID_MESSAGE' ? 'PROTOCOL_MISMATCH' : error.code;
      _fail(RemoteTransportClosed(code, error.message, retryable: false));
      return;
    }
    _trace('data-in', frame.toJson());
    try {
      _handleData(frame);
    } on ProtocolError catch (error) {
      _fail(RemoteTransportClosed(error.code, error.message, retryable: !_incompatibleCodes.contains(error.code)));
    }
  }

  void _handleData(ControlFrame frame) {
    final p = frame.payload;
    switch (frame.type) {
      case 'relay.ready':
        final ready = _ready!;
        if (ready.isCompleted) return;
        if (p['connectionId'] != _connectionId || (_relayEpoch != null && p['epoch'] != _relayEpoch)) {
          throw const ProtocolError('Relay data attach does not match the assigned connection.');
        }
        // As upstream AdaptiveTransport: a Host with an assignment holds the
        // Noise handshake until the client confirms the data plane, then
        // attaches itself.
        _sendControl('transport.selected', {
          'connectionId': _connectionId,
          'targetDeviceId': _hostDeviceId,
          'transport': 'relay',
        });
        ready.complete();
      case 'relay.detach':
        _fail(const RemoteTransportClosed('CONNECTION_FAILED', 'The Host detached from the Relay node.'));
      case 'ping':
        _sendData('pong', p);
      case 'relay':
        _receiveRelay(parseControlFrame(frame.toJson()).payload);
      case 'secure.handshake':
        _receiveHandshake(parseControlFrame(frame.toJson()).payload);
      default:
        break;
    }
  }

  void _sendData(String type, JsonMap payload) {
    final frame = ControlFrame(type, payload);
    final encoded = encodeRelayDataFrame(frame, _limits);
    _trace('data-out', frame.toJson());
    _data!.add(encoded);
  }

  void _deliver(void Function() action) {
    if (_onData == null) {
      _backlog.add(action);
    } else {
      action();
    }
  }

  void _startWatchdog() {
    _watchdog?.cancel();
    final period = Duration(milliseconds: _heartbeatMs);
    _watchdog = Timer.periodic(period, (_) {
      if (DateTime.now().difference(_lastReceived) > period * 3) {
        _fail(const RemoteTransportClosed('CONNECTION_FAILED', 'The Server Control channel went silent.'));
        unawaited(_socket.close(4000, 'heartbeat timeout'));
      }
    });
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
  Future<void> sendHandshake(int step, Uint8List data) async {
    final id = _requireConnection();
    _sendControl('secure.handshake', {
      'connectionId': id,
      'targetDeviceId': _hostDeviceId,
      'step': step,
      'data': toBase64Url(data),
    });
  }

  /// Sends a WebRTC signaling frame ([type] `signal.offer`, `signal.ice` or
  /// `transport.selected`) for this connection to the Host.
  void sendSignal(String type, JsonMap payload) {
    _sendControl(type, {'connectionId': _requireConnection(), 'targetDeviceId': _hostDeviceId, ...payload});
  }

  @override
  Future<void> send(Uint8List ciphertext, {required int counter}) async {
    final payload = {
      'connectionId': _requireConnection(),
      'targetDeviceId': _hostDeviceId,
      'counter': counter,
      'ciphertext': toBase64Url(ciphertext),
    };
    if (_data != null) {
      _sendData('relay', payload);
    } else {
      _sendControl('relay', payload);
    }
  }

  String _requireConnection() {
    final id = _connectionId;
    if (_closed || id == null) {
      throw const RemoteTransportException('CONNECTION_FAILED', 'The relay connection is not open.');
    }
    return id;
  }

  void _sendControl(String type, JsonMap payload) {
    if (_closed) {
      throw const RemoteTransportException('CONNECTION_FAILED', 'The relay control socket is closed.');
    }
    final frame = ControlFrame(type, payload);
    final encoded = encodeControlFrame(frame, _limits);
    _trace('out', frame.toJson());
    _socket.add(encoded);
  }

  void _trace(String direction, JsonMap frame) {
    final tracer = _tracer;
    if (tracer == null) return;
    final payload = asMapOrEmpty(frame['payload']);
    tracer(direction, {
      ...frame,
      'payload': {
        ...payload,
        if (payload.containsKey('accessToken')) 'accessToken': '<redacted>',
        if (payload.containsKey('relayTicket')) 'relayTicket': '<redacted>',
        if (payload.containsKey('ticket')) 'ticket': '<redacted>',
        if (payload.containsKey('ciphertext')) 'ciphertext': '<${(payload['ciphertext']! as String).length} chars>',
        // SDP and candidates carry the device's network addresses.
        if (payload.containsKey('sdp')) 'sdp': '<${(payload['sdp']! as String).length} chars>',
        if (payload.containsKey('candidate')) 'candidate': '<redacted>',
      },
    });
  }

  void _fail(RemoteTransportClosed reason) {
    if (_closed) return;
    _closed = true;
    _watchdog?.cancel();
    final ready = _ready;
    if (ready != null && !ready.isCompleted) {
      ready.completeError(
        RemoteTransportException(reason.code, reason.message, retryable: reason.retryable, closeCode: reason.closeCode),
      );
      // Avoid an unhandled error if the caller already gave up waiting.
      ready.future.ignore();
    } else if (_onClosed != null) {
      if (!_closedNotified) {
        _closedNotified = true;
        _onClosed!(reason);
      }
    } else {
      _pendingClose = reason;
    }
    unawaited(_data?.close(1000).catchError((Object _) {}));
    unawaited(_socket.close(1000).catchError((Object _) {}));
  }

  Future<void> _abort() async {
    _closed = true;
    _watchdog?.cancel();
    unawaited(_data?.close(1000).catchError((Object _) {}));
    await _socket.close(1000).catchError((Object _) {});
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _closedNotified = true;
    _watchdog?.cancel();
    unawaited(_data?.close(1000, 'client closed').catchError((Object _) {}));
    await _socket.close(1000, 'client closed').catchError((Object _) {});
  }
}
