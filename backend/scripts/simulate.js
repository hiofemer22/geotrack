// Simulador de dispositivos para probar el dashboard sin teléfonos:
//   node scripts/simulate.js [URL] [N_DISPOSITIVOS]
// Cada dispositivo camina/corre/maneja alrededor de un punto y envía su posición cada 5 s.
import crypto from 'node:crypto';

const BASE = process.argv[2] || 'http://localhost:8080';
const N = Number(process.argv[3] || 3);
const KEY = process.env.DEVICE_API_KEY || 'dev-device-key';
const CENTER = [19.4326, -99.1332];
const NAMES = ['Repartidor Norte', 'Supervisor Centro', 'Unidad 07', 'Técnico Campo', 'Mensajero Sur'];

const post = (path, body) =>
  fetch(`${BASE}${path}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'x-api-key': KEY },
    body: JSON.stringify(body),
  }).then((r) => r.json());

const devices = [];
for (let i = 0; i < N; i++) {
  const id = `sim-${i + 1}`;
  await post('/api/devices/register', { id, name: NAMES[i % NAMES.length], platform: 'simulator' });
  const sessionId = crypto.randomUUID();
  await post('/api/sessions/start', { deviceId: id, sessionId, startedAt: new Date().toISOString() });
  devices.push({
    id, sessionId,
    lat: CENTER[0] + (Math.random() - 0.5) * 0.03,
    lng: CENTER[1] + (Math.random() - 0.5) * 0.03,
    heading: Math.random() * 360,
    speed: [1.3, 3.2, 11][i % 3], // caminando, corriendo, en vehículo (m/s)
    battery: 100 - i * 30,
  });
}
console.log(`Simulando ${N} dispositivos contra ${BASE}. Ctrl+C para detener.`);

async function step() {
  for (const d of devices) {
    d.heading += (Math.random() - 0.5) * 40;
    const dist = d.speed * 5;
    d.lat += (dist * Math.cos((d.heading * Math.PI) / 180)) / 111320;
    d.lng += (dist * Math.sin((d.heading * Math.PI) / 180)) / (111320 * Math.cos((d.lat * Math.PI) / 180));
    d.battery = Math.max(1, d.battery - 0.2);
    const r = await post('/api/locations', {
      deviceId: d.id,
      sessionId: d.sessionId,
      points: [{ ts: Date.now(), lat: d.lat, lng: d.lng, speed: d.speed * (0.9 + Math.random() * 0.2), accuracy: 5, heading: d.heading, battery: Math.round(d.battery) }],
    });
    if (r.error) console.error(d.id, r);
  }
}

await step();
const timer = setInterval(step, 5000);
process.on('SIGINT', async () => {
  clearInterval(timer);
  for (const d of devices) await post(`/api/sessions/${d.sessionId}/stop`, { deviceId: d.id });
  process.exit(0);
});
