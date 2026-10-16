import Foundation

// Contract: this schema and docs/scv/2.2-data-contracts.md must change together.
// The version lives in `PRAGMA user_version`; migrations are forward-only (C5).

public enum SchemaError: Error, CustomStringConvertible {
    case newerThanApp(found: Int, supported: Int)
    case incompatible(String)
    public var description: String {
        switch self {
        case let .newerThanApp(found, supported):
            return "Database schema v\(found) is newer than this app supports (v\(supported)). Please upgrade ClipVault."
        case .incompatible(let s):
            return "Database is from a pre-release build and is incompatible (\(s)). Move clipvault.sqlite aside to start fresh."
        }
    }
}

public enum Schema {
    public static let currentVersion = 1

    static let v1 = """
    -- 键值配置：hotkey（"keyCode:modifiers"，"none" = 用户已清除）、active_model（图片模型）、
    -- active_text_model（文本模型）、excluded_apps（不记录的 App，JSON 数组）
    CREATE TABLE settings(
      key   TEXT PRIMARY KEY,   -- 配置名
      value TEXT NOT NULL       -- 配置值（字符串 / JSON）
    );

    -- 剪贴板历史条目：每条复制内容一行，本地唯一真相
    CREATE TABLE items(
      id            INTEGER PRIMARY KEY,                  -- 条目 ID（自增，不变）
      seq           INTEGER NOT NULL UNIQUE,              -- 最近使用序号：每次复制 / 从历史复制都换成新的最大值；两个全文表的 rowid = seq
      kind          TEXT NOT NULL CHECK (kind IN ('text','rich','url','file','image')),  -- 类型：纯文本 / 富文本 / 链接 / 文件 / 图片
      content_hash  TEXT NOT NULL UNIQUE,                 -- 去重键：sha256(kind ‖ 0x00 ‖ 主内容)，同内容再复制只更新时间和次数
      text          TEXT,                                 -- 文本内容；链接为 URL；文件为路径（换行分隔）；图片为 NULL
      blob_hash     TEXT,                                 -- 图片文件名（blobs/ 下的 sha256）；非图片为 NULL
      byte_size     INTEGER NOT NULL,                     -- 内容字节数（含富文本等附加表示）
      width         INTEGER,                              -- 图片宽（像素）
      height        INTEGER,                              -- 图片高（像素）
      source_bundle TEXT,                                 -- 复制时前台 App 的 Bundle ID
      source_name   TEXT,                                 -- 复制时前台 App 的名称
      created_at    INTEGER NOT NULL,                     -- 首次复制时间（毫秒时间戳）
      last_used_at  INTEGER NOT NULL,                     -- 最近一次复制 / 从历史复制的时间（毫秒，仅显示；排序用 seq）
      use_count     INTEGER NOT NULL DEFAULT 1,           -- 复制次数
      pinned        INTEGER NOT NULL DEFAULT 0,           -- 是否置顶（1 = 置顶，排在最前）
      ocr_text      TEXT,                                 -- 图片中识别出的文字；'' = 已识别但无文字，NULL = 尚未识别
      labels        TEXT,                                 -- 图片场景标签（空格分隔的英文词）；NULL = 尚未识别
      fts_truncated INTEGER NOT NULL DEFAULT 0            -- 文本超过 256 KB，全文索引只覆盖前 256 KB（1 = 已截断）
    );
    CREATE INDEX items_recent ON items(pinned DESC, seq DESC);              -- 浏览列表：置顶在前，最近使用在前
    CREATE INDEX items_kind_recent ON items(kind, pinned DESC, seq DESC);   -- 按类型筛选的浏览列表
    CREATE INDEX items_blob ON items(blob_hash) WHERE blob_hash IS NOT NULL; -- 删除 / 垃圾回收时查图片文件是否仍被引用

    -- 条目的其它剪贴板表示，用于原样写回（富文本的 RTF / HTML、文件的 file-url 列表）
    CREATE TABLE representations(
      item_id INTEGER NOT NULL REFERENCES items(id) ON DELETE CASCADE,  -- 所属条目
      uti     TEXT NOT NULL,                                            -- 剪贴板类型（如 public.rtf）
      data    BLOB NOT NULL,                                            -- 该类型的原始数据
      PRIMARY KEY(item_id, uti)
    );

    -- 全文索引（≥3 字查询，trigram 分词，中英文子串都能命中）。rowid = items.seq，按最近使用流式读取
    -- 正文 = 文本（前 256 KB）+ 图中文字 + 图片标签；不存原文（contentless），删除时物理清除
    CREATE VIRTUAL TABLE items_fts USING fts5(body, tokenize='trigram', content='', contentless_delete=1);
    -- 短词索引（1–2 字查询）：每个词的单字 + 双字（UTF-8 十六进制编码），覆盖每条前 2048 字。rowid = items.seq
    CREATE VIRTUAL TABLE items_ngram USING fts5(body, tokenize='ascii', content='', contentless_delete=1, detail='none');

    -- 后台索引任务（OCR、生成向量）：与条目同事务入队，成功即删除该行
    CREATE TABLE index_jobs(
      id          INTEGER PRIMARY KEY,                                         -- 任务 ID
      item_id     INTEGER NOT NULL REFERENCES items(id) ON DELETE CASCADE,     -- 要处理的条目（条目删除则任务一起删除）
      kind        TEXT NOT NULL CHECK (kind IN ('vision','embed')),            -- vision = OCR + 标签；embed = 生成向量
      model_id    TEXT NOT NULL DEFAULT '',                                    -- embed 任务用的模型；vision 为空
      state       TEXT NOT NULL CHECK (state IN ('pending','running','failed')),  -- 等待 / 执行中 / 重试用尽失败
      attempts    INTEGER NOT NULL DEFAULT 0,                                  -- 已失败次数（达到上限进入 failed）
      not_before  INTEGER NOT NULL DEFAULT 0,                                  -- 退避：此时间（毫秒）之前不执行
      lease_until INTEGER NOT NULL DEFAULT 0,                                  -- 执行租约到期时间（毫秒）；过期可被重新认领，完成 / 失败需租约仍属于自己
      last_error  TEXT,                                                        -- 最近一次失败原因（不含剪贴板内容）
      UNIQUE(item_id, kind, model_id)
    );
    CREATE INDEX index_jobs_claim ON index_jobs(state, not_before);  -- 认领可执行任务

    -- 语义向量：每个（条目, 模型）一行；切换模型时旧模型的向量保留
    CREATE TABLE embeddings(
      item_id  INTEGER NOT NULL REFERENCES items(id) ON DELETE CASCADE,  -- 所属条目
      model_id TEXT NOT NULL,                                            -- 生成该向量的模型（含版本，如 siglip2-base@1）
      dim      INTEGER NOT NULL,                                         -- 向量维度
      vec      BLOB NOT NULL,                                            -- 向量：fp16 小端，L2 归一化
      PRIMARY KEY(item_id, model_id)
    );
    CREATE INDEX embeddings_model ON embeddings(model_id);  -- 按模型加载向量 / 统计覆盖率
    """

    /// Per-connection pragmas.
    static func configure(_ c: SQLiteConnection, readOnly: Bool) throws {
        if !readOnly {
            try c.exec("PRAGMA journal_mode=WAL")
        }
        // secure_delete: freed pages are zeroed, so deleted clipboard content is not left in the file (R14).
        try c.exec("PRAGMA foreign_keys=ON; PRAGMA synchronous=NORMAL; PRAGMA temp_store=MEMORY; PRAGMA secure_delete=ON")
    }

    static func version(_ c: SQLiteConnection) throws -> Int {
        Int(try c.scalarInt("PRAGMA user_version"))
    }

    /// Brings the database to `currentVersion`. Backs the file up before any upgrade of existing data.
    static func migrate(_ c: SQLiteConnection, databaseURL: URL) throws {
        let found = try version(c)
        if found > currentVersion { throw SchemaError.newerThanApp(found: found, supported: currentVersion) }
        if found == currentVersion {
            // R22: v1 changed once before release (seq / n-gram). Refuse such databases loudly.
            let columns = try c.query("PRAGMA table_info(items)", []) { $0.text(1) ?? "" }
            let tables = try c.query("SELECT name FROM sqlite_master WHERE type = 'table'", []) { $0.text(0) ?? "" }
            guard columns.contains("seq"), tables.contains("items_ngram") else { throw SchemaError.incompatible("missing seq / items_ngram") }
            return
        }
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

    /// FTS5 "secure-delete": deletes remove postings physically instead of leaving tombstones (R14).
    /// Persistent table config; idempotent, also applied to databases created before this existed.
    static func applyPrivacySettings(_ c: SQLiteConnection) throws {
        try c.exec("INSERT INTO items_fts(items_fts, rank) VALUES('secure-delete', 1)")
        try c.exec("INSERT INTO items_ngram(items_ngram, rank) VALUES('secure-delete', 1)")
    }

    /// After deleting content: move WAL pages into the (zeroed) main file and truncate the WAL (R14).
    static func scrubWAL(_ c: SQLiteConnection) {
        try? c.exec("PRAGMA wal_checkpoint(TRUNCATE)")
    }
}
