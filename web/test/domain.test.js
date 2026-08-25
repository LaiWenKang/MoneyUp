import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import {
  Money, MoneyError, ValidationError, TransactionFactory,
  currencyCode, journalEntry, ledgerAccount, posting
} from '../src/domain.js';

describe('Money', () => {
  it('adds without binary floating point drift', () => {
    const total = Money.parse('0.1', 'SGD').add(Money.parse('0.2', 'SGD'));
    assert.equal(total.toString(), '0.3');
  });

  it('keeps long chains of cents exact', () => {
    let running = Money.zero('SGD');
    for (let index = 0; index < 10_000; index += 1) {
      running = running.add(Money.parse('0.01', 'SGD'));
    }
    assert.equal(running.toString(), '100');
  });

  it('parses thousands separators and negatives', () => {
    assert.equal(Money.parse('1,299.00', 'SGD').toString(), '1299');
    assert.equal(Money.parse('-8', 'SGD').toString(), '-8');
  });

  it('rejects nonsense rather than coercing it', () => {
    assert.throws(() => Money.parse('twelve', 'SGD'), MoneyError);
    assert.throws(() => Money.parse('', 'SGD'), MoneyError);
    assert.throws(() => Money.parse('1.2345678', 'SGD'), MoneyError);
  });

  it('refuses to mix currencies', () => {
    assert.throws(
      () => Money.parse('1', 'SGD').add(Money.parse('1', 'USD')),
      MoneyError
    );
  });

  it('round-trips through JSON exactly', () => {
    const original = Money.parse('1234.567', 'USD');
    const restored = Money.fromJSON(JSON.parse(JSON.stringify(original)));
    assert.ok(restored.equals(original));
  });

  it('normalizes currency codes and rejects invalid ones', () => {
    assert.equal(currencyCode(' sgd '), 'SGD');
    assert.throws(() => currencyCode('S$'), MoneyError);
  });
});

describe('journal entries', () => {
  const bank = ledgerAccount({ name: 'Bank', kind: 'asset', currency: 'SGD' });
  const food = ledgerAccount({ name: 'Food', kind: 'expense' });

  it('accepts a balanced entry', () => {
    const entry = TransactionFactory.expense({
      amount: Money.parse('12.50', 'SGD'),
      accountID: bank.id,
      categoryID: food.id
    });
    assert.equal(entry.postings.length, 2);
    assert.equal(entry.kind, 'expense');
  });

  it('refuses an entry that does not balance', () => {
    assert.throws(() => journalEntry({
      kind: 'expense',
      postings: [
        posting({ accountID: food.id, money: Money.parse('10', 'SGD') }),
        posting({ accountID: bank.id, money: Money.parse('-9', 'SGD') })
      ]
    }), ValidationError);
  });

  it('balances each currency independently on an FX transfer', () => {
    const entry = TransactionFactory.foreignCurrencyTransfer({
      sourceAmount: Money.parse('100', 'SGD'),
      destinationAmount: Money.parse('74.20', 'USD'),
      sourceAccountID: 'a',
      destinationAccountID: 'b',
      sourceTradingAccountID: 't1',
      destinationTradingAccountID: 't2'
    });
    assert.equal(entry.postings.length, 4);
  });

  it('rejects a posting that moves nothing', () => {
    assert.throws(() => journalEntry({
      kind: 'adjustment',
      postings: [
        posting({ accountID: 'a', money: Money.zero('SGD') }),
        posting({ accountID: 'b', money: Money.zero('SGD') })
      ]
    }), ValidationError);
  });

  it('treats a reconciliation as neither income nor spending', () => {
    const entry = TransactionFactory.balanceAdjustment({
      displayDelta: Money.parse('75', 'SGD'),
      accountID: bank.id,
      equityAccountID: 'equity',
      accountIsLiability: false
    });
    assert.equal(entry.kind, 'adjustment');
    assert.ok(entry.postings.every((item) => item.accountID !== food.id));
  });

  it('flips the sign for a liability so paying down debt reads correctly', () => {
    const entry = TransactionFactory.balanceAdjustment({
      displayDelta: Money.parse('200', 'SGD'),
      accountID: 'card',
      equityAccountID: 'equity',
      accountIsLiability: true
    });
    const cardPosting = entry.postings.find((item) => item.accountID === 'card');
    assert.equal(cardPosting.money.toString(), '-200');
  });
});
