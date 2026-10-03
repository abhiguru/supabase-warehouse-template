// Optional exact fictional authenticated read hold for confirmed switching.
import assert from 'node:assert/strict';
import {ordersReadDelayMilliseconds} from './fixture-orders-delay.mjs';
export function confirmedOrdersReadDelayMilliseconds(req,target,configured=0){
 assert.ok(configured===0||configured===30000,'EXACT_CONFIRMED_ORDERS_DELAY_REQUIRED');
 if(!configured)return 0;
 return ordersReadDelayMilliseconds(req,target,500)?30000:0;
}

export function createConfirmedOrdersReadController(configured=0,now=Date.now){
 assert.ok(configured===0||configured===30000);let state=configured?'READY':'DISABLED',attemptId=null,deadline=0;
 const status=()=>{if(state==='ARMED'&&now()>=deadline)state='EXPIRED';return {state,attemptId};};
 return {status,arm(request){assert.equal(status().state,'READY','SINGLE_ARM_ONLY');assert.deepEqual(Object.keys(request).sort(),['action','attemptId','deadlineUTC']);assert.equal(request.action,'arm-confirmed-orders-read');assert.match(request.attemptId,/^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/);const until=Date.parse(request.deadlineUTC);assert.ok(Number.isFinite(until)&&until>now()&&until-now()<=60000,'BOUNDED_ARM_WINDOW_REQUIRED');attemptId=request.attemptId;deadline=until;state='ARMED';return status();},take(req,target){if(status().state!=='ARMED'||!confirmedOrdersReadDelayMilliseconds(req,target,configured))return null;state='CONSUMED';return {milliseconds:30000,attemptId};}};
}
