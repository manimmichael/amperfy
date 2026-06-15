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
import CoreImage
import ImageIO
import SwiftUI
import UIKit

// Patch 114: shared CIContext for the off-main pre-blur (Sendable + thread-safe).
private let ambientBlurContext = CIContext(options: nil)

// MARK: - AmbientSourceDecoder

/// cassette: decode the ambient/cover source straight from disk as a
/// downsampled thumbnail via ImageIO, OFF the main thread. Previously the
/// popup fed the ambient model with `getImageToDisplayImmediately`, a
/// synchronous full-res `UIImage(contentsOfFile:)` on the main thread — an
/// oversized cover (e.g. a multi-thousand-pixel render) decoded there blocks
/// popup-open and can starve the audio render thread on first open.
/// `CGImageSourceCreateThumbnailAtIndex` caps the work to `maxPixelSize`
/// regardless of the source's real dimensions, so the cost is bounded.
enum AmbientSourceDecoder {
  static func thumbnail(contentsOfFile path: String, maxPixelSize: Int) -> UIImage? {
    guard let source = CGImageSourceCreateWithURL(
      URL(fileURLWithPath: path) as CFURL, nil
    ) else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
    ]
    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
      source, 0, options as CFDictionary
    ) else { return nil }
    return UIImage(cgImage: cgImage)
  }
}

// MARK: - AmbientBackdropCache

enum AmbientBackdropCache {
  // NSCache is internally thread-safe; the unchecked annotation just satisfies
  // strict concurrency for the shared static.
  private nonisolated(unsafe) static let cache = NSCache<NSString, UIImage>()

  /// Returns a ~32px downsampled **and pre-blurred** copy, cached by key.
  /// Patch 114: the blur now happens HERE, off the main thread, so the SwiftUI
  /// view renders a plain Image. Previously the view applied `.blur(radius:70)`,
  /// whose first-render Gaussian shader compiled on the main thread the first
  /// time the player opened — a one-time spike that starved the audio render
  /// thread (the "first-open glitch"). Doing the decode + downsample + blur on
  /// a detached task and caching the result makes opening the player cheap.
  static func tiny(for key: String, image: UIImage) async -> UIImage {
    if let hit = cache.object(forKey: key as NSString) { return hit }
    let small = await Task.detached(priority: .utility) {
      image.ambientDownsampledBlurred(maxDimension: 32, blurRadius: 8)
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

  /// Patch 114: downsample to ~`maxDimension`px, then Gaussian-blur the tiny
  /// image off-main (CIGaussianBlur on a 32px source is trivial). The soft
  /// blur + the later bilinear upscale-to-fill reproduce the old `.blur(70)`
  /// lamp look without an on-main render-time blur.
  func ambientDownsampledBlurred(maxDimension: CGFloat, blurRadius: Double) -> UIImage {
    let small = ambientDownsampled(maxDimension: maxDimension)
    guard let input = CIImage(image: small) else { return small }
    let cropExtent = input.extent
    guard let filter = CIFilter(name: "CIGaussianBlur") else { return small }
    // Clamp so the blur doesn't pull in transparent edges (dark halo).
    filter.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
    filter.setValue(blurRadius, forKey: kCIInputRadiusKey)
    guard let output = filter.outputImage,
          let cg = ambientBlurContext.createCGImage(output, from: cropExtent)
    else { return small }
    return UIImage(cgImage: cg)
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
            // Patch 114: NO `.blur` here — the tiny image is already blurred
            // off-main in AmbientBackdropCache, so first open compiles no
            // render-time blur shader on the main thread (the audio-glitch
            // fix). The bilinear upscale-to-fill keeps it soft.
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
