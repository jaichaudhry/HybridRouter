import Foundation
import HybridRouterKit

/// Draws a quality-vs-cost chart (one point per strategy) as an SVG, in the style of the
/// architecture diagram.
enum QualityChart {
    /// One theme of `svg`. Safari doesn't apply `prefers-color-scheme` inside an SVG shown with
    /// `<img>`, so the README picks a light or dark file with `<picture>` instead.
    static func themed(_ svg: String, dark: Bool) -> String {
        guard let start = svg.range(of: "@media (prefers-color-scheme: dark) {"),
              let end = svg.range(of: "\n    }\n", range: start.upperBound..<svg.endIndex) else { return svg }
        let darkRules = String(svg[start.upperBound..<end.lowerBound])
        // Later rules win, so the dark file keeps the light rules and appends the dark ones.
        return svg.replacingCharacters(in: start.lowerBound..<end.upperBound, with: dark ? darkRules + "\n" : "")
    }

    static func svg(_ report: QualityReport, caption: String) -> String {
        let width = 760.0, height = 470.0
        let plot = (left: 70.0, top: 40.0, right: 730.0, bottom: 380.0)
        let maxCost = max(0.2, (report.strategies.map(\.costPer100).max() ?? 1) * 1.1)
        let costStep = maxCost > 1 ? 0.25 : 0.1
        let minPass = max(0, floor((report.strategies.map(\.passRate).min() ?? 0) * 10 - 1) * 10)
        func x(_ cost: Double) -> Double { plot.left + cost / maxCost * (plot.right - plot.left) }
        func y(_ pass: Double) -> Double { plot.bottom - (pass * 100 - minPass) / (100 - minPass) * (plot.bottom - plot.top) }
        func f(_ v: Double) -> String { String(format: "%.1f", v) }

        var body: [String] = []
        // Grid and axes.
        for pass in stride(from: minPass, through: 100, by: 10) {
            body.append(#"<line class="grid" x1="\#(f(plot.left))" y1="\#(f(y(pass / 100)))" x2="\#(f(plot.right))" y2="\#(f(y(pass / 100)))"/>"#)
            body.append(#"<text class="tick" x="\#(f(plot.left - 10))" y="\#(f(y(pass / 100) + 4))" text-anchor="end">\#(Int(pass))%</text>"#)
        }
        for cost in stride(from: 0.0, through: maxCost + 1e-9, by: costStep) {
            body.append(#"<line class="grid" x1="\#(f(x(cost)))" y1="\#(f(plot.top))" x2="\#(f(x(cost)))" y2="\#(f(plot.bottom))"/>"#)
            body.append(#"<text class="tick" x="\#(f(x(cost)))" y="\#(f(plot.bottom + 20))" text-anchor="middle">$\#(String(format: "%.2f", cost))</text>"#)
        }
        body.append(#"<text class="axis" x="\#(f((plot.left + plot.right) / 2))" y="\#(f(plot.bottom + 46))" text-anchor="middle">Cost per 100 prompts (USD)</text>"#)
        body.append(#"<text class="axis" transform="translate(18 \#(f((plot.top + plot.bottom) / 2))) rotate(-90)" text-anchor="middle">Answers judged good enough</text>"#)

        // Points first, then labels: each label takes the first of right, left, below or above
        // its point that stays inside the plot and clear of every point and earlier label.
        typealias Box = (minX: Double, maxX: Double, minY: Double, maxY: Double)
        func overlaps(_ a: Box, _ b: Box) -> Bool {
            a.minX < b.maxX && b.minX < a.maxX && a.minY < b.maxY && b.minY < a.maxY
        }
        let points = report.strategies.map { (result: $0, px: x($0.costPer100), py: y($0.passRate)) }
        var placed: [Box] = points.map { ($0.px - 10, $0.px + 10, $0.py - 10, $0.py + 10) }
        for point in points {
            let (cls, r) = switch point.result.strategy {
            case .router: ("router", 9.0)
            case .oracle: ("oracle", 6.5)
            default: ("point", 6.5)
            }
            body.append(#"<circle class="\#(cls)" cx="\#(f(point.px))" cy="\#(f(point.py))" r="\#(f(r))"/>"#)
        }
        for (index, point) in points.enumerated() {
            let (px, py) = (point.px, point.py)
            let name = label(point.result.strategy)
            let detail = "\(Int((point.result.passRate * 100).rounded()))% · $\(String(format: "%.2f", point.result.costPer100))"
            // Roughly 7 px per character at 13 px; two lines, 32 px tall.
            let width = Double(max(name.count, detail.count)) * 7.2
            // (text x, anchor, box): right, left, below and above the point.
            let candidates: [(x: Double, anchor: String, box: Box)] = [
                (px + 14, "start", (px + 14, px + 14 + width, py - 15, py + 17)),
                (px - 14, "end", (px - 14 - width, px - 14, py - 15, py + 17)),
                (px - width / 2, "start", (px - width / 2, px + width / 2, py + 12, py + 44)),
                (px - width / 2, "start", (px - width / 2, px + width / 2, py - 46, py - 14)),
            ]
            let others = placed.enumerated().filter { $0.offset != index }.map(\.element)
            let fits = candidates.first { candidate in
                candidate.box.minX >= plot.left && candidate.box.maxX <= plot.right + 20
                    && candidate.box.minY >= plot.top - 30 && candidate.box.maxY <= plot.bottom
                    && !others.contains { overlaps(candidate.box, $0) }
            } ?? candidates[0]
            placed.append(fits.box)
            body.append(#"<text class="\#(point.result.strategy == .router ? "name strong" : "name")" x="\#(f(fits.x))" y="\#(f(fits.box.minY + 13))" text-anchor="\#(fits.anchor)">\#(name)</text>"#)
            body.append(#"<text class="detail" x="\#(f(fits.x))" y="\#(f(fits.box.minY + 28))" text-anchor="\#(fits.anchor)">\#(detail)</text>"#)
        }
        body.append(#"<text class="detail" x="\#(f(plot.left))" y="\#(f(height - 12))">\#(escape(caption))</text>"#)

        return """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 \(Int(width)) \(Int(height))" width="\(Int(width))" height="\(Int(height))" font-family="-apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif">
          <title>Answer quality versus cost</title>
          <desc>Share of answers judged good enough against cost per 100 prompts for HybridRouter and fixed strategies. \(report.strategies.map { "\(label($0.strategy)): \(Int(($0.passRate * 100).rounded()))% at $\(String(format: "%.2f", $0.costPer100))" }.joined(separator: "; ")).</desc>
          <style>
            .bg { fill: #ffffff; }
            .grid { stroke: #eaeef2; stroke-width: 1; }
            .tick { fill: #59636e; font-size: 12px; }
            .axis { fill: #1f2328; font-size: 13px; font-weight: 600; }
            .name { fill: #1f2328; font-size: 13px; }
            .strong { font-weight: 700; }
            .detail { fill: #59636e; font-size: 12px; }
            .point { fill: #59636e; }
            .router { fill: #b04e2c; stroke: #ffffff; stroke-width: 2; }
            .oracle { fill: #ffffff; stroke: #007c80; stroke-width: 2; }
            @media (prefers-color-scheme: dark) {
              .bg { fill: #0d1117; }
              .grid { stroke: #21262d; }
              .tick, .detail { fill: #9198a1; }
              .axis, .name { fill: #e6edf3; }
              .point { fill: #9198a1; }
              .router { fill: #e07b56; stroke: #0d1117; }
              .oracle { fill: #0d1117; stroke: #3fd0c8; }
            }
          </style>
          <rect class="bg" x="0" y="0" width="\(Int(width))" height="\(Int(height))"/>
          \(body.joined(separator: "\n  "))
        </svg>

        """
    }

    private static func label(_ strategy: QualityReport.Strategy) -> String {
        switch strategy {
        case .router: "HybridRouter"
        case .alwaysOnDevice: "Always on-device"
        case .alwaysAppleCloud: "Always Apple Cloud"
        case .alwaysClaude: "Always Sonnet"
        case .alwaysClaudeDeep: "Always Opus"
        case .alwaysMuseWonder: "Always Muse Wonder"
        case .randomSameMix: "Random, same mix"
        case .oracle: "Perfect routing"
        }
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
    }
}
