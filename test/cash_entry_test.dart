import 'package:flutter_test/flutter_test.dart';
import 'package:shree_glass/main.dart';

void main() {
  group('CashEntry payment tracking', () {
    final date = DateTime(2026, 10, 17, 12, 30);

    test('calculates remaining balance for a part-paid sale', () {
      final entry = CashEntry(
        type: 'income',
        description: 'Sliding window',
        customer: 'Asha Patil',
        amountPaise: 125000,
        collectedPaise: 50000,
        note: '',
        date: date,
        paymentMethod: 'Cash',
      );
      expect(entry.remainingPaise, 75000);
      expect(entry.toMap()['payment_status'], 'credit');
    });

    test('round-trips an online credit purchase', () {
      final entry = CashEntry(
        id: 8,
        type: 'expense',
        description: 'Glass sheets',
        customer: 'Supplier A',
        amountPaise: 450000,
        collectedPaise: 100000,
        note: 'Pay next week',
        date: date,
        paymentStatus: 'credit',
        paymentMethod: 'Online',
      );
      final restored = CashEntry.fromMap(entry.toMap());
      expect(restored.remainingPaise, 350000);
      expect(restored.paymentMethod, 'Online');
      expect(restored.type, 'expense');
      expect(restored.customer, 'Supplier A');
    });

    test('legacy paid rows default to fully collected', () {
      final restored = CashEntry.fromMap({
        'id': 2,
        'type': 'income',
        'description': 'Glass fitting',
        'customer': '',
        'amount_paise': 10000,
        'note': '',
        'entry_date': date.toIso8601String(),
      });
      expect(restored.paymentStatus, 'paid');
      expect(restored.paymentMethod, 'Cash');
      expect(restored.remainingPaise, 0);
    });

    test('converts the receipt total to English words', () {
      expect(amountInWords(4078000), 'Forty Thousand Seven Hundred Eighty Rupees Only');
    });
  });
}
