# Privacy for operators

This is a short guide for the facility that runs this server. You decide why and how the personal data in the app is used, so under India's Digital Personal Data Protection Act, 2023 you are the Data Fiduciary. The app's terms of use and privacy notice are written for that: the facility is the only party. This note is not legal advice.

> **Release gate (WH-140).** The template text of the terms and the privacy notice in the app has not been reviewed by a lawyer. Do not distribute a public build of the app before the owner of the app's release has recorded that review and replaced the text (the app's `LEGAL_TEXT_REVIEWED` constant).

## What the server stores about people

| Data | Where | How long |
|---|---|---|
| Staff and customer logins: mobile number, name, role | `user_profiles` | Until the person deletes their account (`delete_user_account`; the row stays, with the number and name replaced) |
| Customers (the businesses): name, address, phone, GSTIN, PAN | `customers` | As long as the business has records. A business is deactivated, not deleted, once it has data |
| GRNs, dispatches, invoices, orders, stock, with the name of who recorded them | the business tables | Kept as long as GST and company law require; the server never deletes them on a schedule |
| Photos of goods and documents | `grn-images`, `dispatch-images` buckets | Kept with their GRN or dispatch. Unfinished uploads are removed after 24 hours |
| Each signed-in phone: the IP address it signed in from and the app's description (user agent, cut to 300 characters) | the session table | Until the session ends or the person signs out; sign-in records are removed by the daily retention pass |
| The security log (who did what) | `audit_log` | 8 years (2920 days) |
| Generated PDFs | the private `documents` bucket | 7 days |
| Backups | the USB drive and `<state>/backups` | The newest 7 on the host; the USB drive is not pruned |

Nothing else about people leaves the server: there is no central data store. The SMS provider receives a number and a code when someone signs in. Where your copy of the app uses an association's sign-in, the association keeps the mobile number and name. Crash reports go out only if the distributor of the app build switched them on ([TELEMETRY_AND_PRIVACY.md](TELEMETRY_AND_PRIVACY.md)).

## Answering a person's request

A person may ask what you hold about them, ask for a correction, ask for erasure, or nominate someone to act for them. Requests go to the grievance contact you set below. Answer in a reasonable time and keep a note of the request and your answer.

- **See their data.** For a login: Users, then the person (name, number, role, customers, sessions). For a customer business: Customers, then the business. Give a short summary and what it is used for (the privacy notice lists the uses).
- **Correct or complete.** Users or Customers, Edit. The change is recorded in the audit log.
- **Erase.** A login: a person deletes their own account with `delete_user_account` (it replaces their number and name and ends their sessions; their profile row stays). For anyone else, an administrator or supervisor switches the person off (Users, then the person, status off: `update_user_status`), which ends their sessions and closes access. A customer business with records cannot be erased: deactivate it (Customers, switch off Active), which hides it from the pickers (`set_customer_active`).
- **What cannot be erased.** GRNs, dispatches, invoices and the figures on them, and the customer details printed on an invoice, while GST or company law requires you to keep them. Tell the person this and which law, and erase the rest. The same holds for audit log lines for their retention period.
- **A complaint.** If the person is not satisfied with your answer they may complain to the Data Protection Board of India. The privacy notice says so.

## Setting the grievance contact

The terms and the privacy notice name the facility, the city and state of its courts, and a grievance officer. Set them at install or later with `setup.sh` (the same options on a rerun change the values; leaving them out keeps what is stored):

```bash
bash setup.sh --operator <your usual options> \
  --legal-name "Gujarat Example Cold Storage Pvt Ltd" --legal-city Ahmedabad --legal-state Gujarat \
  --grievance-name "A. Patel" --grievance-email grievance@example.in --grievance-phone "+91 98765 43210"
```

- `--legal-name` defaults to the company name. An empty value (`--legal-city ""`) clears a setting.
- The app has no screen for these values yet: set them with `setup.sh` as above. The `set_facility_legal` RPC (administrators only) changes the same six values for a future app screen. Every change, by setup or through the RPC, is written to the audit log (`facility_legal`, old and new values). The six values are one settings row (`system_settings`, key `facility_legal`).
- The values are public: the app reads them without signing in (`legal` in the public configuration) and prints them.
- `node scripts/doctor.mjs` warns when the city, state, grievance name, email or phone is empty. The app then prints "Not given yet" in their place. A public facility should fill all of them.
