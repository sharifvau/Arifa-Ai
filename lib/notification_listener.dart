import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// One incoming WhatsApp message, reconstructed from a Notification Listener
/// event. Only the contact name, the message body and the notification key are
/// ever passed into Dart — nothing leaves the device unless the user explicitly
/// opts into cloud reply/brain in Settings.
class IncomingWhatsAppMessage {
  final String contact;
  final String message;
  final String notificationKey;
  final String packageName;
  final DateTime receivedAt;

  const IncomingWhatsAppMessage({
    required this.contact,
    required this.message,
    required this.notificationKey,
    required this.packageName,
    required this.receivedAt,
  });

  bool get isBusiness => packageName == 'com.whatsapp.w4b';

  factory IncomingWhatsAppMessage.fromJson(Map<String, dynamic> j) {
    return IncomingWhatsAppMessage(
      contact: (j['contact'] ?? '').toString(),
      message: (j['message'] ?? '').toString(),
      notificationKey: (j['key'] ?? '').toString(),
      packageName: (j['package'] ?? 'com.whatsapp').toString(),
      receivedAt: DateTime.fromMillisecondsSinceEpoch(
        int.tryParse((j['ts'] ?? '').toString()) ??
            DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  Map<String, dynamic> toJson() => {
    'contact': contact,
    'message': message,
    'key': notificationKey,
    'package': packageName,
    'ts': receivedAt.millisecondsSinceEpoch,
  };
}

/// Dart side of the native NotificationListenerService + permission helpers.
class NotificationListener {
  NotificationListener();

  static const MethodChannel _method = MethodChannel('arifa/native');
  static const EventChannel _event = EventChannel('arifa/whatsapp_events');

  /// Encrypted queue of notifications that arrived while no Dart isolate was
  /// alive. A fresh isolate drains it on init so no allowed message is lost.
  static const _pendingKey = 'wa_pending_messages';
  static const _pendingCap = 50;
  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(),
  );

  final StreamController<IncomingWhatsAppMessage> _incoming =
      StreamController<IncomingWhatsAppMessage>.broadcast();
  final StreamController<String> _status = StreamController<String>.broadcast();
  StreamSubscription<dynamic>? _sub;

  /// Serializes read-modify-write of the pending queue between bursts.
  Future<void> _pendingWrite = Future<void>.value();

  Stream<IncomingWhatsAppMessage> get incoming => _incoming.stream;
  Stream<String> get status => _status.stream;

  Future<void> init() async {
    if (_sub != null) return;
    _sub = _event.receiveBroadcastStream().listen(
      _onEvent,
      onError: (Object e) => _status.add('[notification listener] $e'),
    );
    // Messages queued during process death are replayed into _incoming here.
    // AutoReplyService subscribes before calling init(), so nothing is lost.
    await drainPending();
  }

  /// Replays the encrypted pending queue into [_incoming] and clears it.
  /// Returns how many messages were handed back to Dart.
  Future<int> drainPending() async {
    var drained = 0;
    // Share the write chain so a burst arriving mid-drain is never lost or
    // replayed twice on the next startup.
    _pendingWrite = _pendingWrite.then((_) async {
      try {
        final raw = await _storage.read(key: _pendingKey);
        if (raw == null || raw.trim().isEmpty) return;
        await _storage.delete(key: _pendingKey);

        final decoded = jsonDecode(raw);
        if (decoded is! List) return;

        for (final item in decoded) {
          if (item is! String || item.isEmpty) continue;
          try {
            final message = IncomingWhatsAppMessage.fromJson(
              jsonDecode(item) as Map<String, dynamic>,
            );
            if (message.contact.isEmpty || message.message.isEmpty) continue;
            _incoming.add(message);
            drained++;
          } catch (_) {
            // A corrupt row is dropped; the rest of the queue still replays.
          }
        }
      } catch (_) {
        // A storage failure never blocks startup.
      }
    });
    await _pendingWrite;
    return drained;
  }

  /// Persists raw JSON so a fresh isolate can reconstruct the message even if
  /// the event channel was never attached in the previous process.
  Future<void> _queuePending(String payload) {
    _pendingWrite = _pendingWrite.then((_) async {
      try {
        final raw = await _storage.read(key: _pendingKey);
        final list = <String>[];
        if (raw != null && raw.trim().isNotEmpty) {
          final decoded = jsonDecode(raw);
          if (decoded is List) list.addAll(decoded.whereType<String>());
        }
        list.add(payload);
        if (list.length > _pendingCap) {
          list.removeRange(0, list.length - _pendingCap);
        }
        await _storage.write(key: _pendingKey, value: jsonEncode(list));
      } catch (_) {
        // Storage failure must never block a live reply.
      }
    });
    return _pendingWrite;
  }

  void _onEvent(dynamic event) {
    if (event is! Map) return;
    final type = (event['type'] ?? '').toString();
    final payload = (event['payload'] ?? '').toString();
    if (type == 'whatsapp_message' && payload.isNotEmpty) {
      try {
        final decoded = jsonDecode(payload) as Map<String, dynamic>;
        final message = IncomingWhatsAppMessage.fromJson(decoded);
        if (message.contact.isNotEmpty && message.message.isNotEmpty) {
          // Survive process death: native has already applied the allow-list,
          // so it is safe to keep this payload for the next Dart isolate.
          unawaited(_queuePending(payload));
          _incoming.add(message);
        }
      } catch (_) {
        // A malformed notification is dropped, never shown or uploaded.
      }
      return;
    }
    if (payload.isNotEmpty) {
      _status.add(payload);
    } else if (type.isNotEmpty) {
      _status.add(type);
    }
  }

  /// Pushes the allow-list gate down to native code: when auto reply is OFF or
  /// the allow list is empty, Android discards the notification without even
  /// emitting its text into Dart.
  Future<bool> configure({
    required bool enabled,
    required List<String> allowList,
    required List<String> importantContacts,
    required bool replyUnknown,
  }) async {
    try {
      final nativeAllow = replyUnknown && !allowList.contains('*')
          ? [...allowList, '*']
          : allowList;
      final result = await _method.invokeMethod<bool>(
        'configureWhatsAppAutoReply',
        {
          'enabled': enabled,
          'allowList': nativeAllow,
          'importantContacts': importantContacts,
        },
      );
      return result ?? false;
    } on PlatformException catch (e) {
      _status.add('[auto reply config] ${e.message}');
      return false;
    }
  }

  Future<bool> get notificationAccessEnabled async {
    try {
      return await _method.invokeMethod<bool>('isNotificationAccessEnabled') ??
          false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> get accessibilityEnabled async {
    try {
      return await _method.invokeMethod<bool>('isAccessibilityEnabled') ??
          false;
    } catch (_) {
      return false;
    }
  }

  Future<void> openNotificationSettings() =>
      _method.invokeMethod<void>('openNotificationAccessSettings');

  Future<void> openAccessibilitySettings() =>
      _method.invokeMethod<void>('openAccessibilitySettings');

  /// Opens the exact WhatsApp conversation from the notification's own
  /// PendingIntent — more reliable than guessing a phone number.
  Future<bool> openChat(String notificationKey) async {
    try {
      return await _method.invokeMethod<bool>('openWhatsAppChat', {
            'key': notificationKey,
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    await _pendingWrite;
    await _incoming.close();
    await _status.close();
  }
}
