//
//  DiagnosticLog.swift
//  AmperfyKit
//
//  Cassette fork — Diagnostics Phase 1 (rolling diagnostic log).
//
//  An always-on, in-memory ring buffer that captures what the app was doing in
//  the minutes before something went weird. This is NOT the CoreData event log
//  (`EventLogger`/`LogEntry`) — that stays as-is for discrete persisted events.
//  This buffer is the high-frequency trace, kept off the hot path:
//
//    • Fixed-capacity, preallocated storage with O(1) index-wrap append. No
//      per-event allocation after warmup, no per-event disk write.
//    • All mutation is confined to one serial queue. `append` enqueues and
//      returns immediately, so it never blocks a caller (notably the audio
//      thread, via the player observer / BackendAudioPlayer error paths).
//    • Disk flush is throttled: a debounced coalescing timer plus explicit
//      flushes on mark-moment, app-background and termination. The snapshot
//      file is what pairs with a MetricKit crash report on the next launch.
//
//  On flush / mark / crash the buffer would also be handed to the upload seam
//  (`DiagnosticUploader`) — but that is a no-op this phase (`DiagnosticsConfig`
//  is off and only `NoopDiagnosticUploader` exists). See DiagnosticUploader.swift.
//

import Foundation
import os.log

// MARK: - DiagnosticLog

public final class DiagnosticLog: @unchecked Sendable {
  public static let shared = DiagnosticLog()

  /// Target capacity. ~2,000 entries is a few minutes of busy playback +
  /// CarPlay + API traffic, which is the window we care about.
  public static let defaultCapacity = 2_000

  private let log = OSLog(subsystem: "Amperfy", category: "DiagnosticLog")

  /// Everything below is touched ONLY on `queue`.
  private let queue = DispatchQueue(label: "digital.cassette.diagnostics", qos: .utility)
  private let capacity: Int
  private var storage: [DiagnosticEntry?]
  private var head = 0 // index of the next write
  private var count = 0 // number of valid entries (≤ capacity)

  private let flushDebounce: TimeInterval = 3.0
  private var pendingFlush = false
  private var flushTimerArmed = false

  private let uploader: DiagnosticUploader = NoopDiagnosticUploader()

  public init(capacity: Int = DiagnosticLog.defaultCapacity) {
    self.capacity = max(1, capacity)
    self.storage = Array(repeating: nil, count: self.capacity)
  }

  // MARK: Append

  /// Fire-and-return. Hands the entry to the serial queue and returns
  /// immediately; callers never wait on the buffer.
  public func append(_ entry: DiagnosticEntry) {
    queue.async {
      self.storage[self.head] = entry
      self.head = (self.head + 1) % self.capacity
      if self.count < self.capacity { self.count += 1 }
      self.scheduleDebouncedFlushLocked()
    }
  }

  /// Convenience: build + append a breadcrumb. `Date()` is captured at call
  /// time so ordering reflects when the event happened, not when it's stored.
  public func log(
    _ category: DiagnosticCategory,
    _ message: String,
    context: [String: String]? = nil
  ) {
    append(DiagnosticEntry(
      timestamp: Date(),
      category: category,
      message: message,
      context: context
    ))
  }

  /// "Mark this moment" — append a marker and force an immediate flush so the
  /// snapshot on disk includes everything up to the mark.
  public func mark(_ label: String, context: [String: String]? = nil) {
    append(DiagnosticEntry(
      timestamp: Date(),
      category: .marker,
      message: label,
      context: context
    ))
    flushNow()
  }

  // MARK: Read

  /// A copy of the buffer, oldest → newest. Synchronized.
  public func snapshot() -> [DiagnosticEntry] {
    queue.sync { snapshotLocked() }
  }

  private func snapshotLocked() -> [DiagnosticEntry] {
    guard count > 0 else { return [] }
    var result = [DiagnosticEntry]()
    result.reserveCapacity(count)
    let start = (head - count + capacity) % capacity
    for offset in 0 ..< count {
      if let entry = storage[(start + offset) % capacity] {
        result.append(entry)
      }
    }
    return result
  }

  // MARK: Flush

  /// Throttled flush request. Coalesces a burst of appends into at most one
  /// disk write per `flushDebounce` window. Must be called on `queue`.
  private func scheduleDebouncedFlushLocked() {
    pendingFlush = true
    guard !flushTimerArmed else { return }
    flushTimerArmed = true
    queue.asyncAfter(deadline: .now() + flushDebounce) {
      self.flushTimerArmed = false
      if self.pendingFlush {
        self.pendingFlush = false
        self.writeToDiskLocked()
      }
    }
  }

  /// Synchronous flush — BLOCKS the caller until the snapshot is on disk. Used on
  /// the lifecycle/termination paths (scene background, terminate) and for
  /// mark-moment, so a flagged moment (or the pre-crash trace) durably reaches
  /// disk rather than racing process teardown / suspension on the background
  /// queue. The write is a few KB, so briefly blocking the main actor is fine.
  /// MUST NOT be called from `queue` itself — that would deadlock.
  public func flushNow() {
    queue.sync {
      self.pendingFlush = false
      self.flushTimerArmed = false // disarm any pending debounce; this write supersedes it
      self.writeToDiskLocked()
    }
  }

  /// Must be called on `queue`.
  private func writeToDiskLocked() {
    let entries = snapshotLocked()
    guard let url = Self.snapshotFileURL() else { return }
    do {
      // Encoder built locally: JSONEncoder isn't Sendable, so it can't be a
      // shared static under Swift 6 strict concurrency. Flush is infrequent.
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(entries)
      try data.write(to: url, options: .atomic)
      maybeUploadLocked(data)
    } catch {
      os_log("DiagnosticLog flush failed: %{public}@", log: log, type: .error, error.localizedDescription)
    }
  }

  /// Upload seam — OFF this phase. `DiagnosticsConfig.isUploadEnabled` is false
  /// and `uploader` is the no-op, so this never touches the network. Phase 2
  /// implements a real `DiagnosticUploader` and flips the flag.
  private func maybeUploadLocked(_ payload: Data) {
    guard DiagnosticsConfig.isUploadEnabled else { return }
    let uploader = self.uploader
    Task.detached { await uploader.upload(payload) }
  }

  // MARK: Disk locations

  /// `…/Application Support/Diagnostics`, created on demand. Application
  /// Support (not Caches) so a snapshot survives to pair with a crash report,
  /// and stays out of the user-visible Documents container.
  public static func diagnosticsDirectory() -> URL? {
    guard let base = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first else { return nil }
    var dir = base.appendingPathComponent("Diagnostics", isDirectory: true)
    if !FileManager.default.fileExists(atPath: dir.path) {
      try? FileManager.default.createDirectory(
        at: dir,
        withIntermediateDirectories: true
      )
      // Reproducible local telemetry — keep it out of iCloud / device backups so
      // the snapshot + crash payloads never bloat the user's backup.
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      try? dir.setResourceValues(values)
    }
    return dir
  }

  /// The single overwrite file holding the latest rolling-buffer snapshot.
  public static func snapshotFileURL() -> URL? {
    diagnosticsDirectory()?.appendingPathComponent("rolling-buffer.json")
  }
}
