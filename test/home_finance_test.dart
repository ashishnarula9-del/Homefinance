import 'package:flutter_test/flutter_test.dart';
import 'package:family_finance/main.dart';

void main() {
  group('recurring dates', () {
    test('monthly clamps to the end of a short month', () {
      final next = nextRecurringDate(
        DateTime(2026, 1, 31),
        {'frequency': 'monthly', 'day': 31},
      );
      expect(next, DateTime(2026, 2, 28));
    });

    test('monthly returns to the wanted day afterwards', () {
      final next = nextRecurringDate(
        DateTime(2026, 2, 28),
        {'frequency': 'monthly', 'day': 31},
      );
      expect(next, DateTime(2026, 3, 31));
    });

    test('monthly rolls over the year', () {
      final next = nextRecurringDate(
        DateTime(2026, 12, 15),
        {'frequency': 'monthly', 'day': 15},
      );
      expect(next, DateTime(2027, 1, 15));
    });

    test('weekly adds seven days', () {
      final next = nextRecurringDate(DateTime(2026, 10, 31), {'frequency': 'weekly'});
      expect(next, DateTime(2026, 11, 7));
    });
  });

  group('money format', () {
    test('whole rupees have no decimals', () {
      expect(money.format(1200), contains('1,200'));
      expect(money.format(1200), isNot(contains('.')));
    });

    test('paise are shown when present', () {
      expect(money.format(1200.5), contains('1,200.50'));
    });

    test('tiny float noise does not show paise', () {
      expect(money.format(0.1 + 0.2 + 99.7), isNot(contains('.')));
    });
  });
}
