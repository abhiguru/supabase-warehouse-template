-- Migration 139: the two user_profiles policies read auth.uid() once per statement.
--
-- Migration 137 wrapped warehouse_security.active_role(), owns_customer() and get_current_user_profile_id() in the policies of the 12
-- app-readable tables. The user_profiles policies also called auth.uid() directly, once per row. Same name, command, roles and logic;
-- only the call is wrapped as a scalar subquery.
DROP POLICY IF EXISTS starter_profile_read ON public.user_profiles;
CREATE POLICY starter_profile_read ON public.user_profiles FOR SELECT TO authenticated
  USING ((((SELECT warehouse_security.active_role()) = ANY (ARRAY['admin'::text, 'supervisor'::text])) OR ((auth_user_id = (SELECT auth.uid())) AND active)));
DROP POLICY IF EXISTS starter_profile_update ON public.user_profiles;
CREATE POLICY starter_profile_update ON public.user_profiles FOR UPDATE TO authenticated
  USING (((auth_user_id = (SELECT auth.uid())) AND active))
  WITH CHECK (((auth_user_id = (SELECT auth.uid())) AND active));

NOTIFY pgrst, 'reload schema';
