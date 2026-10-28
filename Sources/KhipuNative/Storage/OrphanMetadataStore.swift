import Foundation

/// Persisted orphan-metadata record. **IDs only**, by contract: NEVER payment amounts, user identifiers, or anything
/// actionable beyond IDs (PII). Keyed by `operationId` (the merchant id). `Codable` with field names identical to the
/// Kotlin `OrphanRecord` (`@Serializable`) so the JSON shape is structurally equivalent across platforms. Each
/// platform round-trips its OWN blob (it never crosses platforms); the on-disk byte order is NOT identical (Swift =
/// `.sortedKeys` here; Kotlin = kotlinx declaration order) and is not asserted to be.
///
/// `recordedAtWallMs` is the **wall clock at persist time** (≈ the terminal time), NOT the merchant's `start()`
/// wall time: the coordinator is deliberately wall-clock-free, so the `clockMs` lives HERE, in the store,
/// alongside the TTL. The 30-day purge counts from here; the delta vs `start()` (<= the 10–20 min payment budget)
/// is irrelevant to a 30-day window. Mirrors Kotlin's `OrphanRecord`.
struct OrphanRecord: Codable, Equatable {
    let operationId: String
    let debugId: String
    let lastKnownState: String // "timeout" | "cancelled" | "closed" (the payer-in-limbo terminal cause)
    let recordedAtWallMs: Int64
}

/// Minimal persistence seam (the `PaymentPresenting` pattern): the real implementation (`NoBackupFileOrphanStore`)
/// keeps the blob in a SINGLE file; tests inject an in-memory fake. Implementations MUST NOT throw (fail-soft, never
/// crash): a persistence failure must never block or crash the payment. Mirrors Kotlin's `OrphanStringStore`.
protocol OrphanStringStore: AnyObject {
    /// The persisted blob, or nil if absent.
    func read() -> String?
    /// Overwrite the persisted blob.
    func write(_ value: String)
}

/// In-memory `OrphanStringStore` — the coordinator's zero-config default + the unit-test double. Never persists
/// across process death; production wires `NoBackupFileOrphanStore` (KhipuPayment.init). Mirrors Kotlin's
/// `InMemoryOrphanStore`.
final class InMemoryOrphanStore: OrphanStringStore {
    private let lock = NSLock()
    private var blob: String?
    func read() -> String? { lock.lock(); defer { lock.unlock() }; return blob }
    func write(_ value: String) { lock.lock(); blob = value; lock.unlock() }
}

/// `OrphanStringStore` backed by a file in an SDK-owned, backup-excluded container. Plain platform storage with
/// ZERO new dependencies (Foundation only, NOT Keychain): the data is non-secret by design (IDs only), so an
/// encrypted store would be the wrong hammer. A SINGLE file holds the serialized record list, and it clears on app
/// uninstall (uninstall hygiene, unlike the iOS Keychain, which survives uninstall and would leak operationIds
/// across installs). Mirrors Kotlin's `NoBackupFileOrphanStore`.
///
/// **Why a file and not `UserDefaults`.** A dedicated `UserDefaults` suite would ISOLATE the record from the
/// merchant's defaults but not EXCLUDE it from their backup: a `UserDefaults` plist goes to iCloud like any other
/// app data, and the SDK cannot change that from a plist. So the record lives in a directory this SDK marks
/// `isExcludedFromBackupKey`. Android reaches the same place from the other side: there a library cannot opt out
/// through the manifest at all (`dataExtractionRules`/`fullBackupContent` are `<application>` attributes that merge
/// into the merchant's), so it writes under `noBackupFilesDir`.
///
/// **Threading.** Both `read` and `write` do disk I/O on the CALLING thread, which can be the main thread. The lock
/// here guards one instance; serialization ACROSS instances comes from `OrphanMetadataStore`'s process-wide lock,
/// held around every read-modify-write. One write per payment reaching the payer-in-limbo terminal, of a few hundred
/// bytes, is not a hot path; callers that care own the thread choice.
final class NoBackupFileOrphanStore: OrphanStringStore {
    private let directory: URL
    private let file: URL
    private let lock = NSLock()

    /// Moving this container once apps hold records in it is a MIGRATION: the new location needs a
    /// read-old-write-new path kept around for a release cycle.
    ///
    /// `containerDirectory` is injected by tests; production resolves Application Support, which is the
    /// documented home for app data the user does not manage directly (not `Documents`, which is user-facing
    /// and iCloud-synced; not `Caches`, which the system may purge out from under a pending orphan record).
    /// A nil resolution keeps the fail-soft posture by falling back to a temporary directory rather than
    /// trapping: losing the record costs an unreconciled payment, crashing costs the payment RESULT.
    init(containerDirectory: URL? = nil) {
        let base = containerDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent(Self.directoryName, isDirectory: true)
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(Self.directoryName, isDirectory: true)
        self.directory = base
        self.file = base.appendingPathComponent(Self.fileName, isDirectory: false)
    }

    func read() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: file) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func write(_ value: String) {
        lock.lock(); defer { lock.unlock() }
        guard ensureDirectory() else { return }
        try? Data(value.utf8).write(to: file, options: .atomic)
    }

    /// Creates the container if absent and (re-)applies `isExcludedFromBackupKey` to the DIRECTORY.
    ///
    /// **Why the directory and not the file.** Every write is atomic (a new file replaces the old one), and an
    /// exclusion flag set on a file does not survive that file being replaced.
    /// Marking the container covers every future write without anyone having to remember to re-apply it.
    /// Returns false when the container cannot be made usable, so `write` degrades to a no-op instead of
    /// throwing (fail-soft).
    @discardableResult
    private func ensureDirectory() -> Bool {
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDir) {
            guard (try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )) != nil else { return false }
        } else if !isDir.boolValue {
            return false // a regular file squats the container path — nothing usable here
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = directory
        try? mutable.setResourceValues(values)
        return true
    }

    /// The resolved container — asserted by `NoBackupFileOrphanStoreTests` for the backup-exclusion flag.
    var directoryForTest: URL { directory }

    /// Mirrors Android's file name so the two platforms read the same on disk.
    static let fileName = "orphan_metadata.json"
    /// The SDK-owned container inside Application Support, the directory `ensureDirectory` marks backup-excluded.
    static let directoryName = "com.khipu.nativesdk.orphan_metadata"
}

/// The local orphan-metadata store. Persists the IDs of payments that went to the payer-in-limbo terminal
/// (timeout/cancelled/closed while live) so a closed/cold-restart orphan can be SURFACED via
/// `onOrphanedPaymentDetected` on a later launch, and auto-purges anything older than 30 days so the store never
/// grows unbounded.
///
/// **Wall clock, not monotonic:** the 30-day window spans process lifetimes and reboots; monotonic
/// `CLOCK_MONOTONIC` resets on reboot and would never reach 30 days. `clockMs` is injected (house DI) with a real
/// wall default and a test fast-forward seam. A backward NTP jump merely WIDENS the window (we never purge early:
/// safe); a forward one is handled by the clamp in `purgeLocked`.
///
/// **Bounded growth / on-access purge:** `purgeExpired()` runs SYNCHRONOUSLY on every load/access (no background
/// job, as in `DiagnosticsRecorder`'s purge). **Fail-soft:** corrupt/absent blob → empty (never throws out of
/// `init`/`start`/`close`); a write failure is swallowed (the in-flight result delivery has priority).
/// **Deferred-telemetry discipline:** the purge fields are collected under `lock` and
/// `reconciliation.metadata_purged` is emitted AFTER release. Mirrors Kotlin.
final class OrphanMetadataStore {
    private let store: OrphanStringStore
    private let clockMs: () -> Int64
    private let ttlMs: Int64
    private let telemetry: TelemetrySink

    /// PROCESS-WIDE, not per-instance. Every instance serializes its OWN read-modify-write, but two instances in
    /// one process write the SAME backing file, so with distinct locks an interleave would drop a record: A reads
    /// {r1}, B reads {r1}, A writes {r1,r2}, B writes {r1,r3}, r2 gone. A dropped orphan record is a payment that
    /// silently never gets reconciled, since the record IS what a later launch surfaces through
    /// `onOrphanedPaymentDetected`. Nothing prevents a merchant from constructing two `KhipuPayment` instances or
    /// calling the public API off-main, so "one coordinator per process" cannot be assumed. The writes are small
    /// and infrequent (payment terminal), so the added contention is immaterial.
    /// LIMIT, stated rather than implied: this does NOT cover a multi-PROCESS app. A plain file is not
    /// cross-process safe either, so that case needs a different mechanism and is out of scope. Behaviorally
    /// identical to Kotlin.
    private let lock = OrphanMetadataStore.processLock
    private static let processLock = NSLock()

    static let dayMs: Int64 = 24 * 60 * 60 * 1000
    static let defaultTtlMs: Int64 = 30 * 24 * 60 * 60 * 1000 // 30 days

    init(
        store: OrphanStringStore,
        clockMs: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
        ttlMs: Int64 = OrphanMetadataStore.defaultTtlMs,
        telemetry: TelemetrySink = NoopTelemetrySink()
    ) {
        self.store = store
        self.clockMs = clockMs
        self.ttlMs = ttlMs
        self.telemetry = telemetry
    }

    /// Persist `operationId` → record (overwriting any prior record for the same id), stamping
    /// `recordedAtWallMs` with the wall clock NOW. Purges expired entries first (on-access). Best-effort and
    /// fail-soft (a storage/serialization failure is swallowed).
    func put(operationId: String, debugId: String, lastKnownState: String) {
        lock.lock()
        var map = loadLocked()
        let purged = purgeLocked(&map)
        map[operationId] = OrphanRecord(
            operationId: operationId, debugId: debugId, lastKnownState: lastKnownState, recordedAtWallMs: clockMs())
        writeLocked(map)
        lock.unlock()
        emitPurge(purged)
    }

    /// Return ALL live records and REMOVE them (surface-then-remove: they never re-fire on a later launch).
    /// Purges expired entries first (on-access). Order: oldest first (deterministic, parity-pinned).
    func drainAll() -> [OrphanRecord] {
        lock.lock()
        var map = loadLocked()
        let purged = purgeLocked(&map)
        let live = map.values.sorted { $0.recordedAtWallMs < $1.recordedAtWallMs }
        map.removeAll()
        writeLocked(map)
        lock.unlock()
        emitPurge(purged)
        return live
    }

    /// Remove one record by merchant `operationId` (fail-soft no-op if absent).
    func remove(operationId: String) {
        lock.lock()
        var map = loadLocked()
        if map.removeValue(forKey: operationId) != nil { writeLocked(map) }
        lock.unlock()
    }

    /// On-access purge of entries older than `ttlMs` by WALL clock. Emits `reconciliation.metadata_purged` with
    /// `purged_count` (+ `oldest_age_days`) when >0; no-op telemetry when 0.
    func purgeExpired() {
        lock.lock()
        var map = loadLocked()
        let purged = purgeLocked(&map)
        // Write when a clamp happened too: otherwise the pulled-back timestamp is recomputed on every access and
        // never persisted, so the TTL never actually starts running.
        if purged.count > 0 || purged.clamped > 0 { writeLocked(map) }
        lock.unlock()
        emitPurge(purged)
    }

    /// `clamped` = records whose FUTURE timestamp was pulled back to now: a reason to WRITE even when nothing was
    /// purged, or the clamp would be recomputed on every access and never persisted.
    private struct PurgeResult { let count: Int; let oldestAgeDays: Int64; var clamped: Int = 0 }

    /// Read the blob and parse it fail-soft into an `operationId`-keyed map; corrupt/absent → empty (never throws).
    private func loadLocked() -> [String: OrphanRecord] {
        guard let blob = store.read(), let data = blob.data(using: .utf8) else { return [:] }
        let list = (try? JSONDecoder().decode([OrphanRecord].self, from: data)) ?? []
        var map: [String: OrphanRecord] = [:]
        for r in list { map[r.operationId] = r }
        return map
    }

    /// Serialize the record list and write it; a storage/serialization failure is swallowed (fail-soft). Sorted
    /// keys for a deterministic on-disk blob.
    private func writeLocked(_ map: [String: OrphanRecord]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        // Stable element order (oldest first) so the blob is deterministic across writes (forensic/test parity).
        let list = map.values.sorted { $0.recordedAtWallMs < $1.recordedAtWallMs }
        guard let data = try? encoder.encode(list), let json = String(data: data, encoding: .utf8) else { return }
        store.write(json)
    }

    /// Remove entries whose wall-clock age >= `ttlMs`; return the count + the oldest removed age in whole days,
    /// plus how many records had a FUTURE timestamp clamped.
    ///
    /// **The clamp.** A record stamped in the future (a forward NTP jump at persist time, later corrected back)
    /// yields a NEGATIVE age, which is never `>= ttlMs`, so without the clamp it would leak until app uninstall:
    /// the 30-day bounded-growth backstop would not apply to it. Clamping to `now` (rather than treating a future
    /// stamp as purgeable) is the conservative option: the TTL restarts from now and the record eventually
    /// expires, while a transient forward jump at READ time can never delete a still-valid record. Behaviorally
    /// identical to Kotlin.
    private func purgeLocked(_ map: inout [String: OrphanRecord]) -> PurgeResult {
        let now = clockMs()
        var clamped = 0
        for r in map.values where r.recordedAtWallMs > now {
            map[r.operationId] = OrphanRecord(
                operationId: r.operationId,
                debugId: r.debugId,
                lastKnownState: r.lastKnownState,
                recordedAtWallMs: now
            )
            clamped += 1
        }
        let expired = map.values.filter { now - $0.recordedAtWallMs >= ttlMs }
        if expired.isEmpty { return PurgeResult(count: 0, oldestAgeDays: 0, clamped: clamped) }
        let oldestAgeMs = expired.map { now - $0.recordedAtWallMs }.max() ?? 0
        for r in expired { map.removeValue(forKey: r.operationId) }
        return PurgeResult(count: expired.count, oldestAgeDays: oldestAgeMs / Self.dayMs, clamped: clamped)
    }

    /// Emit `reconciliation.metadata_purged` AFTER the lock is released (deferred-telemetry); no-op when nothing purged.
    private func emitPurge(_ purged: PurgeResult) {
        guard purged.count > 0 else { return }
        telemetry.emit(
            event: TelemetryEvent.metadataPurged,
            fields: [
                "purged_count": purged.count,
                "oldest_age_days": purged.oldestAgeDays,
                "severity": "warn",
            ]
        )
    }
}
