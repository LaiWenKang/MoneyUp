// MoneyUp for the browser: state, screens, and rendering.
//
// The domain, budget, report, and parsing modules are ports of MoneyUpCore
// and carry the same invariants. This file is only the shell around them.

import {
  Money, TransactionFactory, currencyCode, ledgerAccount, newID
} from './domain.js';
import { BudgetTree } from './budget.js';
import { balancesByAccount, buildReport, displayBalance, monthSpan, periodInterval, REPORT_PERIODS } from './report.js';
import { parsePhrase, suggestCategory } from './parse.js';
import { createVault, rewrapVault, unlockVault, WrongPassphraseError } from './crypto.js';
import { COLLECTIONS, EncryptedStore, loadEnvelope, openDatabase, saveEnvelope } from './store.js';
import { availableLanguages, language, setLanguage, t } from './i18n.js';
import {
  formatDate, formatMoney, formatMonth, formatPercent, monthElapsed, toLocalInputValue
} from './format.js';
import { exportCSV } from './csv.js';

export const APP_VERSION = '0.2.0';

const state = {
  phase: 'loading',
  db: null,
  store: null,
  envelope: null,
  profile: null,
  accounts: [],
  entries: [],
  budgetNodes: [],
  tab: 'today',
  period: 'thisMonth',
  sheet: null,
  message: null,
  busy: false
};

let derivedRevision = -1;
let revision = 0;
let cachedBalances = null;
const cachedReports = new Map();

function invalidate() {
  revision += 1;
}

function balances() {
  if (derivedRevision !== revision) {
    cachedBalances = null;
    cachedReports.clear();
    derivedRevision = revision;
  }
  cachedBalances ??= balancesByAccount(state.entries);
  return cachedBalances;
}

function report(period = state.period) {
  balances();
  if (cachedReports.has(period)) return cachedReports.get(period);
  if (!state.profile) return null;

  const now = new Date();
  const interval = periodInterval(period, now);
  const trend = monthSpan(period) >= 6 ? interval : periodInterval('sixMonths', now);
  const built = buildReport({
    interval,
    trendInterval: trend,
    accounts: state.accounts,
    entries: state.entries,
    baseCurrency: state.profile.baseCurrency
  });
  cachedReports.set(period, built);
  return built;
}

// ---------------------------------------------------------------- DOM helper

/** Builds an element. Text always goes through textContent, never innerHTML. */
function h(tag, props = {}, ...children) {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(props ?? {})) {
    if (value === null || value === undefined || value === false) continue;
    if (key === 'class') node.className = value;
    else if (key === 'text') node.textContent = value;
    else if (key === 'html') node.innerHTML = value;
    else if (key.startsWith('on')) node.addEventListener(key.slice(2), value);
    else if (key === 'style' && typeof value === 'object') Object.assign(node.style, value);
    else node.setAttribute(key, value === true ? '' : value);
  }
  for (const child of children.flat()) {
    if (child === null || child === undefined || child === false) continue;
    node.append(child instanceof Node ? child : document.createTextNode(String(child)));
  }
  return node;
}

const card = (...children) => h('section', { class: 'card' }, ...children);
const row = (...children) => h('div', { class: 'row' }, ...children);
const muted = (text) => h('p', { class: 'muted', text });

function field(labelText, control) {
  return h('label', { class: 'field' }, h('span', { class: 'field-label', text: labelText }), control);
}

function select(options, value, onChange) {
  const node = h('select', { onchange: (event) => onChange(event.target.value) });
  for (const option of options) {
    node.append(h('option', { value: option.value, selected: option.value === value }, option.label));
  }
  return node;
}

function button(text, onClick, variant = '') {
  return h('button', { class: `btn ${variant}`.trim(), onclick: onClick, type: 'button' }, text);
}

// ------------------------------------------------------------------- helpers

const userAccounts = () => state.accounts.filter(
  (a) => (a.kind === 'asset' || a.kind === 'liability') && !a.isArchived
);
const expenseCategories = () => state.accounts.filter((a) => a.kind === 'expense' && !a.isArchived);
const incomeCategories = () => state.accounts.filter((a) => a.kind === 'income' && !a.isArchived);
const accountByID = (id) => state.accounts.find((a) => a.id === id) ?? null;

function budgetProgressThisMonth() {
  if (!state.profile) return [];
  const current = report('thisMonth');
  if (!current) return [];
  const direct = new Map(current.categorySpending.map((c) => [c.accountID, c.amount]));
  try {
    return new BudgetTree(state.profile.baseCurrency, state.budgetNodes).progress(direct);
  } catch {
    return [];
  }
}

function reviveEntry(raw) {
  return {
    ...raw,
    occurredAt: new Date(raw.occurredAt),
    createdAt: new Date(raw.createdAt),
    postings: raw.postings.map((item) => ({ ...item, money: Money.fromJSON(item.money) }))
  };
}

const serializeEntry = (entry) => ({
  ...entry,
  occurredAt: entry.occurredAt.toISOString(),
  createdAt: entry.createdAt.toISOString(),
  postings: entry.postings.map((item) => ({ ...item, money: item.money.toJSON() }))
});

const reviveNode = (raw) => ({ ...raw, limit: raw.limit ? Money.fromJSON(raw.limit) : null });
const serializeNode = (node) => ({ ...node, limit: node.limit ? node.limit.toJSON() : null });

async function loadBook() {
  const [profile, accounts, entries, nodes] = await Promise.all([
    state.store.get(COLLECTIONS.profile, 'primary'),
    state.store.all(COLLECTIONS.accounts),
    state.store.all(COLLECTIONS.journalEntries),
    state.store.all(COLLECTIONS.budgetNodes)
  ]);
  state.profile = profile;
  state.accounts = accounts;
  state.entries = entries.map(reviveEntry).sort((a, b) => b.occurredAt - a.occurredAt);
  state.budgetNodes = nodes.map(reviveNode);
  invalidate();
  state.phase = profile ? 'ready' : 'onboarding';
}

function lock() {
  state.store = null;
  state.profile = null;
  state.accounts = [];
  state.entries = [];
  state.budgetNodes = [];
  state.sheet = null;
  invalidate();
  state.phase = 'locked';
  render();
}

// ------------------------------------------------------------------- screens

function passphraseScreen() {
  const isSetup = state.phase === 'setup';
  const first = h('input', { type: 'password', autocomplete: 'current-password' });
  const second = isSetup ? h('input', { type: 'password', autocomplete: 'new-password' }) : null;
  const error = h('p', { class: 'error' });

  async function submit() {
    error.textContent = '';
    const passphrase = first.value;
    if (isSetup) {
      if (passphrase.length < 8) { error.textContent = t('setup.too_short'); return; }
      if (passphrase !== second.value) { error.textContent = t('setup.mismatch'); return; }
    }
    state.busy = true;
    render();
    try {
      if (isSetup) {
        const { envelope, dataKey } = await createVault(passphrase);
        await saveEnvelope(state.db, envelope);
        state.envelope = envelope;
        state.store = new EncryptedStore(state.db, dataKey);
        state.phase = 'onboarding';
      } else {
        const dataKey = await unlockVault(state.envelope, passphrase);
        state.store = new EncryptedStore(state.db, dataKey);
        await loadBook();
      }
    } catch (failure) {
      state.phase = isSetup ? 'setup' : 'locked';
      error.textContent = failure instanceof WrongPassphraseError
        ? t('lock.wrong')
        : failure.message;
    } finally {
      state.busy = false;
      render();
      if (error.textContent) {
        document.querySelector('.error').textContent = error.textContent;
      }
    }
  }

  const form = h('form', {
    class: 'gate',
    onsubmit: (event) => { event.preventDefault(); submit(); }
  },
    h('div', { class: 'brand' }, h('div', { class: 'mark' }), h('h1', { text: t('app.name') })),
    h('h2', { text: isSetup ? t('setup.title') : t('lock.title') }),
    muted(isSetup ? t('setup.detail') : t('lock.detail')),
    field(t('setup.passphrase'), first),
    second ? field(t('setup.confirm'), second) : null,
    error,
    h('button', {
      class: 'btn primary wide',
      type: 'submit',
      disabled: state.busy
    }, state.busy ? t('setup.working') : (isSetup ? t('setup.create') : t('lock.unlock')))
  );
  queueMicrotask(() => first.focus());
  return form;
}

function onboardingScreen() {
  const name = h('input', { type: 'text', value: 'Bank', maxlength: '60' });
  const currency = h('input', { type: 'text', value: 'SGD', maxlength: '8' });
  const balance = h('input', { type: 'text', inputmode: 'decimal', placeholder: '0' });
  const error = h('p', { class: 'error' });
  let accountType = 'bank';

  async function start() {
    error.textContent = '';
    try {
      const base = currencyCode(currency.value);
      const opening = balance.value.trim() ? Money.parse(balance.value, base) : null;
      if (opening?.isNegative) throw new Error('Starting balance cannot be negative.');
      await createBook({ base, name: name.value, accountType, opening });
    } catch (failure) {
      error.textContent = failure.message;
    }
  }

  return h('form', {
    class: 'gate',
    onsubmit: (event) => { event.preventDefault(); start(); }
  },
    h('h2', { text: t('onboarding.title') }),
    field(t('onboarding.currency'), currency),
    field(t('onboarding.account_name'), name),
    field(t('onboarding.account_type'), select(
      ['cash', 'bank', 'e_wallet', 'credit_card', 'loan', 'other']
        .map((value) => ({ value, label: t(`account.type.${value}`) })),
      accountType,
      (value) => { accountType = value; }
    )),
    field(t('onboarding.starting'), balance),
    error,
    h('button', { class: 'btn primary wide', type: 'submit' }, t('onboarding.start'))
  );
}

async function createBook({ base, name, accountType, opening }) {
  const isLiability = accountType === 'credit_card' || accountType === 'loan';
  const main = ledgerAccount({
    name: name.trim() || 'Bank',
    kind: isLiability ? 'liability' : 'asset',
    currency: base,
    accountType
  });
  const equity = ledgerAccount({
    name: t('account.opening_balances'), kind: 'equity', systemRole: 'opening_balances'
  });

  const makeCategory = (key, parentID = null) =>
    ledgerAccount({ name: t(`category.${key}`), kind: 'expense', parentID });

  const essentials = makeCategory('essentials');
  const housing = makeCategory('housing');
  const lifestyle = makeCategory('lifestyle');
  const expenses = [
    essentials,
    makeCategory('food', essentials.id),
    makeCategory('transport', essentials.id),
    housing,
    makeCategory('rent', housing.id),
    makeCategory('utilities', housing.id),
    lifestyle,
    makeCategory('shopping', lifestyle.id),
    makeCategory('entertainment', lifestyle.id)
  ];
  const incomes = [
    ledgerAccount({ name: t('category.salary'), kind: 'income' }),
    ledgerAccount({ name: t('category.other_income'), kind: 'income' })
  ];
  const accounts = [main, equity, ...expenses, ...incomes];
  const nodes = expenses.map((account) => ({
    id: account.id, parentID: account.parentID, name: account.name, limit: null
  }));

  const writes = [
    { collection: COLLECTIONS.profile, id: 'primary', value: { baseCurrency: base, createdAt: new Date().toISOString() } },
    ...accounts.map((account) => ({ collection: COLLECTIONS.accounts, id: account.id, value: account })),
    ...nodes.map((node) => ({ collection: COLLECTIONS.budgetNodes, id: node.id, value: serializeNode(node) }))
  ];

  let openingEntry = null;
  if (opening && !opening.isZero) {
    openingEntry = TransactionFactory.balanceAdjustment({
      displayDelta: opening,
      accountID: main.id,
      equityAccountID: equity.id,
      accountIsLiability: isLiability,
      note: t('account.opening_note')
    });
    writes.push({
      collection: COLLECTIONS.journalEntries,
      id: openingEntry.id,
      value: serializeEntry(openingEntry)
    });
  }

  await state.store.write(writes);
  await loadBook();
  render();
}

// ------------------------------------------------------------------- today

function todayScreen() {
  const base = state.profile.baseCurrency;
  const spendable = userAccounts().filter(
    (a) => a.accountType !== 'brokerage' && a.accountType !== 'investment'
  );
  const map = balances();

  let available = 0n;
  const others = new Map();
  for (const account of spendable) {
    const shown = displayBalance(account, map);
    if (!shown) continue;
    const units = account.kind === 'liability' ? -shown.units : shown.units;
    if (account.currency === base) available += units;
    else others.set(account.currency, (others.get(account.currency) ?? 0n) + units);
  }

  const progress = budgetProgressThisMonth();
  const rootIDs = new Set(state.budgetNodes.filter((n) => !n.parentID).map((n) => n.id));
  const roots = progress.filter((item) => rootIDs.has(item.node.id) && item.node.limit);
  const limitUnits = roots.reduce((sum, item) => sum + item.node.limit.units, 0n);
  const spentUnits = roots.reduce((sum, item) => sum + item.spent.units, 0n);

  const recent = state.entries.slice(0, 6);

  return h('div', { class: 'stack' },
    card(
      h('p', { class: 'card-label', text: t('today.safe_to_spend') }),
      h('p', { class: 'headline', text: formatMoney(new Money(available, base)) }),
      muted(t('today.available_detail')),
      others.size
        ? h('p', { class: 'small' },
            `${t('today.other_currencies')} `,
            [...others].sort().map(([code, units]) => formatMoney(new Money(units, code))).join(' · '))
        : null
    ),
    card(
      h('p', { class: 'card-label', text: t('today.monthly_budget') }),
      limitUnits > 0n
        ? h('div', {},
            budgetBar(Number(spentUnits) / Number(limitUnits), monthElapsed()),
            h('p', { class: 'small', text: t('plan.spent_of_limit',
              formatMoney(new Money(spentUnits, base)),
              formatMoney(new Money(limitUnits, base))) }))
        : muted(t('today.no_budget'))
    ),
    card(
      h('p', { class: 'card-label', text: t('today.recent') }),
      recent.length
        ? h('ul', { class: 'list' }, recent.map(entryRow))
        : muted(t('today.no_transactions'))
    ),
    card(
      h('p', { class: 'card-label', text: t('today.private') }),
      muted(t('today.privacy_detail'))
    )
  );
}

function entryRow(entry) {
  const kinds = new Map(state.accounts.map((a) => [a.id, a.kind]));
  let shown = null;
  if (entry.kind === 'expense') {
    shown = entry.postings.find((p) => kinds.get(p.accountID) === 'expense')?.money ?? null;
  } else if (entry.kind === 'income') {
    const found = entry.postings.find((p) => kinds.get(p.accountID) === 'income')?.money;
    shown = found ? found.negated : null;
  }
  const label = entry.payee ?? entry.note ?? t(`log.${entry.kind}`) ?? entry.kind;

  return h('li', { class: 'list-row' },
    h('div', {},
      h('p', { class: 'strong', text: label }),
      h('p', { class: 'small', text: formatDate(entry.occurredAt) })),
    h('p', {
      class: `amount ${entry.kind === 'income' ? 'positive' : ''}`.trim(),
      text: shown ? formatMoney(shown) : '—'
    })
  );
}

// -------------------------------------------------------------------- plan

function budgetBar(ratio, elapsed) {
  const clamped = Math.min(Math.max(ratio, 0), 1);
  return h('div', { class: 'bar', role: 'presentation' },
    h('div', {
      class: `bar-fill ${ratio > 1 ? 'over' : ''}`.trim(),
      style: { width: `${clamped * 100}%` }
    }),
    h('div', { class: 'bar-pace', style: { left: `${Math.min(Math.max(elapsed, 0), 1) * 100}%` } })
  );
}

function planScreen() {
  const base = state.profile.baseCurrency;
  const progress = new Map(budgetProgressThisMonth().map((item) => [item.node.id, item]));
  const elapsed = monthElapsed();

  const ordered = [];
  const byParent = new Map();
  for (const node of state.budgetNodes) {
    const key = node.parentID ?? '';
    byParent.set(key, [...(byParent.get(key) ?? []), node]);
  }
  const walk = (parentID, depth) => {
    for (const node of (byParent.get(parentID ?? '') ?? []).sort((a, b) => a.name.localeCompare(b.name))) {
      ordered.push({ node, depth });
      walk(node.id, depth + 1);
    }
  };
  walk(null, 0);

  const rootIDs = new Set(state.budgetNodes.filter((n) => !n.parentID).map((n) => n.id));
  const roots = [...progress.values()].filter((item) => rootIDs.has(item.node.id) && item.node.limit);
  const limitUnits = roots.reduce((sum, item) => sum + item.node.limit.units, 0n);
  const spentUnits = roots.reduce((sum, item) => sum + item.spent.units, 0n);
  const remainingUnits = limitUnits - spentUnits;

  return h('div', { class: 'stack' },
    limitUnits > 0n
      ? card(
          h('p', { class: 'card-label', text: remainingUnits < 0n ? t('plan.total_over') : t('plan.total_left') }),
          h('p', {
            class: `headline ${remainingUnits < 0n ? 'negative' : ''}`.trim(),
            text: formatMoney(new Money(remainingUnits < 0n ? -remainingUnits : remainingUnits, base))
          }),
          budgetBar(Number(spentUnits) / Number(limitUnits), elapsed),
          h('p', { class: 'small', text: t('plan.spent_of_limit',
            formatMoney(new Money(spentUnits, base)),
            formatMoney(new Money(limitUnits, base))) }),
          h('p', { class: 'tiny', text: t('plan.pace_hint') }))
      : null,
    card(
      row(
        h('p', { class: 'card-label', text: t('plan.this_month') }),
        button(t('plan.add_category'), () => { state.sheet = { type: 'addCategory' }; render(); })),
      ordered.length
        ? h('ul', { class: 'list' }, ordered.map(({ node, depth }) => budgetRow(node, depth, progress.get(node.id), elapsed)))
        : muted(t('plan.empty')),
      h('p', { class: 'tiny', text: t('plan.rollup_detail') })
    )
  );
}

function budgetRow(node, depth, progress, elapsed) {
  const remaining = progress?.remaining ?? null;
  const isOver = remaining ? remaining.isNegative : false;
  const spent = progress?.spent ?? null;
  const ratio = node.limit && node.limit.units > 0n && spent
    ? Number(spent.units) / Number(node.limit.units)
    : null;

  return h('li', {
    class: 'list-row tappable',
    style: { paddingLeft: `${Math.min(depth, 4) * 16}px` },
    onclick: () => { state.sheet = { type: 'limit', node }; render(); }
  },
    h('div', { class: 'grow' },
      row(
        h('p', { class: depth === 0 ? 'strong' : '', text: node.name }),
        remaining
          ? h('p', { class: `amount ${isOver ? 'negative' : ''}`.trim() },
              formatMoney(isOver ? remaining.negated : remaining),
              h('span', { class: 'suffix', text: ` ${isOver ? t('plan.over') : t('plan.left')}` }))
          : (spent && !spent.isZero ? h('p', { class: 'amount', text: formatMoney(spent) }) : null)),
      ratio !== null ? budgetBar(ratio, elapsed) : null,
      h('p', { class: 'small', text: node.limit && spent
        ? t('plan.spent_of_limit', formatMoney(spent), formatMoney(node.limit))
        : t('plan.tap_to_set_limit') })
    )
  );
}

// ---------------------------------------------------------------- insights

function insightsScreen() {
  const current = report();
  if (!current) return muted(t('insights.no_data'));

  const points = categoryPoints(current);
  const flows = current.monthlyFlows;
  const peak = flows.reduce((max, flow) => {
    const value = Math.max(flow.income.toNumber(), flow.expense.toNumber());
    return Math.max(max, value);
  }, 0);

  return h('div', { class: 'stack' },
    card(row(
      h('p', { class: 'card-label', text: t('insights.period') }),
      select(
        REPORT_PERIODS.map((value) => ({ value, label: t(`period.${value}`) })),
        state.period,
        (value) => { state.period = value; render(); }
      ))),
    h('div', { class: 'metrics' },
      metric(t('log.income'), formatMoney(current.baseFlow.income), 'income'),
      metric(t('log.expense'), formatMoney(current.baseFlow.expense), 'expense'),
      metric(t('insights.net'), formatMoney(current.baseFlow.net),
        current.baseFlow.net.isNegative ? 'negative' : 'net')),
    current.holdsUnconvertedActivity
      ? card(
          h('p', { class: 'card-label', text: t('insights.other_currencies') }),
          h('ul', { class: 'list' }, current.foreignFlows.map((flow) => h('li', { class: 'list-row' },
            h('p', { class: 'strong', text: flow.currency }),
            h('p', { class: `amount ${flow.net.isNegative ? 'negative' : ''}`.trim(), text: formatMoney(flow.net) })))),
          h('p', { class: 'tiny', text: t('insights.other_currencies_detail') }))
      : null,
    card(
      h('p', { class: 'card-label', text: t('insights.category_spending') }),
      points.length
        ? h('div', { class: 'chart' }, points.map((point) => {
            const share = points[0].money.units > 0n
              ? Number(point.money.units) / Number(points[0].money.units)
              : 0;
            return h('div', { class: 'chart-row' },
              h('span', { class: 'chart-name', text: point.name }),
              h('span', { class: 'chart-track' },
                h('span', {
                  class: `chart-fill ${point.isOther ? 'other' : ''}`.trim(),
                  style: { width: `${Math.max(share * 100, 2)}%` }
                })),
              h('span', { class: 'chart-value', text: formatMoney(point.money) }));
          }))
        : muted(t('insights.no_spending'))),
    card(
      h('p', { class: 'card-label', text: t('insights.monthly_flow') }),
      peak > 0
        ? h('div', { class: 'columns' }, flows.map((flow) => h('div', { class: 'column' },
            h('div', { class: 'column-pair' },
              columnBar('income', flow.income, peak),
              columnBar('expense', flow.expense, peak)),
            h('span', { class: 'column-label', text: formatMonth(flow.month) }))))
        : muted(t('insights.no_flow_data'))),
    card(
      h('p', { class: 'card-label', text: t('insights.reading') }),
      h('ul', { class: 'readings' }, readings(current).map((line) => h('li', { text: line })))
    )
  );
}

/**
 * A month with no activity must draw nothing. A minimum bar height would put
 * a visible mark under every quiet month, which reads as a small amount
 * rather than none.
 */
function columnBar(tone, money, peak) {
  const value = money.toNumber();
  const height = value > 0 ? Math.max((value / peak) * 100, 1.5) : 0;
  return h('span', {
    class: `column-bar ${tone}`,
    style: { height: `${height}%` },
    title: formatMoney(money)
  });
}

function metric(label, value, tone) {
  return h('div', { class: `metric ${tone}` },
    h('span', { class: 'metric-label', text: label }),
    h('span', { class: 'metric-value', text: value }));
}

function categoryPoints(current) {
  const positive = current.categorySpending.filter((item) => item.money === undefined
    ? item.amount.units > 0n
    : item.money.units > 0n);
  const visible = positive.slice(0, 8).map((item) => ({
    name: item.name, money: item.amount, isOther: false
  }));
  const rest = positive.slice(8);
  if (rest.length) {
    const units = rest.reduce((sum, item) => sum + item.amount.units, 0n);
    visible.push({
      name: t('insights.other_category'),
      money: new Money(units, current.baseCurrency),
      isOther: true
    });
  }
  return visible;
}

function readings(current) {
  if (current.isEmpty) return [t('insights.no_data')];
  const lines = [];

  if (current.baseFlow.expense.units <= 0n && !current.holdsUnconvertedActivity) {
    lines.push(t('insights.no_expense_yet'));
  }
  const rate = current.savingsRate;
  if (rate !== null) {
    if (rate >= 0) lines.push(t('insights.savings_rate', formatPercent(rate)));
    else {
      lines.push(t('insights.overspend',
        formatMoney(current.baseFlow.expense.subtract(current.baseFlow.income))));
    }
  }
  const largest = current.largestCategory;
  if (largest) {
    lines.push(t('insights.largest_category', largest.category.name, formatPercent(largest.share)));
  }
  const change = current.monthOverMonth;
  if (state.period === 'thisMonth' && change && change.previous.expense.units > 0n) {
    const delta = Number(change.latest.expense.units - change.previous.expense.units)
      / Number(change.previous.expense.units);
    if (delta > 0.005) lines.push(t('insights.spending_up', formatPercent(delta)));
    else if (delta < -0.005) lines.push(t('insights.spending_down', formatPercent(-delta)));
    else lines.push(t('insights.spending_flat'));
  }
  return lines.length ? lines : [t('insights.no_data')];
}

// ---------------------------------------------------------------- accounts

function accountsScreen() {
  const map = balances();
  return h('div', { class: 'stack' },
    card(
      row(
        h('p', { class: 'card-label', text: t('accounts.title') }),
        button(t('accounts.add'), () => { state.sheet = { type: 'addAccount' }; render(); })),
      h('ul', { class: 'list' }, userAccounts().map((account) => h('li', { class: 'list-row' },
        h('div', {},
          h('p', { class: 'strong', text: account.name }),
          h('p', { class: 'small', text: t(`account.type.${account.accountType ?? 'other'}`) })),
        h('p', { class: 'amount', text: formatMoney(displayBalance(account, map)) }))))
    ),
    card(
      h('p', { class: 'card-label', text: t('accounts.data') }),
      h('div', { class: 'actions' },
        button(t('accounts.export'), downloadCSV),
        button(t('accounts.change_passphrase'), () => { state.sheet = { type: 'passphrase' }; render(); }),
        button(t('lock.lock_now'), lock),
        button(t('accounts.erase'), () => { state.sheet = { type: 'erase' }; render(); }, 'danger')),
      h('p', { class: 'tiny', text: t('accounts.export_warning') })
    ),
    card(
      row(h('span', { text: t('accounts.language') }), select(
        availableLanguages().map((value) => ({ value, label: value === 'en' ? 'English' : '简体中文' })),
        language,
        (value) => { setLanguage(value); render(); })),
      row(h('span', { text: t('accounts.version') }), h('span', { class: 'mono', text: APP_VERSION }))
    )
  );
}

function downloadCSV() {
  const csv = exportCSV(state.entries, state.accounts);
  const blob = new Blob([csv], { type: 'text/csv;charset=utf-8' });
  const url = URL.createObjectURL(blob);
  const link = h('a', { href: url, download: `moneyup-${new Date().toISOString().slice(0, 10)}.csv` });
  document.body.append(link);
  link.click();
  link.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

export {
  state, h, card, row, muted, field, select, button,
  invalidate, loadBook, lock, accountByID,
  userAccounts, expenseCategories, incomeCategories,
  serializeEntry, serializeNode, budgetProgressThisMonth
};

// ------------------------------------------------------------------ shell

function tabBar() {
  const tabs = [
    ['today', t('tab.today')],
    ['plan', t('tab.plan')],
    ['insights', t('tab.insights')],
    ['accounts', t('tab.accounts')]
  ];
  return h('nav', { class: 'tabs' }, tabs.map(([id, label]) => h('button', {
    class: `tab ${state.tab === id ? 'active' : ''}`.trim(),
    type: 'button',
    'aria-current': state.tab === id ? 'page' : null,
    onclick: () => { state.tab = id; render(); }
  }, label)));
}

function screen() {
  switch (state.tab) {
    case 'plan': return planScreen();
    case 'insights': return insightsScreen();
    case 'accounts': return accountsScreen();
    default: return todayScreen();
  }
}

export function render() {
  const root = document.getElementById('root');
  root.replaceChildren();
  document.documentElement.lang = language === 'zh-Hans' ? 'zh-Hans' : 'en';

  if (state.phase === 'loading') {
    root.append(h('div', { class: 'gate' }, muted('…')));
    return;
  }
  if (state.phase === 'setup' || state.phase === 'locked') {
    root.append(passphraseScreen());
    return;
  }
  if (state.phase === 'onboarding') {
    root.append(onboardingScreen());
    return;
  }

  root.append(
    h('main', { class: 'content' }, screen()),
    h('button', {
      class: 'fab', type: 'button', 'aria-label': t('log.title'),
      onclick: () => { state.sheet = { type: 'log' }; render(); }
    }, '+'),
    tabBar()
  );
  if (state.sheet) root.append(renderSheet(state.sheet));
}

let renderSheet = () => null;
export function registerSheetRenderer(renderer) {
  renderSheet = renderer;
}

export async function boot() {
  state.db = await openDatabase();
  state.envelope = await loadEnvelope(state.db);
  state.phase = state.envelope ? 'locked' : 'setup';
  render();

  // Lock when the tab is hidden, mirroring the iOS background lock.
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'hidden' && state.phase === 'ready') lock();
  });
}
