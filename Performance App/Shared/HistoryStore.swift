import Foundation
import SQLite3

// sqlite3_bind_text's destructor parameter has no Swift-visible constant for
// SQLITE_TRANSIENT (it's a C macro, `(sqlite3_destructor_type)-1`), so it has
// to be reconstructed by hand — this is the standard idiom for this API.
private let SQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// All access to the recorded history database. Only the helper (running as
/// root) ever opens this for writing; the app never touches the file
/// directly — it asks the helper for data over XPC. Safe to also open
/// read-only from tests against a temp-file database.
///
/// Raw per-second samples are always stored unaveraged; bucketing/averaging
/// only happens in the `query...` methods, computed in SQL via `SUM`/`SUM of
/// squares` (turned into mean/variance by `BucketStats`), so arbitrarily long
/// ranges still return a bounded number of points.
nonisolated final class HistoryStore {
    enum StoreError: Error { case openFailed(String), sqlFailed(String) }

    private let db: OpaquePointer

    init(path: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK, let handle else {
            throw StoreError.openFailed(String(cString: sqlite3_errmsg(handle)))
        }
        db = handle
        try exec("PRAGMA journal_mode=WAL")
        try exec("""
            CREATE TABLE IF NOT EXISTS cpu_samples (
                ts REAL NOT NULL, overall REAL NOT NULL, performance REAL, efficiency REAL
            );
            CREATE INDEX IF NOT EXISTS idx_cpu_ts ON cpu_samples(ts);

            CREATE TABLE IF NOT EXISTS memory_samples (
                ts REAL NOT NULL, active REAL NOT NULL, inactive REAL NOT NULL,
                wired REAL NOT NULL, compressed REAL NOT NULL, free REAL NOT NULL, total REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_memory_ts ON memory_samples(ts);

            CREATE TABLE IF NOT EXISTS process_names (
                id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE
            );

            CREATE TABLE IF NOT EXISTS process_samples (
                ts REAL NOT NULL, name_id INTEGER NOT NULL, usage REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_process_ts ON process_samples(ts);

            CREATE TABLE IF NOT EXISTS peaks (
                metric TEXT PRIMARY KEY, value REAL NOT NULL, ts REAL NOT NULL, detail TEXT
            );
            """)
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Writing

    struct CPUSampleInput {
        let date: Date
        let overall: Double
        let performance: Double?
        let efficiency: Double?
    }

    struct MemorySampleInput {
        let date: Date
        let snapshot: MemorySnapshot
    }

    struct ProcessSampleInput {
        let date: Date
        let usages: [(name: String, usage: Double)]
    }

    /// Writes a batch of buffered samples in one transaction, and updates the
    /// all-time peak records from the same batch (so this adds no extra
    /// writes). Call roughly every 10s from the recorder's in-memory buffer,
    /// not once per 1Hz sample — that would make 1 transaction/second, far
    /// more I/O than this needs for a background daemon.
    func flush(cpuSamples: [CPUSampleInput], memorySamples: [MemorySampleInput], processSamples: [ProcessSampleInput]) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            for sample in cpuSamples {
                try run("INSERT INTO cpu_samples (ts, overall, performance, efficiency) VALUES (?, ?, ?, ?)") { stmt in
                    sqlite3_bind_double(stmt, 1, sample.date.timeIntervalSince1970)
                    sqlite3_bind_double(stmt, 2, sample.overall)
                    bindOptionalDouble(stmt, 3, sample.performance)
                    bindOptionalDouble(stmt, 4, sample.efficiency)
                }
                updatePeakIfHigher(.cpuTotal, value: sample.overall, date: sample.date, detail: nil)
                if let performance = sample.performance {
                    updatePeakIfHigher(.cpuPerformance, value: performance, date: sample.date, detail: nil)
                }
                if let efficiency = sample.efficiency {
                    updatePeakIfHigher(.cpuEfficiency, value: efficiency, date: sample.date, detail: nil)
                }
            }

            for sample in memorySamples {
                let snapshot = sample.snapshot
                try run("INSERT INTO memory_samples (ts, active, inactive, wired, compressed, free, total) VALUES (?, ?, ?, ?, ?, ?, ?)") { stmt in
                    sqlite3_bind_double(stmt, 1, sample.date.timeIntervalSince1970)
                    sqlite3_bind_double(stmt, 2, Double(snapshot.activeBytes))
                    sqlite3_bind_double(stmt, 3, Double(snapshot.inactiveBytes))
                    sqlite3_bind_double(stmt, 4, Double(snapshot.wiredBytes))
                    sqlite3_bind_double(stmt, 5, Double(snapshot.compressedBytes))
                    sqlite3_bind_double(stmt, 6, Double(snapshot.freeBytes))
                    sqlite3_bind_double(stmt, 7, Double(snapshot.totalBytes))
                }
                updatePeakIfHigher(.memoryUsed, value: Double(snapshot.usedBytes), date: sample.date, detail: nil)
            }

            for sample in processSamples {
                for (name, usage) in sample.usages {
                    let nameID = try nameID(for: name)
                    try run("INSERT INTO process_samples (ts, name_id, usage) VALUES (?, ?, ?)") { stmt in
                        sqlite3_bind_double(stmt, 1, sample.date.timeIntervalSince1970)
                        sqlite3_bind_int64(stmt, 2, nameID)
                        sqlite3_bind_double(stmt, 3, usage)
                    }
                    updatePeakIfHigher(.singleProcess, value: usage, date: sample.date, detail: name)
                }
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Deletes every sample older than `cutoff`. Call with
    /// `max(now - retentionWindow, bootTime)` so a reboot also discards
    /// samples from the previous boot, not just samples past the retention
    /// window. Never touches `peaks` — those are meant to survive pruning.
    func prune(olderThan cutoff: Date) throws {
        let ts = cutoff.timeIntervalSince1970
        try exec("BEGIN IMMEDIATE")
        do {
            try run("DELETE FROM cpu_samples WHERE ts < ?") { sqlite3_bind_double($0, 1, ts) }
            try run("DELETE FROM memory_samples WHERE ts < ?") { sqlite3_bind_double($0, 1, ts) }
            try run("DELETE FROM process_samples WHERE ts < ?") { sqlite3_bind_double($0, 1, ts) }
            try exec("DELETE FROM process_names WHERE id NOT IN (SELECT DISTINCT name_id FROM process_samples)")
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    // MARK: - Reading

    func queryCPUHistory(since: Date, bucketSeconds: Double) throws -> [CPUHistoryPoint] {
        let sql = """
            SELECT CAST(ts / ?1 AS INTEGER) AS bucket,
                   COUNT(*), SUM(overall), SUM(overall * overall), MIN(overall), MAX(overall),
                   COUNT(performance), SUM(performance), SUM(performance * performance), MIN(performance), MAX(performance),
                   COUNT(efficiency), SUM(efficiency), SUM(efficiency * efficiency), MIN(efficiency), MAX(efficiency)
            FROM cpu_samples
            WHERE ts >= ?2
            GROUP BY bucket
            ORDER BY bucket
            """
        var points: [CPUHistoryPoint] = []
        try query(sql, bind: { stmt in
            sqlite3_bind_double(stmt, 1, bucketSeconds)
            sqlite3_bind_double(stmt, 2, since.timeIntervalSince1970)
        }, row: { stmt in
            let bucket = sqlite3_column_double(stmt, 0)
            let overall = BucketStats(
                count: Int(sqlite3_column_int64(stmt, 1)),
                sum: sqlite3_column_double(stmt, 2),
                sumOfSquares: sqlite3_column_double(stmt, 3),
                min: sqlite3_column_double(stmt, 4),
                max: sqlite3_column_double(stmt, 5)
            )
            let performanceCount = Int(sqlite3_column_int64(stmt, 6))
            let performance = performanceCount > 0 ? BucketStats(
                count: performanceCount,
                sum: sqlite3_column_double(stmt, 7),
                sumOfSquares: sqlite3_column_double(stmt, 8),
                min: sqlite3_column_double(stmt, 9),
                max: sqlite3_column_double(stmt, 10)
            ) : nil
            let efficiencyCount = Int(sqlite3_column_int64(stmt, 11))
            let efficiency = efficiencyCount > 0 ? BucketStats(
                count: efficiencyCount,
                sum: sqlite3_column_double(stmt, 12),
                sumOfSquares: sqlite3_column_double(stmt, 13),
                min: sqlite3_column_double(stmt, 14),
                max: sqlite3_column_double(stmt, 15)
            ) : nil
            let date = Date(timeIntervalSince1970: bucket * bucketSeconds)
            points.append(CPUHistoryPoint(date: date, overall: overall, performance: performance, efficiency: efficiency))
        })
        return points
    }

    func queryMemoryHistory(since: Date, bucketSeconds: Double) throws -> [MemoryHistoryPoint] {
        let sql = """
            SELECT CAST(ts / ?1 AS INTEGER) AS bucket,
                   AVG(active), AVG(inactive), AVG(wired), AVG(compressed),
                   COUNT(*), SUM(active + inactive + wired + compressed),
                   SUM((active + inactive + wired + compressed) * (active + inactive + wired + compressed)),
                   MIN(active + inactive + wired + compressed), MAX(active + inactive + wired + compressed)
            FROM memory_samples
            WHERE ts >= ?2
            GROUP BY bucket
            ORDER BY bucket
            """
        var points: [MemoryHistoryPoint] = []
        try query(sql, bind: { stmt in
            sqlite3_bind_double(stmt, 1, bucketSeconds)
            sqlite3_bind_double(stmt, 2, since.timeIntervalSince1970)
        }, row: { stmt in
            let bucket = sqlite3_column_double(stmt, 0)
            let used = BucketStats(
                count: Int(sqlite3_column_int64(stmt, 5)),
                sum: sqlite3_column_double(stmt, 6),
                sumOfSquares: sqlite3_column_double(stmt, 7),
                min: sqlite3_column_double(stmt, 8),
                max: sqlite3_column_double(stmt, 9)
            )
            points.append(MemoryHistoryPoint(
                date: Date(timeIntervalSince1970: bucket * bucketSeconds),
                active: sqlite3_column_double(stmt, 1),
                inactive: sqlite3_column_double(stmt, 2),
                wired: sqlite3_column_double(stmt, 3),
                compressed: sqlite3_column_double(stmt, 4),
                used: used
            ))
        })
        return points
    }

    /// Ranked by average usage over the range; missing seconds for a given
    /// process count as 0 usage (not skipped), since `AVG` here is only over
    /// the samples that were actually recorded for that name — a process
    /// that's only sometimes in the top-N will look busier than it was if we
    /// averaged only its present samples. This is an accepted approximation:
    /// true "average over the whole range including zeros" would need a
    /// dense per-second record of every process, which is exactly what
    /// keeping only the top-N per second avoids storing.
    func queryProcessSummary(since: Date, limit: Int) throws -> [ProcessSummaryEntry] {
        // Window functions (not a correlated subquery referencing an outer
        // MAX(), which SQLite can't resolve unambiguously) compute the
        // average/peak per name, and rank each name's own rows by usage so
        // `rn = 1` picks exactly the row whose `ts` is the real peak moment.
        let sql = """
            SELECT name, averageUsage, peakUsage, peakDate FROM (
                SELECT n.name AS name,
                       AVG(s.usage) OVER (PARTITION BY s.name_id) AS averageUsage,
                       MAX(s.usage) OVER (PARTITION BY s.name_id) AS peakUsage,
                       s.ts AS peakDate,
                       ROW_NUMBER() OVER (PARTITION BY s.name_id ORDER BY s.usage DESC) AS rn
                FROM process_samples s
                JOIN process_names n ON n.id = s.name_id
                WHERE s.ts >= ?1
            )
            WHERE rn = 1
            ORDER BY averageUsage DESC
            LIMIT ?2
            """
        var entries: [ProcessSummaryEntry] = []
        try query(sql, bind: { stmt in
            sqlite3_bind_double(stmt, 1, since.timeIntervalSince1970)
            sqlite3_bind_int64(stmt, 2, Int64(limit))
        }, row: { stmt in
            entries.append(ProcessSummaryEntry(
                name: String(cString: sqlite3_column_text(stmt, 0)),
                averageUsage: sqlite3_column_double(stmt, 1),
                peakUsage: sqlite3_column_double(stmt, 2),
                peakDate: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
            ))
        })
        return entries
    }

    func fetchPeaks() throws -> [PeakRecord] {
        var records: [PeakRecord] = []
        try query("SELECT metric, value, ts, detail FROM peaks", bind: { _ in }, row: { stmt in
            guard let metric = PeakRecord.Metric(rawValue: String(cString: sqlite3_column_text(stmt, 0))) else { return }
            let detail = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
            records.append(PeakRecord(
                metric: metric,
                value: sqlite3_column_double(stmt, 1),
                date: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                detail: detail
            ))
        })
        return records
    }

    func resetPeaks() throws {
        try exec("DELETE FROM peaks")
    }

    // MARK: - Private helpers

    private func nameID(for name: String) throws -> Int64 {
        try run("INSERT OR IGNORE INTO process_names (name) VALUES (?)") { stmt in
            sqlite3_bind_text(stmt, 1, name, -1, SQLiteTransient)
        }
        var id: Int64 = 0
        try query("SELECT id FROM process_names WHERE name = ?", bind: { stmt in
            sqlite3_bind_text(stmt, 1, name, -1, SQLiteTransient)
        }, row: { stmt in
            id = sqlite3_column_int64(stmt, 0)
        })
        return id
    }

    /// Must be called inside the batch's own transaction (see `flush`), not
    /// as a separate commit per metric — upserts are cheap and this runs at
    /// most a handful of times per flush.
    private func updatePeakIfHigher(_ metric: PeakRecord.Metric, value: Double, date: Date, detail: String?) {
        try? run("""
            INSERT INTO peaks (metric, value, ts, detail) VALUES (?, ?, ?, ?)
            ON CONFLICT(metric) DO UPDATE SET value = excluded.value, ts = excluded.ts, detail = excluded.detail
            WHERE excluded.value > peaks.value
            """) { stmt in
            sqlite3_bind_text(stmt, 1, metric.rawValue, -1, SQLiteTransient)
            sqlite3_bind_double(stmt, 2, value)
            sqlite3_bind_double(stmt, 3, date.timeIntervalSince1970)
            if let detail {
                sqlite3_bind_text(stmt, 4, detail, -1, SQLiteTransient)
            } else {
                sqlite3_bind_null(stmt, 4)
            }
        }
    }

    private func bindOptionalDouble(_ stmt: OpaquePointer?, _ index: Int32, _ value: Double?) {
        if let value {
            sqlite3_bind_double(stmt, index, value)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw StoreError.sqlFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func run(_ sql: String, bind: (OpaquePointer?) -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.sqlFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw StoreError.sqlFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func query(_ sql: String, bind: (OpaquePointer?) -> Void, row: (OpaquePointer?) -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.sqlFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        while sqlite3_step(stmt) == SQLITE_ROW {
            row(stmt)
        }
    }
}
