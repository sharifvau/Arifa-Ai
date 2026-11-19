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
  BrainException(this.message);

  @override
  String toString() => message;
}

/// Multi-model router. The model list, default and keys all come from
/// SettingsService at call time. There is no model version in this file.
class ArifaBrain {
  ArifaBrain({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;
  final SettingsService _settings = SettingsService.instance;

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
    if (RegExp(r'screen|স্ক্রিন|dekho|দেখ|screenshot|ভুল|error|fix|ঠিক')
        .hasMatch(t)) {
      return BrainTask.vision;
    }
    if (RegExp(
            r'apk|build|code|কোড|flutter|dart|app|বানা|banaw|banao|fix|bug|error|compile|project')
        .hasMatch(t)) {
      return BrainTask.coding;
    }
    if (RegExp(
            r'plan|planning|think|vision|long|depth|গভীর|বিশ্লেষ|strateg|roadmap|compare')
        .hasMatch(t)) {
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

    for (final model in models) {
      try {
        final text = await _call(
          model: model,
          messages: _buildMessages(input, history, task),
          imageBase64: imageBase64,
          jsonMode: false,
          maxTokens: task == BrainTask.vision ? 900 : 700,
        );
        return BrainReply(
          text: stripCodeBlocks(text).trim(),
          code: extractCodeBlocks(text),
          task: task,
          modelUsed: model.name,
        );
      } catch (e) {
        errors.add('${model.name}: ${_short(e.toString())}');
      }
    }
    throw BrainException(
      'সব মডেল fail করেছে Emon Bhai। ${errors.join(' | ')}',
    );
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
    buf.writeln('''
Return STRICT JSON only, no markdown:
{"name":"snake_case_project","summary":"one Bangla line","files":[{"path":"pubspec.yaml","content":"..."},{"path":"lib/main.dart","content":"..."}, ...]}
Rules:
- Always include pubspec.yaml and lib/main.dart.
- Use only flutter, dart:*, http if truly needed. No other packages.
- Code must compile on latest Flutter 3.x / Dart 3.x with Material 3.
- No network calls at startup. No unused imports. No `const` with non-const values.
'''.trim());

    final messages = [
      {'role': 'system', 'content': persona},
      {
        'role': 'user',
        'content':
            'You are a senior Flutter engineer. Produce a complete working app.\n${buf.toString()}'
      },
    ];

    final errors = <String>[];
    for (final model in _modelsFor(BrainTask.coding)) {
      try {
        final text = await _call(
          model: model,
          messages: messages,
          jsonMode: true,
          maxTokens: 16000,
        );
        final app = _parseAppJson(text);
        if (app.files.isNotEmpty) return _normalizeApp(app);
        throw BrainException('empty file list');
      } catch (e) {
        errors.add('${model.name}: ${_short(e.toString())}');
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
        .where(
          (m) => m.id.trim().isNotEmpty && _settings.hasKeyFor(m.provider),
        )
        .toList();

    if (usable.isEmpty) {
      throw BrainException(
        'এখনো কোনো মডেল ব্যবহারযোগ্য নেই Emon Bhai। '
        'Settings > AI Brain / Model Manager-এ গিয়ে '
        'Fetch Latest Models দিয়ে একটা মডেল অ্যাড করে Default সেট করো, '
        'অথবা নিজের Model ID লিখে Add & Use Now চাপো।',
      );
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
  }) async {
    final id = model.id.trim();
    if (model.provider == ModelProvider.gemini) {
      return _callGemini(
        model: id,
        messages: messages,
        imageBase64: imageBase64,
        jsonMode: jsonMode,
        maxTokens: maxTokens,
      );
    }
    return _callOpenRouter(
      model: id,
      messages: messages,
      imageBase64: imageBase64,
      jsonMode: jsonMode,
      maxTokens: maxTokens,
    );
  }

  Future<String> _callOpenRouter({
    required String model,
    required List<Map<String, String>> messages,
    String? imageBase64,
    required bool jsonMode,
    required int maxTokens,
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
        .timeout(const Duration(seconds: 90));

    if (res.statusCode >= 400) {
      throw BrainException('OR ${res.statusCode}: ${_short(res.body)}');
    }
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    final choices = j['choices'] as List?;
    if (choices == null || choices.isEmpty) {
      throw BrainException('OR empty choices: ${_short(res.body)}');
    }
    final msg = (choices.first as Map)['message'] as Map?;
    final content = msg?['content'];
    if (content is String) return content;
    if (content is List) {
      return content
          .map((e) => (e is Map ? e['text'] : null)?.toString() ?? '')
          .where((s) => s.isNotEmpty)
          .join('\n');
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
      'system_instruction': {'parts': [{'text': system}]},
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
            '${Uri.encodePathSegment(cleanModel)}:generateContent'
            '?key=${Uri.encodeQueryComponent(key)}',
          ),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 90));

    if (res.statusCode >= 400) {
      throw BrainException('Gemini ${res.statusCode}: ${_short(res.body)}');
    }
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    final candidates = j['candidates'] as List?;
    if (candidates == null || candidates.isEmpty) {
      throw BrainException('Gemini empty: ${_short(res.body)}');
    }
    final parts =
        ((candidates.first as Map)['content'] as Map?)?['parts'] as List?;
    if (parts == null) throw BrainException('Gemini unreadable');
    return parts
        .map((p) => (p is Map ? p['text'] : null)?.toString() ?? '')
        .where((s) => s.isNotEmpty)
        .join('\n');
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
      files.add(const CodeBlock(
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
      ));
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

  String _trimForPrompt(String text, {int limit = 12000}) =>
      text.length > limit ? '${text.substring(0, limit)}\n...[truncated]' : text;

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

  String _short(String s) {
    final flat = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return flat.length > 240 ? '${flat.substring(0, 240)}...' : flat;
  }

  List<T> _takeLast<T>(List<T> list, int n) =>
      list.length <= n ? list : list.sublist(list.length - n);
}
