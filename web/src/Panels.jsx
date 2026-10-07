import { useState } from 'react';
import { ago, alertIcon, api, exportUrl, fmtDistance, fmtDuration, kmh } from './api.js';

function status(d) {
  if (!d.tracking) return { label: 'Inactivo', cls: 'idle' };
  if (d.last_seen_at && Date.now() - new Date(d.last_seen_at) < 120000) return { label: 'En vivo', cls: 'live' };
  return { label: 'Sin señal', cls: 'lost' };
}

function Battery({ value }) {
  if (value == null) return null;
  const icon = value > 80 ? 'battery_full' : value > 50 ? 'battery_5_bar' : value > 20 ? 'battery_3_bar' : 'battery_alert';
  return (
    <span className={`battery ${value <= 15 ? 'low' : ''}`}>
      <span className="material-symbols-rounded">{icon}</span>{value}%
    </span>
  );
}

// ------------------------------------------------------------------ En vivo
export function LivePanel({ devices, trails, onFocus }) {
  const [filter, setFilter] = useState('');
  const list = Object.values(devices)
    .filter((d) => d.name.toLowerCase().includes(filter.toLowerCase()))
    .sort((a, b) => Number(b.tracking) - Number(a.tracking) || a.name.localeCompare(b.name));
  const active = list.filter((d) => d.tracking).length;

  return (
    <div className="stack">
      <div className="search">
        <span className="material-symbols-rounded">search</span>
        <input placeholder="Buscar dispositivo" value={filter} onChange={(e) => setFilter(e.target.value)} />
      </div>
      <div className="summary muted">{active} de {list.length} dispositivos rastreando</div>
      {list.length === 0 && <Empty icon="phone_android" text="Aún no hay dispositivos. Abre la app móvil para registrar uno." />}
      {list.map((d) => {
        const s = status(d);
        const pts = trails[d.id]?.length ?? 0;
        return (
          <button key={d.id} className="device-row" disabled={d.last_lat == null}
            onClick={() => onFocus({ lat: d.last_lat, lng: d.last_lng, zoom: 17, t: Date.now() })}>
            <span className="device-color" style={{ background: d.color }} />
            <div className="device-main">
              <div className="device-name">{d.name}</div>
              <div className="device-meta muted">
                <span className={`status ${s.cls}`}>{s.label}</span>
                <span>· {ago(d.last_seen_at)}</span>
                {d.tracking && pts > 0 && <span>· {pts} pts</span>}
              </div>
            </div>
            <div className="device-side">
              {d.tracking && <span className="speed">{kmh(d.last_speed)}</span>}
              <Battery value={d.last_battery} />
            </div>
          </button>
        );
      })}
    </div>
  );
}

// ------------------------------------------------------------------ Historial
const toLocalInput = (date) => {
  const d = new Date(date);
  d.setMinutes(d.getMinutes() - d.getTimezoneOffset());
  return d.toISOString().slice(0, 16);
};

export function HistoryPanel({ devices, history, setHistory, onLoaded }) {
  const list = Object.values(devices);
  const [deviceId, setDeviceId] = useState(list[0]?.id ?? '');
  const [from, setFrom] = useState(toLocalInput(Date.now() - 86400000));
  const [to, setTo] = useState(toLocalInput(Date.now()));
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState(null);

  const presets = [
    { label: '1 h', ms: 3600000 },
    { label: 'Hoy', today: true },
    { label: '24 h', ms: 86400000 },
    { label: '7 días', ms: 7 * 86400000 },
  ];
  const applyPreset = (p) => {
    const now = Date.now();
    if (p.today) { const d = new Date(); d.setHours(0, 0, 0, 0); setFrom(toLocalInput(d)); }
    else setFrom(toLocalInput(now - p.ms));
    setTo(toLocalInput(now));
  };

  const search = async (e) => {
    e?.preventDefault();
    if (!deviceId) return;
    setLoading(true); setError(null);
    try {
      const params = new URLSearchParams({ deviceId, from: new Date(from).toISOString(), to: new Date(to).toISOString() });
      const [points, stats] = await Promise.all([
        api(`/api/history?${params}`),
        api(`/api/history/stats?${params}`),
      ]);
      setHistory({ device: devices[deviceId], points, stats, from: new Date(from).toISOString(), to: new Date(to).toISOString() });
      onLoaded(points);
    } catch (err) {
      setError(err.message);
    } finally {
      setLoading(false);
    }
  };

  return (
    <form className="stack" onSubmit={search}>
      <label className="field">
        <span>Dispositivo</span>
        <select className="input" value={deviceId} onChange={(e) => setDeviceId(e.target.value)}>
          {list.map((d) => <option key={d.id} value={d.id}>{d.name}</option>)}
        </select>
      </label>
      <div className="chips">
        {presets.map((p) => <button type="button" key={p.label} className="chip" onClick={() => applyPreset(p)}>{p.label}</button>)}
      </div>
      <div className="row">
        <label className="field"><span>Desde</span>
          <input className="input" type="datetime-local" value={from} onChange={(e) => setFrom(e.target.value)} /></label>
        <label className="field"><span>Hasta</span>
          <input className="input" type="datetime-local" value={to} onChange={(e) => setTo(e.target.value)} /></label>
      </div>
      <button className="btn primary" disabled={loading || !deviceId}>
        <span className="material-symbols-rounded">route</span>{loading ? 'Buscando…' : 'Consultar recorrido'}
      </button>
      {error && <div className="error">{error}</div>}

      {history && (
        history.points.length === 0
          ? <Empty icon="location_off" text="No hay ubicaciones en ese rango." />
          : (
            <>
              <div className="stats">
                <Stat icon="straighten" label="Distancia" value={fmtDistance(history.stats.distanceM)} />
                <Stat icon="schedule" label="Duración" value={fmtDuration(history.stats.durationSec)} />
                <Stat icon="speed" label="Vel. media" value={`${history.stats.avgSpeedKmh} km/h`} />
                <Stat icon="bolt" label="Vel. máx." value={`${history.stats.maxSpeedKmh} km/h`} />
              </div>
              <div className="muted small">{history.points.length} puntos registrados</div>
              <div className="row">
                <a className="btn" href={exportUrl({ deviceId: history.device.id, from: history.from, to: history.to, format: 'gpx' })}>
                  <span className="material-symbols-rounded">download</span>GPX</a>
                <a className="btn" href={exportUrl({ deviceId: history.device.id, from: history.from, to: history.to, format: 'csv' })}>
                  <span className="material-symbols-rounded">table_view</span>CSV</a>
              </div>
            </>
          )
      )}
    </form>
  );
}

function Stat({ icon, label, value }) {
  return (
    <div className="stat">
      <span className="material-symbols-rounded">{icon}</span>
      <div><div className="stat-value">{value}</div><div className="muted small">{label}</div></div>
    </div>
  );
}

// ------------------------------------------------------------------ Geocercas
export function GeofencePanel({ geofences, draft, setDraft, onSaved, onFocus }) {
  const save = async () => {
    await api('/api/geofences', { method: 'POST', body: { name: draft.name, lat: draft.lat, lng: draft.lng, radius: draft.radius } });
    setDraft(null);
    onSaved();
  };
  const remove = async (id) => {
    await api(`/api/geofences/${id}`, { method: 'DELETE' });
    onSaved();
  };

  return (
    <div className="stack">
      {!draft ? (
        <button className="btn primary" onClick={() => setDraft({ name: '', radius: 200, lat: null, lng: null })}>
          <span className="material-symbols-rounded">add_location_alt</span>Nueva geocerca
        </button>
      ) : (
        <div className="draft">
          <div className="muted small">{draft.lat == null ? 'Haz clic en el mapa para ubicar el centro.' : 'Puedes volver a hacer clic para moverla.'}</div>
          <input className="input" placeholder="Nombre (p. ej. Oficina central)" value={draft.name}
            onChange={(e) => setDraft({ ...draft, name: e.target.value })} />
          <label className="field"><span>Radio: {draft.radius} m</span>
            <input type="range" min="50" max="5000" step="50" value={draft.radius}
              onChange={(e) => setDraft({ ...draft, radius: Number(e.target.value) })} className="slider" /></label>
          <div className="row">
            <button className="btn" onClick={() => setDraft(null)}>Cancelar</button>
            <button className="btn primary" disabled={!draft.name || draft.lat == null} onClick={save}>Guardar</button>
          </div>
        </div>
      )}
      <div className="muted small">Se genera una alerta cuando un dispositivo entra o sale de una geocerca.</div>
      {geofences.length === 0 && <Empty icon="fence" text="Sin geocercas definidas." />}
      {geofences.map((g) => (
        <div key={g.id} className="device-row" onClick={() => onFocus({ lat: g.lat, lng: g.lng, zoom: 16, t: Date.now() })}>
          <span className="material-symbols-rounded accent">radio_button_checked</span>
          <div className="device-main">
            <div className="device-name">{g.name}</div>
            <div className="muted small">Radio {g.radius_m} m</div>
          </div>
          <button className="icon-btn" title="Eliminar" onClick={(e) => { e.stopPropagation(); remove(g.id); }}>
            <span className="material-symbols-rounded">delete</span>
          </button>
        </div>
      ))}
    </div>
  );
}

// ------------------------------------------------------------------ Alertas
export function AlertsPanel({ alerts, onAck, onFocus }) {
  if (alerts.length === 0) return <Empty icon="notifications_off" text="Sin alertas." />;
  return (
    <div className="stack">
      {alerts.map((a) => (
        <div key={a.id} className={`alert-row ${a.type} ${a.acknowledged ? 'acked' : ''}`}
          onClick={() => a.lat != null && onFocus({ lat: a.lat, lng: a.lng, zoom: 17, t: Date.now() })}>
          <span className="material-symbols-rounded alert-icon">{alertIcon(a.type)}</span>
          <div className="device-main">
            <div className="device-name">{a.message}</div>
            <div className="muted small">{new Date(a.created_at).toLocaleString()}</div>
          </div>
          {!a.acknowledged && (
            <button className="icon-btn" title="Marcar como atendida" onClick={(e) => { e.stopPropagation(); onAck(a.id); }}>
              <span className="material-symbols-rounded">check</span>
            </button>
          )}
        </div>
      ))}
    </div>
  );
}

function Empty({ icon, text }) {
  return (
    <div className="empty muted">
      <span className="material-symbols-rounded">{icon}</span>
      <p>{text}</p>
    </div>
  );
}
