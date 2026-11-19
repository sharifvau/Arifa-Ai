import 'dart:async';

import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

import 'config.dart';
import 'settings_service.dart';

/// Bangla/English TTS + Bangla STT + wake-word matching.
/// The voice profile comes from in-app Settings (encrypted storage).
class VoiceService {
  VoiceService(this._settings);

  final SettingsService _settings;
  final FlutterTts _tts = FlutterTts();
  final SpeechToText _stt = SpeechToText();

  final _speakingController = StreamController<bool>.broadcast();
  final _heardController = StreamController<String>.broadcast();
  final _wakeController = StreamController<String>.broadcast();

  Stream<bool> get onSpeakingChanged => _speakingController.stream;
  Stream<String> get onHeard => _heardController.stream;
  Stream<String> get onWakeWord => _wakeController.stream;

  bool _ready = false;
  bool _listening = false;
  String? _voiceUsed;

  bool get isListening => _listening;
  String? get voiceUsed => _voiceUsed;

  Future<void> init() async {
    if (_ready) return;
    await _configureHandlers();
    await applyVoiceChoice(_settings.voice);
    _stt.errorListener = (error) {
      _heardController.add('[STT] $error');
    };
    _ready = true;
  }

  /// Call after Settings are saved.
  Future<void> reloadVoice() => applyVoiceChoice(_settings.voice);

  Future<void> _configureHandlers() async {
    await _tts.awaitSpeakCompletion(true);
    await _tts.setVolume(1.0);
    _tts.setStartHandler(() => _speakingController.add(true));
    _tts.setCompletionHandler(() => _speakingController.add(false));
    _tts.setCancelHandler(() => _speakingController.add(false));
    _tts.setErrorHandler((msg) {
      _speakingController.add(false);
      _heardController.add('[TTS] $msg');
    });
  }

  Future<void> applyVoiceChoice(VoiceChoice choice) async {
    final locale = choice.locale;
    await _tts.setLanguage(locale);
    await _tts.setPitch(choice.pitch);
    await _tts.setSpeechRate(choice.rate);

    try {
      // getVoices returns Future<dynamic> in flutter_tts 4.x and can be null
      // on some Android engines. Normalise it before using typed operators.
      final rawVoices = await _tts.getVoices;
      final voices = rawVoices is List ? rawVoices : const <dynamic>[];

      // An exact name nominated in Settings always wins.
      final nominated = _settings.ttsVoiceName.trim();
      if (nominated.isNotEmpty) {
        final exact = voices.where((v) {
          return v is Map && v['name'].toString() == nominated;
        }).firstOrNull;
        final name = exact is Map ? exact['name'].toString() : nominated;
        final voiceLocale = exact is Map && exact['locale'] != null
            ? exact['locale'].toString()
            : locale;
        await _tts.setVoice({'name': name, 'locale': voiceLocale});
        _voiceUsed = '$name ($voiceLocale)';
        return;
      }

      final localeVoices = voices.where((v) {
        final l = (v is Map ? v['locale'] : '').toString().toLowerCase();
        return l.startsWith(locale.split('-').first.toLowerCase());
      }).toList();

      // 'google' is not a gender hint: Google ships both male and female
      // engines whose names contain it, so it must not pick a voice here.
      final femaleWords = [
        'female', 'woman', 'zira', 'samantha', 'victoria', 'karen',
        'নারী', 'মহিলা',
      ];
      final maleWords = [
        'male', 'david', 'daniel', 'পুরুষ', 'পুরুষবাচক',
      ];
      final keywords = choice == VoiceChoice.banglaMale
          ? maleWords
          : femaleWords;

      bool matches(dynamic v) {
        final name = (v is Map ? v['name'] : '').toString().toLowerCase();
        return keywords.any(name.contains);
      }

      // Exact locale matches first (bn-BD for Bangladeshi Bengali), then the
      // wider language pool (bn-*), so a Bengali female voice is not beaten
      // by a generic engine from another region.
      final exactLocale = localeVoices.where((v) {
        final l = (v is Map ? v['locale'] : '').toString().toLowerCase();
        return l == locale.toLowerCase();
      }).toList();
      final exactMatches = exactLocale.where(matches).toList();
      final generalMatches = localeVoices.where(matches).toList();
      final candidates = <dynamic>[
        ...exactMatches,
        ...generalMatches.where((v) => !exactMatches.contains(v)),
        ...exactLocale,
        ...localeVoices,
      ];

      final chosen = candidates.firstOrNull;
      if (chosen is Map) {
        final name = chosen['name'].toString();
        final voiceLocale = chosen['locale'].toString();
        _voiceUsed = '$name ($voiceLocale)';
        await _tts.setVoice({'name': name, 'locale': voiceLocale});
      } else {
        _voiceUsed = '$locale default';
        await _tts.setLanguage(locale);
      }
    } catch (_) {
      _voiceUsed = '$locale default';
      await _tts.setLanguage(locale);
    }
  }

  Future<bool> get speechAvailable async {
    try {
      return await _stt.initialize(onError: (e) {}, onStatus: (s) {});
    } catch (_) {
      return false;
    }
  }

  Future<void> speak(String text) async {
    if (text.trim().isEmpty) return;
    try {
      final clean = text
          .replaceAll(
            RegExp(r'```[\s\S]*?```'),
            ' code dekhiye diyechi Emon Bhai. ',
          )
          .replaceAll(RegExp(r'[#*`_>]+'), '')
          .trim();
      await _tts.speak(clean.isEmpty ? text : clean);
    } catch (_) {
      _speakingController.add(false);
    }
  }

  Future<void> stopSpeaking() => _tts.stop();

  Future<bool> startListening({
    void Function(String text, bool finalResult)? onResult,
    Duration? listenFor,
    Duration? pauseFor,
  }) async {
    if (_listening) return true;
    final available = await _stt.initialize(
      onError: (error) {
        _heardController.add('[STT] $error');
      },
      onStatus: (status) {
        if (status == 'done' || status == 'notListening') {
          _listening = false;
        }
      },
    );
    if (!available) return false;

    _listening = true;
    await _stt.listen(
      onResult: (SpeechRecognitionResult result) {
        final text = result.recognizedWords.trim();
        if (text.isEmpty) return;
        _heardController.add(text);
        if (containsWakeWord(text)) {
          _wakeController.add(extractAfterWakeWord(text));
        }
        onResult?.call(text, result.finalResult);
      },
      localeId: ArifaConstants.sttLocale,
      listenFor: listenFor ?? const Duration(seconds: 25),
      pauseFor: pauseFor ?? const Duration(seconds: 4),
      // speech_to_text 7.0.0 still reads these deprecated fields internally.
      // ignore: deprecated_member_use
      partialResults: true,
      // ignore: deprecated_member_use
      cancelOnError: false,
      // ignore: deprecated_member_use
      listenMode: ListenMode.confirmation,
    );
    return true;
  }

  Future<void> stopListening() async {
    if (!_listening) return;
    await _stt.stop();
    _listening = false;
  }

  static bool containsWakeWord(String text) {
    final t = text.toLowerCase();
    return t.contains(ArifaConstants.wakeWord) ||
        t.contains(ArifaConstants.wakeWordBn);
  }

  /// "Arifa, calculator APK banaw" -> "calculator APK banaw"
  static String extractAfterWakeWord(String text) {
    final lower = text.toLowerCase();
    final idx = lower.indexOf(ArifaConstants.wakeWord);
    if (idx >= 0) {
      var rest = text.substring(idx + ArifaConstants.wakeWord.length);
      rest = rest.replaceFirst(RegExp(r'^[\s,।.,:،\-]+'), '');
      return rest.isEmpty ? 'shape tomake' : rest;
    }
    final bnIdx = text.indexOf(ArifaConstants.wakeWordBn);
    if (bnIdx >= 0) {
      var rest = text.substring(bnIdx + ArifaConstants.wakeWordBn.length);
      rest = rest.replaceFirst(RegExp(r'^[\s,।.,:،\-]+'), '');
      return rest.isEmpty ? 'বলো Emon Bhai, কী করব?' : rest;
    }
    return text;
  }

  Future<void> dispose() async {
    await stopListening();
    await stopSpeaking();
    await _speakingController.close();
    await _heardController.close();
    await _wakeController.close();
  }
}
