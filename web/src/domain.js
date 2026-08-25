// Exact money, ledger accounts, and balanced journal entries.
//
// This mirrors Sources/MoneyUpCore in the iOS app. The invariants are the
// same on purpose: amounts are never binary floating point, and an entry that
// does not balance in every currency cannot be constructed.

/** Decimal places every amount is stored at internally. */
export const SCALE = 6;
const SCALE_FACTOR = 10n ** BigInt(SCALE);

export class MoneyError extends Error {}
export class ValidationError extends Error {}

const CURRENCY_PATTERN = /^[A-Z0-9]{3,8}$/;

/**
 * Normalized currency or asset code. Three to eight ASCII letters or digits,
 * matching the iOS rules so the same book is valid in both apps.
 */
export function currencyCode(raw) {
  const normalized = String(raw ?? '').trim().toUpperCase();
  if (!CURRENCY_PATTERN.test(normalized)) {
    throw new MoneyError(`Invalid currency or asset code: ${raw}`);
  }
  return normalized;
}

/**
 * An exact amount paired with a currency.
 *
 * Held as a scaled BigInt rather than a Number. Addition and subtraction —
 * everything the ledger does — are therefore exact, and no rounding drift can
 * accumulate across a book.
 */
export class Money {
  #units;
  #currency;

  constructor(units, currency) {
    if (typeof units !== 'bigint') {
      throw new MoneyError('Money requires an exact integer amount.');
    }
    this.#units = units;
    this.#currency = currencyCode(currency);
    Object.freeze(this);
  }

  static zero(currency) {
    return new Money(0n, currency);
  }

  /** Parses "12.50", "1,234.56", "-8", rejecting anything else. */
  static parse(text, currency) {
    const cleaned = String(text ?? '').trim().replace(/,/g, '');
    const match = /^(-?)(\d*)(?:\.(\d+))?$/.exec(cleaned);
    if (!match || (match[2] === '' && match[3] === undefined)) {
      throw new MoneyError(`Not a number: ${text}`);
    }
    const [, sign, whole, fraction = ''] = match;
    if (fraction.length > SCALE) {
      throw new MoneyError(`More than ${SCALE} decimal places: ${text}`);
    }
    const padded = fraction.padEnd(SCALE, '0');
    const units = BigInt((whole || '0') + padded);
    return new Money(sign === '-' ? -units : units, currency);
  }

  get units() {
    return this.#units;
  }

  get currency() {
    return this.#currency;
  }

  get isZero() {
    return this.#units === 0n;
  }

  get isNegative() {
    return this.#units < 0n;
  }

  get negated() {
    return new Money(-this.#units, this.#currency);
  }

  #requireSameCurrency(other) {
    if (this.#currency !== other.currency) {
      throw new MoneyError(
        `Currency mismatch: expected ${this.#currency}, got ${other.currency}`
      );
    }
  }

  add(other) {
    this.#requireSameCurrency(other);
    return new Money(this.#units + other.units, this.#currency);
  }

  subtract(other) {
    this.#requireSameCurrency(other);
    return new Money(this.#units - other.units, this.#currency);
  }

  compare(other) {
    this.#requireSameCurrency(other);
    if (this.#units < other.units) return -1;
    return this.#units > other.units ? 1 : 0;
  }

  equals(other) {
    return other instanceof Money
      && this.#currency === other.currency
      && this.#units === other.units;
  }

  /**
   * A Number for geometry and ratios only — chart widths, progress fractions.
   * Never round-trip a stored amount through this.
   */
  toNumber() {
    return Number(this.#units) / Number(SCALE_FACTOR);
  }

  /** Plain decimal string, exact, for export and serialization. */
  toString() {
    const negative = this.#units < 0n;
    const digits = (negative ? -this.#units : this.#units)
      .toString()
      .padStart(SCALE + 1, '0');
    const whole = digits.slice(0, -SCALE);
    const fraction = digits.slice(-SCALE).replace(/0+$/, '');
    return `${negative ? '-' : ''}${whole}${fraction ? `.${fraction}` : ''}`;
  }

  toJSON() {
    return { amount: this.toString(), currency: this.#currency };
  }

  static fromJSON(value) {
    return Money.parse(value.amount, value.currency);
  }
}

export const ACCOUNT_KINDS = ['asset', 'liability', 'income', 'expense', 'equity', 'trading'];
export const ACCOUNT_TYPES = [
  'cash', 'bank', 'e_wallet', 'credit_card', 'loan', 'brokerage', 'investment', 'other'
];

export function newID() {
  return globalThis.crypto.randomUUID();
}

/**
 * The accounting account behind a user-facing account, category, or
 * foreign-exchange clearing account.
 */
export function ledgerAccount({
  id = newID(),
  name,
  kind,
  currency = null,
  accountType = null,
  systemRole = null,
  parentID = null,
  isArchived = false
}) {
  const trimmed = String(name ?? '').trim();
  if (!trimmed) throw new ValidationError('An account needs a name.');
  if (!ACCOUNT_KINDS.includes(kind)) {
    throw new ValidationError(`Unknown account kind: ${kind}`);
  }
  return {
    id,
    name: trimmed,
    kind,
    currency: currency === null ? null : currencyCode(currency),
    accountType,
    systemRole,
    parentID,
    isArchived
  };
}

export function posting({ id = newID(), accountID, money, memo = null }) {
  if (!(money instanceof Money)) {
    throw new ValidationError('A posting needs a Money amount.');
  }
  return { id, accountID, money, memo };
}

export const ENTRY_KINDS = ['expense', 'income', 'transfer', 'adjustment', 'investment'];

/**
 * An immutable, balanced financial event.
 *
 * Postings must sum to exactly zero in every currency independently. A
 * foreign-currency transfer balances through two trading postings rather than
 * by applying a rate, so no exchange rate is ever invented.
 */
export function journalEntry({
  id = newID(),
  kind,
  occurredAt = new Date(),
  createdAt = new Date(),
  payee = null,
  note = null,
  postings
}) {
  if (!ENTRY_KINDS.includes(kind)) {
    throw new ValidationError(`Unknown entry kind: ${kind}`);
  }
  if (!Array.isArray(postings) || postings.length < 2) {
    throw new ValidationError('An entry needs at least two postings.');
  }

  const seen = new Set();
  const residual = new Map();
  for (const item of postings) {
    if (seen.has(item.id)) {
      throw new ValidationError(`Duplicate posting id: ${item.id}`);
    }
    seen.add(item.id);
    if (item.money.isZero) {
      throw new ValidationError(`Posting ${item.id} moves nothing.`);
    }
    const currency = item.money.currency;
    residual.set(currency, (residual.get(currency) ?? 0n) + item.money.units);
  }
  for (const [currency, total] of residual) {
    if (total !== 0n) {
      throw new ValidationError(
        `Entry does not balance in ${currency}: residual ${total}`
      );
    }
  }

  return {
    id,
    kind,
    occurredAt: new Date(occurredAt),
    createdAt: new Date(createdAt),
    payee: normalizeText(payee),
    note: normalizeText(note),
    postings
  };
}

function normalizeText(value) {
  if (value === null || value === undefined) return null;
  const trimmed = String(value).trim();
  return trimmed === '' ? null : trimmed;
}

function requirePositive(money) {
  if (money.units <= 0n) {
    throw new ValidationError('Amount must be positive.');
  }
}

/**
 * Balanced entries for the actions people actually take, keeping the
 * accounting out of the UI layer.
 */
export const TransactionFactory = {
  expense({ amount, accountID, categoryID, occurredAt, payee, note }) {
    requirePositive(amount);
    return journalEntry({
      kind: 'expense',
      occurredAt,
      payee,
      note,
      postings: [
        posting({ accountID: categoryID, money: amount }),
        posting({ accountID, money: amount.negated })
      ]
    });
  },

  income({ amount, accountID, categoryID, occurredAt, payee, note }) {
    requirePositive(amount);
    return journalEntry({
      kind: 'income',
      occurredAt,
      payee,
      note,
      postings: [
        posting({ accountID, money: amount }),
        posting({ accountID: categoryID, money: amount.negated })
      ]
    });
  },

  transfer({ amount, sourceAccountID, destinationAccountID, occurredAt, note }) {
    requirePositive(amount);
    if (sourceAccountID === destinationAccountID) {
      throw new ValidationError('Transfer accounts must differ.');
    }
    return journalEntry({
      kind: 'transfer',
      occurredAt,
      note,
      postings: [
        posting({ accountID: sourceAccountID, money: amount.negated }),
        posting({ accountID: destinationAccountID, money: amount })
      ]
    });
  },

  foreignCurrencyTransfer({
    sourceAmount,
    destinationAmount,
    sourceAccountID,
    destinationAccountID,
    sourceTradingAccountID,
    destinationTradingAccountID,
    occurredAt,
    note
  }) {
    requirePositive(sourceAmount);
    requirePositive(destinationAmount);
    if (sourceAccountID === destinationAccountID) {
      throw new ValidationError('Transfer accounts must differ.');
    }
    return journalEntry({
      kind: 'transfer',
      occurredAt,
      note,
      postings: [
        posting({ accountID: sourceAccountID, money: sourceAmount.negated }),
        posting({ accountID: sourceTradingAccountID, money: sourceAmount }),
        posting({
          accountID: destinationTradingAccountID,
          money: destinationAmount.negated
        }),
        posting({ accountID: destinationAccountID, money: destinationAmount })
      ]
    });
  },

  refund({ amount, accountID, categoryID, occurredAt, payee, note }) {
    requirePositive(amount);
    return journalEntry({
      kind: 'expense',
      occurredAt,
      payee,
      note,
      postings: [
        posting({ accountID: categoryID, money: amount.negated }),
        posting({ accountID, money: amount })
      ]
    });
  },

  /**
   * Records an opening balance or later reconciliation without treating it as
   * income or spending. `displayDelta` uses the user-facing sign: positive
   * increases cash, and also increases debt on a liability.
   */
  balanceAdjustment({
    displayDelta,
    accountID,
    equityAccountID,
    accountIsLiability,
    occurredAt,
    note
  }) {
    if (displayDelta.isZero) {
      throw new ValidationError('Adjustment must move something.');
    }
    const ledgerDelta = accountIsLiability ? displayDelta.negated : displayDelta;
    return journalEntry({
      kind: 'adjustment',
      occurredAt,
      note,
      postings: [
        posting({ accountID, money: ledgerDelta }),
        posting({ accountID: equityAccountID, money: ledgerDelta.negated })
      ]
    });
  }
};
