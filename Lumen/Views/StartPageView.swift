import SwiftUI

struct StartPageView: View {
    @ObservedObject var session: BrowserSession
    @ObservedObject var tab: BrowserTab

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LumenTheme.workspace
                SanctuaryFlower()
                    .frame(width: min(380, geometry.size.width * 0.72),
                           height: min(380, geometry.size.height * 0.72))
                    .accessibilityLabel("A luminous flower")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// A lightweight native illustration. No images, network requests, or animation timer.
private struct SanctuaryFlower: View {
    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.height * 0.40, size.width * 0.36)
            let halo = CGRect(x: center.x - radius * 1.25, y: center.y - radius * 1.25,
                              width: radius * 2.5, height: radius * 2.5)
            context.fill(Path(ellipseIn: halo), with: .radialGradient(
                Gradient(colors: [LumenTheme.accent.opacity(0.16), .clear]),
                center: center, startRadius: 0, endRadius: radius * 1.25))
            for ring in 0..<2 {
                for petal in 0..<12 {
                    var layer = context
                    layer.translateBy(x: center.x, y: center.y)
                    layer.rotate(by: .radians(Double(petal) * .pi / 6 + Double(ring) * .pi / 12))
                    let length = radius * (ring == 0 ? 1 : 0.72)
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: 8))
                    path.addCurve(to: CGPoint(x: 0, y: -length),
                                  control1: CGPoint(x: -length * 0.53, y: -length * 0.28),
                                  control2: CGPoint(x: -length * 0.22, y: -length * 0.84))
                    path.addCurve(to: CGPoint(x: 0, y: 8),
                                  control1: CGPoint(x: length * 0.22, y: -length * 0.84),
                                  control2: CGPoint(x: length * 0.53, y: -length * 0.28))
                    let color = ring == 0 ? LumenTheme.accent : LumenTheme.amber
                    layer.fill(path, with: .color(color.opacity(0.035)))
                    layer.stroke(path, with: .color(color.opacity(ring == 0 ? 0.65 : 0.8)), lineWidth: 1)
                }
            }
            for scale in [1.14, 1.23] {
                let r = radius * scale
                context.stroke(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2*r, height: 2*r)),
                               with: .color(LumenTheme.amber.opacity(0.17)), lineWidth: 0.6)
            }
            context.fill(Path(ellipseIn: CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10)), with: .color(LumenTheme.amber))
        }
        .allowsHitTesting(false)
    }
}
