-- Orders list reads live data; decimal weight search no longer errors (review,
-- 2026-10-09).
-- 1. Every insert, update or delete on orders or order_items ran a statement
--    trigger that rebuilt mv_orders_list in full, so each tap on a cart stepper
--    paid for an aggregate over every customer. get_orders_list now reads an
--    ordinary view with the same columns. There is one cart per customer, so
--    the live aggregate stays small. The materialized view and its queue entry
--    remain for operators who still refresh it, but the API no longer reads it.
-- 2. search_customer_items_for_order cast the search text straight to integer,
--    so a decimal weight such as "12.5" raised an error. Weights are rounded
--    to the nearest whole number, matching the integer weight column.
-- 3. Its two access-denied payloads now carry success=false like every other
--    envelope, so clients can tell a denial from an empty result.
-- 4. The orders list sorts by order id last, so pages are stable for clients
--    that scroll with p_offset.
CREATE VIEW public.v_orders_list AS
 WITH order_items_data AS (
         SELECT oi.order_id,
            count(*) FILTER (WHERE (oi.item_status = 'pending'::text)) AS total_items,
            COALESCE(sum(oi.requested_quantity) FILTER (WHERE (oi.item_status = 'pending'::text)), (0)::bigint) AS total_quantity,
            jsonb_agg(jsonb_build_object('id', oi.id, 'order_id', oi.order_id, 'requested_quantity', oi.requested_quantity, 'fulfilled_quantity', oi.fulfilled_quantity, 'grn_items_id', oi.grn_items_id, 'grn_items_item_id', oi.grn_items_item_id, 'grn_items_item_name', oi.grn_items_item_name, 'grn_items_package_mark', oi.grn_items_package_mark, 'grn_items_packaging', oi.grn_items_packaging, 'grn_items_rack', oi.grn_items_rack, 'grn_items_weight', oi.grn_items_weight, 'grn_items_image_url', oi.grn_items_image_url, 'grns_id', oi.grns_id, 'grns_gr_no', oi.grns_gr_no, 'grns_date', oi.grns_date, 'grns_customer_id', oi.grns_customer_id, 'grns_customer_name', oi.grns_customer_name, 'available_stock_at_order', oi.available_stock_at_order, 'current_stock', oi.current_stock, 'item_status', oi.item_status, 'sort_order', oi.sort_order, 'created_at', oi.created_at, 'updated_at', oi.updated_at) ORDER BY oi.sort_order, oi.created_at) AS items_jsonb
           FROM public.order_items oi
          GROUP BY oi.order_id
        ), latest_dispatch AS (
         SELECT DISTINCT ON (dispatch.source_order_id) dispatch.source_order_id,
            dispatch.id AS dispatch_id,
            dispatch.disp_no AS dispatch_no,
            dispatch.created_at AS dispatch_created_at
           FROM public.dispatch
          WHERE (dispatch.source_order_id IS NOT NULL)
          ORDER BY dispatch.source_order_id, dispatch.created_at DESC
        )
 SELECT o.id AS order_id,
    o.order_no,
    o.status,
    o.priority,
    o.customer_id,
    o.customer_name,
    o.customer_email,
    o.customer_phone,
    o.is_ignored,
    o.ignored_at,
    o.ignored_by,
    o.ignored_reason,
    o.cancelled_at,
    o.cancelled_by,
    o.cancellation_reason,
    o.created_at,
    o.updated_at,
    o.created_by,
    o.updated_by,
    c.name AS customer_name_detail,
    c.city AS customer_city,
    c.mobile AS customer_mobile,
    c.address AS customer_address,
    up.name AS updated_by_name,
    up.display_name AS updated_by_display_name,
    (COALESCE(oid.total_items, (0)::bigint))::integer AS total_items,
    (COALESCE(oid.total_quantity, (0)::bigint))::numeric AS total_quantity,
    COALESCE(oid.items_jsonb, '[]'::jsonb) AS items_jsonb,
    ld.dispatch_id,
    ld.dispatch_no,
    ld.dispatch_created_at
   FROM ((((public.orders o
     JOIN public.customers c ON ((c.id = o.customer_id)))
     LEFT JOIN order_items_data oid ON ((oid.order_id = o.id)))
     LEFT JOIN public.user_profiles up ON ((up.id = o.updated_by)))
     LEFT JOIN latest_dispatch ld ON ((ld.source_order_id = o.id)))
  WHERE (o.deleted_at IS NULL);
COMMENT ON VIEW public.v_orders_list IS 'Live replacement for mv_orders_list, read only through get_orders_list.';
REVOKE ALL ON public.v_orders_list FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.v_orders_list TO service_role;

DO $patch$
DECLARE definition text; marker text := 'FROM mv_orders_list m'; page text := 'LIMIT p_limit OFFSET p_offset'; occurrences integer;
BEGIN
  definition := pg_get_functiondef('public.get_orders_list(uuid,text,boolean,uuid,integer,integer)'::regprocedure);
  occurrences := (length(definition)-length(replace(definition,marker,'')))/length(marker);
  IF occurrences <> 2 THEN RAISE EXCEPTION 'Expected two mv_orders_list reads in get_orders_list, found %', occurrences; END IF;
  -- Equal timestamps must not repeat or skip rows between pages.
  occurrences := (length(definition)-length(replace(definition,page,'')))/length(page);
  IF occurrences <> 1 THEN RAISE EXCEPTION 'Expected one page clause in get_orders_list, found %', occurrences; END IF;
  definition := replace(definition, marker, 'FROM public.v_orders_list m');
  EXECUTE replace(definition, page, ', m.order_id ' || page);
END $patch$;

DROP TRIGGER trg_mv_orders_list_refresh_on_orders ON public.orders;
DROP TRIGGER trg_mv_orders_list_refresh_on_order_items ON public.order_items;
DROP FUNCTION public.trigger_refresh_orders_list_mv();

DO $patch$
DECLARE definition text; pair text[]; pairs text[][] := ARRAY[
  ARRAY[$a$split_part(p_search_query, '-', 1)::INTEGER$a$, $b$round(split_part(p_search_query, '-', 1)::numeric)::INTEGER$b$],
  ARRAY[$a$split_part(p_search_query, '-', 2)::INTEGER$a$, $b$round(split_part(p_search_query, '-', 2)::numeric)::INTEGER$b$],
  ARRAY[$a$COALESCE(p_weight_min, p_search_query::INTEGER)$a$, $b$round(COALESCE(p_weight_min, p_search_query::numeric))::INTEGER$b$],
  ARRAY[$a$'error', 'No accessible customers'$a$, $b$'success', false, 'error', 'No accessible customers'$b$],
  ARRAY[$a$'error', 'Access denied to customer'$a$, $b$'success', false, 'error', 'Access denied to customer'$b$]
]; occurrences integer;
BEGIN
  definition := pg_get_functiondef('public.search_customer_items_for_order(text,uuid,text,integer,integer,integer,uuid,numeric,numeric)'::regprocedure);
  FOREACH pair SLICE 1 IN ARRAY pairs LOOP
    occurrences := (length(definition)-length(replace(definition,pair[1],'')))/length(pair[1]);
    IF occurrences <> 1 THEN RAISE EXCEPTION 'Expected one "%" in search_customer_items_for_order, found %', pair[1], occurrences; END IF;
    definition := replace(definition, pair[1], pair[2]);
  END LOOP;
  EXECUTE definition;
END $patch$;

NOTIFY pgrst, 'reload schema';
