// The TallyPrime import files of the accountant pack (WH-158; contract product/tech/accountant-pack.md section 6, decision D4).
// Every element and attribute name, fixed value and the voucher identity live in the frozen TALLY object; the builders below read
// names only from it, so a fix found at the pilot import edits TALLY alone. The builders lay out what they are given: the amounts,
// already worked out in paise and formatted, come from accountant-pack-files.ts. Output is deterministic (no clock, fixed order).

type DeepReadonly<T> = { readonly [K in keyof T]: T[K] extends (...args: never[]) => unknown ? T[K] : DeepReadonly<T[K]> };

function deepFreeze<T extends object>(value: T): DeepReadonly<T> {
  for (const key of Object.keys(value)) {
    const inner = (value as Record<string, unknown>)[key];
    if (inner && typeof inner === 'object') deepFreeze(inner as object);
  }
  return Object.freeze(value) as DeepReadonly<T>;
}

export type TallyVoucherKind = 'sales' | 'receipt';

const GUID_PREFIX = { sales: 'wh-inv-', receipt: 'wh-rcp-' } as const;

export const TALLY = deepFreeze({
  declaration: '<?xml version="1.0" encoding="UTF-8"?>',
  tag: {
    envelope: 'ENVELOPE', header: 'HEADER', tallyRequest: 'TALLYREQUEST', body: 'BODY', importData: 'IMPORTDATA', requestDesc: 'REQUESTDESC',
    reportName: 'REPORTNAME', requestData: 'REQUESTDATA', tallyMessage: 'TALLYMESSAGE',
    ledger: 'LEDGER', name: 'NAME', parent: 'PARENT', gstRegistration: 'LEDGSTREGDETAILS.LIST', registrationType: 'GSTREGISTRATIONTYPE',
    gstin: 'GSTIN', placeOfSupply: 'PLACEOFSUPPLY', mailing: 'LEDMAILINGDETAILS.LIST', state: 'STATE', country: 'COUNTRY',
    voucher: 'VOUCHER', date: 'DATE', guid: 'GUID', voucherTypeName: 'VOUCHERTYPENAME', voucherNumber: 'VOUCHERNUMBER',
    partyLedgerName: 'PARTYLEDGERNAME', isCancelled: 'ISCANCELLED', narration: 'NARRATION', entry: 'ALLLEDGERENTRIES.LIST',
    ledgerName: 'LEDGERNAME', isDeemedPositive: 'ISDEEMEDPOSITIVE', isPartyLedger: 'ISPARTYLEDGER', amount: 'AMOUNT',
  },
  attr: { name: 'NAME', action: 'ACTION', remoteId: 'REMOTEID', vchType: 'VCHTYPE', objView: 'OBJVIEW', udf: 'xmlns:UDF' },
  value: {
    importData: 'Import Data', mastersReport: 'All Masters', vouchersReport: 'Vouchers', udf: 'TallyUDF', create: 'Create',
    objView: 'Accounting Voucher View', debtorsGroup: 'Sundry Debtors', registered: 'Regular', unregistered: 'Unregistered/Consumer',
    country: 'India', yes: 'Yes', no: 'No',
  },
  voucherType: { sales: 'Sales', receipt: 'Receipt' },
  /** The voucher's identity in Tally (REMOTEID and GUID): the same for the same app record in every pack. */
  guid(kind: TallyVoucherKind, id: string): string {
    const prefix = GUID_PREFIX[kind];
    if (!prefix) throw new Error(`TALLY.guid: unknown voucher kind ${String(kind)}`);
    return `${prefix}${id}`;
  },
});

/** A customer ledger of tally-masters.xml. */
export interface TallyLedger { name: string; gstin: string | null; state: string | null }

/** One ledger entry: `amount` formatted with two decimals, negative for a debit. */
export interface TallyEntry { ledger: string; amount: string; debit: boolean; party: boolean }

/** A voucher of tally-vouchers.xml; `cancelled` writes the cancellation form (no party, no entries). Dates are YYYYMMDD. */
export interface TallyVoucher {
  kind: TallyVoucherKind; id: string; date: string; number: string; party: string | null; narration: string;
  entries: TallyEntry[]; cancelled: boolean;
}

// Characters XML 1.0 does not allow: C0 controls other than tab, LF and CR, U+FFFE, U+FFFF and unpaired surrogates.
const NOT_XML = /[\u0000-\u0008\u000B\u000C\u000E-\u001F￾￿]|[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/g;
const ESCAPES: Record<string, string> = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&apos;', '\t': '&#9;', '\n': '&#10;', '\r': '&#13;' };

/** Text or an attribute value, safe in XML 1.0: forbidden characters removed, markup and white space other than a plain space escaped. */
export function xmlText(value: unknown): string {
  return String(value ?? '').replace(NOT_XML, '').replace(/[&<>"'\t\n\r]/g, c => ESCAPES[c]);
}

const element = (tag: string, text: string): string => `<${tag}>${xmlText(text)}</${tag}>`;

function envelope(report: string, objects: string[]): string {
  const t = TALLY.tag;
  return [
    TALLY.declaration,
    `<${t.envelope}>`,
    ` <${t.header}>`,
    `  ${element(t.tallyRequest, TALLY.value.importData)}`,
    ` </${t.header}>`,
    ` <${t.body}>`,
    `  <${t.importData}>`,
    `   <${t.requestDesc}>`,
    `    ${element(t.reportName, report)}`,
    `   </${t.requestDesc}>`,
    `   <${t.requestData}>`,
    `    <${t.tallyMessage} ${TALLY.attr.udf}="${xmlText(TALLY.value.udf)}">`,
    ...objects,
    `    </${t.tallyMessage}>`,
    `   </${t.requestData}>`,
    `  </${t.importData}>`,
    ` </${t.body}>`,
    `</${t.envelope}>`,
    '',
  ].join('\n');
}

function ledgerXml(ledger: TallyLedger): string {
  const t = TALLY.tag; const v = TALLY.value; const a = TALLY.attr;
  const registration = [element(t.registrationType, ledger.gstin ? v.registered : v.unregistered)];
  if (ledger.gstin) registration.push(element(t.gstin, ledger.gstin));
  if (ledger.state) registration.push(element(t.placeOfSupply, ledger.state));
  const mailing = [];
  if (ledger.state) mailing.push(element(t.state, ledger.state));
  mailing.push(element(t.country, v.country));
  return [
    `     <${t.ledger} ${a.name}="${xmlText(ledger.name)}" ${a.action}="${xmlText(v.create)}">`,
    `      ${element(t.name, ledger.name)}`,
    `      ${element(t.parent, v.debtorsGroup)}`,
    `      <${t.gstRegistration}>${registration.join('')}</${t.gstRegistration}>`,
    `      <${t.mailing}>${mailing.join('')}</${t.mailing}>`,
    `     </${t.ledger}>`,
  ].join('\n');
}

function voucherXml(voucher: TallyVoucher): string {
  const t = TALLY.tag; const v = TALLY.value; const a = TALLY.attr;
  const guid = TALLY.guid(voucher.kind, voucher.id);
  const type = TALLY.voucherType[voucher.kind];
  const lines = [
    `     <${t.voucher} ${a.remoteId}="${xmlText(guid)}" ${a.vchType}="${xmlText(type)}" ${a.action}="${xmlText(v.create)}" ${a.objView}="${xmlText(v.objView)}">`,
    `      ${element(t.date, voucher.date)}${element(t.guid, guid)}${element(t.voucherTypeName, type)}${element(t.voucherNumber, voucher.number)}`,
  ];
  if (voucher.cancelled) {
    lines.push(`      ${element(t.isCancelled, v.yes)}${element(t.narration, voucher.narration)}`);
  } else {
    lines.push(`      ${voucher.party !== null ? element(t.partyLedgerName, voucher.party) : ''}${element(t.narration, voucher.narration)}`);
    for (const e of voucher.entries) {
      lines.push(`      <${t.entry}>${element(t.ledgerName, e.ledger)}${element(t.isDeemedPositive, e.debit ? v.yes : v.no)}` +
        `${e.party ? element(t.isPartyLedger, v.yes) : ''}${element(t.amount, e.amount)}</${t.entry}>`);
    }
  }
  lines.push(`     </${t.voucher}>`);
  return lines.join('\n');
}

/** tally-masters.xml: one Sundry Debtors ledger per customer, in the order given. */
export function tallyMastersXml(ledgers: TallyLedger[]): string {
  return envelope(TALLY.value.mastersReport, ledgers.map(ledgerXml));
}

/** tally-vouchers.xml: the vouchers in the order given. */
export function tallyVouchersXml(vouchers: TallyVoucher[]): string {
  return envelope(TALLY.value.vouchersReport, vouchers.map(voucherXml));
}
