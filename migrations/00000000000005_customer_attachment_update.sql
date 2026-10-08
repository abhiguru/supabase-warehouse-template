-- Preserve the create_customer/customers.image_urls contract when editing.
-- The old update path referenced a table absent from this exported schema.
CREATE OR REPLACE FUNCTION public.update_customer(p_customer_id uuid, p_name character varying DEFAULT NULL::character varying, p_mobile character varying DEFAULT NULL::character varying, p_email character varying DEFAULT NULL::character varying, p_address text DEFAULT NULL::text, p_city character varying DEFAULT NULL::character varying, p_state character varying DEFAULT NULL::character varying, p_pincode character varying DEFAULT NULL::character varying, p_gst character varying DEFAULT NULL::character varying, p_pan character varying DEFAULT NULL::character varying, p_active boolean DEFAULT NULL::boolean, p_contact_person character varying DEFAULT NULL::character varying, p_contact_mobile character varying DEFAULT NULL::character varying, p_contact_email character varying DEFAULT NULL::character varying, p_image_urls text[] DEFAULT NULL::text[]) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path = pg_catalog, public, extensions, utils, pg_temp
    AS $_$
DECLARE
    v_existing RECORD;
BEGIN
    PERFORM warehouse_security.authorize_rpc('update_customer', jsonb_build_object('p_customer_id', p_customer_id));
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
        UPDATE customers SET image_urls = p_image_urls WHERE id = p_customer_id;
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
$_$;
NOTIFY pgrst, 'reload schema';
