'use strict';

// google.maps is already loaded when this script runs (injected via _mapsReady callback)

// ─── Main map ─────────────────────────────────────────────────────────────────
const mainMap = new google.maps.Map(document.getElementById('map'), {
    mapTypeId: 'roadmap',
    zoom: 2,
    center: { lat: 20, lng: 0 },
});

// ─── History map ──────────────────────────────────────────────────────────────
const historyMap = new google.maps.Map(document.getElementById('history-map'), {
    mapTypeId: 'roadmap',
    zoom: 2,
    center: { lat: 20, lng: 0 },
});

// Per-device track state
const deviceTracks = {};
let historyPolyline = null;
let historyMarkers  = [];

const DEVICE_COLORS = ['#60a5fa', '#f472b6', '#34d399', '#fbbf24', '#a78bfa'];
let colorIdx = 0;

function getDeviceColor(devEui) {
    if (!deviceTracks[devEui]) initDeviceTrack(devEui);
    return deviceTracks[devEui].color;
}

function initDeviceTrack(devEui) {
    const color = DEVICE_COLORS[colorIdx++ % DEVICE_COLORS.length];
    const polyline = new google.maps.Polyline({
        path: [], strokeColor: color, strokeWeight: 3, strokeOpacity: 0.8, map: mainMap,
    });
    deviceTracks[devEui] = { polyline, marker: null, points: [], color };
}

function addGpsPoint(devEui, lat, lon) {
    if (!deviceTracks[devEui]) initDeviceTrack(devEui);
    const track  = deviceTracks[devEui];
    const latlng = { lat, lng: lon };
    track.points.push(latlng);
    track.polyline.setPath(track.points);

    if (!track.marker) {
        track.marker = new google.maps.Marker({
            position: latlng,
            map: mainMap,
            title: devEui,
            icon: {
                path: google.maps.SymbolPath.CIRCLE,
                scale: 7,
                fillColor: track.color,
                fillOpacity: 1,
                strokeColor: '#ffffff',
                strokeWeight: 2,
            },
        });
    } else {
        track.marker.setPosition(latlng);
    }

    if (track.points.length === 1) {
        mainMap.setCenter(latlng);
        mainMap.setZoom(15);
    }
}

// ─── Device list UI ───────────────────────────────────────────────────────────
const deviceData = {};
const MODE_LABELS = { 1: 'low', 2: 'medium', 3: 'high' };

function renderDevices() {
    const el      = document.getElementById('device-list');
    const histSel = document.getElementById('history-device-sel');

    const devs = Object.values(deviceData);
    if (devs.length === 0) {
        el.innerHTML = '<div style="color:#64748b;font-size:.78rem">No devices seen yet.</div>';
        histSel.innerHTML = '<option value="">— select device —</option>';
        return;
    }

    el.innerHTML = devs.map(d => {
        const now     = Math.floor(Date.now() / 1000);
        const age     = now - (d.last_seen || 0);
        const online  = age < 120;
        const color   = getDeviceColor(d.device_eui);
        const modeStr = MODE_LABELS[d.power_mode] || 'medium';
        return `
        <div class="device-row" onclick="openDeviceModal('${d.device_eui}')">
          <div class="device-info">
            <div class="device-name">
              <span class="dot ${online ? 'online' : ''}"></span>
              <span style="color:${color}">${d.name || d.device_eui}</span>
            </div>
            <div class="device-meta">${modeStr} · ${age < 3600 ? age + 's ago' : 'offline'}</div>
          </div>
          <span class="device-chevron">›</span>
        </div>`;
    }).join('');

    histSel.innerHTML = '<option value="">— select device —</option>' +
        devs.map(d => `<option value="${d.device_eui}">${d.name || d.device_eui}</option>`).join('');
}

function upsertDevice(info) {
    const eui = info.devEui || info.device_eui;
    deviceData[eui] = {
        device_eui: eui,
        name:       info.name || info.device_eui || eui,
        power_mode: info.power_mode  ?? deviceData[eui]?.power_mode  ?? 2,
        last_seen:  info.last_seen   ?? Math.floor(Date.now() / 1000),
        battery:    info.battery     ?? deviceData[eui]?.battery     ?? 0,
        satellites: info.satellites  ?? deviceData[eui]?.satellites  ?? 0,
        rssi:       info.rssi        ?? deviceData[eui]?.rssi        ?? 0,
    };
    renderDevices();
}

// ─── Device detail modal ──────────────────────────────────────────────────────
let currentModalEui = null;
const lastMessages  = {};

function openDeviceModal(devEui) {
    currentModalEui = devEui;
    renderModal();
    document.getElementById('device-modal').classList.add('open');
    document.getElementById('modal-backdrop').classList.add('open');
    setTimeout(() => document.getElementById('modal-msg-input').focus(), 280);
}

function closeDeviceModal() {
    currentModalEui = null;
    document.getElementById('device-modal').classList.remove('open');
    document.getElementById('modal-backdrop').classList.remove('open');
}

function renderModal() {
    if (!currentModalEui) return;
    const devEui  = currentModalEui;
    const d       = deviceData[devEui];
    if (!d) return;

    const now     = Math.floor(Date.now() / 1000);
    const age     = now - (d.last_seen || 0);
    const online  = age < 120;
    const color   = getDeviceColor(devEui);
    const modeStr = MODE_LABELS[d.power_mode] || 'medium';

    document.getElementById('modal-dev-name').innerHTML =
        `<span class="dot ${online ? 'online' : ''}"></span><span style="color:${color}">${d.name || devEui}</span>`;
    document.getElementById('modal-dev-eui').textContent = devEui;

    document.getElementById('modal-mode-btns').innerHTML =
        ['low', 'medium', 'high'].map(m => `
            <button class="mode-btn ${modeStr === m ? 'active-' + m : ''}"
                    onclick="setPowerMode('${devEui}','${m}')">
                ${m[0].toUpperCase() + m.slice(1)}
            </button>
        `).join('');

    // Telemetry
    const teleEl = document.getElementById('modal-telemetry-grid');
    let teleHtml = '';
    const battery    = d.battery    || 0;
    const satellites = d.satellites || 0;
    const rssi       = d.rssi       || 0;

    if (battery > 0) {
        const vbat    = battery / 50.0;
        const pct     = Math.max(0, Math.min(100, Math.round((vbat - 3.0) / (4.2 - 3.0) * 100)));
        const barClr  = pct > 50 ? '#22c55e' : pct > 20 ? '#f59e0b' : '#ef4444';
        teleHtml += `<div class="tele-row">
            <div class="tele-label"><span>Battery</span><span class="tele-val">${vbat.toFixed(2)} V &middot; ${pct}%</span></div>
            <div class="tele-bar-bg"><div class="tele-bar" style="width:${pct}%;background:${barClr}"></div></div>
        </div>`;
    }
    if (satellites > 0) {
        const satClr = satellites >= 4 ? '#22c55e' : satellites >= 2 ? '#f59e0b' : '#ef4444';
        teleHtml += `<div class="tele-row">
            <div class="tele-label"><span>Satellites</span><span class="tele-val" style="color:${satClr}">${satellites}</span></div>
        </div>`;
    }
    if (rssi !== 0) {
        const rssiPct = Math.max(0, Math.min(100, rssi + 150));
        const rssiClr = rssiPct > 60 ? '#22c55e' : rssiPct > 30 ? '#f59e0b' : '#ef4444';
        teleHtml += `<div class="tele-row">
            <div class="tele-label"><span>RSSI</span><span class="tele-val">${rssi} dBm &middot; ${rssiPct}%</span></div>
            <div class="tele-bar-bg"><div class="tele-bar" style="width:${rssiPct}%;background:${rssiClr}"></div></div>
        </div>`;
    }
    teleEl.innerHTML = teleHtml || '<div style="color:#475569;font-size:.75rem">No telemetry yet.</div>';

    const lm   = lastMessages[devEui];
    const lmEl = document.getElementById('modal-last-msg');
    if (lm) {
        const time = new Date(lm.ts).toLocaleTimeString();
        lmEl.className = 'modal-last-msg ' + lm.direction;
        lmEl.innerHTML = `<div class="meta"><span>${lm.direction === 'up' ? '↑ From device' : '↓ To device'}</span><span>${time}</span></div><div>${escHtml(lm.body)}</div>`;
    } else {
        lmEl.className = 'modal-last-msg';
        lmEl.textContent = 'No messages yet.';
    }
}

// ─── Message list UI ─────────────────────────────────────────────────────────
function addMessage(devEui, direction, body, tsMs, skipOverlay = false) {
    const el   = document.getElementById('msg-list');
    const time = new Date(tsMs).toLocaleTimeString();
    const name = deviceData[devEui]?.name || devEui;
    const item = document.createElement('div');
    item.className = `msg-item ${direction}`;
    item.innerHTML = `
        <div class="meta">
            <span>${direction === 'up' ? '↑' : '↓'} ${name}</span>
            <span>${time}</span>
        </div>
        <div>${escHtml(body)}</div>`;
    el.prepend(item);
    while (el.children.length > 100) el.removeChild(el.lastChild);

    // Track last message per device and update modal if open
    lastMessages[devEui] = { direction, body, ts: tsMs };
    if (currentModalEui === devEui) renderModal();

    // Update persistent map overlay (skip for historical bulk-load)
    if (!skipOverlay) {
        document.getElementById('om-dir').textContent    = direction === 'up' ? '↑' : '↓';
        document.getElementById('om-device').textContent = name;
        document.getElementById('om-time').textContent   = time;
        document.getElementById('om-body').textContent   = body;
        document.getElementById('map-msg-overlay').style.display = 'block';
    }
}

function escHtml(s) {
    return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

// ─── Send message from modal ──────────────────────────────────────────────────
async function sendFromModal() {
    if (!currentModalEui) return;
    const input   = document.getElementById('modal-msg-input');
    const message = input.value.trim();
    if (!message) return;

    const btn = document.getElementById('modal-send-btn');
    btn.disabled    = true;
    btn.textContent = 'Sending…';

    try {
        const res  = await fetch('/api/downlink', {
            method:  'POST',
            headers: { 'Content-Type': 'application/json' },
            body:    JSON.stringify({ devEui: currentModalEui, message }),
        });
        const data = await res.json();
        if (data.ok) {
            input.value = '';
        } else {
            alert('Error: ' + (data.error || 'unknown'));
        }
    } catch (e) {
        alert('Network error: ' + e.message);
    } finally {
        btn.disabled    = false;
        btn.textContent = 'Send';
    }
}

document.getElementById('modal-msg-input').addEventListener('keydown', e => {
    if (e.key === 'Enter') sendFromModal();
});

// ─── Set power mode ──────────────────────────────────────────────────────────
const MODE_IDS = { low: 1, medium: 2, high: 3 };

async function setPowerMode(devEui, mode) {
    const prevMode = deviceData[devEui]?.power_mode;

    if (deviceData[devEui]) {
        deviceData[devEui].power_mode = MODE_IDS[mode];
        renderDevices();
        if (currentModalEui === devEui) renderModal();
    }

    try {
        const res  = await fetch('/api/power-mode', {
            method:  'POST',
            headers: { 'Content-Type': 'application/json' },
            body:    JSON.stringify({ devEui, mode }),
        });
        const data = await res.json();
        if (!data.ok) {
            if (deviceData[devEui]) deviceData[devEui].power_mode = prevMode;
            renderDevices();
            if (currentModalEui === devEui) renderModal();
            alert('Error: ' + (data.error || 'unknown'));
        }
    } catch (e) {
        if (deviceData[devEui]) deviceData[devEui].power_mode = prevMode;
        renderDevices();
        if (currentModalEui === devEui) renderModal();
        alert('Network error: ' + e.message);
    }
}

// ─── Fullscreen toggle ────────────────────────────────────────────────────────
function toggleFullscreen(containerId) {
    const el = document.getElementById(containerId);
    if (!document.fullscreenElement) {
        el.requestFullscreen().catch(err => console.warn('Fullscreen:', err));
    } else {
        document.exitFullscreen();
    }
}

document.addEventListener('fullscreenchange', () => {
    setTimeout(() => {
        google.maps.event.trigger(mainMap, 'resize');
        google.maps.event.trigger(historyMap, 'resize');
    }, 150);
});

// ─── WebSocket for real-time updates ─────────────────────────────────────────
const badge = document.getElementById('conn-badge');

function connect() {
    const ws = new WebSocket(`ws://${location.host}`);

    ws.onopen = () => {
        badge.textContent = 'Connected';
        badge.classList.add('connected');
    };
    ws.onclose = () => {
        badge.textContent = 'Reconnecting…';
        badge.classList.remove('connected');
        setTimeout(connect, 3000);
    };
    ws.onerror = () => ws.close();

    ws.onmessage = evt => {
        let msg;
        try { msg = JSON.parse(evt.data); } catch { return; }

        if (msg.type === 'gps') {
            const { devEui, name, lat, lon, rssi, battery, satellites } = msg.payload;
            upsertDevice({ devEui, name, rssi, battery, satellites });
            addGpsPoint(devEui, lat, lon);
        }
        if (msg.type === 'message') {
            const { devEui, direction, body, ts } = msg.payload;
            addMessage(devEui, direction, body, ts);
        }
        if (msg.type === 'powerMode') {
            const { devEui, mode } = msg.payload;
            if (deviceData[devEui]) {
                deviceData[devEui].power_mode = mode;
                renderDevices();
                if (currentModalEui === devEui) renderModal();
            }
        }
    };
}

// ─── Load existing data on page open ─────────────────────────────────────────
async function loadInitialData() {
    const devs = await fetch('/api/devices').then(r => r.json()).catch(() => []);
    devs.forEach(d => {
        deviceData[d.device_eui] = d;
        initDeviceTrack(d.device_eui);
    });
    renderDevices();

    for (const d of devs) {
        const pts = await fetch(`/api/gps/${d.device_eui}`).then(r => r.json()).catch(() => []);
        pts.forEach(p => addGpsPoint(d.device_eui, p.lat, p.lon));
    }

    // Load message history without updating the map overlay for each item
    const msgs = await fetch('/api/messages').then(r => r.json()).catch(() => []);
    msgs.reverse().forEach(m => addMessage(m.device_eui, m.direction, m.body, m.ts * 1000, true));

    // Show the single most-recent message in the overlay (msgs comes newest-first from API)
    if (msgs.length > 0) {
        const latest = msgs[0];
        const name   = deviceData[latest.device_eui]?.name || latest.device_eui;
        document.getElementById('om-dir').textContent    = latest.direction === 'up' ? '↑' : '↓';
        document.getElementById('om-device').textContent = name;
        document.getElementById('om-time').textContent   = new Date(latest.ts * 1000).toLocaleTimeString();
        document.getElementById('om-body').textContent   = latest.body;
        document.getElementById('map-msg-overlay').style.display = 'block';
    }
}

// ─── Auto-refresh every 5 seconds ────────────────────────────────────────────
setInterval(async () => {
    const devs = await fetch('/api/devices').then(r => r.json()).catch(() => []);
    devs.forEach(d => { deviceData[d.device_eui] = { ...deviceData[d.device_eui], ...d }; });
    renderDevices();
    if (currentModalEui) renderModal();
}, 5000);

// ─── GPS Track History panel ──────────────────────────────────────────────────
async function loadDeviceHistory() {
    const devEui = document.getElementById('history-device-sel').value;
    if (!devEui) return;

    if (historyPolyline) { historyPolyline.setMap(null); historyPolyline = null; }
    historyMarkers.forEach(m => m.setMap(null));
    historyMarkers = [];
    document.getElementById('history-stats').textContent = 'Loading…';

    const pts = await fetch(`/api/gps/${devEui}`).then(r => r.json()).catch(() => []);
    if (pts.length === 0) {
        document.getElementById('history-stats').textContent = 'No GPS data for this device.';
        return;
    }

    const path = pts.map(p => ({ lat: p.lat, lng: p.lon }));

    historyPolyline = new google.maps.Polyline({
        path,
        strokeColor: '#60a5fa',
        strokeWeight: 3,
        strokeOpacity: 0.9,
        map: historyMap,
    });

    historyMarkers.push(new google.maps.Marker({
        position: path[0],
        map: historyMap,
        title: 'Start',
        label: { text: 'S', color: '#fff', fontSize: '10px', fontWeight: 'bold' },
        icon: {
            path: google.maps.SymbolPath.CIRCLE,
            scale: 8,
            fillColor: '#22c55e',
            fillOpacity: 1,
            strokeColor: '#fff',
            strokeWeight: 2,
        },
    }));
    historyMarkers.push(new google.maps.Marker({
        position: path[path.length - 1],
        map: historyMap,
        title: 'End',
        label: { text: 'E', color: '#fff', fontSize: '10px', fontWeight: 'bold' },
        icon: {
            path: google.maps.SymbolPath.CIRCLE,
            scale: 8,
            fillColor: '#ef4444',
            fillOpacity: 1,
            strokeColor: '#fff',
            strokeWeight: 2,
        },
    }));

    const bounds = new google.maps.LatLngBounds();
    path.forEach(p => bounds.extend(p));
    historyMap.fitBounds(bounds);

    const tStart = new Date(pts[0].ts * 1000).toLocaleString();
    const tEnd   = new Date(pts[pts.length - 1].ts * 1000).toLocaleString();
    document.getElementById('history-stats').textContent =
        `${pts.length} points · ${tStart} → ${tEnd}`;
}

// ─── Start ────────────────────────────────────────────────────────────────────
loadInitialData();
connect();
