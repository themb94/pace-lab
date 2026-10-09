#if DEBUG
import AppKit

/// Development only: with `-debugTour <folder>` the app walks through its sections in order and saves images
/// of its real window (2560 × 1600 pixels). These make up an intro video. Best combined with
/// `-debugSupportDirectory`, `-projectPath` and `-athleteName` with demo data and `-AppleLanguages "(en)"`.
@MainActor
enum DebugTour {
    static let canvas = CGSize(width: 2560, height: 1600)

    static func run(model: AppModel, window: NSWindow, openSettings: () -> Void, dir: URL) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        window.setFrame(NSRect(x: 100, y: 100, width: 1280, height: 800), display: true)
        // An inactive window is drawn gray; so try several times to bring it to the foreground.
        for attempt in 0..<4 {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .seconds(0.8))
            print("TOUR aktiv: app=\(NSApp.isActive) key=\(window.isKeyWindow) (Versuch \(attempt + 1))")
            if NSApp.isActive && window.isKeyWindow { break }
        }
        try? await Task.sleep(for: .seconds(1))

        var index = 0
        var manifest: [[String: Any]] = []
        func png(_ image: CGImage?) -> Data? {
            image.flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) }
        }
        func save(_ image: CGImage?, _ name: String) {
            guard let data = png(image) else { return }
            index += 1
            let file = String(format: "%02d-%@.png", index, name)
            try? data.write(to: dir.appending(path: file))
            manifest.append(["type": "still", "name": name, "file": file])
        }
        func main(_ name: String, wait: Double = 1.4) async {
            NSApp.activate(); window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .seconds(wait))
            save(DebugSnapshots.captureWindowImage(window).map { fit($0) }, name)
        }
        /// Several images in quick succession while the content slowly scrolls (plays as motion in the video).
        func scrolling(_ name: String, in scroll: NSScrollView?, frames: Int = 28) async {
            guard let scroll else { return }
            let folder = dir.appending(path: "seq-\(name)", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for i in 0..<frames {
                let t = Double(i) / Double(frames - 1), eased = t * t * (3 - 2 * t)
                setScroll(scroll, fraction: eased)
                try? await Task.sleep(for: .milliseconds(45))
                if let data = png(DebugSnapshots.captureWindowImage(window).map { fit($0) }) {
                    try? data.write(to: folder.appending(path: String(format: "%03d.png", i)))
                }
            }
            manifest.append(["type": "sequence", "name": name, "dir": "seq-\(name)", "count": frames])
        }

        model.section = .overview
        await main("overview", wait: 2)

        model.section = .plan
        model.selectedSessionID = nil
        model.showSessionInspector = true
        await main("plan")
        model.selectedSessionID = model.snapshot?.nextSession?.id
        await main("plan-session")

        model.section = .runs
        model.selectedRunID = nil
        await main("runs")
        model.selectedRunID = model.snapshot?.runs.first { ($0.splits?.count ?? 0) > 10 && $0.isAnalyzed }?.id
        await main("run-detail", wait: 1.8)
        let detail = scrollView(in: window.contentView) { $0.convert($0.bounds, to: nil).minX > window.frame.width / 2 }
        await scrolling("run-scroll", in: detail, frames: 24)
        if let detail { setScroll(detail, fraction: 0) }
        model.selectedRunID = model.snapshot?.runs.first { !$0.isAnalyzed }?.id
        try? await Task.sleep(for: .seconds(0.8))
        if let detail = scrollView(in: window.contentView, matching: { $0.convert($0.bounds, to: nil).minX > window.frame.width / 2 }) { setScroll(detail, fraction: 0) }
        await main("run-new")

        model.section = .coach
        try? await Task.sleep(for: .seconds(2))
        let conversation = scrollView(in: window.contentView) { $0.frame.width > 900 }
        if let conversation { setScroll(conversation, fraction: 0) }
        await main("coach", wait: 0.8)
        await scrolling("coach-scroll", in: conversation, frames: 36)

        model.section = .plan
        model.requestPlan(.week, week: model.snapshot.map { $0.focusWeek(on: .now) } ?? 3)
        try? await Task.sleep(for: .seconds(1.6))
        if let sheet = window.attachedSheet, let base = DebugSnapshots.captureWindowImage(window), let overlay = DebugSnapshots.captureWindowImage(sheet) {
            let scale = window.backingScaleFactor
            let origin = CGPoint(x: (sheet.frame.minX - window.frame.minX) * scale, y: (window.frame.maxY - sheet.frame.maxY) * scale)
            save(composite(base: fit(base), overlay: overlay, origin: origin, dim: 0.28), "plan-sheet")
        }
        model.planRequest = nil

        model.section = .history
        await main("history", wait: 2)

        model.section = .overview
        try? await Task.sleep(for: .seconds(1))
        let backdrop = DebugSnapshots.captureWindowImage(window).map { fit($0) }
        for tab in ["general", "runs", "coach"] {
            UserDefaults.standard.set(tab, forKey: "settingsTab")
            openSettings()
            try? await Task.sleep(for: .seconds(tab == "coach" ? 4.5 : 2))
            if let settings = NSApp.windows.first(where: { $0 !== window && $0.isVisible && $0.canBecomeKey && $0.attachedSheet == nil }),
               let overlay = DebugSnapshots.captureWindowImage(settings), let backdrop {
                let origin = CGPoint(x: (canvas.width - CGFloat(overlay.width)) / 2, y: (canvas.height - CGFloat(overlay.height)) / 2)
                save(composite(base: backdrop, overlay: overlay, origin: origin, dim: 0.55), "settings-\(tab)")
                settings.close()
            }
            try? await Task.sleep(for: .seconds(0.8))
        }
        if let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted]) {
            try? data.write(to: dir.appending(path: "manifest.json"))
        }
    }

    /// The largest scrollable area below `root` that satisfies `matching`.
    private static func scrollView(in root: NSView?, matching: (NSScrollView) -> Bool) -> NSScrollView? {
        var best: (NSScrollView, CGFloat)?
        func walk(_ view: NSView) {
            if let scroll = view as? NSScrollView, let document = scroll.documentView, matching(scroll) {
                let extent = document.frame.height - scroll.contentView.bounds.height
                if extent > 40, extent > (best?.1 ?? 0) { best = (scroll, extent) }
            }
            view.subviews.forEach(walk)
        }
        if let root { walk(root) }
        return best?.0
    }

    /// 0 = very top, 1 = very bottom.
    private static func setScroll(_ scroll: NSScrollView, fraction: Double) {
        guard let document = scroll.documentView else { return }
        // The content starts below the toolbar: "very top" is the negative top inset, not 0.
        let top = -scroll.contentInsets.top
        let bottom = document.frame.height - scroll.contentView.bounds.height + scroll.contentInsets.bottom
        let y = document.isFlipped ? top + (bottom - top) * fraction : bottom - (bottom - top) * fraction
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// Scale the image to the fixed size (the window is 1280 × 800 points, i.e. 2560 × 1600 pixels).
    private static func fit(_ image: CGImage) -> CGImage {
        guard image.width != Int(canvas.width) || image.height != Int(canvas.height) else { return image }
        return draw { $0.draw(image, in: CGRect(origin: .zero, size: canvas)) } ?? image
    }

    /// `origin` in pixels from the top left; a darkened background and a shadow like a real sheet/window.
    private static func composite(base: CGImage, overlay: CGImage, origin: CGPoint, dim: CGFloat) -> CGImage? {
        draw { context in
            context.draw(base, in: CGRect(origin: .zero, size: canvas))
            context.setFillColor(CGColor(gray: 0, alpha: dim))
            context.fill(CGRect(origin: .zero, size: canvas))
            context.setShadow(offset: CGSize(width: 0, height: -24), blur: 60, color: CGColor(gray: 0, alpha: 0.55))
            let rect = CGRect(x: origin.x, y: canvas.height - origin.y - CGFloat(overlay.height), width: CGFloat(overlay.width), height: CGFloat(overlay.height))
            context.draw(overlay, in: rect)
        }
    }

    private static func draw(_ body: (CGContext) -> Void) -> CGImage? {
        guard let context = CGContext(data: nil, width: Int(canvas.width), height: Int(canvas.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        body(context)
        return context.makeImage()
    }
}
#endif
