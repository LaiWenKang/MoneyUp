// Locale-aware display. Money always comes from a Money instance, never a
// Number that has been through arithmetic.

import { language } from './i18n.js';

export function formatMoney(money) {
  if (!money) return '—';
  const locale = language === 'zh-Hans' ? 'zh-Hans' : undefined;
  try {
    return new Intl.NumberFormat(locale, {
      style: 'currency',
      currency: money.currency
    }).format(money.toNumber());
  } catch {
    // A valid asset code that is not ISO 4217 — show the code beside the
    // number rather than failing.
    return `${money.currency} ${money.toString()}`;
  }
}

export function formatPercent(fraction, digits = 0) {
  const locale = language === 'zh-Hans' ? 'zh-Hans' : undefined;
  return new Intl.NumberFormat(locale, {
    style: 'percent',
    maximumFractionDigits: digits
  }).format(fraction);
}

export function formatDate(date) {
  const locale = language === 'zh-Hans' ? 'zh-Hans' : undefined;
  return new Intl.DateTimeFormat(locale, { dateStyle: 'medium' }).format(date);
}

export function formatMonth(date) {
  const locale = language === 'zh-Hans' ? 'zh-Hans' : undefined;
  return new Intl.DateTimeFormat(locale, { month: 'short' }).format(date);
}

/** `YYYY-MM-DDTHH:mm` for a datetime-local input, in local time. */
export function toLocalInputValue(date) {
  const pad = (value) => String(value).padStart(2, '0');
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`
    + `T${pad(date.getHours())}:${pad(date.getMinutes())}`;
}

/** Elapsed fraction of the current calendar month, for the budget pace mark. */
export function monthElapsed(now = new Date()) {
  const start = new Date(now.getFullYear(), now.getMonth(), 1);
  const end = new Date(now.getFullYear(), now.getMonth() + 1, 1);
  const span = end - start;
  return span > 0 ? Math.min(Math.max((now - start) / span, 0), 1) : 0;
}
