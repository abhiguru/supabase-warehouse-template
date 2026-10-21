{:ok, _} = Application.ensure_all_started(:supavisor)

{:ok, version} =
  case Supavisor.Repo.query!("select version()") do
    %{rows: [[ver]]} -> Supavisor.Helpers.parse_pg_version(ver)
    _ -> nil
  end

# One tenant with one pool user. An earlier version also registered a
# pgbouncer_reporting user for a separate reporting pool, but no migration or
# init script ever created that database role, so it could not log in.
# The pool user signs in with its own password, DB_PASSWORD_POOLER
# (docs/CONTAINER_SECURITY.md, "Database passwords").
pool_user = %{
  "db_user" => "pgbouncer",
  "db_password" => System.fetch_env!("DB_PASSWORD_POOLER"),
  "mode_type" => System.get_env("POOLER_POOL_MODE"),
  "pool_size" => System.get_env("POOLER_DEFAULT_POOL_SIZE"),
  "is_manager" => true
}

params = %{
  "external_id" => System.get_env("POOLER_TENANT_ID"),
  "db_host" => "db",
  "db_port" => System.get_env("POSTGRES_PORT"),
  "db_database" => System.get_env("POSTGRES_DB"),
  "require_user" => false,
  "auth_query" => "SELECT * FROM pgbouncer.get_auth($1)",
  "default_max_clients" => System.get_env("POOLER_MAX_CLIENT_CONN"),
  "default_pool_size" => System.get_env("POOLER_DEFAULT_POOL_SIZE"),
  "default_parameter_status" => %{"server_version" => version},
  "users" => [pool_user]
}

# The tenant is stored (encrypted with VAULT_ENC_KEY) in the _supabase database.
# An existing one keeps its settings, except the server_version it reports to
# clients (default_parameter_status), which is set to the running server's at
# every start: it stays on the old major after a major upgrade (docs/OPERATOR_INSTALL.md,
# "Major PostgreSQL upgrade") otherwise. The pool user's password is written
# again at every start: it changes on the upgrade to per-role passwords, on
# `npm run db:rotate-passwords`, and when a restore brings back an older
# _supabase database.
case Supavisor.Tenants.get_tenant_by_external_id(params["external_id"]) do
  nil ->
    {:ok, _} = Supavisor.Tenants.create_tenant(params)

  tenant ->
    {:ok, _} = Supavisor.Tenants.update_tenant(tenant, %{"default_parameter_status" => params["default_parameter_status"]})
    :ok = Supavisor.Tenants.update_manager_user_credentials(tenant, Map.take(pool_user, ["db_user", "db_password"]))
end
