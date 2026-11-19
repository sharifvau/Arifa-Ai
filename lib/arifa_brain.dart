import 'dart:convert';

import 'package:http/http.dart' as http;

import 'config.dart';
import 'model_entry.dart';
import 'models.dart';
import 'settings_service.dart';

class BrainReply {
  final String text;
  final List<CodeBlock> code;
  final BrainTask task;
  final String modelUsed;

  const BrainReply({
    required this.text,
    required this.code,
    required this.task,
    required this.modelUsed,
  });
}

class BrainException implements Exception {
  final String message;

  /// HTTP status when the failure came from a provider, for actionable UI text.
  final int? statusCode;

  /// Auth failures (401/403) must stop failover — retrying other models with
  /// the same bad key cannot help and only wastes the user's quota/time.
  final bool authFailure;

  BrainException(this.message, {this.statusCode, this.authFailure = false});

  @override
  String toString() => message;
}

/// Multi-model router. The model list, default and keys all come from
/// SettingsService at call time. There is no model version in this file.
class ArifaBrain {
  ArifaBrain({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;
  final SettingsService _settings = SettingsService.instance;

  /// A single user command must never try an unbounded number of catalog rows.
  static const int maxFailoverModels = 3;
  static const Duration failoverDeadline = Duration(seconds: 25);
  static const Duration perCallTimeout = Duration(seconds: 90);

  static const String persona = '''
তুমি ARIFA — একজন কিউট, বন্ধুত্বপূর্ণ বাংলাদেশী মেয়ে AI অ্যাসিস্ট্যান্ট।
তোমার মালিকের নাম "Emon Bhai"। তাকে সবসময় "Emon Bhai" বলে ডাকবে।
স্বর: মিষ্টি, আদরের, কাছের বন্ধুর মতো, কিন্তু পেশাদার ও সম্মানজনক।
ভাষা: বাংলা (Bangla)। শুধু কোড, কমান্ড বা প্রযুক্তিগত শব্দ ইংরেজিতে রাখবে।
কথা ছোট রাখবে — কারণ তুমি কথা বলছ, ভয়েসে। একবারে ২-৩ বাক্যের বেশি নয়।
কখনো নিজেকে কোনো বাইরের মডেলের নাম বলে পরিচয় দিও না — তুমি ARIFA।
যখন কোড দিও, markdown code fence-এ দিও এবং ফাইলের নাম লিখে দিও।
কখনো "আমি পারব না" বলে কথা শেষ করো না — বিকল্প পথ বাতলে দিও।
''';

  BrainTask classify(String input) {
    final t = input.toLowerCase();
    // Coding first: "fix this Dart error" must not be mistaken for a request
    // to analyse the screen. Screen capture passes forcedTask: vision anyway
    // (lib/screen_service.dart:52), so vision needs only explicit phrases.
    if (RegExp(
      r'apk|build|code|কোড|flutter|dart|app|বানা|banaw|banao|fix|bug|error|compile|project',
    ).hasMatch(t)) {
      return BrainTask.coding;
    }
    if (RegExp(r'screen|স্ক্রিন|dekho|দেখ|screenshot|স্ক্রিনশট').hasMatch(t)) {
      return BrainTask.vision;
    }
    if (RegExp(
      r'plan|planning|think|vision|long|depth|গভীর|বিশ্লেষ|strateg|roadmap|compare',
    ).hasMatch(t)) {
      return BrainTask.deep;
    }
    return BrainTask.chat;
  }

  Future<BrainReply> ask(
    String input, {
    BrainTask? forcedTask,
    List<ChatMessage> history = const [],
    String? imageBase64,
  }) async {
    final task = forcedTask ?? classify(input);
    final models = _modelsFor(task);
    final errors = <String>[];
    final deadline = DateTime.now().add(failoverDeadline);

    for (final model in models.take(maxFailoverModels)) {
      final timeout = _remainingTimeout(deadline);
      if (timeout <= Duration.zero) break;
      try {
        final text = await _call(
          model: model,
          messages: _buildMessages(input, history, task),
          imageBase64: imageBase64,
          jsonMode: false,
          maxTokens: task == BrainTask.vision ? 900 : 700,
          timeout: timeout,
        );
        return BrainReply(
          text: stripCodeBlocks(text).trim(),
          code: extractCodeBlocks(text),
          task: task,
          modelUsed: model.name,
        );
      } catch (e) {
        if (e is BrainException && e.authFailure) break;
        _addError(errors, '${model.name}: ${_short(e.toString())}');
      }
    }
    throw BrainException(
      'সব মডেল fail করেছে Emon Bhai। ${errors.join(' | ')}',
    );
  }

  /// Fast reply composer for WhatsApp Auto Reply. Only called when the user
  /// explicitly enables "Use AI brain" in Settings, because the incoming
  /// message text is sent to their configured provider. Time-boxed to ~1.1s
  /// so a slow model never blocks the human-like local reply fallback.
  Future<String> autoReply({
    required String incomingMessage,
    required String contact,
    List<String> styleSamples = const [],
  }) async {
    final samples = styleSamples.take(6).join('\n');
    final system =
        '''
তুমি Emon Bhai — একজন সাধারণ বাংলাদেশী ছেলে। তোমার বন্ধুর WhatsApp মেসেজের
উত্তর লিখবে। Robot-এর মতো কথা বলবে না, ARIFA বা কোনো AI-র নাম বলবে না।
ভাষা: Bangla + English মিক্স, ছোট এক লাইন, অনানুষ্ঠানিক, বন্ধুর সুর।
সময়: ১-২ সেকেন্ডের মতো দ্রুত উত্তর। মাঝে মাঝে একটা emoji দিও, সবসময় নয়।
কাজ/কোড/APK নিয়ে প্রশ্ন হলে বলবে: "Emon Bhai ektu busy ache, pore kotha bolbe, tumi ki bolte chao amake bolo ami pouche dibo"।
শুধু reply টেক্সট দিও, কোনো ব্যাখ্যা বা quotation নয়।

${samples.isEmpty ? '' : 'আমার আগের কথার স্টাইল (অনুকরণ করো):\n$samples'}
''';

    final usable =
        _settings.defaultModel != null &&
            _settings.defaultModel!.id.trim().isNotEmpty &&
            _settings.hasKeyFor(_settings.defaultModel!.provider)
        ? <ModelEntry>[_settings.defaultModel!]
        : _settings.models
              .where(
                (m) =>
                    m.id.trim().isNotEmpty && _settings.hasKeyFor(m.provider),
              )
              .take(1)
              .toList();

    if (usable.isEmpty) {
      throw BrainException('দ্রুত Reply-র জন্য কোনো মডেল সেট করা নেই');
    }

    final text = await _call(
      model: usable.first,
      messages: [
        {'role': 'system', 'content': system},
        {
          'role': 'user',
          'content':
              'Contact: $contact\nIncoming message: $incomingMessage\n\nReply:',
        },
      ],
      jsonMode: false,
      maxTokens: 100,
      timeout: const Duration(seconds: 1),
    ).timeout(const Duration(milliseconds: 700));

    final clean = stripCodeBlocks(text).trim().replaceAll(RegExp(r'\s+'), ' ');
    if (clean.isEmpty) throw BrainException('empty fast reply');
    return clean.length > 220 ? clean.substring(0, 220) : clean;
  }

  Future<GeneratedApp> generateApp(
    String request, {
    GeneratedApp? previous,
    String? errorLog,
  }) async {
    final repair = errorLog != null && errorLog.trim().isNotEmpty;
    final buf = StringBuffer();
    buf.writeln('User request (Bangla/English): $request');
    if (repair) {
      buf.writeln('BUILD / REVIEW ERROR TO FIX:');
      buf.writeln(errorLog);
    }
    if (previous != null) {
      buf.writeln('CURRENT FILES (return ALL of them, corrected):');
      for (final f in previous.files) {
        buf.writeln('--- ${f.path} ---');
        buf.writeln(_trimForPrompt(f.content));
      }
    } else {
      buf.writeln('Create a NEW minimal, dependency-light Flutter app.');
    }
    buf.writeln(
      '''
Return STRICT JSON only, no markdown:
{"name":"snake_case_project","summary":"one Bangla line","files":[{"path":"pubspec.yaml","content":"..."},{"path":"lib/main.dart","content":"..."}, ...]}
Rules:
- Always include pubspec.yaml and lib/main.dart.
- Use only flutter, dart:*, http if truly needed. No other packages.
- Code must compile on latest Flutter 3.x / Dart 3.x with Material 3.
- No network calls at startup. No unused imports. No `const` with non-const values.
'''
          .trim(),
    );

    final messages = [
      {'role': 'system', 'content': persona},
      {
        'role': 'user',
        'content':
            'You are a senior Flutter engineer. Produce a complete working app.\n${buf.toString()}',
      },
    ];

    final errors = <String>[];
    final deadline = DateTime.now().add(failoverDeadline);
    for (final model in _modelsFor(BrainTask.coding).take(maxFailoverModels)) {
      final timeout = _remainingTimeout(deadline);
      if (timeout <= Duration.zero) break;
      try {
        final text = await _call(
          model: model,
          messages: messages,
          jsonMode: true,
          maxTokens: 16000,
          timeout: timeout,
        );
        final app = _parseAppJson(text);
        if (app.files.isNotEmpty) return _normalizeApp(app);
        throw BrainException('empty file list');
      } catch (e) {
        if (e is BrainException && e.authFailure) break;
        _addError(errors, '${model.name}: ${_short(e.toString())}');
      }
    }
    throw BrainException('কোড জেনারেট fail: ${errors.join(' | ')}');
  }

  /// AI code review used by the on-device source builder.
  Future<String> reviewApp(GeneratedApp app) async {
    final buf = StringBuffer();
    for (final f in app.files) {
      buf.writeln('--- ${f.path} ---');
      buf.writeln(_trimForPrompt(f.content, limit: 6000));
    }
    final reply = await ask(
      'এই Flutter প্রজেক্টের কোড রিভিউ করো। compile error, unused import, '
      'const-এর ভুল ব্যবহার বা বড় সমস্যা থাকলে শুধু সমস্যাগুলো bullets-এ লিখো। '
      'সমস্যা না থাকলে শুধু "OK" লিখো।\n\n$buf',
      forcedTask: BrainTask.coding,
    );
    return reply.text.trim();
  }

  Future<GeneratedApp> fixFromScreen({
    required String screenDescription,
    required String errorLog,
    required GeneratedApp app,
  }) async {
    return generateApp(
      'Fix the error visible on screen and rebuild the same app. '
      'Screen: $screenDescription',
      previous: app,
      errorLog: errorLog,
    );
  }

  /// Default model first, then vision-capable rows when an image is attached,
  /// then every other usable row. Order comes entirely from the saved catalog.
  List<ModelEntry> _modelsFor(BrainTask task) {
    final usable = _settings.models
        .where((m) => m.id.trim().isNotEmpty && _settings.hasKeyFor(m.provider))
        .toList();

    if (usable.isEmpty) {
      // An empty ID and a missing key need different fixes — say which one.
      final all = _settings.models;
      final missingId = all.where((m) => m.id.trim().isEmpty).length;
      final missingKey = all.where((m) => !_settings.hasKeyFor(m.provider)).length;
      String hint() {
        if (all.isNotEmpty && missingId == all.length) {
          return 'Settings > AI Brain / Model Manager-এ গিয়ে Fetch Latest Models '
              'দিয়ে একটা মডেল অ্যাড করে Default সেট করো, অথবা নিজের Model ID '
              'লিখে Add & Use Now চাপো।';
        }
        if (missingId > 0 && missingKey > 0) {
          return 'কিছু মডেলে Model ID নেই, আবার কিছুতে API Key নেই — Settings-এ '
              'দুটোই পূরণ করে Default সেট করো Emon Bhai।';
        }
        if (missingId > 0) {
          return 'এই মডেলগুলোর Model ID খালি Emon Bhai — Settings-এ ID সেট করো।';
        }
        return 'এই মডেলগুলোর জন্য API Key নেই Emon Bhai — Settings-এ নিজের Key '
            'বসাও।';
      }

      throw BrainException('এখনো কোনো মডেল ব্যবহারযোগ্য নেই Emon Bhai। ${hint()}');
    }

    final ordered = <ModelEntry>[];
    final seen = <String>{};

    void add(ModelEntry m) {
      if (seen.add(m.key)) ordered.add(m);
    }

    final defaultModel = _settings.defaultModel;
    if (defaultModel != null &&
        defaultModel.id.trim().isNotEmpty &&
        _settings.hasKeyFor(defaultModel.provider)) {
      add(defaultModel);
    }

    if (task == BrainTask.vision) {
      for (final m in usable) {
        if (m.supportsVision) add(m);
      }
    }

    for (final m in usable) {
      add(m);
    }

    return ordered;
  }

  List<Map<String, String>> _buildMessages(
    String input,
    List<ChatMessage> history,
    BrainTask task,
  ) {
    final messages = <Map<String, String>>[
      {'role': 'system', 'content': persona},
    ];
    for (final h in _takeLast(history, 10)) {
      messages.add({
        'role': h.speaker == Speaker.user ? 'user' : 'assistant',
        'content': h.text,
      });
    }
    final prompt = task == BrainTask.vision
        ? 'স্ক্রিনে কী আছে বাংলায় বলো, সমস্যা থাকলে error টি উদ্ধৃত করো।\n\n$input'
        : input;
    messages.add({'role': 'user', 'content': prompt});
    return messages;
  }

  Future<String> _call({
    required ModelEntry model,
    required List<Map<String, String>> messages,
    String? imageBase64,
    required bool jsonMode,
    required int maxTokens,
    Duration timeout = perCallTimeout,
  }) async {
    final id = model.id.trim();
    if (id.isEmpty) {
      throw BrainException(
        '${model.name}-এর Model ID খালি Emon Bhai — Settings-এ গিয়ে ID সেট করো।',
      );
    }
    if (model.provider == ModelProvider.gemini) {
      return _callGemini(
        model: id,
        messages: messages,
        imageBase64: imageBase64,
        jsonMode: jsonMode,
        maxTokens: maxTokens,
        timeout: timeout,
      );
    }
    return _callOpenRouter(
      model: id,
      messages: messages,
      imageBase64: imageBase64,
      jsonMode: jsonMode,
      maxTokens: maxTokens,
      timeout: timeout,
    );
  }

  Future<String> _callOpenRouter({
    required String model,
    required List<Map<String, String>> messages,
    String? imageBase64,
    required bool jsonMode,
    required int maxTokens,
    Duration timeout = perCallTimeout,
  }) async {
    final key = _settings.openRouterKey;
    if (key.isEmpty) throw BrainException('OpenRouter key নেই');

    final body = <String, dynamic>{
      'model': model,
      'messages': _openRouterMessages(messages, imageBase64),
      'max_tokens': maxTokens,
      'temperature': jsonMode ? 0.1 : 0.7,
    };

    final res = await _client
        .post(
          Uri.parse(ArifaConstants.openRouterEndpoint),
          headers: {
            'Authorization': 'Bearer $key',
            'Content-Type': 'application/json',
            'HTTP-Referer': 'https://arifa.local/app',
            'X-Title': 'ARIFA for Emon Bhai',
          },
          body: jsonEncode(body),
        )
        .timeout(timeout, onTimeout: () {
      throw _timeout('OpenRouter', timeout);
    });

    if (res.statusCode >= 400) throw _httpFailure('OpenRouter', res);

    final decoded = jsonDecode(res.body);
    if (decoded is! Map) throw BrainException('OR unreadable response');
    final choices = decoded['choices'];
    if (choices is! List || choices.isEmpty) {
      throw BrainException('OR empty choices');
    }
    final first = choices.first;
    if (first is! Map) throw BrainException('OR unreadable choice');
    final msg = first['message'];
    if (msg is! Map) throw BrainException('OR unreadable message');
    final content = msg['content'];
    if (content is String) return content;
    if (content is List) {
      final parts = content
          .map((e) => (e is Map ? e['text'] : null)?.toString() ?? '')
          .where((s) => s.isNotEmpty)
          .join('\n');
      if (parts.isNotEmpty) return parts;
    }
    throw BrainException('OR unreadable content');
  }

  List<Map<String, dynamic>> _openRouterMessages(
    List<Map<String, String>> messages,
    String? imageBase64,
  ) {
    final out = <Map<String, dynamic>>[];
    for (final m in messages) {
      out.add({'role': m['role'], 'content': m['content']});
    }
    if (imageBase64 != null && out.isNotEmpty) {
      final last = out.last;
      last['content'] = [
        {'type': 'text', 'text': last['content'] as String},
        {
          'type': 'image_url',
          'image_url': {'url': 'data:image/jpeg;base64,$imageBase64'},
        },
      ];
    }
    return out;
  }

  Future<String> _callGemini({
    required String model,
    required List<Map<String, String>> messages,
    String? imageBase64,
    required bool jsonMode,
    required int maxTokens,
    Duration timeout = perCallTimeout,
  }) async {
    final key = _settings.geminiKey;
    if (key.isEmpty) throw BrainException('Gemini key নেই');

    // Accept both "gemini-..." and "models/gemini-..." custom IDs.
    final cleanModel = model.replaceFirst(RegExp(r'^models/'), '');

    final system = messages
        .where((m) => m['role'] == 'system')
        .map((m) => m['content'])
        .join('\n');
    final chat = messages.where((m) => m['role'] != 'system').toList();
    final contents = <Map<String, dynamic>>[];

    for (final m in chat) {
      final parts = <Map<String, dynamic>>[
        {'text': m['content']},
      ];
      if (m['role'] == 'user' && imageBase64 != null && m == chat.last) {
        parts.add({
          'inline_data': {'mime_type': 'image/jpeg', 'data': imageBase64},
        });
      }
      contents.add({
        'role': m['role'] == 'assistant' ? 'model' : 'user',
        'parts': parts,
      });
    }

    final body = <String, dynamic>{
      'system_instruction': {
        'parts': [
          {'text': system},
        ],
      },
      'contents': contents,
      'generationConfig': {
        'temperature': jsonMode ? 0.1 : 0.7,
        'maxOutputTokens': maxTokens,
        if (jsonMode) 'responseMimeType': 'application/json',
      },
    };

    final res = await _client
        .post(
          Uri.parse(
            '${ArifaConstants.geminiEndpoint}/'
            '${Uri.encodeComponent(cleanModel)}:generateContent',
          ),
          // Key goes in the header so it never lands in a URL or access log.
          headers: {
            'Content-Type': 'application/json',
            'x-goog-api-key': key,
          },
          body: jsonEncode(body),
        )
        .timeout(timeout, onTimeout: () {
      throw _timeout('Gemini', timeout);
    });

    if (res.statusCode >= 400) throw _httpFailure('Gemini', res);

    final decoded = jsonDecode(res.body);
    if (decoded is! Map) throw BrainException('Gemini unreadable response');
    final candidates = decoded['candidates'];
    if (candidates is! List || candidates.isEmpty) {
      throw BrainException('Gemini empty: ${_short(res.body)}');
    }
    final first = candidates.first;
    if (first is! Map) throw BrainException('Gemini unreadable candidate');
    final content = first['content'];
    if (content is! Map) throw BrainException('Gemini unreadable content');
    final parts = content['parts'];
    if (parts is! List) throw BrainException('Gemini unreadable parts');
    final text = parts
        .map((p) => (p is Map ? p['text'] : null)?.toString() ?? '')
        .where((s) => s.isNotEmpty)
        .join('\n');
    if (text.isEmpty) throw BrainException('Gemini empty content');
    return text;
  }

  GeneratedApp _parseAppJson(String raw) {
    var s = raw.trim();
    if (s.startsWith('```')) {
      s = s.replaceFirst(RegExp(r'^```[a-zA-Z0-9]*\s*'), '');
      s = s.replaceFirst(RegExp(r'```\s*$'), '');
    }
    final start = s.indexOf('{');
    final end = s.lastIndexOf('}');
    if (start >= 0 && end > start) s = s.substring(start, end + 1);
    return GeneratedApp.fromJsonMap(jsonDecode(s) as Map<String, dynamic>);
  }

  GeneratedApp _normalizeApp(GeneratedApp app) {
    final files = <CodeBlock>[...app.files];
    bool has(String p) => files.any((f) => f.path == p);

    if (!has('pubspec.yaml')) {
      final safeName = app.name.replaceAll(RegExp(r'[^a-z0-9_]'), '_');
      final name = safeName.isEmpty ? 'generated_app' : safeName;
      files.insert(
        0,
        CodeBlock(
          path: 'pubspec.yaml',
          language: 'yaml',
          content: '''name: $name
description: "Generated by ARIFA"
publish_to: "none"
version: 1.0.0+1
environment:
  sdk: ">=3.4.0 <4.0.0"
dependencies:
  flutter:
    sdk: flutter
flutter:
  uses-material-design: true
''',
        ),
      );
    }
    if (!has('lib/main.dart')) {
      files.add(
        const CodeBlock(
          path: 'lib/main.dart',
          language: 'dart',
          content: '''import 'package:flutter/material.dart';
void main() => runApp(const GeneratedApp());
class GeneratedApp extends StatelessWidget {
  const GeneratedApp({super.key});
  @override
  Widget build(BuildContext context) => const MaterialApp(
    home: Scaffold(body: Center(child: Text('ARIFA generated app'))),
  );
}
''',
        ),
      );
    }
    return GeneratedApp(name: app.name, summary: app.summary, files: files);
  }

  List<CodeBlock> extractCodeBlocks(String text) {
    final blocks = <CodeBlock>[];
    final re = RegExp(r'```([a-zA-Z0-9_]+)?[ \t]*([^\n`]*)\n([\s\S]*?)```');
    for (final m in re.allMatches(text)) {
      final lang = m.group(1) ?? 'text';
      var path = (m.group(2) ?? '').trim();
      if (path.isEmpty) {
        path = lang == 'yaml' ? 'pubspec.yaml' : 'snippet.${_ext(lang)}';
      }
      blocks.add(
        CodeBlock(path: path, language: lang, content: m.group(3) ?? ''),
      );
    }
    return blocks;
  }

  String stripCodeBlocks(String text) =>
      text.replaceAll(RegExp(r'```[\s\S]*?```'), '').trim();

  String _trimForPrompt(String text, {int limit = 12000}) => text.length > limit
      ? '${text.substring(0, limit)}\n...[truncated]'
      : text;

  String _ext(String lang) {
    switch (lang) {
      case 'dart':
        return 'dart';
      case 'yaml':
      case 'yml':
        return 'yaml';
      case 'kotlin':
      case 'kt':
        return 'kt';
      case 'python':
      case 'py':
        return 'py';
      case 'json':
        return 'json';
      default:
        return 'txt';
    }
  }

  /// Time left for the whole failover chain, clamped to one call's ceiling.
  Duration _remainingTimeout(DateTime deadline) {
    final left = deadline.difference(DateTime.now());
    if (left <= Duration.zero) return Duration.zero;
    return left > perCallTimeout ? perCallTimeout : left;
  }

  /// Keeps at most 3 distinct, short errors so the primary cause stays visible
  /// even after a user imports a very large catalog (M10).
  void _addError(List<String> errors, String error) {
    if (error.isEmpty || errors.contains(error) || errors.length >= 3) return;
    errors.add(error);
  }

  /// Status-specific, actionable Bangla messages instead of raw bodies (M9).
  BrainException _httpFailure(String provider, http.Response res) {
    final code = res.statusCode;
    final String detail;
    final bool auth;
    if (code == 401 || code == 403) {
      detail = 'API Key invalid বা expired — Settings-এ Key আপডেট করো';
      auth = true;
    } else if (code == 404) {
      detail = 'Model ID ভুল — Settings-এ Model ID ঠিক করো';
      auth = false;
    } else if (code == 429) {
      detail = 'rate limit হয়েছে — একটু পরে আবার চেষ্টা করো';
      auth = false;
    } else {
      detail = _short(res.body);
      auth = false;
    }
    return BrainException(
      '$provider HTTP $code: $detail',
      statusCode: code,
      authFailure: auth,
    );
  }

  BrainException _timeout(String provider, Duration d) => BrainException(
    '$provider ${d.inSeconds}s-এ উত্তর দিলো না Emon Bhai — আবার চেষ্টা করো।',
  );

  String _short(String s) {
    final flat = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return flat.length > 240 ? '${flat.substring(0, 240)}...' : flat;
  }

  List<T> _takeLast<T>(List<T> list, int n) =>
      list.length <= n ? list : list.sublist(list.length - n);
}
