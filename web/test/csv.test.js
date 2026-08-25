import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { Money, TransactionFactory, ledgerAccount } from '../src/domain.js';
import { exportCSV } from '../src/csv.js';

describe('CSV export', () => {
  const bank = ledgerAccount({ name: 'Bank', kind: 'asset', currency: 'SGD' });
  const food = ledgerAccount({ name: 'Food', kind: 'expense' });

  it('writes one row per posting with exact amounts', () => {
    const entry = TransactionFactory.expense({
      amount: Money.parse('12.50', 'SGD'),
      accountID: bank.id, categoryID: food.id, payee: 'Cafe'
    });
    const rows = exportCSV([entry], [bank, food]).trim().split('\r\n');

    assert.equal(rows.length, 3, 'header plus two postings');
    assert.ok(rows[1].includes('"12.5"'));
    assert.ok(rows[2].includes('"-12.5"'));
  });

  it('neutralizes a payee that a spreadsheet would run as a formula', () => {
    const entry = TransactionFactory.expense({
      amount: Money.parse('1', 'SGD'),
      accountID: bank.id, categoryID: food.id,
      payee: '=HYPERLINK("http://evil","click")'
    });
    const csv = exportCSV([entry], [bank, food]);
    assert.ok(csv.includes(`"'=HYPERLINK`), 'formula must be quoted as text');
    assert.ok(!csv.includes(',"=HYPERLINK'));
  });

  it('escapes embedded quotes rather than breaking the row', () => {
    const entry = TransactionFactory.expense({
      amount: Money.parse('1', 'SGD'),
      accountID: bank.id, categoryID: food.id, payee: 'He said "hi"'
    });
    assert.ok(exportCSV([entry], [bank, food]).includes('"He said ""hi"""'));
  });
});

describe('CSV amounts stay numeric', () => {
  it('does not prefix a negative amount, which a spreadsheet must still sum', () => {
    const bank = ledgerAccount({ name: 'Bank', kind: 'asset', currency: 'SGD' });
    const food = ledgerAccount({ name: 'Food', kind: 'expense' });
    const entry = TransactionFactory.expense({
      amount: Money.parse('12.50', 'SGD'), accountID: bank.id, categoryID: food.id
    });
    const csv = exportCSV([entry], [bank, food]);
    assert.ok(csv.includes('"-12.5"'));
    assert.ok(!csv.includes(`"'-12.5"`), 'amounts must not be quoted as text');
  });
});
