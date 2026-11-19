import 'package:flutter/services.dart';

/// Android Intent + Accessibility based phone actions.
///
/// Android 10+ blocks direct WiFi toggling for normal apps, so WiFi goes
/// through Settings + accessibility tap (best effort, needs user consent).
class PhoneControl {
  PhoneControl();

  static const MethodChannel _ch = MethodChannel('arifa/native');

  Future<String> _call(String method, [Map<String, dynamic>? args]) async {
    try {
      final r = await _ch.invokeMethod<String>(method, args);
      return r ?? 'ok';
    } on PlatformException catch (e) {
      return 'bal na Emon Bhai: ${e.message}';
    } catch (e) {
      return 'bal na Emon Bhai: $e';
    }
  }

  Future<String> openApp(String nameOrPackage) =>
      _call('openApp', {'target': nameOrPackage});

  Future<String> dial(String number) =>
      _call('dial', {'number': number});

  Future<String> call(String number) =>
      _call('call', {'number': number});

  /// Opens WhatsApp with prefilled text. Auto-tap is attempted via the
  /// accessibility service, but WhatsApp may require the user to confirm.
  Future<String> sendWhatsApp(String contact, String message) => _call(
        'sendWhatsApp',
        {'contact': contact, 'message': message},
      );

  Future<String> toggleWifi({bool? enable}) =>
      _call('toggleWifi', {'enable': enable});

  Future<String> playSong(String query) =>
      _call('playSong', {'query': query});

  Future<String> openTtsSettings() => _call('openTtsSettings');

  Future<String> openAccessibilitySettings() =>
      _call('openAccessibilitySettings');

  Future<String> clickSendButton() => _call('clickSendButton');
}
