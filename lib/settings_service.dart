import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'model_entry.dart';

enum VoiceChoice { banglaFemaleCute, banglaMale, englishFemale }

extension VoiceChoiceX on VoiceChoice {
  String get label => switch (this) {
    VoiceChoice.banglaFemaleCute => 'Bangladeshi Female Cute Voice',
    VoiceChoice.banglaMale => 'Bangladeshi Male Voice',
    VoiceChoice.englishFemale => 'English Female Voice',
  };

  String get locale => switch (this) {
    VoiceChoice.englishFemale => ArifaStorageConstants.ttsLocaleEn,
    _ => ArifaStorageConstants.ttsLocaleBn,
  };

  double get pitch => switch (this) {
    VoiceChoice.banglaFemaleCute => 1.22,
    VoiceChoice.banglaMale => 0.86,
    VoiceChoice.englishFemale => 1.12,
  };

  double get rate => switch (this) {
    VoiceChoice.banglaFemaleCute => 0.48,
    VoiceChoice.banglaMale => 0.52,
    VoiceChoice.englishFemale => 0.5,
  };
}

/// Keys for secure storage only.
abstract final class ArifaStorageConstants {
  static const String ttsLocaleBn = 'bn-BD';
  static const String ttsLocaleEn = 'en-US';
}

/// Single source of truth for settings, backed by encrypted storage.
class SettingsService {
  SettingsService._();

  static final SettingsService instance = SettingsService._();

  // v11+ uses Keystore-backed AES-GCM by default. Nothing is written to a
  // plain file, and no secret is ever bundled into the APK.
  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(),
  );

  static const _kGemini = 'gemini_api_key';
  static const _kOpenRouter = 'openrouter_api_key';
  static const _kVoice = 'voice_choice';
  static const _kVoiceName = 'tts_voice_name';
  static const _kWake = 'wake_enabled';
  static const _kOnboarded = 'setup_done';
  static const _kModels = 'model_catalog_v1';
  static const _kModelsSeed = 'model_catalog_seed_version';
  static const _kModelsCorrupt = 'model_catalog_corrupt_backup';

  // WhatsApp Auto Reply — also encrypted, never a plain file.
  static const _kWaEnabled = 'whatsapp_auto_reply_enabled';
  static const _kWaAllow = 'whatsapp_allow_list';
  static const _kWaImportant = 'whatsapp_important_contacts';
  static const _kWaToken = 'whatsapp_business_token';
  static const _kWaPhoneId = 'whatsapp_business_phone_id';
  static const _kWaCloudBrain = 'whatsapp_use_cloud_brain';
  static const _kWaCloudApi = 'whatsapp_use_cloud_api';
  static const _kWaStyle = 'whatsapp_style_samples';
  static const _kWaCustomReplies = 'whatsapp_custom_replies';
  static const _kWaReplyUnknown = 'whatsapp_reply_unknown';

  String geminiKey = '';
  String openRouterKey = '';
  VoiceChoice voice = VoiceChoice.banglaFemaleCute;

  /// Exact TTS voice name nominated in Settings. Empty = choose automatically.
  String ttsVoiceName = '';
  bool wakeEnabled = true;
  bool setupDone = false;

  /// WhatsApp Auto Reply state. Default is OFF and nobody is allowed — no
  /// notification is even read until the user explicitly turns this on.
  bool whatsappAutoReply = false;
  List<String> whatsappAllowList = const [];
  List<String> whatsappImportantContacts = const ['Ammu', 'Family'];
  String whatsappBusinessToken = '';
  String whatsappBusinessPhoneId = '';
  bool whatsappUseCloudBrain = false;
  bool whatsappUseCloudApi = false;
  List<String> whatsappStyleSamples = const [];
  Map<String, String> whatsappCustomReplies = const {};
  bool whatsappReplyUnknown = false;

  /// The live catalog. Loaded from secure storage, never from Dart source.
  List<ModelEntry> models = const [];
  String defaultModelKey = '';
  int _seedVersion = 1;

  /// Set when a corrupt stored catalog was backed up and seed rows restored.
  String catalogWarning = '';

  ModelEntry? get defaultModel {
    for (final m in models) {
      if (m.key == defaultModelKey) return m;
    }
    return null;
  }

  bool hasKeyFor(ModelProvider provider) => switch (provider) {
    ModelProvider.gemini => geminiKey.isNotEmpty,
    ModelProvider.openRouter => openRouterKey.isNotEmpty,
  };

  bool get hasUsableModel =>
      models.any((m) => m.id.trim().isNotEmpty && hasKeyFor(m.provider));

  bool get needsSetup => !setupDone || !hasAnyKey || !hasUsableModel;

  bool get hasAnyKey => geminiKey.isNotEmpty || openRouterKey.isNotEmpty;

  Future<void> init() async {
    final values = await _storage.readAll();
    geminiKey = (values[_kGemini] ?? '').trim();
    openRouterKey = (values[_kOpenRouter] ?? '').trim();
    voice = VoiceChoice.values.firstWhere(
      (e) => e.name == values[_kVoice],
      orElse: () => VoiceChoice.banglaFemaleCute,
    );
    ttsVoiceName = (values[_kVoiceName] ?? '').trim();
    wakeEnabled = values[_kWake] != 'false';
    setupDone = values[_kOnboarded] == 'true';

    whatsappAutoReply = values[_kWaEnabled] == 'true';
    whatsappAllowList = _decodeList(values[_kWaAllow]);
    whatsappImportantContacts = values[_kWaImportant] == null
        ? const ['Ammu', 'Family']
        : _decodeList(values[_kWaImportant]);
    whatsappBusinessToken = (values[_kWaToken] ?? '').trim();
    whatsappBusinessPhoneId = (values[_kWaPhoneId] ?? '').trim();
    whatsappUseCloudBrain = values[_kWaCloudBrain] == 'true';
    whatsappUseCloudApi = values[_kWaCloudApi] == 'true';
    whatsappStyleSamples = _decodeList(values[_kWaStyle]);
    whatsappCustomReplies = _decodeMap(values[_kWaCustomReplies]);
    whatsappReplyUnknown = values[_kWaReplyUnknown] == 'true';

    await _loadModels();
  }

  static List<String> _decodeList(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded
            .map((e) => e.toString().trim())
            .where((e) => e.isNotEmpty)
            .toList(growable: false);
      }
    } catch (_) {}
    return raw
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
  }

  static Map<String, String> _decodeMap(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded.map((k, v) => MapEntry(k.toString(), v.toString()));
    } catch (_) {
      return const {};
    }
  }

  Future<void> _loadModels() async {
    final raw = await _storage.read(key: _kModels);
    final seed = await _readSeed();
    catalogWarning = '';

    if (raw == null || raw.trim().isEmpty) {
      // Never persist an empty seed: a transient asset/read failure must not
      // permanently erase the catalog and bump the seed version (AUDIT H11).
      if (seed.models.isEmpty) {
        _apply(ModelCatalog.empty());
        return;
      }
      await saveCatalog(seed);
      return;
    }

    ModelCatalog current;
    var corrupt = false;
    try {
      current = ModelCatalog.decode(raw);
    } catch (_) {
      // Preserve the bad value for diagnosis and force a seed merge (M1).
      try {
        await _storage.write(key: _kModelsCorrupt, value: raw);
      } catch (_) {}
      current = ModelCatalog.empty();
      corrupt = true;
      catalogWarning = 'মডেল তালিকা খারাপ হয়েছিল — seed মডেলগুলো ফেরত আনা হয়েছে।';
    }

    final storedVersion = corrupt
        ? 0
        : int.tryParse(await _storage.read(key: _kModelsSeed) ?? '') ?? 0;

    if (seed.schemaVersion > storedVersion && seed.models.isNotEmpty) {
      final merged = current.mergeMissing(seed);
      await saveCatalog(
        ModelCatalog(
          schemaVersion: seed.schemaVersion > merged.schemaVersion
              ? seed.schemaVersion
              : merged.schemaVersion,
          models: merged.models,
          defaultKey: merged.defaultKey,
        ),
      );
      return;
    }

    _apply(current);
  }

  Future<ModelCatalog> _readSeed() async {
    try {
      final raw = await rootBundle.loadString('models.json');
      return ModelCatalog.decode(raw);
    } catch (_) {
      return ModelCatalog.empty();
    }
  }

  void _apply(ModelCatalog catalog) {
    models = List.unmodifiable(catalog.models);
    defaultModelKey = catalog.defaultKey;
    _seedVersion = catalog.schemaVersion;
  }

  ModelCatalog toCatalog() => ModelCatalog(
    schemaVersion: _seedVersion < 1 ? 1 : _seedVersion,
    models: models,
    defaultKey: defaultModelKey,
  );

  /// Imported/stored catalogs must be bounded and internally consistent (M2).
  void _validateCatalog(ModelCatalog catalog) {
    if (catalog.schemaVersion < 1 || catalog.schemaVersion > 1000) {
      throw const FormatException('Catalog-এর schemaVersion অবৈধ Emon Bhai।');
    }
    if (catalog.models.length > 200) {
      throw const FormatException('Catalog-এ ২০০-এর বেশি মডেল আছে Emon Bhai।');
    }
    final keys = <String>{};
    for (final m in catalog.models) {
      if (m.key.trim().isEmpty) {
        throw const FormatException('একটা মডেলের key খালি আছে Emon Bhai।');
      }
      if (!keys.add(m.key)) {
        throw FormatException('Duplicate model key: ${m.key}');
      }
      if (m.id.trim().isEmpty && !m.starter) {
        throw FormatException('${m.name}-এর Model ID দেওয়া নেই Emon Bhai।');
      }
    }
    if (catalog.defaultKey.isNotEmpty && !keys.contains(catalog.defaultKey)) {
      throw const FormatException('Default model-টি Catalog-এ নেই Emon Bhai।');
    }
  }

  Future<void> saveCatalog(ModelCatalog catalog) async {
    _validateCatalog(catalog);
    await _storage.write(key: _kModels, value: catalog.encode());
    await _storage.write(
      key: _kModelsSeed,
      value: catalog.schemaVersion.toString(),
    );
    _apply(catalog);
  }

  Future<void> importCatalog(String raw) async {
    final catalog = ModelCatalog.decode(raw);
    if (catalog.models.isEmpty) {
      throw const FormatException('models.json-এ কোনো মডেল নেই Emon Bhai।');
    }
    _validateCatalog(catalog);
    await saveCatalog(catalog);
  }

  Future<void> addModel(ModelEntry entry, {bool setDefault = false}) async {
    final catalog = toCatalog();
    final key = entry.key.isEmpty ? ModelEntry.newKey() : entry.key;
    final clean = entry.copyWith(key: key);
    final list = [...catalog.models, clean];
    await saveCatalog(
      ModelCatalog(
        schemaVersion: catalog.schemaVersion,
        models: list,
        defaultKey: setDefault ? key : catalog.defaultKey,
      ),
    );
  }

  Future<void> updateModel(String key, ModelEntry entry) async {
    final catalog = toCatalog();
    final list = [
      for (final m in catalog.models)
        m.key == key ? entry.copyWith(key: key) : m,
    ];
    await saveCatalog(
      ModelCatalog(
        schemaVersion: catalog.schemaVersion,
        models: list,
        defaultKey: catalog.defaultKey,
      ),
    );
  }

  Future<void> deleteModel(String key) async {
    final catalog = toCatalog();
    final remaining = catalog.models.where((m) => m.key != key).toList();
    final nextDefault = catalog.defaultKey == key
        ? (remaining.isEmpty ? '' : remaining.first.key)
        : catalog.defaultKey;
    await saveCatalog(
      ModelCatalog(
        schemaVersion: catalog.schemaVersion,
        models: remaining,
        defaultKey: nextDefault,
      ),
    );
  }

  Future<void> setDefault(String key) async {
    final catalog = toCatalog();
    if (!catalog.models.any((m) => m.key == key)) return;
    await saveCatalog(
      ModelCatalog(
        schemaVersion: catalog.schemaVersion,
        models: catalog.models,
        defaultKey: key,
      ),
    );
  }

  /// Instant ON/OFF used by the voice command and the home-screen dot.
  /// Nothing else has to be saved for this to take effect.
  Future<void> setWhatsAppEnabled(bool value) async {
    await _storage.write(key: _kWaEnabled, value: value.toString());
    whatsappAutoReply = value;
  }

  /// Persists every WhatsApp Auto Reply preference. Any argument left null is
  /// kept as-is, so callers can update only the fields they own.
  Future<void> saveWhatsApp({
    bool? enabled,
    List<String>? allowList,
    List<String>? importantContacts,
    String? businessToken,
    String? businessPhoneId,
    bool? useCloudBrain,
    bool? useCloudApi,
    List<String>? styleSamples,
    Map<String, String>? customReplies,
    bool? replyUnknown,
  }) async {
    if (enabled != null) {
      await _storage.write(key: _kWaEnabled, value: enabled.toString());
      whatsappAutoReply = enabled;
    }
    if (allowList != null) {
      final clean = allowList
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
      await _storage.write(key: _kWaAllow, value: jsonEncode(clean));
      whatsappAllowList = clean;
    }
    if (importantContacts != null) {
      final clean = importantContacts
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
      await _storage.write(key: _kWaImportant, value: jsonEncode(clean));
      whatsappImportantContacts = clean;
    }
    if (businessToken != null) {
      final clean = businessToken.trim();
      await _storage.write(key: _kWaToken, value: clean);
      whatsappBusinessToken = clean;
    }
    if (businessPhoneId != null) {
      final clean = businessPhoneId.trim();
      await _storage.write(key: _kWaPhoneId, value: clean);
      whatsappBusinessPhoneId = clean;
    }
    if (useCloudBrain != null) {
      await _storage.write(
        key: _kWaCloudBrain,
        value: useCloudBrain.toString(),
      );
      whatsappUseCloudBrain = useCloudBrain;
    }
    if (useCloudApi != null) {
      await _storage.write(key: _kWaCloudApi, value: useCloudApi.toString());
      whatsappUseCloudApi = useCloudApi;
    }
    if (styleSamples != null) {
      final clean = styleSamples
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
      await _storage.write(key: _kWaStyle, value: jsonEncode(clean));
      whatsappStyleSamples = clean;
    }
    if (customReplies != null) {
      final clean = <String, String>{};
      customReplies.forEach((k, v) {
        final key = k.trim();
        final val = v.trim();
        if (key.isNotEmpty && val.isNotEmpty) clean[key] = val;
      });
      await _storage.write(key: _kWaCustomReplies, value: jsonEncode(clean));
      whatsappCustomReplies = clean;
    }
    if (replyUnknown != null) {
      await _storage.write(
        key: _kWaReplyUnknown,
        value: replyUnknown.toString(),
      );
      whatsappReplyUnknown = replyUnknown;
    }
  }

  /// Persist an exact Android TTS voice name (empty clears the override).
  Future<void> saveVoiceName(String name) async {
    final clean = name.trim();
    await _storage.write(key: _kVoiceName, value: clean);
    ttsVoiceName = clean;
  }

  Future<void> saveAll({
    required String gemini,
    required String openRouter,
    required VoiceChoice selectedVoice,
    required bool selectedWake,
    String? selectedVoiceName,
    bool? whatsappAutoReplyEnabled,
    List<String>? whatsappAllow,
    List<String>? whatsappImportant,
    String? whatsappToken,
    String? whatsappPhoneId,
    bool? whatsappCloudBrain,
    bool? whatsappCloudApi,
    List<String>? whatsappStyles,
    Map<String, String>? whatsappReplies,
    bool? whatsappReplyToUnknown,
  }) async {
    final g = gemini.trim();
    final o = openRouter.trim();
    await _storage.write(key: _kGemini, value: g);
    await _storage.write(key: _kOpenRouter, value: o);
    await _storage.write(key: _kVoice, value: selectedVoice.name);
    await _storage.write(key: _kWake, value: selectedWake.toString());
    await _storage.write(key: _kOnboarded, value: 'true');
    if (selectedVoiceName != null) {
      await saveVoiceName(selectedVoiceName);
    }

    geminiKey = g;
    openRouterKey = o;
    voice = selectedVoice;
    wakeEnabled = selectedWake;
    setupDone = true;

    await saveWhatsApp(
      enabled: whatsappAutoReplyEnabled,
      allowList: whatsappAllow,
      importantContacts: whatsappImportant,
      businessToken: whatsappToken,
      businessPhoneId: whatsappPhoneId,
      useCloudBrain: whatsappCloudBrain,
      useCloudApi: whatsappCloudApi,
      styleSamples: whatsappStyles,
      customReplies: whatsappReplies,
      replyUnknown: whatsappReplyToUnknown,
    );
  }
}
