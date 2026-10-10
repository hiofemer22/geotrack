import { Fragment, useEffect, useMemo } from 'react';
import L from 'leaflet';
import { Circle, MapContainer, Marker, Polyline, TileLayer, Tooltip, useMap, useMapEvents, ZoomControl } from 'react-leaflet';
import { kmh } from './api.js';

// Mapa base claro y minimalista (CARTO Voyager), similar a Google Maps
const TILE_URL = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
const TILE_ATTR = '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>';

function deviceIcon(color, { pulse = false, heading = null, dim = false } = {}) {
  const arrow = heading != null
    ? `<div class="dev-heading" style="transform: rotate(${heading}deg)"><div style="border-bottom-color:${color}"></div></div>`
    : '';
  return L.divIcon({
    className: '',
    iconSize: [22, 22],
    iconAnchor: [11, 11],
    html: `<div class="dev-marker ${pulse ? 'pulse' : ''} ${dim ? 'dim' : ''}" style="--c:${color}">${arrow}<div class="dev-dot"></div></div>`,
  });
}

function FocusController({ focus }) {
  const map = useMap();
  useEffect(() => {
    if (!focus) return;
    if (focus.bounds?.length) map.flyToBounds(focus.bounds, { padding: [80, 80], duration: 0.8 });
    else if (focus.lat != null) map.flyTo([focus.lat, focus.lng], focus.zoom ?? Math.max(map.getZoom(), 16), { duration: 0.8 });
  }, [focus, map]);
  return null;
}

function ClickHandler({ onClick }) {
  useMapEvents({ click: (e) => onClick?.(e.latlng) });
  return null;
}

function isLive(d) {
  return d.tracking && d.last_seen_at && Date.now() - new Date(d.last_seen_at) < 120000;
}

export default function MapView({ mode, devices, trails, geofences, draftFence, history, playback, focus, onMapClick }) {
  const deviceList = Object.values(devices);
  const initial = useMemo(() => {
    const d = deviceList.find((x) => x.last_lat != null);
    return d ? [d.last_lat, d.last_lng] : [19.4326, -99.1332];
  }, []); // eslint-disable-line react-hooks/exhaustive-deps

  const showLive = mode !== 'history' || !history;

  return (
    <MapContainer center={initial} zoom={13} zoomControl={false} className="map" worldCopyJump>
      <TileLayer url={TILE_URL} attribution={TILE_ATTR} maxNativeZoom={19} maxZoom={20} />
      <ZoomControl position="bottomright" />
      <FocusController focus={focus} />
      <ClickHandler onClick={onMapClick} />

      {/* Geocercas */}
      {geofences.map((g) => (
        <Circle key={g.id} center={[g.lat, g.lng]} radius={g.radius_m}
          pathOptions={{ color: '#1A73E8', weight: 1.5, fillOpacity: 0.08, dashArray: '6 6' }}>
          <Tooltip direction="center" className="fence-label" permanent={mode === 'geofences'}>{g.name}</Tooltip>
        </Circle>
      ))}
      {draftFence?.lat != null && (
        <Circle center={[draftFence.lat, draftFence.lng]} radius={draftFence.radius}
          pathOptions={{ color: '#E8710A', weight: 2, fillOpacity: 0.12 }} />
      )}

      {/* Modo en vivo: ruta + marcador por dispositivo */}
      {showLive && deviceList.map((d) => {
        const trail = trails[d.id] || [];
        const live = isLive(d);
        return (
          <Fragment key={d.id}>
            {trail.length > 1 && (
              <>
                <Polyline positions={trail.map((p) => [p.lat, p.lng])} pathOptions={{ color: '#ffffff', weight: 8, opacity: 0.9 }} />
                <Polyline positions={trail.map((p) => [p.lat, p.lng])} pathOptions={{ color: d.color, weight: 4.5, opacity: 0.95 }} />
              </>
            )}
            {live && trail.at(-1)?.accuracy > 0 && (
              // Margen de error del GPS en la última lectura (como el círculo azul de Google Maps)
              <Circle center={[d.last_lat, d.last_lng]} radius={trail.at(-1).accuracy} interactive={false}
                pathOptions={{ color: d.color, weight: 1, opacity: 0.4, fillOpacity: 0.12 }} />
            )}
            {d.last_lat != null && (
              <Marker position={[d.last_lat, d.last_lng]} icon={deviceIcon(d.color, { pulse: live, dim: !d.tracking })}>
                <Tooltip permanent direction="top" offset={[0, -12]} className="dev-label">
                  <span style={{ color: d.color }}>●</span> {d.name}
                  {live && <span className="dev-label-speed"> · {kmh(d.last_speed)}</span>}
                </Tooltip>
              </Marker>
            )}
          </Fragment>
        );
      })}

      {/* Modo historial: ruta completa (tenue) + tramo recorrido + marcador animado */}
      {mode === 'history' && history?.points?.length > 0 && (
        <>
          <Polyline positions={history.points.map((p) => [p.lat, p.lng])}
            pathOptions={{ color: history.device.color, weight: 4, opacity: 0.3 }} />
          {playback.traveled.length > 1 && (
            <>
              <Polyline positions={playback.traveled} pathOptions={{ color: '#ffffff', weight: 8, opacity: 0.9 }} />
              <Polyline positions={playback.traveled} pathOptions={{ color: history.device.color, weight: 4.5 }} />
            </>
          )}
          {playback.position && (
            <Marker position={playback.position} icon={deviceIcon(history.device.color, { pulse: playback.playing })}>
              <Tooltip permanent direction="top" offset={[0, -12]} className="dev-label">
                {history.device.name} · {kmh(playback.current?.speed)}
              </Tooltip>
            </Marker>
          )}
        </>
      )}
    </MapContainer>
  );
}
