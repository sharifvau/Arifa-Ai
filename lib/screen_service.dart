import 'dart:convert';
import 'dart:io';

import 'arifa_brain.dart';
import 'background_service.dart';
import 'models.dart';

class ScreenReport {
  final String description;
  final List<String> detectedErrors;
  final String modelUsed;

  const ScreenReport({
    required this.description,
    required this.detectedErrors,
    required this.modelUsed,
  });

  bool get hasError => detectedErrors.isNotEmpty;
}

/// MediaProjection screenshot -> Gemini vision -> Bangla explanation.
class ScreenService {
  ScreenService({required this.brain, required this.native});

  final ArifaBrain brain;
  final BackgroundService native;

  Future<ScreenReport?> seeAndExplain() async {
    final path = await native.captureScreen();
    if (path == null || path.isEmpty) return null;

    try {
      final bytes = await File(path).readAsBytes();
      final base64Image = base64Encode(bytes);
      // Gemini inline_data has a ~4MB safe limit; downscale natively if needed.
      if (bytes.length > 4 * 1024 * 1024) {
        return ScreenReport(
          description:
              'স্ক্রিনশট অনেক বড় ($bytes bytes)। একটু কম রিজোলিউশনে আবার চেষ্টা করছি Emon Bhai।',
          detectedErrors: const [],
          modelUsed: 'local',
        );
      }

      final reply = await brain.ask(
        'এই স্ক্রিনশটে ঠিক কী আছে? বাংলায় বলো। '
        'কোড বা error দেখা গেলে error টি যথাযথভাবে উদ্ধৃত করো এবং কী ঠিক করতে হবে বলো।',
        forcedTask: BrainTask.vision,
        imageBase64: base64Image,
      );

      return ScreenReport(
        description: reply.text,
        detectedErrors: _detectErrors(reply.text),
        modelUsed: reply.modelUsed,
      );
    } on FileSystemException catch (e) {
      return ScreenReport(
        description: 'স্ক্রিনশট ফাইল পড়তে সমস্যা: $e',
        detectedErrors: const [],
        modelUsed: 'local',
      );
    }
  }

  /// Heuristic: pull quoted compile/runtime errors out of the vision reply.
  List<String> _detectErrors(String text) {
    final found = <String>[];
    final patterns = [
      RegExp(r'error[^\n]{0,300}', caseSensitive: false),
      RegExp(r'exception[^\n]{0,300}', caseSensitive: false),
      RegExp(r'failed[^\n]{0,300}', caseSensitive: false),
      RegExp(r'(.*?)\.dart:\d+:\d+[^\n]{0,200}'),
      RegExp(r'এরর[^\n]{0,300}'),
      RegExp(r'সমস্যা[^\n]{0,300}'),
    ];
    for (final p in patterns) {
      for (final m in p.allMatches(text)) {
        final s = m.group(0)?.trim() ?? '';
        if (s.length > 8 && !found.contains(s)) found.add(s);
        if (found.length >= 6) return found;
      }
    }
    return found;
  }
}
