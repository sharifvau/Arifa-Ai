import 'dart:convert';

/// Where a model call is sent. This is NOT a model name.
enum ModelProvider { gemini, openRouter }

extension ModelProviderX on ModelProvider {
  String get wireName => switch (this) {
        ModelProvider.gemini => 'gemini',
        ModelProvider.openRouter => 'openRouter',
      };

  String get label => switch (this) {
        ModelProvider.gemini => 'Gemini',
        ModelProvider.openRouter => 'OpenRouter',
      };

  /// Returns null for unknown values so callers can reject them instead of
  /// silently sending an imported row to the wrong provider (AUDIT M3).
  static ModelProvider? fromWire(String raw) {
    final v = raw.trim().toLowerCase();
    if (v == 'gemini' || v == 'google' || v == 'native') {
      return ModelProvider.gemini;
    }
    if (v == 'openrouter' || v == 'open_router' || v == 'open router') {
      return ModelProvider.openRouter;
    }
    return null;
  }
}

/// One fully user-editable model row. No version is assumed by the app.
class ModelEntry {
  final String key;
  final String name;
  final String id;
  final ModelProvider provider;
  final bool supportsVision;
  final bool starter;

  const ModelEntry({
    required this.key,
    required this.name,
    required this.id,
    required this.provider,
    this.supportsVision = false,
    this.starter = false,
  });

  static String newKey() => 'm_${DateTime.now().microsecondsSinceEpoch}';

  ModelEntry copyWith({
    String? key,
    String? name,
    String? id,
    ModelProvider? provider,
    bool? supportsVision,
    bool? starter,
  }) {
    return ModelEntry(
      key: key ?? this.key,
      name: name ?? this.name,
      id: id ?? this.id,
      provider: provider ?? this.provider,
      supportsVision: supportsVision ?? this.supportsVision,
      starter: starter ?? this.starter,
    );
  }

  Map<String, dynamic> toJson() => {
        'key': key,
        'name': name,
        'id': id,
        'provider': provider.wireName,
        'supportsVision': supportsVision,
        'starter': starter,
      };

  factory ModelEntry.fromJson(Map<String, dynamic> j) {
    final name = _str(j, const ['name', 'displayName', 'label']);
    final id = _str(j, const ['id', 'modelId', 'model']);
    final rawKey = _str(j, const ['key']);
    final key = rawKey.isEmpty
        ? 'm_${name.hashCode.abs()}_${id.hashCode.abs()}'
        : rawKey;
    final rawProvider = _str(j, const ['provider', 'api', 'source']);
    final provider = ModelProviderX.fromWire(rawProvider);
    if (provider == null) {
      throw FormatException('Unknown model provider: "$rawProvider"');
    }
    return ModelEntry(
      key: key,
      name: name.isEmpty ? id : name,
      id: id,
      provider: provider,
      // Unknown/imported models are text-only until the user opts in (M4).
      supportsVision: _bool(
        j,
        const ['supportsVision', 'vision'],
        fallback: false,
      ),
      starter: _bool(j, const ['starter', 'builtIn'], fallback: false),
    );
  }

  static String _str(Map<String, dynamic> j, List<String> keys) {
    for (final k in keys) {
      final v = j[k];
      if (v != null) return v.toString().trim();
    }
    return '';
  }

  static bool _bool(
    Map<String, dynamic> j,
    List<String> keys, {
    required bool fallback,
  }) {
    for (final k in keys) {
      final v = j[k];
      if (v == null) continue;
      if (v is bool) return v;
      final s = v.toString().trim().toLowerCase();
      if (s == 'true' || s == '1' || s == 'yes') return true;
      if (s == 'false' || s == '0' || s == 'no') return false;
    }
    return fallback;
  }
}

/// The whole editable model catalog.
class ModelCatalog {
  final int schemaVersion;
  final List<ModelEntry> models;
  final String defaultKey;

  const ModelCatalog({
    required this.schemaVersion,
    required this.models,
    required this.defaultKey,
  });

  factory ModelCatalog.empty({int schemaVersion = 1}) => ModelCatalog(
        schemaVersion: schemaVersion,
        models: const [],
        defaultKey: '',
      );

  Map<String, dynamic> toJson() => {
        'schemaVersion': schemaVersion,
        'defaultKey': defaultKey,
        'models': models.map((m) => m.toJson()).toList(),
      };

  String encode() => jsonEncode(toJson());

  factory ModelCatalog.fromJson(Map<String, dynamic> j) {
    final models = <ModelEntry>[];
    final raw = j['models'];
    if (raw is List) {
      for (final e in raw) {
        if (e is Map) {
          models.add(ModelEntry.fromJson(Map<String, dynamic>.from(e)));
        }
      }
    }

    var defaultKey = (j['defaultKey'] ?? j['default'] ?? '').toString().trim();
    if (defaultKey.isEmpty || !models.any((m) => m.key == defaultKey)) {
      defaultKey = models.isEmpty ? '' : models.first.key;
    }

    final version =
        int.tryParse((j['schemaVersion'] ?? j['version'] ?? '1').toString()) ??
            1;

    return ModelCatalog(
      schemaVersion: version,
      models: List.unmodifiable(models),
      defaultKey: defaultKey,
    );
  }

  static ModelCatalog decode(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is Map) {
      return ModelCatalog.fromJson(Map<String, dynamic>.from(decoded));
    }
    return ModelCatalog.empty();
  }

  /// Adds seed rows that are missing, without touching user-edited rows.
  ModelCatalog mergeMissing(ModelCatalog seed) {
    final existingKeys = models.map((m) => m.key).toSet();
    final additions =
        seed.models.where((m) => !existingKeys.contains(m.key)).toList();
    if (additions.isEmpty) return this;

    final merged = <ModelEntry>[...models, ...additions];
    final def = defaultKey.isNotEmpty ? defaultKey : merged.first.key;
    return ModelCatalog(
      schemaVersion: seed.schemaVersion > schemaVersion
          ? seed.schemaVersion
          : schemaVersion,
      models: List.unmodifiable(merged),
      defaultKey: def,
    );
  }
}
