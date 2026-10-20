//
//  CarPlayStyle.swift
//  Amperfy
//
//  Cassette: the one place CarPlay images are made (design-system audit 2026-10-20, Wave 1).
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

import AmperfyKit
@preconcurrency import CarPlay
import UIKit

/// Every image CarPlay shows comes from here, built against the CAR's trait collection,
/// never the phone's. The rules:
///
/// - **Glyphs and track numbers** are real bitmaps (CarPlay re-tints templates per background,
///   BUG-054), one per car appearance, registered in a `UIImageAsset`: white on the dark
///   appearance, near-black ink on the light one. The car picks the variant itself, so a
///   headlight flip mid-drive needs no rebuild (BUG-424). The appearance-less fallback is the
///   white variant, which is what every build before this one drew.
/// - **Covers** are the entity's real art, sized to the slot at the car's scale, artists
///   cropped to a circle. No cover means the **placeholder**: the same brand tile as the phone,
///   but with a legible initial (the phone's 8% ghost is invisible at car size, BUG-425).
/// - **Tab images** are the plain template assets on purpose: CarPlay tints its own tab bar and
///   offers no app tint, so they do not come through here.
/// - **No brand orange.** CarPlay chrome (now-playing buttons, accessories, tab selection) stays
///   the system's; the brand is carried by the glyph shapes and the placeholder tile.
@MainActor
struct CarPlayStyle {
  /// The car's traits (`CPInterfaceController.carTraitCollection`).
  let traits: UITraitCollection

  enum Slot {
    /// A `CPListItem` row image.
    case row
    /// A `CPListImageRowItemRowElement` (Home shelf tile).
    case shelf

    var maximumSize: CGSize {
      switch self {
      case .row: return CPListItem.maximumImageSize
      case .shelf: return CPListImageRowItemRowElement.maximumImageSize
      }
    }
  }

  /// Glyph color on a dark car surface.
  static let inkOnDark = UIColor.white
  /// Glyph color on a light car surface: the brand's darkest ink, next to the car's black text.
  static let inkOnLight = UIColor.cassette(.textOnFill)
  /// The placeholder initial: legible on the brand tile at car size.
  static let placeholderMark = UIColor.cassette(.textSecondary).withAlphaComponent(0.65)

  private var scale: CGFloat {
    traits.displayScale > 0 ? traits.displayScale : UITraitCollection.current.displayScale
  }

  // MARK: Glyphs and numbers

  /// A row glyph (Shuffle, All Songs, browse buckets): Lucide or SF Symbol source.
  func glyph(_ source: UIImage, size: ArtworkIconSizeType = .small) -> UIImage {
    perAppearance { color in
      UIImage.carPlayGlyph(with: source, iconSizeType: size, color: color, scale: scale)
    }
  }

  /// The track number an album row shows in place of a cover (BUG-421).
  func trackNumber(_ number: Int) -> UIImage {
    perAppearance { color in
      UIImage.numberToImage(number: number, color: color, scale: scale)
    }
  }

  // MARK: Covers and placeholders

  /// A library entity's cover, or its placeholder when it has none.
  func artwork(
    for entity: AbstractLibraryEntity,
    artworkDisplayPreference: ArtworkDisplayPreference,
    slot: Slot = .row
  )
    -> UIImage {
    artwork(
      LibraryEntityImage.coverImage(
        libraryEntity: entity,
        artworkDisplayPreference: artworkDisplayPreference,
        useCache: false
      ),
      kind: entity.getDefaultArtworkType(),
      name: (entity as? PlayableContainable)?.name,
      circle: entity is Artist,
      slot: slot
    )
  }

  /// A row image for a playable: its track number when the list shows numbers, else its cover.
  func artwork(
    for playable: AbstractPlayable,
    isTrackDisplayed: Bool,
    artworkDisplayPreference: ArtworkDisplayPreference
  )
    -> UIImage {
    isTrackDisplayed
      ? trackNumber(playable.track)
      : artwork(for: playable, artworkDisplayPreference: artworkDisplayPreference)
  }

  /// Any cover, or the placeholder for `kind`/`name` when `image` is nil. Sized to the slot at
  /// the car's scale, circle-cropped for artists.
  func artwork(
    _ image: UIImage?,
    kind: ArtworkType,
    name: String?,
    circle: Bool = false,
    slot: Slot = .row
  )
    -> UIImage {
    let target = slotSize(slot)
    let source = image ?? UIImage.getGeneratedArtwork(
      theme: .defaultValue, // ignored by the renderer; the parameter goes with ThemePreference
      artworkType: kind,
      name: name,
      size: target,
      markColor: Self.placeholderMark,
      scale: scale
    )
    return wrap(fitted(source, into: target, circle: circle))
  }

  /// The placeholder kind for a Home shelf item (a `PlayableContainable` that may not be a
  /// library entity, e.g. a playlist).
  func artworkKind(of containable: PlayableContainable) -> ArtworkType {
    containable.getArtworkCollection(theme: .defaultValue).defaultArtworkType
  }

  // MARK: Plumbing

  private func slotSize(_ slot: Slot) -> CGSize {
    let max = slot.maximumSize
    let side = Swift.max(max.width, max.height)
    // `maximumImageSize` is zero before a head unit has connected on some runtimes.
    return side > 0 ? CGSize(width: side, height: side) : CGSize(width: 90, height: 90)
  }

  /// Scale `image` down (never up) to fit `target` at the car's scale; crop to a circle when asked.
  private func fitted(_ image: UIImage, into target: CGSize, circle: Bool) -> UIImage {
    let size = image.size
    guard size.width > 0, size.height > 0 else { return image }
    let ratio = min(1, target.width / size.width, target.height / size.height)
    var drawSize = CGSize(width: size.width * ratio, height: size.height * ratio)
    if circle {
      let side = min(drawSize.width, drawSize.height)
      drawSize = CGSize(width: side, height: side)
    }
    let format = UIGraphicsImageRendererFormat()
    format.scale = scale
    format.opaque = false
    return UIGraphicsImageRenderer(size: drawSize, format: format).image { _ in
      if circle {
        UIBezierPath(ovalIn: CGRect(origin: .zero, size: drawSize)).addClip()
      }
      // Aspect-fill the (possibly square-cropped) canvas, centered.
      let fill = max(drawSize.width / size.width, drawSize.height / size.height)
      let filled = CGSize(width: size.width * fill, height: size.height * fill)
      image.draw(in: CGRect(
        x: (drawSize.width - filled.width) / 2,
        y: (drawSize.height - filled.height) / 2,
        width: filled.width,
        height: filled.height
      ))
    }
  }

  /// One appearance-independent image, attached to the car's scale.
  private func wrap(_ image: UIImage) -> UIImage {
    let asset = UIImageAsset()
    let base = UITraitCollection(displayScale: scale)
    asset.register(image, with: base)
    return asset.image(with: traits)
  }

  /// One bitmap per car appearance in a single asset, so the car resolves the variant itself.
  private func perAppearance(_ draw: (UIColor) -> UIImage) -> UIImage {
    let onDark = draw(Self.inkOnDark)
    let onLight = draw(Self.inkOnLight)
    let base = UITraitCollection(displayScale: scale)
    let asset = UIImageAsset()
    // Registered first and appearance-less: what a car that reports no appearance gets.
    asset.register(onDark, with: base)
    asset.register(onDark, with: base.modifyingTraits { $0.userInterfaceStyle = .dark })
    asset.register(onLight, with: base.modifyingTraits { $0.userInterfaceStyle = .light })
    return asset.image(with: traits)
  }
}
