// Typed-phrase entry: "lunch 12.50 cash yesterday".
//
// A port of NaturalLanguageEntryParser.swift. Matching runs against the
// user's own account and category names, so the vocabulary is whatever they
// already created. No model, no network, and the same input always gives the
// same result.

const INCOME_WORDS = [
  'salary', 'wage', 'wages', 'income', 'bonus', 'payout', 'received',
  '工资', '薪水', '收入', '奖金', '獎金', '收到'
];

const RELATIVE_DAYS = [
  ['day before yesterday', -2], ['前天', -2],
  ['yesterday', -1], ['昨天', -1], ['昨日', -1],
  ['tomorrow', 1], ['明天', 1], ['明日', 1],
  ['today', 0], ['今天', 0], ['今日', 0]
];

// Sunday is 0, matching Date.getDay(). Three-letter abbreviations are left
// out: "mon" hides inside "monthly", "sat" inside "satay".
const WEEKDAYS = [
  ['sunday', 0], ['周日', 0], ['星期日', 0], ['星期天', 0],
  ['monday', 1], ['周一', 1], ['星期一', 1],
  ['tuesday', 2], ['周二', 2], ['星期二', 2],
  ['wednesday', 3], ['周三', 3], ['星期三', 3],
  ['thursday', 4], ['周四', 4], ['星期四', 4],
  ['friday', 5], ['周五', 5], ['星期五', 5],
  ['saturday', 6], ['周六', 6], ['星期六', 6]
];

const FILLER_WORDS = new Set([
  'for', 'at', 'on', 'in', 'of', 'with', 'from', 'to', 'a', 'an', 'the',
  'spent', 'paid', 'pay', 'bought', 'buy', 'got', 'and', 'my', 'last',
  'this', 'was', 'is', 'cost', 'costs'
]);

const FILLER_CHARS = /^[买買花了在用给給付的，。、,.:：\-–—@#*\s]+|[买買花了在用给給付的，。、,.:：\-–—@#*\s]+$/g;

const AMOUNT_PATTERN =
  /(?<![\d.,])\d{1,3}(?:,\d{3})+(?:\.\d{1,2})?(?![\d.,])|(?<![\d.,:])\d+(?:\.\d{1,2})?(?![\d.,:])/;
const ISO_DATE = /(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})/;
const CJK_DATE = /(\d{4})年(\d{1,2})月(\d{1,2})日/;
const LOOSE_DATE = /(\d{1,2})[-/.](\d{1,2})[-/.](\d{4})/;

function stripOnce(text, fragment) {
  const index = text.toLowerCase().indexOf(fragment.toLowerCase());
  if (index < 0) return text;
  return `${text.slice(0, index)} ${text.slice(index + fragment.length)}`;
}

function sameTimeOfDay(reference, day) {
  const result = new Date(day);
  result.setHours(
    reference.getHours(), reference.getMinutes(), reference.getSeconds(), 0
  );
  return result;
}

/**
 * @returns a draft whose unknown fields stay null. An empty field is obvious
 * to the user; a confidently wrong one is not.
 */
export function parsePhrase(text, {
  accounts = [],
  now = new Date(),
  prefersDayFirst = true
} = {}) {
  let remainder = String(text ?? '');
  const haystack = remainder.toLowerCase();
  const kind = INCOME_WORDS.some((word) => haystack.includes(word))
    ? 'income'
    : 'expense';

  let occurredAt = null;
  const iso = ISO_DATE.exec(remainder) ?? CJK_DATE.exec(remainder);
  const loose = iso ? null : LOOSE_DATE.exec(remainder);

  if (iso) {
    occurredAt = sameTimeOfDay(now, new Date(+iso[1], +iso[2] - 1, +iso[3]));
    remainder = stripOnce(remainder, iso[0]);
  } else if (loose) {
    const [, first, second, year] = loose.map(Number);
    let day = prefersDayFirst ? first : second;
    let month = prefersDayFirst ? second : first;
    if (first > 12) { day = first; month = second; }
    else if (second > 12) { day = second; month = first; }
    occurredAt = sameTimeOfDay(now, new Date(year, month - 1, day));
    remainder = stripOnce(remainder, loose[0]);
  } else {
    for (const [token, offset] of RELATIVE_DAYS) {
      if (!haystack.includes(token)) continue;
      const day = new Date(now);
      day.setDate(day.getDate() + offset);
      occurredAt = day;
      remainder = stripOnce(remainder, token);
      break;
    }
    if (!occurredAt) {
      for (const [token, weekday] of WEEKDAYS) {
        if (!haystack.includes(token)) continue;
        const day = new Date(now);
        while (day.getDay() !== weekday) day.setDate(day.getDate() - 1);
        occurredAt = day;
        remainder = stripOnce(remainder, token);
        break;
      }
    }
  }

  let amount = null;
  const amountMatch = AMOUNT_PATTERN.exec(remainder);
  if (amountMatch) {
    amount = amountMatch[0];
    remainder = stripOnce(remainder, amountMatch[0]);
  }

  const matchName = (candidates) => {
    const lower = remainder.toLowerCase();
    const hit = candidates
      .filter((account) => account.name && lower.includes(account.name.toLowerCase()))
      .sort((a, b) => b.name.length - a.name.length)[0];
    if (!hit) return null;
    remainder = stripOnce(remainder, hit.name);
    return hit.id;
  };

  const accountID = matchName(
    accounts.filter((a) => (a.kind === 'asset' || a.kind === 'liability') && !a.isArchived)
  );
  const categoryKind = kind === 'income' ? 'income' : 'expense';
  const categoryID = matchName(
    accounts.filter((a) => a.kind === categoryKind && !a.isArchived)
  );

  const payee = remainder
    .split(/\s+/)
    .map((word) => word.replace(FILLER_CHARS, ''))
    .filter((word) => word && !FILLER_WORDS.has(word.toLowerCase()))
    .join(' ')
    .replace(FILLER_CHARS, '')
    .slice(0, 64);

  return {
    kind,
    amount,
    occurredAt,
    accountID,
    categoryID,
    payee: /[\p{L}\p{N}]/u.test(payee) ? payee : null,
    get isEmpty() {
      return this.amount === null && this.occurredAt === null && this.payee === null;
    }
  };
}

/**
 * The category this payee was filed under most often before. The whole of
 * MoneyUp's "learning": counting what the person themselves chose.
 */
export function suggestCategory(payee, { entries, accounts, kind = 'expense' }) {
  const needle = String(payee ?? '').trim().toLowerCase();
  if (needle.length < 2) return null;

  const relevant = new Set(
    accounts.filter((a) => a.kind === kind && !a.isArchived).map((a) => a.id)
  );
  if (relevant.size === 0) return null;

  const counts = new Map();
  const latest = new Map();

  for (const entry of entries) {
    if (!entry.payee) continue;
    const stored = entry.payee.toLowerCase();
    const matches = stored === needle
      || (stored.length >= 3 && needle.length >= 3
        && (stored.includes(needle) || needle.includes(stored)));
    if (!matches) continue;

    for (const item of entry.postings) {
      if (!relevant.has(item.accountID)) continue;
      counts.set(item.accountID, (counts.get(item.accountID) ?? 0) + 1);
      const seen = latest.get(item.accountID) ?? 0;
      latest.set(item.accountID, Math.max(seen, entry.occurredAt.getTime()));
    }
  }

  let best = null;
  for (const [id, count] of counts) {
    if (!best || count > best.count
      || (count === best.count && latest.get(id) > latest.get(best.id))) {
      best = { id, count };
    }
  }
  return best?.id ?? null;
}
