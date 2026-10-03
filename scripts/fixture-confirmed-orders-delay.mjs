// Optional exact fictional authenticated read hold for confirmed switching.
import assert from 'node:assert/strict';
import {ordersReadDelayMilliseconds} from './fixture-orders-delay.mjs';
export function confirmedOrdersReadDelayMilliseconds(req,target,configured=0){
 assert.ok(configured===0||configured===30000,'EXACT_CONFIRMED_ORDERS_DELAY_REQUIRED');
 if(!configured)return 0;
 return ordersReadDelayMilliseconds(req,target,500)?30000:0;
}
