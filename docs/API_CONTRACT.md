# Mobile/backend API name coverage

Generated from the second-pass TypeScript syntax inventory on 2026-09-10. Comments and tests are excluded. This is not runtime/signature/security verification.

Regenerate with `node scripts/check-mobile-contract.mjs ../rn-warehouse-template` after installing the mobile dependencies. A nonzero exit is intentional until these gaps are resolved.

## Missing RPCs

70 missing out of 76 literal references.

- `cancel_dispatch_image_upload`
- `cancel_grn_image_upload`
- `check_dispatch_exists`
- `check_grn_exists`
- `confirm_dispatch_image_upload`
- `confirm_grn_image_upload`
- `create_dispatch_with_stock_check`
- `delete_dispatch_image`
- `delete_dispatch_with_order_cleanup`
- `delete_grn_image`
- `delete_user_account`
- `generate_invoice_data_for_grn_with_pricing`
- `get_all_customer_activity_summary`
- `get_all_dispatch_activity`
- `get_all_dispatch_items`
- `get_all_grn_activity`
- `get_all_grn_items`
- `get_all_stock_summary`
- `get_customer_activity_detail`
- `get_customer_dispatch_activity`
- `get_customer_dispatch_items`
- `get_customer_grn_activity`
- `get_customer_grn_items`
- `get_customer_grns_with_stock_dispatch_sorted`
- `get_customer_invoice_summary`
- `get_customer_items_for_order_selection`
- `get_customer_stock_analysis_v2`
- `get_dispatch_list`
- `get_dispatch_list_with_items`
- `get_grn_autocomplete`
- `get_grn_prefixes_with_stock`
- `get_invoice_data`
- `get_invoice_detail`
- `get_invoice_items_detailed`
- `get_invoiceable_grns`
- `get_invoices_list`
- `get_item`
- `get_item_storage_prices`
- `get_items`
- `get_next_dispatch_number`
- `get_next_grn_number`
- `get_next_invoice_number`
- `get_operations_dashboard`
- `get_or_create_cart`
- `get_order_change_log`
- `get_order_with_items`
- `get_orders_list`
- `get_recent_dispatched_orders`
- `get_sensor_history`
- `get_sensor_polling_data`
- `get_stock_aging_report`
- `get_supervisors`
- `get_user_details`
- `get_users_list`
- `refresh_jwt_token`
- `register_dispatch_image_upload`
- `register_grn_image_upload`
- `restore_customer`
- `safe_delete_customer`
- `save_grn`
- `save_invoice`
- `search_customer_items_for_order`
- `search_customers`
- `search_items_autocomplete`
- `update_dispatch_smart`
- `update_grn`
- `update_invoice`
- `update_user_status`
- `upload_grn_image`
- `user_accessible_customers`

## Missing tables

4 missing out of 8 literal references.

- `dispatch_trl`
- `goodsreceived_trl`
- `grn_images`
- `order_items`

## Missing Edge Functions

7 missing out of 10 literal references.

- `generate-customer-stock-pdf`
- `generate-dispatch-pdf`
- `generate-grn-pdf`
- `generate-invoice-pdf`
- `print-dispatch-preprinted`
- `print-grn-preprinted`
- `print-invoice-preprinted`
