//
//  AmbientCoverBackdrop.swift
//  Amperfy
//
//  cassette Patch 112 — Now Playing ambient backlight. Behind the crisp
//  now-playing cover we render a soft, oversized, blurred copy of that same
//  cover so the record's own colours fill the screen like a lamp in a dim
//  room. View-layer only: no colour sampling, no dominant_color, no data
//  model. We blur the image we already have.
//
//  Performance: never blur a full-res image and never blur per frame. The
//  cover is downsampled to ~32px once (off-main, cached in `NSCache`); a 32px
//  texture blurred + scaled up is visually identical to a 1000px one, which is
//  what makes this effectively free on the GPU.
//
//  Hosted (via UIHostingController) behind the UIKit PopupPlayerVC content.
//

import AmperfyKit
import SwiftUI
import UIKit

// MARK: - AmbientBackdropCache

enum AmbientBackdropCache {
  // NSCache is internally thread-safe; the unchecked annotation just satisfies
  // strict concurrency for the shared static.
  private nonisolated(unsafe) static let cache = NSCache<NSString, UIImage>()

  /// Returns a ~32px downsampled copy, cached by key. Safe to call repeatedly.
  static func tiny(for key: String, image: UIImage) async -> UIImage {
    if let hit = cache.object(forKey: key as NSString) { return hit }
    let small = await Task.detached(priority: .utility) {
      image.ambientDownsampled(maxDimension: 32)
    }.value
    cache.setObject(small, forKey: key as NSString)
    return small
  }
}

private extension UIImage {
  func ambientDownsampled(maxDimension: CGFloat) -> UIImage {
    let longest = max(size.width, size.height)
    guard longest > maxDimension else { return self }
    let scale = maxDimension / longest
    let target = CGSize(width: size.width * scale, height: size.height * scale)
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = 1
    return UIGraphicsImageRenderer(size: target, format: format).image { _ in
      draw(in: CGRect(origin: .zero, size: target))
    }
  }
}

// MARK: - AmbientBackdropModel

/// Bridges the UIKit player to the SwiftUI backdrop. The player pushes the
/// current cover (or placeholder) image, a stable id, and the play state.
@MainActor
final class AmbientBackdropModel: ObservableObject {
  /// Stable id for the current artwork (artwork image path, or a placeholder
  /// key). Drives the cross-fade and the downsample cache key.
  @Published var coverID: String = "ambient-placeholder"
  /// The resolved cover image, OR the on-brand placeholder image. One path.
  @Published var image: UIImage?
  @Published var isPlaying: Bool = false
}

// MARK: - AmbientCoverBackdrop

struct AmbientCoverBackdrop: View {
  @ObservedObject var model: AmbientBackdropModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  @State private var tiny: UIImage?

  /// Warm-dark base — the popup player's own background token, so the scrim
  /// and the dim areas blend seamlessly into the room.
  private let base = Color(uiColor: CassetteTheme.UIColors.bg4)

  var body: some View {
    ZStack {
      base

      if let tiny {
        GeometryReader { geo in
          Image(uiImage: tiny)
            .resizable()
            .scaledToFill()
            .frame(width: geo.size.width * 1.4, height: geo.size.height * 1.4)
            .position(x: geo.size.width / 2, y: geo.size.height * 0.42)
            .blur(radius: 70, opaque: true)
            // Restrained: quiet/dark covers stay quiet (a dim cover → a dim
            // room is the intended behaviour, not a bug). Slight lift while
            // playing, settling when paused.
            .opacity(model.isPlaying ? 0.68 : 0.5)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.9), value: model.isPlaying)
        }
        .transition(.opacity)
        .id(model.coverID)
        .animation(reduceMotion ? .easeInOut(duration: 0.3) : .easeInOut(duration: 0.6),
                   value: model.coverID)
      }

      // Warm scrim: keep the room dim and the title/controls legible. Radial
      // darken toward the edges + a stronger floor under the transport.
      RadialGradient(
        colors: [.clear, base.opacity(0.55)],
        center: .init(x: 0.5, y: 0.36),
        startRadius: 80,
        endRadius: 520
      )
      LinearGradient(
        colors: [.clear, base.opacity(0.85)],
        startPoint: .center,
        endPoint: .bottom
      )
    }
    .ignoresSafeArea()
    .task(id: model.coverID) {
      guard let image = model.image else { tiny = nil; return }
      tiny = await AmbientBackdropCache.tiny(for: model.coverID, image: image)
    }
  }
}
