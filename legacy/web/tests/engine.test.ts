import test from 'node:test';
import assert from 'node:assert/strict';
import { initialState, articles, recommend, interestWeights, localDate } from '../lib/engine.ts';

test('daily recommendation survives changing interests and feedback',()=>{const first=recommend(initialState,'2026-11-04')!;const state={...initialState,daily:{'2026-11-04':first.id},interests:['Музыка'],feedback:{[first.id]:-1}};assert.equal(recommend(state,'2026-11-04')?.id,first.id);assert.notEqual(recommend(state,'2026-11-05')?.id,first.id);});
test('feedback is calculated from current vote without accumulating duplicate changes',()=>{const state={...initialState,feedback:{antikythera:1}};assert.ok(Math.abs(interestWeights(state)['История']-0.85)<1e-10);assert.deepEqual(interestWeights(state),interestWeights({...state,feedback:{antikythera:1}}));assert.ok(interestWeights({...state,feedback:{antikythera:-1}})['История']<0.8);});
test('excludes read and previously assigned articles; handles exhausted catalog',()=>{const state={...initialState,read:Object.fromEntries(articles.map(a=>[a.id,'2026-11-03']))};assert.equal(recommend(state,'2026-11-04'),undefined);});
test('local date respects timezone near midnight',()=>{const instant=new Date('2026-11-03T22:00:00Z');assert.equal(localDate('Europe/Moscow',instant),'2026-11-04');assert.equal(localDate('Europe/Berlin',instant),'2026-11-03');});
