// Labels of the report PDFs (generate-report-pdf), in English and Gujarati.
//
// The Gujarati text is copied word for word from the app's own translations
// (rn-warehouse-template src/i18n/locales/gu/reports.ts and common.ts, at app
// commit f3b854b; and, for the labels whose comment names another file, that
// file as read on 2026-10-12) for the same English text, so a PDF says what
// the screen says. The few labels whose exact English the app does not have
// are put together from the app's own words and say so in their comment, so
// the owner can check them. A label whose English the app has no Gujarati for
// at all may be `null` here: the PDF prints the English, and the label is
// listed in `missingGujarati` for the app team to supply. Do not invent
// Gujarati here that is not made of the app's words.
//
// Four labels (sortBy, showing, grnNumber, stockAge) carry the wording of the
// Gujarati review of 2026-10-12, which the owner chose to apply: a paper
// document is a fact line or a column of short numbers, not the screen's
// command or clause. Their comments say which app key the text is, or that
// the app still says otherwise (showing).

export type ReportLang = 'en' | 'gu';

// [English, Gujarati or null]. The comment names the app key it comes from.
const table = {
  // reports.titles.*
  titleGrnActivity: ['GRN activity', 'આવકની કામગીરી'],
  titleDispatchActivity: ['Dispatch activity', 'જાવકની કામગીરી'],
  titleInvoiceHistory: ['Invoice history', 'ઇન્વૉઇસનો ઇતિહાસ'],
  titleStockSummary: ['Stock summary', 'સ્ટોકનો સારાંશ'],
  titleStockAging: ['Stock aging', 'માલ કેટલા દિવસથી પડ્યો છે'],
  titleItemStockSummary: ['Item stock summary', 'આઇટમ મુજબ સ્ટોકનો સારાંશ'],
  titleCustomerActivity: ['Customer activity', 'વેપારીની કામગીરી'],

  // Header and layout
  customer: ['Customer', 'વેપારી'], // common.customer
  customers: ['Customers', 'વેપારીઓ'], // common.customers
  allCustomers: ['All customers', 'બધા વેપારી'], // reports.shared.allCustomers
  period: ['Period', 'સમયગાળો'], // reports.period.label
  dateRange: ['{{from}} – {{to}}', '{{from}}થી {{to}} સુધી'], // filters.chip.dateBetween (also filters.chip.textBetween)
  updated: ['Last updated {{time}}', 'છેલ્લે અપડેટ થયું: {{time}}'], // reports.scaffold.updated
  summary: ['Summary', 'સારાંશ'], // reports.components.summary
  total: ['Total', 'કુલ'], // common.total
  // The reviewed wording (2026-10-12), not the app's: the app says '{{total}}માંથી {{shown}} બતાવ્યા છે'
  // (reports.scaffold.showing), where બતાવ્યા is masculine plural and the rows can be feminine or neuter;
  // 'દેખાય છે' has no gender. The placeholders are the same.
  showing: ['Showing {{shown}} of {{total}}', '{{total}}માંથી {{shown}} દેખાય છે'],
  // A fact line on paper ("Sort by | Date (descending)"), so the app's 'સૉર્ટનો ક્રમ' (filters.sheet.sortOrder)
  // and not the command of its sort sheet, 'આ મુજબ સૉર્ટ કરો' (filters.sheet.sortBy).
  sortBy: ['Sort by', 'સૉર્ટનો ક્રમ'],
  // The direction words of components.table.sortedAscending / sortedDescending
  // ('{{column}}, sorted ascending' = '{{column}}, ચઢતા ક્રમમાં સૉર્ટ કરેલું').
  ascending: ['ascending', 'ચઢતા ક્રમમાં'],
  descending: ['descending', 'ઉતરતા ક્રમમાં'],

  // Empty results
  emptyGrns: ['No GRNs in this period', 'આ સમયગાળામાં કોઈ આવક પાવતી નથી'], // reports.grnActivity.emptyTitle
  emptyDispatches: ['No dispatches in this period', 'આ સમયગાળામાં કોઈ જાવક નથી'], // reports.dispatchActivity.emptyTitle
  emptyInvoices: ['No invoices in this period', 'આ સમયગાળામાં કોઈ ઇન્વૉઇસ નથી'], // reports.invoiceHistory.emptyTitle
  emptyActivity: ['No customer activity', 'વેપારીની કોઈ કામગીરી નથી'], // reports.customerActivity.emptyTitle
  emptyStock: ['No stock yet', 'હજુ કોઈ સ્ટોક નથી'], // reports.shared.noStockYet
  emptyCustomerStock: ['No stock for this customer', 'આ વેપારીનો કોઈ સ્ટોક નથી'], // reports.shared.noStockForCustomer

  // Columns and figures
  grn: ['GRN', 'આવક પાવતી'], // common.grn
  // The app's short form of a GRN number (filters.sort.grnNumberChip), which fits the column of short
  // numbers; the long 'આવક પાવતી નંબર' is common.grnNumber.
  grnNumber: ['GRN number', 'આવક નં.'],
  grns: ['GRNs', 'આવક પાવતી'], // reports.customerActivity.grns
  latestGrn: ['Latest GRN', 'છેલ્લી આવક પાવતી'], // reports.sort.latestGrn
  dispatchNumber: ['Dispatch number', 'જાવક નંબર'], // common.dispatchNumber
  dispatches: ['Dispatches', 'જાવક'], // reports.customerActivity.dispatches
  lastDispatch: ['Last dispatch', 'છેલ્લી જાવક'], // reports.stockAging.lastDispatch
  bagsDispatched: ['Bags dispatched', 'જાવકના નંગ'], // reports.dispatchActivity.bagsDispatched
  customersWithDispatches: ['Customers with dispatches', 'જાવકવાળા વેપારી'], // (wording kept from an earlier app version)
  invoiceNumber: ['Invoice number', 'ઇન્વૉઇસ નંબર'], // common.invoiceNumber
  invoices: ['Invoices', 'ઇન્વૉઇસ'], // reports.invoiceHistory.invoices
  invoiced: ['Invoiced', 'ઇન્વૉઇસ બન્યું'], // reports.grnActivity.invoiced
  // The app says 'Latest {{date}}' in an invoice's customer row (reports.invoiceHistory.latestInvoice =
  // 'છેલ્લું {{date}}'); 'Latest' without a date is its word 'છેલ્લું' (neuter, as ઇન્વૉઇસ is) before the
  // app's word for invoices (reports.invoiceHistory.invoices).
  latestInvoice: ['Latest invoice', 'છેલ્લું ઇન્વૉઇસ'],
  amount: ['Amount', 'રકમ'], // common.amount
  tax: ['Tax', 'ટેક્સ'], // invoice.label.tax (also lists.invoice.tax)
  status: ['Status', 'સ્થિતિ'], // users.fields.status
  paid: ['Paid', 'ચૂકવેલ'], // reports.customerActivity.paid
  pending: ['Pending', 'બાકી'], // common.pending
  payment: ['Payment', 'ચુકવણી'], // reports.filters.payment (the Paid / Pending choice)
  date: ['Date', 'તારીખ'], // common.date
  item: ['Item', 'આઇટમ'], // common.item
  items: ['Items', 'આઇટમ'], // common.items
  quantity: ['Quantity', 'નંગ'], // common.quantity
  receivedQuantity: ['Received quantity', 'આવકના નંગ'], // reports.stockAging.receivedQuantity
  weight: ['Weight', 'વજન'], // common.weight
  kg: ['kg', 'કિલો'], // reports.operations.kg
  stock: ['Stock', 'સ્ટોક'], // common.stock
  totalStock: ['Total stock', 'કુલ સ્ટોક'], // reports.operations.totalStock
  unitsInStock: ['Units in stock', 'સ્ટોકમાં નંગ'], // (wording kept from an earlier app version)
  itemsInStorage: ['Items in storage', 'સ્ટોકમાં રહેલી આઇટમ'], // (wording kept from an earlier app version)
  grnsWithStock: ['GRNs with stock', 'સ્ટોકવાળી આવક પાવતી'], // reports.stockSummary.grnsWithStock
  customersWithStock: ['Customers with stock', 'સ્ટોકવાળા વેપારી'], // (wording kept from an earlier app version)
  rack: ['Rack', 'રેક'], // common.rack
  packageMark: ['Package mark', 'માર્કો'], // common.packageMark
  packaging: ['Packaging', 'પેકિંગ'], // common.packaging
  // The column header of the stock aging report, printed with its unit ('કેટલા દિવસથી (દિવસ)'): the app's short
  // form (reports.sort.age). The report's title is its own label, titleStockAging, and keeps the whole clause.
  stockAge: ['Stock age', 'કેટલા દિવસથી'],
  averageAge: ['Average age', 'સરેરાશ કેટલા દિવસથી'], // reports.stockAging.averageAge
  daysUnit: ['days', 'દિવસ'], // reports.stockAging.daysUnit
  overOneYear: ['Over 1 year', '૧ વર્ષથી વધુ'], // (wording kept from an earlier app version)
  // The tile of the oldest stock on the app's stock aging screen: a count of items in its over-364-days bucket.
  itemsOver364: ['Items over 364 days', '૩૬૪ દિવસથી વધુ જૂની આઇટમ'], // reports.stockAging.itemsOver364
  month: ['Month', 'મહિનો'], // reports.customerActivity.trend.month
  stockAtMonthEnd: ['Stock at month end', 'મહિનાના અંતે સ્ટોક'], // reports.customerActivity.trend.stockAtMonthEnd
  city: ['City', 'શહેર'], // customers.fields.city
  // The app's reports.sort.lastActive ('Last active') and reports.customerActivity.lastActive
  // ('Last active {{date}}') are both 'છેલ્લી કામગીરી' (last activity); this column holds that date.
  lastActivity: ['Last activity', 'છેલ્લી કામગીરી'],
} as const satisfies Record<string, readonly [string, string | null]>;

export type LabelKey = keyof typeof table;

export const labelKeys = Object.keys(table) as LabelKey[];

/** English labels that have no Gujarati in the app yet; the PDF prints the English. */
export const missingGujarati: readonly string[] = labelKeys.filter(key => table[key][1] === null).map(key => table[key][0]);

/** The label in the language, with {{name}} placeholders filled. */
export function label(lang: ReportLang, key: LabelKey, values: Record<string, string> = {}): string {
  const entry = table[key];
  const text = (lang === 'gu' ? entry[1] : null) ?? entry[0];
  return text.replace(/\{\{(\w+)\}\}/g, (_, name: string) => values[name] ?? '');
}

/** A label with a unit after it, as "Weight (kg)". */
export function withUnit(lang: ReportLang, key: LabelKey, unit: LabelKey): string {
  return `${label(lang, key)} (${label(lang, unit)})`;
}
