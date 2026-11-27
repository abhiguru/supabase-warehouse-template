-- Customer accounts read their own goods from the phone copy (WH-306): topic "customer account copy". Named by topic; its number is taken
-- when the work is assembled for main, after WH-303 (feed format 4), WH-304 (5) and WH-305 (6), which this step stacks on (it sets 7).
--
-- 1. A customer account's customers are the ACTIVE assignments of customers that are NOT deleted (contract section 14, item 4, Product's
--    PQ4). One rule in three places: warehouse_sync.caller() (the feed's scope and the access part of the copy key, so deleting or
--    restoring a customer answers reload_all ACCESS_CHANGED), warehouse_security.owns_customer (the gate authorize_rpc applies to every
--    customer read) and public.user_accessible_customers(). The seven reads that check users_customers_new themselves use the same rule.
--    A deactivated customer (active = false, not deleted) is unchanged. Administrators, supervisors and staff are unchanged.
-- 2. No read answers a customer account a key of the agreed forbidden list (created_by, updated_by, deleted_by, supervisor_id, sender_id,
--    import_batch_id, uploaded_by, created_by_name, updated_by_name, updated_by_display_name, user_access), at any depth. Only for a caller
--    whose active role is customer; warehouse_security.customer_answer does it. get_invoice_data and get_invoice_detail call it in their
--    definitions files; get_customer_dispatch_list, get_grn_details, get_orders_list and get_order_with_items here (the other customer reads
--    answer none of these keys).
-- 3. Feed format 7 (CUSTOMER_COPY_FORMAT): the entity list is unchanged on this base; held_items and grn_replacements are added to the
--    customer branch of warehouse_sync.entities() when WH-304 / WH-303 are stacked (assembly).
-- Patched by text with a marker count. No role, table, column, grant, owner, search_path or volatility changes (two new helper functions
-- in warehouse_security have no grant).

DROP FUNCTION IF EXISTS pg_temp.patch_function(regprocedure, text[], text[]);
CREATE FUNCTION pg_temp.patch_function(p_function regprocedure, p_old text[], p_new text[]) RETURNS void
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
    v_count := (length(v_def) - length(replace(v_def, p_old[i], ''))) / length(p_old[i]);
    IF v_count <> 1 THEN
      RAISE EXCEPTION '%: expected marker % once, found % times', p_function, i, v_count;
    END IF;
    v_def := replace(v_def, p_old[i], p_new[i]);
  END LOOP;
  EXECUTE v_def;
END $$;

-- ===== 1. a customer account's customers: active assignments of customers that are not deleted =====
CREATE OR REPLACE FUNCTION warehouse_sync.caller(OUT role text, OUT profile uuid, OUT customers uuid[], OUT access text)
 LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  role := warehouse_security.active_role();
  IF role IS NULL THEN RAISE EXCEPTION 'Active account required' USING ERRCODE = '42501'; END IF;
  SELECT p.id INTO profile FROM public.user_profiles p WHERE p.auth_user_id = auth.uid() AND p.active;
  customers := CASE WHEN role = 'customer' THEN ARRAY(
    SELECT DISTINCT a.customer_id FROM public.users_customers_new a
    JOIN public.customers c ON c.id = a.customer_id AND c.deleted_at IS NULL
    WHERE a.user_profile_id = profile AND a.active AND a.customer_id IS NOT NULL ORDER BY a.customer_id) ELSE '{}'::uuid[] END;
  access := md5(concat_ws('|', profile, role, array_to_string(customers, ',')));
END $$;

CREATE OR REPLACE FUNCTION warehouse_security.owns_customer(customer uuid) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog'
    AS $$
  WITH me AS MATERIALIZED (SELECT warehouse_security.active_role() AS role)
  SELECT me.role IS NOT NULL AND (
    me.role IN ('admin','supervisor') OR EXISTS (
      SELECT 1 FROM public.users_customers_new a JOIN public.user_profiles p ON p.id=a.user_profile_id
        JOIN public.customers c ON c.id=a.customer_id AND c.deleted_at IS NULL
      WHERE a.customer_id=customer AND a.active AND p.active AND p.auth_user_id=auth.uid()
    )
  )
  FROM me;
$$;

SELECT pg_temp.patch_function('public.user_accessible_customers()'::regprocedure, ARRAY[
$m$LEFT JOIN customers c ON c.id = uc.customer_id
        WHERE uc.user_profile_id = v_user_profile_id AND uc.active = true$m$
], ARRAY[
$m$JOIN customers c ON c.id = uc.customer_id AND c.deleted_at IS NULL
        WHERE uc.user_profile_id = v_user_profile_id AND uc.active = true$m$
]);

-- The reads that check the assignment themselves use the same rule.
SELECT pg_temp.patch_function(t.f::regprocedure, ARRAY[
$m$FROM users_customers_new
        WHERE user_profile_id = v_user_id;$m$
], ARRAY[
$m$FROM users_customers_new
        WHERE user_profile_id = v_user_id AND active
          AND customer_id IN (SELECT cu.id FROM public.customers cu WHERE cu.deleted_at IS NULL);$m$
]) FROM unnest(ARRAY[
  'public.get_customer_activity_detail(uuid, date, date)',
  'public.get_customer_grn_activity(uuid, date, date)',
  'public.get_stock_aging_report(uuid, integer[])',
  'public.get_customer_invoice_summary(uuid, date, date, integer)'
]) t(f);

SELECT pg_temp.patch_function(t.f::regprocedure, ARRAY[
$m$SELECT customer_id FROM users_customers_new
                WHERE user_profile_id = (SELECT id FROM user_profiles WHERE auth_user_id = v_user_id)$m$
], ARRAY[
$m$SELECT a.customer_id FROM users_customers_new a
                JOIN public.customers cu ON cu.id = a.customer_id AND cu.deleted_at IS NULL
                WHERE a.active AND a.user_profile_id = (SELECT id FROM user_profiles WHERE auth_user_id = v_user_id)$m$
]) FROM unnest(ARRAY['public.get_grn_details(uuid)', 'public.get_dispatch_details(uuid)']) t(f);

-- ===== 2. no staff-only key in a customer account's answer =====
CREATE FUNCTION warehouse_security.strip_staff_keys(j jsonb) RETURNS jsonb
    LANGUAGE sql IMMUTABLE
    SET search_path TO 'pg_catalog'
    AS $$
  SELECT CASE jsonb_typeof(j)
    WHEN 'object' THEN COALESCE((SELECT jsonb_object_agg(e.key, warehouse_security.strip_staff_keys(e.value))
      FROM jsonb_each(j) e
      WHERE e.key <> ALL (ARRAY['created_by', 'updated_by', 'deleted_by', 'supervisor_id', 'sender_id', 'import_batch_id', 'uploaded_by',
                                'created_by_name', 'updated_by_name', 'updated_by_display_name', 'user_access'])), '{}'::jsonb)
    WHEN 'array' THEN COALESCE((SELECT jsonb_agg(warehouse_security.strip_staff_keys(e.value) ORDER BY e.ord)
      FROM jsonb_array_elements(j) WITH ORDINALITY e(value, ord)), '[]'::jsonb)
    ELSE j END
$$;
ALTER FUNCTION warehouse_security.strip_staff_keys(jsonb) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.strip_staff_keys(jsonb) FROM PUBLIC, anon, authenticated, service_role;

-- The answer of a read, unchanged unless the caller's active role is customer.
CREATE FUNCTION warehouse_security.customer_answer(j jsonb) RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog'
    AS $$
  SELECT CASE WHEN warehouse_security.active_role() = 'customer' THEN warehouse_security.strip_staff_keys(j) ELSE j END
$$;
ALTER FUNCTION warehouse_security.customer_answer(jsonb) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.customer_answer(jsonb) FROM PUBLIC, anon, authenticated, service_role;

-- The four reads of the account's screens whose answer carries a forbidden key (supervisor_id; uploaded_by of a photo; created_by,
-- updated_by, updated_by_name, updated_by_display_name) pass the success answer through customer_answer. Their text stays in public
-- (tests read it there); get_invoice_data and get_invoice_detail do it in their definitions files.
SELECT pg_temp.patch_function('public.get_customer_dispatch_list(uuid, integer, integer, boolean)'::regprocedure, ARRAY[
$m$  RETURN jsonb_build_object(
    'success', true,
    'message', 'Customer dispatches retrieved successfully',
    'data', jsonb_build_object(
      'dispatches', v_dispatches,
      'pagination', jsonb_build_object(
        'total_count', v_total_count,
        'limit', p_limit,
        'offset', p_offset,
        'has_more', (p_offset + p_limit) < v_total_count
      )
    )
  );$m$
], ARRAY[
$m$  RETURN warehouse_security.customer_answer(jsonb_build_object(
    'success', true,
    'message', 'Customer dispatches retrieved successfully',
    'data', jsonb_build_object(
      'dispatches', v_dispatches,
      'pagination', jsonb_build_object(
        'total_count', v_total_count,
        'limit', p_limit,
        'offset', p_offset,
        'has_more', (p_offset + p_limit) < v_total_count
      )
    )
  ));$m$
]);

SELECT pg_temp.patch_function('public.get_grn_details(uuid)'::regprocedure, ARRAY[
$m$        RETURN v_result;

    EXCEPTION$m$
], ARRAY[
$m$        RETURN warehouse_security.customer_answer(v_result);

    EXCEPTION$m$
]);

SELECT pg_temp.patch_function('public.get_orders_list(uuid, text, boolean, uuid, integer, integer, text)'::regprocedure, ARRAY[
$m$    RETURN jsonb_build_object(
        'success', true,
        'data', jsonb_build_object(
            'orders', COALESCE(v_orders, '[]'::jsonb),
            'pagination', jsonb_build_object(
                'total_count', v_total_count,
                'has_more', v_has_more,
                'limit', v_limit,
                'offset', v_offset
            )
        )
    );$m$
], ARRAY[
$m$    RETURN warehouse_security.customer_answer(jsonb_build_object(
        'success', true,
        'data', jsonb_build_object(
            'orders', COALESCE(v_orders, '[]'::jsonb),
            'pagination', jsonb_build_object(
                'total_count', v_total_count,
                'has_more', v_has_more,
                'limit', v_limit,
                'offset', v_offset
            )
        )
    ));$m$
]);

SELECT pg_temp.patch_function('public.get_order_with_items(uuid)'::regprocedure, ARRAY[
$m$    RETURN jsonb_build_object(
        'success', true,
        'data', jsonb_build_object(
            'order_data', v_order_data,
            'items', v_items
        ),
        'message', null
    );$m$
], ARRAY[
$m$    RETURN warehouse_security.customer_answer(jsonb_build_object(
        'success', true,
        'data', jsonb_build_object(
            'order_data', v_order_data,
            'items', v_items
        ),
        'message', null
    ));$m$
]);

-- ===== 3. feed format 7 =====
ALTER TABLE warehouse_sync.state ALTER COLUMN format SET DEFAULT 7;
UPDATE warehouse_sync.state SET format = 7;

DROP FUNCTION pg_temp.patch_function(regprocedure, text[], text[]);
