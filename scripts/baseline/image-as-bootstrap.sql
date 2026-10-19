-- Used only when the baseline is tried on today's Supabase image (verify-baseline.sh, before the baseline is applied).
-- The new bootstrap has NO default privileges (design 13, H2), while the old image grants default privileges in public
-- to anon, authenticated, service_role and postgres. Without this step, every object the baseline creates in public
-- would get those grants on top of the explicit ones the baseline carries. This removes the image's default privileges
-- in schema public, so the baseline starts from the same state as the new bootstrap. Nothing else is changed.
DO $$
DECLARE d record;
BEGIN
  FOR d IN
    SELECT DISTINCT pg_get_userbyid(a.defaclrole) AS owner,
           CASE a.defaclobjtype WHEN 'r' THEN 'TABLES' WHEN 'S' THEN 'SEQUENCES' WHEN 'f' THEN 'FUNCTIONS' WHEN 'T' THEN 'TYPES' END AS kind,
           CASE x.grantee WHEN 0 THEN 'PUBLIC' ELSE pg_get_userbyid(x.grantee) END AS grantee
      FROM pg_default_acl a, aclexplode(a.defaclacl) x
     WHERE a.defaclnamespace = 'public'::regnamespace AND x.grantee <> a.defaclrole
  LOOP
    EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA public REVOKE ALL ON %s FROM %s',
                   d.owner, d.kind, CASE WHEN d.grantee = 'PUBLIC' THEN 'PUBLIC' ELSE quote_ident(d.grantee) END);
  END LOOP;
  -- What remains are the owner's own entries; revoke those too.
  FOR d IN
    SELECT DISTINCT pg_get_userbyid(a.defaclrole) AS owner,
           CASE a.defaclobjtype WHEN 'r' THEN 'TABLES' WHEN 'S' THEN 'SEQUENCES' WHEN 'f' THEN 'FUNCTIONS' WHEN 'T' THEN 'TYPES' END AS kind
      FROM pg_default_acl a WHERE a.defaclnamespace = 'public'::regnamespace
  LOOP
    EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA public REVOKE ALL ON %s FROM %I', d.owner, d.kind, d.owner);
  END LOOP;
END $$;
