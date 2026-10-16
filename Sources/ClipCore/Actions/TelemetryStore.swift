import Foundation

public struct ActionRecord: Sendable, Equatable {
    public let name: String
    public let detail: String?
    public let startedAt: Int64
    public let durationMs: Int64
    public let outcome: ActionOutcome
}

/// FR23 / Q15 — the slowest 1000 actions, in logs/telemetry.sqlite (separate from clipboard data).
/// Contract: TelemetryStore.ddl ↔ docs/scv/2.2-data-contracts.md「埋点库」(checked by SchemaDocTests).
public actor TelemetryStore {
    public static let keep = 1000

    static let ddl = """
    -- 按钮 / 快捷键操作的耗时记录：只保留耗时最长的 1000 条，用于找出需要优化的操作
    CREATE TABLE IF NOT EXISTS op_timings(
      id          INTEGER PRIMARY KEY,                -- 记录 ID
      name        TEXT NOT NULL,                      -- 操作名（静态标识，如 settings.model.activate）
      detail      TEXT,                               -- 操作对象标识（模型 ID、条目 ID）；不含剪贴板内容
      started_at  INTEGER NOT NULL,                   -- 开始时间（毫秒时间戳）
      duration_ms INTEGER NOT NULL,                   -- 耗时（毫秒）；超时记为期限
      outcome     TEXT NOT NULL CHECK (outcome IN ('succeeded','failed','timedOut','cancelled'))  -- 结果
    );
    CREATE INDEX IF NOT EXISTS op_timings_duration ON op_timings(duration_ms DESC);  -- 取最慢 / 淘汰最快
    """

    let conn: SQLiteConnection

    public init(home: AppHome) throws {
        conn = try SQLiteConnection(path: home.logsURL.appendingPathComponent("telemetry.sqlite").path)
        try conn.exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL")
        try conn.exec(Self.ddl)
    }

    public func record(name: String, detail: String?, startedAt: Int64, durationMs: Int64, outcome: ActionOutcome) throws {
        try conn.transaction {
            try conn.run("INSERT INTO op_timings(name, detail, started_at, duration_ms, outcome) VALUES (?,?,?,?,?)",
                         [name, detail, startedAt, durationMs, outcome.rawValue])
            try conn.run("DELETE FROM op_timings WHERE id IN (SELECT id FROM op_timings ORDER BY duration_ms DESC, id DESC LIMIT -1 OFFSET ?)", [Self.keep])
        }
    }

    public func slowest(limit: Int) throws -> [ActionRecord] {
        try conn.query("SELECT name, detail, started_at, duration_ms, outcome FROM op_timings ORDER BY duration_ms DESC, id DESC LIMIT ?", [limit]) {
            ActionRecord(name: $0.text(0) ?? "", detail: $0.text(1), startedAt: $0.int(2), durationMs: $0.int(3),
                         outcome: ActionOutcome(rawValue: $0.text(4) ?? "") ?? .failed)
        }
    }

    /// Human-readable report (CLI --slow-ops, exported logs).
    public func report(limit: Int) throws -> String {
        let fmt = ISO8601DateFormatter()
        var lines = ["# 最慢的 \(limit) 次操作（共保留最慢 \(Self.keep) 次）", "耗时(ms)\t结果\t操作\t对象\t开始时间"]
        for r in try slowest(limit: limit) {
            lines.append("\(r.durationMs)\t\(r.outcome.rawValue)\t\(r.name)\t\(r.detail ?? "")\t\(fmt.string(from: Date(timeIntervalSince1970: Double(r.startedAt) / 1000)))")
        }
        return lines.joined(separator: "\n")
    }
}
