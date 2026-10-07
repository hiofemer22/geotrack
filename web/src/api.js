import { io } from 'socket.io-client';

const TOKEN_KEY = 'geotrack_token';

export function getToken() {
  try { return localStorage.getItem(TOKEN_KEY); } catch { return null; }
}
export function setToken(t) {
  try { t ? localStorage.setItem(TOKEN_KEY, t) : localStorage.removeItem(TOKEN_KEY); } catch { /* sin storage */ }
}

export async function api(path, { method = 'GET', body } = {}) {
  const res = await fetch(path, {
    method,
    headers: {
      Authorization: `Bearer ${getToken()}`,
      ...(body ? { 'Content-Type': 'application/json' } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  if (res.status === 401) {
    setToken(null);
    window.location.reload();
  }
  if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
  return res.json();
}

export function exportUrl({ deviceId, from, to, format }) {
  const q = new URLSearchParams({ deviceId, from, to, format, token: getToken() });
  return `/api/history/export?${q}`;
}

export function connectSocket() {
  return io({ auth: { token: getToken() } });
}

// Utilidades de formato
export const kmh = (mps) => (mps == null ? '—' : `${(mps * 3.6).toFixed(1)} km/h`);
export function ago(date) {
  if (!date) return 'sin datos';
  const s = Math.round((Date.now() - new Date(date)) / 1000);
  if (s < 60) return `hace ${s}s`;
  if (s < 3600) return `hace ${Math.round(s / 60)} min`;
  if (s < 86400) return `hace ${Math.round(s / 3600)} h`;
  return new Date(date).toLocaleDateString();
}
export function fmtDuration(sec) {
  const h = Math.floor(sec / 3600), m = Math.floor((sec % 3600) / 60);
  return h ? `${h} h ${m} min` : `${m} min`;
}
export function fmtDistance(m) {
  return m >= 1000 ? `${(m / 1000).toFixed(2)} km` : `${m} m`;
}

export function alertIcon(type) {
  return {
    sos: 'emergency_home',
    geofence_enter: 'login',
    geofence_exit: 'logout',
    low_battery: 'battery_alert',
    offline: 'signal_disconnected',
  }[type] || 'notifications';
}
