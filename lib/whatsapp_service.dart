import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'config.dart';
import 'notification_listener.dart';

class ReplyOutcome {
  final bool ok;
  final String detail;
  final String channel;

  const ReplyOutcome({
    required this.ok,
    required this.detail,
    required this.channel,
  });
}

/// Sends an already-decided reply. Two channels are supported:
///
/// 1. Accessibility: open the exact chat from the notification PendingIntent,
///    type into the composer and tap Send. No server is involved (default).
/// 2. WhatsApp Business Cloud API: only when the user supplied a token and a
///    Phone Number ID and explicitly enabled it in Settings.
class WhatsAppService {
  WhatsAppService({required NotificationListener listener})
    : _listener = listener;

  final NotificationListener _listener;
  final http.Client _client = http.Client();

  static const MethodChannel _method = MethodChannel('arifa/native');

  Future<bool> get accessibilityEnabled => _listener.accessibilityEnabled;

  Future<ReplyOutcome> sendReply({
    required IncomingWhatsAppMessage incoming,
    required String reply,
    required bool useCloudApi,
    required String token,
    required String phoneNumberId,
    String? cloudRecipient,
  }) async {
    if (useCloudApi && token.isNotEmpty && phoneNumberId.isNotEmpty) {
      final to = cloudRecipient ?? _digits(incoming.contact);
      if (to.isEmpty) {
        return const ReplyOutcome(
          ok: false,
          detail: 'Cloud API winner: add the contact number to the Allow List',
          channel: 'cloud_api',
        );
      }
      try {
        return await _sendViaCloud(
          token: token,
          phoneNumberId: phoneNumberId,
          to: to,
          body: reply,
        );
      } catch (e) {
        // A failed cloud call still falls back to on-device accessibility.
        return _sendViaAccessibility(incoming, reply, fallbackReason: '$e');
      }
    }
    return _sendViaAccessibility(incoming, reply);
  }

  Future<ReplyOutcome> _sendViaAccessibility(
    IncomingWhatsAppMessage incoming,
    String reply, {
    String? fallbackReason,
  }) async {
    if (!await _listener.accessibilityEnabled) {
      return const ReplyOutcome(
        ok: false,
        detail: 'Accessibility Service OFF — enable it in Settings',
        channel: 'accessibility',
      );
    }

    final openedChat = await _listener.openChat(incoming.notificationKey);
    if (!openedChat) {
      await _method.invokeMethod<void>('openWhatsApp');
    }
    await Future<void>.delayed(const Duration(milliseconds: 180));

    try {
      final result = await _method.invokeMethod<String>('typeWhatsAppReply', {
        'text': reply,
      });
      final ok = result == 'sent';
      return ReplyOutcome(
        ok: ok,
        detail: ok
            ? (fallbackReason == null ? 'sent' : 'cloud fail, sent on device')
            : 'composer/send button not found: ${result ?? 'unknown'}',
        channel: 'accessibility',
      );
    } on PlatformException catch (e) {
      return ReplyOutcome(
        ok: false,
        detail: 'accessibility error: ${e.message}',
        channel: 'accessibility',
      );
    }
  }

  Future<ReplyOutcome> _sendViaCloud({
    required String token,
    required String phoneNumberId,
    required String to,
    required String body,
  }) async {
    final res = await _client
        .post(
          Uri.parse(
            '${ArifaConstants.whatsappCloudEndpoint}/'
            '${Uri.encodeComponent(phoneNumberId)}/messages',
          ),
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'messaging_product': 'whatsapp',
            'to': to,
            'type': 'text',
            'text': {'body': body},
          }),
        )
        .timeout(const Duration(seconds: 4));

    if (res.statusCode >= 400) {
      throw Exception('Cloud API ${res.statusCode}: ${res.body}');
    }
    return const ReplyOutcome(
      ok: true,
      detail: 'sent via Business Cloud API',
      channel: 'cloud_api',
    );
  }

  /// Extracts a dialable number from a title like "+880 1712-345678".
  String _digits(String value) {
    final clean = value.replaceAll(RegExp(r'[^\d+]'), '');
    if (!clean.startsWith('+')) return clean.replaceAll('+', '');
    final digits = clean.replaceAll('+', '');
    if (digits.startsWith('880') && digits.length >= 13) return digits;
    if (digits.length == 11 && digits.startsWith('0')) {
      return '880${digits.substring(1)}';
    }
    return digits;
  }

  void dispose() {
    _client.close();
  }
}
