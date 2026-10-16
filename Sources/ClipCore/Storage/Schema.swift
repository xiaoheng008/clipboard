import Foundation

// Contract: this schema and docs/scv/2-data-contracts.md must change together.
// The version lives in `PRAGMA user_version`; migrations are forward-only (C5).

public enum SchemaError: Error, CustomStringConvertible {
    case newerThanApp(found: Int, supported: Int)
    public var description: String {
        switch self {
        case let .newerThanApp(found, supported):
            return "Database schema v\(found) is newer than this app supports (v\(supported)). Please upgrade ClipVault."
        }
    }
}

public enum Schema {
    public static let currentVersion = 1

    static let v1 = """
    CREATE TABLE settings(key TEXT PRIMARY KEY, value TEXT NOT NULL);

    CREATE TABLE items(
      id            INTEGER PRIMARY KEY,
      seq           INTEGER NOT NULL UNIQUE,   -- recency sequence; renewed on every use; = FTS rowid
      kind          TEXT NOT NULL CHECK (kind IN ('text','rich','url','file','image')),
      content_hash  TEXT NOT NULL UNIQUE,
      text          TEXT,
      blob_hash     TEXT,
      byte_size     INTEGER NOT NULL,
      width         INTEGER,
      height        INTEGER,
      source_bundle TEXT,
      source_name   TEXT,
      created_at    INTEGER NOT NULL,
      last_used_at  INTEGER NOT NULL,
      use_count     INTEGER NOT NULL DEFAULT 1,
      pinned        INTEGER NOT NULL DEFAULT 0,
      ocr_text      TEXT,
      labels        TEXT,
      fts_truncated INTEGER NOT NULL DEFAULT 0
    );
    CREATE INDEX items_recent ON items(pinned DESC, seq DESC);
    CREATE INDEX items_kind_recent ON items(kind, pinned DESC, seq DESC);
    CREATE INDEX items_blob ON items(blob_hash) WHERE blob_hash IS NOT NULL;

    CREATE TABLE representations(
      item_id INTEGER NOT NULL REFERENCES items(id) ON DELETE CASCADE,
      uti     TEXT NOT NULL,
      data    BLOB NOT NULL,
      PRIMARY KEY(item_id, uti)
    );

    -- Both full-text tables use rowid = items.seq, so matches stream newest-first and stop at LIMIT.
    CREATE VIRTUAL TABLE items_fts USING fts5(body, tokenize='trigram', content='', contentless_delete=1);
    CREATE VIRTUAL TABLE items_ngram USING fts5(body, tokenize='ascii', content='', contentless_delete=1, detail='none');

    CREATE TABLE index_jobs(
      id          INTEGER PRIMARY KEY,
      item_id     INTEGER NOT NULL REFERENCES items(id) ON DELETE CASCADE,
      kind        TEXT NOT NULL CHECK (kind IN ('vision','embed')),
      model_id    TEXT NOT NULL DEFAULT '',
      state       TEXT NOT NULL CHECK (state IN ('pending','running','failed')),
      attempts    INTEGER NOT NULL DEFAULT 0,
      not_before  INTEGER NOT NULL DEFAULT 0,
      lease_until INTEGER NOT NULL DEFAULT 0,
      last_error  TEXT,
      UNIQUE(item_id, kind, model_id)
    );
    CREATE INDEX index_jobs_claim ON index_jobs(state, not_before);

    CREATE TABLE embeddings(
      item_id  INTEGER NOT NULL REFERENCES items(id) ON DELETE CASCADE,
      model_id TEXT NOT NULL,
      dim      INTEGER NOT NULL,
      vec      BLOB NOT NULL,
      PRIMARY KEY(item_id, model_id)
    );
    CREATE INDEX embeddings_model ON embeddings(model_id);
    """

    /// Per-connection pragmas.
    static func configure(_ c: SQLiteConnection, readOnly: Bool) throws {
        if !readOnly {
            try c.exec("PRAGMA journal_mode=WAL")
        }
        try c.exec("PRAGMA foreign_keys=ON; PRAGMA synchronous=NORMAL; PRAGMA temp_store=MEMORY")
    }

    static func version(_ c: SQLiteConnection) throws -> Int {
        Int(try c.scalarInt("PRAGMA user_version"))
    }

    /// Brings the database to `currentVersion`. Backs the file up before any upgrade of existing data.
    static func migrate(_ c: SQLiteConnection, databaseURL: URL) throws {
        let found = try version(c)
        if found > currentVersion { throw SchemaError.newerThanApp(found: found, supported: currentVersion) }
        if found == currentVersion { return }
        if found > 0 {
            // Forward migration of real user data: keep a copy first (sync-recovery §7).
            let backup = databaseURL.deletingLastPathComponent().appendingPathComponent("clipvault.sqlite.bak-v\(found)")
            try? FileManager.default.removeItem(at: backup)
            try c.exec("VACUUM INTO '\(backup.path.replacingOccurrences(of: "'", with: "''"))'")
        }
        try c.transaction {
            if found < 1 { try c.exec(v1) }
            try c.exec("PRAGMA user_version = \(currentVersion)")
        }
    }
}
