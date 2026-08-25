import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { Money, TransactionFactory, ledgerAccount } from '../src/domain.js';
import { parsePhrase, suggestCategory } from '../src/parse.js';

const cash = ledgerAccount({ name: 'Cash', kind: 'asset', accountType: 'cash' });
const card = ledgerAccount({ name: 'Cash Back Card', kind: 'liability', accountType: 'credit_card' });
const food = ledgerAccount({ name: 'Food', kind: 'expense' });
const salary = ledgerAccount({ name: 'Salary', kind: 'income' });
const accounts = [cash, card, food, salary];

// 2026-03-20 is a Friday.
const now = new Date(2026, 2, 20, 14, 30);

describe('typed phrases', () => {
  it('reads amount, account, and a relative day', () => {
    const draft = parsePhrase('lunch 12.50 cash yesterday', { accounts, now });
    assert.equal(draft.kind, 'expense');
    assert.equal(draft.amount, '12.50');
    assert.equal(draft.accountID, cash.id);
    assert.equal(draft.payee, 'lunch');
    assert.equal(draft.occurredAt.getDate(), 19);
  });

  it('prefers the longer account name it contains', () => {
    const draft = parsePhrase('fuel 60 cash back card', { accounts, now });
    assert.equal(draft.accountID, card.id);
  });

  it('lets "day before yesterday" beat "yesterday"', () => {
    const draft = parsePhrase('coffee 4 day before yesterday', { accounts, now });
    assert.equal(draft.occurredAt.getDate(), 18);
  });

  it('resolves a weekday to its most recent occurrence', () => {
    const draft = parsePhrase('groceries 42.10 wednesday', { accounts, now });
    assert.equal(draft.occurredAt.getDay(), 3);
    assert.equal(draft.occurredAt.getDate(), 18);
  });

  it('switches to income and matches an income category', () => {
    const draft = parsePhrase('salary 5000 today', { accounts, now });
    assert.equal(draft.kind, 'income');
    assert.equal(draft.amount, '5000');
    assert.equal(draft.categoryID, salary.id);
  });

  it('does not mistake an explicit date for the amount', () => {
    const draft = parsePhrase('dinner 88.00 on 15/03/2026', { accounts, now });
    assert.equal(draft.amount, '88.00');
    assert.equal(draft.occurredAt.getMonth(), 2);
    assert.equal(draft.occurredAt.getDate(), 15);
    assert.equal(draft.payee, 'dinner');
  });

  it('keeps the time of day rather than snapping to midnight', () => {
    const draft = parsePhrase('taxi 20 on 2026-03-15', { accounts, now });
    assert.equal(draft.occurredAt.getHours(), 14);
    assert.equal(draft.occurredAt.getMinutes(), 30);
  });

  it('parses a Chinese phrase', () => {
    const yuan = ledgerAccount({ name: '现金', kind: 'asset', accountType: 'cash' });
    const draft = parsePhrase('昨天 现金 午餐 12.50', { accounts: [...accounts, yuan], now });
    assert.equal(draft.amount, '12.50');
    assert.equal(draft.accountID, yuan.id);
    assert.equal(draft.payee, '午餐');
    assert.equal(draft.occurredAt.getDate(), 19);
  });

  it('reports an empty draft rather than guessing', () => {
    assert.ok(parsePhrase('???', { accounts, now }).isEmpty);
  });
});

describe('category suggestion', () => {
  it('picks the category used most often for that payee', () => {
    const coffee = ledgerAccount({ name: 'Coffee', kind: 'expense' });
    const groceries = ledgerAccount({ name: 'Groceries', kind: 'expense' });
    const bank = ledgerAccount({ name: 'Bank', kind: 'asset', currency: 'SGD' });
    const spend = (categoryID, payee) => TransactionFactory.expense({
      amount: Money.parse('6', 'SGD'), accountID: bank.id, categoryID, payee
    });

    const suggestion = suggestCategory('Starbucks', {
      entries: [
        spend(coffee.id, 'Starbucks'),
        spend(coffee.id, 'starbucks orchard'),
        spend(groceries.id, 'Starbucks')
      ],
      accounts: [bank, coffee, groceries]
    });
    assert.equal(suggestion, coffee.id);
  });

  it('suggests nothing for an unseen payee', () => {
    const coffee = ledgerAccount({ name: 'Coffee', kind: 'expense' });
    const bank = ledgerAccount({ name: 'Bank', kind: 'asset', currency: 'SGD' });
    const suggestion = suggestCategory('Hardware Store', {
      entries: [TransactionFactory.expense({
        amount: Money.parse('6', 'SGD'), accountID: bank.id,
        categoryID: coffee.id, payee: 'Starbucks'
      })],
      accounts: [bank, coffee]
    });
    assert.equal(suggestion, null);
  });
});
