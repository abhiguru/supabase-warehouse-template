-- Migration 149 (WH-96): the kept GRN and dispatch numbers of a cancelled invoice line hold up to 20 characters.
--
-- Migration 143 added invoice_trl.kept_disp_no and kept_grn_no as character varying(8). Migration 127 had already widened
-- dispatch.disp_no and goodsreceived.gr_no to 20 (the numbering rule allows up to 20), so cancel_invoice, which copies the numbers
-- without a cast, raised 22001 (value too long) for a number over 8 characters and the cancel could not finish. Both kept columns now
-- are character varying(20), like their sources. No data is rewritten.
-- Nothing depends on the two columns: no view, rule or index reads them (they were added in 143 and no view was made after), and
-- cancel_invoice, get_invoice_detail and get_invoice_data declare no length for them, so no function is redefined here.

ALTER TABLE public.invoice_trl
  ALTER COLUMN kept_disp_no TYPE character varying(20),
  ALTER COLUMN kept_grn_no TYPE character varying(20);
