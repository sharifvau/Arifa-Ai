import 'dart:convert';

import 'package:arifa/arifa_brain.dart';
import 'package:arifa/model_entry.dart';
import 'package:arifa/models.dart';
import 'package:arifa/settings_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// Fake provider endpoint: records the model id of every request and returns a
/// controlled status per id. No real network or API key is used.
class FakeClient extends http.Client {
  FakeClient(this.failures);

  /// model id -> HTTP status. Any id not listed succeeds.
  final Map<String, int> failures;
  final List<String> calls = <String>[];

  @override
  Future<http.Response> post(
    Uri url, {
    Map<String, String>? headers,
    Object? body,
    Encoding? encoding,
  }) async {
    final decoded = jsonDecode(body as String) as Map<String, dynamic>;
    final id = decoded['model'] as String;
    calls.add(id);
    final status = failures[id] ?? 200;
    if (status >= 400) {
      return http.Response('{"error":"nope"}', status);
    }
    return http.Response(
      '{"choices":[{"message":{"content":"ok from $id"}}]}',
      200,
    );
  }
}

void seedSettings({
  required List<ModelEntry> models,
  required String defaultKey,
}) {
  final s = SettingsService.instance;
  s.openRouterKey = 'test-key';
  s.geminiKey = '';
  s.models = models;
  s.defaultModelKey = defaultKey;
}

ModelEntry model(String id, String key, {bool vision = false}) => ModelEntry(
      key: key,
      name: 'name-$key',
      id: id,
      provider: ModelProvider.openRouter,
      supportsVision: vision,
    );

void main() {
  test('classify puts coding before vision and recognises deep/chat', () {
    final brain = ArifaBrain(client: FakeClient(const {}));
    expect(brain.classify('fix this Dart error'), BrainTask.coding);
    expect(brain.classify('dekho screen'), BrainTask.vision);
    expect(brain.classify('plan a roadmap'), BrainTask.deep);
    expect(brain.classify('kemon acho Emon Bhai'), BrainTask.chat);
  });

  test('the default model is attempted first on success', () async {
    final client = FakeClient(const {});
    seedSettings(
      models: [model('id-1', 'k1'), model('id-2', 'k2'), model('id-3', 'k3')],
      defaultKey: 'k2',
    );
    final reply = await ArifaBrain(client: client).ask('hello');
    expect(reply.modelUsed, 'name-k2');
    expect(client.calls, <String>['id-2']);
  });

  test('failover is default-first, then catalog order, with no repeats',
      () async {
    final client = FakeClient(const {'id-2': 500});
    seedSettings(
      models: [model('id-1', 'k1'), model('id-2', 'k2'), model('id-3', 'k3')],
      defaultKey: 'k2',
    );
    final reply = await ArifaBrain(client: client).ask('hello');
    // k2 (default) fails; usable order is k1, k2 (dup skipped), k3.
    expect(reply.modelUsed, 'name-k1');
    expect(client.calls, <String>['id-2', 'id-1']);
  });

  test('at most maxFailoverModels models are attempted', () async {
    final client = FakeClient(const {
      'id-1': 500,
      'id-2': 500,
      'id-3': 500,
      'id-4': 500,
    });
    seedSettings(
      models: [
        model('id-1', 'k1'),
        model('id-2', 'k2'),
        model('id-3', 'k3'),
        model('id-4', 'k4'),
      ],
      defaultKey: 'k1',
    );
    await expectLater(
      ArifaBrain(client: client).ask('hello'),
      throwsA(isA<BrainException>()),
    );
    expect(client.calls.length, ArifaBrain.maxFailoverModels);
  });

  test('an auth failure stops failover immediately', () async {
    final client = FakeClient(const {'id-1': 401});
    seedSettings(
      models: [model('id-1', 'k1'), model('id-2', 'k2')],
      defaultKey: 'k1',
    );
    await expectLater(
      ArifaBrain(client: client).ask('hello'),
      throwsA(
        isA<BrainException>().having(
          (e) => e.authFailure,
          'authFailure',
          isTrue,
        ),
      ),
    );
    expect(client.calls, <String>['id-1']);
  });

  test('a vision task prefers vision-capable rows after the default',
      () async {
    final client = FakeClient(const {'id-default': 500});
    seedSettings(
      models: [
        model('id-default', 'kd'),
        model('id-text', 'kt'),
        model('id-vision', 'kv', vision: true),
      ],
      defaultKey: 'kd',
    );
    final reply = await ArifaBrain(client: client).ask(
      'screen',
      forcedTask: BrainTask.vision,
    );
    // After the default fails, vision rows come before plain text rows.
    expect(reply.modelUsed, 'name-kv');
    expect(client.calls, <String>['id-default', 'id-vision']);
  });
}
