//
//  ShareSongSheet.swift
//  Amperfy
//
//  Cassette: send a song (CASSETTE_SHARING.md). One sheet at two speeds: a raw share is Share, Send,
//  pick a person; a note, any length, is there for whoever wants one, and the keyboard never opens on
//  its own. Send saves the share in the cloud (POST /api/share/song), which first checks that one of the
//  song's videos still plays, so a link never goes out to nothing; then Apple's own share sheet takes
//  it, with a link preview built here from the song's artwork so it draws at once.
//
//  Apple's parts throughout: a page sheet at the medium detent that grows to large when the note is
//  being written, a vertical TextField, a segmented Picker for the start moment, a prominent Button,
//  and UIActivityViewController with LPLinkMetadata.
//
//  A note being written survives the sheet being swiped away (ShareSongDrafts) until it is sent.

import AmperfyKit
import LinkPresentation
import SwiftUI

// MARK: - What the sheet needs to know about the song

struct ShareSongSubject {
  let songId: String
  let title: String
  let artist: String
  let cassetteLocalId: String
  let mbid: String?
  let artworkPath: String?
  /// Seconds into the song when Share was pressed, when it is the one playing and the moment is
  /// worth offering (past the first few seconds, before the last few). Nil otherwise.
  let elapsed: Int?

  @MainActor
  init(song: Song, player: PlayerFacade?) {
    songId = song.id
    title = song.title
    artist = song.creatorName
    cassetteLocalId = CassetteCloudPlaylistBridge.cassetteLocalId(for: song)
    mbid = song.musicBrainzId
    artworkPath = song.artwork?.imagePath
    if let player, player.currentlyPlaying?.asSong?.id == song.id {
      let at = Int(player.elapsedTime)
      elapsed = (at >= 3 && (song.duration == 0 || at <= song.duration - 5)) ? at : nil
    } else {
      elapsed = nil
    }
  }
}

// MARK: - Drafts

/// A note being written, kept per song until it is sent, so swiping the sheet away never loses it.
@MainActor
enum ShareSongDrafts {
  private static var notes: [String: String] = [:]
  static func note(for songId: String) -> String { notes[songId] ?? "" }
  static func keep(_ note: String, for songId: String) {
    notes[songId] = note.isEmpty ? nil : note
  }

  static func clear(_ songId: String) { notes[songId] = nil }
}

// MARK: - The sheet

struct ShareSongSheet: View {
  let subject: ShareSongSubject
  /// The share was saved: hand the link to Apple's share sheet.
  let onShare: (_ url: URL, _ title: String, _ text: String) -> ()
  /// The note field took the focus: grow the sheet to its large detent.
  let onWriting: () -> ()

  @State
  private var note: String
  @State
  private var fromHere = false
  @State
  private var sending = false
  @State
  private var message: String?
  @State
  private var albumFallback: (url: URL, title: String)?
  @FocusState
  private var writing: Bool

  init(
    subject: ShareSongSubject,
    onShare: @escaping (_ url: URL, _ title: String, _ text: String) -> (),
    onWriting: @escaping () -> ()
  ) {
    self.subject = subject
    self.onShare = onShare
    self.onWriting = onWriting
    _note = State(initialValue: ShareSongDrafts.note(for: subject.songId))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      songRow
      if let elapsed = subject.elapsed {
        Picker("Starts", selection: $fromHere) {
          Text("From the start").tag(false)
          Text("From \(clock(elapsed))").tag(true)
        }
        .pickerStyle(.segmented)
      }
      TextField("Add a note", text: $note, axis: .vertical)
        .lineLimit(1 ... 14)
        .font(Font.cassette(.body))
        .foregroundStyle(Color.cassette(.textPrimary))
        .padding(12)
        .background(
          RoundedRectangle(cornerRadius: 12)
            .fill(Color.cassette(.surfaceRaised))
        )
        .focused($writing)
        .onChange(of: writing) { _, isWriting in
          if isWriting { onWriting() }
        }
        .onChange(of: note) { _, value in
          ShareSongDrafts.keep(value, for: subject.songId)
        }
      if let message {
        Text(message)
          .font(Font.cassette(.caption))
          .foregroundStyle(Color.cassette(.textSecondary))
      }
      if let albumFallback {
        Button("Send the album instead") {
          onShare(albumFallback.url, "\(albumFallback.title) on Cassette", albumFallback.title)
        }
        .font(Font.cassette(.caption))
      }
      Spacer(minLength: 0)
      Button {
        Task { await send() }
      } label: {
        HStack(spacing: 8) {
          if sending { ProgressView() }
          Text(sending ? "Sending" : "Send")
        }
        .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .disabled(sending)
    }
    .padding(.horizontal, 20)
    .padding(.top, 24)
    .padding(.bottom, 16)
    .background(Color.cassette(.surfaceBase))
  }

  private var songRow: some View {
    HStack(spacing: 12) {
      artwork
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 4))
      VStack(alignment: .leading, spacing: 2) {
        Text(subject.title)
          .font(Font.cassette(.rowTitle))
          .foregroundStyle(Color.cassette(.textPrimary))
          .lineLimit(1)
        Text(subject.artist)
          .font(Font.cassette(.cardSubtitle))
          .foregroundStyle(Color.cassette(.textSecondary))
          .lineLimit(1)
      }
    }
  }

  @ViewBuilder
  private var artwork: some View {
    if let path = subject.artworkPath, let image = UIImage(contentsOfFile: path) {
      Image(uiImage: image).resizable().scaledToFill()
    } else {
      RoundedRectangle(cornerRadius: 4).fill(Color.cassette(.surfaceRaised))
    }
  }

  private func clock(_ seconds: Int) -> String {
    String(format: "%d:%02d", seconds / 60, seconds % 60)
  }

  @MainActor
  private func send() async {
    sending = true
    message = nil
    albumFallback = nil
    defer { sending = false }
    let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
    do {
      let result = try await CassetteSyncAPI.shared.createSongShare(
        cassetteLocalId: subject.cassetteLocalId,
        mbid: subject.mbid,
        subsonicTrackId: subject.songId,
        note: trimmed.isEmpty ? nil : trimmed,
        startSeconds: fromHere ? subject.elapsed : nil
      )
      if result.ok, let link = result.url.flatMap(URL.init(string:)) {
        ShareSongDrafts.clear(subject.songId)
        onShare(link, result.title ?? subject.title, result.text ?? subject.title)
        return
      }
      switch result.reason {
      case "no_video":
        message = "No video for this one yet."
        if let url = result.albumUrl.flatMap(URL.init(string:)) {
          albumFallback = (url, result.albumTitle ?? "The album")
        }
      default:
        message = "Cassette can't find this song in its catalog yet."
      }
    } catch CassetteSyncError.notAuthenticated {
      message = "Sign in to Cassette to share songs."
    } catch {
      message = "Couldn't share that. Try again."
    }
  }
}

// MARK: - The link preview Apple's share sheet draws

/// The shared link, with its preview ready: the song's title line and its artwork, so the share sheet
/// draws the card at once instead of fetching the page first.
final class ShareSongItem: NSObject, UIActivityItemSource {
  private let url: URL
  private let title: String
  private let image: UIImage?

  init(url: URL, title: String, image: UIImage?) {
    self.url = url
    self.title = title
    self.image = image
  }

  func activityViewControllerPlaceholderItem(_: UIActivityViewController) -> Any { url }

  func activityViewController(
    _: UIActivityViewController,
    itemForActivityType _: UIActivity.ActivityType?
  )
    -> Any? { url }

  func activityViewController(
    _: UIActivityViewController,
    subjectForActivityType _: UIActivity.ActivityType?
  )
    -> String { title }

  func activityViewControllerLinkMetadata(_: UIActivityViewController) -> LPLinkMetadata? {
    let metadata = LPLinkMetadata()
    metadata.originalURL = url
    metadata.url = url
    metadata.title = title
    if let image {
      metadata.imageProvider = NSItemProvider(object: image)
      metadata.iconProvider = NSItemProvider(object: image)
    }
    return metadata
  }
}

// MARK: - Presentation

extension UIViewController {
  /// Share a song: the sheet, then Apple's share sheet from this view controller. Call from any screen
  /// (a song's long-press menu, Now Playing).
  @MainActor
  func presentShareSong(_ song: Song) {
    let subject = ShareSongSubject(song: song, player: appDelegate.player)
    var hostRef: UIHostingController<ShareSongSheet>?
    let sheet = ShareSongSheet(
      subject: subject,
      onShare: { [weak self] url, title, _ in
        let image = subject.artworkPath.flatMap { UIImage(contentsOfFile: $0) }
        hostRef?.dismiss(animated: true) {
          self?.presentActivity(for: ShareSongItem(url: url, title: title, image: image))
        }
      },
      onWriting: {
        guard let sheet = hostRef?.sheetPresentationController else { return }
        sheet.animateChanges { sheet.selectedDetentIdentifier = .large }
      }
    )
    let host = UIHostingController(rootView: sheet)
    hostRef = host
    host.view.backgroundColor = UIColor(Color.cassette(.surfaceBase))
    host.overrideUserInterfaceStyle = .dark
    if let sheetController = host.sheetPresentationController {
      sheetController.detents = [.medium(), .large()]
      sheetController.prefersGrabberVisible = true
      sheetController.preferredCornerRadius = 28
      sheetController.prefersScrollingExpandsWhenScrolledToEdge = false
    }
    present(host, animated: true)
  }

  @MainActor
  private func presentActivity(for item: ShareSongItem) {
    let activity = UIActivityViewController(activityItems: [item], applicationActivities: nil)
    // iPad: the share sheet is a popover and needs somewhere to point
    if let popover = activity.popoverPresentationController {
      popover.sourceView = view
      popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
      popover.permittedArrowDirections = []
    }
    present(activity, animated: true)
  }
}
