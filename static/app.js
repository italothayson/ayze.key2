/* AYZE 2.0 */
const $=(s,r=document)=>r.querySelector(s),$$=(s,r=document)=>[...r.querySelectorAll(s)];
function toast(msg,kind){const box=$('.toasts');if(!box)return;const t=document.createElement('div');t.className='toast '+(kind||'');t.textContent=msg;box.appendChild(t);setTimeout(()=>{t.classList.add('out');setTimeout(()=>t.remove(),320)},3200)}
async function copyText(v,btn){try{await navigator.clipboard.writeText(v)}catch(e){const a=document.createElement('textarea');a.value=v;document.body.appendChild(a);a.select();document.execCommand('copy');a.remove()}
 toast('Copiado: '+(v.length>40?v.slice(0,40)+'…':v));if(btn){const o=btn.textContent;btn.textContent='COPIADA ✓';setTimeout(()=>btn.textContent=o,900)}}
window.toast=toast;window.copyText=copyText;
/* flashes vindas do servidor */
$$('[data-flash]').forEach(f=>toast(f.dataset.msg,f.dataset.flash==='err'?'err':''));
/* spotlight nos cards */
document.addEventListener('mousemove',e=>{const c=e.target.closest&&e.target.closest('.card');if(!c)return;const r=c.getBoundingClientRect();c.style.setProperty('--mx',(e.clientX-r.left)+'px');c.style.setProperty('--my',(e.clientY-r.top)+'px')});
/* contador animado */
function countUp(el){const to=+el.dataset.count||0,d=700,s=performance.now();(function f(n){const p=Math.min(1,(n-s)/d);el.textContent=Math.round(to*(1-Math.pow(1-p,3)));if(p<1)requestAnimationFrame(f)})(s)}
$$('[data-count]').forEach(countUp);
/* sidebar mobile */
const sb=$('.sidebar');$('.burger')&&$('.burger').addEventListener('click',()=>sb.classList.toggle('open'));
document.addEventListener('click',e=>{if(sb&&sb.classList.contains('open')&&!e.target.closest('.sidebar,.burger'))sb.classList.remove('open')});
/* relógio */
const clock=$('#clock');if(clock){const t=()=>{const d=new Date();clock.textContent=d.toLocaleTimeString('pt-BR')};t();setInterval(t,1000)}
/* confirmação customizada */
let pendingForm=null;const cm=$('#confirmModal');
document.addEventListener('submit',e=>{const f=e.target;if(f.dataset.confirm&&!f.dataset.ok){e.preventDefault();pendingForm=f;$('#confirmText').textContent=f.dataset.confirm;cm.classList.add('show')}});
$('#confirmYes')&&$('#confirmYes').addEventListener('click',()=>{if(pendingForm){pendingForm.dataset.ok=1;pendingForm.submit()}});
$$('[data-close]').forEach(b=>b.addEventListener('click',()=>b.closest('.overlay').classList.remove('show')));
$$('.overlay').forEach(o=>o.addEventListener('mousedown',e=>{if(e.target===o)o.classList.remove('show')}));
/* paleta de comandos */
const ck=$('#cmdk');
if(ck){const items=$$('#cmdList li');const inp=$('#cmdInput');let idx=0;
 const vis=()=>items.filter(l=>l.style.display!=='none');
 const mark=()=>{vis().forEach((l,i)=>l.classList.toggle('on',i===idx))};
 const open=()=>{ck.classList.add('show');inp.value='';items.forEach(l=>l.style.display='');idx=0;mark();setTimeout(()=>inp.focus(),30)};
 const run=l=>{if(!l)return;if(l.dataset.href)location.href=l.dataset.href;else if(l.dataset.act==='logout')$('#logoutForm').submit();else if(l.dataset.act==='copy-url')copyText(l.dataset.val);ck.classList.remove('show')};
 inp.addEventListener('input',()=>{const q=inp.value.toLowerCase();items.forEach(l=>l.style.display=l.textContent.toLowerCase().includes(q)?'':'none');idx=0;mark()});
 inp.addEventListener('keydown',e=>{const v=vis();if(e.key==='ArrowDown'){idx=(idx+1)%v.length;mark();e.preventDefault()}else if(e.key==='ArrowUp'){idx=(idx-1+v.length)%v.length;mark();e.preventDefault()}else if(e.key==='Enter')run(v[idx])});
 items.forEach(l=>l.addEventListener('click',()=>run(l)));
 $$('[data-cmdk]').forEach(b=>b.addEventListener('click',open));
 document.addEventListener('keydown',e=>{if((e.ctrlKey||e.metaKey)&&e.key.toLowerCase()==='k'){e.preventDefault();open()}if(e.key==='Escape')$$('.overlay.show').forEach(o=>o.classList.remove('show'))})}
/* ---------- KEYS: filtro, ordenação, paginação, seleção ---------- */
const table=$('#keysTable');
if(table){const tb=table.tBodies[0];const rows=[...tb.rows].filter(r=>r.dataset.key);const per0=+table.dataset.per||25;let per=per0,page=1,st='all',q='',sortCol=null,dir=1;
 const search=$('#search');const info=$('#pageInfo'),pg=$('#pager');
 const hit=r=>(st==='all'||r.dataset.status===st||(st==='online'&&r.dataset.online==='1'))&&(!q||r.innerText.toLowerCase().includes(q));
 function render(){const f=rows.filter(hit);const pages=Math.max(1,Math.ceil(f.length/per));if(page>pages)page=pages;rows.forEach(r=>r.style.display='none');
  f.slice((page-1)*per,page*per).forEach(r=>r.style.display='');
  info.textContent=f.length?`${(page-1)*per+1}–${Math.min(page*per,f.length)} de ${f.length}`:'Nada encontrado';
  pg.innerHTML='';for(let i=1;i<=pages&&i<=12;i++){const b=document.createElement('button');b.className='pill'+(i===page?' on':'');b.textContent=i;b.onclick=()=>{page=i;render()};pg.appendChild(b)}
  $('#emptyRow').style.display=f.length?'none':'';sel()}
 function sel(){const c=rows.filter(r=>r.querySelector('.cb')&&r.querySelector('.cb').checked);rows.forEach(r=>r.classList.toggle('sel',r.querySelector('.cb').checked));const b=$('#bulk');b.classList.toggle('show',c.length>0);$('#bulkN').textContent=c.length;
  $$('#bulkForm input[name=keys]').forEach(i=>i.remove());c.forEach(r=>{const i=document.createElement('input');i.type='hidden';i.name='keys';i.value=r.dataset.key;$('#bulkForm').appendChild(i)})}
 search&&search.addEventListener('input',()=>{q=search.value.toLowerCase();page=1;render()});
 $$('[data-filter]').forEach(p=>p.addEventListener('click',()=>{$$('[data-filter]').forEach(x=>x.classList.remove('on'));p.classList.add('on');st=p.dataset.filter;page=1;render()}));
 $('#perPage')&&$('#perPage').addEventListener('change',e=>{per=+e.target.value;page=1;render()});
 $$('th.sort').forEach(th=>th.addEventListener('click',()=>{const c=th.cellIndex;dir=sortCol===c?-dir:1;sortCol=c;
  rows.sort((a,b)=>{const x=a.cells[c].dataset.v??a.cells[c].innerText,y=b.cells[c].dataset.v??b.cells[c].innerText;const nx=parseFloat(x),ny=parseFloat(y);return (isNaN(nx)||isNaN(ny)?x.localeCompare(y):nx-ny)*dir});
  rows.forEach(r=>tb.insertBefore(r,$('#emptyRow')));render()}));
 $('#checkAll')&&$('#checkAll').addEventListener('change',e=>{rows.filter(r=>r.style.display!=='none').forEach(r=>r.querySelector('.cb').checked=e.target.checked);sel()});
 tb.addEventListener('change',e=>{if(e.target.classList.contains('cb'))sel()});
 $('#bulkAction')&&$('#bulkAction').addEventListener('change',e=>{$('#bulkTime').style.display=e.target.value==='add_time'?'flex':'none'});
 if(search&&search.dataset.init){search.value=search.dataset.init;q=search.value.toLowerCase()}
 render()}
/* modais de key */
document.addEventListener('click',e=>{const b=e.target.closest('[data-edit],[data-addtime]');if(!b)return;
 if(b.dataset.edit){const m=$('#editModal');$('#editKey').value=b.dataset.edit;$('#editName').value=b.dataset.name;$('#editNote').value=b.dataset.note||'';$('#editTitle').textContent=b.dataset.edit;m.classList.add('show')}
 if(b.dataset.addtime){const m=$('#timeModal');$('#timeKey').value=b.dataset.addtime;$('#timeTitle').textContent=b.dataset.addtime;m.classList.add('show')}});
/* presets do gerador */
$$('.preset').forEach(p=>p.addEventListener('click',()=>{$$('.preset').forEach(x=>x.classList.remove('on'));p.classList.add('on');$('#gAmount').value=p.dataset.a;$('#gUnit').value=p.dataset.u;$('#gAmount').disabled=p.dataset.u==='permanent'}));
$('#gUnit')&&$('#gUnit').addEventListener('change',e=>{$('#gAmount').disabled=e.target.value==='permanent'});
$('#copyAll')&&$('#copyAll').addEventListener('click',()=>copyText($$('.keycard code').map(c=>c.textContent).join('\n')));
$('#dlAll')&&$('#dlAll').addEventListener('click',()=>{const t=$$('.keycard code').map(c=>c.textContent).join('\n');const a=document.createElement('a');a.href=URL.createObjectURL(new Blob([t],{type:'text/plain'}));a.download='keys.txt';a.click()});
$$('.keycard').forEach(k=>k.addEventListener('click',()=>copyText($('code',k).textContent)));
/* tabs de configuração */
const tabs=$$('.tab');if(tabs.length){const go=n=>{tabs.forEach(t=>t.classList.toggle('on',t.dataset.tab===n));$$('.pane').forEach(p=>p.classList.toggle('on',p.id==='pane-'+n));$$('input[name=tab]').forEach(i=>i.value=n)};
 tabs.forEach(t=>t.addEventListener('click',()=>{history.replaceState(null,'','#'+t.dataset.tab);go(t.dataset.tab)}));go((location.hash||'#geral').slice(1)||'geral');}
/* pré-visualização de cor */
function hexRgb(h){h=h.replace('#','');return [0,2,4].map(i=>parseInt(h.substr(i,2),16)).join(',')}
function setAccent(h){document.documentElement.style.setProperty('--accent',h);document.documentElement.style.setProperty('--accent-rgb',hexRgb(h))}
$$('.sw-c').forEach(s=>s.addEventListener('click',()=>{$$('.sw-c').forEach(x=>x.classList.remove('on'));s.classList.add('on');$('#accentInput').value=s.dataset.c;setAccent(s.dataset.c)}));
$('#accentInput')&&$('#accentInput').addEventListener('input',e=>{$$('.sw-c').forEach(x=>x.classList.remove('on'));setAccent(e.target.value)});
/* API tester */
const term=$('#term');
$$('[data-ping]').forEach(b=>b.addEventListener('click',async()=>{const u=b.dataset.ping;const t0=performance.now();term.innerHTML+=`<span class="p">$</span> GET ${u}\n`;
 try{const r=await fetch(u);const x=await r.text();term.innerHTML+=`${r.status} · ${Math.round(performance.now()-t0)}ms\n${x.replace(/</g,'&lt;').slice(0,300)}\n\n`}catch(e){term.innerHTML+='ERRO: '+e.message+'\n\n'}term.scrollTop=term.scrollHeight}));
$$('[data-copy]').forEach(b=>b.addEventListener('click',()=>copyText(b.dataset.copy,b)));
$('#clearTerm')&&$('#clearTerm').addEventListener('click',()=>term.innerHTML='');
/* dashboard: refresh ao vivo */
if($('[data-live]')){setInterval(async()=>{try{const r=await fetch('/panel/api/stats');if(!r.ok)return;const d=await r.json();$$('[data-live]').forEach(el=>{const v=d[el.dataset.live];if(v!==undefined&&+el.textContent!==v){el.dataset.count=v;countUp(el)}})}catch(e){}},30000)}
/* login: rede de partículas */
const cv=$('#net');
if(cv){const c=cv.getContext('2d');let w,h,P=[];const rgb=getComputedStyle(document.documentElement).getPropertyValue('--accent-rgb').trim()||'139,92,246';
 const rs=()=>{w=cv.width=innerWidth;h=cv.height=innerHeight;P=Array.from({length:Math.min(90,Math.floor(w*h/24000))},()=>({x:Math.random()*w,y:Math.random()*h,vx:(Math.random()-.5)*.5,vy:(Math.random()-.5)*.5}))};rs();addEventListener('resize',rs);
 let mx=-999,my=-999;addEventListener('mousemove',e=>{mx=e.clientX;my=e.clientY});
 (function f(){c.clearRect(0,0,w,h);P.forEach((p,i)=>{p.x+=p.vx;p.y+=p.vy;if(p.x<0||p.x>w)p.vx*=-1;if(p.y<0||p.y>h)p.vy*=-1;c.fillStyle=`rgba(${rgb},.7)`;c.beginPath();c.arc(p.x,p.y,1.4,0,7);c.fill();
  for(let j=i+1;j<P.length;j++){const q=P[j],d=Math.hypot(p.x-q.x,p.y-q.y);if(d<130){c.strokeStyle=`rgba(${rgb},${.28*(1-d/130)})`;c.beginPath();c.moveTo(p.x,p.y);c.lineTo(q.x,q.y);c.stroke()}}
  const dm=Math.hypot(p.x-mx,p.y-my);if(dm<170){c.strokeStyle=`rgba(255,255,255,${.4*(1-dm/170)})`;c.beginPath();c.moveTo(p.x,p.y);c.lineTo(mx,my);c.stroke()}});requestAnimationFrame(f)})()}
