import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { Money, TransactionFactory, ledgerAccount } from '../src/domain.js';
import { BudgetTree, budgetNode } from '../src/budget.js';
import {
  balancesByAccount, buildReport, displayBalance, periodInterval
} from '../src/report.js';

const sgd = 'SGD';
const usd = 'USD';
const at = (year, month, day, hour = 12) => new Date(year, month - 1, day, hour);

function book() {
  const bank = ledgerAccount({ name: 'Bank', kind: 'asset', currency: sgd, accountType: 'bank' });
  const card = ledgerAccount({ name: 'USD card', kind: 'liability', currency: usd, accountType: 'credit_card' });
  const salary = ledgerAccount({ name: 'Salary', kind: 'income' });
  const rent = ledgerAccount({ name: 'Rent', kind: 'expense' });
  const food = ledgerAccount({ name: 'Food', kind: 'expense' });
  return { bank, card, salary, rent, food, accounts: [bank, card, salary, rent, food] };
}

describe('period report', () => {
  it('keeps foreign spending instead of dropping it', () => {
    const { bank, card, salary, food, accounts } = book();
    const entries = [
      TransactionFactory.income({
        amount: Money.parse('4000', sgd), accountID: bank.id,
        categoryID: salary.id, occurredAt: at(2026, 3, 1)
      }),
      TransactionFactory.expense({
        amount: Money.parse('30', sgd), accountID: bank.id,
        categoryID: food.id, occurredAt: at(2026, 3, 5)
      }),
      TransactionFactory.expense({
        amount: Money.parse('45', usd), accountID: card.id,
        categoryID: food.id, occurredAt: at(2026, 3, 6)
      })
    ];

    const report = buildReport({
      interval: periodInterval('thisMonth', at(2026, 3, 15)),
      accounts, entries, baseCurrency: sgd
    });

    assert.equal(report.baseFlow.income.toString(), '4000');
    assert.equal(report.baseFlow.expense.toString(), '30');
    assert.equal(report.baseFlow.net.toString(), '3970');
    assert.ok(report.holdsUnconvertedActivity);
    assert.equal(report.foreignFlows.length, 1);
    assert.equal(report.foreignFlows[0].currency, usd);
    assert.equal(report.foreignFlows[0].expense.toString(), '45');
    assert.deepEqual(report.categorySpending.map((c) => c.amount.toString()), ['30']);
  });

  it('leaves transfers and reconciliations out of income and spending', () => {
    const { bank, food, accounts } = book();
    const wallet = ledgerAccount({ name: 'Wallet', kind: 'asset', currency: sgd });
    const equity = ledgerAccount({ name: 'Opening', kind: 'equity' });
    const entries = [
      TransactionFactory.transfer({
        amount: Money.parse('200', sgd), sourceAccountID: bank.id,
        destinationAccountID: wallet.id, occurredAt: at(2026, 3, 4)
      }),
      TransactionFactory.balanceAdjustment({
        displayDelta: Money.parse('75', sgd), accountID: bank.id,
        equityAccountID: equity.id, accountIsLiability: false,
        occurredAt: at(2026, 3, 7)
      }),
      TransactionFactory.expense({
        amount: Money.parse('18', sgd), accountID: wallet.id,
        categoryID: food.id, occurredAt: at(2026, 3, 8)
      })
    ];

    const report = buildReport({
      interval: periodInterval('thisMonth', at(2026, 3, 15)),
      accounts: [...accounts, wallet, equity], entries, baseCurrency: sgd
    });

    assert.equal(report.baseFlow.income.toString(), '0');
    assert.equal(report.baseFlow.expense.toString(), '18');
  });

  it('lets a refund reduce category spending', () => {
    const { bank, food, accounts } = book();
    const entries = [
      TransactionFactory.expense({
        amount: Money.parse('120', sgd), accountID: bank.id,
        categoryID: food.id, occurredAt: at(2026, 3, 2)
      }),
      TransactionFactory.refund({
        amount: Money.parse('40', sgd), accountID: bank.id,
        categoryID: food.id, occurredAt: at(2026, 3, 9)
      })
    ];
    const report = buildReport({
      interval: periodInterval('thisMonth', at(2026, 3, 15)),
      accounts, entries, baseCurrency: sgd
    });
    assert.equal(report.baseFlow.expense.toString(), '80');
  });

  it('counts midnight on the first in one month only', () => {
    const { bank, food, accounts } = book();
    const entries = [TransactionFactory.expense({
      amount: Money.parse('12', sgd), accountID: bank.id,
      categoryID: food.id, occurredAt: at(2026, 4, 1, 0)
    })];

    const march = buildReport({
      interval: periodInterval('thisMonth', at(2026, 3, 15)),
      accounts, entries, baseCurrency: sgd
    });
    const april = buildReport({
      interval: periodInterval('thisMonth', at(2026, 4, 15)),
      accounts, entries, baseCurrency: sgd
    });

    assert.equal(march.baseFlow.expense.toString(), '0');
    assert.equal(april.baseFlow.expense.toString(), '12');
  });

  it('draws quiet months in the trend series', () => {
    const { bank, food, accounts } = book();
    const entries = [TransactionFactory.expense({
      amount: Money.parse('60', sgd), accountID: bank.id,
      categoryID: food.id, occurredAt: at(2026, 4, 20)
    })];
    const now = at(2026, 6, 15);

    const report = buildReport({
      interval: periodInterval('thisMonth', now),
      trendInterval: periodInterval('sixMonths', now),
      accounts, entries, baseCurrency: sgd
    });

    assert.equal(report.monthlyFlows.length, 6);
    assert.deepEqual(
      report.monthlyFlows.map((flow) => flow.expense.toString()),
      ['0', '0', '0', '60', '0', '0']
    );
    assert.ok(report.isEmpty, 'June itself holds nothing');
  });

  it('derives readings from the same period the charts show', () => {
    const { bank, salary, rent, food, accounts } = book();
    const entries = [
      TransactionFactory.income({
        amount: Money.parse('5000', sgd), accountID: bank.id,
        categoryID: salary.id, occurredAt: at(2026, 3, 1)
      }),
      TransactionFactory.expense({
        amount: Money.parse('1500', sgd), accountID: bank.id,
        categoryID: rent.id, occurredAt: at(2026, 3, 2)
      }),
      TransactionFactory.expense({
        amount: Money.parse('500', sgd), accountID: bank.id,
        categoryID: food.id, occurredAt: at(2026, 3, 3)
      })
    ];
    const report = buildReport({
      interval: periodInterval('thisMonth', at(2026, 3, 15)),
      accounts, entries, baseCurrency: sgd
    });

    assert.equal(report.savingsRate, 0.6);
    assert.equal(report.largestCategory.category.name, 'Rent');
    assert.equal(report.largestCategory.share, 0.75);
    assert.deepEqual(report.categorySpending.map((c) => c.name), ['Rent', 'Food']);
  });

  it('has no savings rate without income', () => {
    const { bank, food, accounts } = book();
    const report = buildReport({
      interval: periodInterval('thisMonth', at(2026, 3, 15)),
      accounts,
      entries: [TransactionFactory.expense({
        amount: Money.parse('9', sgd), accountID: bank.id,
        categoryID: food.id, occurredAt: at(2026, 3, 3)
      })],
      baseCurrency: sgd
    });
    assert.equal(report.savingsRate, null);
    assert.ok(report.largestCategory);
  });

  it('aligns every period to whole months', () => {
    const now = at(2026, 6, 15);
    const thisMonth = periodInterval('thisMonth', now);
    const lastMonth = periodInterval('lastMonth', now);
    const sixMonths = periodInterval('sixMonths', now);
    const yearToDate = periodInterval('yearToDate', now);

    assert.deepEqual(thisMonth.start, new Date(2026, 5, 1));
    assert.deepEqual(lastMonth.start, new Date(2026, 4, 1));
    assert.deepEqual(lastMonth.end, thisMonth.start);
    assert.deepEqual(sixMonths.start, new Date(2026, 0, 1));
    assert.deepEqual(sixMonths.end, thisMonth.end);
    assert.deepEqual(yearToDate.start, new Date(2026, 0, 1));
  });
});

describe('balances', () => {
  it('uses user-facing signs for assets and liabilities', () => {
    const { bank, card, food, accounts } = book();
    const entries = [
      TransactionFactory.expense({
        amount: Money.parse('25', sgd), accountID: bank.id, categoryID: food.id
      }),
      TransactionFactory.expense({
        amount: Money.parse('40', usd), accountID: card.id, categoryID: food.id
      })
    ];
    const balances = balancesByAccount(entries);

    assert.equal(displayBalance(bank, balances).toString(), '-25');
    assert.equal(displayBalance(card, balances).toString(), '40');
    assert.equal(displayBalance(food, balances), null, 'a category has no currency');
    assert.equal(accounts.length, 5);
  });
});

describe('budget roll-up', () => {
  it('rolls descendant spending into every ancestor', () => {
    const essentials = { id: 'e', parentID: null, name: 'Essentials', limit: Money.parse('900', sgd) };
    const groceries = { id: 'g', parentID: 'e', name: 'Groceries', limit: Money.parse('400', sgd) };
    const tree = new BudgetTree(sgd, [essentials, groceries]);

    const progress = tree.progress(new Map([['g', Money.parse('250', sgd)]]));
    const byID = new Map(progress.map((item) => [item.node.id, item]));

    assert.equal(byID.get('g').spent.toString(), '250');
    assert.equal(byID.get('e').spent.toString(), '250', 'parent sees the child spend');
    assert.equal(byID.get('e').remaining.toString(), '650');
    assert.equal(byID.get('g').remaining.toString(), '150');
  });

  it('rejects a cycle rather than looping forever', () => {
    assert.throws(() => new BudgetTree(sgd, [
      budgetNode({ id: 'a', parentID: 'b', name: 'A' }),
      budgetNode({ id: 'b', parentID: 'a', name: 'B' })
    ]));
  });

  it('rejects a limit in the wrong currency', () => {
    assert.throws(() => new BudgetTree(sgd, [
      budgetNode({ id: 'a', name: 'A', limit: Money.parse('10', usd) })
    ]));
  });
});
