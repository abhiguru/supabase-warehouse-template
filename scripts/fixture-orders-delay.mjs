// Optional bounded fictional Orders-read transport; no write route can match.
import assert from 'node:assert/strict';
export function ordersReadDelayMilliseconds(req,target,configured=0){
 assert.ok(Number.isInteger(configured)&&(configured===0||configured>=500&&configured<=5000),'BOUNDED_FIXTURE_ORDERS_DELAY_REQUIRED');
 if(!configured)return 0;
 return req.method==='POST'&&target.protocol==='http:'&&target.hostname==='127.0.0.1'&&target.port==='18080'&&target.pathname==='/rest/v1/rpc/get_orders_list'&&target.search===''&&req.headers.host==='backend-core.example.test'&&typeof req.headers.authorization==='string'&&req.headers.authorization.length>0?configured:0;
}
