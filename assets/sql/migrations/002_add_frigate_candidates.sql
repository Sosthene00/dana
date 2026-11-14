-- frigate_candidates: unconfirmed receipt candidates (frigate path only, B3.1).
-- Identity is the outpoint (txid, vout). A candidate NEVER enters
-- owned_outputs, never advances a checkpoint and is never spendable (B3.2);
-- it graduates only through the phase-3 confirmation path (B3.3).
CREATE TABLE frigate_candidates (
  txid TEXT NOT NULL,
  vout INTEGER NOT NULL,
  tweak BLOB NOT NULL,
  script BLOB NOT NULL,
  amount_sat INTEGER NOT NULL,
  first_seen INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
  source TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'confirmed', 'dropped')),
  PRIMARY KEY (txid, vout)
);
CREATE INDEX idx_frigate_candidates_status ON frigate_candidates(status);
