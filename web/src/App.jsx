import { useCallback, useEffect, useMemo, useState } from 'react';
import { alertIcon, api, connectSocket, getToken, setToken } from './api.js';
import MapView from './MapView.jsx';
import { AlertsPanel, GeofencePanel, HistoryPanel, LivePanel } from './Panels.jsx';
import Playback, { usePlayback } from './Playback.jsx';

const MAX_TRAIL = 5000;

const TABS = [
  { id: 'live', icon: 'sensors', label: 'En vivo' },
  { id: 'history', icon: 'history', label: 'Historial' },
  { id: 'geofences', icon: 'fence', label: 'Geocercas' },
  { id: 'alerts', icon: 'notifications', label: 'Alertas' },
];

export default function App() {
  const [token, setTok] = useState(getToken());
  if (!token) return <Login onLogin={(t) => { setToken(t); setTok(t); }} />;
  return <Dashboard />;
}

function Login({ onLogin }) {
  const [value, setValue] = useState('');
  return (
    <div className="login">
      <form className="card login-card" onSubmit={(e) => { e.preventDefault(); value && onLogin(value.trim()); }}>
        <div className="brand"><span className="material-symbols-rounded brand-icon">my_location</span>GeoTrack</div>
        <p className="muted">Centro de Monitoreo</p>
        <input className="input" type="password" placeholder="Token de acceso" value={value}
          onChange={(e) => setValue(e.target.value)} autoFocus />
        <button className="btn primary" type="submit">Entrar</button>
      </form>
    </div>
  );
}

function Dashboard() {
  const [tab, setTab] = useState('live');
  const [panelOpen, setPanelOpen] = useState(true);
  const [devices, setDevices] = useState({});
  const [trails, setTrails] = useState({});
  const [alerts, setAlerts] = useState([]);
  const [geofences, setGeofences] = useState([]);
  const [toasts, setToasts] = useState([]);
  const [focus, setFocus] = useState(null);           // {lat, lng, zoom?} para centrar el mapa
  const [history, setHistory] = useState(null);       // {device, points, stats, from, to}
  const [draftFence, setDraftFence] = useState(null); // {lat, lng, radius, name}
  const [connected, setConnected] = useState(false);

  const playback = usePlayback(history?.points ?? []);

  const loadGeofences = useCallback(() => api('/api/geofences').then(setGeofences), []);

  useEffect(() => {
    api('/api/devices').then((list) => setDevices(Object.fromEntries(list.map((d) => [d.id, d]))));
    api('/api/live').then(setTrails);
    api('/api/alerts').then(setAlerts);
    loadGeofences();

    const socket = connectSocket();
    socket.on('connect', () => setConnected(true));
    socket.on('disconnect', () => setConnected(false));
    socket.on('device', (d) => setDevices((prev) => ({ ...prev, [d.id]: d })));
    socket.on('session_start', ({ deviceId }) => setTrails((prev) => ({ ...prev, [deviceId]: [] })));
    socket.on('locations', ({ deviceId, points }) => {
      setTrails((prev) => {
        const merged = [...(prev[deviceId] || []), ...points]
          .sort((a, b) => new Date(a.ts) - new Date(b.ts))
          .slice(-MAX_TRAIL);
        return { ...prev, [deviceId]: merged };
      });
    });
    socket.on('alert', (a) => {
      setAlerts((prev) => [a, ...prev].slice(0, 100));
      const id = `${a.id}-${Date.now()}`;
      setToasts((prev) => [...prev, { ...a, toastId: id }]);
      setTimeout(() => setToasts((prev) => prev.filter((t) => t.toastId !== id)), a.type === 'sos' ? 20000 : 7000);
    });
    socket.on('geofences_changed', loadGeofences);
    return () => socket.disconnect();
  }, [loadGeofences]);

  // Al salir de la pestaña de historial se limpia la ruta consultada
  useEffect(() => {
    if (tab !== 'history') { setHistory(null); }
    if (tab !== 'geofences') setDraftFence(null);
  }, [tab]);

  const pendingAlerts = useMemo(() => alerts.filter((a) => !a.acknowledged).length, [alerts]);

  const ackAlert = async (id) => {
    await api(`/api/alerts/${id}/ack`, { method: 'POST' });
    setAlerts((prev) => prev.map((a) => (a.id === id ? { ...a, acknowledged: true } : a)));
  };

  const onMapClick = (latlng) => {
    if (tab === 'geofences' && draftFence) setDraftFence((f) => ({ ...f, lat: latlng.lat, lng: latlng.lng }));
  };

  return (
    <div className="app">
      <MapView
        mode={tab}
        devices={devices}
        trails={trails}
        geofences={geofences}
        draftFence={draftFence}
        history={history}
        playback={playback}
        focus={focus}
        alerts={alerts}
        onMapClick={onMapClick}
      />

      <aside className={`panel card ${panelOpen ? '' : 'collapsed'}`}>
        <header className="panel-header">
          <div className="brand"><span className="material-symbols-rounded brand-icon">my_location</span>GeoTrack</div>
          <span className={`conn ${connected ? 'on' : ''}`} title={connected ? 'Conectado en tiempo real' : 'Reconectando…'} />
          <button className="icon-btn" onClick={() => setPanelOpen((o) => !o)} title="Contraer panel">
            <span className="material-symbols-rounded">{panelOpen ? 'chevron_left' : 'chevron_right'}</span>
          </button>
        </header>
        {panelOpen && (
          <>
            <nav className="tabs">
              {TABS.map((t) => (
                <button key={t.id} className={`tab ${tab === t.id ? 'active' : ''}`} onClick={() => setTab(t.id)}>
                  <span className="material-symbols-rounded">{t.icon}</span>
                  <span>{t.label}</span>
                  {t.id === 'alerts' && pendingAlerts > 0 && <span className="badge">{pendingAlerts}</span>}
                </button>
              ))}
            </nav>
            <div className="panel-body">
              {tab === 'live' && <LivePanel devices={devices} trails={trails} onFocus={setFocus} />}
              {tab === 'history' && (
                <HistoryPanel devices={devices} history={history} setHistory={setHistory}
                  onLoaded={(pts) => pts[0] && setFocus({ bounds: pts.map((p) => [p.lat, p.lng]) })} />
              )}
              {tab === 'geofences' && (
                <GeofencePanel geofences={geofences} draft={draftFence} setDraft={setDraftFence}
                  onSaved={loadGeofences} onFocus={setFocus} />
              )}
              {tab === 'alerts' && <AlertsPanel alerts={alerts} onAck={ackAlert} onFocus={setFocus} />}
            </div>
          </>
        )}
      </aside>

      {tab === 'history' && history?.points?.length > 1 && <Playback playback={playback} device={history.device} />}

      <div className="toasts">
        {toasts.map((t) => (
          <div key={t.toastId} className={`toast card ${t.type}`}
            onClick={() => t.lat && setFocus({ lat: t.lat, lng: t.lng, zoom: 17 })}>
            <span className="material-symbols-rounded">{alertIcon(t.type)}</span>
            <span>{t.message}</span>
          </div>
        ))}
      </div>
    </div>
  );
}
