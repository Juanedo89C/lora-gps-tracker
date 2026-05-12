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
    const el       = document.getElementById('device-list');
    const sel      = document.getElementById('target-device');
    const histSel  = document.getElementById('history-device-sel');
    const selected = sel.value;

    const devs = Object.values(deviceData);
    if (devs.length === 0) {
        el.innerHTML = '<div style="color:#64748b;font-size:.78rem">No devices seen yet.</div>';
        sel.innerHTML = '<option value="">— select —</option>';
        histSel.innerHTML = '<option value="">— select device —</option>';
        return;
    }

    el.innerHTML = devs.map(d => {
        const now     = Math.floor(Date.now() / 1000);
        const age     = now - (d.last_seen || 0);
        const online  = age < 120;
        const modeStr = MODE_LABELS[d.power_mode] || 'medium';
        const color   = getDeviceColor(d.device_eui);
        return `
        <div class="device-row">
          <div class="device-info">
            <div class="device-name">
              <span class="dot ${online ? 'online' : ''}"></span>
              <span style="color:${color}">${d.name || d.device_eui}</span>
            </div>
            <div class="device-meta">${d.device_eui} · ${age < 3600 ? age + 's ago' : 'offline'}</div>
          </div>
          <div class="mode-btns">
            ${['low', 'medium', 'high'].map(m => `
              <button class="mode-btn ${modeStr === m ? 'active-' + m : ''}"
                      onclick="setPowerMode('${d.device_eui}','${m}')">${m[0].toUpperCase()}</button>
            `).join('')}
          </div>
        </div>`;
    }).join('');

    const devOpts = devs.map(d =>
        `<option value="${d.device_eui}" ${d.device_eui === selected ? 'selected' : ''}>${d.name || d.device_eui}</option>`
    ).join('');
    sel.innerHTML     = '<option value="">— select —</option>' + devOpts;
    histSel.innerHTML = '<option value="">— select device —</option>' +
        devs.map(d => `<option value="${d.device_eui}">${d.name || d.device_eui}</option>`).join('');
}

function upsertDevice(info) {
    const eui = info.devEui || info.device_eui;
    deviceData[eui] = {
        device_eui: eui,
        name:       info.name || info.device_eui || eui,
        power_mode: info.power_mode ?? deviceData[eui]?.power_mode ?? 2,
        last_seen:  Math.floor(Date.now() / 1000),
    };
    renderDevices();
}

// ─── Message list UI ─────────────────────────────────────────────────────────
function addMessage(devEui, direction, body, tsMs) {
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
}

function escHtml(s) {
    return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

// ─── Send message ────────────────────────────────────────────────────────────
async function sendMessage() {
    const devEui  = document.getElementById('target-device').value;
    const message = document.getElementById('msg-input').value.trim();
    if (!devEui || !message) return;

    const btn = document.getElementById('send-btn');
    btn.disabled = true;
    btn.textContent = 'Sending…';

    try {
        const res = await fetch('/api/downlink', {
            method:  'POST',
            headers: { 'Content-Type': 'application/json' },
            body:    JSON.stringify({ devEui, message }),
        });
        const data = await res.json();
        if (data.ok) {
            document.getElementById('msg-input').value = '';
        } else {
            alert('Error: ' + (data.error || 'unknown'));
        }
    } catch (e) {
        alert('Network error: ' + e.message);
    } finally {
        btn.disabled = false;
        btn.textContent = 'Send';
    }
}

document.getElementById('msg-input').addEventListener('keydown', e => {
    if (e.key === 'Enter') sendMessage();
});

// ─── Set power mode ──────────────────────────────────────────────────────────
const MODE_IDS = { low: 1, medium: 2, high: 3 };

async function setPowerMode(devEui, mode) {
    const prevMode = deviceData[devEui]?.power_mode;

    // Optimistic update — show selection immediately
    if (deviceData[devEui]) {
        deviceData[devEui].power_mode = MODE_IDS[mode];
        renderDevices();
    }

    try {
        const res = await fetch('/api/power-mode', {
            method:  'POST',
            headers: { 'Content-Type': 'application/json' },
            body:    JSON.stringify({ devEui, mode }),
        });
        const data = await res.json();
        if (!data.ok) {
            // Revert on server error
            if (deviceData[devEui]) deviceData[devEui].power_mode = prevMode;
            renderDevices();
            alert('Error: ' + (data.error || 'unknown'));
        }
    } catch (e) {
        if (deviceData[devEui]) deviceData[devEui].power_mode = prevMode;
        renderDevices();
        alert('Network error: ' + e.message);
    }
}

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
            const { devEui, name, lat, lon } = msg.payload;
            upsertDevice({ devEui, name });
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

    const msgs = await fetch('/api/messages').then(r => r.json()).catch(() => []);
    msgs.reverse().forEach(m => addMessage(m.device_eui, m.direction, m.body, m.ts * 1000));
}

// ─── Auto-refresh every 5 seconds ────────────────────────────────────────────
setInterval(async () => {
    const devs = await fetch('/api/devices').then(r => r.json()).catch(() => []);
    devs.forEach(d => { deviceData[d.device_eui] = { ...deviceData[d.device_eui], ...d }; });
    renderDevices();
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
