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
    _sub = _events.listen(
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

  /// Mirrors the wake setting into native SharedPreferences so BootReceiver
  /// can decide whether to start the foreground service after a reboot.
  Future<void> setWakeEnabled(bool enabled) async {
    try {
      await _method.invokeMethod<bool>('setWakeEnabled', {'enabled': enabled});
    } catch (_) {
      // Older native builds simply ignore this; boot defaults to enabled.
    }
  }

  Future<bool> isServiceRunning() async {
    try {
      return await _method.invokeMethod<bool>('isServiceRunning') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Starts Android MediaProjection consent and returns the real saved JPEG
  /// path. The MethodChannel result stays pending until ArifaService has
  /// actually written (and downscaled) the screenshot.
  Future<String?> captureScreen() async {
    try {
      return await _method.invokeMethod<String>('captureScreen');
    } on PlatformException catch (e) {
      _controller.add(WakeEvent(text: '[screen] ${e.message}', source: 'screen'));
      return null;
    }
  }

  /// Deletes the cached screenshot once the caller has consumed its bytes.
  Future<bool> clearScreenCapture() async {
    try {
      return await _method.invokeMethod<bool>('clearScreenCapture') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    await _controller.close();
  }
}
