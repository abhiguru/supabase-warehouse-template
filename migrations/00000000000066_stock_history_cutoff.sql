-- A stock analysis with a date gives each lot's balance at that moment
-- (backend review 2026-10-13, I2).
--
-- get_customer_stock_analysis_v2 with p_date_filter cut the receipts and the
-- dispatches at the date, but took each lot's balance from its CURRENT stock and
-- left out every lot whose current stock is 0. Asked for April 15 after 10 bags
-- came in on April 1 and 4 left on June 1, it answered 10 received, 0
-- dispatched, 6 in stock; a lot emptied after the date was missing altogether.
--
-- With a date, a lot's balance is now its received quantity less what was
-- dispatched from it up to the date (dispatch_trl with the dispatch's date, or
-- its creation time when it has none), and the in-stock filter (balance > 0)
-- is applied after that. The source is the receipt and dispatch lines, never
-- stock_movements (their signs were inconsistent before migration 67). Without
-- a date nothing changes: the current stock of each lot, lots with stock only,
-- and all their dispatches, as before.
--
-- The function is patched in place (one marker: the CTE block of the baseline,
-- unchanged by migration 60, which changed only the message); its owner,
-- grants, SECURITY DEFINER and settings are kept and checked below.
DO $patch$
DECLARE fn regprocedure; definition text; marker text; replacement text; occurrences integer;
  before_secdef boolean; before_acl aclitem[]; before_config text[];
  after_secdef boolean; after_acl aclitem[]; after_config text[];
BEGIN
  fn := 'public.get_customer_stock_analysis_v2(uuid,timestamp with time zone,jsonb,boolean)'::regprocedure;
  SELECT prosecdef, proacl, proconfig INTO STRICT before_secdef, before_acl, before_config
    FROM pg_proc WHERE oid=fn;
  definition := pg_get_functiondef(fn);
  marker := $m$    -- NEW LOGIC: GRN receipt-level filtering
    -- Step 1: Identify GRN items with remaining stock
    WITH grn_items_with_stock AS (
        SELECT
            grt.id as gr_trl_id,
            grt.item_id,
            grt.qty as grn_qty,
            grt.stock as remaining_stock,
            gr.date as grn_date
        FROM goodsreceived_trl grt
        JOIN goodsreceived gr ON grt.gr_id = gr.id
        WHERE gr.customer_id = p_customer_id
        AND (p_date_filter IS NULL OR gr.date <= p_date_filter)
        AND grt.stock > 0  -- KEY: Only GRN items with remaining stock
    ),
    -- Step 2: Aggregate GRN quantities ONLY from items with stock
    grn_data AS (
        SELECT
            item_id,
            SUM(grn_qty) as total_grn_qty,
            SUM(remaining_stock) as total_remaining_stock
        FROM grn_items_with_stock
        GROUP BY item_id
    ),
    -- Step 3: Calculate dispatches ONLY from those GRN items
    dispatch_data AS (
        SELECT
            gws.item_id,
            SUM(dt.disp_qty) as total_dispatch_qty
        FROM dispatch_trl dt
        JOIN grn_items_with_stock gws ON dt.gr_trl_id = gws.gr_trl_id
        JOIN dispatch d ON dt.disp_id = d.id
        WHERE (p_date_filter IS NULL OR d.disp_date <= p_date_filter)
        GROUP BY gws.item_id
    ),
    -- Step 4: Calculate stock based on filtered data
    stock_calculation AS (
        SELECT
            i.id as item_id,
            i.name as item_name,
            i.packaging,
            i.description,
            COALESCE(grn.total_grn_qty, 0) as grn_qty,
            COALESCE(disp.total_dispatch_qty, 0) as dispatch_qty,
            -- Use the pre-calculated stock from goodsreceived_trl for accuracy
            COALESCE(grn.total_remaining_stock, 0) as calculated_stock
        FROM items i
        INNER JOIN grn_data grn ON i.id = grn.item_id  -- INNER JOIN since we only want items with stock
        LEFT JOIN dispatch_data disp ON i.id = disp.item_id
        WHERE i.active = true
        AND (NOT p_item_filter ? 'item_name' OR p_item_filter->>'item_name' = ''
             OR i.name ILIKE '%' || (p_item_filter->>'item_name') || '%')
        AND (NOT p_item_filter ? 'item_id' OR p_item_filter->>'item_id' = ''
             OR i.id = (p_item_filter->>'item_id')::uuid)
        -- Apply in_stock_only filter
        AND (p_in_stock_only IS NULL OR
             (p_in_stock_only = true AND COALESCE(grn.total_remaining_stock, 0) > 0) OR
             (p_in_stock_only = false))
    )$m$;
  replacement := $r$    -- Each lot of the customer's receipts up to the date, whatever its stock
    -- today (migration 66).
    WITH customer_lots AS (
        SELECT
            grt.id as gr_trl_id,
            grt.item_id,
            grt.qty,
            grt.stock
        FROM goodsreceived_trl grt
        JOIN goodsreceived gr ON grt.gr_id = gr.id
        WHERE gr.customer_id = p_customer_id
        AND (p_date_filter IS NULL OR gr.date <= p_date_filter)
    ),
    -- What left each lot, up to the date when one is given.
    lot_dispatches AS (
        SELECT
            dt.gr_trl_id,
            SUM(dt.disp_qty) as dispatched
        FROM dispatch_trl dt
        JOIN customer_lots cl ON cl.gr_trl_id = dt.gr_trl_id
        JOIN dispatch d ON dt.disp_id = d.id
        WHERE (p_date_filter IS NULL OR COALESCE(d.disp_date, d.created_at) <= p_date_filter)
        GROUP BY dt.gr_trl_id
    ),
    -- Each lot's balance at the date (today: its stock), then only the lots
    -- that had stock then.
    grn_items_with_stock AS (
        SELECT * FROM (
            SELECT
                cl.gr_trl_id,
                cl.item_id,
                cl.qty as grn_qty,
                COALESCE(ld.dispatched, 0) as dispatched_qty,
                CASE WHEN p_date_filter IS NULL THEN cl.stock
                     ELSE cl.qty - COALESCE(ld.dispatched, 0) END as remaining_stock
            FROM customer_lots cl
            LEFT JOIN lot_dispatches ld ON ld.gr_trl_id = cl.gr_trl_id
        ) lots
        WHERE lots.remaining_stock > 0
    ),
    grn_data AS (
        SELECT
            item_id,
            SUM(grn_qty) as total_grn_qty,
            SUM(dispatched_qty) as total_dispatch_qty,
            SUM(remaining_stock) as total_remaining_stock
        FROM grn_items_with_stock
        GROUP BY item_id
    ),
    stock_calculation AS (
        SELECT
            i.id as item_id,
            i.name as item_name,
            i.packaging,
            i.description,
            COALESCE(grn.total_grn_qty, 0) as grn_qty,
            COALESCE(grn.total_dispatch_qty, 0) as dispatch_qty,
            COALESCE(grn.total_remaining_stock, 0) as calculated_stock
        FROM items i
        INNER JOIN grn_data grn ON i.id = grn.item_id
        WHERE i.active = true
        AND (NOT p_item_filter ? 'item_name' OR p_item_filter->>'item_name' = ''
             OR i.name ILIKE '%' || (p_item_filter->>'item_name') || '%')
        AND (NOT p_item_filter ? 'item_id' OR p_item_filter->>'item_id' = ''
             OR i.id = (p_item_filter->>'item_id')::uuid)
        AND (p_in_stock_only IS NULL OR
             (p_in_stock_only = true AND COALESCE(grn.total_remaining_stock, 0) > 0) OR
             (p_in_stock_only = false))
    )$r$;
  occurrences := (length(definition)-length(replace(definition,marker,'')))/length(marker);
  IF occurrences <> 1 THEN
    RAISE EXCEPTION 'Expected one stock-calculation marker in get_customer_stock_analysis_v2, found %', occurrences;
  END IF;
  EXECUTE replace(definition,marker,replacement);

  SELECT prosecdef, proacl, proconfig INTO STRICT after_secdef, after_acl, after_config
    FROM pg_proc WHERE oid=fn;
  IF NOT after_secdef OR after_secdef IS DISTINCT FROM before_secdef THEN
    RAISE EXCEPTION 'get_customer_stock_analysis_v2 is no longer SECURITY DEFINER';
  END IF;
  IF after_acl IS DISTINCT FROM before_acl THEN
    RAISE EXCEPTION 'get_customer_stock_analysis_v2 grants changed: % became %', before_acl, after_acl;
  END IF;
  IF after_config IS DISTINCT FROM before_config THEN
    RAISE EXCEPTION 'get_customer_stock_analysis_v2 settings changed: % became %', before_config, after_config;
  END IF;
  IF position('lot_dispatches AS (' IN pg_get_functiondef(fn)) = 0 THEN
    RAISE EXCEPTION 'get_customer_stock_analysis_v2 was not patched';
  END IF;
END $patch$;
NOTIFY pgrst, 'reload schema';
