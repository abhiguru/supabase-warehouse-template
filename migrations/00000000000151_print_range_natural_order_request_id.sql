-- Migration 151 (WH-109, printing): dispatch print ranges in natural order, and a unique request id per print job.
--
-- 1. public.get_dispatch_range_for_print(start_disp_no, end_disp_no, limit_count): the range was compared as text, so numbers of
--    different widths were out of order (A998..A1002 matched nothing, because 'A998' is above 'A1002' as text, and A9999..A10000 the
--    same), and a disp_no stored with a trailing space could not be printed by its own number ('A1000 ' is above 'A1000').
--    A disp_no is read as <letters><digits><letters> (A1000, A1000B). When both ends have the same letters, a row matches when it has
--    those letters and its (number, suffix) lies between the two ends' (number, suffix), so A1000..A1001 includes A1000B. The number is
--    compared as a number, so leading zeros and digit counts do not matter. Otherwise (an end that does not parse, or different
--    letters) the old text comparison is used, on trimmed, upper-cased values. Rows come back in the same natural order, and the
--    disp_no in the answer is trimmed. Nothing else changes: same signature, SECURITY DEFINER, search_path and grants (CREATE OR
--    REPLACE keeps the ACL), same payload, joins and limit.
--    warehouse_security.document_number_sort_key was looked at and not reused: it orders by the trailing digits only, so a suffixed
--    number (A1000B) lands under its own letters and a trailing space defeats it.
-- 2. public.print_jobs.request_id (uuid, NULL): the print functions will write a 'queued' row first, keyed on a request id the
--    app sends, so a client retry cannot print twice. One id is unique per user; rows without one (all existing rows) are not
--    constrained. No existing data changes.

CREATE OR REPLACE FUNCTION public.get_dispatch_range_for_print(start_disp_no text, end_disp_no text, limit_count integer DEFAULT 100) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
    v_result jsonb;
    v_start text := upper(btrim(start_disp_no));
    v_end   text := upper(btrim(end_disp_no));
    v_sm    text[] := regexp_match(upper(btrim(start_disp_no)), '^([A-Z]*)([0-9]+)([A-Z]*)$');
    v_em    text[] := regexp_match(upper(btrim(end_disp_no)),   '^([A-Z]*)([0-9]+)([A-Z]*)$');
    v_natural boolean;
BEGIN
    v_natural := v_sm IS NOT NULL AND v_em IS NOT NULL AND v_sm[1] = v_em[1];

    WITH parsed AS (
        SELECT d.*, regexp_match(upper(btrim(d.disp_no)), '^([A-Z]*)([0-9]+)([A-Z]*)$') AS m
        FROM dispatch d
    ),
    dispatch_data AS (
        SELECT
            p.id as dispatch_id,
            btrim(p.disp_no) as disp_no,
            TO_CHAR(p.disp_date, 'YYYY-MM-DD') as formatted_date,
            p.registration,
            p.customer_id::TEXT,
            p.customer_name,
            p.supervisor_id::TEXT,
            p.supervisor_name,
            p.note,
            p.disp_image_url,
            p.source_order_id,
            o.order_no as source_order_no,
            COALESCE(p.m[1], upper(btrim(p.disp_no))) as sort_pfx,
            COALESCE(p.m[2]::numeric, -1) as sort_num,
            COALESCE(p.m[3], '') as sort_sfx
        FROM parsed p
        LEFT JOIN orders o ON o.id = p.source_order_id
        WHERE CASE WHEN v_natural THEN
                  p.m IS NOT NULL
                  AND p.m[1] = v_sm[1]
                  AND (p.m[2]::numeric, p.m[3]) >= (v_sm[2]::numeric, v_sm[3])
                  AND (p.m[2]::numeric, p.m[3]) <= (v_em[2]::numeric, v_em[3])
              ELSE
                  upper(btrim(p.disp_no)) >= v_start
                  AND upper(btrim(p.disp_no)) <= v_end
              END
        ORDER BY sort_pfx, sort_num, sort_sfx, btrim(p.disp_no)
        LIMIT limit_count
    ),
    dispatch_with_customer AS (
        SELECT
            dd.*,
            CASE WHEN c.id IS NOT NULL THEN
                jsonb_build_object(
                    'id', c.id::TEXT,
                    'first_name', c."firstName",
                    'last_name', c."lastName",
                    'address', c.address,
                    'city', c.city,
                    'mobile', c.mobile
                )
            ELSE NULL
            END as customer_data
        FROM dispatch_data dd
        LEFT JOIN customers c ON c.id = dd.customer_id::UUID
    ),
    dispatch_items_with_grn AS (
        SELECT
            dwc.*,
            dt.id as dispatch_trl_id,
            dt.disp_qty,
            gr.id as gr_id,
            gr.gr_no,
            TO_CHAR(gr.date, 'YYYY-MM-DD') as gr_date,
            gr.customer_id as gr_customer_id,
            gr.customer_name as gr_customer_name,
            gr.registration as gr_registration,
            gr.gr_image_url as gr_image_url,
            COALESCE(gr.invoiced, FALSE) as gr_invoiced,
            COALESCE(gr.leon, FALSE) as gr_leon,
            gr.note as gr_note,
            COALESCE(gr.out_of_stock, FALSE) as gr_out_of_stock,
            gr.sender_id as gr_sender_id,
            gr.sender_name as gr_sender_name,
            gr.supervisor_id as gr_supervisor_id,
            gr.supervisor_name as gr_supervisor_name,
            grt.id as grt_id,
            grt.item_id as grt_item_id,
            grt.item_name as grt_item_name,
            grt.packaging as grt_packaging,
            grt.qty as grt_qty,
            grt.stock as grt_stock,
            grt.weight as grt_weight,
            grt.rack as grt_rack,
            grt.package_mark as grt_package_mark,
            grt.trl_img_url as grt_trl_img_url,
            ROW_NUMBER() OVER (PARTITION BY dwc.dispatch_id ORDER BY uuid_extract_timestamp(dt.id), dt.id) as sr_no
        FROM dispatch_with_customer dwc
        LEFT JOIN dispatch_trl dt ON dt.disp_id = dwc.dispatch_id
        LEFT JOIN goodsreceived gr ON gr.id = dt.gr_id
        LEFT JOIN goodsreceived_trl grt ON grt.id = dt.gr_trl_id
    ),
    dispatch_with_items AS (
        SELECT
            diwg.dispatch_id,
            diwg.disp_no,
            diwg.formatted_date,
            diwg.registration,
            diwg.customer_id,
            diwg.customer_name,
            diwg.supervisor_id,
            diwg.supervisor_name,
            diwg.note,
            diwg.disp_image_url,
            diwg.source_order_id,
            diwg.source_order_no,
            diwg.customer_data,
            diwg.sort_pfx,
            diwg.sort_num,
            diwg.sort_sfx,
            jsonb_agg(
                CASE WHEN diwg.dispatch_trl_id IS NOT NULL THEN
                    jsonb_build_object(
                        'id', diwg.dispatch_trl_id::TEXT,
                        'dispatch_id', diwg.dispatch_id::TEXT,
                        'disp_no', diwg.disp_no,
                        'disp_quantity', COALESCE(diwg.disp_qty, 0),
                        'grn_items_id', diwg.grt_id::TEXT,
                        'grn_items_image_url', diwg.grt_trl_img_url,
                        'grn_items_item_id', diwg.grt_item_id::TEXT,
                        'grn_items_item_name', diwg.grt_item_name,
                        'grn_items_package_mark', diwg.grt_package_mark,
                        'grn_items_packaging', diwg.grt_packaging,
                        'grn_items_quantity', COALESCE(diwg.grt_qty, 0),
                        'grn_items_rack', diwg.grt_rack,
                        'grn_items_stock', COALESCE(diwg.grt_stock, 0),
                        'grn_items_weight', COALESCE(diwg.grt_weight, 0),
                        'grns_id', diwg.gr_id::TEXT,
                        'grns_gr_no', diwg.gr_no,
                        'grns_date', diwg.gr_date,
                        'grns_customer_id', diwg.gr_customer_id::TEXT,
                        'grns_customer_name', diwg.gr_customer_name,
                        'grns_registration', diwg.gr_registration,
                        'grns_image_url', diwg.gr_image_url,
                        'grns_invoiced', diwg.gr_invoiced,
                        'grns_leon', diwg.gr_leon,
                        'grns_note', diwg.gr_note,
                        'grns_out_of_stock', diwg.gr_out_of_stock,
                        'grns_sender_id', diwg.gr_sender_id::TEXT,
                        'grns_sender_name', diwg.gr_sender_name,
                        'grns_supervisor_id', diwg.gr_supervisor_id::TEXT,
                        'grns_supervisor_name', diwg.gr_supervisor_name,
                        'sr_no', diwg.sr_no
                    )
                ELSE NULL
                END
                ORDER BY diwg.sr_no
            ) FILTER (WHERE diwg.dispatch_trl_id IS NOT NULL) as items_data,
            SUM(COALESCE(diwg.disp_qty, 0)) as total_quantity
        FROM dispatch_items_with_grn diwg
        GROUP BY
            diwg.dispatch_id, diwg.disp_no, diwg.formatted_date, diwg.registration,
            diwg.customer_id, diwg.customer_name, diwg.supervisor_id, diwg.supervisor_name,
            diwg.note, diwg.disp_image_url, diwg.source_order_id, diwg.source_order_no, diwg.customer_data,
            diwg.sort_pfx, diwg.sort_num, diwg.sort_sfx
    ),
    final_result AS (
        SELECT jsonb_agg(
            jsonb_build_object(
                'id', dwi.dispatch_id,
                'disp_no', dwi.disp_no,
                'disp_date', dwi.formatted_date,
                'registration', dwi.registration,
                'customer_id', dwi.customer_id,
                'customer_name', dwi.customer_name,
                'supervisor_id', dwi.supervisor_id,
                'supervisor_name', dwi.supervisor_name,
                'note', dwi.note,
                'image_url', dwi.disp_image_url,
                'source_order_id', dwi.source_order_id,
                'source_order_no', dwi.source_order_no,
                'customer', dwi.customer_data,
                'items', COALESCE(dwi.items_data, '[]'::jsonb),
                'total_qty', COALESCE(dwi.total_quantity, 0)::INTEGER,
                'total_qty_in_words', convert_number_to_words(COALESCE(dwi.total_quantity, 0)::INTEGER)
            ) ORDER BY dwi.sort_pfx, dwi.sort_num, dwi.sort_sfx, dwi.disp_no
        ) as data
        FROM dispatch_with_items dwi
    )
    SELECT COALESCE(data, '[]'::jsonb) INTO v_result FROM final_result;

    RETURN utils.success_response(v_result, NULL);
END;
$$;

ALTER TABLE public.print_jobs ADD COLUMN IF NOT EXISTS request_id uuid;

CREATE UNIQUE INDEX IF NOT EXISTS print_jobs_user_request_id_key ON public.print_jobs (user_id, request_id) WHERE request_id IS NOT NULL;
