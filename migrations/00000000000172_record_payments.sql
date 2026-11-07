-- Migration 172: administrators and supervisors record what a customer pays against an invoice (WH-143).
--
--  1. The switch. warehouse_security.charging_rule (migrations 164, 165) gains record_payments boolean, default false: the facility's
--     "Record payments" setting on the Charging screen. set_record_payments(p_enabled) changes it (administrators only; a change is one
--     audit_log row through the charging rule's audit trigger, the same value again writes nothing). get_public_config answers it as
--     record_payments, and get-public-config serves it as capabilities.payments: from this migration the database, not instance.json, says
--     whether payments are on (scripts/set-capability.mjs refuses payments and points to the app setting).
--     Carried over once: an installation that had capabilities.payments on in instance.json keeps payments on. A migration can not read
--     the state's files, so scripts/migrate.sh, after the plan, reads that flag and calls warehouse_security.carry_payments_capability:
--     the first call turns record_payments on if the file said on (one audit_log row, through the trigger) and marks the carry-over done
--     (payments_carried_over); every later call changes nothing, so an administrator's later choice is never overridden.
--     Turning it off hides payments in the app and keeps every row; the invoice refusals of item 5 hold whether it is on or off.
--  2. payments. Rows entered in the app carry paid_on (the payment day, an India day); rows that came from the old accounting link keep
--     paid_on NULL, stay readable and count as before, and can not be edited or deleted through the app. New columns: paid_on, updated_at,
--     updated_by. payment_mode widens to 20 characters (bank_transfer is 13). A row with paid_on must name an invoice and an amount, a mode
--     of cash, upi, bank_transfer, cheque or other, and a note of at most 200 characters. payment_no of an app row is APP-<n> from a
--     sequence. payments.invoice_id becomes ON DELETE RESTRICT (it was SET NULL): an invoice with payments is never removed under them.
--  3. record_payment, update_payment, delete_payment (administrators and supervisors; authorize_rpc admits them and refuses staff and
--     customers; the body checks the role too). With the switch off: PAYMENTS_OFF (WH409). The invoice row is locked FOR UPDATE (after the
--     list-refresh lock 71040, as cancel_invoice and delete_invoice take them) before the amount due is read, so two payments at the same
--     moment take turns and the second sees the first. The rules, on a create and an edit alike:
--       - the day is not after today in India: PAYMENT_DATE_FUTURE {date, today} (error_code WH422);
--       - the day is not before the invoice day: PAYMENT_BEFORE_INVOICE {date, invoice_date} (WH422);
--       - the amount is more than 0 with at most two decimals, else 22023; it is at most the amount due: PAYMENT_OVER_DUE {due, paid, total}
--         (WH409). Due = invoice total - the sum of the invoice's payments (an edit leaves the edited payment out of that sum), never below 0.
--         No overpayment, credit or advance is ever recorded (spec non-goal).
--       - mode one of the five above, note at most 200 characters once trimmed (blank: none), else 22023.
--     Not recorded on a cancelled invoice (INVOICE_CANCELLED) or an unknown or deleted one (INVOICE_NOT_FOUND). update_payment takes the
--     version the form read (p_expected_updated_at, required): STALE_RECORD when it changed. A row from the accounting link: PAYMENT_NOT_EDITABLE.
--     All three take p_request_id: the first success answer is kept 7 days under the user (idempotency_keys), a resend of the same request
--     returns it and writes nothing, and get_submission_result finds it (W22). Every insert, update and delete of a payment writes an
--     audit_log row with the old and the new row (audit_payments, audit_payments_update, migration 134).
--  4. No payment on a cancelled or deleted invoice, whoever writes it (WH-99): the payments trigger of migration 134 now locks the invoice
--     row FOR KEY SHARE whether or not it is cancelled, so a payment written while cancel_invoice runs waits for the cancel and is refused,
--     or the cancel waits for the payment and is refused (INVOICE_HAS_PAYMENTS). It also refuses an invoice that is soft-deleted.
--  5. Invoices with payments: cancel_invoice and delete_invoice answer INVOICE_HAS_PAYMENTS with the invoice number (inv_no, inv_fin_year;
--     their error texts are unchanged). update_invoice refuses an edit whose recalculated total is lower than both the paid sum and the
--     total before the edit: TOTAL_BELOW_PAID {paid, total} (WH409, nothing saved). The same rule is checked at commit for every other
--     write of invoice.total (a deferred constraint trigger), so no path can take a paid invoice's total below what was paid.
--  6. Reads. warehouse_security.invoice_payment_state(invoice) = {paid_amount, due_amount, payment_status}; payment_status is 'due' (nothing
--     paid), 'part_paid' or 'paid' (nothing due; an invoice of 0 is 'paid'), and NULL with due 0 for a cancelled invoice. The rule is exact:
--     a balance of 0.50 is still due (the 0.50 tolerance of the older report status, migration 62, is unchanged there).
--       - get_invoices_list answers the three fields on each row and takes p_payment_status ('due', 'part_paid', 'paid'; the signature
--         grows by one defaulted parameter, the old one is dropped). For administrators and supervisors only: staff see no figure and are
--         refused the filter.
--       - get_invoice_detail and get_invoice_data (definition files) answer the three fields, and the detail a payments[] list, to
--         administrators, supervisors and the invoice's customer; staff see nothing new.
--       - get_customer_activity_detail: total_paid_amount also counts the customer's payments that name no invoice (accounting-link rows),
--         by payment day in the period. get_customer_invoice_summary (one customer): summary.unlinked_paid_amount, the same rows; its
--         per-invoice figures and paid_amount (which add up to the invoice totals) are unchanged.
--
-- Money, worked by hand (made-up figures): invoice 2026-7001 of 1000.00 dated 2026-05-02. record 400.00 on 2026-05-03: paid 400, due 600,
-- part_paid. record 600.00: paid 1000, due 0, paid. record 1.00: PAYMENT_OVER_DUE {due 0}. Edit the 400.00 to 450.00: the others sum 600,
-- due for the edit 400, refused {due 400}; edit it to 350.00: paid 950, due 50, part_paid. update_invoice taking the total from 1000 to 900
-- with 950 paid: TOTAL_BELOW_PAID {paid 950, total 900}; to 1200: allowed, due 250, part_paid. A payment dated 2026-05-01: PAYMENT_BEFORE_INVOICE.
--
-- The function patches are the marker-count pattern of migration 134 (each marker found exactly once, no replacement contains its marker).

-- Section 1: the switch
ALTER TABLE warehouse_security.charging_rule ADD COLUMN record_payments boolean DEFAULT false NOT NULL;
ALTER TABLE warehouse_security.charging_rule ADD COLUMN payments_carried_over boolean DEFAULT false NOT NULL;
COMMENT ON COLUMN warehouse_security.charging_rule.payments_carried_over IS 'Migration 172: true once scripts/migrate.sh carried the instance.json payments flag over to record_payments.';
COMMENT ON COLUMN warehouse_security.charging_rule.record_payments IS 'Migration 172: "Record payments": administrators and supervisors record payments against invoices, and the app shows what is paid and due. Served as capabilities.payments.';

DROP TRIGGER audit_charging_rule_update ON warehouse_security.charging_rule;
CREATE TRIGGER audit_charging_rule_update AFTER UPDATE ON warehouse_security.charging_rule FOR EACH ROW
  WHEN (ROW(OLD.step_days, OLD.minimum_days, OLD.days_counted, OLD.rounding, OLD.invoice_as_goods_leave, OLD.record_payments)
        IS DISTINCT FROM ROW(NEW.step_days, NEW.minimum_days, NEW.days_counted, NEW.rounding, NEW.invoice_as_goods_leave, NEW.record_payments))
  EXECUTE FUNCTION public.audit_trigger_func();

CREATE FUNCTION warehouse_security.payments_enabled() RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog'
    AS $$
  SELECT COALESCE((SELECT r.record_payments FROM warehouse_security.charging_rule r WHERE r.id), false)
$$;
ALTER FUNCTION warehouse_security.payments_enabled() OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.payments_enabled() FROM PUBLIC;

-- Called by scripts/migrate.sh (the database owner, no app role has a grant) with the payments flag of instance.json. Once only:
-- 'carried_on' (switched on), 'kept_off' (the file said off), 'already' (done before; nothing changes).
CREATE FUNCTION warehouse_security.carry_payments_capability(p_file_on boolean) RETURNS text
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog'
    AS $$
DECLARE
  v_done boolean;
BEGIN
  SELECT r.payments_carried_over INTO v_done FROM warehouse_security.charging_rule r WHERE r.id FOR UPDATE;
  IF v_done THEN
    RETURN 'already';
  END IF;
  -- Two statements: the first is the audited change (record_payments), the second only marks the carry-over (not audited).
  IF COALESCE(p_file_on, false) THEN
    UPDATE warehouse_security.charging_rule r SET record_payments = true, updated_at = now() WHERE r.id AND NOT r.record_payments;
  END IF;
  UPDATE warehouse_security.charging_rule r SET payments_carried_over = true WHERE r.id;
  RETURN CASE WHEN COALESCE(p_file_on, false) THEN 'carried_on' ELSE 'kept_off' END;
END $$;
ALTER FUNCTION warehouse_security.carry_payments_capability(boolean) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.carry_payments_capability(boolean) FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.set_record_payments(p_enabled boolean) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $$
DECLARE
  v_old boolean;
  v_new warehouse_security.charging_rule;
  v_changed boolean;
BEGIN
  PERFORM warehouse_security.authorize_rpc('set_record_payments', jsonb_build_object());
  IF warehouse_security.active_role() IS DISTINCT FROM 'admin' AND auth.jwt()->>'role' IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Administrator required' USING ERRCODE = '42501';
  END IF;
  IF p_enabled IS NULL THEN
    RAISE EXCEPTION 'p_enabled must be true or false' USING ERRCODE = '22023';
  END IF;
  SELECT r.record_payments INTO v_old FROM warehouse_security.charging_rule r WHERE r.id FOR UPDATE;
  UPDATE warehouse_security.charging_rule r
     SET record_payments = p_enabled, updated_by = public.get_current_user_profile_id(), updated_at = now()
   WHERE r.id AND r.record_payments IS DISTINCT FROM p_enabled
  RETURNING r.* INTO v_new;
  v_changed := FOUND;
  IF NOT v_changed THEN
    SELECT r.* INTO v_new FROM warehouse_security.charging_rule r WHERE r.id;
  END IF;
  RETURN jsonb_build_object('success', true, 'changed', v_changed, 'record_payments', v_new.record_payments, 'previous', v_old,
    'updated_at', v_new.updated_at, 'updated_by', v_new.updated_by,
    'updated_by_name', (SELECT p.name FROM public.user_profiles p WHERE p.id = v_new.updated_by));
END $$;
ALTER FUNCTION public.set_record_payments(boolean) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.set_record_payments(boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.set_record_payments(boolean) TO authenticated, service_role;

-- The public configuration carries the switch (the anon key reads it through this function only).
CREATE OR REPLACE FUNCTION public.get_public_config(p_environment text) RETURNS json
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
  SELECT json_build_object(
    'app_version', c.app_version,
    'maintenance_mode', c.maintenance_mode,
    'feature_flags', COALESCE((SELECT json_object_agg(f.name, f.enabled) FROM public.feature_flags f), '{}'::json),
    'record_payments', COALESCE((SELECT r.record_payments FROM warehouse_security.charging_rule r WHERE r.id), false))
  FROM public.api_configurations c
  WHERE c.environment = p_environment AND c.is_active
$$;

-- Section 2: payments
ALTER TABLE public.payments ALTER COLUMN payment_mode TYPE character varying(20);
ALTER TABLE public.payments
  ADD COLUMN paid_on date,
  ADD COLUMN updated_at timestamptz DEFAULT now() NOT NULL,
  ADD COLUMN updated_by uuid,
  ADD CONSTRAINT payments_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  ADD CONSTRAINT payments_app_row_check CHECK (paid_on IS NULL OR (
    invoice_id IS NOT NULL AND amount IS NOT NULL
    AND payment_mode IN ('cash', 'upi', 'bank_transfer', 'cheque', 'other')
    AND (note IS NULL OR char_length(note) <= 200)));
COMMENT ON COLUMN public.payments.paid_on IS 'Migration 172: the payment day (India) of a payment recorded in the app; NULL on rows from the old accounting link, which the app does not edit.';
CREATE INDEX idx_payments_updated_by ON public.payments USING btree (updated_by);

ALTER TABLE public.payments DROP CONSTRAINT payments_invoice_id_fkey;
ALTER TABLE public.payments ADD CONSTRAINT payments_invoice_id_fkey FOREIGN KEY (invoice_id) REFERENCES public.invoice(id) ON DELETE RESTRICT NOT VALID;
ALTER TABLE public.payments VALIDATE CONSTRAINT payments_invoice_id_fkey;

CREATE SEQUENCE public.payments_app_no_seq AS bigint;
ALTER SEQUENCE public.payments_app_no_seq OWNER TO supabase_admin;
REVOKE ALL ON SEQUENCE public.payments_app_no_seq FROM PUBLIC, anon, authenticated;

-- Section 3: no payment on a cancelled or deleted invoice (WH-99). The row is locked whatever its state, so a cancel in progress
-- (FOR UPDATE) is waited for and its result seen.
CREATE OR REPLACE FUNCTION warehouse_security.refuse_payment_for_cancelled_invoice() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
DECLARE
  v_cancelled_at timestamptz;
  v_deleted_at timestamptz;
BEGIN
  IF NEW.invoice_id IS NULL THEN
    RETURN NEW;
  END IF;
  SELECT i.cancelled_at, i.deleted_at INTO v_cancelled_at, v_deleted_at FROM public.invoice i WHERE i.id = NEW.invoice_id FOR KEY SHARE;
  -- An unknown invoice is answered by the foreign key.
  IF v_cancelled_at IS NOT NULL THEN
    RAISE EXCEPTION 'Invoice % is cancelled: no payment can be recorded for it', NEW.invoice_id USING ERRCODE = 'WH409';
  END IF;
  IF v_deleted_at IS NOT NULL THEN
    RAISE EXCEPTION 'Invoice % is deleted: no payment can be recorded for it', NEW.invoice_id USING ERRCODE = 'WH409';
  END IF;
  RETURN NEW;
END $$;

-- Section 4: helpers
-- What is paid and due on one invoice. Exact: nothing is forgiven. A cancelled invoice owes nothing and has no status.
CREATE FUNCTION warehouse_security.invoice_payment_state(p_invoice_id uuid) RETURNS jsonb
    LANGUAGE sql STABLE
    SET search_path TO 'pg_catalog', 'public'
    AS $$
  SELECT jsonb_build_object(
           'paid_amount', s.paid,
           'due_amount', CASE WHEN s.cancelled THEN 0 ELSE GREATEST(s.total - s.paid, 0) END,
           'payment_status', CASE WHEN s.cancelled THEN NULL
                                  WHEN s.total - s.paid <= 0 THEN 'paid'
                                  WHEN s.paid > 0 THEN 'part_paid'
                                  ELSE 'due' END)
    FROM (SELECT COALESCE(i.total, 0)::numeric(12,2) AS total,
                 i.cancelled_at IS NOT NULL AS cancelled,
                 COALESCE((SELECT sum(p.amount) FROM public.payments p WHERE p.invoice_id = i.id), 0)::numeric(14,2) AS paid
            FROM public.invoice i WHERE i.id = p_invoice_id) s
$$;
ALTER FUNCTION warehouse_security.invoice_payment_state(uuid) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.invoice_payment_state(uuid) FROM PUBLIC;

-- One payment as the app reads it. recorded_in_app: entered through record_payment (editable); false for an accounting-link row.
CREATE FUNCTION warehouse_security.payment_json(p public.payments) RETURNS jsonb
    LANGUAGE sql STABLE
    SET search_path TO 'pg_catalog', 'public'
    AS $$
  SELECT jsonb_build_object(
    'id', p.id, 'payment_no', p.payment_no, 'invoice_id', p.invoice_id,
    'paid_on', to_char(COALESCE(p.paid_on, warehouse_security.business_date(p.payment_date)), 'YYYY-MM-DD'),
    'amount', p.amount, 'mode', p.payment_mode, 'note', p.note,
    'entered_by', p.supervisor_id, 'entered_by_name', p.supervisor_name,
    'updated_at', p.updated_at, 'updated_by', p.updated_by,
    'recorded_in_app', p.paid_on IS NOT NULL)
$$;
ALTER FUNCTION warehouse_security.payment_json(public.payments) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.payment_json(public.payments) FROM PUBLIC;

-- The payments of a customer that name no invoice (the old accounting link), by payment day (India) in [from, to] and, when given, in the
-- financial year that starts on 1 April of p_fin_year.
CREATE FUNCTION warehouse_security.unlinked_payments_total(p_customer_id uuid, p_from date, p_to date, p_fin_year integer DEFAULT NULL) RETURNS numeric
    LANGUAGE sql STABLE
    SET search_path TO 'pg_catalog', 'public'
    AS $$
  SELECT COALESCE(sum(p.amount), 0)
    FROM public.payments p
   WHERE p.invoice_id IS NULL AND p.customer_id = p_customer_id
     AND (p_from IS NULL OR p.payment_date >= warehouse_security.business_day_start(p_from))
     AND (p_to IS NULL OR p.payment_date < warehouse_security.business_day_start(p_to + 1))
     AND (p_fin_year IS NULL OR (p.payment_date >= warehouse_security.business_day_start(make_date(p_fin_year, 4, 1))
                                 AND p.payment_date < warehouse_security.business_day_start(make_date(p_fin_year + 1, 4, 1))))
$$;
ALTER FUNCTION warehouse_security.unlinked_payments_total(uuid, date, date, integer) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.unlinked_payments_total(uuid, date, date, integer) FROM PUBLIC;

-- The four inputs of a payment form, the same on a create and an edit. Answers the note as stored (trimmed, blank = NULL).
CREATE FUNCTION warehouse_security.checked_payment_note(p_paid_on date, p_amount numeric, p_mode text, p_note text) RETURNS text
    LANGUAGE plpgsql IMMUTABLE
    SET search_path TO 'pg_catalog'
    AS $$
DECLARE
  v_note text := NULLIF(btrim(p_note), '');
BEGIN
  IF p_paid_on IS NULL THEN
    RAISE EXCEPTION 'Give the payment date' USING ERRCODE = '22023';
  END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'The amount must be more than 0' USING ERRCODE = '22023';
  END IF;
  IF p_amount <> round(p_amount, 2) THEN
    RAISE EXCEPTION 'The amount has at most two decimals' USING ERRCODE = '22023';
  END IF;
  IF p_mode IS NULL OR p_mode NOT IN ('cash', 'upi', 'bank_transfer', 'cheque', 'other') THEN
    RAISE EXCEPTION 'mode must be cash, upi, bank_transfer, cheque or other' USING ERRCODE = '22023';
  END IF;
  IF char_length(v_note) > 200 THEN
    RAISE EXCEPTION 'The note has at most 200 characters' USING ERRCODE = '22023';
  END IF;
  RETURN v_note;
END $$;
ALTER FUNCTION warehouse_security.checked_payment_note(date, numeric, text, text) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.checked_payment_note(date, numeric, text, text) FROM PUBLIC;

-- The day rules against a locked invoice. NULL when the day is allowed, else the refusal (WH422).
CREATE FUNCTION warehouse_security.payment_day_refusal(p_paid_on date, p_inv_date timestamptz) RETURNS jsonb
    LANGUAGE plpgsql STABLE
    SET search_path TO 'pg_catalog'
    AS $$
DECLARE
  v_today date := warehouse_security.business_date(now());
  v_invoice_day date := warehouse_security.business_date(p_inv_date);
BEGIN
  IF p_paid_on > v_today THEN
    RETURN warehouse_security.refuse('PAYMENT_DATE_FUTURE',
      format('A payment can''t be dated in the future. Today is %s.', to_char(v_today, 'YYYY-MM-DD')),
      jsonb_build_object('date', to_char(p_paid_on, 'YYYY-MM-DD'), 'today', to_char(v_today, 'YYYY-MM-DD')))
      || jsonb_build_object('error_code', 'WH422');
  END IF;
  IF p_paid_on < v_invoice_day THEN
    RETURN warehouse_security.refuse('PAYMENT_BEFORE_INVOICE',
      format('A payment can''t be dated before the invoice (%s).', to_char(v_invoice_day, 'YYYY-MM-DD')),
      jsonb_build_object('date', to_char(p_paid_on, 'YYYY-MM-DD'), 'invoice_date', to_char(v_invoice_day, 'YYYY-MM-DD')))
      || jsonb_build_object('error_code', 'WH422');
  END IF;
  RETURN NULL;
END $$;
ALTER FUNCTION warehouse_security.payment_day_refusal(date, timestamptz) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.payment_day_refusal(date, timestamptz) FROM PUBLIC;

-- A replayed answer of this user for this request (W22), or NULL. The key is locked first, so two sends of one request take turns.
CREATE FUNCTION warehouse_security.payment_replay(p_rpc text, p_key text, p_profile uuid) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog', 'public'
    AS $$
DECLARE
  v_cached jsonb;
BEGIN
  IF p_key IS NULL THEN
    RETURN NULL;
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('payment_key:' || p_key, 0));
  SELECT k.response INTO v_cached FROM public.idempotency_keys k
   WHERE k.idempotency_key = p_key AND k.rpc_function = p_rpc AND k.created_by = p_profile AND k.expires_at > now();
  RETURN v_cached;
END $$;
ALTER FUNCTION warehouse_security.payment_replay(text, text, uuid) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.payment_replay(text, text, uuid) FROM PUBLIC;

-- Keeps a success answer for 7 days under the user; a key that another function or user holds is left alone unless it has expired.
CREATE FUNCTION warehouse_security.payment_keep_answer(p_rpc text, p_key text, p_profile uuid, p_answer jsonb) RETURNS void
    LANGUAGE sql
    SET search_path TO 'pg_catalog', 'public'
    AS $$
  INSERT INTO public.idempotency_keys (idempotency_key, rpc_function, response, created_by, expires_at)
  SELECT p_key, p_rpc, p_answer, p_profile, now() + interval '7 days'
   WHERE p_key IS NOT NULL
  ON CONFLICT (idempotency_key) DO UPDATE SET
    rpc_function = EXCLUDED.rpc_function, response = EXCLUDED.response, created_by = EXCLUDED.created_by,
    created_at = now(), expires_at = EXCLUDED.expires_at
  WHERE idempotency_keys.expires_at <= now()
     OR (idempotency_keys.rpc_function = EXCLUDED.rpc_function AND idempotency_keys.created_by IS NOT DISTINCT FROM EXCLUDED.created_by)
$$;
ALTER FUNCTION warehouse_security.payment_keep_answer(text, text, uuid, jsonb) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.payment_keep_answer(text, text, uuid, jsonb) FROM PUBLIC;

-- Section 5: record_payment, update_payment, delete_payment
CREATE FUNCTION public.record_payment(p_invoice_id uuid, p_paid_on date, p_amount numeric, p_mode text,
                                      p_note text DEFAULT NULL, p_request_id text DEFAULT NULL) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $$
DECLARE
  v_key text := NULLIF(btrim(p_request_id), '');
  v_profile uuid;
  v_profile_name text;
  v_cached jsonb;
  v_note text;
  v_inv record;
  v_refusal jsonb;
  v_paid numeric;
  v_due numeric;
  v_payment public.payments;
  v_result jsonb;
BEGIN
  PERFORM warehouse_security.authorize_rpc('record_payment', jsonb_build_object('p_invoice_id', p_invoice_id));
  IF COALESCE(warehouse_security.active_role(), '') NOT IN ('admin', 'supervisor') AND auth.jwt()->>'role' IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Administrator or supervisor required' USING ERRCODE = '42501';
  END IF;
  SELECT p.id, p.name INTO v_profile, v_profile_name FROM public.user_profiles p WHERE p.id = public.get_current_user_profile_id();
  IF v_profile IS NULL THEN
    RETURN warehouse_security.refuse('USER_REQUIRED', 'A payment is recorded by a signed-in person.');
  END IF;

  -- W22: this user's first answer for the request is returned as it was, while the payment it recorded exists.
  v_cached := warehouse_security.payment_replay('record_payment', v_key, v_profile);
  IF v_cached IS NOT NULL AND v_cached->>'invoice_id' = p_invoice_id::text
     AND EXISTS (SELECT 1 FROM public.payments p WHERE p.id::text = v_cached->>'payment_id') THEN
    RETURN v_cached;
  END IF;

  IF NOT warehouse_security.payments_enabled() THEN
    RETURN warehouse_security.refuse('PAYMENTS_OFF', 'Record payments is turned off for this facility.');
  END IF;
  v_note := warehouse_security.checked_payment_note(p_paid_on, p_amount, p_mode, p_note);

  -- The list-refresh lock comes before any row lock (migration 46); the invoice row lock makes payments on one invoice take turns.
  PERFORM pg_advisory_xact_lock(71040);
  SELECT i.id, i.inv_no, i.inv_fin_year, i.inv_date, i.total, i.customer_id, i.cancelled_at,
         (SELECT c.name FROM public.customers c WHERE c.id = i.customer_id) AS customer_name
    INTO v_inv
    FROM public.invoice i WHERE i.id = p_invoice_id AND i.deleted_at IS NULL FOR UPDATE OF i;
  IF NOT FOUND THEN
    RETURN warehouse_security.refuse('INVOICE_NOT_FOUND', 'Invoice not found', jsonb_build_object('invoice_id', p_invoice_id));
  END IF;
  IF v_inv.cancelled_at IS NOT NULL THEN
    RETURN warehouse_security.refuse('INVOICE_CANCELLED', 'This invoice is cancelled: no payment can be recorded for it.',
      jsonb_build_object('invoice_id', p_invoice_id, 'inv_no', v_inv.inv_no, 'inv_fin_year', v_inv.inv_fin_year));
  END IF;
  v_refusal := warehouse_security.payment_day_refusal(p_paid_on, v_inv.inv_date);
  IF v_refusal IS NOT NULL THEN
    RETURN v_refusal;
  END IF;
  SELECT COALESCE(sum(p.amount), 0) INTO v_paid FROM public.payments p WHERE p.invoice_id = p_invoice_id;
  v_due := GREATEST(COALESCE(v_inv.total, 0) - v_paid, 0);
  IF p_amount > v_due THEN
    RETURN warehouse_security.refuse('PAYMENT_OVER_DUE', format('Only %s is due on this invoice.', v_due),
      jsonb_build_object('due', v_due, 'paid', v_paid, 'total', COALESCE(v_inv.total, 0)));
  END IF;

  INSERT INTO public.payments (payment_no, payment_date, paid_on, customer_id, customer_name, supervisor_id, supervisor_name,
                               note, payment_mode, amount, invoice_id, updated_at, updated_by)
  VALUES ('APP-' || nextval('public.payments_app_no_seq'), warehouse_security.business_day_start(p_paid_on), p_paid_on,
          v_inv.customer_id, v_inv.customer_name, v_profile, left(v_profile_name, 30),
          v_note, p_mode, p_amount, p_invoice_id, now(), v_profile)
  RETURNING * INTO v_payment;

  v_result := jsonb_build_object('success', true, 'payment_id', v_payment.id, 'invoice_id', p_invoice_id,
    'payment', warehouse_security.payment_json(v_payment),
    'invoice', jsonb_build_object('invoice_id', p_invoice_id, 'inv_no', v_inv.inv_no, 'inv_fin_year', v_inv.inv_fin_year,
                                  'total', COALESCE(v_inv.total, 0))
               || warehouse_security.invoice_payment_state(p_invoice_id),
    'message', format('Payment of %s recorded on invoice %s.', p_amount, v_inv.inv_no));
  PERFORM warehouse_security.payment_keep_answer('record_payment', v_key, v_profile, v_result);
  RETURN v_result;
END $$;
ALTER FUNCTION public.record_payment(uuid, date, numeric, text, text, text) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.record_payment(uuid, date, numeric, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.record_payment(uuid, date, numeric, text, text, text) TO authenticated, service_role;

-- p_note is the note after the edit (NULL or blank: none). p_expected_updated_at is the payment's updated_at as the form read it.
CREATE FUNCTION public.update_payment(p_id uuid, p_paid_on date, p_amount numeric, p_mode text, p_expected_updated_at timestamptz,
                                      p_note text DEFAULT NULL, p_request_id text DEFAULT NULL) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $$
DECLARE
  v_key text := NULLIF(btrim(p_request_id), '');
  v_profile uuid;
  v_cached jsonb;
  v_note text;
  v_invoice_id uuid;
  v_inv record;
  v_old public.payments;
  v_new public.payments;
  v_refusal jsonb;
  v_paid_others numeric;
  v_due numeric;
  v_changed boolean;
  v_result jsonb;
BEGIN
  PERFORM warehouse_security.authorize_rpc('update_payment', jsonb_build_object('p_id', p_id));
  IF COALESCE(warehouse_security.active_role(), '') NOT IN ('admin', 'supervisor') AND auth.jwt()->>'role' IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Administrator or supervisor required' USING ERRCODE = '42501';
  END IF;
  v_profile := public.get_current_user_profile_id();
  IF v_profile IS NULL THEN
    RETURN warehouse_security.refuse('USER_REQUIRED', 'A payment is changed by a signed-in person.');
  END IF;

  v_cached := warehouse_security.payment_replay('update_payment', v_key, v_profile);
  IF v_cached IS NOT NULL AND v_cached->>'payment_id' = p_id::text AND EXISTS (SELECT 1 FROM public.payments p WHERE p.id = p_id) THEN
    RETURN v_cached;
  END IF;

  IF NOT warehouse_security.payments_enabled() THEN
    RETURN warehouse_security.refuse('PAYMENTS_OFF', 'Record payments is turned off for this facility.');
  END IF;
  IF p_expected_updated_at IS NULL THEN
    RAISE EXCEPTION 'Send the payment''s updated_at as the form read it' USING ERRCODE = '22023';
  END IF;
  v_note := warehouse_security.checked_payment_note(p_paid_on, p_amount, p_mode, p_note);

  PERFORM pg_advisory_xact_lock(71040);
  SELECT p.invoice_id INTO v_invoice_id FROM public.payments p WHERE p.id = p_id;
  IF NOT FOUND THEN
    RETURN warehouse_security.refuse('PAYMENT_NOT_FOUND', 'Payment not found', jsonb_build_object('payment_id', p_id));
  END IF;
  -- The invoice first, then the payment: the order record_payment and delete_payment lock in.
  SELECT i.id, i.inv_no, i.inv_fin_year, i.inv_date, i.total, i.cancelled_at, i.deleted_at INTO v_inv
    FROM public.invoice i WHERE i.id = v_invoice_id FOR UPDATE;
  SELECT p.* INTO v_old FROM public.payments p WHERE p.id = p_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN warehouse_security.refuse('PAYMENT_NOT_FOUND', 'Payment not found', jsonb_build_object('payment_id', p_id));
  END IF;
  IF v_old.paid_on IS NULL OR v_old.invoice_id IS NULL THEN
    RETURN warehouse_security.refuse('PAYMENT_NOT_EDITABLE', 'This payment came from the accounting link and can not be changed here.',
      jsonb_build_object('payment_id', p_id));
  END IF;
  IF v_old.invoice_id IS DISTINCT FROM v_invoice_id
     OR date_trunc('milliseconds', v_old.updated_at) IS DISTINCT FROM date_trunc('milliseconds', p_expected_updated_at) THEN
    RETURN warehouse_security.refuse('STALE_RECORD', 'Someone else changed this payment. Open it again.',
      jsonb_build_object('what', 'payment', 'id', p_id, 'expected_updated_at', p_expected_updated_at, 'current_updated_at', v_old.updated_at));
  END IF;
  IF v_inv.id IS NULL OR v_inv.deleted_at IS NOT NULL THEN
    RETURN warehouse_security.refuse('INVOICE_NOT_FOUND', 'Invoice not found', jsonb_build_object('invoice_id', v_invoice_id));
  END IF;
  IF v_inv.cancelled_at IS NOT NULL THEN
    RETURN warehouse_security.refuse('INVOICE_CANCELLED', 'This invoice is cancelled: its payments can not be changed.',
      jsonb_build_object('invoice_id', v_invoice_id, 'inv_no', v_inv.inv_no, 'inv_fin_year', v_inv.inv_fin_year));
  END IF;
  v_refusal := warehouse_security.payment_day_refusal(p_paid_on, v_inv.inv_date);
  IF v_refusal IS NOT NULL THEN
    RETURN v_refusal;
  END IF;
  -- The amount due for this edit: the total less every other payment of the invoice.
  SELECT COALESCE(sum(p.amount), 0) INTO v_paid_others FROM public.payments p WHERE p.invoice_id = v_invoice_id AND p.id <> p_id;
  v_due := GREATEST(COALESCE(v_inv.total, 0) - v_paid_others, 0);
  IF p_amount > v_due THEN
    RETURN warehouse_security.refuse('PAYMENT_OVER_DUE', format('Only %s is due on this invoice.', v_due),
      jsonb_build_object('due', v_due, 'paid', v_paid_others, 'total', COALESCE(v_inv.total, 0)));
  END IF;

  UPDATE public.payments p
     SET paid_on = p_paid_on, payment_date = warehouse_security.business_day_start(p_paid_on), amount = p_amount,
         payment_mode = p_mode, note = v_note, updated_at = now(), updated_by = v_profile
   WHERE p.id = p_id
     AND ROW(p.paid_on, p.amount, p.payment_mode::text, p.note::text) IS DISTINCT FROM ROW(p_paid_on, p_amount, p_mode, v_note)
  RETURNING p.* INTO v_new;
  v_changed := FOUND;
  IF NOT v_changed THEN
    v_new := v_old;
  END IF;

  v_result := jsonb_build_object('success', true, 'changed', v_changed, 'payment_id', p_id, 'invoice_id', v_invoice_id,
    'payment', warehouse_security.payment_json(v_new),
    'previous', warehouse_security.payment_json(v_old),
    'invoice', jsonb_build_object('invoice_id', v_invoice_id, 'inv_no', v_inv.inv_no, 'inv_fin_year', v_inv.inv_fin_year,
                                  'total', COALESCE(v_inv.total, 0))
               || warehouse_security.invoice_payment_state(v_invoice_id),
    'message', 'Payment updated');
  PERFORM warehouse_security.payment_keep_answer('update_payment', v_key, v_profile, v_result);
  RETURN v_result;
END $$;
ALTER FUNCTION public.update_payment(uuid, date, numeric, text, timestamptz, text, text) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.update_payment(uuid, date, numeric, text, timestamptz, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.update_payment(uuid, date, numeric, text, timestamptz, text, text) TO authenticated, service_role;

-- p_expected_updated_at: optional; when sent, a payment changed since it was read is refused (STALE_RECORD).
CREATE FUNCTION public.delete_payment(p_id uuid, p_expected_updated_at timestamptz DEFAULT NULL, p_request_id text DEFAULT NULL) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $$
DECLARE
  v_key text := NULLIF(btrim(p_request_id), '');
  v_profile uuid;
  v_cached jsonb;
  v_invoice_id uuid;
  v_inv record;
  v_old public.payments;
  v_result jsonb;
BEGIN
  PERFORM warehouse_security.authorize_rpc('delete_payment', jsonb_build_object('p_id', p_id));
  IF COALESCE(warehouse_security.active_role(), '') NOT IN ('admin', 'supervisor') AND auth.jwt()->>'role' IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Administrator or supervisor required' USING ERRCODE = '42501';
  END IF;
  v_profile := public.get_current_user_profile_id();
  IF v_profile IS NULL THEN
    RETURN warehouse_security.refuse('USER_REQUIRED', 'A payment is deleted by a signed-in person.');
  END IF;

  -- A resend of a delete that went through answers as the delete did.
  v_cached := warehouse_security.payment_replay('delete_payment', v_key, v_profile);
  IF v_cached IS NOT NULL AND v_cached->>'payment_id' = p_id::text AND NOT EXISTS (SELECT 1 FROM public.payments p WHERE p.id = p_id) THEN
    RETURN v_cached;
  END IF;

  IF NOT warehouse_security.payments_enabled() THEN
    RETURN warehouse_security.refuse('PAYMENTS_OFF', 'Record payments is turned off for this facility.');
  END IF;

  PERFORM pg_advisory_xact_lock(71040);
  SELECT p.invoice_id INTO v_invoice_id FROM public.payments p WHERE p.id = p_id;
  IF NOT FOUND THEN
    RETURN warehouse_security.refuse('PAYMENT_NOT_FOUND', 'Payment not found', jsonb_build_object('payment_id', p_id));
  END IF;
  SELECT i.id, i.inv_no, i.inv_fin_year, i.total INTO v_inv FROM public.invoice i WHERE i.id = v_invoice_id FOR UPDATE;
  SELECT p.* INTO v_old FROM public.payments p WHERE p.id = p_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN warehouse_security.refuse('PAYMENT_NOT_FOUND', 'Payment not found', jsonb_build_object('payment_id', p_id));
  END IF;
  IF v_old.paid_on IS NULL OR v_old.invoice_id IS NULL THEN
    RETURN warehouse_security.refuse('PAYMENT_NOT_EDITABLE', 'This payment came from the accounting link and can not be deleted here.',
      jsonb_build_object('payment_id', p_id));
  END IF;
  IF v_old.invoice_id IS DISTINCT FROM v_invoice_id
     OR (p_expected_updated_at IS NOT NULL
         AND date_trunc('milliseconds', v_old.updated_at) IS DISTINCT FROM date_trunc('milliseconds', p_expected_updated_at)) THEN
    RETURN warehouse_security.refuse('STALE_RECORD', 'Someone else changed this payment. Open it again.',
      jsonb_build_object('what', 'payment', 'id', p_id, 'expected_updated_at', p_expected_updated_at, 'current_updated_at', v_old.updated_at));
  END IF;

  DELETE FROM public.payments p WHERE p.id = p_id;

  v_result := jsonb_build_object('success', true, 'payment_id', p_id, 'invoice_id', v_invoice_id,
    'deleted', warehouse_security.payment_json(v_old),
    'invoice', jsonb_build_object('invoice_id', v_invoice_id, 'inv_no', v_inv.inv_no, 'inv_fin_year', v_inv.inv_fin_year,
                                  'total', COALESCE(v_inv.total, 0))
               || warehouse_security.invoice_payment_state(v_invoice_id),
    'message', 'Payment deleted');
  PERFORM warehouse_security.payment_keep_answer('delete_payment', v_key, v_profile, v_result);
  RETURN v_result;
END $$;
ALTER FUNCTION public.delete_payment(uuid, timestamptz, text) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.delete_payment(uuid, timestamptz, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.delete_payment(uuid, timestamptz, text) TO authenticated, service_role;

-- Section 6: invoice totals never go below what was paid.
-- update_invoice answers it (TOTAL_BELOW_PAID, raised as 'rate_fail' and answered by its handler after the rollback of the block). Rule:
-- the new total is lower than the paid sum and lower than the total before the edit (an older over-paid invoice stays editable while
-- its total does not fall).
CREATE FUNCTION warehouse_security.check_total_covers_paid(p_invoice_id uuid, p_total_before numeric) RETURNS void
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog', 'public'
    AS $$
DECLARE
  v_total numeric;
  v_paid numeric;
BEGIN
  SELECT COALESCE(i.total, 0) INTO v_total FROM public.invoice i WHERE i.id = p_invoice_id;
  SELECT COALESCE(sum(p.amount), 0) INTO v_paid FROM public.payments p WHERE p.invoice_id = p_invoice_id;
  IF v_total < v_paid AND v_total < COALESCE(p_total_before, 0) THEN
    RAISE EXCEPTION 'rate_fail' USING ERRCODE = 'P0001', DETAIL = warehouse_security.refuse('TOTAL_BELOW_PAID',
      format('%s has been paid on this invoice, more than the new total %s.', v_paid, v_total),
      jsonb_build_object('invoice_id', p_invoice_id, 'paid', v_paid, 'total', v_total))::text;
  END IF;
END $$;
ALTER FUNCTION warehouse_security.check_total_covers_paid(uuid, numeric) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.check_total_covers_paid(uuid, numeric) FROM PUBLIC;

-- Every other write of invoice.total is checked when the transaction commits, against the row as it then is (update_invoice sets the
-- total to 0 and recalculates it, so a row trigger would see the step in between).
CREATE FUNCTION warehouse_security.refuse_total_below_paid() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
DECLARE
  v_total numeric;
  v_paid numeric;
BEGIN
  SELECT COALESCE(i.total, 0) INTO v_total FROM public.invoice i WHERE i.id = NEW.id;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;
  SELECT COALESCE(sum(p.amount), 0) INTO v_paid FROM public.payments p WHERE p.invoice_id = NEW.id;
  IF v_total < v_paid AND v_total < COALESCE(OLD.total, 0) THEN
    RAISE EXCEPTION 'Invoice %: % has been paid, more than the new total %', NEW.id, v_paid, v_total
      USING ERRCODE = 'WH409', DETAIL = warehouse_security.refuse('TOTAL_BELOW_PAID',
        format('%s has been paid on this invoice, more than the new total %s.', v_paid, v_total),
        jsonb_build_object('invoice_id', NEW.id, 'paid', v_paid, 'total', v_total))::text;
  END IF;
  RETURN NULL;
END $$;
ALTER FUNCTION warehouse_security.refuse_total_below_paid() OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.refuse_total_below_paid() FROM PUBLIC, anon, authenticated;
CREATE CONSTRAINT TRIGGER invoice_total_covers_paid AFTER UPDATE OF total ON public.invoice
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
  WHEN (NEW.total IS DISTINCT FROM OLD.total)
  EXECUTE FUNCTION warehouse_security.refuse_total_below_paid();

-- Section 7: patches of existing functions
CREATE FUNCTION pg_temp.patch_function(p_function regprocedure, p_old text[], p_new text[], p_drop_first boolean DEFAULT false) RETURNS void
    LANGUAGE plpgsql AS $$
DECLARE
  v_def text := pg_get_functiondef(p_function);
  v_count integer;
  i integer;
BEGIN
  IF array_length(p_old, 1) IS DISTINCT FROM array_length(p_new, 1) THEN
    RAISE EXCEPTION '%: the marker list and the replacement list differ in length', p_function;
  END IF;
  FOR i IN 1 .. array_length(p_old, 1) LOOP
    IF position(p_old[i] IN p_new[i]) > 0 THEN
      RAISE EXCEPTION '%: the replacement of marker % contains the marker', p_function, i;
    END IF;
    v_count := (length(v_def) - length(replace(v_def, p_old[i], ''))) / length(p_old[i]);
    IF v_count <> 1 THEN
      RAISE EXCEPTION '%: expected marker % once, found % times', p_function, i, v_count;
    END IF;
    v_def := replace(v_def, p_old[i], p_new[i]);
  END LOOP;
  -- A signature change: the old function goes first, so no second overload remains for PostgREST.
  IF p_drop_first THEN
    EXECUTE format('DROP FUNCTION %s', p_function);
  END IF;
  EXECUTE v_def;
END $$;

-- 7.1 update_invoice: TOTAL_BELOW_PAID right after the header is recalculated (v_old_total is the total before the edit, migration 129).
SELECT pg_temp.patch_function('public.update_invoice(uuid, jsonb, jsonb[])'::regprocedure, ARRAY[
$m$recalculate_invoice_header(p_invoice_id);
    IF v_money_changed OR$m$
], ARRAY[
$m$recalculate_invoice_header(p_invoice_id);
    -- Migration 172: the new total may not fall below what has been paid on the invoice.
    PERFORM warehouse_security.check_total_covers_paid(p_invoice_id, v_old_total);
    IF v_money_changed OR$m$
]);

-- 7.2 cancel_invoice and delete_invoice name the invoice in INVOICE_HAS_PAYMENTS (the error texts stay).
SELECT pg_temp.patch_function('public.cancel_invoice(uuid, text, timestamptz)'::regprocedure, ARRAY[
$m$jsonb_build_object('invoice_id', p_invoice_id, 'payments', v_payments));$m$
], ARRAY[
$m$jsonb_build_object('invoice_id', p_invoice_id, 'payments', v_payments, 'inv_no', v_inv_no, 'inv_fin_year', v_fin_year));$m$
]);

SELECT pg_temp.patch_function('public.delete_invoice(uuid, timestamptz)'::regprocedure, ARRAY[
$m$  IF EXISTS (SELECT 1 FROM payments WHERE invoice_id = p_invoice_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Cannot delete an invoice that has payments');
  END IF;$m$
], ARRAY[
$m$  IF EXISTS (SELECT 1 FROM payments WHERE invoice_id = p_invoice_id) THEN
    -- Migration 172: the refusal names the invoice; the error text is the one callers already match.
    RETURN warehouse_security.refuse('INVOICE_HAS_PAYMENTS', 'Cannot delete an invoice that has payments',
      jsonb_build_object('invoice_id', p_invoice_id, 'inv_no', v_inv_no, 'inv_fin_year', v_fin_year,
                         'payments', (SELECT count(*) FROM payments WHERE invoice_id = p_invoice_id)));
  END IF;$m$
]);

-- 7.3 get_invoices_list: paid, due and status on each row, and the status filter, for administrators and supervisors.
SELECT pg_temp.patch_function('public.get_invoices_list(integer, integer, uuid, integer, text, text, text, text, integer, integer, text, timestamp with time zone, timestamp with time zone, uuid[])'::regprocedure, ARRAY[
$m$p_customer_ids uuid[] DEFAULT NULL::uuid[])
 RETURNS jsonb$m$,
$m$    v_data jsonb;
BEGIN$m$,
$m$    p_offset := GREATEST(COALESCE(p_offset, 0), 0);
    -- Which customers$m$,
$m$            AND ($11 IS NULL OR i.inv_date <= $11)
            AND ($6 IS NULL$m$,
$m$                   ) ORDER BY pg.ord)$m$,
$m$p_sort_field, p_sort_direction;$m$
], ARRAY[
$m$p_customer_ids uuid[] DEFAULT NULL::uuid[], p_payment_status text DEFAULT NULL::text)
 RETURNS jsonb$m$,
$m$    v_data jsonb;
    v_show_payments boolean := auth.jwt()->>'role' = 'service_role' OR warehouse_security.active_role() IN ('admin', 'supervisor');
BEGIN$m$,
$m$    p_offset := GREATEST(COALESCE(p_offset, 0), 0);
    -- Migration 172: paid, due and the payment status are for administrators and supervisors; staff see none and may not filter by them.
    IF p_payment_status IS NOT NULL AND p_payment_status NOT IN ('due', 'part_paid', 'paid') THEN
        RAISE EXCEPTION 'p_payment_status must be due, part_paid or paid' USING ERRCODE = '22023';
    END IF;
    IF p_payment_status IS NOT NULL AND NOT COALESCE(v_show_payments, false) THEN
        RAISE EXCEPTION 'Administrator or supervisor required' USING ERRCODE = '42501';
    END IF;
    -- Which customers$m$,
$m$            AND ($11 IS NULL OR i.inv_date <= $11)
            AND ($17 IS NULL OR warehouse_security.invoice_payment_state(i.id)->>'payment_status' = $17)
            AND ($6 IS NULL$m$,
$m$                   ) || CASE WHEN $18 THEN warehouse_security.invoice_payment_state(i.id) ELSE '{}'::jsonb END ORDER BY pg.ord)$m$,
$m$p_sort_field, p_sort_direction, p_payment_status, COALESCE(v_show_payments, false);$m$
], true);
ALTER FUNCTION public.get_invoices_list(integer, integer, uuid, integer, text, text, text, text, integer, integer, text, timestamp with time zone, timestamp with time zone, uuid[], text) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.get_invoices_list(integer, integer, uuid, integer, text, text, text, text, integer, integer, text, timestamp with time zone, timestamp with time zone, uuid[], text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_invoices_list(integer, integer, uuid, integer, text, text, text, text, integer, integer, text, timestamp with time zone, timestamp with time zone, uuid[], text) TO authenticated, service_role;

-- 7.4 get_customer_activity_detail: total_paid_amount also counts the customer's payments that name no invoice, by payment day.
SELECT pg_temp.patch_function('public.get_customer_activity_detail(uuid, date, date)'::regprocedure, ARRAY[
$m$        FROM payments p
        JOIN invoice i ON p.invoice_id = i.id
        WHERE i.customer_id = p_customer_uuid
            AND i.deleted_at IS NULL
            AND i.inv_date >= warehouse_security.business_day_start(p_from_date) AND i.inv_date < warehouse_security.business_day_start(p_to_date + 1)
    )$m$
], ARRAY[
$m$        FROM payments p
        LEFT JOIN invoice i ON p.invoice_id = i.id
        WHERE (p.invoice_id IS NOT NULL
            AND i.customer_id = p_customer_uuid
            AND i.deleted_at IS NULL
            AND i.inv_date >= warehouse_security.business_day_start(p_from_date) AND i.inv_date < warehouse_security.business_day_start(p_to_date + 1))
           -- Migration 172: payments of the old accounting link that name no invoice count for their customer, by payment day.
           OR (p.invoice_id IS NULL AND p.customer_id = p_customer_uuid
            AND p.payment_date >= warehouse_security.business_day_start(p_from_date) AND p.payment_date < warehouse_security.business_day_start(p_to_date + 1))
    )$m$
]);

-- 7.5 get_customer_invoice_summary (one customer): the payments that name no invoice, beside the per-invoice figures.
SELECT pg_temp.patch_function('public.get_customer_invoice_summary(uuid, date, date, integer)'::regprocedure, ARRAY[
$m$'paid_amount', COALESCE((SELECT SUM(received_amount) FROM invoices_full WHERE cancelled_at IS NULL), 0),
                'pending_amount'$m$
], ARRAY[
$m$'paid_amount', COALESCE((SELECT SUM(received_amount) FROM invoices_full WHERE cancelled_at IS NULL), 0),
                'unlinked_paid_amount', warehouse_security.unlinked_payments_total(p_customer_uuid, v_from_date, v_to_date, p_financial_year),
                'pending_amount'$m$
]);

-- 7.6 get_submission_result finds the three payment saves (W22).
SELECT pg_temp.patch_function('public.get_submission_result(text)'::regprocedure, ARRAY[
$m$            WHEN 'set_standard_rate' THEN true
            ELSE false$m$
], ARRAY[
$m$            WHEN 'set_standard_rate' THEN true
            WHEN 'record_payment' THEN EXISTS (SELECT 1 FROM payments p WHERE p.id::text = k.response->>'payment_id')
            WHEN 'update_payment' THEN EXISTS (SELECT 1 FROM payments p WHERE p.id::text = k.response->>'payment_id')
            WHEN 'delete_payment' THEN true
            ELSE false$m$
]);

DROP FUNCTION pg_temp.patch_function(regprocedure, text[], text[], boolean);

NOTIFY pgrst, 'reload schema';
