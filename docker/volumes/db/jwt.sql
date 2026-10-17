\set jwt_exp `echo "$JWT_EXP"`

-- The signing secret is deliberately not stored here as a database setting: a setting is readable
-- by every role through current_setting(). The database code reads warehouse_security.auth_config;
-- migration 92 resets the setting that earlier installs hold.
ALTER DATABASE postgres SET "app.settings.jwt_exp" TO :'jwt_exp';
