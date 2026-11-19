import 'package:arifa/allow_list.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('normalizeContact', () {
    test('collapses case and whitespace for names', () {
      expect(normalizeContact('  Ali  Ahmed '), 'ali ahmed');
      expect(normalizeContact('ALI'), 'ali');
    });

    test('normalises Bangladeshi phone formats to one 880-prefixed key', () {
      expect(normalizeContact('01712345678'), '8801712345678');
      expect(normalizeContact('+880 1712-345678'), '8801712345678');
      expect(normalizeContact('+88 01712 345678'), '8801712345678');
    });

    test('empty input stays empty', () {
      expect(normalizeContact(''), isEmpty);
      expect(normalizeContact('   '), isEmpty);
    });
  });

  group('matchesAllowListEntry', () {
    test('matches the exact name regardless of case/whitespace', () {
      expect(matchesAllowListEntry('Ali Ahmed', ' ali   ahmed '), isTrue);
    });

    test('never substring-matches a different contact', () {
      expect(matchesAllowListEntry('Ali', 'Alina'), isFalse);
      expect(matchesAllowListEntry('Ali', 'Ali Ahmed'), isFalse);
    });

    test('matches phone numbers across formatting styles', () {
      expect(
        matchesAllowListEntry('+880 1712-345678', '01712345678'),
        isTrue,
      );
    });

    test('the removed * wildcard never matches everyone', () {
      expect(matchesAllowListEntry('*', 'Alina'), isFalse);
      expect(matchesAllowListEntry('*', '01712345678'), isFalse);
    });

    test('empty entries never match', () {
      expect(matchesAllowListEntry('', 'Ali'), isFalse);
      expect(matchesAllowListEntry(' ', 'Ali'), isFalse);
    });
  });
}
