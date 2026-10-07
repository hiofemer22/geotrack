const R = 6371000;
const toRad = (d) => (d * Math.PI) / 180;

/** Distancia en metros entre dos coordenadas (fórmula de Haversine). */
export function haversine(lat1, lng1, lat2, lng2) {
  const dLat = toRad(lat2 - lat1);
  const dLng = toRad(lng2 - lng1);
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(a));
}

// Paleta de colores distintivos para los dispositivos (estilo Material / Google)
const PALETTE = [
  '#1A73E8', '#D93025', '#188038', '#F9AB00', '#A142F4',
  '#12B5CB', '#E8710A', '#E52592', '#5F6368', '#0B8043',
];

export function colorFor(index) {
  return PALETTE[index % PALETTE.length];
}

/** Puntos de una ruta -> GPX 1.1 */
export function toGpx(deviceName, points) {
  const esc = (s) => String(s).replace(/[<>&"']/g, (c) => `&#${c.charCodeAt(0)};`);
  const pts = points
    .map(
      (p) =>
        `<trkpt lat="${p.lat}" lon="${p.lng}">${
          p.altitude != null ? `<ele>${p.altitude}</ele>` : ''
        }<time>${new Date(p.ts).toISOString()}</time></trkpt>`,
    )
    .join('\n      ');
  return `<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="GeoTrack" xmlns="http://www.topografix.com/GPX/1/1">
  <trk>
    <name>${esc(deviceName)}</name>
    <trkseg>
      ${pts}
    </trkseg>
  </trk>
</gpx>
`;
}

export function toCsv(points) {
  const header = 'timestamp,lat,lng,speed_mps,accuracy_m,heading,altitude,battery,activity';
  const rows = points.map((p) =>
    [
      new Date(p.ts).toISOString(), p.lat, p.lng, p.speed ?? '', p.accuracy ?? '',
      p.heading ?? '', p.altitude ?? '', p.battery ?? '', p.activity ?? '',
    ].join(','),
  );
  return [header, ...rows].join('\n');
}
