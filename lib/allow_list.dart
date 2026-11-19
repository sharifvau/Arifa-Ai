/// Pure allow-list contact matching, shared by the app and its unit tests.
///
/// Names are compared after trimming, lowercasing and collapsing whitespace;
/// phone numbers are normalised to a 880-prefixed digit string so formatting
/// cannot bypass the gate. There is deliberately no substring matching
/// ("Ali" must not match "Alina") and no "*" wildcard — unknown senders are a
/// separate, explicit Settings switch.
String normalizeContact(String value) {
  final trimmed = value.trim().toLowerCase();
  if (trimmed.isEmpty) return '';
  final digits = trimmed.replaceAll(RegExp(r'[^0-9]'), '');
  if (digits.length >= 7 && RegExp(r'^[+\d\s().-]+$').hasMatch(trimmed)) {
    if (digits.length == 11 && digits.startsWith('0')) {
      return '880${digits.substring(1)}';
    }
    return digits;
  }
  return trimmed.replaceAll(RegExp(r'\s+'), ' ');
}

/// Whether [entry] from the allow list exactly authorises [contact].
bool matchesAllowListEntry(String entry, String contact) {
  final a = normalizeContact(entry);
  final b = normalizeContact(contact);
  if (a.isEmpty || b.isEmpty) return false;
  return a == b;
}
