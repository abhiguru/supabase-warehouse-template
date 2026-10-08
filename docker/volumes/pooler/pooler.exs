{:ok, _} = Application.ensure_all_started(:supavisor)

{:ok, version} =
  case Supavisor.Repo.query!("select version()") do
    %{rows: [[ver]]} -> Supavisor.Helpers.parse_pg_version(ver)
    _ -> nil
  end

# Main tenant with TWO users for pool isolation:
# - pgbouncer: Transactional operations (GRN, Dispatch, Auth) - 50 connections
# - pgbouncer_reporting: Heavy reporting queries (stock analysis) - 25 connections
# Each user gets its own isolated connection pool within the same tenant
reporting_pool_size = System.get_env("POOLER_REPORTING_POOL_SIZE") || "25"

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
  "users" => [
    # Primary user for transactional operations
    %{
      "db_user" => "pgbouncer",
      "db_password" => System.get_env("POSTGRES_PASSWORD"),
      "mode_type" => System.get_env("POOLER_POOL_MODE"),
      "pool_size" => System.get_env("POOLER_DEFAULT_POOL_SIZE"),
      "is_manager" => true
    },
    # Reporting user for heavy stock analysis queries (isolated pool)
    %{
      "db_user" => "pgbouncer_reporting",
      "db_password" => System.get_env("POSTGRES_PASSWORD"),
      "mode_type" => "transaction",
      "pool_size" => reporting_pool_size,
      "is_manager" => false
    }
  ]
}

if !Supavisor.Tenants.get_tenant_by_external_id(params["external_id"]) do
  {:ok, _} = Supavisor.Tenants.create_tenant(params)
end
