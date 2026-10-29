// Chromecast support — hand-rolled CASTV2 client, a port of the iOS
// app's CastManager (v1.3.0). The official Cast SDK needs Google Play
// services and a much heavier native footprint; CASTV2 itself is a
// small length-prefixed protobuf protocol over TLS that the Default
// Media Receiver (CC1AD845) speaks, so the phone app speaks it
// directly: Bonjour discovery (package:nsd wraps Android's NsdManager),
// TLS to port 8009 with the TV's self-signed certificate accepted, and
// hand-encoded CastMessage envelopes.
//
// Flow: CONNECT + LAUNCH on the receiver channel, then a second
// CONNECT to the launched app's transportId, then LOAD of the HLS URL
// on the media channel. Heartbeat PING every 5 s, PONG replies.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:nsd/nsd.dart' as nsd;

class CastDevice {
  final String id; // service name — stable per device
  final String friendlyName;
  final InternetAddress address;
  final int port;
  const CastDevice({
    required this.id,
    required this.friendlyName,
    required this.address,
    required this.port,
  });
}

enum CastPhase { idle, scanning, connecting, connected, ready }

class CastManager extends ChangeNotifier {
  static const _senderId = 'sender-0';
  static const _receiverId = 'receiver-0';
  static const _defaultReceiverAppId = 'CC1AD845';
  static const _nsConnection = 'urn:x-cast:com.google.cast.tp.connection';
  static const _nsHeartbeat = 'urn:x-cast:com.google.cast.tp.heartbeat';
  static const _nsReceiver = 'urn:x-cast:com.google.cast.receiver';
  static const _nsMedia = 'urn:x-cast:com.google.cast.media';

  CastPhase phase = CastPhase.idle;
  final List<CastDevice> devices = [];
  String? connectedDeviceName;
  String? lastError;
  bool isCastingMedia = false;
  String remotePlayerState = '';

  nsd.Discovery? _discovery;
  SecureSocket? _socket;
  StreamSubscription<Uint8List>? _socketSub;
  final BytesBuilder _buffer = BytesBuilder();
  Timer? _heartbeat;
  int _requestId = 0;

  String? _mediaTransportId;
  String? _receiverSessionId;
  int? _mediaSessionId;
  bool _appTransportConnected = false;
  String? _lastLoadedUrl;
  ({String url, String title, String? image})? _pendingMedia;

  int _nextRequestId() => ++_requestId;

  // ---------------------------------------------------------------------
  // Discovery
  // ---------------------------------------------------------------------

  Future<void> startDiscovery() async {
    if (_discovery != null) return;
    phase = CastPhase.scanning;
    notifyListeners();
    try {
      final discovery = await nsd.startDiscovery('_googlecast._tcp',
          ipLookupType: nsd.IpLookupType.any);
      _discovery = discovery;
      discovery.addServiceListener((service, status) {
        if (status == nsd.ServiceStatus.found) {
          _addService(service);
        } else {
          devices.removeWhere((d) => d.id == service.name);
          notifyListeners();
        }
      });
      for (final s in discovery.services) {
        _addService(s);
      }
    } catch (e) {
      lastError = 'Could not look for Chromecast devices: $e';
      phase = CastPhase.idle;
      notifyListeners();
    }
  }

  void _addService(nsd.Service service) {
    final name = service.name;
    if (name == null || devices.any((d) => d.id == name)) return;
    final address = (service.addresses != null && service.addresses!.isNotEmpty)
        ? service.addresses!.first
        : null;
    if (address == null) return;
    var friendly = name;
    final fn = service.txt?['fn'];
    if (fn != null) {
      final decoded = utf8.decode(fn, allowMalformed: true);
      if (decoded.isNotEmpty) friendly = decoded;
    }
    devices.add(CastDevice(
      id: name,
      friendlyName: friendly,
      address: address,
      port: service.port ?? 8009,
    ));
    notifyListeners();
  }

  Future<void> stopDiscovery() async {
    final d = _discovery;
    _discovery = null;
    if (d != null) {
      try {
        await nsd.stopDiscovery(d);
      } catch (_) {}
    }
    if (phase == CastPhase.scanning) phase = CastPhase.idle;
    notifyListeners();
  }

  // ---------------------------------------------------------------------
  // Connection
  // ---------------------------------------------------------------------

  Future<void> connect(CastDevice device) async {
    disconnect();
    phase = CastPhase.connecting;
    connectedDeviceName = device.friendlyName;
    lastError = null;
    notifyListeners();
    try {
      final socket = await SecureSocket.connect(
        device.address,
        device.port,
        onBadCertificate: (_) => true, // TVs present self-signed certs
        timeout: const Duration(seconds: 10),
      );
      _socket = socket;
      _socketSub = socket.listen(
        _onData,
        onError: (Object e) {
          lastError = 'Cast connection failed: $e';
          disconnect();
        },
        onDone: () {
          if (phase != CastPhase.idle) disconnect();
        },
      );
      phase = CastPhase.connected;
      notifyListeners();
      _send(_nsConnection, _receiverId, {'type': 'CONNECT'});
      _send(_nsReceiver, _receiverId, {
        'type': 'LAUNCH',
        'appId': _defaultReceiverAppId,
        'requestId': _nextRequestId(),
      });
      _heartbeat?.cancel();
      _heartbeat = Timer.periodic(const Duration(seconds: 5), (_) {
        _send(_nsHeartbeat, _receiverId, {'type': 'PING'});
      });
    } catch (e) {
      lastError = "Couldn't connect to the TV: $e";
      disconnect();
    }
  }

  void disconnect() {
    _heartbeat?.cancel();
    _heartbeat = null;
    _socketSub?.cancel();
    _socketSub = null;
    _socket?.destroy();
    _socket = null;
    _buffer.clear();
    phase = CastPhase.idle;
    connectedDeviceName = null;
    _mediaTransportId = null;
    _receiverSessionId = null;
    _mediaSessionId = null;
    _appTransportConnected = false;
    isCastingMedia = false;
    remotePlayerState = '';
    _lastLoadedUrl = null;
    _pendingMedia = null;
    notifyListeners();
  }

  // ---------------------------------------------------------------------
  // Media control
  // ---------------------------------------------------------------------

  void load(String url, String title, String? image) {
    if (url == _lastLoadedUrl && isCastingMedia) return;
    if (_appTransportConnected) {
      _sendLoad(url, title, image);
    } else if (phase == CastPhase.connected || phase == CastPhase.connecting) {
      _pendingMedia = (url: url, title: title, image: image);
    }
  }

  void _sendLoad(String url, String title, String? image) {
    final transportId = _mediaTransportId;
    if (transportId == null) return;
    _lastLoadedUrl = url;
    final metadata = <String, dynamic>{'metadataType': 0, 'title': title};
    if (image != null) {
      metadata['images'] = [
        {'url': image}
      ];
    }
    _send(_nsMedia, transportId, {
      'type': 'LOAD',
      'requestId': _nextRequestId(),
      'media': {
        'contentId': url,
        'contentType': 'application/x-mpegURL',
        'streamType': 'LIVE',
        'metadata': metadata,
      },
      'currentTime': 0,
      'autoplay': true,
      'activeTrackIds': <int>[],
      'customData': <String, dynamic>{},
    });
    isCastingMedia = true;
    remotePlayerState = 'BUFFERING';
    notifyListeners();
  }

  void togglePlayPause() {
    final transportId = _mediaTransportId;
    if (transportId == null) return;
    final payload = <String, dynamic>{
      'type': remotePlayerState == 'PLAYING' ? 'PAUSE' : 'PLAY',
      'requestId': _nextRequestId(),
    };
    if (_mediaSessionId != null) payload['mediaSessionId'] = _mediaSessionId;
    _send(_nsMedia, transportId, payload);
  }

  void stopCasting() {
    final transportId = _mediaTransportId;
    if (transportId != null) {
      if (_mediaSessionId != null) {
        _send(_nsMedia, transportId, {
          'type': 'STOP',
          'requestId': _nextRequestId(),
          'mediaSessionId': _mediaSessionId,
        });
      }
      _send(_nsConnection, transportId, {'type': 'CLOSE'});
    }
    if (_receiverSessionId != null) {
      _send(_nsReceiver, _receiverId, {
        'type': 'STOP',
        'sessionId': _receiverSessionId,
        'requestId': _nextRequestId(),
      });
    }
    isCastingMedia = false;
    remotePlayerState = '';
    notifyListeners();
    // Give the STOP messages a beat to flush before hanging up.
    Future.delayed(const Duration(milliseconds: 400), disconnect);
  }

  // ---------------------------------------------------------------------
  // Incoming messages
  // ---------------------------------------------------------------------

  void _route(String namespace, String source, Map<String, dynamic> payload) {
    final type = payload['type'] as String? ?? '';
    switch (namespace) {
      case _nsHeartbeat:
        if (type == 'PING') {
          _send(_nsHeartbeat, source.isEmpty ? _receiverId : source,
              {'type': 'PONG'});
        }
      case _nsReceiver:
        if (type == 'RECEIVER_STATUS') _handleReceiverStatus(payload);
        if (type == 'LAUNCH_ERROR') {
          lastError = "The TV couldn't start its player app.";
          notifyListeners();
        }
      case _nsMedia:
        if (type == 'MEDIA_STATUS') _handleMediaStatus(payload);
        if (type == 'LOAD_FAILED' || type == 'LOAD_CANCELLED') {
          isCastingMedia = false;
          lastError = "The TV couldn't play this channel.";
          notifyListeners();
        }
      case _nsConnection:
        if (type == 'CLOSE') _appTransportClosed();
    }
  }

  void _handleReceiverStatus(Map<String, dynamic> payload) {
    final status = payload['status'];
    if (status is! Map) return;
    final apps = status['applications'];
    if (apps is! List) return;
    Map? app;
    for (final a in apps) {
      if (a is Map && a['appId'] == _defaultReceiverAppId) {
        app = a;
        break;
      }
    }
    final transportId = app?['transportId'];
    if (app == null || transportId is! String) {
      // The receiver app isn't running (stopped from elsewhere).
      if (_mediaTransportId != null) _appTransportClosed();
      return;
    }
    _receiverSessionId = app['sessionId'] as String?;
    if (_mediaTransportId != transportId) {
      _mediaTransportId = transportId;
      _appTransportConnected = false;
    }
    if (!_appTransportConnected) {
      _appTransportConnected = true;
      _send(_nsConnection, transportId, {'type': 'CONNECT'});
      phase = CastPhase.ready;
      final pending = _pendingMedia;
      if (pending != null) {
        _pendingMedia = null;
        _sendLoad(pending.url, pending.title, pending.image);
      }
      notifyListeners();
    }
  }

  void _handleMediaStatus(Map<String, dynamic> payload) {
    final status = payload['status'];
    if (status is! List || status.isEmpty) return;
    final first = status.first;
    if (first is! Map) return;
    final id = first['mediaSessionId'];
    if (id is num) _mediaSessionId = id.toInt();
    final state = first['playerState'] as String? ?? '';
    remotePlayerState = state;
    if (state == 'IDLE') {
      final reason = first['idleReason'] as String? ?? '';
      if (reason == 'FINISHED' || reason == 'CANCELLED' || reason == 'ERROR') {
        isCastingMedia = false;
      }
    } else if (state.isNotEmpty) {
      isCastingMedia = true;
    }
    notifyListeners();
  }

  void _appTransportClosed() {
    _mediaTransportId = null;
    _mediaSessionId = null;
    _appTransportConnected = false;
    isCastingMedia = false;
    remotePlayerState = '';
    if (phase == CastPhase.ready) phase = CastPhase.connected;
    notifyListeners();
  }

  // ---------------------------------------------------------------------
  // CASTV2 wire format
  //
  // Frames are a 4-byte big-endian length + a CastMessage protobuf:
  // 1 protocol_version (varint, 0), 2 source_id, 3 destination_id,
  // 4 namespace, 5 payload_type (varint, 0 = STRING), 6 payload_utf8.
  // ---------------------------------------------------------------------

  void _send(String namespace, String destination, Map<String, dynamic> payload) {
    final socket = _socket;
    if (socket == null) return;
    final body = BytesBuilder();
    _writeVarintField(body, 1, 0);
    _writeStringField(body, 2, _senderId);
    _writeStringField(body, 3, destination);
    _writeStringField(body, 4, namespace);
    _writeVarintField(body, 5, 0);
    _writeStringField(body, 6, jsonEncode(payload));
    final bytes = body.toBytes();
    final header = ByteData(4)..setUint32(0, bytes.length, Endian.big);
    socket.add([...header.buffer.asUint8List(), ...bytes]);
  }

  void _writeVarint(BytesBuilder out, int value) {
    var v = value;
    while (true) {
      final b = v & 0x7F;
      v >>= 7;
      if (v == 0) {
        out.addByte(b);
        return;
      }
      out.addByte(b | 0x80);
    }
  }

  void _writeVarintField(BytesBuilder out, int field, int value) {
    _writeVarint(out, field << 3);
    _writeVarint(out, value);
  }

  void _writeStringField(BytesBuilder out, int field, String value) {
    final bytes = utf8.encode(value);
    _writeVarint(out, (field << 3) | 2);
    _writeVarint(out, bytes.length);
    out.add(bytes);
  }

  void _onData(Uint8List data) {
    _buffer.add(data);
    while (true) {
      final bytes = _buffer.toBytes();
      if (bytes.length < 4) return;
      final length = ByteData.sublistView(bytes, 0, 4).getUint32(0, Endian.big);
      if (length <= 0 || length > 1 << 20) {
        _buffer.clear();
        return;
      }
      if (bytes.length < 4 + length) return;
      final frame = Uint8List.sublistView(bytes, 4, 4 + length);
      final rest = bytes.sublist(4 + length);
      _buffer.clear();
      if (rest.isNotEmpty) _buffer.add(rest);
      _parseMessage(frame);
    }
  }

  void _parseMessage(Uint8List frame) {
    var pos = 0;
    var namespace = '';
    var source = '';
    var payloadUtf8 = '';
    while (pos < frame.length) {
      final tag = _readVarint(frame, pos);
      if (tag == null) return;
      pos = tag.$2;
      final field = tag.$1 >> 3;
      final wire = tag.$1 & 7;
      if (wire == 0) {
        final v = _readVarint(frame, pos);
        if (v == null) return;
        pos = v.$2;
      } else if (wire == 2) {
        final len = _readVarint(frame, pos);
        if (len == null) return;
        pos = len.$2;
        if (pos + len.$1 > frame.length) return;
        final slice = Uint8List.sublistView(frame, pos, pos + len.$1);
        if (field == 2) source = utf8.decode(slice, allowMalformed: true);
        if (field == 4) namespace = utf8.decode(slice, allowMalformed: true);
        if (field == 6) payloadUtf8 = utf8.decode(slice, allowMalformed: true);
        pos += len.$1;
      } else {
        return; // unknown wire type — bail
      }
    }
    if (namespace.isEmpty || payloadUtf8.isEmpty) return;
    try {
      final decoded = jsonDecode(payloadUtf8);
      if (decoded is Map<String, dynamic>) {
        _route(namespace, source, decoded);
      }
    } catch (_) {
      // Non-JSON payload — ignore.
    }
  }

  (int, int)? _readVarint(Uint8List bytes, int start) {
    var result = 0;
    var shift = 0;
    var pos = start;
    while (pos < bytes.length) {
      final b = bytes[pos];
      pos++;
      result |= (b & 0x7F) << shift;
      if ((b & 0x80) == 0) return (result, pos);
      shift += 7;
      if (shift > 63) return null;
    }
    return null;
  }
}
