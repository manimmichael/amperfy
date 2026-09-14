//
//  MoodDoorArt.swift
//  Amperfy
//
//  Cassette: native port of the web app's MoodTileArt.tsx — same six
//  procedural motifs (radial bloom, dot grid, diagonal stripes, concentric
//  rings, diamond outline, hatch lines), same 200x150 proportions, drawn with
//  SwiftUI Canvas instead of inline SVG. Sits behind the door name as a
//  low-opacity texture layer, same as on web — never a poster, texture only.

import SwiftUI

struct MoodDoorArt: View {
  let shape: MoodDoorShape
  let color: Color

  /// Reference box the web SVGs are drawn in (viewBox="0 0 200 150") —
  /// every coordinate below is proportional to this, then scaled to
  /// whatever size Canvas actually renders at.
  private static let refWidth: CGFloat = 200
  private static let refHeight: CGFloat = 150

  var body: some View {
    Canvas { context, size in
      let sx = size.width / Self.refWidth
      let sy = size.height / Self.refHeight
      func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * sx, y: y * sy) }

      switch shape {
      case .radialBloom:
        let center = p(140, 30)
        let radius = 150 * max(sx, sy)
        context.fill(
          Path(ellipseIn: CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
          )),
          with: .radialGradient(
            Gradient(stops: [
              .init(color: color.opacity(0.55), location: 0),
              .init(color: color.opacity(0.12), location: 0.6),
              .init(color: color.opacity(0), location: 1),
            ]),
            center: center,
            startRadius: 0,
            endRadius: radius
          )
        )

      case .dotGrid:
        for row in 0 ..< 5 {
          for col in 0 ..< 7 {
            let center = p(20 + CGFloat(col) * 26, 10 + CGFloat(row) * 26)
            let r: CGFloat = 2.5 * min(sx, sy)
            context.fill(
              Path(ellipseIn: CGRect(
                x: center.x - r,
                y: center.y - r,
                width: r * 2,
                height: r * 2
              )),
              with: .color(color.opacity(0.35))
            )
          }
        }

      case .diagonalStripes:
        for i in 0 ..< 14 {
          let x = CGFloat(-60 + i * 24)
          var path = Path()
          path.move(to: p(x, 160))
          path.addLine(to: p(x + 160, -10))
          context.stroke(path, with: .color(color.opacity(0.3)), lineWidth: 2)
        }

      case .concentricRings:
        let center = p(155, 30)
        for r: CGFloat in [14, 28, 42, 56] {
          let radius = r * min(sx, sy)
          context.stroke(
            Path(ellipseIn: CGRect(
              x: center.x - radius,
              y: center.y - radius,
              width: radius * 2,
              height: radius * 2
            )),
            with: .color(color.opacity(0.35)),
            lineWidth: 1.5
          )
        }

      case .diamondOutline:
        func diamond(cx: CGFloat, cy: CGFloat, side: CGFloat) -> Path {
          var path = Path()
          path.move(to: p(cx, cy - side))
          path.addLine(to: p(cx + side, cy))
          path.addLine(to: p(cx, cy + side))
          path.addLine(to: p(cx - side, cy))
          path.closeSubpath()
          return path
        }
        context.stroke(
          diamond(cx: 156, cy: 30, side: 26),
          with: .color(color.opacity(0.4)),
          lineWidth: 2
        )
        context.stroke(
          diamond(cx: 160, cy: 70, side: 15),
          with: .color(color.opacity(0.4)),
          lineWidth: 2
        )

      case .hatchLines:
        for i in 0 ..< 10 {
          let x = CGFloat(100 + i * 10)
          var path = Path()
          path.move(to: p(x, 0))
          path.addLine(to: p(x - 40, 150))
          context.stroke(path, with: .color(color.opacity(0.28)), lineWidth: 1.5)
        }
      }
    }
  }
}
