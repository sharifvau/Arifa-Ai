/// Compile-time constants only. NO keys, NO model versions, NO secrets.
/// Models come from models.json on first launch, then from secure storage.
class ArifaConstants {
  ArifaConstants._();

  static const String wakeWord = 'arifa';
  static const String wakeWordBn = 'আরিফা';
  static const String ttsLocaleBn = 'bn-BD';
  static const String ttsLocaleEn = 'en-US';
  static const String sttLocale = 'bn_BD';
  static const String ownerName = 'Emon Bhai';

  static const String geminiEndpoint =
      'https://generativelanguage.googleapis.com/v1beta/models';
  static const String openRouterEndpoint =
      'https://openrouter.ai/api/v1/chat/completions';
  static const String openRouterModelsEndpoint =
      'https://openrouter.ai/api/v1/models';
}
