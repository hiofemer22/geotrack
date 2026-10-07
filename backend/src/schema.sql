-- Esquema de GeoTrack. Se aplica automáticamente al arrancar el servidor.

CREATE TABLE IF NOT EXISTS devices (
  id            TEXT PRIMARY KEY,
  name          TEXT NOT NULL,
  color         TEXT NOT NULL,
  platform      TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_seen_at  TIMESTAMPTZ,
  last_lat      DOUBLE PRECISION,
  last_lng      DOUBLE PRECISION,
  last_speed    DOUBLE PRECISION,
  last_battery  INTEGER,
  tracking      BOOLEAN NOT NULL DEFAULT false
);

CREATE TABLE IF NOT EXISTS sessions (
  id          TEXT PRIMARY KEY,
  device_id   TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  name        TEXT,
  started_at  TIMESTAMPTZ NOT NULL,
  ended_at    TIMESTAMPTZ,
  distance_m  DOUBLE PRECISION NOT NULL DEFAULT 0,
  calories    DOUBLE PRECISION NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS sessions_device_idx ON sessions (device_id, started_at DESC);

CREATE TABLE IF NOT EXISTS locations (
  id          BIGSERIAL PRIMARY KEY,
  device_id   TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  session_id  TEXT,
  ts          TIMESTAMPTZ NOT NULL,
  lat         DOUBLE PRECISION NOT NULL,
  lng         DOUBLE PRECISION NOT NULL,
  speed       DOUBLE PRECISION,
  accuracy    DOUBLE PRECISION,
  heading     DOUBLE PRECISION,
  altitude    DOUBLE PRECISION,
  battery     INTEGER,
  activity    TEXT,
  UNIQUE (device_id, ts)
);
CREATE INDEX IF NOT EXISTS locations_device_ts_idx ON locations (device_id, ts);

CREATE TABLE IF NOT EXISTS geofences (
  id          BIGSERIAL PRIMARY KEY,
  name        TEXT NOT NULL,
  lat         DOUBLE PRECISION NOT NULL,
  lng         DOUBLE PRECISION NOT NULL,
  radius_m    DOUBLE PRECISION NOT NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Último estado conocido de cada dispositivo frente a cada geocerca (dentro/fuera)
CREATE TABLE IF NOT EXISTS geofence_state (
  device_id   TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  geofence_id BIGINT NOT NULL REFERENCES geofences(id) ON DELETE CASCADE,
  inside      BOOLEAN NOT NULL,
  PRIMARY KEY (device_id, geofence_id)
);

CREATE TABLE IF NOT EXISTS alerts (
  id            BIGSERIAL PRIMARY KEY,
  device_id     TEXT REFERENCES devices(id) ON DELETE CASCADE,
  type          TEXT NOT NULL,          -- sos | geofence_enter | geofence_exit | low_battery | offline
  message       TEXT NOT NULL,
  lat           DOUBLE PRECISION,
  lng           DOUBLE PRECISION,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  acknowledged  BOOLEAN NOT NULL DEFAULT false
);
CREATE INDEX IF NOT EXISTS alerts_created_idx ON alerts (created_at DESC);
