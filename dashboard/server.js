'use strict';

const express = require('express');
const mqtt    = require('mqtt');
const Database = require('better-sqlite3');
const { WebSocketServer } = require('ws');
const http    = require('http');
const path    = require('path');
const fetch   = (...args) => import('node-fetch').then(m => m.default(...args));

// ─── Config (edit these) ──────────────────────────────────────────────────────
const CONFIG = {
    mqttUrl:         'mqtt://localhost:1883',
    chirpstackUrl:   'http://localhost:8080',
    chirpstackToken: process.env.CHIRPSTACK_API_TOKEN || 'YOUR_API_TOKEN_HERE',
    dashboardPort:   3000,
};

// ─── Database ─────────────────────────────────────────────────────────────────
const db = new Database(path.join(__dirname, 'tracker.db'));

db.exec(`
    CREATE TABLE IF NOT EXISTS gps_points (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        device_eui TEXT    NOT NULL,
        lat        REAL    NOT NULL,
        lon        REAL    NOT NULL,
        alt        REAL    NOT NULL DEFAULT 0,
        ts         INTEGER NOT NULL DEFAULT (unixepoch())
    );
    CREATE TABLE IF NOT EXISTS messages (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        device_eui TEXT    NOT NULL,
        direction  TEXT    NOT NULL,
        body       TEXT    NOT NULL,
        ts         INTEGER NOT NULL DEFAULT (unixepoch())
    );
    CREATE TABLE IF NOT EXISTS device_state (
        device_eui TEXT    PRIMARY KEY,
        name       TEXT,
        power_mode INTEGER NOT NULL DEFAULT 2,
        last_seen  INTEGER NOT NULL DEFAULT 0,
        battery    INTEGER NOT NULL DEFAULT 0,
        satellites INTEGER NOT NULL DEFAULT 0,
        rssi       INTEGER NOT NULL DEFAULT 0
    );
`);

// Migrate existing databases that are missing the new columns
for (const col of ['battery INTEGER NOT NULL DEFAULT 0',
                    'satellites INTEGER NOT NULL DEFAULT 0',
                    'rssi INTEGER NOT NULL DEFAULT 0']) {
    try { db.exec(`ALTER TABLE device_state ADD COLUMN ${col}`); } catch {}
}

// Prepared statements
const stmtInsertGps = db.prepare(
    'INSERT INTO gps_points (device_eui, lat, lon, alt) VALUES (?, ?, ?, ?)'
);
const stmtInsertMsg = db.prepare(
    'INSERT INTO messages (device_eui, direction, body) VALUES (?, ?, ?)'
);
const stmtUpsertDevice = db.prepare(`
    INSERT INTO device_state (device_eui, name, power_mode, last_seen)
    VALUES (?, ?, ?, unixepoch())
    ON CONFLICT(device_eui) DO UPDATE SET
        name       = excluded.name,
        last_seen  = excluded.last_seen
`);
const stmtUpdateMode = db.prepare(
    'UPDATE device_state SET power_mode = ? WHERE device_eui = ?'
);
const stmtUpdateTelemetry = db.prepare(
    'UPDATE device_state SET rssi = ?, battery = ?, satellites = ? WHERE device_eui = ?'
);

// ─── WebSocket broadcast ──────────────────────────────────────────────────────
let wss;
function broadcast(type, payload) {
    const msg = JSON.stringify({ type, payload });
    if (!wss) return;
    wss.clients.forEach(client => {
        if (client.readyState === 1) client.send(msg);
    });
}

// ─── Payload decoder (mirrors firmware payload.cpp) ──────────────────────────
// v1: type(1)+lat(4)+lon(4)+alt(2)+mode(1)+msg(0-50)              = 12+ bytes
// v2: type(1)+lat(4)+lon(4)+alt(2)+mode(1)+battery(1)+sats(1)+msg = 14+ bytes
function decodePayload(base64data) {
    let buf;
    try { buf = Buffer.from(base64data, 'base64'); } catch { return null; }
    if (buf.length < 1) return null;

    const type     = buf[0];
    const hasGps   = (type === 0x01 || type === 0x03);
    const hasMsg   = (type === 0x02 || type === 0x03);
    const isNewFmt = buf.length >= 14;
    const obj      = {};

    if (hasGps && buf.length >= 11) {
        obj.latitude  = buf.readInt32BE(1) / 10000.0;
        obj.longitude = buf.readInt32BE(5) / 10000.0;
        obj.altitude  = buf.readUInt16BE(9);
    }
    if (buf.length > 11) obj.powerMode = buf[11];
    if (isNewFmt) {
        obj.battery    = buf[12];  // Vbat * 50; decode: voltage = val/50
        obj.satellites = buf[13];
    }
    const msgOffset = isNewFmt ? 14 : 12;
    if (hasMsg && buf.length > msgOffset) obj.message = buf.slice(msgOffset).toString('utf8');

    return obj;
}

// ─── ChirpStack MQTT uplink handler ──────────────────────────────────────────
function handleUplink(topic, raw) {
    let envelope;
    try { envelope = JSON.parse(raw); } catch { return; }

    const devEui = envelope?.deviceInfo?.devEui;
    if (!devEui) return;

    // Decode raw bytes directly — bypasses any broken ChirpStack codec
    const obj = envelope.data ? decodePayload(envelope.data) : envelope.object;
    if (!obj) return;

    const name       = envelope?.deviceInfo?.deviceName || devEui;
    const rssi       = envelope?.rxInfo?.[0]?.rssi ?? 0;
    const battery    = obj.battery    ?? 0;
    const satellites = obj.satellites ?? 0;

    stmtUpsertDevice.run(devEui, name, 2);
    stmtUpdateTelemetry.run(rssi, battery, satellites, devEui);

    // GPS data
    if (obj.latitude != null && obj.longitude != null) {
        const lat = obj.latitude;
        const lon = obj.longitude;
        const alt = obj.altitude || 0;
        console.log(`[uplink] GPS ${devEui} lat=${lat} lon=${lon} alt=${alt} rssi=${rssi} batt=${battery} sats=${satellites}`);
        stmtInsertGps.run(devEui, lat, lon, alt);
        broadcast('gps', { devEui, name, lat, lon, alt, rssi, battery, satellites, ts: Date.now() });
    }

    // Text message
    if (obj.message) {
        stmtInsertMsg.run(devEui, 'up', obj.message);
        broadcast('message', { devEui, name, direction: 'up', body: obj.message, ts: Date.now() });
    }

    // Power mode echo intentionally ignored here — the DB is updated immediately
    // when a command is sent, and uplink echoes arrive before the device receives
    // the downlink, which would revert the UI back to the old mode.
}

// ─── MQTT client ─────────────────────────────────────────────────────────────
const mqttClient = mqtt.connect(CONFIG.mqttUrl);
mqttClient.on('connect', () => {
    console.log('MQTT connected');
    mqttClient.subscribe('application/+/device/+/event/up');
});
mqttClient.on('message', (topic, buf) => {
    if (topic.endsWith('/event/up')) handleUplink(topic, buf.toString());
});
mqttClient.on('error', err => console.error('MQTT error:', err.message));

// ─── gRPC-web helpers ────────────────────────────────────────────────────────
function pbVarint(v) {
    const b = [];
    while (v > 0x7F) { b.push((v & 0x7F) | 0x80); v >>>= 7; }
    b.push(v & 0x7F);
    return Buffer.from(b);
}
function pbString(field, s) {
    const b = Buffer.from(s, 'utf8');
    return Buffer.concat([pbVarint((field << 3) | 2), pbVarint(b.length), b]);
}
function pbBytes(field, b) {
    b = Buffer.isBuffer(b) ? b : Buffer.from(b);
    return Buffer.concat([pbVarint((field << 3) | 2), pbVarint(b.length), b]);
}
function pbUint32(field, v) {
    return Buffer.concat([pbVarint((field << 3) | 0), pbVarint(v)]);
}
function grpcWebFrame(msg) {
    const hdr = Buffer.alloc(5);
    hdr[0] = 0;
    hdr.writeUInt32BE(msg.length, 1);
    return Buffer.concat([hdr, msg]);
}

// ─── ChirpStack downlink helper (gRPC-web) ───────────────────────────────────
async function sendDownlink(devEui, fPort, bytesArr) {
    // DeviceQueueItem fields (ChirpStack v4): id=1 (skip), dev_eui=2, confirmed=3, f_port=4, data=5
    const queueItem = Buffer.concat([
        pbString(2, devEui),
        pbUint32(3, 0),
        pbUint32(4, fPort),
        pbBytes(5, Buffer.from(bytesArr)),
    ]);
    const body = grpcWebFrame(pbBytes(1, queueItem));

    console.log('[downlink] →', devEui, 'fPort', fPort, 'len', bytesArr.length);
    const res = await fetch(`${CONFIG.chirpstackUrl}/api.DeviceService/Enqueue`, {
        method:  'POST',
        headers: {
            'Content-Type': 'application/grpc-web+proto',
            'authorization': `Bearer ${CONFIG.chirpstackToken}`,
            'x-grpc-web': '1',
        },
        body,
    });
    if (!res.ok) {
        const text = await res.text();
        throw new Error(`ChirpStack HTTP ${res.status}: ${text}`);
    }

    // gRPC-web always returns HTTP 200; real errors live in trailer frames (flag byte 0x80)
    const buf = Buffer.from(await res.arrayBuffer());
    let offset = 0;
    while (offset + 5 <= buf.length) {
        const flags    = buf[offset];
        const frameLen = buf.readUInt32BE(offset + 1);
        offset += 5;
        if (offset + frameLen > buf.length) break;
        if (flags & 0x80) {
            const trailerFields = {};
            buf.slice(offset, offset + frameLen).toString('utf8')
                .split(/\r?\n/)
                .forEach(line => {
                    const colon = line.indexOf(':');
                    if (colon > 0) trailerFields[line.slice(0, colon).trim().toLowerCase()] = line.slice(colon + 1).trim();
                });
            const status = trailerFields['grpc-status'];
            if (status && status !== '0') {
                const message = trailerFields['grpc-message'] || '';
                console.error('[downlink] gRPC error', status, message, devEui);
                throw new Error(`gRPC ${status}: ${decodeURIComponent(message)}`);
            }
        }
        offset += frameLen;
    }

    console.log('[downlink] ✓', devEui);
    return { ok: true };
}

// ─── Express API ──────────────────────────────────────────────────────────────
const app = express();
app.use(express.json());
app.use(express.static(path.join(__dirname, 'public'), {
    setHeaders: (res, filePath) => {
        if (filePath.endsWith('.html') || filePath.endsWith('.js')) {
            res.setHeader('Cache-Control', 'no-store, must-revalidate');
            res.setHeader('Pragma', 'no-cache');
            res.setHeader('Expires', '0');
        }
    },
}));

// List devices
app.get('/api/devices', (_req, res) => {
    const rows = db.prepare(
        'SELECT device_eui, name, power_mode, last_seen, battery, satellites, rssi FROM device_state ORDER BY last_seen DESC'
    ).all();
    res.json(rows);
});

// GPS history for one device (last 500 points)
app.get('/api/gps/:devEui', (req, res) => {
    const rows = db.prepare(
        'SELECT lat, lon, alt, ts FROM gps_points WHERE device_eui = ? ORDER BY ts ASC LIMIT 500'
    ).all(req.params.devEui);
    res.json(rows);
});

// All messages (newest first)
app.get('/api/messages', (_req, res) => {
    const rows = db.prepare(
        'SELECT m.*, d.name FROM messages m LEFT JOIN device_state d USING(device_eui) ORDER BY m.ts DESC LIMIT 200'
    ).all();
    res.json(rows);
});

// Google Maps API key for the frontend
app.get('/api/config', (_req, res) => {
    res.json({ googleMapsKey: process.env.GOOGLE_MAPS_KEY || '' });
});

// Send text downlink to a device
app.post('/api/downlink', async (req, res) => {
    const { devEui, message } = req.body;
    if (!devEui || !message) return res.status(400).json({ error: 'devEui and message required' });
    try {
        const bytes = [0x10, ...Buffer.from(message.slice(0, 50))];
        await sendDownlink(devEui, 10, bytes);
        stmtInsertMsg.run(devEui, 'down', message);
        broadcast('message', { devEui, direction: 'down', body: message, ts: Date.now() });
        res.json({ ok: true });
    } catch (e) {
        res.status(500).json({ error: e.message });
    }
});

// Set power mode on a device
const POWER_MODES = { low: 0x01, medium: 0x02, high: 0x03 };
app.post('/api/power-mode', async (req, res) => {
    const { devEui, mode } = req.body;
    if (!devEui || !POWER_MODES[mode]) {
        return res.status(400).json({ error: 'devEui and mode (low|medium|high) required' });
    }
    try {
        const modeId = POWER_MODES[mode];
        await sendDownlink(devEui, 11, [0x20, modeId]);
        stmtUpdateMode.run(modeId, devEui);
        broadcast('powerMode', { devEui, mode: modeId });
        res.json({ ok: true });
    } catch (e) {
        res.status(500).json({ error: e.message });
    }
});

// ─── HTTP + WebSocket server ──────────────────────────────────────────────────
const server = http.createServer(app);
wss = new WebSocketServer({ server });
wss.on('connection', ws => {
    ws.on('error', () => {});
});

server.listen(CONFIG.dashboardPort, () => {
    console.log(`Dashboard running at http://localhost:${CONFIG.dashboardPort}`);
    console.log(`ChirpStack: ${CONFIG.chirpstackUrl}`);
});
