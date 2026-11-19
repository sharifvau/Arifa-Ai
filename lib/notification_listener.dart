import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

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

  final StreamController<IncomingWhatsAppMessage> _incoming =
      StreamController<IncomingWhatsAppMessage>.broadcast();
  final StreamController<String> _status = StreamController<String>.broadcast();
  StreamSubscription<dynamic>? _sub;

  Stream<IncomingWhatsAppMessage> get incoming => _incoming.stream;
  Stream<String> get status => _status.stream;

  Future<void> init() async {
    if (_sub != null) return;
    _sub = _event.receiveBroadcastStream().listen(
      _onEvent,
      onError: (Object e) => _status.add('[notification listener] $e'),
    );
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
    await _incoming.close();
    await _status.close();
  }
}
