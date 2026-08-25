// Modal sheets: logging, accounts, categories, limits, and destructive actions.

import { Money, TransactionFactory, currencyCode, ledgerAccount } from './domain.js';
import { BudgetTree } from './budget.js';
import { parsePhrase, suggestCategory } from './parse.js';
import { rewrapVault, unlockVault, WrongPassphraseError } from './crypto.js';
import { COLLECTIONS, saveEnvelope } from './store.js';
import { t } from './i18n.js';
import { toLocalInputValue } from './format.js';
import {
  accountByID, button, card, expenseCategories, field, h, incomeCategories,
  invalidate, loadBook, muted, render, row, select, serializeEntry,
  serializeNode, state, userAccounts
} from './app.js';

function close() {
  state.sheet = null;
  render();
}

function sheet(title, ...body) {
  return h('div', {
    class: 'scrim',
    onclick: (event) => { if (event.target === event.currentTarget) close(); }
  },
    h('div', { class: 'sheet', role: 'dialog', 'aria-modal': 'true', 'aria-label': title },
      h('header', { class: 'sheet-head' },
        h('h2', { text: title }),
        h('button', { class: 'icon', type: 'button', 'aria-label': t('action.close'), onclick: close }, '✕')),
      h('div', { class: 'sheet-body' }, ...body))
  );
}

function errorLine() {
  return h('p', { class: 'error' });
}

async function guard(error, work) {
  error.textContent = '';
  try {
    await work();
  } catch (failure) {
    error.textContent = failure.message;
  }
}

// ------------------------------------------------------------------- log

function logSheet() {
  const accounts = userAccounts();
  const error = errorLine();

  let kind = 'expense';
  let accountID = accounts[0]?.id ?? null;
  let destinationID = accounts.find((a) => a.id !== accountID)?.id ?? null;
  let categoryID = null;

  const phrase = h('input', { type: 'text', placeholder: t('log.smart_placeholder') });
  const amount = h('input', { type: 'text', inputmode: 'decimal', placeholder: '0.00' });
  const received = h('input', { type: 'text', inputmode: 'decimal', placeholder: '0.00' });
  const when = h('input', { type: 'datetime-local', value: toLocalInputValue(new Date()) });
  const payee = h('input', { type: 'text' });
  const note = h('input', { type: 'text' });
  const body = h('div', { class: 'stack-tight' });

  const categoriesFor = () => (kind === 'income' ? incomeCategories() : expenseCategories());

  function ensureCategory() {
    const options = categoriesFor();
    if (!options.some((option) => option.id === categoryID)) {
      categoryID = options.find((option) => option.parentID)?.id ?? options[0]?.id ?? null;
    }
  }

  function applyDraft(draft) {
    if (draft.isEmpty) {
      error.textContent = t('log.smart_nothing');
      return;
    }
    error.textContent = '';
    kind = draft.kind === 'income' ? 'income' : 'expense';
    ensureCategory();
    if (draft.amount) amount.value = draft.amount;
    if (draft.occurredAt) when.value = toLocalInputValue(draft.occurredAt);
    if (draft.payee) payee.value = draft.payee;
    if (draft.accountID) accountID = draft.accountID;
    if (draft.categoryID) categoryID = draft.categoryID;
    else if (draft.payee) {
      const learned = suggestCategory(draft.payee, {
        entries: state.entries,
        accounts: state.accounts,
        kind: draft.kind === 'income' ? 'income' : 'expense'
      });
      if (learned) categoryID = learned;
    }
    draw();
  }

  function draw() {
    ensureCategory();
    const sourceCurrency = accountByID(accountID)?.currency ?? null;
    const destinationCurrency = accountByID(destinationID)?.currency ?? null;
    const isForeign = kind === 'transfer' && sourceCurrency && destinationCurrency
      && sourceCurrency !== destinationCurrency;

    body.replaceChildren(
      h('div', { class: 'segmented' }, ['expense', 'income', 'transfer'].map((value) =>
        h('button', {
          type: 'button',
          class: `segment ${kind === value ? 'active' : ''}`.trim(),
          onclick: () => { kind = value; draw(); }
        }, t(`log.${value}`)))),

      kind === 'transfer' ? null : card(
        h('p', { class: 'card-label', text: t('log.smart') }),
        row(phrase, button(t('log.smart_fill'), () => applyDraft(parsePhrase(phrase.value, {
          accounts: state.accounts
        })))),
        h('p', { class: 'tiny', text: t('log.smart_footer') })),

      field(t('log.amount'), amount),
      field(kind === 'transfer' ? t('log.from') : t('log.account'), select(
        accounts.map((account) => ({ value: account.id, label: account.name })),
        accountID,
        (value) => { accountID = value; draw(); })),

      kind === 'transfer'
        ? field(t('log.to'), select(
            accounts.filter((a) => a.id !== accountID).map((a) => ({ value: a.id, label: a.name })),
            destinationID,
            (value) => { destinationID = value; draw(); }))
        : field(t('log.category'), select(
            categoriesFor().map((c) => ({ value: c.id, label: c.name })),
            categoryID,
            (value) => { categoryID = value; })),

      isForeign ? field(`${t('log.received')} (${destinationCurrency})`, received) : null,
      field(t('log.date'), when),
      kind === 'transfer' ? null : field(t('log.payee'), payee),
      field(t('log.note'), note),
      error,
      accounts.length === 0 ? muted(t('log.no_accounts')) : null,
      kind === 'transfer' && accounts.length < 2 ? muted(t('log.need_two')) : null,
      h('button', {
        class: 'btn primary wide',
        type: 'button',
        onclick: () => guard(error, save)
      }, t('action.save'))
    );
  }

  async function save() {
    const source = accountByID(accountID);
    if (!source) throw new Error(t('log.no_accounts'));
    const currency = source.currency ?? state.profile.baseCurrency;
    const value = Money.parse(amount.value, currency);
    if (value.units <= 0n) throw new Error('Amount must be positive.');
    const occurredAt = when.value ? new Date(when.value) : new Date();

    let entry;
    if (kind === 'transfer') {
      const destination = accountByID(destinationID);
      if (!destination) throw new Error(t('log.need_two'));
      if (destination.currency && destination.currency !== currency) {
        const other = Money.parse(received.value, destination.currency);
        if (other.units <= 0n) throw new Error('Amount must be positive.');
        entry = TransactionFactory.foreignCurrencyTransfer({
          sourceAmount: value,
          destinationAmount: other,
          sourceAccountID: source.id,
          destinationAccountID: destination.id,
          sourceTradingAccountID: await tradingAccount(currency),
          destinationTradingAccountID: await tradingAccount(destination.currency),
          occurredAt,
          note: note.value
        });
      } else {
        entry = TransactionFactory.transfer({
          amount: value,
          sourceAccountID: source.id,
          destinationAccountID: destination.id,
          occurredAt,
          note: note.value
        });
      }
    } else {
      if (!categoryID) throw new Error('Choose a category.');
      const build = kind === 'income' ? TransactionFactory.income : TransactionFactory.expense;
      entry = build({
        amount: value,
        accountID: source.id,
        categoryID,
        occurredAt,
        payee: payee.value,
        note: note.value
      });
    }

    await state.store.put(COLLECTIONS.journalEntries, entry.id, serializeEntry(entry));
    state.entries = [entry, ...state.entries].sort((a, b) => b.occurredAt - a.occurredAt);
    invalidate();
    close();
  }

  draw();
  return sheet(t('log.title'), body);
}

/** Per-currency clearing account, created on first use like the iOS app. */
async function tradingAccount(currency) {
  const existing = state.accounts.find(
    (account) => account.kind === 'trading' && account.currency === currency
  );
  if (existing) return existing.id;

  const created = ledgerAccount({
    name: `${t('account.fx_clearing')} ${currency}`,
    kind: 'trading',
    currency
  });
  await state.store.put(COLLECTIONS.accounts, created.id, created);
  state.accounts = [...state.accounts, created];
  invalidate();
  return created.id;
}

// -------------------------------------------------------------- accounts

function addAccountSheet() {
  const name = h('input', { type: 'text', maxlength: '60' });
  const currency = h('input', { type: 'text', value: state.profile.baseCurrency, maxlength: '8' });
  const opening = h('input', { type: 'text', inputmode: 'decimal', placeholder: '0' });
  const error = errorLine();
  let accountType = 'bank';

  async function save() {
    const code = currencyCode(currency.value);
    const isLiability = accountType === 'credit_card' || accountType === 'loan';
    const account = ledgerAccount({
      name: name.value,
      kind: isLiability ? 'liability' : 'asset',
      currency: code,
      accountType
    });

    const writes = [{ collection: COLLECTIONS.accounts, id: account.id, value: account }];
    const added = [account];
    let entry = null;

    const startingText = opening.value.trim();
    if (startingText) {
      const starting = Money.parse(startingText, code);
      if (starting.isNegative) throw new Error('Starting balance cannot be negative.');
      if (!starting.isZero) {
        let equity = state.accounts.find((a) => a.systemRole === 'opening_balances');
        if (!equity) {
          equity = ledgerAccount({
            name: t('account.opening_balances'), kind: 'equity', systemRole: 'opening_balances'
          });
          writes.push({ collection: COLLECTIONS.accounts, id: equity.id, value: equity });
          added.push(equity);
        }
        entry = TransactionFactory.balanceAdjustment({
          displayDelta: starting,
          accountID: account.id,
          equityAccountID: equity.id,
          accountIsLiability: isLiability,
          note: t('account.opening_note')
        });
        writes.push({
          collection: COLLECTIONS.journalEntries, id: entry.id, value: serializeEntry(entry)
        });
      }
    }

    await state.store.write(writes);
    state.accounts = [...state.accounts, ...added];
    if (entry) state.entries = [entry, ...state.entries];
    invalidate();
    close();
  }

  return sheet(t('accounts.add'),
    field(t('accounts.name'), name),
    field(t('accounts.type'), select(
      ['cash', 'bank', 'e_wallet', 'credit_card', 'loan', 'brokerage', 'investment', 'other']
        .map((value) => ({ value, label: t(`account.type.${value}`) })),
      accountType,
      (value) => { accountType = value; })),
    field(t('accounts.currency'), currency),
    field(t('accounts.starting'), opening),
    error,
    h('button', { class: 'btn primary wide', type: 'button', onclick: () => guard(error, save) },
      t('action.save'))
  );
}

// ------------------------------------------------------- categories, limits

function addCategorySheet() {
  const name = h('input', { type: 'text', maxlength: '60' });
  const error = errorLine();
  let parentID = '';

  async function save() {
    const category = ledgerAccount({
      name: name.value, kind: 'expense', parentID: parentID || null
    });
    const node = {
      id: category.id, parentID: category.parentID, name: category.name, limit: null
    };
    // Validate before writing, so an impossible hierarchy is never persisted.
    new BudgetTree(state.profile.baseCurrency, [...state.budgetNodes, node]);

    await state.store.write([
      { collection: COLLECTIONS.accounts, id: category.id, value: category },
      { collection: COLLECTIONS.budgetNodes, id: node.id, value: serializeNode(node) }
    ]);
    state.accounts = [...state.accounts, category];
    state.budgetNodes = [...state.budgetNodes, node];
    invalidate();
    close();
  }

  return sheet(t('plan.add_category'),
    field(t('plan.category_name'), name),
    field(t('plan.parent'), select(
      [{ value: '', label: t('plan.no_parent') },
        ...expenseCategories().map((c) => ({ value: c.id, label: c.name }))],
      parentID,
      (value) => { parentID = value; })),
    error,
    h('button', { class: 'btn primary wide', type: 'button', onclick: () => guard(error, save) },
      t('action.save'))
  );
}

function limitSheet(node) {
  const amount = h('input', {
    type: 'text', inputmode: 'decimal',
    value: node.limit ? node.limit.toString() : ''
  });
  const error = errorLine();

  async function save() {
    const text = amount.value.trim();
    const limit = text ? Money.parse(text, state.profile.baseCurrency) : null;
    if (limit?.isNegative) throw new Error('A limit cannot be negative.');

    const updated = { ...node, limit };
    const candidate = state.budgetNodes.map((item) => (item.id === node.id ? updated : item));
    new BudgetTree(state.profile.baseCurrency, candidate);

    await state.store.put(COLLECTIONS.budgetNodes, node.id, serializeNode(updated));
    state.budgetNodes = candidate;
    invalidate();
    close();
  }

  return sheet(node.name,
    field(t('plan.monthly_limit'), amount),
    h('p', { class: 'tiny', text: t('plan.blank_removes_limit') }),
    error,
    h('button', { class: 'btn primary wide', type: 'button', onclick: () => guard(error, save) },
      t('action.save'))
  );
}

// ------------------------------------------------------------ passphrase

function passphraseSheet() {
  const current = h('input', { type: 'password', autocomplete: 'current-password' });
  const next = h('input', { type: 'password', autocomplete: 'new-password' });
  const error = errorLine();

  async function save() {
    if (next.value.length < 8) throw new Error(t('setup.too_short'));
    try {
      const envelope = await rewrapVault(state.envelope, current.value, next.value);
      await saveEnvelope(state.db, envelope);
      state.envelope = envelope;
      close();
    } catch (failure) {
      throw failure instanceof WrongPassphraseError ? new Error(t('lock.wrong')) : failure;
    }
  }

  return sheet(t('accounts.change_passphrase'),
    field(t('accounts.current_passphrase'), current),
    field(t('accounts.new_passphrase'), next),
    muted(t('setup.detail')),
    error,
    h('button', { class: 'btn primary wide', type: 'button', onclick: () => guard(error, save) },
      t('action.save'))
  );
}

function eraseSheet() {
  const error = errorLine();
  return sheet(t('accounts.erase'),
    muted(t('accounts.erase_detail')),
    error,
    h('button', {
      class: 'btn danger wide', type: 'button',
      onclick: () => guard(error, async () => {
        await state.store.eraseEverything();
        state.envelope = null;
        state.store = null;
        state.profile = null;
        state.accounts = [];
        state.entries = [];
        state.budgetNodes = [];
        state.sheet = null;
        invalidate();
        state.phase = 'setup';
        render();
      })
    }, t('accounts.erase_confirm'))
  );
}

export function renderSheet(descriptor) {
  switch (descriptor.type) {
    case 'log': return logSheet();
    case 'addAccount': return addAccountSheet();
    case 'addCategory': return addCategorySheet();
    case 'limit': return limitSheet(descriptor.node);
    case 'passphrase': return passphraseSheet();
    case 'erase': return eraseSheet();
    default: return null;
  }
}
