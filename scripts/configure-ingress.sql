\set ON_ERROR_STOP on
-- How requests reach this installation (WH-146): setup.sh passes the psql variable ingress_mode (compose.env INGRESS; empty = cloudflare-tunnel).
-- Stored as auth_config 'ingress_mode'; migration 170's pairing functions work only while it is 'local-only'. A rerun with the same value changes nothing.
\if :{?ingress_mode}
\else
  \set ingress_mode ''
\endif
SELECT CASE WHEN :'ingress_mode' IN ('local-only', 'trusted-proxy') THEN :'ingress_mode' ELSE 'cloudflare-tunnel' END AS ingress_mode_value \gset
INSERT INTO warehouse_security.auth_config(key, value) VALUES ('ingress_mode', :'ingress_mode_value')
ON CONFLICT(key) DO UPDATE SET value = excluded.value WHERE warehouse_security.auth_config.value IS DISTINCT FROM excluded.value;
