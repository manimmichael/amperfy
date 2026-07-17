//
//  DiagnosticCrashReporter.swift
//  AmperfyKit
//
//  Cassette fork — Diagnostics Phase 1 (on-device crash capture via MetricKit).
//
//  MetricKit delivers crash and hang reports on the NEXT launch, on-device,
//  with no third-party SDK — which keeps observability 100% Apple-native, like
//  the rest of the app. Registered once at launch (`start()`), it writes each
//  diagnostic payload next to the last rolling-buffer snapshot
//  (`DiagnosticLog.diagnosticsDirectory()`), so a crash report sits beside
//  "what the app was doing right before". The buffer's debounced/background
//  flush is what guarantees a recent snapshot exists when the crash happened.
//
//  Guarded by `canImport(MetricKit)` so non-iOS build configs compile to a
//  no-op rather than failing to link.
//

import Foundation
import os.log

#if canImport(MetricKit)
  import MetricKit

  // MARK: - DiagnosticCrashReporter

  public final class DiagnosticCrashReporter: NSObject, MXMetricManagerSubscriber,
    @unchecked Sendable {
    public static let shared = DiagnosticCrashReporter()

    private let log = OSLog(subsystem: "Amperfy", category: "DiagnosticCrashReporter")
    private let registerLock = NSLock()
    private var isRegistered = false

    override private init() { super.init() }

    /// Register as a MetricKit subscriber. Idempotent; safe to call at launch.
    public func start() {
      registerLock.lock()
      defer { registerLock.unlock() }
      guard !isRegistered else { return }
      isRegistered = true
      MXMetricManager.shared.add(self)
      os_log("MetricKit crash capture registered", log: log, type: .info)
    }

    // MARK: MXMetricManagerSubscriber

    public func didReceive(_ payloads: [MXMetricPayload]) {
      // Metrics (launch time, hangs, battery, …) are informational here. Note
      // their arrival in the trace; persist the raw payloads alongside the
      // snapshot for later inspection.
      DiagnosticLog.shared.log(
        .lifecycle,
        "MetricKit: received \(payloads.count) metric payload(s)"
      )
      for (index, payload) in payloads.enumerated() {
        write(payload.jsonRepresentation(), prefix: "metrics", index: index)
      }
      prune(prefix: "metrics", keep: 10)
    }

    public func didReceive(_ payloads: [MXDiagnosticPayload]) {
      // Diagnostics carry crash + hang + disk-write-exception reports from the
      // previous session. This is the headline "what happened when it died" data.
      DiagnosticLog.shared.log(
        .crashContext,
        "MetricKit: received \(payloads.count) diagnostic payload(s) from a previous session"
      )
      for (index, payload) in payloads.enumerated() {
        write(payload.jsonRepresentation(), prefix: "crash", index: index)
      }
      // Prune is upload-aware for crashes (never deletes an un-acknowledged file),
      // so it can't drop a report before it's sent even though it runs before the
      // async drain completes.
      prune(prefix: "crash", keep: 20, protectUnuploaded: true)

      // Upload the freshly written (and any still-pending) crash reports. Idempotent
      // via the upload ledger, so overlapping with the launch drain is safe.
      if DiagnosticsConfig.isUploadEnabled {
        Task.detached(priority: .utility) {
          await DiagnosticsConfig.sharedUploader.drainPendingCrashReports()
        }
      }
    }

    // MARK: Disk

    /// Keep only the most recent `keep` files for a prefix so the diagnostics
    /// directory can't grow without bound (MetricKit delivers a metrics payload
    /// ~daily even with no crashes). Filenames are `yyyyMMdd-HHmmss`-stamped, so
    /// a lexicographic sort is chronological — drop the oldest.
    ///
    /// `protectUnuploaded` guarantees the crash drain never loses data: an oldest
    /// file that hasn't been acknowledged in the upload ledger is skipped rather
    /// than deleted. It may briefly exceed `keep` while uploads are failing, which
    /// is the correct trade — nothing is dropped unsent.
    private func prune(prefix: String, keep: Int, protectUnuploaded: Bool = false) {
      guard let dir = DiagnosticLog.diagnosticsDirectory(),
            let files = try? FileManager.default.contentsOfDirectory(
              at: dir,
              includingPropertiesForKeys: nil
            ) else { return }
      let matching = files
        .filter { $0.lastPathComponent.hasPrefix("\(prefix)-") }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
      let excess = matching.count - keep
      guard excess > 0 else { return }
      for url in matching.prefix(excess) {
        let filename = url.lastPathComponent
        if protectUnuploaded, !DiagnosticUploadLedger.isUploaded(filename) { continue }
        try? FileManager.default.removeItem(at: url)
        // Once the file is gone its ledger bookkeeping is dead weight — drop it.
        DiagnosticUploadLedger.forget(filename)
      }
    }

    private func write(_ data: Data, prefix: String, index: Int) {
      guard let dir = DiagnosticLog.diagnosticsDirectory() else { return }
      // Formatter built locally: DateFormatter isn't Sendable, so it can't be a
      // shared static under Swift 6 strict concurrency. Writes are rare.
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.dateFormat = "yyyyMMdd-HHmmss"
      let stamp = formatter.string(from: Date())
      let url = dir.appendingPathComponent("\(prefix)-\(stamp)-\(index).json")
      do {
        try data.write(to: url, options: .atomic)
        os_log(
          "MetricKit payload written: %{public}@",
          log: log,
          type: .info,
          url.lastPathComponent
        )
      } catch {
        os_log(
          "MetricKit payload write failed: %{public}@",
          log: log,
          type: .error,
          error.localizedDescription
        )
      }
    }
  }

#else

  // MARK: - DiagnosticCrashReporter (MetricKit unavailable)

  public final class DiagnosticCrashReporter: @unchecked Sendable {
    public static let shared = DiagnosticCrashReporter()
    private init() {}
    public func start() {}
  }

#endif
