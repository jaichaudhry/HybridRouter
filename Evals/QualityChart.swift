import Foundation
import HybridRouterKit

/// Draws a quality-vs-cost chart (one point per strategy) as an SVG that follows the reader's
/// light or dark theme, in the style of docs/architecture.svg.
enum QualityChart {
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

        // Points, labelled to the right except where that would leave the plot or collide.
        for result in report.strategies {
            let px = x(result.costPer100), py = y(result.passRate)
            let leftLabel = result.strategy == .oracle || px > plot.right - 200
            let (cls, r) = switch result.strategy {
            case .router: ("router", 9.0)
            case .oracle: ("oracle", 6.5)
            default: ("point", 6.5)
            }
            body.append(#"<circle class="\#(cls)" cx="\#(f(px))" cy="\#(f(py))" r="\#(f(r))"/>"#)
            let lx = leftLabel ? px - 14 : px + 14
            let anchor = leftLabel ? "end" : "start"
            let name = label(result.strategy)
            let detail = "\(Int((result.passRate * 100).rounded()))% · $\(String(format: "%.2f", result.costPer100))"
            body.append(#"<text class="\#(result.strategy == .router ? "name strong" : "name")" x="\#(f(lx))" y="\#(f(py - 2))" text-anchor="\#(anchor)">\#(name)</text>"#)
            body.append(#"<text class="detail" x="\#(f(lx))" y="\#(f(py + 13))" text-anchor="\#(anchor)">\#(detail)</text>"#)
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
        case .alwaysClaude: "Always Sonnet"
        case .alwaysClaudeDeep: "Always Opus"
        case .randomSameMix: "Random, same mix"
        case .oracle: "Perfect routing"
        }
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
    }
}
