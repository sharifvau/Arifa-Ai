import 'package:arifa/voice_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('VoiceService.containsWakeWord', () {
    test('detects the English wake word case-insensitively', () {
      expect(VoiceService.containsWakeWord('Arifa, kemon acho'), isTrue);
      expect(VoiceService.containsWakeWord('ARIFA hello'), isTrue);
      expect(VoiceService.containsWakeWord('hey arifa'), isTrue);
    });

    test('detects the Bangla wake word', () {
      expect(VoiceService.containsWakeWord('আরিফা, গান চালাও'), isTrue);
    });

    test('does not fire on unrelated speech', () {
      expect(VoiceService.containsWakeWord('hello there'), isFalse);
      expect(VoiceService.containsWakeWord('communications'), isFalse);
    });
  });

  group('VoiceService.extractAfterWakeWord', () {
    test('strips the English wake word and leading punctuation', () {
      expect(
        VoiceService.extractAfterWakeWord('Arifa, calculator APK banaw'),
        'calculator APK banaw',
      );
    });

    test('strips the Bangla wake word', () {
      expect(
        VoiceService.extractAfterWakeWord('আরিফা, বলো Emon Bhai'),
        'বলো Emon Bhai',
      );
    });

    test('returns a prompt when only the wake word was spoken', () {
      final english = VoiceService.extractAfterWakeWord('Arifa');
      expect(english, isNotEmpty);
      expect(english, isNot(contains('arifa')));
      final bangla = VoiceService.extractAfterWakeWord('আরিফা');
      expect(bangla, isNotEmpty);
    });

    test('leaves text without a wake word unchanged', () {
      expect(
        VoiceService.extractAfterWakeWord('kemon acho'),
        'kemon acho',
      );
    });
  });
}
