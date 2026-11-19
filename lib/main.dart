import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';

import 'apk_builder.dart';
import 'arifa_avatar.dart';
import 'auto_reply_service.dart';
import 'arifa_brain.dart';
import 'background_service.dart';
import 'live_background.dart';
import 'models.dart';
import 'phone_control.dart';
import 'screen_service.dart';
import 'settings_screen.dart';
import 'settings_service.dart';
import 'voice_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SettingsService.instance.init();
  // Start before the UI so allow-listed replies keep working even when the
  // chat sheet is closed or the app is in the background.
  await AutoReplyService.instance.init();
  runApp(const ArifaApp());
}

class ArifaApp extends StatelessWidget {
  const ArifaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ARIFA',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF010610),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00B4FF),
          brightness: Brightness.dark,
        ),
      ),
      home: const ArifaHome(),
    );
  }
}

class ArifaHome extends StatefulWidget {
  const ArifaHome({super.key});

  @override
  State<ArifaHome> createState() => _ArifaHomeState();
}

class _ArifaHomeState extends State<ArifaHome>
    with SingleTickerProviderStateMixin {
  late final ArifaBrain _brain;
  late final VoiceService _voice;
  late final BackgroundService _native;
  late final PhoneControl _phone;
  late final ScreenService _screen;
  late final ApkBuilder _builder;
  late final FlutterLocalNotificationsPlugin _notifications;
  late final AnimationController _pulse;

  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final List<ChatMessage> _messages = [];

  StreamSubscription<WakeEvent>? _wakeSub;
  StreamSubscription<bool>? _speakingSub;
  StreamSubscription<String>? _heardSub;
  StreamSubscription<bool>? _waEnabledSub;
  StreamSubscription<String>? _waStatusSub;
  Timer? _moodTimer;

  AvatarMood _mood = AvatarMood.happy;
  String _caption = 'Jekhoni "Arifa" bolben ♥';
  bool _speaking = false;
  bool _listening = false;
  bool _busy = false;
  bool _serviceOn = false;
  bool _waAutoReply = false;
  String _waStatus = '';
  String _status = 'শুরু হচ্ছে...';
  GeneratedApp? _lastApp;

  static const _channelId = 'arifa_channel';

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1300),
    )..repeat(reverse: true);

    _brain = ArifaBrain();
    _voice = VoiceService(SettingsService.instance);
    _native = BackgroundService();
    _phone = PhoneControl();
    _screen = ScreenService(brain: _brain, native: _native);
    _builder = ApkBuilder(brain: _brain);
    _notifications = FlutterLocalNotificationsPlugin();

    _boot();
  }

  Future<void> _boot() async {
    try {
      await _voice.init();
      await _initNotifications();
      await _askPermissions();

      _speakingSub = _voice.onSpeakingChanged.listen((v) {
        if (!mounted) return;
        setState(() => _speaking = v);
        if (v) {
          _setMood(AvatarMood.speaking, 'বলছি Emon Bhai ♥');
        } else if (!_busy && _mood == AvatarMood.speaking) {
          _setMood(AvatarMood.happy, 'Jekhoni "Arifa" bolben ♥');
        }
      });
      _heardSub = _voice.onHeard.listen((t) {
        if (t.startsWith('[TTS]') || t.startsWith('[STT]')) {
          if (mounted) setState(() => _status = t);
        }
      });

      await _native.listen();
      _wakeSub = _native.events.listen(_onNativeEvent);
      await _syncWakeService();

      _waAutoReply = AutoReplyService.instance.isEnabled;
      _waEnabledSub = AutoReplyService.instance.enabledChanges.listen((v) {
        if (mounted) setState(() => _waAutoReply = v);
      });
      _waStatusSub = AutoReplyService.instance.status.listen((s) {
        if (mounted) setState(() => _waStatus = s);
      });

      _addArifa('Ji Emon Bhai, bolen na, ki korbo apnar jonno? ♥');
      _setMood(
        AvatarMood.speaking,
        'Ji Emon Bhai, bolen na ♥',
        autoReset: const Duration(seconds: 3),
      );
      await _voice.speak('Ji Emon Bhai, bolen na, ki korbo apnar jonno?');

      if (mounted) {
        setState(() {
          _status = _serviceOn
              ? 'সবসময় শুনছি, Emon Bhai'
              : 'মাইক দিয়ে কথা বলুন';
        });
      }
      await _promptFirstRun();
    } catch (e) {
      if (mounted) setState(() => _status = 'Init error: $e');
    }
  }

  void _setMood(AvatarMood mood, String caption, {Duration? autoReset}) {
    if (!mounted) return;
    _moodTimer?.cancel();
    setState(() {
      _mood = mood;
      _caption = caption;
    });
    if (autoReset != null) {
      _moodTimer = Timer(autoReset, () {
        if (!mounted || _busy || _speaking) return;
        setState(() {
          _mood = AvatarMood.happy;
          _caption = 'Jekhoni "Arifa" bolben ♥';
        });
      });
    }
  }

  Future<void> _syncWakeService() async {
    final shouldRun = SettingsService.instance.wakeEnabled;
    final ok = shouldRun
        ? await _native.startWakeService()
        : await _native.stopWakeService();
    if (mounted) {
      setState(() => _serviceOn = shouldRun && ok);
    }
  }

  Future<void> _promptFirstRun() async {
    if (!SettingsService.instance.needsSetup || !mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF06182B),
        title: const Text(
          'Emon Bhai, Settings e giye API Key din',
          style: TextStyle(color: Colors.cyanAccent),
        ),
        content: const Text(
          'API key আর মডেল আইডি ছাড়া ARIFA-র ব্রেইন চলবে না। '
          'তোমার কীগুলো কোডে বা APK-তে নয় — এনক্রিপ্টেড স্টোরে রাখা হবে। '
          'এখন Settings খুলছি ♥',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            style: FilledButton.styleFrom(backgroundColor: Colors.cyanAccent),
            child: const Text(
              'Settings e jaan',
              style: TextStyle(color: Colors.black),
            ),
          ),
        ],
      ),
    );
    if (mounted) await _openSettings();
  }

  Future<void> _openSettings() async {
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const SettingsScreen()),
    );
    if (saved == true) {
      await _voice.reloadVoice();
      await _syncWakeService();
      await AutoReplyService.instance.refreshConfig();
      if (mounted) {
        setState(() {
          _status = _serviceOn
              ? 'সব প্রস্তুত, Emon Bhai ♥'
              : 'ভয়েস ও ব্রেইন সেভ হয়েছে';
        });
      }
      _setMood(
        AvatarMood.happy,
        'প্রস্তুত Emon Bhai ♥',
        autoReset: const Duration(seconds: 2),
      );
    }
  }

  Future<void> _initNotifications() async {
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    await _notifications.initialize(
      const InitializationSettings(android: android),
    );
  }

  Future<void> _askPermissions() async {
    await [Permission.microphone, Permission.notification].request();
  }

  void _addArifa(String text, [List<CodeBlock> code = const []]) {
    setState(() {
      _messages.add(
        ChatMessage(speaker: Speaker.arifa, text: text, code: code),
      );
    });
    _scrollToEnd();
  }

  void _addUser(String text) {
    setState(() {
      _messages.add(ChatMessage(speaker: Speaker.user, text: text));
    });
    _scrollToEnd();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _onNativeEvent(WakeEvent event) {
    if (event.text.startsWith('[')) {
      if (mounted) setState(() => _status = event.text);
      return;
    }
    switch (event.source) {
      case 'wake':
        _handleWake(event.text);
        break;
      case 'screen':
        _addArifa('স্ক্রিনশট নেওয়া হয়েছে: ${event.text}');
        break;
      default:
        if (event.text.isNotEmpty) _handleCommand(event.text);
    }
  }

  Future<void> _handleWake(String heard) async {
    if (_busy || _listening) return;

    final inlineCommand = VoiceService.extractAfterWakeWord(heard).trim();
    if (inlineCommand.isNotEmpty &&
        !inlineCommand.startsWith('shape tomake') &&
        !inlineCommand.startsWith('বলো')) {
      _handleCommand(heard);
      return;
    }

    _setMood(AvatarMood.listening, 'Ji Emon Bhai ♥');
    await _voice.speak('হ্যাঁ Emon Bhai, বলুন?');
    final started = await _voice.startListening(
      onResult: (text, finalResult) {
        if (!finalResult) return;
        _voice.stopListening();
        _handleCommand(text);
      },
      listenFor: const Duration(seconds: 20),
      pauseFor: const Duration(seconds: 3),
    );
    if (mounted) setState(() => _listening = started);
    if (!started) {
      _addArifa(
        'মাইক চালু হলো না। Settings-এ microphone permission দিও Emon Bhai।',
      );
      _setMood(
        AvatarMood.error,
        'Sorry Emon Bhai, ami thik kore dicchi',
        autoReset: const Duration(seconds: 3),
      );
    }
  }

  Future<void> _handleCommand(String raw) async {
    final text = VoiceService.extractAfterWakeWord(raw).trim();
    if (text.isEmpty || _busy) return;

    // Instant ON/OFF — no brain call, no "thinking" delay.
    final waToggle = _whatsAppAutoReplyIntent(text);
    if (waToggle != null) {
      _addUser(raw);
      await _setWhatsAppAutoReply(waToggle);
      return;
    }

    _addUser(raw);
    setState(() {
      _busy = true;
      _status = 'ভাবছি...';
    });
    _moodTimer?.cancel();
    _setMood(AvatarMood.thinking, 'Daran Emon Bhai, vabtesi...');

    try {
      final lower = text.toLowerCase();
      if (RegExp(r'screen|স্ক্রিন|screenshot|dekho|দেখ').hasMatch(lower)) {
        await _handleScreen();
      } else if (RegExp(r'apk|app|অ্যাপ|বানা|banaw|banao|build|কম্পাইল|compile')
          .hasMatch(lower)) {
        await _handleBuild(text);
      } else if (RegExp(r'setting|সেটিং').hasMatch(lower)) {
        await _openSettings();
      } else if (RegExp(r'whatsapp|হোয়াটসঅ্যাপ').hasMatch(lower)) {
        await _handleWhatsApp(text);
      } else if (RegExp(r'wifi|wi-fi|ওয়াইফাই|ওয়াইফাই').hasMatch(lower)) {
        await _handleWifi(text);
      } else if (RegExp(r'call|ফোন|কল|dial').hasMatch(lower)) {
        await _handleCall(text);
      } else if (RegExp(r'song|গান|music|মিউজিক|play').hasMatch(lower)) {
        await _handleSong(text);
      } else if (RegExp(r'open|খুল|খোল|launch').hasMatch(lower)) {
        await _handleOpen(text);
      } else if (RegExp(r'voice|ভয়েস|ভয়েস|tts').hasMatch(lower)) {
        final r = await _phone.openTtsSettings();
        _addArifa('Google TTS settings খুলে দিচ্ছি Emon Bhai। $r');
        await _voice.speak('ভয়েস সেটিংস খুলে দিলাম Emon Bhai।');
      } else {
        final reply = await _brain.ask(text, history: _messages);
        _addArifa(reply.text, reply.code);
        await _voice.speak(reply.text);
      }
    } catch (e) {
      _addArifa('একটু সমস্যা হলো Emon Bhai: $e');
      _setMood(
        AvatarMood.error,
        'Sorry Emon Bhai, ami thik kore dicchi',
        autoReset: const Duration(seconds: 4),
      );
      await _voice.speak('Sorry Emon Bhai, ami thik kore dicchi.');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = _serviceOn ? 'সবসময় শুনছি, Emon Bhai' : 'প্রস্তুত';
        });
      }
    }
  }

  /// Recognizes "Arifa WhatsApp auto reply ON/OFF koro" and Bangla variants.
  bool? _whatsAppAutoReplyIntent(String text) {
    final lower = text.toLowerCase();
    if (!RegExp(r'(auto|অটো)[\s_-]*(reply|রিপ্লাই)').hasMatch(lower)) {
      return null;
    }
    if (RegExp(r'\boff\b|বন্ধ|বাতিল|ব্যাতিল|না\s*চাই').hasMatch(lower)) {
      return false;
    }
    if (RegExp(r'\bon\b|চালু|অন\s*কোর').hasMatch(lower)) {
      return true;
    }
    return null;
  }

  Future<void> _setWhatsAppAutoReply(bool on) async {
    await AutoReplyService.instance.setEnabled(on);
    _setMood(
      on ? AvatarMood.success : AvatarMood.happy,
      on ? 'WhatsApp Auto Reply ON ♥' : 'WhatsApp Auto Reply OFF',
      autoReset: const Duration(seconds: 2),
    );
    final line = on
        ? 'WhatsApp Auto Reply ON হয়ে গেছে Emon Bhai ♥ '
              'Allow List-এ যাদের নাম দিয়েছি শুধু তাদেরই reply দিব।'
        : 'WhatsApp Auto Reply OFF হয়ে গেছে Emon Bhai।';
    _addArifa(line);
    await _voice.speak(line);
  }

  Future<void> _handleScreen() async {
    if (mounted) setState(() => _status = 'স্ক্রিন দেখছি...');
    final report = await _screen.seeAndExplain();
    if (report == null) {
      _addArifa(
        'স্ক্রিন ধরতে পারলাম না Emon Bhai। '
        'Settings > Apps > ARIFA > Screen capture permission দিয়ে '
        'আবার বলো "Arifa screen dekho"।',
      );
      _setMood(
        AvatarMood.error,
        'Sorry Emon Bhai, amar screen permission chai',
        autoReset: const Duration(seconds: 4),
      );
      await _voice.speak('স্ক্রিন ক্যাপচার পারমিশন চাই Emon Bhai।');
      return;
    }

    _addArifa(report.description);
    await _voice.speak(report.description);

    if (report.hasError && _lastApp != null) {
      if (mounted) setState(() => _status = 'নিজে error ঠিক করছি...');
      try {
        final fixed = await _brain.fixFromScreen(
          screenDescription: report.description,
          errorLog: report.detectedErrors.join('\n'),
          app: _lastApp!,
        );
        _lastApp = fixed;
        final zip = await _builder.saveSourceZip(fixed);
        _addArifa(
          'Error টা ধরেছি, কোড ঠিক করে নতুন source zip দিলাম Emon Bhai।\n$zip',
          fixed.files,
        );
        _setMood(
          AvatarMood.success,
          'Hoye geche! ♥',
          autoReset: const Duration(seconds: 4),
        );
        await Share.shareXFiles([XFile(zip)], subject: 'ARIFA fixed source');
      } catch (e) {
        _addArifa('Auto-fix ব্যর্থ: $e');
        _setMood(
          AvatarMood.error,
          'Sorry Emon Bhai, ami thik kore dicchi',
          autoReset: const Duration(seconds: 4),
        );
      }
    }
  }

  Future<void> _handleBuild(String request) async {
    final result = await _builder.buildWithAutoFix(
      request,
      onProgress: (stage, detail) {
        if (mounted) setState(() => _status = '$stage: $detail');
      },
    );
    _lastApp = result.app;
    await _finishSourceBuild(result);
  }

  Future<void> _finishSourceBuild(BuildResult result) async {
    final msg =
        'Hoye geche Emon Bhai ♥\n'
        'কোড তৈরি + AI রিভিউ শেষ। Android ফোন নিজে APK build করতে পারে না, '
        'তাই source zip দিচ্ছি। Termux/PC-তে চালাও:\n'
        'flutter pub get\nflutter build apk --release\n\n'
        '${result.zipPath}';
    _addArifa(msg, result.app.files);
    _setMood(
      AvatarMood.success,
      'Hoye geche! ♥',
      autoReset: const Duration(seconds: 4),
    );
    await _voice.speak('Hoye geche Emon Bhai!');
    await _notifications.show(
      1001,
      'ARIFA - Source Ready',
      'Hoye geche Emon Bhai, source zip ready ♥',
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          'ARIFA',
          channelDescription: 'ARIFA build notifications',
          importance: Importance.high,
          priority: Priority.high,
        ),
      ),
    );
    await Share.shareXFiles([
      XFile(result.zipPath),
    ], subject: 'ARIFA generated Flutter project');
  }

  Future<void> _handleWhatsApp(String text) async {
    final clean = text
        .replaceFirst(RegExp(r'.*?(whatsapp|হোয়াটসঅ্যাপ)'), '')
        .trim();
    final contact =
        RegExp(r'(\+?\d[\d\s-]{6,})').firstMatch(clean)?.group(1)?.trim() ??
        clean.split(RegExp(r'\s(to|কে|\|)\s')).first;
    var message = clean.replaceFirst(contact, '').trim();
    if (message.isEmpty) message = 'Ji Emon Bhai, ARIFA থেকে বার্তা ♥';
    final r = await _phone.sendWhatsApp(contact, message);
    _addArifa('WhatsApp খুলে মেসেজ লিখে দিলাম Emon Bhai। $r');
    await _voice.speak('WhatsApp মেসেজ প্রস্তুত Emon Bhai।');
  }

  Future<void> _handleWifi(String text) async {
    final lower = text.toLowerCase();
    bool? enable;
    if (lower.contains('off') || lower.contains('বন্ধ')) {
      enable = false;
    } else if (lower.contains('on') || lower.contains('চালু')) {
      enable = true;
    }
    final r = await _phone.toggleWifi(enable: enable);
    _addArifa(
      'WiFi ${enable == false ? 'বন্ধ' : 'চালু'} করার চেষ্টা করছি Emon Bhai। $r',
    );
    await _voice.speak('WiFi সেটিংসে নিয়ে যাচ্ছি Emon Bhai।');
  }

  Future<void> _handleCall(String text) async {
    final number =
        RegExp(r'(\+?\d[\d\s-]{6,})').firstMatch(text)?.group(1) ?? '';
    if (number.isEmpty) {
      _addArifa('কোন নম্বর বলো Emon Bhai, যেমন: "Arifa call 01712345678"।');
      await _voice.speak('নম্বর বলো Emon Bhai।');
      return;
    }
    final r = await _phone.dial(number);
    _addArifa('নম্বর ডায়াল করছি Emon Bhai। $r');
    await _voice.speak('ডায়াল করছি Emon Bhai।');
  }

  Future<void> _handleSong(String text) async {
    final query = text
        .replaceFirst(RegExp(r'.*?(play|গান|song|মিউজিক|music)'), '')
        .trim();
    final r = await _phone.playSong(query.isEmpty ? 'Bangla hits' : query);
    _addArifa('গান চালিয়ে দিচ্ছি Emon Bhai। $r');
    await _voice.speak('গান চালিয়ে দিলাম Emon Bhai।');
  }

  Future<void> _handleOpen(String text) async {
    final target = text
        .replaceFirst(RegExp(r'.*?(open|খুল|খোল|launch)\s*'), '')
        .trim();
    if (target.isEmpty) {
      _addArifa('কোন অ্যাপ খুলব Emon Bhai?');
      return;
    }
    final r = await _phone.openApp(target);
    _addArifa('$target খুলে দিচ্ছি Emon Bhai। $r');
    await _voice.speak('$target খুলে দিলাম Emon Bhai।');
  }

  Future<void> _toggleListening() async {
    if (_listening) {
      await _voice.stopListening();
      if (mounted) setState(() => _listening = false);
      _setMood(AvatarMood.happy, 'Jekhoni "Arifa" bolben ♥');
      return;
    }
    _setMood(AvatarMood.listening, 'Ji Emon Bhai ♥');
    await _voice.speak('হ্যাঁ Emon Bhai, বলুন?');
    final ok = await _voice.startListening(
      onResult: (text, finalResult) {
        if (!finalResult) return;
        _voice.stopListening();
        if (mounted) setState(() => _listening = false);
        _handleCommand(text);
      },
    );
    if (mounted) setState(() => _listening = ok);
    if (!ok) {
      _setMood(
        AvatarMood.error,
        'Sorry Emon Bhai, ami thik kore dicchi',
        autoReset: const Duration(seconds: 3),
      );
    }
  }

  void _send() {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    _handleCommand(text);
  }

  @override
  void dispose() {
    _moodTimer?.cancel();
    _wakeSub?.cancel();
    _speakingSub?.cancel();
    _heardSub?.cancel();
    _waEnabledSub?.cancel();
    _waStatusSub?.cancel();
    _voice.dispose();
    _native.dispose();
    _pulse.dispose();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          LiveBackground(speaking: _speaking, listening: _listening),
          SafeArea(
            child: Column(
              children: [
                _topBar(),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Column(
                    children: [
                      Text(
                        _status,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.cyanAccent,
                          fontSize: 11,
                          letterSpacing: 0.4,
                        ),
                      ),
                      if (_waStatus.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 3),
                          child: Text(
                            _waStatus,
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.greenAccent,
                              fontSize: 10,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const Spacer(),
                ArifaAvatar(
                  mood: _mood,
                  caption: _caption,
                  scale: MediaQuery.of(context).size.width < 360 ? 0.82 : 1,
                ),
                const Spacer(),
                _bottomControls(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _topBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            'ARIFA',
            style: TextStyle(
              fontSize: 30,
              fontWeight: FontWeight.w800,
              letterSpacing: 8,
              color: Colors.white,
              shadows: [
                Shadow(color: Colors.cyanAccent, blurRadius: 20),
                Shadow(color: Colors.blueAccent, blurRadius: 32),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.greenAccent,
              boxShadow: [
                BoxShadow(
                  color: Colors.greenAccent.withOpacity(0.9),
                  blurRadius: 12,
                  spreadRadius: 3,
                ),
              ],
            ),
          ),
          const SizedBox(width: 5),
          const Text(
            'Online',
            style: TextStyle(color: Colors.greenAccent, fontSize: 11),
          ),
          const SizedBox(width: 12),
          GestureDetector(
            onTap: () => _setWhatsAppAutoReply(!_waAutoReply),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: BoxDecoration(
                color: _waAutoReply
                    ? Colors.green.withOpacity(0.12)
                    : Colors.red.withOpacity(0.12),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: (_waAutoReply ? Colors.greenAccent : Colors.redAccent)
                      .withOpacity(0.7),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 14,
                    height: 14,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _waAutoReply
                          ? Colors.greenAccent
                          : Colors.redAccent,
                      boxShadow: [
                        BoxShadow(
                          color:
                              (_waAutoReply
                                      ? Colors.greenAccent
                                      : Colors.redAccent)
                                  .withOpacity(0.85),
                          blurRadius: 12,
                          spreadRadius: 3,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    _waAutoReply ? 'WA Reply ON' : 'WA Reply OFF',
                    style: TextStyle(
                      color: _waAutoReply
                          ? Colors.greenAccent
                          : Colors.redAccent,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _bottomControls() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
      child: Column(
        children: [
          AnimatedBuilder(
            animation: _pulse,
            builder: (context, _) {
              final glow = 0.35 + _pulse.value * (_speaking ? 0.55 : 0.3);
              return GestureDetector(
                onTap: _toggleListening,
                child: Container(
                  width: 84,
                  height: 84,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [
                        Colors.cyanAccent.withOpacity(0.95),
                        const Color(0xFF063A63),
                      ],
                    ),
                    border: Border.all(
                      color: Colors.cyanAccent.withOpacity(0.9),
                      width: 2,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.cyan.withOpacity(glow),
                        blurRadius: 28 + _pulse.value * 22,
                        spreadRadius: 4,
                      ),
                      BoxShadow(
                        color: Colors.blue.withOpacity(glow * 0.6),
                        blurRadius: 50,
                      ),
                    ],
                  ),
                  child: Icon(
                    _listening ? Icons.stop : Icons.mic,
                    size: 36,
                    color: _listening ? Colors.black : Colors.white,
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 22),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _miniAction(
                icon: Icons.chat_bubble_outline,
                label: 'Chat',
                onPressed: _openChat,
              ),
              _miniAction(
                icon: Icons.android,
                label: 'Build APK',
                onPressed: () => _handleCommand('Arifa calculator APK banaw'),
              ),
              _miniAction(
                icon: Icons.settings_outlined,
                label: 'Settings',
                onPressed: _openSettings,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _miniAction({
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
  }) {
    return GestureDetector(
      onTap: onPressed,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 54,
            height: 54,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0x99102846),
              border: Border.all(color: Colors.cyanAccent.withOpacity(0.55)),
              boxShadow: [
                BoxShadow(color: Colors.cyan.withOpacity(0.22), blurRadius: 14),
              ],
            ),
            child: Icon(icon, color: Colors.cyanAccent, size: 23),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            style: const TextStyle(color: Colors.white70, fontSize: 11),
          ),
        ],
      ),
    );
  }

  void _openChat() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xF4040D18),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: SizedBox(
          height: MediaQuery.of(ctx).size.height * 0.86,
          child: Column(
            children: [
              Row(
                children: [
                  const Padding(
                    padding: EdgeInsets.all(14),
                    child: Text(
                      'Chat with ARIFA',
                      style: TextStyle(
                        color: Colors.cyanAccent,
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white70),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              SizedBox(
                height: 54,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  children: [
                    _quickChip('Screen Vision', 'Arifa screen dekho'),
                    _quickChip('Permissions', 'Arifa settings'),
                    _quickChip('WiFi on', 'Arifa wifi on'),
                    _quickChip('Play song', 'Arifa play Bangla hits'),
                    _quickChip('Open app', 'Arifa open YouTube'),
                    _quickChip(
                      _waAutoReply ? 'WA Reply OFF' : 'WA Reply ON',
                      'Arifa WhatsApp auto reply ${_waAutoReply ? 'OFF' : 'ON'} koro',
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  itemCount: _messages.length,
                  itemBuilder: (context, i) => _messageBubble(_messages[i]),
                ),
              ),
              _chatInput(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _quickChip(String label, String command) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: ActionChip(
        label: Text(
          label,
          style: const TextStyle(color: Colors.cyanAccent, fontSize: 11),
        ),
        backgroundColor: const Color(0xFF0A2036),
        onPressed: () => _handleCommand(command),
      ),
    );
  }

  Widget _chatInput() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      decoration: BoxDecoration(
        color: const Color(0xFF060D18),
        border: Border(
          top: BorderSide(color: Colors.cyanAccent.withOpacity(0.16)),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _input,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'Emon Bhai, কী বলবেন?',
                hintStyle: const TextStyle(color: Colors.white38),
                filled: true,
                fillColor: const Color(0xFF0A1626),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(26),
                  borderSide: BorderSide.none,
                ),
              ),
              onSubmitted: (_) => _send(),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            onPressed: _busy ? null : _send,
            icon: const Icon(Icons.send, color: Colors.cyanAccent),
          ),
        ],
      ),
    );
  }

  Widget _messageBubble(ChatMessage m) {
    final isUser = m.speaker == Speaker.user;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.82,
        ),
        decoration: BoxDecoration(
          color: isUser ? const Color(0xFF0B3A5C) : const Color(0xFF08182A),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.cyanAccent.withOpacity(0.22)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              m.text,
              style: const TextStyle(color: Colors.white, fontSize: 13.5),
            ),
            for (final c in m.code) ...[
              const SizedBox(height: 8),
              _codeCard(c),
            ],
          ],
        ),
      ),
    );
  }

  Widget _codeCard(CodeBlock code) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0xFF020A12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.cyanAccent.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Padding(
                padding: const EdgeInsets.all(6),
                child: Text(
                  code.path,
                  style: const TextStyle(
                    color: Colors.cyanAccent,
                    fontSize: 10,
                  ),
                ),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: code.content));
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('${code.path} copy হয়েছে Emon Bhai!'),
                      ),
                    );
                  }
                },
                icon: const Icon(Icons.copy, size: 12),
                label: const Text('Copy', style: TextStyle(fontSize: 11)),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: Text(
              code.content.length > 600
                  ? '${code.content.substring(0, 600)}\n... (Copy করলে পুরো কোড পাবে)'
                  : code.content,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 10,
                color: Color(0xFFB9E8FF),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
