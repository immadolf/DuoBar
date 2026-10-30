import AppKit

/// Stateless AppKit/CoreGraphics port of the visible geometry in upstream DuoBar
/// v1.3.2 (DuoGlyphMetrics, DuoWiFiReferenceGeometry and DuoVolumeIndicatorGeometry).
/// No timer, retain cycle, SwiftUI view tree or animated state is involved.
enum GlyphRenderer {
    static let imageSize = NSSize(width: 29, height: 24)
    static let statusItemWidth: CGFloat = 31
    private static let canvasScale: CGFloat = (24.0 / 32.0) * 1.05
    private static let referenceRingDiameter: CGFloat = 26.5
    private static let referenceRingYOffset: CGFloat = -0.8
    private static let arcGap = 120.22
    private static let strokeRatio: CGFloat = 0.076378

    static func activeDotCount(volume: Double?, muted: Bool) -> Int? {
        guard let volume, volume.isFinite else { return nil }
        if muted { return 0 }
        return min(4, max(0, Int(ceil(max(0, min(volume, 1)) * 4))))
    }

    static func image(for status: Status, from previous: Status? = nil,
                      progress: CGFloat = 1) -> NSImage {
        // Capture only the value-type snapshot. NSImage may defer drawing until
        // AppKit asks for its representation.
        let snapshot = status
        let oldSnapshot = previous
        let phase = progress
        let image = NSImage(size: imageSize, flipped: false) { frame in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            draw(snapshot, in: frame, context: context, from: oldSnapshot, progress: phase)
            return true
        }
        image.isTemplate = true
        return image
    }

    static func draw(_ status: Status, in bounds: CGRect, context: CGContext,
                     from previous: Status? = nil, progress: CGFloat = 1) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setShouldAntialias(true)
        // Smoothstep is a deterministic ease-in-out, with no long-lived display link.
        let t = min(1, max(0, progress))
        let eased = t * t * (3 - 2 * t)
        let scale = canvasScale
        let ringDiameter = referenceRingDiameter * scale
        let ringLineWidth = referenceRingDiameter * strokeRatio * scale
        let ringRadius = (ringDiameter - ringLineWidth) / 2
        // Convert SwiftUI's y-down coordinate space to CoreGraphics' y-up.
        let center = CGPoint(x: bounds.midX, y: bounds.midY - referenceRingYOffset * scale)
        let foreground = NSColor.labelColor.withAlphaComponent(1.0)
        let ringAvailable = status.charge != nil
        let start = -(90.0 + arcGap / 2.0) * .pi / 180.0
        let sweep = -(360.0 - arcGap) * .pi / 180.0

        context.setLineWidth(ringLineWidth)
        context.setLineCap(.round)
        context.setStrokeColor(foreground.withAlphaComponent(ringAvailable ? 0.24 : 0.18).cgColor)
        context.addArc(center: center, radius: ringRadius,
                       startAngle: start, endAngle: start + sweep, clockwise: true)
        context.strokePath()

        if let target = status.charge {
            let old = previous?.charge ?? target
            let value = old + (target - old) * Double(eased)
            if value > 0 {
                context.setStrokeColor(foreground.cgColor)
                context.addArc(center: center, radius: ringRadius,
                               startAngle: start, endAngle: start + sweep * value, clockwise: true)
                context.strokePath()
            }
        }

        // An unobtrusive battery charging indicator at the top of the ring.
        // The original app animates its appearance; the Lite edition draws only
        // the settled state, with no 60-fps display link or animation loop.
        let targetBoltAlpha: CGFloat = status.onAC ? (status.charge.map { $0 >= 0.999 ? 0.52 : 1.0 } ?? 0.4) : 0
        let oldBoltAlpha: CGFloat = previous.map {
            $0.onAC ? ($0.charge.map { $0 >= 0.999 ? 0.52 : 1.0 } ?? 0.4) : 0
        } ?? targetBoltAlpha
        let boltAlpha = oldBoltAlpha + (targetBoltAlpha - oldBoltAlpha) * eased
        if boltAlpha > 0.01 {
            let boltPoint = CGPoint(x: center.x, y: center.y + ringRadius - 1.8 * scale)
            let hole = CGRect(x: boltPoint.x - 2.65, y: boltPoint.y - 3.15,
                              width: 5.3, height: 6.3)
            context.saveGState()
            context.setBlendMode(.clear)
            context.fill(hole)
            context.restoreGState()
            drawSymbol("bolt.fill",
                       in: CGRect(x: boltPoint.x - 2.4, y: boltPoint.y - 3.3,
                                  width: 4.8, height: 6.6),
                       opacity: boltAlpha)
        }

        // Center glyphs must NEVER be cross-faded on top of each other:
        // "network.slash" + Wi-Fi arcs + Ethernet are different shapes, and
        // blending them makes the menu icon look like multiple states at once.
        // Use fade-out, discrete switch at midpoint, fade-in instead.
        if let previous, previous.networkUp != status.networkUp
            || previous.networkKind != status.networkKind || previous.wifiOn != status.wifiOn {
            context.saveGState()
            if eased < 0.5 {
                context.setAlpha(1 - 2 * eased)
                drawCenter(previous, center: center, ringDiameter: ringDiameter,
                           scale: scale, context: context)
            } else {
                context.setAlpha(2 * eased - 1)
                drawCenter(status, center: center, ringDiameter: ringDiameter,
                           scale: scale, context: context)
            }
            context.restoreGState()
        } else {
            drawCenter(status, center: center, ringDiameter: ringDiameter, scale: scale, context: context)
        }
        drawDots(status, previous: previous, eased: eased, center: center,
                 ringDiameter: ringDiameter, context: context)
    }

    private static func drawCenter(_ status: Status, center: CGPoint,
                                   ringDiameter: CGFloat, scale: CGFloat, context: CGContext) {
        guard status.networkUp && !(status.wifiOn == false && status.networkKind == .wifi) else {
            drawSymbol("network.slash",
                       in: CGRect(x: center.x - 5.2 * scale / 0.75,
                                  y: center.y - 4.6 * scale / 0.75,
                                  width: 10.4 * scale / 0.75,
                                  height: 9.2 * scale / 0.75),
                       opacity: 0.45)
            return
        }

        if status.networkKind == .ethernet {
            drawSymbol("cable.connector.horizontal",
                       in: CGRect(x: center.x - 5.7, y: center.y - 4.6,
                                  width: 11.4, height: 9.2))
            return
        }

        if status.networkKind != .wifi {
            drawSymbol("ellipsis.circle", in: CGRect(x: center.x - 4.5, y: center.y - 4.5,
                                                     width: 9, height: 9), opacity: 0.8)
            return
        }

        // Reference shape measured in upstream's DuoWiFiReferenceGeometry.
        // The central apex is slightly below the ring centre.
        let apex = CGPoint(x: center.x, y: center.y - ringDiameter * 0.128157)
        let width = ringDiameter * 0.060540
        context.setStrokeColor(NSColor.labelColor.cgColor)
        context.setLineWidth(width)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        let bands: Int
        if let rssi = status.wifiRSSI {
            bands = rssi >= -65 ? 3 : rssi >= -75 ? 2 : 1
        } else {
            bands = 3
        }
        for (index, radiusRatio) in [CGFloat(0.268964), 0.155314].enumerated() {
            context.saveGState()
            context.setAlpha(index == 0 && bands < 3 || index == 1 && bands < 2 ? 0.28 : 1)
            let radius = ringDiameter * radiusRatio
            let span = 43.673 * .pi / 180.0
            context.addArc(center: apex, radius: radius,
                           startAngle: .pi / 2 + span,
                           endAngle: .pi / 2 - span,
                           clockwise: true)
            context.strokePath()
            context.restoreGState()
        }
        context.saveGState()
        context.setAlpha(bands >= 1 ? 1 : 0.28)
        let radius = ringDiameter * 0.059620
        let half = 59.232 * .pi / 180.0
        context.move(to: apex)
        context.addArc(center: apex, radius: radius,
                       startAngle: .pi / 2 + half,
                       endAngle: .pi / 2 - half,
                       clockwise: true)
        context.closePath()
        context.setFillColor(NSColor.labelColor.cgColor)
        context.fillPath()
        context.restoreGState()
    }

    private static func drawDots(_ status: Status, previous: Status?, eased: CGFloat,
                                 center: CGPoint,
                                 ringDiameter: CGFloat, context: CGContext) {
        let count = activeDotCount(volume: status.volume, muted: status.muted)
        let oldCount = previous.flatMap { activeDotCount(volume: $0.volume, muted: $0.muted) } ?? count
        let dotDiameter = ringDiameter * 0.096502
        let centerRadius = ringDiameter * 0.455450
        for (index, degrees) in [32.273, 10.813, -10.813, -32.273].enumerated() {
            let angle = degrees * .pi / 180
            let point = CGPoint(x: center.x - sin(angle) * centerRadius,
                                y: center.y - cos(angle) * centerRadius)
            let afterAlpha: CGFloat = count.map { index < $0 ? 1.0 : 0.30 } ?? 0.30
            let beforeAlpha: CGFloat = oldCount.map { index < $0 ? 1.0 : 0.30 } ?? 0.30
            context.setFillColor(NSColor.labelColor.withAlphaComponent(
                beforeAlpha + (afterAlpha - beforeAlpha) * eased
            ).cgColor)
            context.fillEllipse(in: CGRect(x: point.x - dotDiameter / 2,
                                           y: point.y - dotDiameter / 2,
                                           width: dotDiameter,
                                           height: dotDiameter))
        }
    }

    private static func drawSymbol(_ name: String, in bounds: CGRect, opacity: CGFloat = 1) {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)) else {
            return
        }
        image.isTemplate = true
        image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: opacity)
    }
}
