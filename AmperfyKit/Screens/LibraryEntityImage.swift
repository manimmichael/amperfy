//
//  LibraryEntityImage.swift
//  AmperfyKit
//
//  Created by Maximilian Bauer on 10.06.21.
//  Copyright (c) 2021 Maximilian Bauer. All rights reserved.
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

import CoreData
import ImageIO
import UIKit

extension LibraryEntityImage {
  // Cache should not be used between different instances -> iOS and Carplay
  static public func getImageToDisplayImmediately(
    libraryEntity: AbstractLibraryEntity,
    themePreference: ThemePreference,
    artworkDisplayPreference: ArtworkDisplayPreference,
    useCache: Bool
  )
    -> UIImage {
    // cassette §art-collapse: resolve the album-level cover (the `setting` is
    // inert), prefer the small thumb tier, and decode it DOWNSAMPLED via ImageIO
    // — never the synchronous full-resolution decode this used to do on the main
    // thread (it fires on every track change via NowPlayingInfoCenterHandler).
    // Cache-first, so repeat calls are free.
    if let fullPath = libraryEntity.imagePath(setting: artworkDisplayPreference) {
      let sourcePath = CoverImageStore.preferredSourcePath(
        forFullPath: fullPath,
        smallSurface: true
      )
      if useCache, let cachedImg = Self.cache.object(forKey: sourcePath as NSString) {
        return cachedImg
      }
      let maxPixel = CoverImageStore.isThumbPath(sourcePath)
        ? CoverImageStore.thumbMaxPixel
        : CoverImageStore.heroMaxPixel
      if let img = CoverImageStore.downsampledImage(atPath: sourcePath, maxPixel: maxPixel) {
        Self.cache.setObject(img, forKey: sourcePath as NSString)
        return img
      }
    }
    return UIImage.getGeneratedArtwork(
      theme: themePreference,
      artworkType: libraryEntity.getDefaultArtworkType(),
      name: (libraryEntity as? PlayableContainable)?.name
    )
  }
}

// MARK: - LibraryEntityImage

@MainActor
public class LibraryEntityImage: RoundedImage {
  static private let cache: NSCache<NSString, UIImage> = NSCache()

  /// Drop the cached bitmap(s) for a cover whose bytes changed on disk (both the full
  /// and thumb tiers). The cache is keyed by tier source PATH, and a re-download
  /// overwrites at the SAME path — so without this the stale image survives until the
  /// app restarts. Also called directly by the Cassette folder-cover refresh, where
  /// every other invalidation hook keys on path or entity identity and so sees nothing
  /// change.
  static func evictCache(forFullPath fullPath: String) {
    cache.removeObject(forKey: fullPath as NSString)
    cache.removeObject(forKey: CoverImageStore.thumbPath(forFullPath: fullPath) as NSString)
  }

  private let appDelegate: AmperKit

  private var entity: AbstractLibraryEntity?
  private var backupArtworkType: ArtworkType?
  private var accountNotificationHandler: AccountNotificationHandler?
  // The tier source path (thumb vs full) currently loaded into `image`, so a
  // layout pass that doesn't change the tier doesn't trigger a redundant decode.
  private var loadedSourcePath: String?

  required public init?(coder: NSCoder) {
    self.appDelegate = AmperKit.shared
    super.init(coder: coder)
    // cassette §art-collapse: one contentMode for every cover. With square
    // sources aspectFill never crops; this fixes the mini-player stretch
    // (UIImageView's scaleToFill default) and fills the now-playing hero, in one
    // place instead of the old per-surface aspectFill/aspectFit/scaleToFill mix.
    contentMode = .scaleAspectFill
    self.accountNotificationHandler = AccountNotificationHandler(
      storage: appDelegate.storage,
      notificationHandler: appDelegate.notificationHandler
    )
    accountNotificationHandler?.registerCallbackForAllAccounts { [weak self] accountInfo in
      guard let self else { return }
      appDelegate.notificationHandler.register(
        self,
        selector: #selector(downloadFinishedSuccessful(notification:)),
        name: .downloadFinishedSuccess,
        object: appDelegate.getMeta(accountInfo).artworkDownloadManager
      )
      appDelegate.notificationHandler.register(
        self,
        selector: #selector(downloadFinishedSuccessful(notification:)),
        name: .downloadFinishedSuccess,
        object: appDelegate.getMeta(accountInfo).playableDownloadManager
      )
    }
  }

  override public init(frame: CGRect) {
    self.appDelegate = AmperKit.shared
    super.init(frame: .zero)
    contentMode = .scaleAspectFill
    self.accountNotificationHandler = AccountNotificationHandler(
      storage: appDelegate.storage,
      notificationHandler: appDelegate.notificationHandler
    )
    accountNotificationHandler?.registerCallbackForAllAccounts { [weak self] accountInfo in
      guard let self else { return }
      appDelegate.notificationHandler.register(
        self,
        selector: #selector(downloadFinishedSuccessful(notification:)),
        name: .downloadFinishedSuccess,
        object: appDelegate.getMeta(accountInfo).artworkDownloadManager
      )
      appDelegate.notificationHandler.register(
        self,
        selector: #selector(downloadFinishedSuccessful(notification:)),
        name: .downloadFinishedSuccess,
        object: appDelegate.getMeta(accountInfo).playableDownloadManager
      )
    }
  }

  public func display(entity: AbstractLibraryEntity) {
    self.entity = entity
    backupArtworkType = entity.getDefaultArtworkType()
    loadedSourcePath = nil
    refresh()
  }

  public func displayAndUpdate(entity: AbstractLibraryEntity) {
    guard self.entity != entity else { return }

    display(entity: entity)
    if let artwork = entity.artwork, let accountInfo = entity.account?.info {
      appDelegate.getMeta(accountInfo).artworkDownloadManager.download(object: artwork)
    }
  }

  internal func display(image: UIImage) {
    self.image = image
    entity = nil
    loadedSourcePath = nil
  }

  public func display(artworkType: ArtworkType) {
    backupArtworkType = artworkType
    entity = nil
    loadedSourcePath = nil
    refresh()
  }

  private var placeholderImage: UIImage {
    var theme = appDelegate.storage.settings.accounts.activeSetting.read.themePreference
    if let accountInfo = entity?.account?.info {
      theme = appDelegate.storage.settings.accounts.getSetting(accountInfo).read.themePreference
    }
    return UIImage.getGeneratedArtwork(
      theme: theme,
      artworkType: backupArtworkType ?? .song,
      name: (entity as? PlayableContainable)?.name
    )
  }

  /// The album-level cover path for the current entity (the `setting` is inert
  /// after the art-collapse — every playable resolves to its album cover).
  private var entityImagePathToDisplay: String? {
    let setting = appDelegate.storage.settings.accounts.activeSetting.read.artworkDisplayPreference
    return entity?.imagePath(setting: setting)
  }

  /// The tier source to decode: the ~480px thumb for small surfaces (carousel,
  /// queue, mini, resume) when it exists, the capped full for heroes. Driven by
  /// the view's bounds, so it settles correctly after layout.
  private func tierSourcePath(fullPath: String) -> String {
    let maxSide = max(bounds.width, bounds.height)
    let smallSurface = maxSide > 1 && maxSide <= CoverImageStore.smallSurfaceMaxPt
    return CoverImageStore.preferredSourcePath(forFullPath: fullPath, smallSurface: smallSurface)
  }

  /// `keepCurrentImageWhileLoading` suppresses the placeholder swap while we
  /// re-decode NEW bytes for the SAME entity that already has a valid image on
  /// screen — a cover re-check or pick overwrite. Without it every cover the sync
  /// pass re-checks briefly flashes the gray placeholder before the (usually
  /// identical) new bytes land, which is the "covers flash while it checks them"
  /// blink. A fresh entity or a reused cell still shows the placeholder, because
  /// there `loadedSourcePath` is nil AND this stays false (see the call sites).
  private func refresh(keepCurrentImageWhileLoading: Bool = false) {
    guard let fullPath = entityImagePathToDisplay else {
      image = placeholderImage
      loadedSourcePath = nil
      return
    }
    let sourcePath = tierSourcePath(fullPath: fullPath)

    // Already showing the right tier — nothing to do (avoids redundant decodes
    // on every layout pass).
    if sourcePath == loadedSourcePath, image != nil {
      return
    }

    if let cachedImg = Self.cache.object(forKey: sourcePath as NSString) {
      image = cachedImg
      loadedSourcePath = sourcePath
      return
    }

    if loadedSourcePath == nil, !keepCurrentImageWhileLoading {
      image = placeholderImage
    }
    Task.detached(priority: .high) { [weak self] in
      await self?.loadImageAndCacheIt(sourcePath: sourcePath)
    }
  }

  @concurrent
  private func loadImageAndCacheIt(sourcePath: String) async {
    guard !Task.isCancelled else { return }
    let maxPixel = CoverImageStore.isThumbPath(sourcePath)
      ? CoverImageStore.thumbMaxPixel
      : CoverImageStore.heroMaxPixel
    // Off-main, size-bounded ImageIO decode — a 160pt cell never holds a
    // full-resolution bitmap, and there is no synchronous main-thread decode.
    guard let readyImage = CoverImageStore.downsampledImage(atPath: sourcePath, maxPixel: maxPixel)
    else { return }
    guard !Task.isCancelled else { return }
    Task { @MainActor [weak self] in
      guard let self else { return }
      Self.cache.setObject(readyImage, forKey: sourcePath as NSString)
      // Re-evaluate against the current tier (bounds may have changed) and show.
      refresh()
    }
  }

  override public func layoutSubviews() {
    super.layoutSubviews()
    // Bounds are valid here — re-pick the tier (e.g. a hero upgrading from a
    // cached thumb to the full cover). refresh() no-ops when the tier is stable.
    if entity != nil {
      refresh()
    }
  }

  @objc
  private func downloadFinishedSuccessful(notification: Notification) {
    guard let downloadNotification = DownloadNotification.fromNotification(notification), let entity
    else { return }
    let matchesPlayable = (entity as? AbstractPlayable)?.uniqueID == downloadNotification.id
    let matchesArtwork = entity.artwork?.uniqueID == downloadNotification.id
    // cassette: a song shows its ALBUM's cover (AbstractPlayable.imagePath is
    // album-first), and the album artwork is a DISTINCT Core Data row from the
    // song's own — so an owned-album cover backfill completing carries the album
    // artwork id, which the two ids above both miss, and the now-playing hero /
    // any song cell stays on the gray placeholder until the next track change or a
    // layout pass. Match the album artwork id too. Mirrors the C09 patch already in
    // NowPlayingInfoCenterHandler (lock screen); this is the same fix for the in-app view.
    let matchesAlbumArtwork =
      (entity as? AbstractPlayable)?.asSong?.album?.artwork?.uniqueID == downloadNotification.id
    guard matchesPlayable || matchesArtwork || matchesAlbumArtwork else { return }
    Task { @MainActor in
      // The cover (and its thumb) now exist — or its bytes CHANGED (a pick
      // re-download overwrites at the same path). Drop the stale cache first so
      // refresh() re-decodes the new file instead of serving the old bitmap, then
      // re-resolve the tier and load it. Keep whatever is already on screen up
      // until the new bytes are decoded (keepCurrentImageWhileLoading) — a re-check
      // that lands the same or a better cover must never blink through the gray
      // placeholder first.
      if let fullPath = self.entityImagePathToDisplay {
        Self.evictCache(forFullPath: fullPath)
      }
      self.loadedSourcePath = nil
      self.refresh(keepCurrentImageWhileLoading: true)
    }
  }
}

// MARK: - CoverImageStore

/// cassette §art-collapse: the two-tier, square, off-main cover machinery shared
/// by ingestion (the native getCoverArt path via SubsonicArtworkDownloadDelegate)
/// and display (LibraryEntityImage). One album-level cover per album, stored as
/// a capped full file plus a ~480px square thumb beside it (`<id>_thumb.<ext>`),
/// decoded at the size the view actually needs.
public enum CoverImageStore {
  /// Thumb tier longest side — crisp in the 160pt carousel at 3x.
  public static let thumbMaxPixel = 480
  /// Full/hero tier decode cap — covers the 240pt detail hero and ≤360pt
  /// now-playing hero at 3x. Also the off-main decode ceiling for the full file.
  public static let heroMaxPixel = 1000
  /// Surfaces at or below this point size use the thumb tier.
  public static let smallSurfaceMaxPt: CGFloat = 200

  /// Thumb path for a full cover path: `…/al-x.png` → `…/al-x_thumb.png`.
  public static func thumbPath(forFullPath full: String) -> String {
    let ns = full as NSString
    let ext = ns.pathExtension
    let base = ns.deletingPathExtension
    return ext.isEmpty ? base + "_thumb" : base + "_thumb." + ext
  }

  /// Whether `path` already names a thumb file.
  public static func isThumbPath(_ path: String) -> Bool {
    ((path as NSString).deletingPathExtension as NSString).lastPathComponent.hasSuffix("_thumb")
  }

  /// The path to decode for a surface: the thumb (when small and present), else
  /// the full cover.
  public static func preferredSourcePath(forFullPath full: String, smallSurface: Bool) -> String {
    guard smallSurface else { return full }
    let tp = thumbPath(forFullPath: full)
    return FileManager.default.fileExists(atPath: tp) ? tp : full
  }

  /// Off-disk ImageIO decode, downsampled so the longest side ≈ maxPixel.
  /// Bounded cost regardless of the source's real dimensions; safe to call off
  /// the main thread.
  public static func downsampledImage(atPath path: String, maxPixel: Int) -> UIImage? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)
    else { return nil }
    let opts: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixel,
    ]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    else { return nil }
    // cassette §art-collapse: normalize to sRGB. ImageIO returns the source's
    // own colour space, so a CMYK or exotic-profile JPEG (common in commercial
    // CD cover art) comes back non-RGB and renders as a solid BLACK square once
    // wrapped in a UIImage and drawn through an opaque context. Redrawing into an
    // sRGB bitmap forces the conversion, so every cover decodes to true colour on
    // every surface. (UIImage(contentsOfFile:) used to hide this; the tiered
    // ImageIO path does not.)
    return normalizedSRGBImage(cg) ?? UIImage(cgImage: cg)
  }

  /// Redraw a CGImage into an 8-bit sRGB bitmap so non-RGB sources (CMYK,
  /// grayscale, wide-gamut, odd ICC profiles) become standard sRGB. Returns nil
  /// only when the context can't be created (the caller then falls back to the
  /// raw image rather than showing nothing).
  private static func normalizedSRGBImage(_ cg: CGImage) -> UIImage? {
    let width = cg.width
    let height = cg.height
    guard width > 0, height > 0 else { return nil }
    let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue
      | CGBitmapInfo.byteOrder32Big.rawValue
    guard let ctx = CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: space,
      bitmapInfo: bitmapInfo
    ) else { return nil }
    ctx.interpolationQuality = .high
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let normalized = ctx.makeImage() else { return nil }
    return UIImage(cgImage: normalized)
  }

  /// Longest-side cap for the decodability probe below. An unbounded full decode
  /// (`CGImageSourceCreateImageAtIndex(src, 0, nil)`) allocates the source's
  /// entire bitmap — a 6000² cover ≈ 144MB RGBA — which can be jettisoned under
  /// memory pressure and is exactly what dropped oversized covers on the phone.
  /// Probing with a bounded thumbnail proves the bytes decode at a fraction of
  /// the cost, so an oversized/hostile cover can never take the accept path down
  /// regardless of what the server sends.
  public static let decodeProbeMaxPixel = 2048

  /// Whether `src` decodes to a real image WITHOUT ever allocating the full-
  /// resolution bitmap. `kCGImageSourceCreateThumbnailFromImageAlways` forces a
  /// genuine decode (so truncated/corrupt data is still rejected), bounded to
  /// `decodeProbeMaxPixel`.
  private static func sourceDecodes(_ src: CGImageSource) -> Bool {
    guard CGImageSourceGetCount(src) > 0 else { return false }
    let opts: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceThumbnailMaxPixelSize: decodeProbeMaxPixel,
    ]
    return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) != nil
  }

  /// Whether raw bytes decode to an image. Forces an actual (bounded) decode, not
  /// just a header read, so truncated/corrupt data is rejected. Used to gate
  /// every cover write — a download that doesn't decode must never overwrite a
  /// good cover (Rule 1) and falls to the placeholder, never a broken file (§5).
  public static func isDecodable(_ data: Data) -> Bool {
    guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
    return sourceDecodes(src)
  }

  /// Whether the file at `url` decodes to an image (forces a bounded real decode).
  public static func isDecodable(fileURL url: URL) -> Bool {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
    return sourceDecodes(src)
  }

  /// Pixel dimensions of an image file via ImageIO (header only — no decode).
  public static func pixelSize(atPath path: String) -> (width: Int, height: Int)? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
          let w = props[kCGImagePropertyPixelWidth] as? Int,
          let h = props[kCGImagePropertyPixelHeight] as? Int
    else { return nil }
    return (w, h)
  }

  /// Ingest a freshly-stored full cover: write the ~480px thumb beside it, at the
  /// source's NATIVE aspect. Best-effort — failures leave the full cover usable on
  /// its own. Safe to call off the main thread.
  ///
  /// Nothing is padded to a square. We never bake bars into a stored image: album
  /// covers are square already, and an artist photo is a portrait/landscape press
  /// shot that would bar-out if squared. Every frame crops to fill (`.scaleAspectFill`
  /// / the web's `object-fit: cover`), so native aspect is exactly what fills, and a
  /// bar the crop can't remove is never created. The sidecar makes the same choice
  /// (normalizeCover, native ratio) for the files it materializes.
  public static func processStoredCover(fullFileURL: URL) {
    let fullPath = fullFileURL.path
    // Thumb tier — native aspect, capped. No square-pad, ever.
    if let thumbSrc = downsampledImage(atPath: fullPath, maxPixel: thumbMaxPixel) {
      if let data = thumbSrc.jpegData(compressionQuality: 0.85) {
        try? data.write(to: URL(fileURLWithPath: thumbPath(forFullPath: fullPath)))
      }
    }
  }

  /// Generate the thumb tier for an existing full cover only when it's missing.
  /// Cheap + idempotent (a single fileExists check when the thumb is present),
  /// so the re-tier backfill is safe to run on every sync. Safe off-main.
  public static func ensureThumb(forFullPath fullPath: String) {
    if FileManager.default.fileExists(atPath: thumbPath(forFullPath: fullPath)) { return }
    processStoredCover(fullFileURL: URL(fileURLWithPath: fullPath))
  }
}
