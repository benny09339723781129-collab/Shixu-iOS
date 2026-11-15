// Pure transformations shared by the local TradingView component and its checks.
globalThis.SXChartCore = Object.freeze({
  validDay(value) {
    if(typeof value!=='string'||!/^\d{4}-\d{2}-\d{2}$/.test(value))return false;
    const date=new Date(value+'T00:00:00Z');return Number.isFinite(+date)&&date.toISOString().slice(0,10)===value;
  },
  rows(input) {
    const days=new Map();
    for(const row of Array.isArray(input)?input:[]) {
      if(!row||!this.validDay(row.time)||!['open','high','low','close','volume'].every(key=>Number.isFinite(row[key]))||row.low<=0||row.open<=0||row.close<=0||row.high<Math.max(row.open,row.close)||row.low>Math.min(row.open,row.close)||row.volume<0)continue;
      days.set(row.time,{time:row.time,open:row.open,high:row.high,low:row.low,close:row.close,volume:row.volume});
    } return [...days.values()].sort((a,b)=>a.time.localeCompare(b.time));
  },
  average(rows,period) {
    if(!Number.isInteger(period)||period<1||period>500)return [];
    let sum=0;const output=[];
    rows.forEach((row,index)=>{sum+=row.close;if(index>=period)sum-=rows[index-period].close;if(index>=period-1)output.push({time:row.time,value:sum/period});});return output;
  },
  weekly(rows) {
    const weeks=new Map();
    for(const row of rows){const date=new Date(row.time+'T00:00:00Z');date.setUTCDate(date.getUTCDate()-(date.getUTCDay()+6)%7);const time=date.toISOString().slice(0,10),previous=weeks.get(time);if(previous){previous.close=row.close;previous.high=Math.max(previous.high,row.high);previous.low=Math.min(previous.low,row.low);previous.volume+=row.volume;}else weeks.set(time,{...row,time});}
    return [...weeks.values()];
  },
  forecast(input,key='price') {
    return (Array.isArray(input)?input:[]).filter(row=>row&&this.validDay(row.date)&&Number.isFinite(row[key])&&row[key]>0).map(row=>({time:row.date,value:row[key]}));
  }
});
