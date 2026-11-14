-- B2.8: single-writer lease for the sync state (frigate path, B2.3).
-- Exactly one row (id = 1): the identity of the current sync-state writer
-- and the epoch-millis of its last heartbeat. The live writer (the
-- foreground service, or the app after takeover) renews it every 5 s. A
-- process may take over writing only after the lease is observed stale for
-- >= 10 s (two missed heartbeats).
CREATE TABLE writer_lease (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    writer_id TEXT NOT NULL,
    heartbeat_ms INTEGER NOT NULL
);
