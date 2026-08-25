// Posting-level CSV, matching LedgerCSVExporter.swift.
//
// Every cell is quoted, and a cell that begins with a formula character is
// prefixed so a spreadsheet treats it as text rather than executing it.

const HEADER = [
  'entry_id', 'occurred_at', 'kind', 'payee', 'note',
  'account_id', 'account_name', 'account_kind', 'amount', 'currency', 'memo'
];

function cell(value) {
  const text = value === null || value === undefined ? '' : String(value);
  return `"${text.replaceAll('"', '""')}"`;
}

/**
 * Neutralizes user-controlled text that a spreadsheet would run as a formula.
 * Quoting a CSV cell alone does not reliably prevent execution.
 *
 * Applied to free text only, never to amounts: a leading minus makes a
 * negative number look like a formula, and prefixing it would import every
 * negative posting as text that cannot be summed.
 */
function textCell(value) {
  const text = value === null || value === undefined ? '' : String(value);
  const first = text.trimStart()[0];
  return cell('=+-@'.includes(first ?? '') ? `'${text}` : text);
}

export function exportCSV(entries, accounts) {
  const byID = new Map(accounts.map((account) => [account.id, account]));
  const rows = [HEADER.map(cell).join(',')];

  const ordered = [...entries].sort((a, b) => a.occurredAt - b.occurredAt);
  for (const entry of ordered) {
    for (const item of entry.postings) {
      const account = byID.get(item.accountID);
      rows.push([
        cell(entry.id),
        cell(entry.occurredAt.toISOString()),
        cell(entry.kind),
        textCell(entry.payee),
        textCell(entry.note),
        cell(item.accountID),
        textCell(account?.name ?? ''),
        cell(account?.kind ?? ''),
        cell(item.money.toString()),
        cell(item.money.currency),
        textCell(item.memo)
      ].join(','));
    }
  }
  return `${rows.join('\r\n')}\r\n`;
}
