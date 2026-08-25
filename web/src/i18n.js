// English and Simplified Chinese ship together, as they do on iOS.

const STRINGS = {
  en: {
    'app.name': 'MoneyUp',
    'app.tagline': 'Private money, clearly understood.',

    'setup.title': 'Set a passphrase',
    'setup.detail': 'Your data is encrypted on this device with a key only this passphrase unlocks. Nothing is uploaded, and there is no way to recover a forgotten passphrase.',
    'setup.passphrase': 'Passphrase',
    'setup.confirm': 'Confirm passphrase',
    'setup.create': 'Create encrypted book',
    'setup.mismatch': 'Those two passphrases do not match.',
    'setup.too_short': 'Use at least 8 characters.',
    'setup.working': 'Deriving key…',

    'lock.title': 'MoneyUp is locked',
    'lock.detail': 'Enter your passphrase to decrypt this book.',
    'lock.unlock': 'Unlock',
    'lock.lock_now': 'Lock now',
    'lock.wrong': 'That passphrase does not open this data.',

    'onboarding.title': 'Set up your book',
    'onboarding.currency': 'Base currency',
    'onboarding.account_name': 'First account',
    'onboarding.account_type': 'Type',
    'onboarding.starting': 'Starting balance (optional)',
    'onboarding.start': 'Start',

    'tab.today': 'Today',
    'tab.plan': 'Plan',
    'tab.insights': 'Insights',
    'tab.accounts': 'Accounts',

    'today.safe_to_spend': 'Safe to spend',
    'today.available_detail': 'Liquid balances minus card and loan debt in your base currency.',
    'today.other_currencies': 'Also held:',
    'today.monthly_budget': 'Monthly budget',
    'today.no_budget': 'No limits set yet. Add one in Plan.',
    'today.recent': 'Recent activity',
    'today.no_transactions': 'Nothing logged yet.',
    'today.private': 'Private by design',
    'today.privacy_detail': 'Everything here is encrypted in this browser. No account, no server, no analytics.',

    'plan.this_month': 'This month',
    'plan.rollup_detail': 'A parent limit caps all spending beneath it. Child limits are allocations inside it.',
    'plan.left': 'left',
    'plan.over': 'over',
    'plan.total_left': 'Left to spend this month',
    'plan.total_over': 'Over budget this month',
    'plan.spent_of_limit': '{0} spent of {1}',
    'plan.tap_to_set_limit': 'Tap to set a monthly limit',
    'plan.pace_hint': 'The line marks how far through the month you are.',
    'plan.monthly_limit': 'Monthly limit',
    'plan.blank_removes_limit': 'Leave blank to remove the limit.',
    'plan.empty': 'No categories yet.',
    'plan.add_category': 'Add category',
    'plan.category_name': 'Category name',
    'plan.parent': 'Inside',
    'plan.no_parent': 'Top level',

    'insights.period': 'Period',
    'period.thisMonth': 'This month',
    'period.lastMonth': 'Last month',
    'period.threeMonths': '3 months',
    'period.sixMonths': '6 months',
    'period.twelveMonths': '12 months',
    'period.yearToDate': 'Year to date',
    'insights.net': 'Net flow',
    'insights.category_spending': 'Top spending categories',
    'insights.no_spending': 'No category spending in this period.',
    'insights.other_category': 'Other categories',
    'insights.monthly_flow': 'Monthly cash flow',
    'insights.no_flow_data': 'No income or expenses in these months yet.',
    'insights.other_currencies': 'Other currencies',
    'insights.other_currencies_detail': 'MoneyUp holds no exchange rates, so this activity is listed on its own and is not part of the totals above.',
    'insights.reading': 'Local insight',
    'insights.no_data': 'Log transactions to build a local insight.',
    'insights.no_expense_yet': 'No expenses are logged in this period yet.',
    'insights.savings_rate': 'You kept {0} of the income logged in this period.',
    'insights.overspend': 'Spending exceeded income by {0} in this period.',
    'insights.largest_category': '{0} is the largest category, at {1} of spending.',
    'insights.spending_up': 'Spending is up {0} from the previous month.',
    'insights.spending_down': 'Spending is down {0} from the previous month.',
    'insights.spending_flat': 'Spending is level with the previous month.',

    'accounts.title': 'Accounts and cards',
    'accounts.add': 'Add account',
    'accounts.name': 'Account name',
    'accounts.type': 'Type',
    'accounts.currency': 'Currency',
    'accounts.starting': 'Starting balance (optional)',
    'accounts.data': 'Data and privacy',
    'accounts.export': 'Export CSV for Numbers or Excel',
    'accounts.export_warning': 'A CSV export is readable plaintext. Anyone who opens the file can read every transaction.',
    'accounts.change_passphrase': 'Change passphrase',
    'accounts.current_passphrase': 'Current passphrase',
    'accounts.new_passphrase': 'New passphrase',
    'accounts.erase': 'Erase all data',
    'accounts.erase_detail': 'This deletes the encrypted book and its key from this browser. It cannot be undone and there is no backup.',
    'accounts.erase_confirm': 'Erase everything',
    'accounts.version': 'Version',
    'accounts.language': 'Language',

    'log.title': 'Log',
    'log.expense': 'Expense',
    'log.income': 'Income',
    'log.transfer': 'Transfer',
    'log.smart': 'Smart entry',
    'log.smart_placeholder': 'lunch 12.50 cash yesterday',
    'log.smart_fill': 'Fill',
    'log.smart_footer': 'Parsed on this device against your own account and category names.',
    'log.smart_nothing': 'Nothing recognizable. Fill the fields below instead.',
    'log.amount': 'Amount',
    'log.account': 'Account',
    'log.from': 'From',
    'log.to': 'To',
    'log.received': 'Amount received',
    'log.category': 'Category',
    'log.date': 'Date',
    'log.payee': 'Payee',
    'log.note': 'Note',
    'log.no_accounts': 'Add an account first.',
    'log.need_two': 'A transfer needs two accounts.',

    'action.save': 'Save',
    'action.cancel': 'Cancel',
    'action.continue': 'Continue',
    'action.close': 'Close',
    'account.type.cash': 'Cash',
    'account.type.bank': 'Bank account',
    'account.type.e_wallet': 'E-wallet',
    'account.type.credit_card': 'Credit card',
    'account.type.loan': 'Loan',
    'account.type.brokerage': 'Brokerage',
    'account.type.investment': 'Investment',
    'account.type.other': 'Other',
    'category.essentials': 'Essentials',
    'category.food': 'Food',
    'category.transport': 'Transport',
    'category.housing': 'Housing',
    'category.rent': 'Rent',
    'category.utilities': 'Utilities',
    'category.lifestyle': 'Lifestyle',
    'category.shopping': 'Shopping',
    'category.entertainment': 'Entertainment',
    'category.salary': 'Salary',
    'category.other_income': 'Other income',
    'account.opening_balances': 'Opening balances',
    'account.opening_note': 'Opening balance',
    'account.fx_clearing': 'Currency exchange'
  },

  'zh-Hans': {
    'app.name': 'MoneyUp',
    'app.tagline': '私密记账，一目了然。',

    'setup.title': '设置密码短语',
    'setup.detail': '数据将在本设备加密保存，只有此密码短语能解锁。不会上传到任何服务器，密码短语一旦遗忘将无法找回。',
    'setup.passphrase': '密码短语',
    'setup.confirm': '确认密码短语',
    'setup.create': '创建加密账本',
    'setup.mismatch': '两次输入的密码短语不一致。',
    'setup.too_short': '请至少输入 8 个字符。',
    'setup.working': '正在推导密钥…',

    'lock.title': 'MoneyUp 已锁定',
    'lock.detail': '输入密码短语以解密账本。',
    'lock.unlock': '解锁',
    'lock.lock_now': '立即锁定',
    'lock.wrong': '该密码短语无法打开此数据。',

    'onboarding.title': '设置账本',
    'onboarding.currency': '本位币',
    'onboarding.account_name': '第一个账户',
    'onboarding.account_type': '类型',
    'onboarding.starting': '期初余额（可选）',
    'onboarding.start': '开始',

    'tab.today': '今天',
    'tab.plan': '预算',
    'tab.insights': '洞察',
    'tab.accounts': '账户',

    'today.safe_to_spend': '可安心支出',
    'today.available_detail': '本位币流动余额减去信用卡和贷款负债。',
    'today.other_currencies': '另持有：',
    'today.monthly_budget': '本月预算',
    'today.no_budget': '尚未设置限额，可在“预算”中添加。',
    'today.recent': '最近动态',
    'today.no_transactions': '还没有记账。',
    'today.private': '隐私优先',
    'today.privacy_detail': '所有内容都在此浏览器中加密保存。无账号、无服务器、无统计追踪。',

    'plan.this_month': '本月',
    'plan.rollup_detail': '父级限额覆盖其下所有支出，子级限额是其中的分配。',
    'plan.left': '剩余',
    'plan.over': '超支',
    'plan.total_left': '本月可用余额',
    'plan.total_over': '本月已超出预算',
    'plan.spent_of_limit': '已用 {0}，共 {1}',
    'plan.tap_to_set_limit': '点按设置每月限额',
    'plan.pace_hint': '竖线表示本月已过去的时间进度。',
    'plan.monthly_limit': '每月限额',
    'plan.blank_removes_limit': '留空即可取消限额。',
    'plan.empty': '还没有分类。',
    'plan.add_category': '添加分类',
    'plan.category_name': '分类名称',
    'plan.parent': '归属于',
    'plan.no_parent': '顶层',

    'insights.period': '统计区间',
    'period.thisMonth': '本月',
    'period.lastMonth': '上月',
    'period.threeMonths': '近 3 个月',
    'period.sixMonths': '近 6 个月',
    'period.twelveMonths': '近 12 个月',
    'period.yearToDate': '今年至今',
    'insights.net': '净现金流',
    'insights.category_spending': '主要支出分类',
    'insights.no_spending': '该区间暂无分类支出。',
    'insights.other_category': '其他分类',
    'insights.monthly_flow': '每月现金流',
    'insights.no_flow_data': '这段时间还没有收支记录。',
    'insights.other_currencies': '其他币种',
    'insights.other_currencies_detail': 'MoneyUp 不保存汇率，因此这些金额单独列出，未计入上方合计。',
    'insights.reading': '本机洞察',
    'insights.no_data': '记账后即可在本机生成洞察。',
    'insights.no_expense_yet': '该区间尚未记录支出。',
    'insights.savings_rate': '本区间已记录的收入中，你留存了 {0}。',
    'insights.overspend': '本区间支出比收入多 {0}。',
    'insights.largest_category': '{0} 是最大的支出分类，占支出的 {1}。',
    'insights.spending_up': '支出比上月增加 {0}。',
    'insights.spending_down': '支出比上月减少 {0}。',
    'insights.spending_flat': '支出与上月基本持平。',

    'accounts.title': '账户与卡片',
    'accounts.add': '添加账户',
    'accounts.name': '账户名称',
    'accounts.type': '类型',
    'accounts.currency': '币种',
    'accounts.starting': '期初余额（可选）',
    'accounts.data': '数据与隐私',
    'accounts.export': '导出 CSV（Numbers 或 Excel）',
    'accounts.export_warning': 'CSV 导出为明文，任何打开该文件的人都能读到全部交易。',
    'accounts.change_passphrase': '修改密码短语',
    'accounts.current_passphrase': '当前密码短语',
    'accounts.new_passphrase': '新密码短语',
    'accounts.erase': '清除所有数据',
    'accounts.erase_detail': '将从此浏览器删除加密账本及其密钥。此操作不可撤销，且没有备份。',
    'accounts.erase_confirm': '全部清除',
    'accounts.version': '版本',
    'accounts.language': '语言',

    'log.title': '记一笔',
    'log.expense': '支出',
    'log.income': '收入',
    'log.transfer': '转账',
    'log.smart': '智能录入',
    'log.smart_placeholder': '昨天 现金 午餐 12.50',
    'log.smart_fill': '填入',
    'log.smart_footer': '在本机依据你自己的账户与分类名称解析。',
    'log.smart_nothing': '未能识别内容，请在下方手动填写。',
    'log.amount': '金额',
    'log.account': '账户',
    'log.from': '转出',
    'log.to': '转入',
    'log.received': '到账金额',
    'log.category': '分类',
    'log.date': '日期',
    'log.payee': '收款方',
    'log.note': '备注',
    'log.no_accounts': '请先添加账户。',
    'log.need_two': '转账需要两个账户。',

    'action.save': '保存',
    'action.cancel': '取消',
    'action.continue': '继续',
    'action.close': '关闭',
    'account.type.cash': '现金',
    'account.type.bank': '银行账户',
    'account.type.e_wallet': '电子钱包',
    'account.type.credit_card': '信用卡',
    'account.type.loan': '贷款',
    'account.type.brokerage': '证券账户',
    'account.type.investment': '投资账户',
    'account.type.other': '其他',
    'category.essentials': '必需支出',
    'category.food': '餐饮',
    'category.transport': '交通',
    'category.housing': '居住',
    'category.rent': '房租',
    'category.utilities': '水电煤',
    'category.lifestyle': '生活',
    'category.shopping': '购物',
    'category.entertainment': '娱乐',
    'category.salary': '工资',
    'category.other_income': '其他收入',
    'account.opening_balances': '期初余额',
    'account.opening_note': '期初余额',
    'account.fx_clearing': '货币兑换'
  }
};

const STORAGE_KEY = 'moneyup.language';

function detectLanguage() {
  try {
    const saved = localStorage.getItem(STORAGE_KEY);
    if (saved && STRINGS[saved]) return saved;
  } catch {
    // Storage can be blocked entirely; the default is still correct.
  }
  const preferred = (globalThis.navigator?.languages ?? []).find(
    (tag) => tag.toLowerCase().startsWith('zh')
  );
  return preferred ? 'zh-Hans' : 'en';
}

export let language = detectLanguage();

export function setLanguage(next) {
  if (!STRINGS[next]) return;
  language = next;
  try {
    localStorage.setItem(STORAGE_KEY, next);
  } catch {
    // A preference that cannot be remembered is not worth failing over.
  }
}

export function availableLanguages() {
  return Object.keys(STRINGS);
}

/** Looks up a key, substituting {0}, {1}, … positionally. */
export function t(key, ...args) {
  const table = STRINGS[language] ?? STRINGS.en;
  const value = table[key] ?? STRINGS.en[key] ?? key;
  return args.reduce(
    (text, arg, index) => text.replaceAll(`{${index}}`, String(arg)),
    value
  );
}
