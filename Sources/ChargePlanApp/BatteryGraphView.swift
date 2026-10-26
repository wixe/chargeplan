import AppKit
import Foundation

final class LinkButton: NSButton {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

final class BatteryGraphView: NSView {
    struct Sample {
        let timestamp: Date
        let percent: Double
        let targetLimit: Int
        let isCharging: Bool
    }
    
    public enum YAxisMode: Int {
        case full = 0    // 0% – 100%
        case zoomed = 1  // Focused operating band
    }
    
    public var yAxisMode: YAxisMode = .full {
        didSet {
            needsDisplay = true
        }
    }
    
    private var samples: [Sample] = []
    
    public var selectedRangeSeconds: Double = 1800.0 { // Default 30 minutes
        didSet {
            needsDisplay = true
        }
    }
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }
    
    func addSample(percent: Double, targetLimit: Int, isCharging: Bool, timestamp: Date = Date()) {
        if let last = samples.last, timestamp.timeIntervalSince(last.timestamp) < 0.5 {
            // In-place update to prevent duplicate samples within 0.5s
            samples[samples.count - 1] = Sample(timestamp: timestamp, percent: percent, targetLimit: targetLimit, isCharging: isCharging)
            needsDisplay = true
            return
        }
        
        // Append actual recorded sample only — no artificial historical anchors
        samples.append(Sample(timestamp: timestamp, percent: percent, targetLimit: targetLimit, isCharging: isCharging))
        
        // Retain up to 24 hours of rolling history (86,400s)
        let cutoff = timestamp.addingTimeInterval(-86400)
        if let idx = samples.firstIndex(where: { $0.timestamp >= cutoff }), idx > 0 {
            samples.removeFirst(idx)
        }
        
        needsDisplay = true
    }
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        
        let rect = bounds
        let bgPath = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        NSColor.controlBackgroundColor.withAlphaComponent(0.6).setFill()
        bgPath.fill()
        NSColor.separatorColor.withAlphaComponent(0.4).setStroke()
        bgPath.lineWidth = 1
        bgPath.stroke()
        
        let padLeft: CGFloat = 36
        let padRight: CGFloat = 12
        let padBottom: CGFloat = 18
        let padTop: CGFloat = 18
        let plotW = rect.width - padLeft - padRight
        let plotH = rect.height - padBottom - padTop
        guard plotW > 10 && plotH > 10 else { return }
        
        let now = samples.last?.timestamp ?? Date()
        let startTime = now.addingTimeInterval(-selectedRangeSeconds)
        
        // Visible samples within the selected time window
        var visible = samples.filter { $0.timestamp >= startTime }
        if let older = samples.last(where: { $0.timestamp < startTime }) {
            visible.insert(Sample(timestamp: startTime, percent: older.percent, targetLimit: older.targetLimit, isCharging: older.isCharging), at: 0)
        }
        
        // Compute Y-axis min, max, and grid step
        let yMin: Double
        let yMax: Double
        let gridStep: Double
        
        switch yAxisMode {
        case .full:
            yMin = 0.0
            yMax = 100.0
            gridStep = 25.0
        case .zoomed:
            let cap = Double(samples.last?.targetLimit ?? 80)
            let pcts = visible.map(\.percent)
            let minPct = pcts.min() ?? cap
            let maxPct = pcts.max() ?? cap
            var lo = min(minPct, cap) - 3.0
            var hi = max(maxPct, cap) + 3.0
            if (hi - lo) < 15.0 {
                let center = (lo + hi) / 2.0
                lo = center - 7.5
                hi = center + 7.5
            }
            if (hi - lo) > 35.0 {
                gridStep = 10.0
                yMin = max(0.0, floor(lo / 10.0) * 10.0)
                yMax = min(100.0, ceil(hi / 10.0) * 10.0)
            } else {
                gridStep = 5.0
                yMin = max(0.0, floor(lo / 5.0) * 5.0)
                yMax = min(100.0, ceil(hi / 5.0) * 5.0)
            }
        }
        let ySpan = max(1.0, yMax - yMin)
        
        // Grid reference lines & Left Y-axis labels
        let gridColor = NSColor.tertiaryLabelColor.withAlphaComponent(0.35)
        let gridFont = NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .regular)
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: gridFont,
            .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.7)
        ]
        
        var curLevel = yMin
        while curLevel <= yMax + 0.001 {
            let y = padBottom + CGFloat((curLevel - yMin) / ySpan) * plotH
            
            let gPath = NSBezierPath()
            gPath.move(to: NSPoint(x: padLeft, y: y))
            gPath.line(to: NSPoint(x: rect.width - padRight, y: y))
            let dashes: [CGFloat] = [2, 4]
            gPath.setLineDash(dashes, count: 2, phase: 0)
            gridColor.setStroke()
            gPath.lineWidth = 0.5
            gPath.stroke()
            
            let tick = NSBezierPath()
            tick.move(to: NSPoint(x: padLeft - 3, y: y))
            tick.line(to: NSPoint(x: padLeft, y: y))
            gridColor.setStroke()
            tick.lineWidth = 0.75
            tick.stroke()
            
            let label = "\(Int(round(curLevel)))%"
            let labelSize = (label as NSString).size(withAttributes: textAttrs)
            let labelX = max(2, padLeft - labelSize.width - 5)
            let labelY = max(2, min(rect.height - labelSize.height - 2, y - labelSize.height * 0.5))
            (label as NSString).draw(at: NSPoint(x: labelX, y: labelY), withAttributes: textAttrs)
            
            curLevel += gridStep
        }
        
        // Left Y-axis vertical ruler line
        let yAxisLine = NSBezierPath()
        yAxisLine.move(to: NSPoint(x: padLeft, y: padBottom))
        yAxisLine.line(to: NSPoint(x: padLeft, y: padBottom + plotH))
        gridColor.setStroke()
        yAxisLine.lineWidth = 0.75
        yAxisLine.stroke()
        
        // Target Limit dashed line (Amber / Orange)
        if let targetLimit = samples.last?.targetLimit, Double(targetLimit) >= yMin && Double(targetLimit) <= yMax {
            let targetY = padBottom + CGFloat((Double(targetLimit) - yMin) / ySpan) * plotH
            let tPath = NSBezierPath()
            tPath.move(to: NSPoint(x: padLeft, y: targetY))
            tPath.line(to: NSPoint(x: rect.width - padRight, y: targetY))
            let dashes: [CGFloat] = [4, 3]
            tPath.setLineDash(dashes, count: 2, phase: 0)
            NSColor.systemOrange.withAlphaComponent(0.75).setStroke()
            tPath.lineWidth = 1.0
            tPath.stroke()
            
            let capTag = "Target \(targetLimit)%"
            let capAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 8, weight: .semibold),
                .foregroundColor: NSColor.systemOrange
            ]
            let tagSize = (capTag as NSString).size(withAttributes: capAttrs)
            (capTag as NSString).draw(at: NSPoint(x: rect.width - padRight - tagSize.width - 2, y: min(rect.height - 12, targetY - 4)), withAttributes: capAttrs)
        }
        
        // Time Axis Baseline & Ticks
        let baseline = NSBezierPath()
        baseline.move(to: NSPoint(x: padLeft, y: padBottom))
        baseline.line(to: NSPoint(x: rect.width - padRight, y: padBottom))
        gridColor.setStroke()
        baseline.lineWidth = 0.75
        baseline.stroke()
        
        for frac: CGFloat in [0.0, 0.5, 1.0] {
            let tickX = padLeft + frac * plotW
            let tick = NSBezierPath()
            tick.move(to: NSPoint(x: tickX, y: padBottom))
            tick.line(to: NSPoint(x: tickX, y: padBottom - 3))
            gridColor.setStroke()
            tick.lineWidth = 0.75
            tick.stroke()
        }
        
        // Time Axis Labels
        let timeFont = NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .medium)
        let timeAttrs: [NSAttributedString.Key: Any] = [
            .font: timeFont,
            .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.8)
        ]
        
        let leftLabel = "-30m"
        let midLabel = "-15m"
        let rightLabel = "Now"
        
        (leftLabel as NSString).draw(at: NSPoint(x: padLeft, y: 3), withAttributes: timeAttrs)
        
        let midSize = (midLabel as NSString).size(withAttributes: timeAttrs)
        (midLabel as NSString).draw(at: NSPoint(x: padLeft + (plotW - midSize.width) * 0.5, y: 3), withAttributes: timeAttrs)
        
        let rightSize = (rightLabel as NSString).size(withAttributes: timeAttrs)
        (rightLabel as NSString).draw(at: NSPoint(x: rect.width - padRight - rightSize.width, y: 3), withAttributes: timeAttrs)
        
        guard !samples.isEmpty else { return }
        
        // Group samples into continuous segments (break on gaps > 30s)
        var segments: [[Sample]] = []
        var currentSegment: [Sample] = []
        let maxGapSeconds: Double = 30.0
        
        for s in visible {
            if let lastS = currentSegment.last {
                if s.timestamp.timeIntervalSince(lastS.timestamp) > maxGapSeconds {
                    if !currentSegment.isEmpty {
                        segments.append(currentSegment)
                    }
                    currentSegment = [s]
                } else {
                    currentSegment.append(s)
                }
            } else {
                currentSegment.append(s)
            }
        }
        if !currentSegment.isEmpty {
            segments.append(currentSegment)
        }
        
        let isCharging = samples.last?.isCharging ?? false
        let baseColor = isCharging ? NSColor.systemGreen : NSColor.systemBlue
        
        for seg in segments {
            guard seg.count >= 2 else {
                if let single = seg.first {
                    let elapsed = single.timestamp.timeIntervalSince(startTime)
                    let frac = max(0.0, min(1.0, elapsed / selectedRangeSeconds))
                    let x = padLeft + CGFloat(frac) * plotW
                    let clampedPct = max(yMin, min(yMax, single.percent))
                    let y = padBottom + CGFloat((clampedPct - yMin) / ySpan) * plotH
                    baseColor.setFill()
                    let dot = NSBezierPath(ovalIn: NSRect(x: x - 2, y: y - 2, width: 4, height: 4))
                    dot.fill()
                }
                continue
            }
            
            var points: [NSPoint] = []
            for s in seg {
                let elapsed = s.timestamp.timeIntervalSince(startTime)
                let frac = max(0.0, min(1.0, elapsed / selectedRangeSeconds))
                let x = padLeft + CGFloat(frac) * plotW
                let clampedPct = max(yMin, min(yMax, s.percent))
                let y = padBottom + CGFloat((clampedPct - yMin) / ySpan) * plotH
                points.append(NSPoint(x: x, y: y))
            }
            
            guard points.count >= 2 else { continue }
            
            let fillPath = NSBezierPath()
            fillPath.move(to: NSPoint(x: points[0].x, y: padBottom))
            for pt in points {
                fillPath.line(to: pt)
            }
            fillPath.line(to: NSPoint(x: points.last!.x, y: padBottom))
            fillPath.close()
            
            ctx.saveGState()
            fillPath.addClip()
            let gradient = NSGradient(starting: baseColor.withAlphaComponent(0.28), ending: baseColor.withAlphaComponent(0.02))
            gradient?.draw(in: rect, angle: 90)
            ctx.restoreGState()
            
            let strokePath = NSBezierPath()
            strokePath.move(to: points[0])
            for pt in points.dropFirst() {
                strokePath.line(to: pt)
            }
            baseColor.setStroke()
            strokePath.lineWidth = 2.0
            strokePath.lineCapStyle = .round
            strokePath.lineJoinStyle = .round
            strokePath.stroke()
        }
        
        if let lastSample = samples.last {
            let elapsed = lastSample.timestamp.timeIntervalSince(startTime)
            let frac = max(0.0, min(1.0, elapsed / selectedRangeSeconds))
            let lastX = padLeft + CGFloat(frac) * plotW
            let clampedPct = max(yMin, min(yMax, lastSample.percent))
            let lastY = padBottom + CGFloat((clampedPct - yMin) / ySpan) * plotH
            let lastPt = NSPoint(x: lastX, y: lastY)
            
            baseColor.withAlphaComponent(0.3).setFill()
            let glow = NSBezierPath(ovalIn: NSRect(x: lastPt.x - 5, y: lastPt.y - 5, width: 10, height: 10))
            glow.fill()
            
            baseColor.setFill()
            let dot = NSBezierPath(ovalIn: NSRect(x: lastPt.x - 2.5, y: lastPt.y - 2.5, width: 5, height: 5))
            dot.fill()
            
            let str = String(format: "%.2f%%", lastSample.percent)
            let badgeAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold),
                .foregroundColor: baseColor
            ]
            let strSize = (str as NSString).size(withAttributes: badgeAttrs)
            var strX = lastPt.x - strSize.width - 6
            var strY = lastPt.y + 4
            if strY + strSize.height > rect.height - 2 {
                strY = lastPt.y - strSize.height - 4
            }
            if strX < padLeft {
                strX = padLeft + 2
            }
            (str as NSString).draw(at: NSPoint(x: strX, y: strY), withAttributes: badgeAttrs)
        }
    }
}

