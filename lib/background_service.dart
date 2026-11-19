import 'dart:async';

import 'package:flutter/services.dart';

import 'models.dart';

/// Interface to the native Kotlin foreground service / accessibility helpers.
class BackgroundService {
  BackgroundService();

  static const MethodChannel _method = MethodChannel('arifa/native');
  static const EventChannel _event = EventChannel('arifa/events');

  late final Stream<WakeEvent> _events =
      _event.receiveBroadcastStream().map((dynamic e) {
    if (e is Map) {
      return WakeEvent(
        text: (e['text'] ?? e['path'] ?? '').toString(),
        source: (e['type'] ?? 'unknown').toString(),
      );
    }
    return WakeEvent(text: e.toString());
  });
  StreamSubscription<dynamic>? _sub;
  final _controller = StreamController<WakeEvent>.broadcast();

  Stream<WakeEvent> get events => _controller.stream;

  Future<void> listen() async {
    if (_sub != null) return;
    _sub = _events!.listen(
      _controller.add,
      onError: (Object e) => _controller.add(WakeEvent(text: '[native] $e')),
    );
  }

  Future<bool> startWakeService() async {
    try {
      final r = await _method.invokeMethod<bool>('startWakeService');
      return r ?? false;
    } on PlatformException catch (e) {
      _controller.add(WakeEvent(text: '[service] ${e.message}'));
      return false;
    }
  }

  Future<bool> stopWakeService() async {
    try {
      return await _method.invokeMethod<bool>('stopWakeService') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> isServiceRunning() async {
    try {
      return await _method.invokeMethod<bool>('isServiceRunning') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Starts Android MediaProjection consent and returns captured JPEG path.
  Future<String?> captureScreen() async {
    try {
      return await _method.invokeMethod<String>('captureScreen');
    } on PlatformException catch (e) {
      _controller.add(WakeEvent(text: '[screen] ${e.message}', source: 'screen'));
      return null;
    }
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    await _controller.close();
  }
}
