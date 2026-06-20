//
//  HeaderPopDebug.swift
//  Amperfy
//
//  cassette (header-pop fix): TEMPORARY instrumentation for the collapsing
//  detail-header pop bug. The physical-device console is unreachable (the
//  IDEPseudoTerminalDomain attach error), so os_log/print never make it back to
//  the bench. Instead this renders an ON-SCREEN HUD — a translucent green-on-black
//  label pinned to the window centre showing the last N events — so the live
//  values can be captured with a screenshot. Gated behind #if DEBUG; delete the
//  whole file (and its call sites) once the pop bug is closed.
//

import UIKit

@MainActor
enum HeaderPopDebug {
  #if DEBUG
  private static var lines: [String] = []
  private static let maxLines = 16
  private static weak var overlay: UILabel?
  private static var seq = 0

  private static func activeWindow() -> UIWindow? {
    for scene in UIApplication.shared.connectedScenes {
      guard let ws = scene as? UIWindowScene else { continue }
      if let key = ws.windows.first(where: { $0.isKeyWindow }) { return key }
      if let any = ws.windows.last { return any }
    }
    return nil
  }

  private static func ensureOverlay() -> UILabel? {
    if let o = overlay, o.window != nil { return o }
    guard let win = activeWindow() else { return nil }
    let label = UILabel()
    label.numberOfLines = 0
    label.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
    label.textColor = .green
    label.backgroundColor = UIColor.black.withAlphaComponent(0.72)
    label.isUserInteractionEnabled = false
    label.translatesAutoresizingMaskIntoConstraints = false
    label.layer.zPosition = 100_000
    win.addSubview(label)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: win.leadingAnchor),
      label.trailingAnchor.constraint(equalTo: win.trailingAnchor),
      label.centerYAnchor.constraint(equalTo: win.centerYAnchor),
    ])
    overlay = label
    return label
  }

  private static func push(_ line: String) {
    seq += 1
    lines.append(String(format: "%03d %@", seq, line))
    if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
    guard let o = ensureOverlay() else { return }
    o.text = lines.joined(separator: "\n")
    o.superview?.bringSubviewToFront(o)
  }

  private static func short(_ vc: UIViewController) -> String {
    String(describing: type(of: vc))
      .replacingOccurrences(of: "DetailVC", with: "")
      .replacingOccurrences(of: "ViewController", with: "")
  }
  #endif

  /// Free-form event line (optional caller name + message) shown in the HUD.
  static func event(_ message: String, in viewController: UIViewController? = nil) {
    #if DEBUG
    if let viewController {
      push("[\(short(viewController))] \(message)")
    } else {
      push(message)
    }
    #endif
  }

  /// Free-form note tagged with the caller VC.
  static func log(_ message: String, in viewController: UIViewController) {
    #if DEBUG
    push("[\(short(viewController))] \(message)")
    #endif
  }

  /// Header frame + scroll geometry at a labeled point in the pop.
  static func snapshot(
    _ label: String,
    header: UIView?,
    scrollView: UIScrollView?,
    in viewController: UIViewController
  ) {
    #if DEBUG
    let frozen = (viewController as? BasicTableViewController)?.isHeaderTransitionFrozen ?? false
    _ = header
    let off = scrollView?.contentOffset.y ?? 0
    // nT = navigationItem.title (string), tv = titleView alpha + "H" when isHidden.
    // nT should read "·". tv should read "…H" (hidden → invisible no matter the
    // alpha) at the top and through the pop, and a bare alpha like "1.0" only once
    // scrolled. A bare "1.0" at the top is the bug.
    let nT = viewController.navigationItem.title.map { String($0.prefix(5)) } ?? "·"
    let tv = viewController.navigationItem.titleView.map {
      String(format: "%.1f%@", $0.alpha, $0.isHidden ? "H" : "")
    } ?? "nil"
    push(String(
      format: "[%@] %@ frz=%@ off=%.0f tv=%@ nT=%@",
      short(viewController), label, frozen ? "Y" : "N", off, tv, nT
    ))
    #endif
  }
}
