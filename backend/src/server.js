import 'dotenv/config';
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import cors from 'cors';
import express from 'express';
import { Server } from 'socket.io';
import { migrate, pool, query } from './db.js';
import { colorFor, haversine, toCsv, toGpx } from './geo.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const PORT = Number(process.env.PORT || 8080);
const DEVICE_API_KEY = process.env.DEVICE_API_KEY || 'dev-device-key';
const DASHBOARD_TOKEN = process.env.DASHBOARD_TOKEN || 'dev-dashboard-token';
// Dashboard abierto: cualquiera con la URL ve el panel sin token
const DASHBOARD_PUBLIC = process.env.DASHBOARD_PUBLIC === 'true';
const OFFLINE_AFTER_SEC = Number(process.env.OFFLINE_AFTER_SEC || 120);
const LOW_BATTERY = 15;
// Lecturas con peor precisión (Wi-Fi/antenas) se ocultan en mapas y estadísticas: la app ya no las envía,
// pero las rutas antiguas sí las tienen y aparecen como saltos.
const MAX_ACCURACY_M = 40;

const app = express();
app.use(cors());
app.use(express.json({ limit: '5mb' }));

const server = http.createServer(app);
const io = new Server(server, { cors: { origin: '*' } });

// ---------------------------------------------------------------- auth
const requireDevice = (req, res, next) =>
  req.get('x-api-key') === DEVICE_API_KEY ? next() : res.status(401).json({ error: 'unauthorized' });

const requireDashboard = (req, res, next) => {
  if (DASHBOARD_PUBLIC) return next();
  const token = (req.get('authorization') || '').replace(/^Bearer /, '') || req.query.token;
  return token === DASHBOARD_TOKEN ? next() : res.status(401).json({ error: 'unauthorized' });
};

io.use((socket, next) =>
  DASHBOARD_PUBLIC || socket.handshake.auth?.token === DASHBOARD_TOKEN ? next() : next(new Error('unauthorized')),
);

app.get('/api/config', (_req, res) => res.json({ public: DASHBOARD_PUBLIC }));

const wrap = (fn) => (req, res, next) => fn(req, res, next).catch(next);

// ---------------------------------------------------------------- helpers
async function getDevice(id) {
  const { rows } = await query('SELECT * FROM devices WHERE id = $1', [id]);
  return rows[0];
}

async function createAlert(device, type, message, lat, lng) {
  const { rows } = await query(
    `INSERT INTO alerts (device_id, type, message, lat, lng) VALUES ($1,$2,$3,$4,$5) RETURNING *`,
    [device.id, type, message, lat ?? null, lng ?? null],
  );
  const alert = { ...rows[0], device_name: device.name, device_color: device.color };
  io.emit('alert', alert);
  return alert;
}

async function checkGeofences(device, point) {
  const { rows: fences } = await query(
    `SELECT g.*, s.inside AS prev_inside FROM geofences g
     LEFT JOIN geofence_state s ON s.geofence_id = g.id AND s.device_id = $1`,
    [device.id],
  );
  for (const f of fences) {
    const inside = haversine(point.lat, point.lng, f.lat, f.lng) <= f.radius_m;
    if (f.prev_inside === null) {
      // Primera vez que se evalúa: solo registrar el estado, sin alertar
    } else if (inside !== f.prev_inside) {
      await createAlert(
        device,
        inside ? 'geofence_enter' : 'geofence_exit',
        `${device.name} ${inside ? 'entró a' : 'salió de'} la geocerca "${f.name}"`,
        point.lat,
        point.lng,
      );
    }
    await query(
      `INSERT INTO geofence_state (device_id, geofence_id, inside) VALUES ($1,$2,$3)
       ON CONFLICT (device_id, geofence_id) DO UPDATE SET inside = EXCLUDED.inside`,
      [device.id, f.id, inside],
    );
  }
}

const offlineNotified = new Set();

// ---------------------------------------------------------------- API móvil
app.get('/api/health', (_req, res) => res.json({ ok: true, time: new Date().toISOString() }));

app.post('/api/devices/register', requireDevice, wrap(async (req, res) => {
  const { id, name, platform } = req.body;
  if (!id || !name) return res.status(400).json({ error: 'id y name son obligatorios' });
  const existing = await getDevice(id);
  let device;
  if (existing) {
    ({ rows: [device] } = await query(
      'UPDATE devices SET name = $2, platform = $3 WHERE id = $1 RETURNING *',
      [id, name, platform ?? existing.platform],
    ));
  } else {
    const { rows: [{ count }] } = await query('SELECT count(*)::int AS count FROM devices');
    ({ rows: [device] } = await query(
      'INSERT INTO devices (id, name, color, platform) VALUES ($1,$2,$3,$4) RETURNING *',
      [id, name, colorFor(count), platform ?? null],
    ));
  }
  io.emit('device', device);
  res.json(device);
}));

app.post('/api/sessions/start', requireDevice, wrap(async (req, res) => {
  const { deviceId, sessionId, startedAt, name } = req.body;
  await query(
    `INSERT INTO sessions (id, device_id, name, started_at) VALUES ($1,$2,$3,$4)
     ON CONFLICT (id) DO NOTHING`,
    [sessionId, deviceId, name ?? null, startedAt ?? new Date()],
  );
  const { rows: [device] } = await query(
    'UPDATE devices SET tracking = true WHERE id = $1 RETURNING *', [deviceId],
  );
  if (device) io.emit('device', device);
  io.emit('session_start', { deviceId, sessionId });
  res.json({ ok: true });
}));

app.post('/api/sessions/:id/stop', requireDevice, wrap(async (req, res) => {
  const { deviceId, endedAt, distance, calories } = req.body;
  await query(
    `UPDATE sessions SET ended_at = $2, distance_m = COALESCE($3, distance_m), calories = COALESCE($4, calories)
     WHERE id = $1`,
    [req.params.id, endedAt ?? new Date(), distance ?? null, calories ?? null],
  );
  const { rows: [device] } = await query(
    'UPDATE devices SET tracking = false WHERE id = $1 RETURNING *', [deviceId],
  );
  offlineNotified.delete(deviceId);
  if (device) io.emit('device', device);
  res.json({ ok: true });
}));

app.patch('/api/sessions/:id', requireDevice, wrap(async (req, res) => {
  await query('UPDATE sessions SET name = $2 WHERE id = $1', [req.params.id, req.body.name]);
  res.json({ ok: true });
}));

/**
 * Recibe un lote de puntos (en línea o vaciando la cola offline del teléfono).
 * Es idempotente: (device_id, ts) es único, así que reenvíos no duplican datos.
 */
app.post('/api/locations', requireDevice, wrap(async (req, res) => {
  const { deviceId, sessionId, points } = req.body;
  if (!deviceId || !Array.isArray(points) || points.length === 0) {
    return res.status(400).json({ error: 'deviceId y points son obligatorios' });
  }
  const device = await getDevice(deviceId);
  if (!device) return res.status(404).json({ error: 'dispositivo no registrado' });

  if (sessionId) {
    const first = points.reduce((a, b) => (a.ts < b.ts ? a : b));
    await query(
      `INSERT INTO sessions (id, device_id, started_at) VALUES ($1,$2,$3) ON CONFLICT (id) DO NOTHING`,
      [sessionId, deviceId, new Date(first.ts)],
    );
  }

  const cols = ['device_id', 'session_id', 'ts', 'lat', 'lng', 'speed', 'accuracy', 'heading', 'altitude', 'battery', 'activity'];
  const values = [];
  const tuples = points.map((p, i) => {
    values.push(deviceId, p.sessionId ?? sessionId ?? null, new Date(p.ts), p.lat, p.lng,
      p.speed ?? null, p.accuracy ?? null, p.heading ?? null, p.altitude ?? null,
      p.battery ?? null, p.activity ?? null);
    return `(${cols.map((_, j) => `$${i * cols.length + j + 1}`).join(',')})`;
  });
  const { rows: inserted } = await query(
    `INSERT INTO locations (${cols.join(',')}) VALUES ${tuples.join(',')}
     ON CONFLICT (device_id, ts) DO NOTHING RETURNING *`,
    values,
  );
  inserted.sort((a, b) => a.ts - b.ts);

  const latest = inserted[inserted.length - 1];
  let updated = device;
  if (latest && (!device.last_seen_at || latest.ts >= device.last_seen_at)) {
    ({ rows: [updated] } = await query(
      `UPDATE devices SET last_seen_at = $2, last_lat = $3, last_lng = $4, last_speed = $5,
         last_battery = COALESCE($6, last_battery), tracking = true
       WHERE id = $1 RETURNING *`,
      [deviceId, latest.ts, latest.lat, latest.lng, latest.speed, latest.battery],
    ));
    offlineNotified.delete(deviceId);

    if (latest.battery != null && latest.battery <= LOW_BATTERY &&
        (device.last_battery == null || device.last_battery > LOW_BATTERY)) {
      await createAlert(updated, 'low_battery', `${device.name}: batería baja (${latest.battery}%)`, latest.lat, latest.lng);
    }
    await checkGeofences(updated, latest);
  }

  if (inserted.length) {
    io.emit('locations', { deviceId, points: inserted });
    io.emit('device', updated);
  }
  res.json({ received: points.length, stored: inserted.length });
}));

app.post('/api/alerts/sos', requireDevice, wrap(async (req, res) => {
  const { deviceId, lat, lng } = req.body;
  const device = await getDevice(deviceId);
  if (!device) return res.status(404).json({ error: 'dispositivo no registrado' });
  const alert = await createAlert(device, 'sos', `🚨 SOS de ${device.name}`, lat, lng);
  res.json(alert);
}));

// ---------------------------------------------------------------- API dashboard
app.get('/api/devices', requireDashboard, wrap(async (_req, res) => {
  const { rows } = await query('SELECT * FROM devices ORDER BY created_at');
  res.json(rows);
}));

app.patch('/api/devices/:id', requireDashboard, wrap(async (req, res) => {
  const { name, color } = req.body;
  const { rows: [device] } = await query(
    'UPDATE devices SET name = COALESCE($2, name), color = COALESCE($3, color) WHERE id = $1 RETURNING *',
    [req.params.id, name ?? null, color ?? null],
  );
  if (device) io.emit('device', device);
  res.json(device);
}));

/** Rutas de la sesión activa de cada dispositivo que está rastreando. */
app.get('/api/live', requireDashboard, wrap(async (_req, res) => {
  const { rows } = await query(
    `SELECT l.device_id, l.ts, l.lat, l.lng, l.speed, l.accuracy FROM locations l
     JOIN devices d ON d.id = l.device_id AND d.tracking
     WHERE l.session_id = (SELECT s.id FROM sessions s WHERE s.device_id = d.id ORDER BY s.started_at DESC LIMIT 1)
       AND (l.accuracy IS NULL OR l.accuracy <= $1)
     ORDER BY l.ts`,
    [MAX_ACCURACY_M],
  );
  const trails = {};
  for (const r of rows) (trails[r.device_id] ||= []).push(r);
  res.json(trails);
}));

function historyParams(req) {
  const { deviceId, from, to } = req.query;
  return [deviceId, from ? new Date(from) : new Date(Date.now() - 86400000), to ? new Date(to) : new Date()];
}

app.get('/api/history', requireDashboard, wrap(async (req, res) => {
  const { rows } = await query(
    `SELECT ts, lat, lng, speed, accuracy, heading, altitude, battery, activity, session_id
     FROM locations WHERE device_id = $1 AND ts BETWEEN $2 AND $3 AND (accuracy IS NULL OR accuracy <= $4)
     ORDER BY ts LIMIT 100000`,
    [...historyParams(req), MAX_ACCURACY_M],
  );
  res.json(rows);
}));

app.get('/api/history/stats', requireDashboard, wrap(async (req, res) => {
  const { rows } = await query(
    `SELECT ts, lat, lng, speed FROM locations
     WHERE device_id = $1 AND ts BETWEEN $2 AND $3 AND (accuracy IS NULL OR accuracy <= $4) ORDER BY ts`,
    [...historyParams(req), MAX_ACCURACY_M],
  );
  let distance = 0, maxSpeed = 0, moving = 0;
  for (let i = 1; i < rows.length; i++) {
    const a = rows[i - 1], b = rows[i];
    distance += haversine(a.lat, a.lng, b.lat, b.lng);
    maxSpeed = Math.max(maxSpeed, b.speed ?? 0);
    if ((b.speed ?? 0) > 0.5) moving += (b.ts - a.ts) / 1000;
  }
  const duration = rows.length > 1 ? (rows[rows.length - 1].ts - rows[0].ts) / 1000 : 0;
  res.json({
    points: rows.length,
    distanceM: Math.round(distance),
    durationSec: Math.round(duration),
    movingSec: Math.round(moving),
    maxSpeedKmh: +(maxSpeed * 3.6).toFixed(1),
    avgSpeedKmh: moving > 0 ? +((distance / moving) * 3.6).toFixed(1) : 0,
  });
}));

app.get('/api/history/export', requireDashboard, wrap(async (req, res) => {
  const params = historyParams(req);
  const device = await getDevice(params[0]);
  if (!device) return res.status(404).json({ error: 'dispositivo no encontrado' });
  const { rows } = await query(
    `SELECT * FROM locations WHERE device_id = $1 AND ts BETWEEN $2 AND $3 ORDER BY ts`, params,
  );
  const format = req.query.format === 'csv' ? 'csv' : 'gpx';
  const filename = `${device.name.replace(/[^\w-]+/g, '_')}_${params[1].toISOString().slice(0, 10)}.${format}`;
  res.setHeader('Content-Disposition', `attachment; filename="${filename}"`);
  res.type(format === 'csv' ? 'text/csv' : 'application/gpx+xml');
  res.send(format === 'csv' ? toCsv(rows) : toGpx(device.name, rows));
}));

app.get('/api/sessions', requireDashboard, wrap(async (req, res) => {
  const { rows } = await query(
    `SELECT * FROM sessions WHERE ($1::text IS NULL OR device_id = $1) ORDER BY started_at DESC LIMIT 200`,
    [req.query.deviceId ?? null],
  );
  res.json(rows);
}));

app.get('/api/geofences', requireDashboard, wrap(async (_req, res) => {
  res.json((await query('SELECT * FROM geofences ORDER BY id')).rows);
}));

app.post('/api/geofences', requireDashboard, wrap(async (req, res) => {
  const { name, lat, lng, radius } = req.body;
  const { rows: [fence] } = await query(
    'INSERT INTO geofences (name, lat, lng, radius_m) VALUES ($1,$2,$3,$4) RETURNING *',
    [name, lat, lng, radius],
  );
  io.emit('geofences_changed');
  res.json(fence);
}));

app.delete('/api/geofences/:id', requireDashboard, wrap(async (req, res) => {
  await query('DELETE FROM geofences WHERE id = $1', [req.params.id]);
  io.emit('geofences_changed');
  res.json({ ok: true });
}));

app.get('/api/alerts', requireDashboard, wrap(async (_req, res) => {
  const { rows } = await query(
    `SELECT a.*, d.name AS device_name, d.color AS device_color FROM alerts a
     LEFT JOIN devices d ON d.id = a.device_id ORDER BY a.created_at DESC LIMIT 100`,
  );
  res.json(rows);
}));

app.post('/api/alerts/:id/ack', requireDashboard, wrap(async (req, res) => {
  await query('UPDATE alerts SET acknowledged = true WHERE id = $1', [req.params.id]);
  res.json({ ok: true });
}));

// ---------------------------------------------------------------- dashboard estático
const publicDir = path.join(__dirname, '..', 'public');
if (fs.existsSync(publicDir)) {
  app.use(express.static(publicDir));
  app.get(/^(?!\/api|\/socket\.io).*/, (_req, res) => res.sendFile(path.join(publicDir, 'index.html')));
}

app.use((err, _req, res, _next) => {
  console.error(err);
  res.status(500).json({ error: 'internal_error' });
});

// ---------------------------------------------------------------- vigilancia de dispositivos sin señal
async function offlineWatchdog() {
  const { rows } = await query(
    `SELECT * FROM devices WHERE tracking AND last_seen_at < now() - ($1 || ' seconds')::interval`,
    [OFFLINE_AFTER_SEC],
  );
  for (const d of rows) {
    if (offlineNotified.has(d.id)) continue;
    offlineNotified.add(d.id);
    await createAlert(d, 'offline', `${d.name} no envía datos desde hace más de ${Math.round(OFFLINE_AFTER_SEC / 60)} min`, d.last_lat, d.last_lng);
  }
}

await migrate();
setInterval(() => offlineWatchdog().catch(console.error), 30000);
server.listen(PORT, () => console.log(`GeoTrack API escuchando en :${PORT}`));

process.on('SIGTERM', async () => {
  server.close();
  await pool.end();
  process.exit(0);
});
