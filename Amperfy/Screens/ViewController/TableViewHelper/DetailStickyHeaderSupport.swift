//
//  DetailStickyHeaderSupport.swift
//  Amperfy
//
//  cassette Patch 064: shared scroll threshold for detail sticky headers.

import UIKit

enum DetailStickyHeaderSupport {
  static func install(
    stickyHeader: DetailStickyHeaderView,
    in viewController: UIViewController
  ) {
    guard let hostView = viewController.view else { return }
    hostView.addSubview(stickyHeader)
    let top = stickyHeader.topAnchor.constraint(equalTo: hostView.safeAreaLayoutGuide.topAnchor)
    NSLayoutConstraint.activate([
      top,
      stickyHeader.leadingAnchor.constraint(equalTo: hostView.leadingAnchor),
      stickyHeader.trailingAnchor.constraint(equalTo: hostView.trailingAnchor),
      stickyHeader.heightAnchor.constraint(equalToConstant: 56),
    ])
  }

  static func updateAlpha(
    stickyHeader: DetailStickyHeaderView,
    scrollView: UIScrollView,
    tableHeaderView: UIView?,
    navigationBarMaxY: CGFloat
  ) {
    guard let header = tableHeaderView else {
      stickyHeader.alpha = 0
      return
    }
    let threshold = header.frame.height - stickyHeader.frame.height - navigationBarMaxY
    let progress = max(0, min(1, (scrollView.contentOffset.y - threshold) / 20))
    stickyHeader.alpha = progress
  }
}
