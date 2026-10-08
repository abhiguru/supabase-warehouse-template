-- Dispatch edits roll back completely when refused, and administrator status
-- changes keep the operator enrollment state consistent (review, 2026-10-08).
-- update_dispatch_smart updated the header before validating lines and then
-- RETURNed a refusal, committing a partial edit. A raise reaches the function's
-- own handler, which returns the same error text after rolling everything back.
DO $patch$
DECLARE fn regprocedure := 'public.update_dispatch_smart(uuid,jsonb,jsonb[])'::regprocedure;
  definition text; marker text; replacement text; occurrences integer;
BEGIN
  definition := pg_get_functiondef(fn);
  marker := $m$        IF v_invoiced_items IS NOT NULL THEN
            RETURN jsonb_build_object(
                'success', false,
                'error', 'Cannot modify invoiced items: ' || v_invoiced_items
            );
        END IF;$m$;
  replacement := $r$        IF v_invoiced_items IS NOT NULL THEN
            RAISE EXCEPTION 'Cannot modify invoiced items: %', v_invoiced_items USING ERRCODE = 'WH409';
        END IF;$r$;
  occurrences := (length(definition)-length(replace(definition,marker,'')))/length(marker);
  IF occurrences <> 1 THEN RAISE EXCEPTION 'Expected one invoiced-line refusal in update_dispatch_smart, found %', occurrences; END IF;
  definition := replace(definition,marker,replacement);
  marker := $m$        IF v_insufficient_stock IS NOT NULL THEN
            RETURN jsonb_build_object(
                'success', false,
                'error', 'Insufficient stock: ' || v_insufficient_stock
            );
        END IF;$m$;
  replacement := $r$        IF v_insufficient_stock IS NOT NULL THEN
            RAISE EXCEPTION 'Insufficient stock: %', v_insufficient_stock USING ERRCODE = 'WH409';
        END IF;$r$;
  occurrences := (length(definition)-length(replace(definition,marker,'')))/length(marker);
  IF occurrences <> 1 THEN RAISE EXCEPTION 'Expected one stock refusal in update_dispatch_smart, found %', occurrences; END IF;
  EXECUTE replace(definition,marker,replacement);
END $patch$;

-- update_user_status(false) now disables the enrollment and revokes sessions;
-- update_user_status(true) re-approves a disabled or rejected profile. Pending
-- enrollments still require operator_review_enrollment with a customer
-- assignment. The row UPDATE is unchanged in shape, so auditing is unchanged.
DO $patch$
DECLARE fn regprocedure := 'public.update_user_status(uuid,boolean)'::regprocedure;
  definition text; marker text; replacement text; occurrences integer;
BEGIN
  definition := pg_get_functiondef(fn);
  marker := $m$    -- Update the status
    UPDATE user_profiles
    SET active = p_active,
        updated_at = now()
    WHERE id = p_user_id;$m$;
  replacement := $r$    -- Update the status and keep the operator enrollment state consistent
    IF p_active AND EXISTS (SELECT 1 FROM user_profiles WHERE id = p_user_id AND enrollment_status = 'pending') THEN
        RAISE EXCEPTION 'Pending enrollment must be reviewed with a customer assignment';
    END IF;
    UPDATE user_profiles
    SET active = p_active,
        enrollment_status = CASE WHEN p_active THEN 'approved' ELSE 'disabled' END,
        updated_at = now()
    WHERE id = p_user_id;
    IF NOT p_active THEN
        DELETE FROM warehouse_security.refresh_sessions
        WHERE user_id = (SELECT auth_user_id FROM user_profiles WHERE id = p_user_id);
    END IF;$r$;
  occurrences := (length(definition)-length(replace(definition,marker,'')))/length(marker);
  IF occurrences <> 1 THEN RAISE EXCEPTION 'Expected one status update in update_user_status, found %', occurrences; END IF;
  EXECUTE replace(definition,marker,replacement);
END $patch$;
NOTIFY pgrst, 'reload schema';
