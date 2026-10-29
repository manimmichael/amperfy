//
//  Radio.swift
//  AmperfyKit
//
//  Created by Maximilian Bauer on 27.12.24.
//  Copyright (c) 2024 Maximilian Bauer. All rights reserved.
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
import Foundation
import UIKit

public class Radio: AbstractPlayable, Identifyable {
  public let managedObject: RadioMO

  public init(managedObject: RadioMO) {
    self.managedObject = managedObject
    super.init(managedObject: managedObject)
  }

  public var siteURL: URL? {
    get {
      guard let siteUrlString = managedObject.siteUrl else { return nil }
      return URL(string: siteUrlString)
    }
    set {
      managedObject.siteUrl = newValue?.absoluteString
    }
  }

  override public var creatorName: String {
    ""
  }

  override public func infoDetails(for api: ServerApiType?, details: DetailInfoType) -> [String] {
    var infoContent = [String]()
    if details.type == .long {
      if let siteUrl = siteURL {
        infoContent.append("Site \(siteUrl)")
      }
      if let urlString = url {
        infoContent.append("Steam URL \(urlString)")
      }
    }
    return infoContent
  }

  public var identifier: String {
    title
  }

  override public func isAvailableToUser() -> Bool {
    // See also RadioMO.excludeServerDeleteRadiosFetchPredicate()
    remoteStatus == .available
  }

  /// cassette 2026-10-29 (BUG-617): the phone keeps its own record of every station on Cassette's
  /// dial, so the whole dial plays without the computer holding a station (a station plays from its
  /// own stream). Their ids start with this, then the station's registry slug; the computer's station
  /// sync leaves them alone (LibraryStorage.matchDialRadios).
  public static let dialIdPrefix = "cassette-dial:"

  /// One of the phone's own dial records, not a station the computer holds.
  public var isOnDial: Bool { id.hasPrefix(Self.dialIdPrefix) }
}

// MARK: - DialStation

/// A station on Cassette's dial as the app holds it, for LibraryStorage.matchDialRadios.
public struct DialStation: Sendable {
  public let slug: String
  public let name: String
  public let streamUrl: String
  public let siteUrl: String?

  public init(slug: String, name: String, streamUrl: String, siteUrl: String?) {
    self.slug = slug
    self.name = name
    self.streamUrl = streamUrl
    self.siteUrl = siteUrl
  }
}
