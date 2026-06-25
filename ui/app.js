// Agent Status Lights — dashboard logic (vanilla JS)
'use strict';

const COLOR_KEYS = ['working','approval','done','error','idle','normal','off'];
const STATUS_DOT = {
  working:'#0982FC', approval:'#FC682A', done:'#00FF00',
  error:'#8D3EF9', idle:'#FEFEFF', normal:'#FEFEFF', off:'#444'
};

let currentConfig = {};

const $ = sel => document.querySelector(sel);
function log(msg){
  const el = $('#log');
  const t = new Date().toLocaleTimeString();
  el.textContent = `[${t}] ${msg}\n` + el.textContent;
}

async function api(path, opts){
  const r = await fetch(path, opts);
  return r.json();
}

function applyHero(state){
  const eff = (state && state.effective) || 'idle';
  const color = (state && state.color) || '#000000';
  const prov = (state && state.provider) || '—';
  $('#heroStatus').textContent = eff;
  $('#heroColor').textContent = color;
  $('#heroProvider').textContent = prov;
  $('#heroSwatch').style.background = color;
  $('#heroSwatch').style.boxShadow = `0 0 40px ${color}66, inset 0 0 0 2px rgba(255,255,255,.08)`;
  // session count
  let n = 0;
  if (state && state.sessions) n = Object.keys(state.sessions).length;
  $('#heroSessions').textContent = n;
  // pill
  $('#pillText').textContent = eff;
  $('#pillDot').style.background = STATUS_DOT[eff] || '#7F7F81';
  $('#pillDot').style.color = STATUS_DOT[eff] || '#7F7F81';
  $('#logoDot').style.filter = '';
  if (state && state.updated) $('#updatedAt').textContent = 'updated ' + new Date(state.updated).toLocaleTimeString();
}

function renderDevices(orgb){
  const box = $('#orgbStatus');
  const list = $('#devList');
  list.innerHTML = '';
  if (!orgb || !orgb.installed){
    box.innerHTML = `<b style="color:#FC682A">OpenRGB not installed</b><br><span class="muted">Running in fallback mode (console + notification + sound). Install OpenRGB and click Rescan.</span>`;
    return;
  }
  box.innerHTML = `<b style="color:#00FF00">OpenRGB found</b><br><code>${orgb.path||''}</code>`;
  const devs = orgb.devices || [];
  if (!devs.length){
    list.innerHTML = `<li><span class="muted">No devices listed yet — click Rescan, ensure the OpenRGB SDK server is running.</span></li>`;
    return;
  }
  devs.forEach(d=>{
    const li = document.createElement('li');
    li.innerHTML = `<span><span class="idx">#${d.index}</span> ${d.name}</span><button class="mini" data-idx="${d.index}">use</button>`;
    li.querySelector('button').onclick = ()=>{ $('#cfgDeviceIndex').value = d.idx; currentConfig.deviceIndex = d.index; $('#cfgDeviceIndex').value = d.index; log('device index set to '+d.index+' (remember to Save)'); };
    list.appendChild(li);
  });
}

function renderEvents(events){
  const box = $('#events');
  box.innerHTML = '';
  if (!events || !events.length){ box.innerHTML = '<span class="muted">No events yet. Trigger a status or run a test.</span>'; return; }
  events.slice().reverse().forEach(e=>{
    const div = document.createElement('div');
    div.className = 'evt';
    const c = STATUS_DOT[e.effective] || '#7F7F81';
    div.innerHTML = `
      <span class="ts">${new Date(e.ts).toLocaleTimeString()}</span>
      <span class="src">${e.source||''}</span>
      <span><span class="dot" style="background:${c};display:inline-block;margin-right:6px"></span>${e.requested} → <b>${e.effective}</b> ${e.message?('· '+e.message):''}</span>
      <span class="muted">${e.provider||''}</span>`;
    box.appendChild(div);
  });
}

function fillConfig(cfg){
  currentConfig = cfg || {};
  $('#cfgOpenRgbPath').value = cfg.openRgbPath || '';
  $('#cfgDeviceIndex').value = (cfg.deviceIndex ?? -1);
  $('#cfgDeviceName').value = cfg.deviceName || '';
  $('#cfgAllowAll').checked = !!cfg.allowAllDevices;
  $('#cfgNotify').checked = cfg.enableNotifications !== false;
  $('#cfgSounds').checked = cfg.enableSounds !== false;
  // colors
  const grid = $('#colorGrid'); grid.innerHTML = '';
  const colors = cfg.colors || {};
  COLOR_KEYS.forEach(k=>{
    const item = document.createElement('div');
    item.className = 'color-item';
    item.innerHTML = `<input type="color" value="${colors[k]||'#000000'}" data-key="${k}"><span>${k}</span>`;
    grid.appendChild(item);
  });
}

function gatherConfig(){
  const cfg = JSON.parse(JSON.stringify(currentConfig || {}));
  cfg.openRgbPath = $('#cfgOpenRgbPath').value.trim();
  cfg.deviceIndex = parseInt($('#cfgDeviceIndex').value, 10); if (isNaN(cfg.deviceIndex)) cfg.deviceIndex = -1;
  cfg.deviceName = $('#cfgDeviceName').value.trim();
  cfg.allowAllDevices = $('#cfgAllowAll').checked;
  cfg.enableNotifications = $('#cfgNotify').checked;
  cfg.enableSounds = $('#cfgSounds').checked;
  cfg.colors = cfg.colors || {};
  document.querySelectorAll('#colorGrid input[type=color]').forEach(inp=>{
    cfg.colors[inp.dataset.key] = inp.value;
  });
  return cfg;
}

async function refresh(){
  try{
    const data = await api('/api/state');
    applyHero(data.state);
    renderDevices(data.openrgb);
    renderEvents(data.events);
    if (!document.activeElement || !document.activeElement.closest('.cfg-grid')) fillConfig(data.config);
    $('#footEnv').textContent = `TERM_PROGRAM=${data.env.TERM_PROGRAM||'?'}  provider=${data.provider}`;
  }catch(e){ log('refresh failed: '+e); }
}

// ---- wire up ----
document.querySelectorAll('.btn[data-status]').forEach(b=>{
  b.onclick = async ()=>{
    const status = b.dataset.status;
    log('set status → '+status);
    await api('/api/status', {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({status})});
    setTimeout(refresh, 300);
  };
});

$('#btnTest').onclick = async ()=>{ log('running full test… (watch console window)'); await api('/api/test',{method:'POST'}); log('test finished'); refresh(); };
$('#btnDevices').onclick = async ()=>{ log('rescanning devices…'); const d = await api('/api/devices'); renderDevices(d); };
$('#btnRefresh').onclick = refresh;

$('#btnInstall').onclick = async ()=>{
  const target = $('#installTarget').value;
  if(!confirm('Install status-light hooks into '+target+' config? Files are backed up first.')) return;
  log('installing hooks ('+target+')…');
  const r = await api('/api/install',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({target})});
  log(r.out || r.err || 'done');
};
$('#btnPlan').onclick = async ()=>{
  const target = $('#installTarget').value;
  log('dry-run install ('+target+')…');
  const r = await api('/api/install',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({target,plan:true})});
  log(r.out || r.err || 'done');
};
$('#btnUninstall').onclick = async ()=>{
  const target = $('#installTarget').value;
  if(!confirm('Remove status-light hooks from '+target+' config?')) return;
  log('uninstalling ('+target+')…');
  const r = await api('/api/uninstall',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({target})});
  log(r.out || r.err || 'done');
};

$('#btnSave').onclick = async ()=>{
  const cfg = gatherConfig();
  const r = await api('/api/config',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(cfg)});
  $('#saveMsg').textContent = r.ok ? 'saved ✓' : ('error: '+r.error);
  log('config saved');
  currentConfig = cfg;
  setTimeout(()=>$('#saveMsg').textContent='', 2500);
};

refresh();
setInterval(refresh, 4000);
