(()=>{
  const L=globalThis.LightweightCharts,C=globalThis.SXChartCore,root=document.getElementById('plot'),empty=document.getElementById('empty');
  let chart,series=[],primary,rows=[],payload={},period='',stateTimer,paintFrame;
  const send=(type,value)=>globalThis.webkit?.messageHandlers?.chartEvent?.postMessage({type,...value});
  const format=n=>Number.isFinite(n)?n.toLocaleString('en-US',{maximumFractionDigits:2}):'—';
  const validRange=range=>range&&Number.isFinite(range.from)&&Number.isFinite(range.to)&&range.to>range.from;
  function state(){const range=chart.timeScale().getVisibleLogicalRange(),canvas=[...root.querySelectorAll('canvas')].sort((a,b)=>b.width*b.height-a.width*a.height)[0];return {bars:rows.length,period,ma:payload.averages||[],visibleFrom:range?.from??0,visibleTo:range?.to??0,plotWidth:root.clientWidth,plotHeight:root.clientHeight,canvasWidth:canvas?.width??0,canvasHeight:canvas?.height??0};}
  function emitState(){if(chart)send('state',state());}
  function afterPaint(){cancelAnimationFrame(paintFrame);paintFrame=requestAnimationFrame(()=>{paintFrame=requestAnimationFrame(()=>send('painted',state()));});}
  function resize(){if(!chart||root.clientWidth<1||root.clientHeight<1)return;chart.resize(root.clientWidth,root.clientHeight,true);if(rows.length&&!validRange(chart.timeScale().getVisibleLogicalRange()))reset();emitState();afterPaint();}
  function readout(event){const row=event?.time?rows.find(row=>row.time===event.time):rows.at(-1);if(!row)return;const text=[row.time,`開 ${format(row.open)}`,`高 ${format(row.high)}`,`低 ${format(row.low)}`,`收 ${format(row.close)}`,`量 ${format(row.volume)}`];for(const n of payload.averages||[]){const value=series.find(s=>s.period===n)?.data.get(row.time);if(Number.isFinite(value))text.push(`MA${n} ${format(value)}`);}send('readout',{text:text.join('  ')});}
  function create(dark){
    chart=L.createChart(root,{autoSize:false,width:Math.max(1,root.clientWidth),height:Math.max(1,root.clientHeight),layout:{background:{type:'solid',color:dark?'#16201d':'#ffffff'},textColor:dark?'#b9c8bf':'#63776c',fontFamily:'-apple-system, sans-serif',fontSize:11,attributionLogo:true},grid:{vertLines:{color:dark?'#24342c':'#edf2ee'},horzLines:{color:dark?'#24342c':'#edf2ee'}},rightPriceScale:{borderVisible:false,scaleMargins:{top:.08,bottom:.25}},timeScale:{borderVisible:false,rightOffset:3,barSpacing:7},crosshair:{mode:0},handleScroll:{mouseWheel:true,pressedMouseMove:true,horzTouchDrag:true,vertTouchDrag:false},handleScale:{pinch:true,mouseWheel:true,axisPressedMouseMove:true},localization:{locale:'zh-TW',timeFormatter:t=>typeof t==='string'?t:`${t.year}-${String(t.month).padStart(2,'0')}-${String(t.day).padStart(2,'0')}`},trackingMode:{exitMode:L.TrackingModeExitMode.OnNextTap}});
    chart.subscribeCrosshairMove(readout);chart.timeScale().subscribeVisibleLogicalRangeChange(()=>{clearTimeout(stateTimer);stateTimer=setTimeout(emitState,60);});
  }
  function render(p){
    const changedPeriod=period!==(p.period||'day'),darkChanged=payload.dark!==p.dark;
    const range=chart?.timeScale().getVisibleLogicalRange(),saved=rows.length&&validRange(range)&&range.to>=0&&range.from<rows.length?range:null;payload=p;period=p.period||'day';
    if(!chart||darkChanged){chart?.remove();create(p.dark);series=[];}
    for(const entry of series)chart.removeSeries(entry.line);series=[];
    rows=C.rows(p.rows);if(period==='week')rows=C.weekly(rows);
    const up=p.upRed?'#c95b53':'#298563',down=p.upRed?'#298563':'#c95b53';
    if(p.forecast?.length){
      const points=C.forecast(p.forecast);empty.textContent=points.length?'':'沒有可顯示的原始預測價位';
      for(const [key,color,width] of [['low','#a8b8cb',1],['high','#a8b8cb',1],['price','#5f83b5',3]]){const line=chart.addSeries(L.LineSeries,{color,lineWidth:width,priceLineVisible:false,lastValueVisible:key==='price',lineStyle:key==='price'?0:2});line.setData(C.forecast(p.forecast,key));series.push({line});if(key==='price')primary=line;}
      if(Number.isFinite(p.latestClose)&&p.latestClose>0)primary.createPriceLine({price:p.latestClose,color:'#8c998f',lineWidth:1,lineStyle:2,axisLabelVisible:true,title:'原始收盤'});
      chart.timeScale().fitContent();emitState();afterPaint();return;
    }
    empty.textContent=rows.length?'':'行情尚未取得，請下拉重試';
    primary=chart.addSeries(L.CandlestickSeries,{upColor:up,downColor:down,wickUpColor:up,wickDownColor:down,borderVisible:false});primary.setData(rows);series.push({line:primary});
    const volume=chart.addSeries(L.HistogramSeries,{priceScaleId:'volume',priceFormat:{type:'volume'},lastValueVisible:false,priceLineVisible:false});volume.priceScale().applyOptions({scaleMargins:{top:.82,bottom:0}});volume.setData(rows.map(row=>({time:row.time,value:row.volume,color:(row.close>=row.open?up:down)+'60'})));series.push({line:volume});
    for(const [index,n] of (p.averages||[5,20]).entries()){const points=C.average(rows,n),line=chart.addSeries(L.LineSeries,{color:['#c69a55','#6384b3','#9e76ae','#7d9c62'][index],lineWidth:1,priceLineVisible:false,lastValueVisible:false,crosshairMarkerVisible:false});line.setData(points);series.push({line,period:n,data:new Map(points.map(x=>[x.time,x.value]))});}
    if(saved&&!changedPeriod&&!p.reset&&saved.to>=0&&saved.from<rows.length)chart.timeScale().setVisibleLogicalRange(saved);else reset();
    readout();emitState();afterPaint();
  }
  function reset(){if(!chart||!rows.length)return;if(payload.visible>0)chart.timeScale().setVisibleLogicalRange({from:Math.max(-1,rows.length-payload.visible-1),to:rows.length+2});else chart.timeScale().fitContent();emitState();}
  globalThis.SXChart={render,reset,resize,range(count){payload.visible=count;reset();}};
  new ResizeObserver(()=>requestAnimationFrame(resize)).observe(root);
  send('ready',{});
})();
