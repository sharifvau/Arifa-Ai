import 'dart:convert';

enum Speaker { user, arifa, system }

class ChatMessage {
  final Speaker speaker;
  final String text;
  final DateTime at;
  final List<CodeBlock> code;

  ChatMessage({
    required this.speaker,
    required this.text,
    List<CodeBlock>? code,
    DateTime? at,
  })  : code = code ?? const [],
        at = at ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'speaker': speaker.name,
        'text': text,
        'at': at.toIso8601String(),
        'code': code.map((c) => c.toJson()).toList(),
      };

  factory ChatMessage.fromJson(Map<String, dynamic> j) => ChatMessage(
        speaker: Speaker.values.firstWhere(
          (s) => s.name == j['speaker'],
          orElse: () => Speaker.system,
        ),
        text: j['text'] as String? ?? '',
        at: DateTime.tryParse(j['at'] as String? ?? '') ?? DateTime.now(),
        code: (j['code'] as List? ?? [])
            .map((e) => CodeBlock.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

class CodeBlock {
  final String path;
  final String language;
  final String content;

  const CodeBlock({
    required this.path,
    required this.language,
    required this.content,
  });

  Map<String, dynamic> toJson() => {
        'path': path,
        'language': language,
        'content': content,
      };

  factory CodeBlock.fromJson(Map<String, dynamic> j) => CodeBlock(
        path: j['path'] as String? ?? 'main.dart',
        language: j['language'] as String? ?? 'dart',
        content: j['content'] as String? ?? '',
      );
}

enum BrainTask { coding, chat, deep, vision }

class GeneratedApp {
  final String name;
  final String summary;
  final List<CodeBlock> files;

  const GeneratedApp({
    required this.name,
    required this.summary,
    required this.files,
  });

  Map<String, dynamic> toJsonMap() => {
        'name': name,
        'summary': summary,
        'files': {
          for (final f in files)
            f.path: {'content': f.content, 'language': f.language},
        },
      };

  factory GeneratedApp.fromJsonMap(Map<String, dynamic> j) {
    final files = <CodeBlock>[];
    final raw = j['files'];
    if (raw is Map) {
      raw.forEach((key, value) {
        if (value is String) {
          files.add(
            CodeBlock(path: key.toString(), language: 'dart', content: value),
          );
        } else if (value is Map) {
          files.add(CodeBlock(
            path: key.toString(),
            language: value['language'] as String? ?? 'dart',
            content: value['content'] as String? ?? '',
          ));
        }
      });
    } else if (raw is List) {
      for (final e in raw) {
        files.add(CodeBlock.fromJson(e as Map<String, dynamic>));
      }
    }
    return GeneratedApp(
      name: j['name'] as String? ?? 'arifa_app',
      summary: j['summary'] as String? ?? '',
      files: files,
    );
  }
}

class WakeEvent {
  final String text;
  final String source;
  final DateTime at;

  WakeEvent({required this.text, this.source = 'wake', DateTime? at})
      : at = at ?? DateTime.now();

  factory WakeEvent.fromJson(Map<String, dynamic> j) => WakeEvent(
        text: j['text'] as String? ?? '',
        source: j['source'] as String? ?? 'wake',
      );

  Map<String, dynamic> toJson() => {'text': text, 'source': source};
}

List<ChatMessage> decodeHistory(String raw) {
  try {
    final list = jsonDecode(raw) as List;
    return list
        .map((e) => ChatMessage.fromJson(e as Map<String, dynamic>))
        .toList();
  } catch (_) {
    return const [];
  }
}

String encodeHistory(List<ChatMessage> messages) =>
    jsonEncode(messages.map((m) => m.toJson()).toList());
