import 'dart:async';
import 'dart:convert';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'arifa_brain.dart';
import 'notification_listener.dart';
import 'settings_service.dart';
import 'whatsapp_service.dart';

enum ReplySource { custom, cloudBrain, local }

/// One row of the on-device "Kake ki reply dilam" log.
class AutoReplyLogEntry {
  final String id;
  final String contact;
  final String incoming;
  final String reply;
  final DateTime at;
  final bool sent;
  final String channel;
  final String source;
  final bool important;

  const AutoReplyLogEntry({
    required this.id,
    required this.contact,
    required this.incoming,
    required this.reply,
    required this.at,
    required this.sent,
    required this.channel,
    required this.source,
    required this.important,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'contact': contact,
    'incoming': incoming,
    'reply': reply,
    'at': at.toIso8601String(),
    'sent': sent,
    'channel': channel,
    'source': source,
    'important': important,
  };

  factory AutoReplyLogEntry.fromJson(Map<String, dynamic> j) =>
      AutoReplyLogEntry(
        id: (j['id'] ?? '').toString(),
        contact: (j['contact'] ?? '').toString(),
        incoming: (j['incoming'] ?? '').toString(),
        reply: (j['reply'] ?? '').toString(),
        at: DateTime.tryParse((j['at'] ?? '').toString()) ?? DateTime.now(),
        sent: j['sent'] == true,
        channel: (j['channel'] ?? '').toString(),
        source: (j['source'] ?? 'local').toString(),
        important: j['important'] == true,
      );
}

class _ReplyDecision {
  final String reply;
  final ReplySource source;
  const _ReplyDecision(this.reply, this.source);
}

/// Reads allow-listed WhatsApp notifications and replies like Emon Bhai.
///
/// Privacy defaults: OFF, empty allow list, local reply brain, local sending.
/// Incoming message text never leaves the phone unless the user explicitly
/// switches on "Use AI brain" or "Business Cloud API" in Settings.
class AutoReplyService {
  AutoReplyService._();

  static final AutoReplyService instance = AutoReplyService._();

  final NotificationListener _listener = NotificationListener();
  late final WhatsAppService _whatsapp;
  ArifaBrain? _brain;
  FlutterLocalNotificationsPlugin? _notifications;

  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(),
  );
  static const _logKey = 'whatsapp_reply_log_v1';
  static const _channelId = 'arifa_channel';

  final List<AutoReplyLogEntry> _logs = <AutoReplyLogEntry>[];
  final StreamController<List<AutoReplyLogEntry>> _logsCtrl =
      StreamController<List<AutoReplyLogEntry>>.broadcast();
  final StreamController<String> _statusCtrl =
      StreamController<String>.broadcast();
  final StreamController<bool> _enabledCtrl =
      StreamController<bool>.broadcast();

  final List<IncomingWhatsAppMessage> _queue = <IncomingWhatsAppMessage>[];
  final List<String> _recent = <String>[];
  bool _started = false;
  bool _draining = false;

  Stream<List<AutoReplyLogEntry>> get logs => _logsCtrl.stream;
  Stream<String> get status => _statusCtrl.stream;
  Stream<bool> get enabledChanges => _enabledCtrl.stream;
  List<AutoReplyLogEntry> get entries => List.unmodifiable(_logs);
  bool get isEnabled => SettingsService.instance.whatsappAutoReply;
  NotificationListener get notificationListener => _listener;

  Future<void> init() async {
    if (_started) return;
    _started = true;

    await _listener.init();
    _whatsapp = WhatsAppService(listener: _listener);
    _brain = ArifaBrain();
    _notifications = FlutterLocalNotificationsPlugin();
    await _notifications!.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
    );
    await _loadLogs();

    _listener.incoming.listen(_queueMessage);
    _listener.status.listen((s) => _statusCtrl.add(s));
    await refreshConfig();
  }

  /// Re-pushes settings (including the native allow-list gate).
  Future<void> refreshConfig() async {
    final s = SettingsService.instance;
    await _listener.configure(
      enabled: s.whatsappAutoReply,
      allowList: s.whatsappAllowList,
      importantContacts: s.whatsappImportantContacts,
      replyUnknown: s.whatsappReplyUnknown,
    );
    if (!_enabledCtrl.isClosed) _enabledCtrl.add(s.whatsappAutoReply);

    if (s.whatsappAutoReply) {
      if (!await _listener.notificationAccessEnabled) {
        if (!_statusCtrl.isClosed) {
          _statusCtrl.add('WA ON: Notification access chai — Settings e din');
        }
      } else if (!await _listener.accessibilityEnabled) {
        if (!_statusCtrl.isClosed) {
          _statusCtrl.add('WA ON: Accessibility chai — Settings e din');
        }
      }
    }
  }

  /// Instant ON/OFF from the home dot, Settings switch or voice command.
  Future<void> setEnabled(bool value) async {
    await SettingsService.instance.setWhatsAppEnabled(value);
    await refreshConfig();
    if (!_statusCtrl.isClosed) {
      _statusCtrl.add(
        value ? 'WhatsApp Auto Reply ON ♥' : 'WhatsApp Auto Reply OFF',
      );
    }
  }

  Future<void> clearLogs() async {
    _logs.clear();
    await _persistLogs();
  }

  Future<void> _loadLogs() async {
    try {
      final raw = await _storage.read(key: _logKey);
      if (raw == null || raw.trim().isEmpty) return;
      final decoded = jsonDecode(raw) as List;
      _logs.addAll(
        decoded.whereType<Map<String, dynamic>>().map(
          AutoReplyLogEntry.fromJson,
        ),
      );
      if (!_logsCtrl.isClosed) _logsCtrl.add(List.unmodifiable(_logs));
    } catch (_) {
      // A corrupt log is ignored; no user data is destroyed.
    }
  }

  Future<void> _persistLogs() async {
    try {
      final capped = _logs.take(200).toList();
      await _storage.write(
        key: _logKey,
        value: jsonEncode(capped.map((e) => e.toJson()).toList()),
      );
    } catch (_) {}
    if (!_logsCtrl.isClosed) _logsCtrl.add(List.unmodifiable(_logs));
  }

  void _queueMessage(IncomingWhatsAppMessage msg) {
    if (!isEnabled || !_canReply(msg.contact)) return;

    final fingerprint =
        '${msg.contact}|${msg.message}|${msg.receivedAt.millisecondsSinceEpoch ~/ 1000}';
    if (_recent.contains(fingerprint)) return;
    _recent.add(fingerprint);
    if (_recent.length > 80) _recent.removeAt(0);

    _queue.add(msg);
    _drain();
  }

  Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    while (_queue.isNotEmpty && isEnabled) {
      final msg = _queue.removeAt(0);
      try {
        await _handleMessage(msg);
      } catch (e) {
        if (!_statusCtrl.isClosed) {
          _statusCtrl.add('WhatsApp reply error: $e');
        }
      }
    }
    _draining = false;
  }

  Future<void> _handleMessage(IncomingWhatsAppMessage msg) async {
    final s = SettingsService.instance;
    final important = _isImportant(msg.contact);
    if (!_statusCtrl.isClosed) {
      _statusCtrl.add('${msg.contact}: typing...');
    }
    if (important) await _notifyImportant(msg);

    final decision = await _decideReply(msg, s);

    // Human-like beat before the send. Everything above is local and instant.
    await Future<void>.delayed(const Duration(milliseconds: 500));
    if (!_statusCtrl.isClosed) {
      _statusCtrl.add('${msg.contact}: sending...');
    }

    String? cloudRecipient;
    for (final entry in s.whatsappAllowList) {
      if (_matches(entry, msg.contact)) {
        cloudRecipient = _asInternationalNumber(entry);
        break;
      }
    }

    final outcome = await _whatsapp.sendReply(
      incoming: msg,
      reply: decision.reply,
      useCloudApi: s.whatsappUseCloudApi,
      token: s.whatsappBusinessToken,
      phoneNumberId: s.whatsappBusinessPhoneId,
      cloudRecipient: cloudRecipient,
    );

    _logs.insert(
      0,
      AutoReplyLogEntry(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        contact: msg.contact,
        incoming: msg.message,
        reply: decision.reply,
        at: DateTime.now(),
        sent: outcome.ok,
        channel: outcome.channel,
        source: decision.source.name,
        important: important,
      ),
    );
    await _persistLogs();

    if (!_statusCtrl.isClosed) {
      _statusCtrl.add(
        outcome.ok
            ? '${msg.contact}-কে reply dilam ♥'
            : '${msg.contact}: reply dilam na (${outcome.detail})',
      );
    }
  }

  Future<void> _notifyImportant(IncomingWhatsAppMessage msg) async {
    await _notifications!.show(
      DateTime.now().millisecondsSinceEpoch ~/ 1000 % 2147483647,
      'Emon Bhai, ${msg.contact} message dise, dekhen',
      msg.message.length > 90
          ? '${msg.message.substring(0, 90)}…'
          : msg.message,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          'ARIFA',
          channelDescription: 'ARIFA build and WhatsApp alerts',
          importance: Importance.high,
          priority: Priority.high,
        ),
      ),
    );
  }

  Future<_ReplyDecision> _decideReply(
    IncomingWhatsAppMessage msg,
    SettingsService s,
  ) async {
    for (final entry in s.whatsappCustomReplies.entries) {
      if (_matches(entry.key, msg.contact) && entry.value.trim().isNotEmpty) {
        return _ReplyDecision(entry.value.trim(), ReplySource.custom);
      }
    }

    if (s.whatsappUseCloudBrain) {
      try {
        final text = await _brain!.autoReply(
          incomingMessage: msg.message,
          contact: msg.contact,
          styleSamples: _styleSamples(s),
        );
        if (text.trim().isNotEmpty) {
          return _ReplyDecision(text.trim(), ReplySource.cloudBrain);
        }
      } catch (_) {
        // Slow or failing cloud model → instant local style brain takes over.
      }
    }

    return _ReplyDecision(_localReply(msg, s), ReplySource.local);
  }

  List<String> _styleSamples(SettingsService s) {
    final samples = <String>[...s.whatsappStyleSamples];
    for (final e in _logs.take(6)) {
      if (e.sent && e.reply.isNotEmpty) samples.add(e.reply);
    }
    return samples;
  }

  String _localReply(IncomingWhatsAppMessage msg, SettingsService s) {
    final text = msg.message.toLowerCase().trim();
    final hash = msg.message.hashCode ^ msg.contact.hashCode;
    final emoji = hash.abs() % 3 == 0 ? ' ♥' : '';

    if (!_isAllowed(msg.contact) && s.whatsappReplyUnknown) {
      return 'Ke bolchen? Emon Bhai ekhon busy, pore reply dibe';
    }

    if (RegExp(
      r'apk|code|flutter|dart|work|office|meeting|client|boss|deadline|payment|'
      r'কোড|কাজ|অফিস|মিটিং|বানা|টাকা',
      caseSensitive: false,
    ).hasMatch(text)) {
      return 'Emon Bhai ektu busy ache, pore kotha bolbe, '
          'tumi ki bolte chao amake bolo ami pouche dibo';
    }

    if (RegExp(
      r'^(hi|hello|hey|yo|assalamu.?alaikum|আসসালামু|নমস্কার|adt)\b',
      caseSensitive: false,
    ).hasMatch(text)) {
      return 'hi, kemon achos?$emoji';
    }

    if (RegExp(
      r'kire koi tui|koi tui|কই তুই|কোথায় তুই|where are you',
      caseSensitive: false,
    ).hasMatch(text)) {
      return 'are ei to achi, ektu busy chilam, bol ki khobor?';
    }

    if (RegExp(
      r'ki khobor|kemon achos|কেমন আছিস|খবর কী',
      caseSensitive: false,
    ).hasMatch(text)) {
      return 'bhalo achi bhai, tumi ki khobor?$emoji';
    }

    if (RegExp(
      r'thanks|thank you|ধন্যবাদ|ok|okay',
      caseSensitive: false,
    ).hasMatch(text)) {
      return 'are kichu na bhai ♥';
    }

    const builtIn = <String>[
      'hmm boli na ki, ektu busy achi — bol ki khobor?',
      'achi bhai, ki bolchis?',
      'are thik achi, tumi bolo ki korchen? ♥',
      'ha bhai, bol — ami shoti khuji.',
      'ektu pore kotha bolbo, aaj onek kaj chole ache bhai.',
    ];
    final pool = <String>[...builtIn, ...s.whatsappStyleSamples];
    if (pool.isEmpty) return 'achi bhai, bol ki khobor?';
    return pool[hash.abs() % pool.length];
  }

  bool _canReply(String contact) {
    final s = SettingsService.instance;
    if (s.whatsappAllowList.isEmpty && !s.whatsappReplyUnknown) return false;
    return _isAllowed(contact) || s.whatsappReplyUnknown;
  }

  bool _isAllowed(String contact) {
    for (final entry in SettingsService.instance.whatsappAllowList) {
      if (_matches(entry, contact)) return true;
    }
    return false;
  }

  bool _isImportant(String contact) {
    for (final entry in SettingsService.instance.whatsappImportantContacts) {
      if (_matches(entry, contact)) return true;
    }
    return false;
  }

  bool _matches(String entry, String contact) {
    final a = entry.trim().toLowerCase();
    final b = contact.trim().toLowerCase();
    if (a.isEmpty || b.isEmpty) return false;
    if (a == '*') return true;
    return a == b || b.contains(a) || a.contains(b);
  }

  String _asInternationalNumber(String value) {
    var digits = value.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.startsWith('880') && digits.length >= 13) return digits;
    if (digits.length == 11 && digits.startsWith('0')) {
      return '880${digits.substring(1)}';
    }
    return digits;
  }

  Future<void> dispose() async {
    _whatsapp.dispose();
    await _listener.dispose();
    await _logsCtrl.close();
    await _statusCtrl.close();
    await _enabledCtrl.close();
  }
}
