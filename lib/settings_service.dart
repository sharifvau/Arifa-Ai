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
  static const _kWake = 'wake_enabled';
  static const _kOnboarded = 'setup_done';
  static const _kModels = 'model_catalog_v1';
  static const _kModelsSeed = 'model_catalog_seed_version';

  String geminiKey = '';
  String openRouterKey = '';
  VoiceChoice voice = VoiceChoice.banglaFemaleCute;
  bool wakeEnabled = true;
  bool setupDone = false;

  /// The live catalog. Loaded from secure storage, never from Dart source.
  List<ModelEntry> models = const [];
  String defaultModelKey = '';
  int _seedVersion = 1;

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

  bool get hasUsableModel => models.any(
        (m) => m.id.trim().isNotEmpty && hasKeyFor(m.provider),
      );

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
    wakeEnabled = values[_kWake] != 'false';
    setupDone = values[_kOnboarded] == 'true';
    await _loadModels();
  }

  Future<void> _loadModels() async {
    final raw = await _storage.read(key: _kModels);

    if (raw == null || raw.trim().isEmpty) {
      await saveCatalog(await _readSeed());
      return;
    }

    ModelCatalog current;
    try {
      current = ModelCatalog.decode(raw);
    } catch (_) {
      current = ModelCatalog.empty();
    }

    final storedVersion =
        int.tryParse(await _storage.read(key: _kModelsSeed) ?? '') ?? 0;
    final seed = await _readSeed();

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

  Future<void> saveCatalog(ModelCatalog catalog) async {
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
    await saveCatalog(catalog);
  }

  Future<void> addModel(
    ModelEntry entry, {
    bool setDefault = false,
  }) async {
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

  Future<void> saveAll({
    required String gemini,
    required String openRouter,
    required VoiceChoice selectedVoice,
    required bool selectedWake,
  }) async {
    final g = gemini.trim();
    final o = openRouter.trim();
    await _storage.write(key: _kGemini, value: g);
    await _storage.write(key: _kOpenRouter, value: o);
    await _storage.write(key: _kVoice, value: selectedVoice.name);
    await _storage.write(key: _kWake, value: selectedWake.toString());
    await _storage.write(key: _kOnboarded, value: 'true');

    geminiKey = g;
    openRouterKey = o;
    voice = selectedVoice;
    wakeEnabled = selectedWake;
    setupDone = true;
  }
}
