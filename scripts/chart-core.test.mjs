import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import vm from 'node:vm';

// Run the exact shipped component in a separate JS realm, without browser,
// network, filesystem or mocked mathematical implementations in its context.
const scriptURL=new URL('../Shixu/Resources/Chart/chart-core.js',import.meta.url);
const context=vm.createContext({});
vm.runInContext(await readFile(scriptURL,'utf8'),context,{filename:scriptURL.pathname});
const core=context.SXChartCore;
const plain=value=>JSON.parse(JSON.stringify(value));
const freeze=rows=>Object.freeze(rows.map(row=>Object.freeze({...row})));
const bar=(time,close=100,volume=1000)=>({time,open:close-.5,high:close+1,low:close-.75,close,volume});
function tradingDates(count){
  const output=[],date=new Date('2026-01-05T00:00:00Z');
  while(output.length<count){if(![0,6].includes(date.getUTCDay()))output.push(date.toISOString().slice(0,10));date.setUTCDate(date.getUTCDate()+1);}
  return output;
}
const dates=tradingDates(126);
const history=freeze(dates.slice(0,100).map((date,index)=>bar(date,index+1,1000+index)));

test('ISO dates require real calendar days, including correct leap years',()=>{
  for(const day of ['2024-02-29','2026-01-05','2026-12-31'])assert.equal(core.validDay(day),true,day);
  for(const day of ['2026-02-29','2026-02-30','2026-04-31','2026-00-10','2026-13-01','2026-01-00','2026-01-32','2026-1-05','01/05/2026','2026-01-05T00:00:00Z','',null,20260105]){
    assert.equal(core.validDay(day),false,String(day));
    assert.deepEqual(plain(core.rows([{...bar('2026-01-05'),time:day}])),[]);
  }
});

test('invalid OHLC and nonnumeric or nonfinite amounts are discarded without price substitution',()=>{
  const good=bar('2026-01-05'),invalid=[
    {...good,open:0},{...good,close:-1},{...good,low:0},
    {...good,high:good.open-.1},{...good,low:good.close+.1},
    {...good,volume:-1},null,{}
  ];
  for(const key of ['open','high','low','close','volume']){
    for(const value of [NaN,Infinity,-Infinity,String(good[key]),null,undefined,true])invalid.push({...good,[key]:value});
  }
  assert.deepEqual(plain(core.rows(invalid)),[]);
  assert.deepEqual(plain(core.rows([{...good,volume:0}])),[{...good,volume:0}],'a valid zero-volume bar must remain zero');
});

test('history sorts by date and keeps the last received duplicate without mutating source records',()=>{
  const first=bar('2026-01-05',100,200),replacement=bar('2026-01-05',110,300);
  const input=freeze([bar('2026-01-07',120),first,bar('2026-01-06',115),replacement]);
  const before=JSON.stringify(input);
  assert.deepEqual(plain(core.rows(input)),[replacement,bar('2026-01-06',115),bar('2026-01-07',120)]);
  assert.equal(JSON.stringify(input),before);
});

test('MA5 and MA20 use all 100 completed closes and do not mutate history',()=>{
  const before=JSON.stringify(history),ma5=plain(core.average(history,5)),ma20=plain(core.average(history,20));
  assert.equal(ma5.length,96);assert.deepEqual(ma5[0],{time:dates[4],value:3});assert.deepEqual(ma5.at(-1),{time:dates[99],value:98});
  assert.equal(ma20.length,81);assert.deepEqual(ma20[0],{time:dates[19],value:10.5});assert.deepEqual(ma20.at(-1),{time:dates[99],value:90.5});
  assert.equal(JSON.stringify(history),before);
});

test('a 22-bar viewport retains 22 MA20 points when calculations precede viewport clipping',()=>{
  // Visible range is a presentation concern: earlier bars still contribute to
  // each moving average. Computing MA20 from only 22 bars would leave 3 points.
  const visibleDates=new Set(history.slice(-22).map(row=>row.time));
  const ma20=plain(core.average(history,20)).filter(point=>visibleDates.has(point.time));
  const ma5=plain(core.average(history,5)).filter(point=>visibleDates.has(point.time));
  assert.equal(ma20.length,22);assert.equal(ma5.length,22);
  assert.deepEqual(ma20[0],{time:dates[78],value:69.5});assert.deepEqual(ma20.at(-1),{time:dates[99],value:90.5});
  assert.deepEqual(ma5[0],{time:dates[78],value:77});
});

test('weekly candles start on Monday and preserve first open, last close, extrema and share volume',()=>{
  const input=freeze([
    {time:'2026-01-09',open:116,high:128,low:113,close:125,volume:500},
    {time:'2025-12-31',open:98,high:105,low:96,close:100,volume:100},
    {time:'2026-01-07',open:119,high:123,low:114,close:115,volume:400},
    {time:'2026-01-12',open:126,high:132,low:124,close:130,volume:0},
    {time:'2026-01-02',open:101,high:112,low:99,close:110,volume:200},
    {time:'2026-01-05',open:111,high:121,low:109,close:120,volume:300}
  ]),before=JSON.stringify(input);
  assert.deepEqual(plain(core.weekly(core.rows(input))),[
    {time:'2025-12-29',open:98,high:112,low:96,close:110,volume:300},
    {time:'2026-01-05',open:111,high:128,low:109,close:125,volume:1200},
    {time:'2026-01-12',open:126,high:132,low:124,close:130,volume:0}
  ]);
  assert.equal(JSON.stringify(input),before);
});

const schedules=[
  {horizon:7,steps:[1,2,3,4,5,6,7]},
  {horizon:30,steps:[3,6,9,12,15,18,21,24,27,30]},
  {horizon:126,steps:[5,11,16,21,26,32,37,42,47,53,58,63,68,74,79,84,89,95,100,105,110,116,121,126]}
];
for(const {horizon,steps} of schedules)test(`${horizon}-day forecast preserves all ${steps.length} archived prices, bounds and dates without interpolation`,()=>{
  const input=freeze(steps.map((day,index)=>({day,date:dates[day-1],price:100+index*.375,low:94+index*.25,high:110+index*.5,judgment:`Original point ${index+1}`})));
  const before=JSON.stringify(input);
  for(const key of ['price','low','high']){
    const output=plain(core.forecast(input,key));
    assert.equal(output.length,steps.length);
    assert.deepEqual(output,input.map(point=>({time:point.date,value:point[key]})));
    assert.deepEqual(output.map(point=>point.time),input.map(point=>point.date));
    assert.equal(output.at(-1).time,dates[horizon-1]);
  }
  assert.equal(JSON.stringify(input),before);
});

test('invalid forecast dates and values are omitted, never repaired or filled from another bound',()=>{
  const input=[{date:'2026-02-30',price:100,low:90,high:110},{date:'2026-01-05',price:'100',low:NaN,high:Infinity},{date:'2026-01-06',price:0,low:-1,high:null}];
  for(const key of ['price','low','high'])assert.deepEqual(plain(core.forecast(input,key)),[]);
});

test('empty or insufficient data never produces synthetic bars, prices or moving averages',()=>{
  for(const input of [[],null,undefined,{}]){
    assert.deepEqual(plain(core.rows(input)),[]);assert.deepEqual(plain(core.forecast(input)),[]);
  }
  assert.deepEqual(plain(core.weekly([])),[]);
  assert.deepEqual(plain(core.average([],5)),[]);
  assert.deepEqual(plain(core.average(history.slice(0,4),5)),[]);
  assert.deepEqual(plain(core.average(history.slice(0,19),20)),[]);
});
