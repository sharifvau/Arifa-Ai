import 'dart:async';

import 'package:flutter/material.dart';

import 'arifa_avatar.dart';
import 'arifa_brain.dart';
import 'settings_service.dart';

// Temporarily disabled for the FIRST GREEN BUILD. Nothing is deleted —
// full sources are intact in lib/ and under backup/full_features/lib/.
// import 'package:path_provider/path_provider.dart';
// import 'apk_builder.dart';          // source-zip / APK builder (needs path_provider)
// import 'auto_reply_service.dart';   // WhatsApp auto reply
// import 'background_service.dart';   // native wake channel
// import 'live_background.dart';      // animated galaxy background
// import 'models.dart';
// import 'phone_control.dart';        // phone / SMS / WiFi
// import 'screen_service.dart';       // screen vision
// import 'settings_screen.dart';      // full settings (needs path_provider)
// import 'voice_service.dart';        // TTS / STT

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await SettingsService.instance.init();
  } catch (_) {
    // Secure-storage failure must not block the UI.
  }
  runApp(const ArifaApp());
}

class ArifaApp extends StatelessWidget {
  const ArifaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ARIFA',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: const ArifaHome(),
    );
  }
}

class _ChatLine {
  final bool mine;
  final String text;
  const _ChatLine(this.mine, this.text);
}

class ArifaHome extends StatefulWidget {
  const ArifaHome({super.key});

  @override
  State<ArifaHome> createState() => _ArifaHomeState();
}

class _ArifaHomeState extends State<ArifaHome> {
  final ArifaBrain _brain = ArifaBrain();
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final List<_ChatLine> _lines = <_ChatLine>[];

  AvatarMood _mood = AvatarMood.happy;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (SettingsService.instance.needsSetup) {
      unawaited(_showSetupHint());
    }
  }

  Future<void> _showSetupHint() async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF06182B),
        title: const Text(
          'Emon Bhai, Settings e giye API Key din',
          style: TextStyle(color: Colors.cyanAccent, fontSize: 16),
        ),
        content: const Text(
          'Settings > AI Brain-এ গিয়ে নিজের API Key আর Model ID দিন।',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _add(String text, {required bool mine}) {
    if (!mounted) return;
    setState(() => _lines.add(_ChatLine(mine, text)));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _busy) return;
    _input.clear();
    _add(text, mine: true);
    setState(() {
      _busy = true;
      _mood = AvatarMood.thinking;
    });
    try {
      final reply = await _brain.ask(text);
      if (!mounted) return;
      _add(reply.text.isEmpty ? '...' : reply.text, mine: false);
    } catch (e) {
      if (!mounted) return;
      _add('এখনো সেটাপ হয়নি Emon Bhai — Settings-এ Key ও Model ID দিন।', mine: false);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _mood = AvatarMood.happy;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF030D18),
      appBar: AppBar(
        title: const Text('ARIFA'),
        backgroundColor: const Color(0xFF06182B),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const _MinimalSettingsPage(),
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            SizedBox(
              height: 150,
              child: ArifaAvatar(mood: _mood, scale: 0.8),
            ),
            Expanded(
              child: ListView.builder(
                controller: _scroll,
                padding: const EdgeInsets.all(12),
                itemCount: _lines.length,
                itemBuilder: (context, i) {
                  final line = _lines[i];
                  return Align(
                    alignment:
                        line.mine ? Alignment.centerRight : Alignment.centerLeft,
                    child: Container(
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: line.mine
                            ? const Color(0xFF123A52)
                            : const Color(0xFF0C2438),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        line.text,
                        style: const TextStyle(color: Colors.white, fontSize: 13),
                      ),
                    ),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(10),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(
                        hintText: 'Emon Bhai, message লিখুন...',
                        hintStyle: TextStyle(color: Colors.white24),
                      ),
                      onSubmitted: (_) => unawaited(_send()),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _busy ? null : () => unawaited(_send()),
                    child: const Text('Send'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Minimal settings page: only the API keys / Model ID needed for chat.
class _MinimalSettingsPage extends StatefulWidget {
  const _MinimalSettingsPage();

  @override
  State<_MinimalSettingsPage> createState() => _MinimalSettingsPageState();
}

class _MinimalSettingsPageState extends State<_MinimalSettingsPage> {
  final TextEditingController _gemini = TextEditingController();
  final TextEditingController _router = TextEditingController();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final s = SettingsService.instance;
    _gemini.text = s.geminiKey;
    _router.text = s.openRouterKey;
  }

  @override
  void dispose() {
    _gemini.dispose();
    _router.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final s = SettingsService.instance;
      await s.saveAll(
        gemini: _gemini.text,
        openRouter: _router.text,
        selectedVoice: s.voice,
        selectedWake: s.wakeEnabled,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Settings save hoye geche Emon Bhai ♥')),
        );
        Navigator.pop(context);
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Save fail — abar try korun Emon Bhai')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _gemini,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Gemini API Key'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _router,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'OpenRouter API Key'),
            ),
            const SizedBox(height: 8),
            const Text(
              'Model ID: Settings > AI Brain-এ অ্যাড করুন (full version-এ আছে)।',
              style: TextStyle(color: Colors.white38, fontSize: 11),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _saving ? null : () => unawaited(_save()),
              child: Text(_saving ? 'Saving...' : 'Save'),
            ),
          ],
        ),
      ),
    );
  }
}
