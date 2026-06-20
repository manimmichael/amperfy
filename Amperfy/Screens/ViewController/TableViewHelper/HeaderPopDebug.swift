//
//  HeaderPopDebug.swift
//  Amperfy
//
//  cassette (header-pop fix, round 3): TEMPORARY instrumentation used to PROVE,
//  on a live simulator gesture, that the collapsing detail hero holds its frame
//  through an interactive pop instead of re-expanding ("popping in"). Logs the
//  header view frame, the scroll view contentOffset, and adjustedContentInset
//  at transition start, every layout pass, and the transition completion.
//
//  Capture with either:
//    xcrun simctl spawn booted log stream --level debug \
//      --predicate 'subsystem == "Amperfy"' > /tmp/hdrlog.txt &
//  or just grep stdout for the "HDR:" prefix.
//
//  Gated behind #if DEBUG and intended to be deleted after verification.
//

import os
import UIKit

enum HeaderPopDebug {
  #if DEBUG
  private static let log = OSLog(subsystem: "Amperfy", category: "HeaderDebug")
  #endif

  /// Free-form note (e.g. flag transitions, completion + isCancelled).
  static func log(_ message: String, in viewController: UIViewController) {
    #if DEBUG
    let name = String(describing: type(of: viewController))
    os_log("%{public}@", log: log, type: .debug, "HDR: [\(name)] \(message)")
    #endif
  }

  /// The load-bearing measurement: header frame + scroll geometry at a labeled
  /// point in the pop. This is what proves the frame holds (or moves).
  static func snapshot(
    _ label: String,
    header: UIView?,
    scrollView: UIScrollView?,
    in viewController: UIViewController
  ) {
    #if DEBUG
    let name = String(describing: type(of: viewController))
    let frozen = (viewController as? BasicTableViewController)?.isHeaderTransitionFrozen ?? false
    let f = header?.frame ?? .null
    let offset = scrollView?.contentOffset ?? .zero
    let inset = scrollView?.adjustedContentInset ?? .zero
    let msg = String(
      format: "HDR: [%@] %@ frozen=%@ headerFrame=(%.1f,%.1f,%.1f,%.1f) " +
        "contentOffset=(%.1f,%.1f) adjustedInset=(t%.1f,b%.1f)",
      name, label, frozen ? "Y" : "N",
      f.origin.x, f.origin.y, f.size.width, f.size.height,
      offset.x, offset.y,
      inset.top, inset.bottom
    )
    os_log("%{public}@", log: log, type: .debug, msg)
    #endif
  }
}
