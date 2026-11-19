import 'dart:convert';

import 'package:arifa/model_entry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ModelCatalog.decode / ModelEntry.fromJson', () {
    test('parses providers, names, ids and the vision opt-in', () {
      const raw = '''
      {
        "schemaVersion": 3,
        "defaultKey": "k2",
        "models": [
          {"key":"k1","name":"Gemini Flash","id":"gemini-1.5-flash","provider":"gemini","supportsVision":true,"starter":false},
          {"key":"k2","name":"Router","id":"openrouter/x","provider":"openRouter"},
          {"key":"k3","name":"Seed","id":"","provider":"openRouter","starter":true}
        ]
      }
      ''';
      final c = ModelCatalog.decode(raw);
      expect(c.schemaVersion, 3);
      expect(c.models.length, 3);
      expect(c.defaultKey, 'k2');

      expect(c.models[0].provider, ModelProvider.gemini);
      expect(c.models[0].id, 'gemini-1.5-flash');
      expect(c.models[0].supportsVision, isTrue);
      expect(c.models[0].starter, isFalse);

      expect(c.models[1].provider, ModelProvider.openRouter);
      // Unspecified vision must default to false, not true (AUDIT M4).
      expect(c.models[1].supportsVision, isFalse);

      // Starter rows are allowed an empty Model ID until the user fills it.
      expect(c.models[2].id, isEmpty);
      expect(c.models[2].starter, isTrue);
    });

    test('provider aliases normalise to gemini / openRouter', () {
      final c = ModelCatalog.decode(jsonEncode({
        'models': [
          {'key': 'a', 'id': 'g', 'provider': 'google'},
          {'key': 'b', 'id': 'o', 'provider': 'open_router'},
        ],
      }));
      expect(c.models[0].provider, ModelProvider.gemini);
      expect(c.models[1].provider, ModelProvider.openRouter);
    });

    test('unknown provider is rejected instead of becoming OpenRouter', () {
      expect(
        () => ModelCatalog.decode(jsonEncode({
          'models': [
            {'key': 'x', 'id': 'm', 'provider': 'anthropic'},
          ],
        })),
        throwsA(isA<FormatException>()),
      );
    });

    test('encode then decode round-trips the catalog', () {
      final original = ModelCatalog.decode(jsonEncode({
        'schemaVersion': 2,
        'defaultKey': 'a',
        'models': [
          {
            'key': 'a',
            'name': 'A',
            'id': 'id-a',
            'provider': 'gemini',
            'supportsVision': true,
          },
        ],
      }));
      final round = ModelCatalog.decode(original.encode());
      expect(round.schemaVersion, original.schemaVersion);
      expect(round.defaultKey, original.defaultKey);
      expect(round.models.length, 1);
      expect(round.models.first.name, 'A');
      expect(round.models.first.id, 'id-a');
      expect(round.models.first.provider, ModelProvider.gemini);
      expect(round.models.first.supportsVision, isTrue);
    });

    test('non-map JSON or an empty object yields an empty catalog', () {
      expect(ModelCatalog.decode('[]').models, isEmpty);
      expect(ModelCatalog.decode('{}').models, isEmpty);
    });
  });
}
