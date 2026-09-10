-- ============================================================
-- Supabase Warehouse Template - Initial Schema
-- ============================================================
-- This migration creates all tables, functions, indexes, and RLS policies
-- for a warehouse management system with custom OTP authentication.
--
-- Tables: ~25 (auth, config, warehouse domain)
-- Functions: ~15 (auth, CRUD, utilities)
-- ============================================================

-- Enable required extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp" SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pgcrypto SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- ============================================================
-- AUTH TABLES
-- ============================================================

CREATE TABLE public.item_storage_prices (
    id uuid DEFAULT extensions.uuid_generate_v1() NOT NULL,
    item_id uuid NOT NULL,
    customer_id uuid,
    weight_min integer NOT NULL,
    weight_max integer NOT NULL,
    labour_rate numeric(12,2) NOT NULL,
    tax_percent numeric(5,2) NOT NULL,
    effective_from date DEFAULT CURRENT_DATE NOT NULL,
    effective_to date,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid,
    unit_price_one_time numeric(12,2) NOT NULL,
    unit_price_monthly numeric(12,2) NOT NULL,
    price_type text NOT NULL,
    unit_price numeric(12,2) NOT NULL,
    CONSTRAINT dates_valid CHECK (((effective_to IS NULL) OR (effective_from < effective_to))),
    CONSTRAINT labour_rate_positive CHECK ((labour_rate >= (0)::numeric)),
    CONSTRAINT price_type_valid CHECK ((price_type = ANY (ARRAY['one_time'::text, 'monthly'::text]))),
    CONSTRAINT tax_percent_valid CHECK (((tax_percent >= (0)::numeric) AND (tax_percent <= (100)::numeric))),
    CONSTRAINT unit_price_monthly_positive CHECK (((unit_price_monthly IS NULL) OR (unit_price_monthly >= (0)::numeric))),
    CONSTRAINT unit_price_one_time_positive CHECK (((unit_price_one_time IS NULL) OR (unit_price_one_time >= (0)::numeric))),
    CONSTRAINT unit_price_positive CHECK ((unit_price >= (0)::numeric)),
    CONSTRAINT weight_range_valid CHECK ((weight_min <= weight_max))
);
CREATE TABLE public.api_configurations (
    id uuid DEFAULT extensions.uuid_generate_v4() NOT NULL,
    environment character varying(20) NOT NULL,
    app_version character varying(20) DEFAULT '1.0.0'::character varying NOT NULL,
    build_date timestamp with time zone DEFAULT now() NOT NULL,
    maintenance_mode boolean DEFAULT false,
    mapbox_token text,
    google_maps_key text,
    sentry_dsn text,
    custom_config jsonb,
    is_active boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now()
);
CREATE TABLE public.audit_log (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    table_name text NOT NULL,
    action text NOT NULL,
    user_id uuid,
    old_data jsonb,
    new_data jsonb,
    ip_address inet,
    user_agent text,
    created_at timestamp with time zone DEFAULT now() NOT NULL
)
PARTITION BY RANGE (created_at);
CREATE TABLE public.auth_logs (
    id uuid DEFAULT extensions.uuid_generate_v1() NOT NULL,
    action character varying(50) NOT NULL,
    phone_number character varying(15),
    user_id uuid,
    success boolean NOT NULL,
    details jsonb,
    ip_address inet,
    user_agent text,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);
CREATE TABLE public.customers (
    id uuid DEFAULT extensions.uuid_generate_v1() NOT NULL,
    address character varying(300) DEFAULT NULL::character varying,
    city character varying(25) DEFAULT NULL::character varying,
    "firstName" character varying(30) DEFAULT NULL::character varying,
    "lastName" character varying(30) DEFAULT NULL::character varying,
    mobile character varying(30) DEFAULT NULL::character varying,
    name character varying(80) NOT NULL,
    pincode character varying(30) DEFAULT NULL::character varying,
    state character varying(50) DEFAULT NULL::character varying,
    telephone1 character varying(30) DEFAULT NULL::character varying,
    telephone2 character varying(30) DEFAULT NULL::character varying,
    gst character varying(30) DEFAULT NULL::character varying,
    email character varying(100) DEFAULT NULL::character varying,
    active boolean DEFAULT true NOT NULL,
    created_by uuid,
    updated_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now(),
    auto_invoice_generation boolean DEFAULT false,
    contact text,
    pan character varying(30),
    deleted_at timestamp with time zone,
    deleted_by uuid,
    contact_person character varying(100),
    contact_mobile character varying(20),
    contact_email character varying(255),
    image_urls text[],
    document_urls text[]
);
CREATE TABLE public.dispatch (
    id uuid DEFAULT extensions.uuid_generate_v1() NOT NULL,
    disp_no character varying(8) NOT NULL,
    registration character varying(14) DEFAULT NULL::character varying,
    disp_date timestamp with time zone,
    customer_id uuid NOT NULL,
    customer_name character varying(200) DEFAULT NULL::character varying,
    supervisor_id uuid,
    supervisor_name character varying(80) DEFAULT NULL::character varying,
    note character varying(800) DEFAULT NULL::character varying,
    disp_image_url character varying(400) DEFAULT NULL::character varying,
    created_by uuid,
    updated_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now(),
    source_order_id uuid,
    source_order_no text,
    deleted_at timestamp with time zone,
    deleted_by uuid
);
CREATE TABLE public.feature_flags (
    id uuid DEFAULT extensions.uuid_generate_v4() NOT NULL,
    name character varying(100) NOT NULL,
    description text,
    enabled boolean DEFAULT false,
    rollout_percentage integer,
    user_roles text[],
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now(),
    CONSTRAINT feature_flags_rollout_percentage_check CHECK (((rollout_percentage >= 0) AND (rollout_percentage <= 100)))
);
CREATE TABLE public.goodsreceived (
    id uuid DEFAULT extensions.uuid_generate_v1() NOT NULL,
    gr_no character varying(8) NOT NULL,
    registration character varying(20) DEFAULT NULL::character varying,
    date timestamp with time zone,
    sender_id uuid,
    sender_name character varying(200) DEFAULT NULL::character varying,
    customer_id uuid NOT NULL,
    customer_name character varying(200) DEFAULT NULL::character varying,
    supervisor_id uuid,
    supervisor_name character varying(30) DEFAULT NULL::character varying,
    note character varying(280) DEFAULT NULL::character varying,
    leon boolean,
    out_of_stock boolean,
    invoiced boolean,
    gr_image_url character varying(80) DEFAULT NULL::character varying,
    created_by uuid,
    updated_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now(),
    pricing_mode character varying(20),
    deleted_at timestamp with time zone,
    deleted_by uuid,
    CONSTRAINT goodsreceived_pricing_mode_check CHECK (((pricing_mode)::text = ANY (ARRAY[('ONE_TIME'::character varying)::text, ('MONTHLY'::character varying)::text])))
);
CREATE TABLE public.invoice (
    id uuid DEFAULT extensions.uuid_generate_v1() NOT NULL,
    inv_fin_year integer NOT NULL,
    inv_no integer NOT NULL,
    gr_id uuid NOT NULL,
    gr_no character varying(8) NOT NULL,
    customer_id uuid NOT NULL,
    customer_name character varying(200),
    inv_name character varying(300),
    inv_date timestamp with time zone NOT NULL,
    one_time_charge boolean DEFAULT false,
    is_auto_generated boolean DEFAULT false,
    pricing_mode character varying(20),
    notes text,
    created_by uuid,
    labour numeric(12,2),
    tax_amount numeric(12,2),
    total numeric(12,2),
    discount numeric(12,2),
    deleted_at timestamp with time zone,
    deleted_by uuid,
    CONSTRAINT chk_invoice_total_nonneg CHECK ((total >= (0)::numeric)),
    CONSTRAINT invoice_pricing_mode_check CHECK (((pricing_mode)::text = ANY (ARRAY[('ONE_TIME'::character varying)::text, ('MONTHLY'::character varying)::text])))
);
CREATE TABLE public.items (
    id uuid DEFAULT extensions.uuid_generate_v1() NOT NULL,
    name character varying(80) NOT NULL,
    packaging character varying(40),
    description character varying(40),
    active boolean DEFAULT true
);
CREATE TABLE public.jwt_config (
    id integer NOT NULL,
    secret_name character varying(50) NOT NULL,
    secret_value text NOT NULL,
    is_active boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now()
);
CREATE SEQUENCE public.jwt_config_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;
ALTER SEQUENCE public.jwt_config_id_seq OWNED BY public.jwt_config.id;
CREATE TABLE public.sms_config (
    id integer NOT NULL,
    production_mode boolean DEFAULT false,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now(),
    provider character varying(20) DEFAULT 'twilio'::character varying,
    account_sid text,
    auth_token text,
    from_phone text,
    msg91_auth_key text,
    msg91_template_id text,
    msg91_sender_id character varying(6) DEFAULT 'MYAPP'::character varying,
    msg91_pe_id text
);
CREATE SEQUENCE public.msg91_config_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;
ALTER SEQUENCE public.msg91_config_id_seq OWNED BY public.sms_config.id;
CREATE TABLE public.user_profiles (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    auth_user_id uuid NOT NULL,
    name character varying(30),
    display_name character varying(30),
    role public.user_role DEFAULT 'user'::public.user_role NOT NULL,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now(),
    mobile character varying(15) NOT NULL,
    mobile_verified boolean DEFAULT false NOT NULL,
    mobile_verified_at timestamp with time zone,
    CONSTRAINT check_mobile_no_plus_prefix CHECK (((mobile)::text !~~ '+%'::text))
);
CREATE TABLE public.otp_rate_limits (
    phone_number character varying(15) NOT NULL,
    hourly_count integer DEFAULT 0,
    daily_count integer DEFAULT 0,
    last_reset_hour timestamp with time zone DEFAULT now(),
    last_reset_day timestamp with time zone DEFAULT now(),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now()
);
CREATE TABLE public.otp_verifications (
    id uuid DEFAULT extensions.uuid_generate_v1() NOT NULL,
    phone_number character varying(15) NOT NULL,
    otp_code character varying(6),
    otp_hash character varying(255),
    msg91_request_id character varying(255),
    purpose character varying(50) NOT NULL,
    attempts integer DEFAULT 0 NOT NULL,
    max_attempts integer DEFAULT 3 NOT NULL,
    verified boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    expires_at timestamp with time zone DEFAULT (now() + '00:10:00'::interval) NOT NULL,
    verified_at timestamp with time zone,
    user_agent text,
    ip_address inet,
    msg91_status text,
    msg91_response jsonb,
    delivery_status text DEFAULT 'pending'::text,
    otp_code_hash text,
    failed_attempts integer DEFAULT 0,
    locked_until timestamp with time zone,
    CONSTRAINT otp_verifications_purpose_check CHECK (((purpose)::text = ANY (ARRAY[('login'::character varying)::text, ('registration'::character varying)::text, ('phone_verification'::character varying)::text, ('password_reset'::character varying)::text])))
);
CREATE TABLE public.payments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    payment_no character varying(8) NOT NULL,
    payment_date timestamp with time zone NOT NULL,
    customer_id uuid,
    customer_name character varying(200) DEFAULT NULL::character varying,
    supervisor_id uuid,
    supervisor_name character varying(30) DEFAULT NULL::character varying,
    note character varying(800) DEFAULT NULL::character varying,
    payment_mode character varying(12) DEFAULT NULL::character varying,
    bank character varying(50) DEFAULT NULL::character varying,
    cheque_no character varying(12) DEFAULT NULL::character varying,
    online_ref character varying(50) DEFAULT NULL::character varying,
    amount numeric(12,2),
    invoice_id uuid
);
CREATE TABLE public.print_jobs (
    id uuid DEFAULT extensions.uuid_generate_v4() NOT NULL,
    cups_job_id integer,
    job_type character varying(20) NOT NULL,
    document_range_start character varying(50) NOT NULL,
    document_range_end character varying(50) NOT NULL,
    document_count integer,
    user_id uuid NOT NULL,
    user_name character varying(100),
    status character varying(20) DEFAULT 'queued'::character varying NOT NULL,
    error_message text,
    content_size integer,
    printer_name character varying(100),
    submitted_at timestamp with time zone DEFAULT now() NOT NULL,
    completed_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT print_jobs_job_type_check CHECK (((job_type)::text = ANY (ARRAY[('GRN'::character varying)::text, ('Invoice'::character varying)::text, ('Dispatch'::character varying)::text]))),
    CONSTRAINT print_jobs_status_check CHECK (((status)::text = ANY (ARRAY[('queued'::character varying)::text, ('printing'::character varying)::text, ('completed'::character varying)::text, ('cancelled'::character varying)::text, ('failed'::character varying)::text])))
);
CREATE TABLE public.printer_status (
    printer_name text NOT NULL,
    status text NOT NULL,
    message text,
    last_updated timestamp with time zone DEFAULT now(),
    last_job_id integer,
    last_error text,
    CONSTRAINT printer_status_status_check CHECK ((status = ANY (ARRAY['online'::text, 'offline'::text, 'error'::text, 'busy'::text])))
);
CREATE TABLE public.user_session_activity (
    id uuid DEFAULT extensions.uuid_generate_v4() NOT NULL,
    user_id uuid NOT NULL,
    auth_session_id uuid,
    last_activity_at timestamp with time zone DEFAULT now() NOT NULL,
    ip_address inet,
    user_agent text,
    activity_type character varying(50),
    created_at timestamp with time zone DEFAULT now() NOT NULL
);
CREATE TABLE public.stock_movements (
    id uuid DEFAULT extensions.uuid_generate_v1() NOT NULL,
    gr_trl_id uuid NOT NULL,
    movement_type character varying(20) NOT NULL,
    quantity integer NOT NULL,
    reference_id uuid,
    reference_type character varying(20),
    balance_before integer NOT NULL,
    balance_after integer NOT NULL,
    notes text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid,
    CONSTRAINT stock_movements_movement_type_check CHECK (((movement_type)::text = ANY (ARRAY[('dispatch'::character varying)::text, ('return'::character varying)::text, ('adjustment'::character varying)::text])))
);
CREATE TABLE public.system_settings (
    key character varying(100) NOT NULL,
    value text NOT NULL,
    description text,
    updated_at timestamp with time zone DEFAULT now()
);
CREATE TABLE public.test_otp_records (
    phone_number character varying(15) NOT NULL,
    fixed_otp character varying(6),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now()
);
ALTER TABLE ONLY public.jwt_config ALTER COLUMN id SET DEFAULT nextval('public.jwt_config_id_seq'::regclass);
ALTER TABLE ONLY public.sms_config ALTER COLUMN id SET DEFAULT nextval('public.msg91_config_id_seq'::regclass);
ALTER TABLE ONLY public.api_configurations
    ADD CONSTRAINT api_configurations_environment_is_active_key UNIQUE (environment, is_active);
ALTER TABLE ONLY public.api_configurations
    ADD CONSTRAINT api_configurations_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.audit_log
    ADD CONSTRAINT audit_log_pkey PRIMARY KEY (id, created_at);
ALTER TABLE ONLY public.auth_logs
    ADD CONSTRAINT auth_logs_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.customers
    ADD CONSTRAINT customers_name_key UNIQUE (name);
ALTER TABLE ONLY public.customers
    ADD CONSTRAINT customers_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.dispatch
    ADD CONSTRAINT dispatch_disp_no_key UNIQUE (disp_no);
ALTER TABLE ONLY public.dispatch
    ADD CONSTRAINT dispatch_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.feature_flags
    ADD CONSTRAINT feature_flags_name_key UNIQUE (name);
ALTER TABLE ONLY public.feature_flags
    ADD CONSTRAINT feature_flags_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.goodsreceived
    ADD CONSTRAINT goodsreceived_gr_no_key UNIQUE (gr_no);
ALTER TABLE ONLY public.goodsreceived
    ADD CONSTRAINT goodsreceived_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.invoice
    ADD CONSTRAINT invoice_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.item_storage_prices
    ADD CONSTRAINT item_storage_prices_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.items
    ADD CONSTRAINT items_name_key UNIQUE (name);
ALTER TABLE ONLY public.items
    ADD CONSTRAINT items_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.jwt_config
    ADD CONSTRAINT jwt_config_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.jwt_config
    ADD CONSTRAINT jwt_config_secret_name_key UNIQUE (secret_name);
ALTER TABLE ONLY public.sms_config
    ADD CONSTRAINT msg91_config_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.otp_rate_limits
    ADD CONSTRAINT otp_rate_limits_pkey PRIMARY KEY (phone_number);
ALTER TABLE ONLY public.otp_verifications
    ADD CONSTRAINT otp_verifications_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_payment_no_key UNIQUE (payment_no);
ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.print_jobs
    ADD CONSTRAINT print_jobs_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.printer_status
    ADD CONSTRAINT printer_status_pkey PRIMARY KEY (printer_name);
ALTER TABLE ONLY public.stock_movements
    ADD CONSTRAINT stock_movements_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.system_settings
    ADD CONSTRAINT system_settings_pkey PRIMARY KEY (key);
ALTER TABLE ONLY public.test_otp_records
    ADD CONSTRAINT test_otp_records_pkey PRIMARY KEY (phone_number);
ALTER TABLE ONLY public.invoice
    ADD CONSTRAINT unique_inv_no_per_year UNIQUE (inv_fin_year, inv_no);
ALTER TABLE ONLY public.user_profiles
    ADD CONSTRAINT user_profiles_auth_user_id_key UNIQUE (auth_user_id);
ALTER TABLE ONLY public.user_profiles
    ADD CONSTRAINT user_profiles_mobile_unique UNIQUE (mobile);
ALTER TABLE ONLY public.user_profiles
    ADD CONSTRAINT user_profiles_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.user_session_activity
    ADD CONSTRAINT user_session_activity_pkey PRIMARY KEY (id);
CREATE INDEX idx_api_config_env ON public.api_configurations USING btree (environment, is_active);
CREATE INDEX idx_audit_log_table_created ON ONLY public.audit_log USING btree (table_name, created_at DESC);
CREATE INDEX idx_audit_log_user_created ON ONLY public.audit_log USING btree (user_id, created_at DESC);
CREATE INDEX idx_auth_logs_created_at ON public.auth_logs USING btree (created_at);
CREATE INDEX idx_auth_logs_phone ON public.auth_logs USING btree (phone_number);
CREATE INDEX idx_auth_logs_user_id ON public.auth_logs USING btree (user_id);
CREATE INDEX idx_customers_active_only ON public.customers USING btree (id) WHERE ((active = true) AND (deleted_at IS NULL));
CREATE INDEX idx_customers_contact ON public.customers USING btree (contact);
CREATE INDEX idx_customers_deleted_at ON public.customers USING btree (deleted_at) WHERE (deleted_at IS NULL);
CREATE INDEX idx_customers_deleted_by_fk ON public.customers USING btree (deleted_by) WHERE (deleted_by IS NOT NULL);
CREATE INDEX idx_customers_mobile ON public.customers USING btree (mobile);
CREATE INDEX idx_customers_pan ON public.customers USING btree (pan);
CREATE INDEX idx_dispatch_customer_id ON public.dispatch USING btree (customer_id);
CREATE INDEX idx_dispatch_deleted_at ON public.dispatch USING btree (deleted_at) WHERE (deleted_at IS NULL);
CREATE INDEX idx_dispatch_deleted_by_fk ON public.dispatch USING btree (deleted_by) WHERE (deleted_by IS NOT NULL);
CREATE INDEX idx_dispatch_disp_date ON public.dispatch USING btree (disp_date);
CREATE INDEX idx_dispatch_registration_upper ON public.dispatch USING btree (upper((registration)::text) text_pattern_ops) WHERE ((registration IS NOT NULL) AND ((registration)::text <> ''::text) AND (deleted_at IS NULL));
CREATE INDEX idx_dispatch_source_order_id ON public.dispatch USING btree (source_order_id);
CREATE INDEX idx_feature_flags_enabled ON public.feature_flags USING btree (enabled);
CREATE INDEX idx_goodsreceived_customer_deleted_active ON public.goodsreceived USING btree (customer_id, id, gr_no, date, customer_name) WHERE (deleted_at IS NULL);
CREATE INDEX idx_goodsreceived_customer_id ON public.goodsreceived USING btree (customer_id);
CREATE INDEX idx_goodsreceived_date_active ON public.goodsreceived USING btree (date DESC) WHERE (deleted_at IS NULL);
CREATE INDEX idx_goodsreceived_deleted_at ON public.goodsreceived USING btree (deleted_at) WHERE (deleted_at IS NULL);
CREATE INDEX idx_goodsreceived_deleted_by_fk ON public.goodsreceived USING btree (deleted_by) WHERE (deleted_by IS NOT NULL);
CREATE INDEX idx_goodsreceived_gr_id_no ON public.goodsreceived USING btree (id, gr_no);
CREATE INDEX idx_goodsreceived_gr_no_prefix ON public.goodsreceived USING btree ("left"((gr_no)::text, 1), customer_id) WHERE (deleted_at IS NULL);
CREATE INDEX idx_goodsreceived_gr_no_trgm ON public.goodsreceived USING gin (gr_no public.gin_trgm_ops);
CREATE INDEX idx_goodsreceived_registration_upper ON public.goodsreceived USING btree (upper((registration)::text) text_pattern_ops) WHERE ((registration IS NOT NULL) AND ((registration)::text <> ''::text) AND (deleted_at IS NULL));
CREATE INDEX idx_goodsreceived_search ON public.goodsreceived USING btree (gr_no, customer_name, date DESC);
CREATE INDEX idx_invoice_customer_date ON public.invoice USING btree (customer_id, inv_date DESC);
CREATE INDEX idx_invoice_customer_id ON public.invoice USING btree (customer_id);
CREATE INDEX idx_invoice_deleted_at ON public.invoice USING btree (deleted_at) WHERE (deleted_at IS NULL);
CREATE INDEX idx_invoice_deleted_by ON public.invoice USING btree (deleted_by) WHERE (deleted_by IS NOT NULL);
CREATE INDEX idx_invoice_grn ON public.invoice USING btree (gr_id, inv_date DESC);
CREATE INDEX idx_invoice_inv_date ON public.invoice USING btree (inv_date DESC);
CREATE INDEX idx_invoice_inv_fin_year ON public.invoice USING btree (inv_fin_year);
CREATE INDEX idx_item_storage_prices_created_by ON public.item_storage_prices USING btree (created_by);
CREATE INDEX idx_item_storage_prices_customer_id ON public.item_storage_prices USING btree (customer_id);
CREATE INDEX idx_item_storage_prices_effective_dates ON public.item_storage_prices USING btree (effective_from, effective_to);
CREATE INDEX idx_item_storage_prices_item_id ON public.item_storage_prices USING btree (item_id);
CREATE UNIQUE INDEX idx_item_storage_prices_unique_combo ON public.item_storage_prices USING btree (item_id, COALESCE(customer_id, '00000000-0000-0000-0000-000000000000'::uuid), weight_min, weight_max, price_type, effective_from, COALESCE(effective_to, '9999-12-31'::date));
CREATE INDEX idx_item_storage_prices_weight_range ON public.item_storage_prices USING btree (weight_min, weight_max);
CREATE INDEX idx_otp_created_at ON public.otp_verifications USING btree (created_at);
CREATE INDEX idx_otp_expires_at ON public.otp_verifications USING btree (expires_at);
CREATE INDEX idx_otp_phone_purpose ON public.otp_verifications USING btree (phone_number, purpose);
CREATE INDEX idx_payments_customer_id ON public.payments USING btree (customer_id);
CREATE INDEX idx_payments_invoice_id ON public.payments USING btree (invoice_id) WHERE (invoice_id IS NOT NULL);
CREATE INDEX idx_payments_supervisor_id ON public.payments USING btree (supervisor_id);
CREATE INDEX idx_print_jobs_cups_job_id ON public.print_jobs USING btree (cups_job_id);
CREATE INDEX idx_print_jobs_job_type ON public.print_jobs USING btree (job_type);
CREATE INDEX idx_print_jobs_status ON public.print_jobs USING btree (status);
CREATE INDEX idx_print_jobs_submitted_at ON public.print_jobs USING btree (submitted_at DESC);
CREATE INDEX idx_print_jobs_user_id ON public.print_jobs USING btree (user_id);
CREATE INDEX idx_printer_status_name ON public.printer_status USING btree (printer_name);
CREATE INDEX idx_session_activity_auth_session ON public.user_session_activity USING btree (auth_session_id);
CREATE INDEX idx_session_activity_last_activity ON public.user_session_activity USING btree (last_activity_at DESC);
CREATE INDEX idx_session_activity_user_id ON public.user_session_activity USING btree (user_id);
CREATE INDEX idx_stock_movements_gr_trl_id ON public.stock_movements USING btree (gr_trl_id);
CREATE INDEX idx_user_profiles_active ON public.user_profiles USING btree (active);
CREATE INDEX idx_user_profiles_auth_uid_role ON public.user_profiles USING btree (auth_user_id) INCLUDE (role) WHERE (auth_user_id IS NOT NULL);
CREATE INDEX idx_user_profiles_rls_check ON public.user_profiles USING btree (auth_user_id, role, active) WHERE (active = true);
CREATE INDEX idx_user_profiles_rls_composite ON public.user_profiles USING btree (auth_user_id, active, role) WHERE (active = true);
CREATE INDEX idx_user_profiles_role ON public.user_profiles USING btree (role);
CREATE TRIGGER audit_customers AFTER INSERT OR DELETE OR UPDATE ON public.customers FOR EACH ROW EXECUTE FUNCTION public.audit_trigger_func();
CREATE TRIGGER audit_dispatch AFTER INSERT OR DELETE OR UPDATE ON public.dispatch FOR EACH ROW EXECUTE FUNCTION public.audit_trigger_func();
CREATE TRIGGER audit_user_profiles AFTER INSERT OR DELETE OR UPDATE ON public.user_profiles FOR EACH ROW EXECUTE FUNCTION public.audit_trigger_func();
CREATE TRIGGER trg_mark_dispatch_mvs_dirty AFTER INSERT OR DELETE OR UPDATE ON public.dispatch FOR EACH STATEMENT EXECUTE FUNCTION public.mark_dispatch_mvs_dirty();
CREATE TRIGGER trg_mark_grn_mvs_dirty AFTER INSERT OR DELETE OR UPDATE ON public.goodsreceived FOR EACH STATEMENT EXECUTE FUNCTION public.mark_grn_mvs_dirty();
CREATE TRIGGER trg_mv_dispatch_list_refresh_on_customers AFTER INSERT OR DELETE OR UPDATE ON public.customers FOR EACH STATEMENT EXECUTE FUNCTION public.trigger_refresh_dispatch_list_mv();
CREATE TRIGGER trg_mv_grn_list_refresh_on_customers AFTER INSERT OR DELETE OR UPDATE ON public.customers FOR EACH STATEMENT EXECUTE FUNCTION public.trigger_refresh_grn_list_mv();
CREATE TRIGGER trg_mv_grn_list_refresh_on_items AFTER INSERT OR DELETE OR UPDATE ON public.items FOR EACH STATEMENT EXECUTE FUNCTION public.trigger_refresh_grn_list_mv();
CREATE TRIGGER trg_mv_invoice_list_refresh_on_customers AFTER INSERT OR DELETE OR UPDATE ON public.customers FOR EACH STATEMENT EXECUTE FUNCTION public.trigger_refresh_invoice_list_mv();
CREATE TRIGGER trg_mv_invoice_list_refresh_on_inv AFTER INSERT OR DELETE OR UPDATE ON public.invoice FOR EACH STATEMENT EXECUTE FUNCTION public.trigger_refresh_invoice_list_mv();
CREATE TRIGGER trg_mv_orders_list_refresh_on_customers AFTER INSERT OR DELETE OR UPDATE ON public.customers FOR EACH STATEMENT EXECUTE FUNCTION public.trigger_refresh_orders_list_mv();
CREATE TRIGGER trg_restore_stock_on_dispatch_delete BEFORE DELETE ON public.dispatch FOR EACH ROW EXECUTE FUNCTION public.restore_stock_on_dispatch_delete();
CREATE TRIGGER trigger_auto_cleanup_otps AFTER INSERT ON public.otp_verifications FOR EACH ROW EXECUTE FUNCTION public.auto_cleanup_expired_otps();
CREATE TRIGGER trigger_customers_audit BEFORE INSERT OR UPDATE ON public.customers FOR EACH ROW EXECUTE FUNCTION public.set_audit_columns();
CREATE TRIGGER trigger_customers_updated_at BEFORE UPDATE ON public.customers FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER trigger_dispatch_audit BEFORE INSERT OR UPDATE ON public.dispatch FOR EACH ROW EXECUTE FUNCTION public.set_audit_columns();
CREATE TRIGGER trigger_dispatch_updated_at BEFORE UPDATE ON public.dispatch FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER trigger_goodsreceived_audit BEFORE INSERT OR UPDATE ON public.goodsreceived FOR EACH ROW EXECUTE FUNCTION public.set_audit_columns();
CREATE TRIGGER trigger_goodsreceived_updated_at BEFORE UPDATE ON public.goodsreceived FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER trigger_reset_grn_invoiced_on_invoice_delete AFTER DELETE ON public.invoice FOR EACH ROW EXECUTE FUNCTION public.reset_grn_invoiced_flag();
CREATE TRIGGER trigger_user_profiles_updated_at BEFORE UPDATE ON public.user_profiles FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_api_configurations_updated_at BEFORE UPDATE ON public.api_configurations FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_feature_flags_updated_at BEFORE UPDATE ON public.feature_flags FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_jwt_config_updated_at BEFORE UPDATE ON public.jwt_config FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_otp_rate_limits_updated_at BEFORE UPDATE ON public.otp_rate_limits FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_print_jobs_updated_at BEFORE UPDATE ON public.print_jobs FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_sms_config_updated_at BEFORE UPDATE ON public.sms_config FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_system_settings_updated_at BEFORE UPDATE ON public.system_settings FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_test_otp_records_updated_at BEFORE UPDATE ON public.test_otp_records FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
ALTER TABLE ONLY public.customers
    ADD CONSTRAINT customers_deleted_by_fkey FOREIGN KEY (deleted_by) REFERENCES public.user_profiles(id);
ALTER TABLE ONLY public.customers
    ADD CONSTRAINT customers_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.user_profiles(id) ON DELETE SET NULL;
ALTER TABLE ONLY public.dispatch
    ADD CONSTRAINT dispatch_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.user_profiles(id) ON DELETE SET NULL;
ALTER TABLE ONLY public.dispatch
    ADD CONSTRAINT dispatch_deleted_by_fkey FOREIGN KEY (deleted_by) REFERENCES public.user_profiles(id);
ALTER TABLE ONLY public.dispatch
    ADD CONSTRAINT dispatch_source_order_id_fkey FOREIGN KEY (source_order_id) REFERENCES public.orders(id);
ALTER TABLE ONLY public.dispatch
    ADD CONSTRAINT dispatch_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.user_profiles(id) ON DELETE SET NULL;
ALTER TABLE ONLY public.dispatch
    ADD CONSTRAINT dispatch_user_profiles_supervisor_fk FOREIGN KEY (supervisor_id) REFERENCES public.user_profiles(id) ON DELETE SET NULL;
ALTER TABLE ONLY public.user_session_activity
    ADD CONSTRAINT fk_user_session_activity_user FOREIGN KEY (user_id) REFERENCES public.user_profiles(id);
ALTER TABLE ONLY public.goodsreceived
    ADD CONSTRAINT goodsreceived_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.user_profiles(id) ON DELETE SET NULL;
ALTER TABLE ONLY public.goodsreceived
    ADD CONSTRAINT goodsreceived_customers_id_fk FOREIGN KEY (customer_id) REFERENCES public.customers(id);
ALTER TABLE ONLY public.goodsreceived
    ADD CONSTRAINT goodsreceived_deleted_by_fkey FOREIGN KEY (deleted_by) REFERENCES public.user_profiles(id);
ALTER TABLE ONLY public.goodsreceived
    ADD CONSTRAINT goodsreceived_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.user_profiles(id) ON DELETE SET NULL;
ALTER TABLE ONLY public.goodsreceived
    ADD CONSTRAINT goodsreceived_user_profiles_id_fk FOREIGN KEY (supervisor_id) REFERENCES public.user_profiles(id) ON DELETE SET NULL;
ALTER TABLE ONLY public.invoice
    ADD CONSTRAINT invoice_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.user_profiles(id);
ALTER TABLE ONLY public.invoice
    ADD CONSTRAINT invoice_deleted_by_fkey FOREIGN KEY (deleted_by) REFERENCES public.user_profiles(id);
ALTER TABLE ONLY public.item_storage_prices
    ADD CONSTRAINT item_storage_prices_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.user_profiles(id);
ALTER TABLE ONLY public.item_storage_prices
    ADD CONSTRAINT item_storage_prices_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customers(id);
ALTER TABLE ONLY public.item_storage_prices
    ADD CONSTRAINT item_storage_prices_item_id_fkey FOREIGN KEY (item_id) REFERENCES public.items(id);
ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_invoice_id_fkey FOREIGN KEY (invoice_id) REFERENCES public.invoice(id) ON DELETE SET NULL;
ALTER TABLE ONLY public.stock_movements
    ADD CONSTRAINT stock_movements_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.user_profiles(id);
ALTER TABLE ONLY public.stock_movements
    ADD CONSTRAINT stock_movements_gr_trl_id_fkey FOREIGN KEY (gr_trl_id) REFERENCES public.goodsreceived_trl(id);
ALTER TABLE ONLY public.user_session_activity
    ADD CONSTRAINT user_session_activity_auth_session_id_fkey FOREIGN KEY (auth_session_id) REFERENCES auth.sessions(id) ON DELETE CASCADE;
ALTER TABLE ONLY public.user_session_activity
    ADD CONSTRAINT user_session_activity_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.user_profiles(id);
CREATE POLICY "Admins and supervisors can delete customers" ON public.customers FOR DELETE USING (public.is_admin_or_supervisor());
CREATE POLICY "Admins and supervisors can delete dispatch" ON public.dispatch FOR DELETE USING ((public.is_admin_or_supervisor() OR (customer_id = ANY (public.user_accessible_customers()))));
CREATE POLICY "Admins and supervisors can delete invoice" ON public.invoice FOR DELETE USING ((public.is_admin_or_supervisor() OR (customer_id = ANY (public.user_accessible_customers()))));
CREATE POLICY "Admins and supervisors can delete items" ON public.items FOR DELETE USING (public.is_admin_or_supervisor());
CREATE POLICY "Admins and supervisors can insert customers" ON public.customers FOR INSERT WITH CHECK (public.is_admin_or_supervisor());
CREATE POLICY "Admins and supervisors can insert dispatch" ON public.dispatch FOR INSERT WITH CHECK ((public.is_admin_or_supervisor() OR (customer_id = ANY (public.user_accessible_customers()))));
CREATE POLICY "Admins and supervisors can insert invoice" ON public.invoice FOR INSERT WITH CHECK ((public.is_admin_or_supervisor() OR (customer_id = ANY (public.user_accessible_customers()))));
CREATE POLICY "Admins and supervisors can insert items" ON public.items FOR INSERT WITH CHECK (public.is_admin_or_supervisor());
CREATE POLICY "Admins and supervisors can update customers" ON public.customers FOR UPDATE USING ((public.is_admin_or_supervisor() OR (id = ANY (public.user_accessible_customers())))) WITH CHECK ((public.is_admin_or_supervisor() OR (id = ANY (public.user_accessible_customers()))));
CREATE POLICY "Admins and supervisors can update dispatch" ON public.dispatch FOR UPDATE USING ((public.is_admin_or_supervisor() OR (customer_id = ANY (public.user_accessible_customers())))) WITH CHECK ((public.is_admin_or_supervisor() OR (customer_id = ANY (public.user_accessible_customers()))));
CREATE POLICY "Admins and supervisors can update invoice" ON public.invoice FOR UPDATE USING ((public.is_admin_or_supervisor() OR (customer_id = ANY (public.user_accessible_customers())))) WITH CHECK ((public.is_admin_or_supervisor() OR (customer_id = ANY (public.user_accessible_customers()))));
CREATE POLICY "Admins and supervisors can update items" ON public.items FOR UPDATE USING (public.is_admin_or_supervisor()) WITH CHECK (public.is_admin_or_supervisor());
CREATE POLICY "Admins and supervisors can view all print jobs" ON public.print_jobs FOR SELECT USING ((public.get_current_user_role() = ANY (ARRAY['admin'::public.user_role, 'supervisor'::public.user_role])));
CREATE POLICY "Admins can delete goods received" ON public.goodsreceived FOR DELETE USING (public.has_role('admin'::public.user_role));
CREATE POLICY "Admins can manage API configurations" ON public.api_configurations USING (((auth.uid() IS NOT NULL) AND public.is_admin()));
CREATE POLICY "Admins can manage all customers" ON public.customers USING (public.has_role('admin'::public.user_role));
CREATE POLICY "Admins can manage feature flags" ON public.feature_flags USING (((auth.uid() IS NOT NULL) AND public.is_admin()));
CREATE POLICY "Admins can manage system settings" ON public.system_settings USING (((auth.uid() IS NOT NULL) AND public.is_admin()));
CREATE POLICY "Admins can update all print jobs" ON public.print_jobs FOR UPDATE USING (public.is_admin());
CREATE POLICY "Admins can view all auth logs" ON public.auth_logs USING ((public.get_current_user_role() = ANY (ARRAY['admin'::public.user_role, 'supervisor'::public.user_role])));
CREATE POLICY "Admins read SMS config" ON public.sms_config FOR SELECT TO authenticated USING ((public.is_admin_or_supervisor() AND (( SELECT user_profiles.role
   FROM public.user_profiles
  WHERE (user_profiles.auth_user_id = ( SELECT auth.uid() AS uid))) = 'admin'::public.user_role)));
CREATE POLICY "Admins read test OTP records" ON public.test_otp_records FOR SELECT USING ((public.get_current_user_role() = ANY (ARRAY['admin'::public.user_role, 'supervisor'::public.user_role])));
CREATE POLICY "Authenticated users can view items" ON public.items FOR SELECT TO authenticated USING (true);
CREATE POLICY "Users can read printer status" ON public.printer_status FOR SELECT TO anon, authenticated USING (true);
CREATE POLICY "Allow public read" ON public.feature_flags FOR SELECT USING (true);
CREATE POLICY "Allow service role update printer status" ON public.printer_status TO service_role USING (true);
CREATE POLICY "Authenticated users can read active configs" ON public.api_configurations FOR SELECT USING (((is_active = true) AND (( SELECT auth.uid() AS uid) IS NOT NULL)));
CREATE POLICY "Authenticated users can read enabled features" ON public.feature_flags FOR SELECT USING (((enabled = true) AND (( SELECT auth.uid() AS uid) IS NOT NULL)));
CREATE POLICY "Authenticated users can read system settings" ON public.system_settings FOR SELECT USING ((( SELECT auth.uid() AS uid) IS NOT NULL));
CREATE POLICY "Functions delete OTPs" ON public.otp_verifications FOR DELETE TO service_role USING (true);
CREATE POLICY "Functions manage OTPs" ON public.otp_verifications FOR INSERT TO service_role WITH CHECK (true);
CREATE POLICY "Functions update OTPs" ON public.otp_verifications FOR UPDATE TO service_role USING (true);
CREATE POLICY "Service role bypass" ON public.user_profiles TO service_role USING (true) WITH CHECK (true);
CREATE POLICY "Service role can update" ON public.printer_status FOR UPDATE USING ((auth.role() = 'service_role'::text));
CREATE POLICY "Service role full access - api_configurations" ON public.api_configurations USING ((auth.role() = 'service_role'::text));
CREATE POLICY "Service role full access - feature_flags" ON public.feature_flags USING ((auth.role() = 'service_role'::text));
CREATE POLICY "Service role full access - system_settings" ON public.system_settings USING ((auth.role() = 'service_role'::text));
CREATE POLICY "Service role manages SMS config" ON public.sms_config TO service_role USING (true) WITH CHECK (true);
CREATE POLICY "Service role manages rate limits" ON public.otp_rate_limits TO service_role USING (true) WITH CHECK (true);
CREATE POLICY "Service role manages test OTP records" ON public.test_otp_records TO service_role USING (true) WITH CHECK (true);
CREATE POLICY "Service role only JWT config" ON public.jwt_config TO service_role USING (true) WITH CHECK (true);
CREATE POLICY "Stock movements admin/supervisor only" ON public.stock_movements FOR INSERT WITH CHECK ((public.is_admin_or_supervisor() AND (current_setting('app.in_stock_function'::text, true) = 'true'::text)));
CREATE POLICY "Users can insert assigned customer goods" ON public.goodsreceived FOR INSERT WITH CHECK ((public.is_admin_or_supervisor() OR (customer_id = ANY (public.user_accessible_customers()))));
CREATE POLICY "Users can insert their own print jobs" ON public.print_jobs FOR INSERT WITH CHECK ((( SELECT auth.uid() AS uid) = user_id));
CREATE POLICY "Users can update assigned customer goods" ON public.goodsreceived FOR UPDATE USING ((public.is_admin_or_supervisor() OR (customer_id = ANY (public.user_accessible_customers())))) WITH CHECK ((public.is_admin_or_supervisor() OR (customer_id = ANY (public.user_accessible_customers()))));
CREATE POLICY "Users can update own profile" ON public.user_profiles FOR UPDATE TO authenticated USING ((auth_user_id = ( SELECT auth.uid() AS uid))) WITH CHECK ((auth_user_id = ( SELECT auth.uid() AS uid)));
CREATE POLICY "Users can update their own print jobs" ON public.print_jobs FOR UPDATE USING ((( SELECT auth.uid() AS uid) = user_id));
CREATE POLICY "Users can view assigned customer dispatch" ON public.dispatch FOR SELECT USING ((public.is_admin_or_supervisor() OR (customer_id = ANY (public.user_accessible_customers()))));
CREATE POLICY "Users can view assigned customer goods" ON public.goodsreceived FOR SELECT USING ((public.is_admin_or_supervisor() OR (customer_id = ANY (public.user_accessible_customers()))));
CREATE POLICY "Users can view assigned customer invoices" ON public.invoice FOR SELECT USING ((public.is_admin_or_supervisor() OR (customer_id = ANY (public.user_accessible_customers()))));
CREATE POLICY "Users can view assigned customers" ON public.customers FOR SELECT USING (((active = true) AND (public.is_admin_or_supervisor() OR (id = ANY (public.user_accessible_customers())))));
CREATE POLICY "Users can view own profile" ON public.user_profiles FOR SELECT TO authenticated USING ((auth_user_id = ( SELECT auth.uid() AS uid)));
CREATE POLICY "Users can view their own print jobs" ON public.print_jobs FOR SELECT USING ((( SELECT auth.uid() AS uid) = user_id));
CREATE POLICY "Users see own rate limits" ON public.otp_rate_limits FOR SELECT TO authenticated USING (((phone_number)::text = (( SELECT user_profiles.mobile
   FROM public.user_profiles
  WHERE (user_profiles.auth_user_id = ( SELECT auth.uid() AS uid))))::text));
CREATE POLICY admin_supervisor_manage_otp_func ON public.otp_verifications TO authenticated USING (public.is_admin_or_supervisor());
ALTER TABLE public.api_configurations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.auth_logs ENABLE ROW LEVEL SECURITY;
CREATE POLICY admin_supervisor_user_profiles_access ON public.user_profiles FOR SELECT TO authenticated USING (public.is_admin_or_supervisor());
ALTER TABLE public.customers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.dispatch ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.feature_flags ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.goodsreceived ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.invoice ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.item_storage_prices ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.items ENABLE ROW LEVEL SECURITY;
CREATE POLICY jwt_based_goodsreceived_access ON public.goodsreceived TO authenticated USING (((((current_setting('request.jwt.claims'::text, true))::json ->> 'user_role'::text) = ANY (ARRAY['admin'::text, 'supervisor'::text])) OR (customer_id = ANY (public.user_accessible_customers())))) WITH CHECK (((((current_setting('request.jwt.claims'::text, true))::json ->> 'user_role'::text) = ANY (ARRAY['admin'::text, 'supervisor'::text])) OR (customer_id = ANY (public.user_accessible_customers()))));
ALTER TABLE public.jwt_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.otp_rate_limits ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.otp_verifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payments ENABLE ROW LEVEL SECURITY;
CREATE POLICY pricing_admin_supervisor_only ON public.item_storage_prices USING ((public.get_current_user_role() = ANY (ARRAY['admin'::public.user_role, 'supervisor'::public.user_role])));
ALTER TABLE public.print_jobs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.printer_status ENABLE ROW LEVEL SECURITY;
CREATE POLICY role_based_customers_access ON public.customers TO authenticated USING ((((((current_setting('request.jwt.claims'::text, true))::jsonb -> 'user_metadata'::text) ->> 'role'::text) = ANY (ARRAY['admin'::text, 'supervisor'::text])) OR (id = ANY (public.user_accessible_customers())))) WITH CHECK (((((current_setting('request.jwt.claims'::text, true))::jsonb -> 'user_metadata'::text) ->> 'role'::text) = ANY (ARRAY['admin'::text, 'supervisor'::text])));
CREATE POLICY role_based_dispatch_access ON public.dispatch TO authenticated USING (((((current_setting('request.jwt.claims'::text, true))::jsonb ->> 'user_role'::text) = ANY (ARRAY['admin'::text, 'supervisor'::text])) OR (customer_id = ANY (public.user_accessible_customers()))));
CREATE POLICY role_based_goodsreceived_access ON public.goodsreceived TO authenticated USING (((((current_setting('request.jwt.claims'::text, true))::jsonb ->> 'user_role'::text) = ANY (ARRAY['admin'::text, 'supervisor'::text])) OR (customer_id = ANY (public.user_accessible_customers()))));
CREATE POLICY role_based_payments_access ON public.payments TO authenticated USING (((((current_setting('request.jwt.claims'::text, true))::jsonb ->> 'user_role'::text) = ANY (ARRAY['admin'::text, 'supervisor'::text])) OR (customer_id = ANY (public.user_accessible_customers()))));
CREATE POLICY role_based_stock_movements_access ON public.stock_movements USING ((public.get_current_user_role() = ANY (ARRAY['admin'::public.user_role, 'supervisor'::public.user_role])));
ALTER TABLE public.sms_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stock_movements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.system_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.test_otp_records ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_session_activity ENABLE ROW LEVEL SECURITY;
CREATE POLICY users_own_otp_func ON public.otp_verifications FOR SELECT TO authenticated USING (((phone_number)::text = (( SELECT user_profiles.mobile
   FROM public.user_profiles
  WHERE (user_profiles.auth_user_id = ( SELECT auth.uid() AS uid))))::text));

-- ============================================================
-- RPC FUNCTIONS
-- ============================================================

CREATE OR REPLACE FUNCTION public.audit_trigger_func()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
    INSERT INTO public.audit_log (table_name, action, user_id, old_data, new_data)
    VALUES (
        TG_TABLE_NAME,
        TG_OP,
        NULLIF(current_setting('request.jwt.claims', true)::json->>'sub', '')::UUID,
        CASE WHEN TG_OP IN ('UPDATE', 'DELETE') THEN to_jsonb(OLD) ELSE NULL END,
        CASE WHEN TG_OP IN ('INSERT', 'UPDATE') THEN to_jsonb(NEW) ELSE NULL END
    );
    RETURN COALESCE(NEW, OLD);
EXCEPTION
    WHEN OTHERS THEN
        -- Log warning but don't block the operation - audit failure shouldn't stop business operations
        RAISE WARNING 'audit_trigger_func failed for table % operation %: % - %', TG_TABLE_NAME, TG_OP, SQLSTATE, SQLERRM;
        RETURN COALESCE(NEW, OLD);
END;
$function$

CREATE OR REPLACE FUNCTION public.check_otp_rate_limit(p_phone_number character varying)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_phone_formatted VARCHAR(15);
    v_rate_limit RECORD;
    v_hourly_limit INTEGER := 40;
    v_daily_limit INTEGER := 20;
    v_current_hour TIMESTAMP WITH TIME ZONE;
    v_current_day TIMESTAMP WITH TIME ZONE;
BEGIN
    v_phone_formatted := REGEXP_REPLACE(p_phone_number, '[^0-9]', '', 'g');
    IF LENGTH(v_phone_formatted) = 10 THEN
        v_phone_formatted := '91' || v_phone_formatted;
    END IF;
    
    v_current_hour := DATE_TRUNC('hour', NOW());
    v_current_day := DATE_TRUNC('day', NOW());
    
    INSERT INTO public.otp_rate_limits (phone_number)
    VALUES (v_phone_formatted)
    ON CONFLICT (phone_number) DO NOTHING;
    
    SELECT * INTO v_rate_limit FROM public.otp_rate_limits WHERE phone_number = v_phone_formatted;
    
    IF v_rate_limit.last_reset_hour < v_current_hour THEN
        UPDATE public.otp_rate_limits
        SET hourly_count = 0, last_reset_hour = v_current_hour, updated_at = NOW()
        WHERE phone_number = v_phone_formatted;
        v_rate_limit.hourly_count := 0;
    END IF;
    
    IF v_rate_limit.last_reset_day < v_current_day THEN
        UPDATE public.otp_rate_limits
        SET daily_count = 0, last_reset_day = v_current_day, hourly_count = 0,
            last_reset_hour = v_current_hour, updated_at = NOW()
        WHERE phone_number = v_phone_formatted;
        v_rate_limit.daily_count := 0;
        v_rate_limit.hourly_count := 0;
    END IF;
    
    IF v_rate_limit.hourly_count >= v_hourly_limit THEN
        RETURN utils.error_response('OTP_RATE_LIMIT', 'Hourly OTP limit exceeded. Please try again later.',
            jsonb_build_object('hourly_remaining', 0, 'daily_remaining', v_daily_limit - v_rate_limit.daily_count)::text);
    ELSIF v_rate_limit.daily_count >= v_daily_limit THEN
        RETURN utils.error_response('OTP_RATE_LIMIT', 'Daily OTP limit exceeded. Please try again tomorrow.',
            jsonb_build_object('hourly_remaining', 0, 'daily_remaining', 0)::text);
    END IF;
    
    UPDATE public.otp_rate_limits
    SET hourly_count = hourly_count + 1, daily_count = daily_count + 1, updated_at = NOW()
    WHERE phone_number = v_phone_formatted;
    
    RETURN utils.success_response(
        jsonb_build_object(
            'allowed', true,
            'hourly_remaining', v_hourly_limit - v_rate_limit.hourly_count - 1,
            'daily_remaining', v_daily_limit - v_rate_limit.daily_count - 1
        ),
        'Rate limit check passed'
    );
EXCEPTION
    WHEN OTHERS THEN
        RETURN utils.database_error_response('Rate limit check failed', SQLERRM, SQLSTATE);
END;
$function$

CREATE OR REPLACE FUNCTION public.check_session_validity()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_user_id UUID;
    v_last_activity TIMESTAMPTZ;
    v_inactive_duration INTERVAL;
BEGIN
    SELECT id INTO v_user_id 
    FROM user_profiles 
    WHERE auth_user_id = auth.uid();
    
    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('valid', FALSE, 'error', 'Not authenticated');
    END IF;
    
    -- Get last activity
    SELECT last_activity_at INTO v_last_activity
    FROM user_session_activity
    WHERE user_id = v_user_id
    ORDER BY last_activity_at DESC
    LIMIT 1;
    
    IF v_last_activity IS NULL THEN
        -- First activity, session is valid
        RETURN jsonb_build_object('valid', TRUE, 'first_activity', TRUE);
    END IF;
    
    v_inactive_duration := NOW() - v_last_activity;
    
    -- Check 15-minute inactivity timeout
    IF v_inactive_duration > INTERVAL '15 minutes' THEN
        RETURN jsonb_build_object(
            'valid', FALSE,
            'error', 'Session expired due to inactivity',
            'last_activity', v_last_activity,
            'inactive_duration_seconds', EXTRACT(EPOCH FROM v_inactive_duration)::INTEGER,
            'requires_reauth', TRUE
        );
    END IF;
    
    RETURN jsonb_build_object(
        'valid', TRUE,
        'last_activity', v_last_activity,
        'inactive_duration_seconds', EXTRACT(EPOCH FROM v_inactive_duration)::INTEGER,
        'time_until_timeout_seconds', (900 - EXTRACT(EPOCH FROM v_inactive_duration))::INTEGER
    );
END;
$function$

CREATE OR REPLACE FUNCTION public.cleanup_expired_otps()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  DECLARE
      v_deleted_count INTEGER;
  BEGIN
      DELETE FROM public.otp_verifications
      WHERE expires_at < NOW() - INTERVAL '1 hour'  -- Keep for 1 hour after expiry for logging
      OR (verified = TRUE AND verified_at < NOW() - INTERVAL '24 hours'); -- Clean verified OTPs after 24 hours

      GET DIAGNOSTICS v_deleted_count = ROW_COUNT;

      RETURN v_deleted_count;
  END;
  $function$

CREATE OR REPLACE FUNCTION public.create_customer(p_name character varying, p_mobile character varying, p_email character varying DEFAULT NULL::character varying, p_address text DEFAULT NULL::text, p_city character varying DEFAULT NULL::character varying, p_state character varying DEFAULT NULL::character varying, p_pincode character varying DEFAULT NULL::character varying, p_gst_number character varying DEFAULT NULL::character varying, p_pan_number character varying DEFAULT NULL::character varying, p_contact_person character varying DEFAULT NULL::character varying, p_contact_mobile character varying DEFAULT NULL::character varying, p_contact_email character varying DEFAULT NULL::character varying, p_image_urls text[] DEFAULT NULL::text[], p_document_urls text[] DEFAULT NULL::text[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_customer_id UUID;
    v_image_count INTEGER;
    v_document_count INTEGER;
BEGIN
    -- Check permission: Admin/Supervisor only
    IF NOT is_admin_or_supervisor() THEN
        RETURN utils.permission_denied_response('admins and supervisors');
    END IF;

    -- Validate name
    IF p_name IS NULL OR TRIM(p_name) = '' THEN
        RETURN utils.validation_error_response('name', 'Customer name is required');
    END IF;

    -- Validate mobile format (but allow duplicates)
    IF p_mobile IS NULL OR NOT p_mobile ~ '^[0-9]{10,15}$' THEN
        RETURN utils.validation_error_response('mobile', 'Mobile number must be 10-15 digits');
    END IF;

    -- Count images and documents
    v_image_count := COALESCE(array_length(p_image_urls, 1), 0);
    v_document_count := COALESCE(array_length(p_document_urls, 1), 0);

    -- Insert customer with image_urls and document_urls stored directly in the table
    INSERT INTO customers (
        name, mobile, email, address, city, state, pincode, 
        gst, pan, contact_person, contact_mobile, contact_email,
        image_urls, document_urls
    )
    VALUES (
        TRIM(p_name), p_mobile, p_email, p_address, p_city, p_state, p_pincode, 
        p_gst_number, p_pan_number, p_contact_person, p_contact_mobile, p_contact_email,
        p_image_urls, p_document_urls
    )
    RETURNING id INTO v_customer_id;

    RETURN utils.success_response(
        jsonb_build_object(
            'customer_id', v_customer_id, 
            'images_saved', v_image_count,
            'documents_saved', v_document_count
        ),
        'Customer created successfully'
    );

EXCEPTION
    WHEN unique_violation THEN
        RETURN utils.error_response('DUPLICATE_NAME', 'A customer with this name already exists');
    WHEN OTHERS THEN
        RETURN utils.database_error_response('Failed to create customer', SQLERRM, SQLSTATE);
END;
$function$

CREATE OR REPLACE FUNCTION public.create_first_admin(admin_mobile character varying, admin_name character varying, admin_display_name character varying DEFAULT NULL::character varying)
 RETURNS uuid
 LANGUAGE plpgsql
AS $function$
DECLARE
    new_profile_id uuid;
BEGIN
    INSERT INTO user_profiles (
        auth_user_id,
        name,
        display_name,
        mobile,
        role,
        active
    ) VALUES (
        gen_random_uuid(),
        admin_name,
        COALESCE(admin_display_name, admin_name),
        admin_mobile,
        'admin',
        true
    ) RETURNING id INTO new_profile_id;

    RAISE NOTICE 'Created admin user profile with ID: %', new_profile_id;
    RAISE NOTICE 'Mobile: %', admin_mobile;
    RAISE NOTICE 'IMPORTANT: User must log in through Supabase Auth to complete setup';

    RETURN new_profile_id;
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'create_first_admin failed: % - %', SQLSTATE, SQLERRM;
        RETURN NULL;
END;
$function$

CREATE OR REPLACE FUNCTION public.get_customer_stock_summary(p_customer_uuid uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_result JSONB;
    v_user_role TEXT;
BEGIN
    -- Get user role from JWT claims
    v_user_role := COALESCE(
        (current_setting('request.jwt.claims', true)::jsonb ->> 'user_role'),
        (current_setting('request.jwt.claims', true)::jsonb -> 'user_metadata' ->> 'role')
    );

    -- Check access: admin/supervisor can access all, others only assigned customers
    IF v_user_role NOT IN ('admin', 'supervisor', 'service_role') THEN
        IF NOT EXISTS (
            SELECT 1 FROM unnest(user_accessible_customers()) AS uc(id)
            WHERE uc.id = p_customer_uuid
        ) THEN
            RETURN jsonb_build_object(
                'error', 'Access denied: customer not accessible',
                'summary', NULL,
                'items', '[]'::jsonb,
                'out_of_stock_items', '[]'::jsonb
            );
        END IF;
    END IF;

    SELECT jsonb_build_object(
        'summary', (
            SELECT jsonb_build_object(
                'total_items', COUNT(DISTINCT gt.item_id),
                'total_quantity', COALESCE(SUM(gt.stock), 0),
                'total_weight_kg', COALESCE(SUM(gt.weight::numeric * gt.stock), 0),
                'oldest_stock_date', MIN(g.date)::date,
                'grn_count', COUNT(DISTINCT g.id),
                'grn_count_empty', (
                    SELECT COUNT(DISTINCT g2.id)
                    FROM goodsreceived g2
                    WHERE g2.customer_id = p_customer_uuid
                      AND g2.deleted_at IS NULL
                      AND NOT EXISTS (
                          SELECT 1 FROM goodsreceived_trl gt2
                          WHERE gt2.gr_id = g2.id AND gt2.stock > 0
                      )
                ),
                -- Last GRN entry date and number
                'last_grn_date', (
                    SELECT MAX(g3.date)::date 
                    FROM goodsreceived g3 
                    WHERE g3.customer_id = p_customer_uuid 
                      AND g3.deleted_at IS NULL
                ),
                'last_grn_no', (
                    SELECT g3.gr_no 
                    FROM goodsreceived g3 
                    WHERE g3.customer_id = p_customer_uuid 
                      AND g3.deleted_at IS NULL 
                    ORDER BY g3.date DESC, g3.created_at DESC 
                    LIMIT 1
                ),
                -- Last Dispatch entry date and number
                'last_dispatch_date', (
                    SELECT MAX(d.disp_date)::date 
                    FROM dispatch d 
                    WHERE d.customer_id = p_customer_uuid 
                      AND d.deleted_at IS NULL
                ),
                'last_dispatch_no', (
                    SELECT d.disp_no 
                    FROM dispatch d 
                    WHERE d.customer_id = p_customer_uuid 
                      AND d.deleted_at IS NULL 
                    ORDER BY d.disp_date DESC, d.created_at DESC 
                    LIMIT 1
                )
            )
            FROM goodsreceived g
            JOIN goodsreceived_trl gt ON gt.gr_id = g.id
            WHERE g.customer_id = p_customer_uuid
              AND g.deleted_at IS NULL
              AND gt.stock > 0
        ),
        -- Group by item_id and item_name ONLY (not packaging) to avoid duplicates
        'items', COALESCE((
            SELECT jsonb_agg(item_data ORDER BY item_data->>'item_name')
            FROM (
                SELECT jsonb_build_object(
                    'item_id', gt.item_id,
                    'item_name', gt.item_name,
                    'packaging', NULL,  -- Will show individual packaging in GRN details
                    'total_stock', SUM(gt.stock),
                    'total_weight', SUM(gt.weight::numeric * gt.stock),
                    'grn_count', COUNT(DISTINCT g.id),
                    'grns', (
                        SELECT jsonb_agg(
                            jsonb_build_object(
                                'grn_id', g2.id,
                                'gr_no', g2.gr_no,
                                'date', g2.date::date,
                                'orig_qty', gt2.qty,
                                'stock', gt2.stock,
                                'item_weight', gt2.weight,
                                'rack', gt2.rack,
                                'packaging', gt2.packaging,
                                'package_mark', gt2.package_mark
                            ) ORDER BY g2.date DESC
                        )
                        FROM goodsreceived g2
                        JOIN goodsreceived_trl gt2 ON gt2.gr_id = g2.id
                        WHERE g2.customer_id = p_customer_uuid
                          AND g2.deleted_at IS NULL
                          AND gt2.item_id = gt.item_id
                          AND gt2.stock > 0
                    )
                ) AS item_data
                FROM goodsreceived g
                JOIN goodsreceived_trl gt ON gt.gr_id = g.id
                WHERE g.customer_id = p_customer_uuid
                  AND g.deleted_at IS NULL
                  AND gt.stock > 0
                GROUP BY gt.item_id, gt.item_name  -- Removed packaging from GROUP BY
            ) AS items_agg
        ), '[]'::jsonb),
        -- out_of_stock_items - items where stock = 0, emptied within last 360 days
        'out_of_stock_items', COALESCE((
            SELECT jsonb_agg(item_data ORDER BY item_data->>'item_name')
            FROM (
                SELECT jsonb_build_object(
                    'item_id', gt.item_id,
                    'item_name', gt.item_name,
                    'packaging', NULL,
                    'grn_count', COUNT(DISTINCT g.id),
                    'grns', (
                        SELECT jsonb_agg(
                            jsonb_build_object(
                                'grn_id', g2.id,
                                'gr_no', g2.gr_no,
                                'date', g2.date::date,
                                'orig_qty', gt2.qty,
                                'stock', gt2.stock,
                                'item_weight', gt2.weight,
                                'rack', gt2.rack,
                                'packaging', gt2.packaging,
                                'package_mark', gt2.package_mark,
                                'emptied_date', (
                                    SELECT MAX(sm.created_at)::date
                                    FROM stock_movements sm
                                    WHERE sm.gr_trl_id = gt2.id
                                      AND sm.balance_after = 0
                                )
                            ) ORDER BY (
                                SELECT MAX(sm.created_at)
                                FROM stock_movements sm
                                WHERE sm.gr_trl_id = gt2.id
                                  AND sm.balance_after = 0
                            ) DESC NULLS LAST
                        )
                        FROM goodsreceived g2
                        JOIN goodsreceived_trl gt2 ON gt2.gr_id = g2.id
                        WHERE g2.customer_id = p_customer_uuid
                          AND g2.deleted_at IS NULL
                          AND gt2.item_id = gt.item_id
                          AND gt2.stock = 0
                          AND gt2.qty > 0
                          -- 360-day filter via stock_movements
                          AND EXISTS (
                              SELECT 1 FROM stock_movements sm
                              WHERE sm.gr_trl_id = gt2.id
                                AND sm.balance_after = 0
                                AND sm.created_at >= NOW() - INTERVAL '360 days'
                          )
                    )
                ) AS item_data
                FROM goodsreceived g
                JOIN goodsreceived_trl gt ON gt.gr_id = g.id
                WHERE g.customer_id = p_customer_uuid
                  AND g.deleted_at IS NULL
                  AND gt.stock = 0
                  AND gt.qty > 0
                  -- 360-day filter
                  AND EXISTS (
                      SELECT 1 FROM stock_movements sm
                      WHERE sm.gr_trl_id = gt.id
                        AND sm.balance_after = 0
                        AND sm.created_at >= NOW() - INTERVAL '360 days'
                  )
                GROUP BY gt.item_id, gt.item_name  -- Removed packaging from GROUP BY
            ) AS items_agg
        ), '[]'::jsonb)
    ) INTO v_result;

    RETURN v_result;
END;
$function$

CREATE OR REPLACE FUNCTION public.get_dispatch_details(p_dispatch_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
    DECLARE
        v_user_id uuid;
        v_role text;
        v_result jsonb;
    BEGIN
        v_user_id := auth.uid();
        
        SELECT role INTO v_role
        FROM user_profiles
        WHERE auth_user_id = v_user_id;
        
        SELECT jsonb_build_object(
            'success', true,
            'data', jsonb_build_object(
                'dispatch', jsonb_build_object(
                    'id', d.id,
                    'disp_no', d.disp_no,
                    'disp_date', d.disp_date,
                    'registration', d.registration,
                    'note', d.note,
                    'disp_image_url', d.disp_image_url,
                    'source_order_id', d.source_order_id,
                    'source_order_no', d.source_order_no,
                    'created_at', d.created_at,
                    'updated_at', d.updated_at,
                    
                    'images', COALESCE(
                        (
                            SELECT jsonb_agg(
                                jsonb_build_object(
                                    'id', di.id,
                                    'storage_path', di.storage_path,
                                    'original_filename', di.original_filename,
                                    'file_size', di.file_size,
                                    'mime_type', di.mime_type,
                                    'display_order', di.display_order,
                                    'created_at', di.created_at
                                )
                                ORDER BY di.display_order, di.created_at
                            )
                            FROM dispatch_images di
                            WHERE di.dispatch_id = d.id
                            AND di.status = 'confirmed'
                        ),
                        '[]'::jsonb
                    ),
                    
                    'customer_details', CASE
                        WHEN c.id IS NOT NULL THEN jsonb_build_object(
                            'id', c.id,
                            'name', c.name,
                            'first_name', c."firstName",
                            'last_name', c."lastName",
                            'gst', c.gst,
                            'mobile', c.mobile,
                            'address', c.address,
                            'city', c.city,
                            'state', c.state,
                            'pincode', c.pincode,
                            'email', c.email,
                            'active', c.active,
                            'auto_invoice_generation', c.auto_invoice_generation
                        )
                        ELSE null
                    END,
                    
                    'supervisor_details', CASE
                        WHEN u.id IS NOT NULL THEN jsonb_build_object(
                            'id', u.id,
                            'name', u.name,
                            'mobile', u.mobile,
                            'role', u.role,
                            'display_name', u.display_name
                        )
                        ELSE null
                    END,
                    
                    'items', COALESCE(
                        (
                            SELECT jsonb_agg(
                                jsonb_build_object(
                                    'id', dt.id,
                                    'disp_qty', dt.disp_qty,
                                    'grn_id', dt.gr_id,
                                    'grn_item_id', dt.gr_trl_id,
                                    
                                    'grn_item_details', CASE
                                        WHEN grt.id IS NOT NULL THEN jsonb_build_object(
                                            'id', grt.id,
                                            'qty', grt.qty,
                                            'stock', grt.stock,
                                            'weight', grt.weight,
                                            'rack', grt.rack,
                                            'package_mark', grt.package_mark,
                                            'item_name', grt.item_name,
                                            'packaging', grt.packaging,
                                            'pricing_mode', gr.pricing_mode,
                                            'trl_img_url', grt.trl_img_url
                                        )
                                        ELSE null
                                    END,
                                    
                                    'grn_details', CASE
                                        WHEN gr.id IS NOT NULL THEN jsonb_build_object(
                                            'id', gr.id,
                                            'gr_no', gr.gr_no,
                                            'date', gr.date,
                                            'registration', gr.registration,
                                            'customer_name', gr.customer_name,
                                            'supervisor_name', gr.supervisor_name,
                                            'sender_name', gr.sender_name,
                                            'invoiced', gr.invoiced,
                                            'out_of_stock', gr.out_of_stock
                                        )
                                        ELSE null
                                    END,
                                    
                                    'item_details', CASE
                                        WHEN i.id IS NOT NULL THEN jsonb_build_object(
                                            'id', i.id,
                                            'name', i.name,
                                            'packaging', i.packaging,
                                            'description', i.description,
                                            'active', i.active
                                        )
                                        ELSE null
                                    END,
                                    
                                    'invoice_details', CASE
                                        WHEN it.id IS NOT NULL THEN jsonb_build_object(
                                            'invoice_trl_id', it.id,
                                            'invoice_id', it.invoice_id,
                                            'duration', it.duration,
                                            'no_of_days', it.no_of_days,
                                            'charge', it.charge,
                                            'tax', it.tax,
                                            'labour_rate', it.labour_rate,
                                            'invoice_no', inv.inv_no,
                                            'invoice_date', inv.inv_date,
                                            'total', inv.total
                                        )
                                        ELSE null
                                    END
                                )
                                ORDER BY dt.id
                            )
                            FROM dispatch_trl dt
                            LEFT JOIN goodsreceived_trl grt ON dt.gr_trl_id = grt.id
                            LEFT JOIN goodsreceived gr ON dt.gr_id = gr.id
                            LEFT JOIN items i ON grt.item_id = i.id
                            LEFT JOIN invoice_trl it ON dt.id = it.disp_trl_id
                            LEFT JOIN invoice inv ON it.invoice_id = inv.id
                            WHERE dt.disp_id = d.id
                        ),
                        '[]'::jsonb
                    ),
                    
                    'statistics', (
                        SELECT jsonb_build_object(
                            'total_items', COUNT(DISTINCT dt.gr_trl_id),
                            'total_dispatched_qty', COALESCE(SUM(dt.disp_qty), 0),
                            'unique_grns', COUNT(DISTINCT dt.gr_id),
                            'total_invoiced_items', COUNT(DISTINCT it.id),
                            'total_invoice_amount', COALESCE(SUM(it.charge * it.duration), 0),
                            'avg_duration', COALESCE(AVG(it.duration), 0),
                            'avg_no_of_days', COALESCE(AVG(it.no_of_days), 0)
                        )
                        FROM dispatch_trl dt
                        LEFT JOIN invoice_trl it ON dt.id = it.disp_trl_id
                        WHERE dt.disp_id = d.id
                    ),
                    
                    'grns_summary', (
                        SELECT jsonb_build_object(
                            'total_grns', COUNT(DISTINCT gr.id),
                            'grn_numbers', COALESCE(
                                jsonb_agg(
                                    DISTINCT gr.gr_no
                                    ORDER BY gr.gr_no
                                ) FILTER (WHERE gr.gr_no IS NOT NULL),
                                '[]'::jsonb
                            )
                        )
                        FROM dispatch_trl dt
                        JOIN goodsreceived gr ON dt.gr_id = gr.id
                        WHERE dt.disp_id = d.id
                    ),
                    
                    'invoices_summary', (
                        SELECT jsonb_build_object(
                            'total_invoices', COUNT(DISTINCT inv.id),
                            'total_amount', COALESCE(SUM(inv.total), 0),
                            'invoice_numbers', COALESCE(
                                jsonb_agg(
                                    DISTINCT inv.inv_no
                                    ORDER BY inv.inv_no
                                ) FILTER (WHERE inv.inv_no IS NOT NULL),
                                '[]'::jsonb
                            )
                        )
                        FROM dispatch_trl dt
                        JOIN invoice_trl it ON dt.id = it.disp_trl_id
                        JOIN invoice inv ON it.invoice_id = inv.id
                        WHERE dt.disp_id = d.id
                    )
                )
            ),
            'message', 'Dispatch details retrieved successfully'
        ) INTO v_result
        FROM dispatch d
        LEFT JOIN customers c ON d.customer_id = c.id
        LEFT JOIN user_profiles u ON d.supervisor_id = u.id
        WHERE d.id = p_dispatch_id
        AND (
            v_role IN ('admin', 'supervisor') OR
            d.customer_id IN (
                SELECT customer_id FROM users_customers_new
                WHERE user_profile_id = (SELECT id FROM user_profiles WHERE auth_user_id = v_user_id)
            )
        );
        
        IF v_result IS NULL THEN
            RETURN jsonb_build_object(
                'success', false,
                'data', null,
                'message', 'Dispatch not found or access denied'
            );
        END IF;
        
        RETURN v_result;
        
    EXCEPTION
        WHEN OTHERS THEN
            RETURN jsonb_build_object(
                'success', false,
                'data', null,
                'message', 'Error retrieving dispatch details: ' || SQLERRM
            );
    END;
    $function$

CREATE OR REPLACE FUNCTION public.get_grn_details(p_grn_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
    DECLARE
        v_user_id uuid;
        v_role text;
        v_result jsonb;
    BEGIN
        v_user_id := auth.uid();
        
        SELECT role INTO v_role
        FROM user_profiles
        WHERE auth_user_id = v_user_id;
        
        SELECT jsonb_build_object(
            'success', true,
            'data', jsonb_build_object(
                'grn', jsonb_build_object(
                    'id', gr.id,
                    'gr_no', gr.gr_no,
                    'date', gr.date,
                    'registration', gr.registration,
                    'note', gr.note,
                    'gr_image_url', gr.gr_image_url,
                    'invoiced', COALESCE(gr.invoiced, false),
                    'leon', COALESCE(gr.leon, false),
                    'out_of_stock', COALESCE(gr.out_of_stock, false),
                    'pricing_mode', gr.pricing_mode,
                    'created_at', gr.created_at,
                    'updated_at', gr.updated_at,
                    
                    'header_images', COALESCE(
                        (
                            SELECT jsonb_agg(
                                jsonb_build_object(
                                    'id', gi.id,
                                    'storage_path', gi.storage_path,
                                    'image_url', gi.storage_path,
                                    'original_filename', gi.original_filename,
                                    'file_size', gi.file_size,
                                    'mime_type', gi.mime_type,
                                    'display_order', gi.display_order,
                                    'uploaded_by', gi.uploaded_by,
                                    'created_at', gi.created_at
                                )
                                ORDER BY gi.display_order, gi.created_at
                            )
                            FROM grn_images gi
                            WHERE gi.grn_id = gr.id
                            AND gi.image_type = 'header'
                        ),
                        '[]'::jsonb
                    ),
                    
                    'customer_details', CASE
                        WHEN c.id IS NOT NULL THEN jsonb_build_object(
                            'id', c.id,
                            'name', c.name,
                            'first_name', c."firstName",
                            'last_name', c."lastName",
                            'gst', c.gst,
                            'mobile', c.mobile,
                            'address', c.address,
                            'city', c.city,
                            'state', c.state,
                            'pincode', c.pincode,
                            'email', c.email,
                            'active', c.active,
                            'auto_invoice_generation', c.auto_invoice_generation
                        )
                        ELSE null
                    END,
                    
                    'supervisor_details', CASE
                        WHEN u.id IS NOT NULL THEN jsonb_build_object(
                            'id', u.id,
                            'name', u.name,
                            'mobile', u.mobile,
                            'role', u.role,
                            'display_name', u.display_name
                        )
                        ELSE null
                    END,
                    
                    'sender_details', jsonb_build_object(
                        'id', gr.sender_id,
                        'name', gr.sender_name
                    ),
                    
                    'items', COALESCE(
                        (
                            SELECT jsonb_agg(
                                jsonb_build_object(
                                    'id', grt.id,
                                    'qty', grt.qty,
                                    'stock', grt.stock,
                                    'weight', grt.weight,
                                    'rack', grt.rack,
                                    'package_mark', grt.package_mark,
                                    'item_name', grt.item_name,
                                    'packaging', grt.packaging,
                                    'pricing_mode', gr.pricing_mode,
                                    'trl_img_url', grt.trl_img_url,
                                    'item_images', COALESCE(
                                        (
                                            SELECT jsonb_agg(
                                                jsonb_build_object(
                                                    'id', gi2.id,
                                                    'storage_path', gi2.storage_path,
                                                    'image_url', gi2.storage_path,
                                                    'original_filename', gi2.original_filename,
                                                    'file_size', gi2.file_size,
                                                    'mime_type', gi2.mime_type,
                                                    'display_order', gi2.display_order,
                                                    'uploaded_by', gi2.uploaded_by,
                                                    'created_at', gi2.created_at
                                                )
                                                ORDER BY gi2.display_order, gi2.created_at
                                            )
                                            FROM grn_images gi2
                                            WHERE gi2.grn_id = gr.id
                                            AND gi2.grn_item_id = grt.id
                                            AND gi2.image_type = 'item'
                                        ),
                                        '[]'::jsonb
                                    ),
                                    'item_details', CASE
                                        WHEN i.id IS NOT NULL THEN jsonb_build_object(
                                            'id', i.id,
                                            'name', i.name,
                                            'packaging', i.packaging,
                                            'description', i.description,
                                            'active', i.active
                                        )
                                        ELSE null
                                    END
                                )
                                ORDER BY grt.id
                            )
                            FROM goodsreceived_trl grt
                            LEFT JOIN items i ON grt.item_id = i.id
                            WHERE grt.gr_id = gr.id
                        ),
                        '[]'::jsonb
                    ),
                    
                    'statistics', (
                        SELECT jsonb_build_object(
                            'total_items', COUNT(DISTINCT grt.item_id),
                            'total_qty', COALESCE(SUM(grt.qty), 0),
                            'total_stock', COALESCE(SUM(grt.stock), 0),
                            'total_weight', COALESCE(SUM(grt.weight), 0),
                            'total_dispatched', COALESCE(
                                (
                                    SELECT SUM(dt.disp_qty)
                                    FROM dispatch_trl dt
                                    WHERE dt.gr_trl_id IN (
                                        SELECT id FROM goodsreceived_trl
                                        WHERE gr_id = gr.id
                                    )
                                ), 0
                            ),
                            'has_out_of_stock', EXISTS(
                                SELECT 1 FROM goodsreceived_trl
                                WHERE gr_id = gr.id AND stock <= 0
                            )
                        )
                        FROM goodsreceived_trl grt
                        WHERE grt.gr_id = gr.id
                    ),
                    
                    'invoices_summary', (
                        SELECT jsonb_build_object(
                            'total_invoices', COUNT(DISTINCT inv.id),
                            'total_amount', COALESCE(SUM(inv.total), 0),
                            'invoice_numbers', COALESCE(
                                jsonb_agg(
                                    DISTINCT inv.inv_no
                                    ORDER BY inv.inv_no
                                ) FILTER (WHERE inv.inv_no IS NOT NULL),
                                '[]'::jsonb
                            )
                        )
                        FROM invoice inv
                        WHERE inv.gr_id = gr.id
                    ),
                    
                    'dispatches_summary', (
                        SELECT jsonb_build_object(
                            'total_dispatches', COUNT(DISTINCT d.id),
                            'dispatch_numbers', COALESCE(
                                jsonb_agg(
                                    DISTINCT d.disp_no
                                    ORDER BY d.disp_no
                                ) FILTER (WHERE d.disp_no IS NOT NULL),
                                '[]'::jsonb
                            )
                        )
                        FROM dispatch d
                        WHERE EXISTS (
                            SELECT 1
                            FROM dispatch_trl dt
                            JOIN goodsreceived_trl grt ON dt.gr_trl_id = grt.id
                            WHERE grt.gr_id = gr.id
                            AND dt.disp_id = d.id
                        )
                    )
                )
            ),
            'message', 'GRN details retrieved successfully'
        ) INTO v_result
        FROM goodsreceived gr
        LEFT JOIN customers c ON gr.customer_id = c.id
        LEFT JOIN user_profiles u ON gr.supervisor_id = u.id
        WHERE gr.id = p_grn_id
        AND (
            v_role IN ('admin', 'supervisor') OR
            gr.customer_id IN (
                SELECT customer_id FROM users_customers_new
                WHERE user_profile_id = (SELECT id FROM user_profiles WHERE auth_user_id = v_user_id)
            )
        );
        
        IF v_result IS NULL THEN
            RETURN jsonb_build_object(
                'success', false,
                'data', null,
                'message', 'GRN not found or access denied'
            );
        END IF;
        
        RETURN v_result;
        
    EXCEPTION
        WHEN OTHERS THEN
            RETURN jsonb_build_object(
                'success', false,
                'data', null,
                'message', 'Error retrieving GRN details: ' || SQLERRM
            );
    END;
    $function$

CREATE OR REPLACE FUNCTION public.get_invoice_details(p_inv_no integer, p_fin_year integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_user_id uuid;
    v_role text;
    v_result jsonb;
    v_target_fin_year INTEGER;
BEGIN
    v_user_id := auth.uid();

    SELECT role INTO v_role
    FROM user_profiles
    WHERE auth_user_id = v_user_id;

    -- Default to current financial year if not specified
    v_target_fin_year := COALESCE(p_fin_year, EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER);

    SELECT jsonb_build_object(
        'success', true,
        'data', jsonb_build_object(
            'invoice', jsonb_build_object(
                'id', i.id,
                'inv_no', i.inv_no,
                'inv_no_str', 'INV' || LPAD(i.inv_no::TEXT, 3, '0'),
                'inv_fin_year', i.inv_fin_year,
                'inv_date', i.inv_date,
                'inv_name', i.inv_name,
                'gr_id', i.gr_id,
                'gr_no', i.gr_no,
                'pricing_mode', i.pricing_mode,
                'one_time_charge', COALESCE(i.one_time_charge, false),
                'labour', COALESCE(i.labour, 0),
                'discount', COALESCE(i.discount, 0),
                'tax_amount', COALESCE(i.tax_amount, 0),
                'total', COALESCE(i.total, 0),
                'notes', i.notes,
                'is_auto_generated', COALESCE(i.is_auto_generated, false),
                'created_at', i.created_at,
                'updated_at', i.updated_at,

                -- Customer details
                'customer_details', CASE
                    WHEN c.id IS NOT NULL THEN jsonb_build_object(
                        'id', c.id,
                        'name', c.name,
                        'first_name', c."firstName",
                        'last_name', c."lastName",
                        'gst', c.gst,
                        'mobile', c.mobile,
                        'address', c.address,
                        'city', c.city,
                        'state', c.state,
                        'pincode', c.pincode,
                        'email', c.email,
                        'active', c.active
                    )
                    ELSE null
                END,

                -- Invoice line items with full details
                'items', COALESCE(
                    (
                        SELECT jsonb_agg(
                            jsonb_build_object(
                                'id', it.id,
                                'duration', COALESCE(it.duration, 0),
                                'no_of_days', COALESCE(it.no_of_days, 0),
                                'charge', COALESCE(it.charge, 0),
                                'tax', COALESCE(it.tax, 0),
                                'labour_rate', COALESCE(it.labour_rate, 0),
                                'item_total', COALESCE(it.charge * it.duration, 0),
                                'labour_amount', COALESCE(it.labour_rate * grt.weight, 0),

                                -- Dispatch details
                                'dispatch_details', CASE
                                    WHEN dt.id IS NOT NULL THEN jsonb_build_object(
                                        'disp_trl_id', dt.id,
                                        'disp_id', dt.disp_id,
                                        'disp_qty', COALESCE(dt.disp_qty, 0),
                                        'disp_no', d.disp_no,
                                        'disp_date', d.disp_date
                                    )
                                    ELSE null
                                END,

                                -- GRN Item details
                                'grn_item_details', CASE
                                    WHEN grt.id IS NOT NULL THEN jsonb_build_object(
                                        'id', grt.id,
                                        'item_name', grt.item_name,
                                        'packaging', grt.packaging,
                                        'qty', grt.qty,
                                        'stock', grt.stock,
                                        'weight', grt.weight,
                                        'rack', grt.rack,
                                        'package_mark', grt.package_mark
                                    )
                                    ELSE null
                                END,

                                -- GRN header details
                                'grn_details', CASE
                                    WHEN gr.id IS NOT NULL THEN jsonb_build_object(
                                        'gr_no', gr.gr_no,
                                        'date', gr.date,
                                        'customer_name', gr.customer_name
                                    )
                                    ELSE null
                                END
                            )
                            ORDER BY grt.item_name, it.id
                        )
                        FROM invoice_trl it
                        LEFT JOIN dispatch_trl dt ON it.disp_trl_id = dt.id
                        LEFT JOIN dispatch d ON dt.disp_id = d.id
                        LEFT JOIN goodsreceived_trl grt ON dt.gr_trl_id = grt.id
                        LEFT JOIN goodsreceived gr ON dt.gr_id = gr.id
                        WHERE it.invoice_id = i.id
                    ),
                    '[]'::jsonb
                ),

                -- Statistics
                'statistics', (
                    SELECT jsonb_build_object(
                        'total_items', COUNT(DISTINCT it.id),
                        'total_disp_qty', COALESCE(SUM(dt.disp_qty), 0),
                        'total_grn_qty', COALESCE(SUM(grt.qty), 0),
                        'total_weight', COALESCE(SUM(grt.weight), 0),
                        'total_item_charges', COALESCE(SUM(it.charge * it.duration), 0),
                        'total_labour_amount', COALESCE(SUM(it.labour_rate * grt.weight), 0),
                        'avg_duration', ROUND(COALESCE(AVG(it.duration), 0)::numeric, 2),
                        'avg_no_of_days', ROUND(COALESCE(AVG(it.no_of_days), 0)::numeric, 0)
                    )
                    FROM invoice_trl it
                    LEFT JOIN dispatch_trl dt ON it.disp_trl_id = dt.id
                    LEFT JOIN goodsreceived_trl grt ON dt.gr_trl_id = grt.id
                    WHERE it.invoice_id = i.id
                ),

                -- Amount in words
                'amount_in_words', (
                    SELECT
                        'Rupees ' ||
                        CASE
                            WHEN floor(COALESCE(i.total, 0)) >= 10000000 THEN
                                (SELECT convert_number_to_words(floor(floor(COALESCE(i.total, 0)) / 10000000)::integer)) || ' Crore '
                            ELSE ''
                        END ||
                        CASE
                            WHEN floor(COALESCE(i.total, 0)) % 10000000 >= 100000 THEN
                                (SELECT convert_number_to_words(floor((floor(COALESCE(i.total, 0)) % 10000000) / 100000)::integer)) || ' Lakh '
                            ELSE ''
                        END ||
                        CASE
                            WHEN floor(COALESCE(i.total, 0)) % 100000 >= 1000 THEN
                                (SELECT convert_number_to_words(floor((floor(COALESCE(i.total, 0)) % 100000) / 1000)::integer)) || ' Thousand '
                            ELSE ''
                        END ||
                        CASE
                            WHEN floor(COALESCE(i.total, 0)) % 1000 > 0 THEN
                                (SELECT convert_number_to_words(floor(floor(COALESCE(i.total, 0)) % 1000)::integer))
                            WHEN floor(COALESCE(i.total, 0)) = 0 THEN 'Zero'
                            ELSE ''
                        END ||
                        ' Only'
                )
            )
        ),
        'message', 'Invoice details retrieved successfully'
    ) INTO v_result
    FROM invoice i
    LEFT JOIN customers c ON i.customer_id = c.id
    WHERE i.inv_no = p_inv_no
    AND i.inv_fin_year = v_target_fin_year
    AND (
        v_role IN ('admin', 'supervisor') OR
        i.customer_id IN (
            SELECT customer_id FROM users_customers_new
            WHERE user_profile_id = (SELECT id FROM user_profiles WHERE auth_user_id = v_user_id)
        )
    );

    IF v_result IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'data', null,
            'message', 'Invoice not found or access denied'
        );
    END IF;

    RETURN v_result;

EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'data', null,
            'message', 'Error retrieving invoice: ' || SQLERRM
        );
END;
$function$

CREATE OR REPLACE FUNCTION public.send_otp(p_phone_number character varying, p_purpose character varying DEFAULT 'login'::character varying, p_user_agent text DEFAULT NULL::text, p_ip_address inet DEFAULT NULL::inet, p_captcha_token text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
    v_otp_code VARCHAR(6);
    v_otp_hash TEXT;
    v_request_id TEXT;
    v_expires_at TIMESTAMP WITH TIME ZONE;
    v_phone_formatted VARCHAR(15);
    v_production_mode BOOLEAN;
    v_provider VARCHAR(20);
    v_account_sid TEXT;
    v_auth_token TEXT;
    v_from_phone TEXT;
    v_twilio_url TEXT;
    v_twilio_message_sid TEXT;
    v_msg91_auth_key TEXT;
    v_msg91_template_id TEXT;
    v_msg91_sender_id TEXT;
    v_msg91_pe_id TEXT;
    v_msg91_url TEXT;
    v_http_response http_response;
    v_response_body JSONB;
    v_request_headers http_header[];
    v_request_body TEXT;
    v_rate_check jsonb;
    v_ip_check jsonb;
    v_captcha_check JSONB;
    v_test_otp VARCHAR(6);
BEGIN
    -- Format phone number
    v_phone_formatted := REGEXP_REPLACE(p_phone_number, '[^0-9]', '', 'g');
    IF LENGTH(v_phone_formatted) <> 10 AND NOT (LENGTH(v_phone_formatted) = 12 AND LEFT(v_phone_formatted, 2) = '91') THEN
        RETURN utils.validation_error_response('phone_number', 'Invalid phone number format');
    END IF;
    IF LENGTH(v_phone_formatted) = 10 THEN
        v_phone_formatted := '91' || v_phone_formatted;
    END IF;
    
    -- Verify captcha
    v_captcha_check := verify_captcha(p_captcha_token);
    IF NOT (v_captcha_check->>'success')::boolean THEN
        RETURN utils.error_response('CAPTCHA_FAILED', v_captcha_check->>'message');
    END IF;
    
    -- Check IP rate limit
    v_ip_check := check_ip_rate_limit(p_ip_address);
    IF NOT (v_ip_check->>'success')::boolean THEN
        RETURN v_ip_check;
    END IF;
    
    -- Check OTP rate limit
    v_rate_check := check_otp_rate_limit(v_phone_formatted);
    IF NOT (v_rate_check->>'success')::boolean THEN
        RETURN v_rate_check;
    END IF;
    
    -- Get SMS config
    SELECT provider, production_mode, account_sid, auth_token, from_phone,
           msg91_auth_key, msg91_template_id, msg91_sender_id, msg91_pe_id
    INTO v_provider, v_production_mode, v_account_sid, v_auth_token, v_from_phone,
         v_msg91_auth_key, v_msg91_template_id, v_msg91_sender_id, v_msg91_pe_id
    FROM public.sms_config ORDER BY id DESC LIMIT 1;
    
    v_provider := COALESCE(v_provider, 'twilio');
    v_expires_at := NOW() + INTERVAL '5 minutes';
    v_request_id := 'OTP_' || EXTRACT(EPOCH FROM NOW())::BIGINT || '_' || FLOOR(RANDOM() * 10000)::TEXT;
    
    -- Invalidate previous OTPs
    UPDATE public.otp_verifications SET verified = TRUE, verified_at = NOW()
    WHERE phone_number = v_phone_formatted AND purpose = p_purpose AND verified = FALSE AND expires_at > NOW();
    
    -- CHECK TEST OTP RECORDS (works in both test and production mode for specific phone numbers)
    SELECT fixed_otp INTO v_test_otp
    FROM public.test_otp_records
    WHERE phone_number = v_phone_formatted;
    
    IF v_test_otp IS NOT NULL THEN
        v_otp_code := v_test_otp;
        v_otp_hash := encode(digest(v_test_otp, 'sha256'), 'hex');
        INSERT INTO public.otp_verifications (phone_number, otp_code, otp_code_hash, msg91_request_id, purpose, expires_at, user_agent, ip_address, msg91_status, delivery_status)
        VALUES (v_phone_formatted, NULL, v_otp_hash, v_request_id, p_purpose, v_expires_at, p_user_agent, p_ip_address, 'test_phone', 'test_phone');
        
        RETURN utils.success_response(
            jsonb_build_object('request_id', v_request_id, 'expires_at', v_expires_at),
            'OTP sent successfully (test phone)'
        );
    END IF;
    
    -- TEST MODE (when production_mode is false)
    IF NOT v_production_mode THEN
        v_otp_code := '123456';
        v_otp_hash := encode(digest('123456', 'sha256'), 'hex');
        INSERT INTO public.otp_verifications (phone_number, otp_code, otp_code_hash, msg91_request_id, purpose, expires_at, user_agent, ip_address, msg91_status, delivery_status)
        VALUES (v_phone_formatted, NULL, v_otp_hash, v_request_id, p_purpose, v_expires_at, p_user_agent, p_ip_address, 'test_mode', 'test_mode');
        
        RETURN utils.success_response(
            jsonb_build_object('request_id', v_request_id, 'expires_at', v_expires_at),
            'OTP sent successfully (test mode)'
        );
    END IF;
    
    -- PRODUCTION MODE
    CASE v_provider
    WHEN 'twilio' THEN
        IF v_account_sid IS NULL OR v_auth_token IS NULL OR v_from_phone IS NULL THEN
            v_otp_code := '123456';
            v_otp_hash := encode(digest('123456', 'sha256'), 'hex');
            INSERT INTO public.otp_verifications (phone_number, otp_code, otp_code_hash, msg91_request_id, purpose, expires_at, user_agent, ip_address, msg91_status, delivery_status)
            VALUES (v_phone_formatted, NULL, v_otp_hash, v_request_id, p_purpose, v_expires_at, p_user_agent, p_ip_address, 'config_missing', 'test_mode');
            
            RETURN utils.success_response(
                jsonb_build_object('request_id', v_request_id, 'expires_at', v_expires_at),
                'OTP sent (test mode - Twilio config missing)'
            );
        END IF;
        
        v_otp_code := generate_secure_otp();
        v_otp_hash := encode(digest(v_otp_code, 'sha256'), 'hex');
        
        BEGIN
            v_twilio_url := 'https://' || v_account_sid || ':' || v_auth_token || '@api.twilio.com/2010-04-01/Accounts/' || v_account_sid || '/Messages.json';
            v_request_headers := ARRAY[]::http_header[];
            v_request_body := 'To=' || replace('+' || v_phone_formatted, '+', '%2B') || '&From=' || replace(v_from_phone, '+', '%2B') || '&Body=Your%20OTP%20code%20is%3A%20' || v_otp_code || '.%20Valid%20for%2010%20minutes.';
            v_http_response := http(('POST', v_twilio_url, v_request_headers, 'application/x-www-form-urlencoded', v_request_body)::http_request);
            
            IF v_http_response.content IS NOT NULL AND v_http_response.content != '' THEN
                IF v_http_response.content LIKE '{%' THEN
                    v_response_body := v_http_response.content::JSONB;
                    v_twilio_message_sid := v_response_body->>'sid';
                ELSIF v_http_response.content LIKE '<%' THEN
                    IF v_http_response.content LIKE '%<Sid>%' THEN
                        v_twilio_message_sid := substring(v_http_response.content from '<Sid>(.*?)</Sid>');
                    END IF;
                END IF;
            END IF;
        EXCEPTION WHEN OTHERS THEN
            v_twilio_message_sid := NULL;
        END;
        
        INSERT INTO public.otp_verifications (phone_number, otp_code, otp_code_hash, msg91_request_id, purpose, expires_at, user_agent, ip_address, msg91_status, delivery_status)
        VALUES (v_phone_formatted, NULL, v_otp_hash, COALESCE(v_twilio_message_sid, v_request_id), p_purpose, v_expires_at, p_user_agent, p_ip_address, 'twilio_sent', 'pending');
        
    WHEN 'msg91' THEN
        IF v_msg91_auth_key IS NULL OR v_msg91_template_id IS NULL THEN
            v_otp_code := '123456';
            v_otp_hash := encode(digest('123456', 'sha256'), 'hex');
            INSERT INTO public.otp_verifications (phone_number, otp_code, otp_code_hash, msg91_request_id, purpose, expires_at, user_agent, ip_address, msg91_status, delivery_status)
            VALUES (v_phone_formatted, NULL, v_otp_hash, v_request_id, p_purpose, v_expires_at, p_user_agent, p_ip_address, 'config_missing', 'test_mode');
            
            RETURN utils.success_response(
                jsonb_build_object('request_id', v_request_id, 'expires_at', v_expires_at),
                'OTP sent (test mode - MSG91 config missing)'
            );
        END IF;
        
        v_otp_code := generate_secure_otp();
        v_otp_hash := encode(digest(v_otp_code, 'sha256'), 'hex');
        
        BEGIN
            v_msg91_url := 'https://control.msg91.com/api/v5/flow/';
            v_request_headers := ARRAY[http_header('authkey', v_msg91_auth_key), http_header('Content-Type', 'application/json')]::http_header[];
            v_request_body := jsonb_build_object(
                'template_id', v_msg91_template_id,
                'short_url', '0',
                'realTimeResponse', '1',
                'recipients', jsonb_build_array(
                    jsonb_build_object('mobiles', v_phone_formatted, 'OTP', v_otp_code)
                )
            )::text;
            v_http_response := http(('POST', v_msg91_url, v_request_headers, 'application/json', v_request_body)::http_request);
        EXCEPTION WHEN OTHERS THEN
            NULL;
        END;
        
        INSERT INTO public.otp_verifications (phone_number, otp_code, otp_code_hash, msg91_request_id, purpose, expires_at, user_agent, ip_address, msg91_status, delivery_status)
        VALUES (v_phone_formatted, NULL, v_otp_hash, v_request_id, p_purpose, v_expires_at, p_user_agent, p_ip_address, 'msg91_sent', 'pending');
    ELSE
        RETURN utils.error_response('INVALID_PROVIDER', 'Invalid SMS provider configured: ' || v_provider);
    END CASE;
    
    RETURN utils.success_response(
        jsonb_build_object('request_id', v_request_id, 'expires_at', v_expires_at),
        'OTP sent successfully'
    );
    
EXCEPTION
    WHEN OTHERS THEN
        RETURN utils.database_error_response('Failed to send OTP', SQLERRM, SQLSTATE);
END;
$function$

CREATE OR REPLACE FUNCTION public.update_customer(p_customer_id uuid, p_name character varying DEFAULT NULL::character varying, p_mobile character varying DEFAULT NULL::character varying, p_email character varying DEFAULT NULL::character varying, p_address text DEFAULT NULL::text, p_city character varying DEFAULT NULL::character varying, p_state character varying DEFAULT NULL::character varying, p_pincode character varying DEFAULT NULL::character varying, p_gst character varying DEFAULT NULL::character varying, p_pan character varying DEFAULT NULL::character varying, p_active boolean DEFAULT NULL::boolean, p_contact_person character varying DEFAULT NULL::character varying, p_contact_mobile character varying DEFAULT NULL::character varying, p_contact_email character varying DEFAULT NULL::character varying, p_image_urls text[] DEFAULT NULL::text[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_existing RECORD;
BEGIN
    -- Check permission
    IF NOT is_admin_or_supervisor() THEN
        RETURN utils.permission_denied_response('admins and supervisors');
    END IF;
    
    -- Check if customer exists
    SELECT * INTO v_existing FROM customers WHERE id = p_customer_id;
    IF v_existing IS NULL THEN
        RETURN utils.not_found_response('Customer', p_customer_id::text);
    END IF;
    
    -- Validate mobile if provided
    IF p_mobile IS NOT NULL AND NOT p_mobile ~ '^[0-9]{10,15}$' THEN
        RETURN utils.validation_error_response('mobile', 'Mobile number must be 10-15 digits');
    END IF;
    
    -- Check for duplicate mobile
    IF p_mobile IS NOT NULL AND EXISTS(SELECT 1 FROM customers WHERE mobile = p_mobile AND id != p_customer_id AND active = true) THEN
        RETURN utils.error_response('DUPLICATE_MOBILE', 'A customer with this mobile number already exists');
    END IF;
    
    -- Update customer
    UPDATE customers SET
        name = COALESCE(p_name, name),
        mobile = COALESCE(p_mobile, mobile),
        email = COALESCE(p_email, email),
        address = COALESCE(p_address, address),
        city = COALESCE(p_city, city),
        state = COALESCE(p_state, state),
        pincode = COALESCE(p_pincode, pincode),
        gst = COALESCE(p_gst, gst),
        pan = COALESCE(p_pan, pan),
        active = COALESCE(p_active, active),
        contact_person = COALESCE(p_contact_person, contact_person),
        contact_mobile = COALESCE(p_contact_mobile, contact_mobile),
        contact_email = COALESCE(p_contact_email, contact_email),
        updated_at = NOW()
    WHERE id = p_customer_id;
    
    -- Handle images if provided
    IF p_image_urls IS NOT NULL THEN
        DELETE FROM customer_images WHERE customer_id = p_customer_id;
        IF array_length(p_image_urls, 1) > 0 THEN
            INSERT INTO customer_images (customer_id, storage_path)
            SELECT p_customer_id, unnest(p_image_urls);
        END IF;
    END IF;
    
    RETURN utils.success_response(
        jsonb_build_object('customer_id', p_customer_id),
        'Customer updated successfully'
    );
    
EXCEPTION
    WHEN unique_violation THEN
        RETURN utils.error_response('DUPLICATE_MOBILE', 'A customer with this mobile number already exists');
    WHEN OTHERS THEN
        RETURN utils.database_error_response('Failed to update customer', SQLERRM, SQLSTATE);
END;
$function$

CREATE OR REPLACE FUNCTION public.update_user_role(p_user_id uuid, p_new_role user_role)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_auth_uid UUID;
    v_caller_id UUID;
    v_caller_role user_role;
    v_target_id UUID;
    v_old_role user_role;
BEGIN
    -- Cache auth.uid()
    v_auth_uid := auth.uid();
    
    -- Get caller's profile
    SELECT id, role INTO v_caller_id, v_caller_role
    FROM user_profiles
    WHERE auth_user_id = v_auth_uid AND active = true;
    
    -- Authorization: must be admin or supervisor
    IF v_caller_role IS NULL OR v_caller_role NOT IN ('admin', 'supervisor') THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'PERMISSION_DENIED',
            'message', 'Only administrators and supervisors can change user roles'
        );
    END IF;
    
    -- Validate user_id
    IF p_user_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'INVALID_INPUT',
            'message', 'User ID is required'
        );
    END IF;
    
    -- Validate new_role
    IF p_new_role IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'INVALID_INPUT',
            'message', 'New role is required'
        );
    END IF;
    
    -- Get target user
    SELECT id, role INTO v_target_id, v_old_role
    FROM user_profiles
    WHERE id = p_user_id;
    
    IF v_target_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'NOT_FOUND',
            'message', 'User not found'
        );
    END IF;
    
    -- Users cannot change their own role
    IF v_caller_id = v_target_id THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'SELF_EDIT_FORBIDDEN',
            'message', 'You cannot change your own role'
        );
    END IF;
    
    -- Supervisors cannot modify admin users
    IF v_caller_role = 'supervisor' AND v_old_role = 'admin' THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'PERMISSION_DENIED',
            'message', 'Supervisors cannot modify admin users'
        );
    END IF;
    
    -- Supervisors cannot set role to admin
    IF v_caller_role = 'supervisor' AND p_new_role = 'admin' THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'CANNOT_PROMOTE_TO_ADMIN',
            'message', 'Supervisors cannot promote users to admin role'
        );
    END IF;
    
    -- No change needed
    IF v_old_role = p_new_role THEN
        RETURN jsonb_build_object(
            'success', true,
            'user_id', p_user_id,
            'old_role', v_old_role,
            'new_role', p_new_role,
            'message', 'Role unchanged'
        );
    END IF;
    
    -- Update the role
    UPDATE user_profiles
    SET role = p_new_role,
        updated_at = now()
    WHERE id = p_user_id;
    
    RETURN jsonb_build_object(
        'success', true,
        'user_id', p_user_id,
        'old_role', v_old_role,
        'new_role', p_new_role,
        'message', 'Role updated successfully'
    );

EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'INTERNAL_ERROR',
            'message', 'Failed to update user role: ' || SQLERRM
        );
END;
$function$

CREATE OR REPLACE FUNCTION public.verify_otp_or_register(p_phone_number character varying, p_otp_code character varying, p_name character varying DEFAULT NULL::character varying, p_display_name character varying DEFAULT NULL::character varying)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
    v_phone_formatted VARCHAR(15);
    v_otp_record RECORD;
    v_otp_hash TEXT;
    v_user_profile RECORD;
    v_action_taken TEXT;
    v_jwt_secret TEXT;
    v_access_token_expiry INTEGER;
    v_refresh_token_expiry INTEGER;
    v_access_token TEXT;
    v_refresh_token TEXT;
    v_access_token_payload TEXT;
    v_refresh_token_payload TEXT;
    v_token_expires_at TIMESTAMP WITH TIME ZONE;
    v_access_exp BIGINT;
    v_refresh_exp BIGINT;
    v_iat BIGINT;
    v_test_otp VARCHAR(6);
    v_is_test_phone BOOLEAN := FALSE;
BEGIN
    v_phone_formatted := REGEXP_REPLACE(p_phone_number, '[^0-9]', '', 'g');
    IF LENGTH(v_phone_formatted) = 10 THEN
        v_phone_formatted := '91' || v_phone_formatted;
    END IF;

    -- Check if this is a test phone number
    SELECT fixed_otp INTO v_test_otp 
    FROM public.test_otp_records 
    WHERE phone_number = v_phone_formatted;
    
    IF v_test_otp IS NOT NULL AND p_otp_code = v_test_otp THEN
        -- Test phone number with correct OTP - bypass normal verification
        v_is_test_phone := TRUE;
    ELSE
        -- Normal OTP verification flow
        v_otp_hash := encode(digest(p_otp_code, 'sha256'), 'hex');

        SELECT * INTO v_otp_record
        FROM public.otp_verifications ov
        WHERE ov.phone_number = v_phone_formatted
            AND ov.otp_code_hash = v_otp_hash
            AND ov.verified = FALSE
            AND ov.expires_at > NOW()
        ORDER BY ov.created_at DESC
        LIMIT 1;

        IF NOT FOUND THEN
            RETURN jsonb_build_object(
                'success', false,
                'message', 'Invalid or expired OTP',
                'data', null
            );
        END IF;

        UPDATE public.otp_verifications
        SET verified = TRUE, verified_at = NOW()
        WHERE id = v_otp_record.id;
    END IF;

    SELECT * INTO v_user_profile
    FROM public.user_profiles
    WHERE mobile = v_phone_formatted;

    IF NOT FOUND THEN
        INSERT INTO public.user_profiles (auth_user_id, mobile, name, display_name, role, mobile_verified, active)
        VALUES (
            gen_random_uuid(),
            v_phone_formatted,
            COALESCE(p_name, 'User_' || RIGHT(v_phone_formatted, 4)),
            COALESCE(p_display_name, p_name, 'User_' || RIGHT(v_phone_formatted, 4)),
            'customer',
            TRUE,
            TRUE
        )
        RETURNING * INTO v_user_profile;
        v_action_taken := 'register';
    ELSE
        UPDATE public.user_profiles
        SET mobile_verified = TRUE,
            updated_at = NOW(),
            name = COALESCE(p_name, name),
            display_name = COALESCE(p_display_name, display_name)
        WHERE id = v_user_profile.id
        RETURNING * INTO v_user_profile;
        v_action_taken := 'login';
    END IF;

    SELECT secret_value INTO v_jwt_secret
    FROM public.jwt_config
    WHERE secret_name = 'supabase_jwt_secret' AND is_active = TRUE
    LIMIT 1;

    SELECT secret_value::INTEGER INTO v_access_token_expiry
    FROM public.jwt_config
    WHERE secret_name = 'jwt_access_token_expiry' AND is_active = TRUE
    LIMIT 1;

    SELECT secret_value::INTEGER INTO v_refresh_token_expiry
    FROM public.jwt_config
    WHERE secret_name = 'jwt_refresh_token_expiry' AND is_active = TRUE
    LIMIT 1;

    v_access_token_expiry := COALESCE(v_access_token_expiry, 63072000);
    v_refresh_token_expiry := COALESCE(v_refresh_token_expiry, 63072000);
    v_token_expires_at := NOW() + (v_access_token_expiry || ' seconds')::INTERVAL;

    v_iat := EXTRACT(EPOCH FROM NOW())::BIGINT;
    v_access_exp := EXTRACT(EPOCH FROM v_token_expires_at)::BIGINT;
    v_refresh_exp := EXTRACT(EPOCH FROM NOW() + (v_refresh_token_expiry || ' seconds')::INTERVAL)::BIGINT;

    v_access_token_payload := format(
        '{"aud":"authenticated","exp":%s,"iat":%s,"iss":"supabase","sub":"%s","phone":"%s","app_metadata":{"provider":"phone","providers":["phone"]},"user_metadata":{"name":"%s","display_name":"%s","role":"%s"},"role":"authenticated"}',
        v_access_exp, v_iat,
        v_user_profile.auth_user_id::TEXT,
        v_user_profile.mobile,
        COALESCE(v_user_profile.name, ''),
        COALESCE(v_user_profile.display_name, ''),
        v_user_profile.role::TEXT
    );

    v_refresh_token_payload := format(
        '{"aud":"authenticated","exp":%s,"iat":%s,"iss":"supabase","sub":"%s","type":"refresh"}',
        v_refresh_exp, v_iat,
        v_user_profile.auth_user_id::TEXT
    );

    v_access_token := extensions.sign(v_access_token_payload::json, v_jwt_secret, 'HS256');
    v_refresh_token := extensions.sign(v_refresh_token_payload::json, v_jwt_secret, 'HS256');

    RETURN jsonb_build_object(
        'success', true,
        'message', CASE WHEN v_action_taken = 'register' THEN 'Registration successful' ELSE 'Login successful' END,
        'data', jsonb_build_object(
            'user', jsonb_build_object(
                'id', v_user_profile.id,
                'auth_user_id', v_user_profile.auth_user_id,
                'name', v_user_profile.name,
                'display_name', v_user_profile.display_name,
                'mobile', v_user_profile.mobile,
                'role', v_user_profile.role,
                'active', v_user_profile.active,
                'mobile_verified', v_user_profile.mobile_verified
            ),
            'session', jsonb_build_object(
                'access_token', v_access_token,
                'refresh_token', v_refresh_token,
                'expires_at', v_token_expires_at,
                'expires_in', v_access_token_expiry,
                'token_type', 'bearer'
            ),
            'action', v_action_taken
        )
    );
END;
$function$


-- ============================================================
-- ROW LEVEL SECURITY
-- ============================================================

-- Enable RLS on all data tables
ALTER TABLE public.user_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.customers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.goodsreceived ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.grn_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.invoice ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.invoice_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.dispatch ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.dispatch_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stock_movements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.print_jobs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.audit_log ENABLE ROW LEVEL SECURITY;

-- Admin/supervisor: full access to all tables
CREATE POLICY admin_full_access ON public.customers FOR ALL
  USING (
    EXISTS (
      SELECT 1 FROM public.user_profiles
      WHERE auth_user_id = (current_setting('request.jwt.claims', true)::jsonb->>'sub')::uuid
      AND role IN ('admin', 'supervisor')
      AND active = true
    )
  );

CREATE POLICY admin_full_access ON public.goodsreceived FOR ALL
  USING (
    EXISTS (
      SELECT 1 FROM public.user_profiles
      WHERE auth_user_id = (current_setting('request.jwt.claims', true)::jsonb->>'sub')::uuid
      AND role IN ('admin', 'supervisor')
      AND active = true
    )
  );

CREATE POLICY admin_full_access ON public.invoice FOR ALL
  USING (
    EXISTS (
      SELECT 1 FROM public.user_profiles
      WHERE auth_user_id = (current_setting('request.jwt.claims', true)::jsonb->>'sub')::uuid
      AND role IN ('admin', 'supervisor')
      AND active = true
    )
  );

CREATE POLICY admin_full_access ON public.dispatch FOR ALL
  USING (
    EXISTS (
      SELECT 1 FROM public.user_profiles
      WHERE auth_user_id = (current_setting('request.jwt.claims', true)::jsonb->>'sub')::uuid
      AND role IN ('admin', 'supervisor')
      AND active = true
    )
  );

-- Customer: read own data only
CREATE POLICY customer_read_own ON public.customers FOR SELECT
  USING (
    id = (
      SELECT customer_id FROM public.user_profiles
      WHERE auth_user_id = (current_setting('request.jwt.claims', true)::jsonb->>'sub')::uuid
    )
  );

-- Service role bypasses all RLS
CREATE POLICY service_role_bypass ON public.customers FOR ALL
  USING (current_setting('request.jwt.claims', true)::jsonb->>'role' = 'service_role');

CREATE POLICY service_role_bypass ON public.user_profiles FOR ALL
  USING (current_setting('request.jwt.claims', true)::jsonb->>'role' = 'service_role');

-- ============================================================
-- INDEXES
-- ============================================================

CREATE INDEX IF NOT EXISTS idx_user_profiles_auth_user_id ON public.user_profiles(auth_user_id);
CREATE INDEX IF NOT EXISTS idx_user_profiles_mobile ON public.user_profiles(mobile);
CREATE INDEX IF NOT EXISTS idx_otp_verifications_phone ON public.otp_verifications(phone_number);
CREATE INDEX IF NOT EXISTS idx_otp_rate_limits_phone ON public.otp_rate_limits(phone_number);
CREATE INDEX IF NOT EXISTS idx_customers_mobile ON public.customers(mobile);
CREATE INDEX IF NOT EXISTS idx_goodsreceived_customer ON public.goodsreceived(customer_id);
CREATE INDEX IF NOT EXISTS idx_grn_items_grn ON public.grn_items(grn_id);
CREATE INDEX IF NOT EXISTS idx_invoice_customer ON public.invoice(customer_id);
CREATE INDEX IF NOT EXISTS idx_invoice_items_invoice ON public.invoice_items(invoice_id);
CREATE INDEX IF NOT EXISTS idx_dispatch_customer ON public.dispatch(customer_id);
CREATE INDEX IF NOT EXISTS idx_dispatch_items_dispatch ON public.dispatch_items(dispatch_id);
CREATE INDEX IF NOT EXISTS idx_stock_movements_customer ON public.stock_movements(customer_id);
CREATE INDEX IF NOT EXISTS idx_audit_log_table ON public.audit_log(table_name);
CREATE INDEX IF NOT EXISTS idx_audit_log_timestamp ON public.audit_log(created_at);

-- ============================================================
-- GRANTS
-- ============================================================

-- Grant usage on public schema
GRANT USAGE ON SCHEMA public TO anon, authenticated;

-- Grant access to tables for authenticated users (RLS enforced)
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO authenticated;
GRANT SELECT ON public.feature_flags, public.printer_status TO anon;

-- Grant execute on functions
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO anon, authenticated;

-- Grant sequence usage
GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO authenticated;
