import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

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

  /// Requests CALL_PHONE + SEND_SMS together. Returns true only when both are
  /// granted, so callers can switch direct call()/sendSms() on with one check.
  Future<bool> requestPhonePermissions() async {
    final statuses = await <Permission>[
      Permission.phone,
      Permission.sms,
    ].request();
    return statuses[Permission.phone]?.isGranted == true &&
        statuses[Permission.sms]?.isGranted == true;
  }

  /// Sends an SMS through native SmsManager (or the default SMS app as a
  /// fallback). Native owns the actual send — this is just the channel call.
  Future<String> sendSms(String phone, String body) =>
      _call('sendSms', {'phone': phone, 'body': body});

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
