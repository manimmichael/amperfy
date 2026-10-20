//
//  CassetteBanner.swift
//  Amperfy
//
//  Cassette: one banner look (design-system audit 2026-10-20, Wave 3, BRW-4).
//
//  The app had four banner systems: the Home sync banner (raised surface, 14pt corners,
//  hairline border), the error/info toast (raised surface, 10pt corners, severity lost),
//  the SwiftUI settings banner (white text on full system red or green, 10pt) and a
//  system-blue sync popup nothing presented any more. They now share the Home sync
//  banner's surface, and severity is carried by an accent on that surface, never a fill.
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
import SwiftUI
import UIKit

// MARK: - CassetteBannerKind

/// What a banner is telling the person. Drives only the accent: the border of a toast, the
/// leading bar of an inline banner.
enum CassetteBannerKind {
  case info
  case success
  case error
  /// Something is underway (sync).
  case progress

  init(logType: LogEntryType) {
    switch logType {
    case .apiError, .error: self = .error
    case .info, .debug: self = .info
    }
  }

  var accent: CassetteColorRole {
    switch self {
    case .info: return .hairline
    case .success: return .success
    case .error: return .danger
    case .progress: return .accentProgress
    }
  }
}

// MARK: - CassetteBannerStyle

/// The shared surface, taken from the Home sync banner.
enum CassetteBannerStyle {
  static let background = CassetteColorRole.surfaceRaised
  static let cornerRadius = CassetteRadius.card
  static let borderWidth: CGFloat = 1
  /// The leading accent bar on an inline banner.
  static let accentWidth: CGFloat = 3
  static let titleFont = CassetteTextStyle.miniTitle
  static let messageFont = CassetteTextStyle.body
  static let textColor = CassetteColorRole.textPrimary
  static let padding = CassetteTheme.Spacing.md
}

// MARK: - CassetteBannerView (SwiftUI)

/// An inline banner in a SwiftUI screen (settings forms report success or failure here).
struct CassetteBannerView: View {
  var message: String
  var kind: CassetteBannerKind

  var body: some View {
    HStack(spacing: 0) {
      Rectangle()
        .fill(Color.cassette(kind.accent))
        .frame(width: CassetteBannerStyle.accentWidth)
      Text(message)
        .font(Font.cassette(CassetteBannerStyle.messageFont))
        .foregroundStyle(Color.cassette(CassetteBannerStyle.textColor))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(CassetteBannerStyle.padding)
    }
    .background(Color.cassette(CassetteBannerStyle.background))
    .clipShape(RoundedRectangle(cornerRadius: CassetteBannerStyle.cornerRadius, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: CassetteBannerStyle.cornerRadius, style: .continuous)
        .stroke(
          Color.cassette(.hairline),
          lineWidth: CassetteBannerStyle.borderWidth
        )
    )
  }
}

// MARK: - CassetteBannerView_Previews

struct CassetteBannerView_Previews: PreviewProvider {
  static var previews: some View {
    VStack(spacing: 12) {
      CassetteBannerView(message: "Password updated.", kind: .success)
      CassetteBannerView(message: "The server did not answer.", kind: .error)
      CassetteBannerView(message: "Syncing your library.", kind: .progress)
    }
    .padding()
    .background(Color.cassette(.surfaceBase))
    .preferredColorScheme(.dark)
  }
}
