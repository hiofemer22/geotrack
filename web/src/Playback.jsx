import { useEffect, useMemo, useRef, useState } from 'react';
import { kmh } from './api.js';

const SPEEDS = [1, 10, 20, 30, 60];
const MAX_GAP_MS = 60000; // huecos mayores (p.ej. sin señal) se saltan durante la reproducción

/**
 * Reproduce una ruta en "tiempo simulado": el reloj avanza speed × tiempo real
 * y la posición se interpola entre los dos puntos que rodean el instante actual.
 */
export function usePlayback(points) {
  const times = useMemo(() => points.map((p) => new Date(p.ts).getTime()), [points]);
  const start = times[0] ?? 0;
  const end = times[times.length - 1] ?? 0;

  const [t, setT] = useState(start);
  const [playing, setPlaying] = useState(false);
  const [speed, setSpeed] = useState(10);
  const raf = useRef();

  useEffect(() => { setT(start); setPlaying(false); }, [start, end]);

  useEffect(() => {
    if (!playing) return undefined;
    let last = performance.now();
    const tick = (now) => {
      const dt = (now - last) * speed;
      last = now;
      setT((prev) => {
        let next = prev + dt;
        const i = upperIndex(times, prev);
        if (i < times.length && times[i] - times[i - 1] > MAX_GAP_MS && next < times[i]) next = times[i];
        if (next >= end) { setPlaying(false); return end; }
        return next;
      });
      raf.current = requestAnimationFrame(tick);
    };
    raf.current = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(raf.current);
  }, [playing, speed, times, end]);

  const idx = Math.max(1, upperIndex(times, t));
  let position = null;
  let traveled = [];
  let current = points[0];
  if (points.length === 1) position = [points[0].lat, points[0].lng];
  if (points.length > 1) {
    const a = points[idx - 1];
    const b = points[Math.min(idx, points.length - 1)];
    const ta = times[idx - 1];
    const tb = times[Math.min(idx, points.length - 1)];
    const f = tb > ta ? Math.min(1, Math.max(0, (t - ta) / (tb - ta))) : 1;
    position = [a.lat + (b.lat - a.lat) * f, a.lng + (b.lng - a.lng) * f];
    traveled = [...points.slice(0, idx).map((p) => [p.lat, p.lng]), position];
    current = a;
  }

  return {
    t, start, end, playing, speed, position, traveled, current,
    progress: end > start ? (t - start) / (end - start) : 0,
    toggle: () => {
      if (t >= end) setT(start);
      setPlaying((p) => !p);
    },
    seek: (fraction) => setT(start + (end - start) * fraction),
    setSpeed,
  };
}

/** Primer índice i tal que times[i] > value (búsqueda binaria). */
function upperIndex(times, value) {
  let lo = 0, hi = times.length;
  while (lo < hi) {
    const mid = (lo + hi) >> 1;
    if (times[mid] <= value) lo = mid + 1; else hi = mid;
  }
  return lo;
}

const fmtTime = (ms) =>
  new Date(ms).toLocaleString([], { day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit', second: '2-digit' });

export default function Playback({ playback, device }) {
  const { playing, toggle, progress, seek, speed, setSpeed, t, start, end, current } = playback;
  return (
    <div className="playback card">
      <button className="play-btn" onClick={toggle} title={playing ? 'Pausa' : 'Reproducir'} style={{ background: device.color }}>
        <span className="material-symbols-rounded">{playing ? 'pause' : 'play_arrow'}</span>
      </button>
      <div className="playback-main">
        <div className="playback-info">
          <strong>{fmtTime(t)}</strong>
          <span className="muted">{kmh(current?.speed)}</span>
        </div>
        <input type="range" min="0" max="1000" value={Math.round(progress * 1000)}
          onChange={(e) => seek(Number(e.target.value) / 1000)} className="slider" style={{ '--c': device.color }} />
        <div className="playback-range muted">
          <span>{fmtTime(start)}</span><span>{fmtTime(end)}</span>
        </div>
      </div>
      <div className="speeds">
        {SPEEDS.map((s) => (
          <button key={s} className={`chip ${speed === s ? 'active' : ''}`} onClick={() => setSpeed(s)}>x{s}</button>
        ))}
      </div>
    </div>
  );
}
