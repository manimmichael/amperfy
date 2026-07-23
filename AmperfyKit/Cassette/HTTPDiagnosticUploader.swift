//
//  HTTPDiagnosticUploader.swift
//  AmperfyKit
//
//  Cassette fork — Diagnostics Phase 2 (real uploader + crash drain).
//
//  The live `DiagnosticUploader`, replacing the Phase 1 no-op. It talks to the
//  diagnostics spine at cassette.digital and mirrors CassetteSyncAPI's
//  networking: an ephemeral URLSession behind the auth-preserving redirect
//  delegate, an optional bearer (the reports endpoint is anonymous-allowed — a
//  bearer just lets the server stamp the account), and the device-id header.
//
//  Two jobs:
//    • `drainPendingCrashReports()` — on the NEXT launch (MetricKit is
//      post-mortem), upload every not-yet-acknowledged `crash-*.json`. We do NOT
//      install a crash-time signal handler that flushes/encodes from inside a
//      dying process (that is async-signal-unsafe and can deadlock or re-trap);
//      the residual is a small tail-loss window if the app is deleted before the
//      next launch drains, which is acceptable for post-mortem MetricKit data.
//    • `submitExport(...)` — the explicit, user-consented full diagnostics
//      upload behind the Settings action.
//
//  Large blobs (the raw MetricKit payload, the full rolling trace, the full
//  export) are never inlined: they are declared as attachments and PUT to the
//  presigned URL the server returns, then acknowledged via /attachments/complete.
//

import Foundation
import os.log

// MARK: - HTTPDiagnosticUploader

public final class HTTPDiagnosticUploader: DiagnosticUploader, @unchecked Sendable {
  // The CANONICAL host. `cassette.digital` 307-redirects to `www.` — and on a
  // redirect URLSession hands the delegate a `newRequest` with NO httpBody, so a
  // POST re-issued to `www.` arrives body-less and the spine rejects it (every
  // iOS report silently failed this way). Posting straight to `www.` avoids the
  // redirect entirely, matching the Android client (Cassette.BASE_URL) + the web.
  private static let apiBase = "https://www.cassette.digital"

  private let log = OSLog(subsystem: "Amperfy", category: "HTTPDiagnosticUploader")

  // Ephemeral session with the same auth-preserving redirect delegate the sync
  // client uses, so a Vercel redirect before the route handler doesn't strip a
  // bearer we did send.
  private lazy var session: URLSession = .init(
    configuration: .ephemeral,
    delegate: CassetteAuthPreservingDelegate(),
    delegateQueue: nil
  )

  /// Serialize drains so a launch drain and a just-delivered-payload drain can't
  /// race the same files.
  private let drainGate = NSLock()
  private var isDraining = false

  public init() {}

  // MARK: Crash drain

  /// Claim the single-flight drain slot. Synchronous on purpose: NSLock's
  /// lock()/unlock() are unavailable from async contexts (they can block a
  /// cooperative-pool thread), so the guarded check-and-set stays OUT of the async
  /// drain and the lock is never held across an await. False = a drain is running.
  private func claimDrainSlot() -> Bool {
    drainGate.lock()
    defer { drainGate.unlock() }
    if isDraining { return false }
    isDraining = true
    return true
  }

  private func releaseDrainSlot() {
    drainGate.lock()
    defer { drainGate.unlock() }
    isDraining = false
  }

  public func drainPendingCrashReports() async {
    guard DiagnosticsConfig.isUploadEnabled else { return }

    // Single-flight: claim/release through the synchronous helpers above so NSLock
    // is never touched from this async context.
    guard claimDrainSlot() else { return }
    defer { releaseDrainSlot() }

    guard let dir = DiagnosticLog.diagnosticsDirectory(),
          let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
          ) else { return }

    // Oldest first (filenames are timestamp-stamped), skip anything already
    // acknowledged. Crash-time trace is preserved out of band at launch, so
    // attach that snapshot rather than the live (already-overwritten) buffer.
    let pending = files
      .filter { $0.lastPathComponent.hasPrefix("crash-") && $0.pathExtension == "json" }
      .filter { !DiagnosticUploadLedger.isUploaded($0.lastPathComponent) }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
    guard !pending.isEmpty else { return }

    let traceURL = DiagnosticLog.lastSessionSnapshotFileURL()
      .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    let breadcrumbs = traceURL.flatMap(Self.decodeTrace) ?? []

    for crashURL in pending {
      await drainOne(crashURL: crashURL, traceURL: traceURL, breadcrumbs: breadcrumbs)
    }
  }

  private func drainOne(crashURL: URL, traceURL: URL?, breadcrumbs: [DiagnosticEntry]) async {
    let filename = crashURL.lastPathComponent
    guard let crashBytes = try? Data(contentsOf: crashURL),
          let payload = DiagnosticCrashPayload(fileURL: crashURL) else {
      // Unreadable/garbled file: mark it acknowledged so it stops blocking the
      // drain and becomes prunable. It's already lost either way.
      DiagnosticUploadLedger.markUploaded(filename)
      os_log("crash drain: skipping unreadable %{public}@", log: log, type: .error, filename)
      return
    }

    let iso = ISO8601DateFormatter()
    var report = DiagnosticReport(
      idempotencyKey: DiagnosticUploadLedger.idempotencyKey(for: filename),
      reportType: payload.reportType,
      appVersion: payload.appVersion ?? Self.bundleShortVersion,
      installId: DiagnosticInstallIdentity.installId,
      occurredAt: iso.string(from: payload.occurredAt)
    )
    report.appBuild = payload.appBuild ?? Self.bundleVersion
    report.osName = "iOS"
    report.osVersion = payload.osVersion
    // device_model here is the precise MetricKit `deviceType` (e.g. "iPhone15,2"),
    // which is better than the export path's generic UIDevice.model "iPhone".
    report.deviceModel = payload.deviceModel
    report.deviceId = CassetteSyncAPI.deviceId
    report.severity = payload.severity
    report.title = payload.title
    report.fingerprint = payload.fingerprint
    report.crashSummary = payload.summary
    report.context = DiagnosticReport.breadcrumbContext(
      breadcrumbs,
      extra: ["trace_source": .string("previous_session")]
    )
    report.consent = DiagnosticConsent(
      userConsented: false, // opt-out: crashes auto-upload without an explicit share
      uploadEnabled: DiagnosticsConfig.isUploadEnabled,
      containsPii: false,
      redacted: false
    )

    var declarations = [
      DiagnosticAttachmentDeclaration(
        slot: "metrickit_crash",
        kind: "metrickit_crash",
        contentType: "application/json",
        byteSize: crashBytes.count
      ),
    ]
    var attachmentBytes: [String: Data] = ["metrickit_crash": crashBytes]
    if let traceURL, let traceBytes = try? Data(contentsOf: traceURL) {
      declarations.append(DiagnosticAttachmentDeclaration(
        slot: "rolling_trace",
        kind: "rolling_trace",
        contentType: "application/json",
        byteSize: traceBytes.count
      ))
      attachmentBytes["rolling_trace"] = traceBytes
    }
    report.attachments = declarations

    guard let response = await postReport(report) else {
      // Network/HTTP failure — leave un-acknowledged so the next launch retries
      // with the same idempotency key.
      return
    }

    // Deduped means the server already has this report; there may still be
    // attachment slots it's missing, so honour any uploads it hands back.
    guard await uploadAttachments(
      response.attachmentUploads,
      bytes: attachmentBytes,
      reportId: response.id,
      idempotencyKey: report.idempotencyKey
    ) else {
      // An attachment PUT/complete failed — don't acknowledge; retry next launch.
      return
    }

    DiagnosticUploadLedger.markUploaded(filename)
    os_log("crash drain: uploaded %{public}@", log: log, type: .info, filename)
  }

  // MARK: Explicit export

  /// Upload the full diagnostics export the user chose to share. Called from the
  /// Settings action (user-driven → `user_consented=true`). Device fields are
  /// provided by the caller, which reads them on the main actor.
  public func submitExport(
    payload: Data,
    occurredAt: Date,
    deviceModel: String,
    osVersion: String,
    breadcrumbs: [DiagnosticEntry]
  ) async
    -> Bool {
    let iso = ISO8601DateFormatter()
    var report = DiagnosticReport(
      idempotencyKey: UUID().uuidString,
      reportType: "diagnostic_export",
      appVersion: Self.bundleShortVersion,
      installId: DiagnosticInstallIdentity.installId,
      occurredAt: iso.string(from: occurredAt)
    )
    report.appBuild = Self.bundleVersion
    report.osName = "iOS"
    report.osVersion = osVersion
    // followUp: UIDevice.current.model is the generic family ("iPhone"). A precise
    // model needs sysctl("hw.machine"); the crash path already gets the exact
    // model from the MetricKit payload's deviceType.
    report.deviceModel = deviceModel
    report.deviceId = CassetteSyncAPI.deviceId
    report.severity = "info"
    report.title = "Diagnostic export"
    report.context = DiagnosticReport.breadcrumbContext(breadcrumbs)
    report.consent = DiagnosticConsent(
      userConsented: true, // explicit user share
      uploadEnabled: DiagnosticsConfig.isUploadEnabled,
      containsPii: true, // full export carries library + settings state
      redacted: false
    )
    report.attachments = [
      DiagnosticAttachmentDeclaration(
        slot: "full_export",
        kind: "diagnostic_export",
        contentType: "application/json",
        byteSize: payload.count
      ),
    ]

    guard let response = await postReport(report) else { return false }
    return await uploadAttachments(
      response.attachmentUploads,
      bytes: ["full_export": payload],
      reportId: response.id,
      idempotencyKey: report.idempotencyKey
    )
  }

  // MARK: Manual feedback

  /// Upload a MANUAL user-feedback report. User-initiated → ALWAYS sent, with no
  /// `isUploadEnabled` gate (that flag only governs the AUTO crash drain). The
  /// free-text `message` rides inline as `user_message`; an optional key-window
  /// PNG rides as a `screenshot` attachment (content_type image/png) via the same
  /// presign two-step. Device fields are read by the caller on the main actor.
  public func submitFeedback(
    message: String,
    screenshot: Data?,
    deviceModel: String,
    osVersion: String,
    breadcrumbs: [DiagnosticEntry]
  ) async
    -> Bool {
    let iso = ISO8601DateFormatter()
    var report = DiagnosticReport(
      idempotencyKey: UUID().uuidString,
      reportType: "user_feedback",
      appVersion: Self.bundleShortVersion,
      installId: DiagnosticInstallIdentity.installId,
      occurredAt: iso.string(from: Date())
    )
    report.appBuild = Self.bundleVersion
    report.osName = "iOS"
    report.osVersion = osVersion
    report.deviceModel = deviceModel
    report.deviceId = CassetteSyncAPI.deviceId
    report.severity = "info"
    report.title = "User feedback"
    report.userMessage = message
    report.context = DiagnosticReport.breadcrumbContext(breadcrumbs)
    report.consent = DiagnosticConsent(
      userConsented: true, // manual, user-initiated
      uploadEnabled: DiagnosticsConfig.isUploadEnabled,
      containsPii: true, // free text + optional screenshot may carry PII
      redacted: false
    )

    var attachmentBytes: [String: Data] = [:]
    var contentTypes: [String: String] = [:]
    if let screenshot, !screenshot.isEmpty {
      report.attachments = [
        DiagnosticAttachmentDeclaration(
          slot: "screenshot",
          kind: "screenshot",
          contentType: "image/png",
          byteSize: screenshot.count
        ),
      ]
      attachmentBytes["screenshot"] = screenshot
      contentTypes["screenshot"] = "image/png"
    }

    guard let response = await postReport(report) else { return false }
    return await uploadAttachments(
      response.attachmentUploads,
      bytes: attachmentBytes,
      contentTypes: contentTypes,
      reportId: response.id,
      idempotencyKey: report.idempotencyKey
    )
  }

  // MARK: Networking

  private func postReport(_ report: DiagnosticReport) async -> DiagnosticReportResponse? {
    guard let url = URL(string: Self.apiBase + "/api/diagnostics/reports") else { return nil }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 30
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    applyOptionalAuth(&request)

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    guard let body = try? encoder.encode(report) else { return nil }
    request.httpBody = body

    do {
      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else { return nil }
      guard (200 ..< 300).contains(http.statusCode) else {
        os_log(
          "diagnostics report POST failed: %d",
          log: log,
          type: .error,
          http.statusCode
        )
        return nil
      }
      return try? JSONDecoder().decode(DiagnosticReportResponse.self, from: data)
    } catch {
      os_log(
        "diagnostics report POST error: %{public}@",
        log: log,
        type: .error,
        error.localizedDescription
      )
      return nil
    }
  }

  /// PUT each presigned attachment, then acknowledge it. Returns true only if
  /// every upload the server asked for completed (or it asked for none).
  /// `contentTypes` overrides the PUT `Content-Type` per slot (defaulting to
  /// `application/json`) so a `screenshot` slot PUTs as `image/png` — the header
  /// must match the content_type the server presigned the URL with, or R2 rejects
  /// the signature.
  private func uploadAttachments(
    _ uploads: [DiagnosticAttachmentUpload]?,
    bytes: [String: Data],
    contentTypes: [String: String] = [:],
    reportId: String,
    idempotencyKey: String
  ) async
    -> Bool {
    guard let uploads, !uploads.isEmpty else { return true }
    for upload in uploads {
      guard let data = bytes[upload.slot] else {
        // Server asked for a slot we didn't declare bytes for — nothing to send.
        continue
      }
      let contentType = contentTypes[upload.slot] ?? "application/json"
      guard await putAttachment(data, contentType: contentType, to: upload.presignedUrl)
      else { return false }
      guard await completeAttachment(
        reportId: reportId,
        idempotencyKey: idempotencyKey,
        slot: upload.slot,
        byteSize: data.count
      ) else { return false }
    }
    return true
  }

  private func putAttachment(
    _ bytes: Data,
    contentType: String,
    to presignedUrl: String
  ) async
    -> Bool {
    guard let url = URL(string: presignedUrl) else { return false }
    var request = URLRequest(url: url)
    request.httpMethod = "PUT"
    request.timeoutInterval = 60
    request.setValue(contentType, forHTTPHeaderField: "Content-Type")
    request.httpBody = bytes
    do {
      let (_, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode)
      else { return false }
      return true
    } catch {
      return false
    }
  }

  private func completeAttachment(
    reportId: String,
    idempotencyKey: String,
    slot: String,
    byteSize: Int
  ) async
    -> Bool {
    let encodedId = reportId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
      ?? reportId
    guard let url = URL(
      string: Self.apiBase + "/api/diagnostics/reports/\(encodedId)/attachments/complete"
    ) else { return false }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 30
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    applyOptionalAuth(&request)

    let body: [String: Any] = [
      "idempotency_key": idempotencyKey,
      "slot": slot,
      "byte_size": byteSize,
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: body) else { return false }
    request.httpBody = data
    do {
      let (_, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode)
      else { return false }
      return true
    } catch {
      return false
    }
  }

  /// The reports endpoint is anonymous-allowed. If a bearer happens to be present
  /// we send it (the server stamps the account); otherwise the report is
  /// anonymous. The device-id header rides along for correlation, matching the
  /// sync client.
  private func applyOptionalAuth(_ request: inout URLRequest) {
    if let token = CassetteSyncAPI.bearerToken {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    request.setValue(CassetteSyncAPI.deviceId, forHTTPHeaderField: "X-Cassette-Device-Id")
  }

  // MARK: Helpers

  private static var bundleShortVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
  }

  private static var bundleVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
  }

  private static func decodeTrace(_ url: URL) -> [DiagnosticEntry]? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode([DiagnosticEntry].self, from: data)
  }
}
