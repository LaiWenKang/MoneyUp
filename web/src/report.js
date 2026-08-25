// Single-pass period reporting, mirroring ReportBuilder.swift.
//
// Every currency is kept. Nothing outside the base currency is silently
// dropped, because MoneyUp holds no exchange rates and will not invent one.

import { Money } from './domain.js';

export const REPORT_PERIODS = [
  'thisMonth', 'lastMonth', 'threeMonths', 'sixMonths', 'twelveMonths', 'yearToDate'
];

const MONTH_SPAN = {
  thisMonth: 1,
  lastMonth: 1,
  threeMonths: 3,
  sixMonths: 6,
  twelveMonths: 12,
  yearToDate: 12
};

export function monthSpan(period) {
  return MONTH_SPAN[period] ?? 1;
}

function startOfMonth(date) {
  return new Date(date.getFullYear(), date.getMonth(), 1);
}

function addMonths(date, count) {
  return new Date(date.getFullYear(), date.getMonth() + count, 1);
}

/** Whole-month window for a period, so comparisons stay meaningful. */
export function periodInterval(period, now = new Date()) {
  const thisStart = startOfMonth(now);
  const thisEnd = addMonths(thisStart, 1);

  switch (period) {
    case 'thisMonth':
      return { start: thisStart, end: thisEnd };
    case 'lastMonth':
      return { start: addMonths(thisStart, -1), end: thisStart };
    case 'threeMonths':
      return { start: addMonths(thisStart, -2), end: thisEnd };
    case 'sixMonths':
      return { start: addMonths(thisStart, -5), end: thisEnd };
    case 'twelveMonths':
      return { start: addMonths(thisStart, -11), end: thisEnd };
    case 'yearToDate':
      return { start: new Date(now.getFullYear(), 0, 1), end: thisEnd };
    default:
      return { start: thisStart, end: thisEnd };
  }
}

/**
 * Half-open containment. Including the end instant would count a transaction
 * stamped at midnight on the first in two months at once.
 */
function contains(date, interval) {
  return date >= interval.start && date < interval.end;
}

function monthStarts(interval) {
  const months = [];
  let current = startOfMonth(interval.start);
  while (current < interval.end) {
    months.push(current);
    current = addMonths(current, 1);
  }
  return months;
}

/**
 * Builds headline totals, per-currency flows, category spending, and the
 * monthly series in one pass over the journal.
 */
export function buildReport({
  interval,
  trendInterval = null,
  accounts,
  entries,
  baseCurrency
}) {
  const trend = trendInterval ?? interval;
  const kinds = new Map();
  const names = new Map();
  for (const account of accounts) {
    kinds.set(account.id, account.kind);
    names.set(account.id, account.name);
  }

  const income = new Map();
  const expense = new Map();
  const categoryTotals = new Map();
  const monthlyIncome = new Map();
  const monthlyExpense = new Map();

  for (const entry of entries) {
    const inPeriod = contains(entry.occurredAt, interval);
    const inTrend = contains(entry.occurredAt, trend);
    if (!inPeriod && !inTrend) continue;
    const monthKey = inTrend ? startOfMonth(entry.occurredAt).getTime() : null;

    for (const item of entry.postings) {
      const kind = kinds.get(item.accountID);
      if (kind !== 'income' && kind !== 'expense') continue;

      const currency = item.money.currency;
      // Income accounts are credited, so their postings are negative.
      const units = kind === 'income' ? -item.money.units : item.money.units;

      if (inPeriod) {
        if (kind === 'income') {
          income.set(currency, (income.get(currency) ?? 0n) + units);
        } else {
          expense.set(currency, (expense.get(currency) ?? 0n) + units);
          if (currency === baseCurrency) {
            categoryTotals.set(
              item.accountID,
              (categoryTotals.get(item.accountID) ?? 0n) + units
            );
          }
        }
      }

      if (monthKey !== null && currency === baseCurrency) {
        const bucket = kind === 'income' ? monthlyIncome : monthlyExpense;
        bucket.set(monthKey, (bucket.get(monthKey) ?? 0n) + units);
      }
    }
  }

  const currencies = new Set([...income.keys(), ...expense.keys(), baseCurrency]);
  const flows = [...currencies].map((currency) => {
    const incomeUnits = income.get(currency) ?? 0n;
    const expenseUnits = expense.get(currency) ?? 0n;
    return {
      currency,
      income: new Money(incomeUnits, currency),
      expense: new Money(expenseUnits, currency),
      net: new Money(incomeUnits - expenseUnits, currency)
    };
  });

  const baseFlow = flows.find((flow) => flow.currency === baseCurrency);
  const foreignFlows = flows
    .filter((flow) => flow.currency !== baseCurrency)
    .filter((flow) => !(flow.income.isZero && flow.expense.isZero))
    .sort((a, b) => a.currency.localeCompare(b.currency));

  const categorySpending = [...categoryTotals]
    .map(([accountID, units]) => ({
      accountID,
      name: names.get(accountID) ?? '',
      amount: new Money(units, baseCurrency)
    }))
    .sort((a, b) => {
      if (a.amount.units === b.amount.units) return a.name.localeCompare(b.name);
      return a.amount.units > b.amount.units ? -1 : 1;
    });

  const monthlyFlows = monthStarts(trend).map((month) => {
    const key = month.getTime();
    const incomeUnits = monthlyIncome.get(key) ?? 0n;
    const expenseUnits = monthlyExpense.get(key) ?? 0n;
    return {
      month,
      income: new Money(incomeUnits, baseCurrency),
      expense: new Money(expenseUnits, baseCurrency),
      net: new Money(incomeUnits - expenseUnits, baseCurrency)
    };
  });

  return {
    interval,
    trendInterval: trend,
    baseCurrency,
    baseFlow,
    foreignFlows,
    categorySpending,
    monthlyFlows,

    get holdsUnconvertedActivity() {
      return foreignFlows.length > 0;
    },

    get isEmpty() {
      return baseFlow.income.isZero
        && baseFlow.expense.isZero
        && foreignFlows.length === 0;
    },

    /** Share of income not spent, or null when there was no income. */
    get savingsRate() {
      if (baseFlow.income.units <= 0n) return null;
      return Number(baseFlow.net.units) / Number(baseFlow.income.units);
    },

    /** Largest positive category and its share of base-currency spending. */
    get largestCategory() {
      if (baseFlow.expense.units <= 0n) return null;
      const top = categorySpending[0];
      if (!top || top.amount.units <= 0n) return null;
      return {
        category: top,
        share: Number(top.amount.units) / Number(baseFlow.expense.units)
      };
    },

    get monthOverMonth() {
      if (monthlyFlows.length < 2) return null;
      return {
        previous: monthlyFlows[monthlyFlows.length - 2],
        latest: monthlyFlows[monthlyFlows.length - 1]
      };
    }
  };
}

/** Every account balance, per currency, in one pass. */
export function balancesByAccount(entries) {
  const totals = new Map();
  for (const entry of entries) {
    for (const item of entry.postings) {
      let perCurrency = totals.get(item.accountID);
      if (!perCurrency) {
        perCurrency = new Map();
        totals.set(item.accountID, perCurrency);
      }
      const currency = item.money.currency;
      perCurrency.set(currency, (perCurrency.get(currency) ?? 0n) + item.money.units);
    }
  }
  return new Map(
    [...totals].map(([accountID, perCurrency]) => [
      accountID,
      new Map([...perCurrency].map(([currency, units]) => [
        currency,
        new Money(units, currency)
      ]))
    ])
  );
}

/** Balance in the account's own currency, using the user-facing sign. */
export function displayBalance(account, balances) {
  if (!account.currency) return null;
  const raw = balances.get(account.id)?.get(account.currency)
    ?? Money.zero(account.currency);
  return account.kind === 'liability' ? raw.negated : raw;
}
