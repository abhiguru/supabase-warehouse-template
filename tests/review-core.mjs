import assert from 'node:assert/strict';

// Explicit fictional fixtures. Assertions below state expected values directly.
export async function reviewCore({ api, rpc, success, login, anon, adminToken, customerToken, customerId, grnId, grnItem, dispatchId, base }) {
  const outsider = await login('0000000003');
  const outsiderToken = outsider.access_token;
  const outsiderProfile = (await api('/rest/v1/user_profiles?mobile=eq.910000000003&select=id', adminToken)).data[0].id;
  success(await rpc('update_user_role', adminToken, { p_user_id: outsiderProfile, p_new_role: 'customer' }), 'outsider role');
  for (const row of (await api('/rest/v1/customers?select=id', outsiderToken)).data) await rpc('remove_customer_assignment', adminToken, { target_user_mobile: '910000000003', target_customer_id: row.id });
  const otherCustomer = await rpc('create_customer', adminToken, { p_name: `Review customer ${Date.now()}`, p_mobile: '0000000009' });
  success(otherCustomer, 'create review customer');
  const otherId = otherCustomer.data.customer_id;
  assert.equal(await rpc('assign_customer_to_user', adminToken, { target_user_mobile: '910000000003', target_customer_id: otherId }), true);

  // Active-session role changes must use the current database role, not old JWT claims.
  success(await rpc('update_user_role', adminToken, { p_user_id: outsiderProfile, p_new_role: 'supervisor' }), 'promote active session');
  assert.ok((await api('/rest/v1/customers?select=id', outsiderToken)).data.length > 1);
  success(await rpc('update_user_role', adminToken, { p_user_id: outsiderProfile, p_new_role: 'customer' }), 'demote active session');
  assert.equal((await api('/rest/v1/customers?select=id', outsiderToken)).data.length, 1);
  assert.ok(!(await api('/rest/v1/rpc/save_grn', outsiderToken, { p_gr_no: 'DENIED', p_date: '2026-04-01', p_customer_id: otherId, p_customer_name: 'Review', p_pricing_mode: 'MONTHLY', p_items: [] })).ok);
  assert.equal((await api('/functions/v1/get-config', outsiderToken)).status, 200, 'demoted active session still gets its own configuration');

  for (const [kind, parent, args] of [
    ['grn', grnId, { p_grn_id: grnId, p_image_type: 'header' }],
    ['dispatch', dispatchId, { p_dispatch_id: dispatchId }],
  ]) {
    const bucket = `${kind}-images`;
    const registration = await rpc(`register_${kind}_image_upload`, adminToken, { ...args, p_file_name: 'review.jpg', p_file_size: 1024, p_mime_type: 'image/jpeg' });
    success(registration, `register ${kind} image`);
    const path = `/storage/v1/object/${bucket}/${registration.storage_path}`;
    const upload = await fetch(base + path, { method: 'POST', headers: { apikey: anon, Authorization: `Bearer ${adminToken}`, 'Content-Type': 'image/jpeg' }, body: Buffer.alloc(1024), signal: AbortSignal.timeout(15000) });
    assert.equal(upload.status, 200);
    assert.ok(!(await api(path, customerToken)).ok, 'pending image not shared');
    success(await rpc(`confirm_${kind}_image_upload`, adminToken, { p_image_id: registration.image_id, p_upload_token: registration.upload_token }), 'confirm image');
    assert.equal((await api(path, customerToken)).status, 200, 'assigned customer reads confirmed image');
    assert.ok(!(await api(path, outsiderToken)).ok, 'other assigned customer cannot read confirmed image');
    assert.ok(!(await api(path, anon)).ok, 'anonymous confirmed image denied');
    success(await rpc(`delete_${kind}_image`, adminToken, { p_image_id: registration.image_id }), 'delete image metadata');
    assert.ok(!(await api(path, customerToken)).ok, 'deleted metadata immediately denies reads');
    assert.ok((await api(`/storage/v1/object/${bucket}`, adminToken, { prefixes: [registration.storage_path] }, 'DELETE')).ok, 'delete stored bytes');
    assert.ok(!(await api(path, adminToken)).ok, 'stored object removed');
    assert.equal((await rpc(`register_${kind}_image_upload`, adminToken, { ...args, p_file_name: 'large.jpg', p_file_size: 10485761, p_mime_type: 'image/jpeg' })).success, false);
  }
  console.log('Confirmed GRN/dispatch images isolate customers; metadata and stored-byte deletion, upload limits and active role changes passed.');

  const cart = await rpc('get_or_create_cart', customerToken, { p_customer_id: customerId });
  assert.equal(typeof cart, 'string', 'cart response is a UUID scalar');
  assert.equal(await rpc('get_or_create_cart', customerToken, { p_customer_id: customerId }), cart, 'cart retry preserves identity');
  assert.ok((await api(`/rest/v1/order_items?order_id=eq.${cart}`, customerToken, undefined, 'DELETE')).ok, 'reset fictional demo cart for this fixture');
  const added = await rpc('add_item_to_order', customerToken, { p_order_id: cart, p_grn_item_id: grnItem, p_quantity: 7 });
  success(added, 'add order item');
  const item = (await api(`/rest/v1/order_items?order_id=eq.${cart}&grn_items_id=eq.${grnItem}&select=id,requested_quantity`, customerToken)).data[0];
  assert.equal(item.requested_quantity, 7);
  const list = await rpc('get_orders_list', customerToken, { p_customer_id: customerId, p_has_items: true });
  success(list, 'order list');
  assert.equal(list.data.orders.find(row => row.id === cart)?.quantity_sum, 7, 'order list reflects committed write immediately');
  success(await rpc('update_order_item_quantity', customerToken, { p_order_item_id: item.id, p_new_quantity: 9 }), 'edit quantity');
  assert.equal((await rpc('get_orders_list', customerToken, { p_customer_id: customerId })).data.orders.find(row => row.id === cart)?.quantity_sum, 9);
  const forbiddenEdit = await api('/rest/v1/rpc/update_order_item_quantity', outsiderToken, { p_order_item_id: item.id, p_new_quantity: 10 });
  assert.ok(!forbiddenEdit.ok || forbiddenEdit.data?.success === false, 'cross-customer edit denied');
  assert.equal((await api(`/rest/v1/order_items?id=eq.${item.id}&select=requested_quantity`, customerToken)).data[0].requested_quantity, 9);
  assert.equal((await rpc('add_item_to_order', customerToken, { p_order_id: cart, p_grn_item_id: grnItem, p_quantity: 7 })).success, false, 'duplicate add rejected');
  assert.ok((await api(`/rest/v1/order_items?id=eq.${item.id}&order_id=eq.${cart}`, customerToken, undefined, 'DELETE')).ok);
  assert.equal((await api(`/rest/v1/order_items?id=eq.${item.id}`, customerToken)).data.length, 0);
  console.log('Customer order creation, retry, add/edit/list/delete and cross-customer denial passed.');

  // Customer attachment metadata uses the existing customers.image_urls contract.
  success(await rpc('update_customer', adminToken, { p_customer_id: otherId, p_image_urls: ['review/attachment.jpg'] }), 'update customer attachment metadata');
  assert.deepEqual((await api(`/rest/v1/customers?id=eq.${otherId}&select=image_urls`, adminToken)).data[0].image_urls, ['review/attachment.jpg']);
  success(await rpc('update_customer', adminToken, { p_customer_id: otherId, p_image_urls: [] }), 'remove customer attachments');
  assert.deepEqual((await api(`/rest/v1/customers?id=eq.${otherId}&select=image_urls`, adminToken)).data[0].image_urls, []);

  const number = `F${Date.now().toString(36).slice(-6).toUpperCase()}`;
  success(await rpc('save_grn', adminToken, { p_gr_no: number, p_date: '2026-04-01T12:00:00Z', p_customer_id: otherId, p_customer_name: 'Review', p_pricing_mode: 'MONTHLY', p_items: [{ item_id: '33333333-0000-4000-8000-000000000001', item_name: 'Example Potatoes', packaging: 'Bag', qty: 100, weight: 10, rack: 'REVIEW' }] }), 'financial GRN');
  const financialGrn = (await api(`/rest/v1/goodsreceived?gr_no=eq.${number}&select=id`, adminToken)).data[0].id;
  const stockItem = (await api(`/rest/v1/goodsreceived_trl?gr_id=eq.${financialGrn}&select=id`, adminToken)).data[0].id;
  const dispatchArgs = { p_dispatch_data: { disp_no: number, disp_date: '2026-05-02T12:00:00Z', customer_id: otherId, customer_name: 'Review', supervisor_id: '11111111-0000-4000-8000-000000000001', supervisor_name: 'Demo Admin' }, p_dispatch_items: [{ gr_trl_id: stockItem, disp_qty: 20 }], p_generate_invoice: false, p_idempotency_key: `review-${number}` };
  success(await rpc('create_dispatch_with_stock_check', adminToken, dispatchArgs), 'financial dispatch');
  success(await rpc('create_dispatch_with_stock_check', adminToken, dispatchArgs), 'dispatch retry');
  assert.equal((await api(`/rest/v1/goodsreceived_trl?id=eq.${stockItem}&select=stock`, adminToken)).data[0].stock, 80, 'retry cannot decrement stock twice');
  const report = await rpc('get_customer_stock_summary', outsiderToken, { p_customer_uuid: otherId });
  assert.equal(report.summary.total_quantity, 80);
  assert.equal(report.summary.total_weight_kg, 800);
  assert.equal(report.summary.grn_count, 1);
  success(await rpc('create_item_storage_price', adminToken, {
    p_item_id: '33333333-0000-4000-8000-000000000001', p_customer_id: otherId,
    p_weight_min: 0, p_weight_max: 100, p_price_type: 'monthly', p_unit_price: 5,
    p_labour_rate: 2, p_tax_percent: 5, p_effective_from: '2026-01-01',
  }), 'fixture monthly pricing');
  assert.equal((await rpc('generate_invoice_data_for_grn_with_pricing', adminToken, { p_gr_id: financialGrn })).success, false, 'preview requires fully dispatched GRN');
  success(await rpc('create_dispatch_with_stock_check', adminToken, {
    ...dispatchArgs, p_dispatch_data: { ...dispatchArgs.p_dispatch_data, disp_no: number + 'B' },
    p_dispatch_items: [{ gr_trl_id: stockItem, disp_qty: 80 }], p_idempotency_key: `review-${number}-remaining`,
  }), 'remaining financial dispatch');
  const preview = await rpc('generate_invoice_data_for_grn_with_pricing', adminToken, { p_gr_id: financialGrn, p_duration_mode: 'legacy' });
  success(preview, 'priced invoice preview');
  const pricedRows = [...preview.rows].sort((a, b) => a.dispatch_qty - b.dispatch_qty);
  assert.deepEqual(pricedRows.map(row => ({ qty: row.dispatch_qty, days: row.no_of_days, duration: row.duration, storage: row.storage_amount, labour: row.labour_amount, tax: row.tax_amount, total: row.total_amount })), [
    { qty: 20, days: 31, duration: 1.5, storage: 150, labour: 40, tax: 9.5, total: 199.5 },
    { qty: 80, days: 31, duration: 1.5, storage: 600, labour: 160, tax: 38, total: 798 },
  ]);
  assert.deepEqual(preview.totals, { subtotal: 950, tax: 48, total_tax: 48, grand_total: 998, total: 998, total_rows: 2 });
  const financialDispatch = (await api(`/rest/v1/dispatch?disp_no=eq.${number}&select=id`, adminToken)).data[0].id;
  const dispatchItem = (await api(`/rest/v1/dispatch_trl?disp_id=eq.${financialDispatch}&select=id`, adminToken)).data[0].id;
  const invoiceArgs = { inv_no: Date.now() % 1000000000, inv_fin_year: 2026, gr_id: financialGrn, gr_no: number, customer_id: otherId, customer_name: 'Review', inv_date: '2026-05-02T12:00:00Z', total: 116.01, tax_amount: 5.01, discount: 2.5, duration_mode: 'legacy', items: [{ disp_trl_id: dispatchItem, charge: 5, tax: 5, labour_rate: 2 }] };
  const saved = await rpc('save_invoice', adminToken, { p_invoice_data: invoiceArgs }); success(saved, 'financial invoice');
  const header = (await api(`/rest/v1/invoice?id=eq.${saved.invoice_id}&select=total,tax_amount,discount`, adminToken)).data[0];
  assert.deepEqual(header, { total: 117, tax_amount: 6, discount: 2.5 }, 'existing whole-unit ceiling rule, client-supplied totals');
  const line = (await api(`/rest/v1/invoice_trl?invoice_id=eq.${saved.invoice_id}&select=duration,no_of_days,charge,tax,labour_rate`, adminToken)).data[0];
  assert.deepEqual(line, { duration: 1.5, no_of_days: 31, charge: 5, tax: 5, labour_rate: 2 });
  const invalidNumber = invoiceArgs.inv_no + 1;
  assert.equal((await rpc('save_invoice', adminToken, { p_invoice_data: { ...invoiceArgs, inv_no: invalidNumber, items: [{ disp_trl_id: '00000000-0000-4000-8000-000000000000', charge: 1 }] } })).success, false, 'missing dispatch line cannot create an empty invoice');
  assert.equal((await api(`/rest/v1/invoice?inv_no=eq.${invalidNumber}&select=id`, adminToken)).data.length, 0, 'failed invoice rolls back its header');
  console.log('Independent invoice duration/rounding and stock-report fixtures, dispatch retry and failed-invoice rollback passed.');

  // Genuine server refresh/logout race: either ordering must end revoked.
  const raced = await login('0000000004');
  const [refresh] = await Promise.all([rpc('refresh_jwt_token', anon, { p_refresh_token: raced.refresh_token }), rpc('logout_session', anon, { p_refresh_token: raced.refresh_token })]);
  if (refresh.success) {
    // The logout carrying the original credential must revoke the rotated session.
    assert.ok(!(await api('/rest/v1/customers', refresh.access_token)).ok);
  }
  await rpc('logout_session', anon, { p_refresh_token: outsider.refresh_token });
}
