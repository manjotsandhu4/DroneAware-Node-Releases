-- DroneAware Remote ID observations table
-- Run once on the flighttracker database:
--   psql -U fduflyer -d flighttracker -f rid_migration.sql

CREATE TABLE IF NOT EXISTS rid_observations (
    id           BIGSERIAL PRIMARY KEY,
    received_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    node_id      TEXT NOT NULL,
    radio        TEXT NOT NULL,          -- 'ble', 'wifi_beacon', 'wifi_nan'
    mac          TEXT NOT NULL,
    rssi         INTEGER,
    obs_time     TIMESTAMPTZ,            -- feeder-reported timestamp
    msg_type     TEXT,                   -- 'Basic ID', 'Location/Vector', etc.
    uas_id       TEXT,                   -- from Basic ID
    ua_type      TEXT,                   -- from Basic ID
    operator_id  TEXT,                   -- from Operator ID
    lat          DOUBLE PRECISION,       -- from Location/Vector
    lon          DOUBLE PRECISION,       -- from Location/Vector
    alt_geo      DOUBLE PRECISION,       -- geodetic altitude (m)
    ground_speed DOUBLE PRECISION,       -- m/s
    heading      DOUBLE PRECISION,       -- degrees
    payload_hex  TEXT,                   -- raw message hex
    decoded      JSONB                   -- full decoded object
);

CREATE INDEX IF NOT EXISTS rid_obs_received_at_idx  ON rid_observations(received_at DESC);
CREATE INDEX IF NOT EXISTS rid_obs_mac_time_idx     ON rid_observations(mac, obs_time DESC);
CREATE INDEX IF NOT EXISTS rid_obs_uas_id_idx       ON rid_observations(uas_id) WHERE uas_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS rid_obs_msg_type_idx     ON rid_observations(msg_type);
