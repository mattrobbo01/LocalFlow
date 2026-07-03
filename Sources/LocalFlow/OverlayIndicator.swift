import AppKit

/// Floating status pill shown near the bottom of the screen — Wispr-style
/// live audio bars while recording, a gentle wave while transcribing.
/// Non-activating so focus (and therefore the paste target) never changes.
@MainActor
final class OverlayIndicator {
    enum Mode {
        case listening(handsFree: Bool)
        case processing
        case message(String)
    }

    /// Sampled ~20×/s while listening to drive the bars.
    var levelProvider: (() -> Float)?

    private var panel: NSPanel?
    private var content: NSView?
    private var bars: [NSView] = []
    private var label: NSTextField?
    private var tickTimer: Timer?
    private var levels: [Float]
    private var phase: Double = 0
    private var mode: Mode = .processing

    private static let barCount = 7
    private static let barWidth: CGFloat = 3
    private static let barGap: CGFloat = 3
    private static let pillHeight: CGFloat = 26
    private static let maxBarHeight: CGFloat = 16
    private static let minBarHeight: CGFloat = 3

    init() {
        levels = Array(repeating: 0, count: Self.barCount)
    }

    func show(_ mode: Mode) {
        if panel == nil { buildPanel() }
        guard let panel, let label else { return }
        self.mode = mode

        tickTimer?.invalidate()
        tickTimer = nil

        switch mode {
        case .listening(let handsFree):
            label.isHidden = true
            setBars(hidden: false, color: handsFree ? .systemTeal : .white)
            levels = Array(repeating: 0, count: Self.barCount)
            resize(toWidth: barsWidth)
            startTicking()
        case .processing:
            label.isHidden = true
            setBars(hidden: false, color: .systemOrange)
            resize(toWidth: barsWidth)
            startTicking()
        case .message(let text):
            setBars(hidden: true, color: .white)
            label.stringValue = text
            label.isHidden = false
            label.sizeToFit()
            resize(toWidth: label.frame.width + 28)
            label.frame.origin = NSPoint(x: 14, y: (Self.pillHeight - label.frame.height) / 2)
        }

        position(panel)
        panel.orderFrontRegardless()
    }

    func hide() {
        tickTimer?.invalidate()
        tickTimer = nil
        panel?.orderOut(nil)
    }

    // MARK: - Animation

    private var barsWidth: CGFloat {
        CGFloat(Self.barCount) * Self.barWidth
            + CGFloat(Self.barCount - 1) * Self.barGap + 24
    }

    private func startTicking() {
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        switch mode {
        case .listening:
            // Scroll the level history through the bars, newest on the right.
            levels.removeFirst()
            levels.append(levelProvider?() ?? 0)
            for (index, bar) in bars.enumerated() {
                setHeight(of: bar, fraction: CGFloat(levels[index]))
            }
        case .processing:
            // Idle sine wave while the model thinks.
            phase += 0.25
            for (index, bar) in bars.enumerated() {
                let wave = (sin(phase + Double(index) * 0.9) + 1) / 2
                setHeight(of: bar, fraction: 0.15 + CGFloat(wave) * 0.4)
            }
        case .message:
            break
        }
    }

    private func setHeight(of bar: NSView, fraction: CGFloat) {
        let height = Self.minBarHeight + (Self.maxBarHeight - Self.minBarHeight) * min(max(fraction, 0), 1)
        var frame = bar.frame
        frame.size.height = height
        frame.origin.y = (Self.pillHeight - height) / 2
        bar.frame = frame
    }

    private func setBars(hidden: Bool, color: NSColor) {
        for bar in bars {
            bar.isHidden = hidden
            bar.layer?.backgroundColor = color.withAlphaComponent(0.9).cgColor
        }
    }

    // MARK: - Panel construction

    private func buildPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: barsWidth, height: Self.pillHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false

        // Solid dark pill, Wispr-style — independent of system appearance.
        let content = NSView(
            frame: NSRect(x: 0, y: 0, width: barsWidth, height: Self.pillHeight))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(white: 0.13, alpha: 0.96).cgColor
        content.layer?.cornerRadius = Self.pillHeight / 2
        content.layer?.masksToBounds = true

        bars = (0..<Self.barCount).map { index in
            let x = 12 + CGFloat(index) * (Self.barWidth + Self.barGap)
            let bar = NSView(frame: NSRect(
                x: x, y: (Self.pillHeight - Self.minBarHeight) / 2,
                width: Self.barWidth, height: Self.minBarHeight))
            bar.wantsLayer = true
            bar.layer?.cornerRadius = Self.barWidth / 2
            bar.layer?.backgroundColor = NSColor.white.cgColor
            content.addSubview(bar)
            return bar
        }

        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.isHidden = true
        content.addSubview(label)

        panel.contentView = content
        self.panel = panel
        self.content = content
        self.label = label
    }

    private func resize(toWidth width: CGFloat) {
        guard let panel, let content else { return }
        panel.setContentSize(NSSize(width: width, height: Self.pillHeight))
        content.frame = NSRect(x: 0, y: 0, width: width, height: Self.pillHeight)
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        let origin = NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.minY + 24)
        panel.setFrameOrigin(origin)
    }
}
