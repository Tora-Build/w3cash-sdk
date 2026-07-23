-- W3Cash telemetry (item 17) — D1 schema.
-- Mirror of PUBLIC chain events + the compile-time intent metadata. Nothing secret is stored.

-- On-chain events, keyed uniquely so re-indexing is idempotent.
CREATE TABLE IF NOT EXISTS events (
  chain_id     INTEGER NOT NULL,
  tx_hash      TEXT    NOT NULL,
  log_index    INTEGER NOT NULL,
  block        INTEGER NOT NULL,
  event        TEXT    NOT NULL,
  kind         TEXT    NOT NULL,          -- executed | paused | cancelled
  payload_hash TEXT    NOT NULL,
  indexed_at   INTEGER NOT NULL,
  PRIMARY KEY (chain_id, tx_hash, log_index)
);
CREATE INDEX IF NOT EXISTS idx_events_hash ON events (payload_hash);

-- Where the indexer left off per chain (resume point).
CREATE TABLE IF NOT EXISTS cursors (
  chain_id   INTEGER PRIMARY KEY,
  last_block INTEGER NOT NULL
);

-- Compile-time intent metadata (the "your intents" linkage). Optional: populated by the ASP's
-- best-effort POST /record at compile time. `summary` is ASP-supplied free text and is NEVER
-- returned by the unauthenticated read endpoints; payload_hash/chain_id/initiator only become
-- public once an intent executes on-chain. Nothing secret (keys/signatures) is stored here.
CREATE TABLE IF NOT EXISTS intents (
  payload_hash TEXT    NOT NULL,
  chain_id     INTEGER NOT NULL,
  initiator    TEXT,
  summary      TEXT,
  compiled_at  INTEGER NOT NULL,
  PRIMARY KEY (payload_hash, chain_id)
);
CREATE INDEX IF NOT EXISTS idx_intents_initiator ON intents (initiator);
