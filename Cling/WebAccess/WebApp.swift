//
//  WebApp.swift
//  Cling
//
//  What makes the File server page installable as an app: the manifest, Home Screen icons, the launch screens an
//  iPhone needs one of for each screen size, and the service worker that shows a page of its own when the Mac is out
//  of reach. The iOS quirks the page works around on the client are in cling-web.js.
//

import AppKit
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - WebApp

enum WebApp {
    struct Device {
        init(_ width: Int, _ height: Int, _ scale: Int) {
            self.width = width
            self.height = height
            self.scale = scale
        }

        let width: Int
        let height: Int
        let scale: Int

    }

    /// Every iPhone and iPad in use, by screen size in points and pixel density. iOS composes no launch screen from the
    /// manifest the way Android does: without an image whose media query matches the device exactly, an app opens on
    /// a blank white page.
    static let devices: [Device] = [
        Device(320, 568, 2), // iPhone SE (1st)
        Device(375, 667, 2), // iPhone 8, SE (2nd and 3rd)
        Device(414, 736, 3), // iPhone 8 Plus
        Device(375, 812, 3), // iPhone X, XS, 11 Pro, 12 mini, 13 mini
        Device(414, 896, 2), // iPhone XR, 11
        Device(414, 896, 3), // iPhone XS Max, 11 Pro Max
        Device(390, 844, 3), // iPhone 12, 13, 14, 16e
        Device(428, 926, 3), // iPhone 12 Pro Max, 13 Pro Max, 14 Plus
        Device(393, 852, 3), // iPhone 14 Pro, 15, 15 Pro, 16
        Device(430, 932, 3), // iPhone 14 Pro Max, 15 Plus, 15 Pro Max, 16 Plus
        Device(402, 874, 3), // iPhone 16 Pro, 17, 17 Pro
        Device(420, 912, 3), // iPhone Air
        Device(440, 956, 3), // iPhone 16 Pro Max, 17 Pro Max
        Device(744, 1133, 2), // iPad mini (6th and 7th)
        Device(768, 1024, 2), // iPad mini (5th), older iPads
        Device(810, 1080, 2), // iPad (7th to 9th)
        Device(820, 1180, 2), // iPad (10th), iPad Air 10.9 and 11
        Device(834, 1112, 2), // iPad Pro 10.5, iPad Air (3rd)
        Device(834, 1194, 2), // iPad Pro 11 (1st to 4th)
        Device(834, 1210, 2), // iPad Pro 11 (M4 and later)
        Device(1024, 1366, 2), // iPad Pro 12.9, iPad Air 13
        Device(1032, 1376, 2), // iPad Pro 13 (M4 and later)
    ]

    /// The page's own background in each appearance, so the launch screen hands over to it without a flash.
    static let lightBackground = "#f5f5f7"
    static let darkBackground = "#000000"

    /// The tags in the page's head that describe it as an app. iOS reads the Home Screen title and icon from these
    /// rather than the manifest, and picks a launch screen by media query.
    static func head(version: String) -> String {
        var tags = [
            #"<meta name="theme-color" media="(prefers-color-scheme: light)" content="\#(lightBackground)">"#,
            #"<meta name="theme-color" media="(prefers-color-scheme: dark)" content="\#(darkBackground)">"#,
            #"<meta name="mobile-web-app-capable" content="yes">"#,
            #"<meta name="apple-mobile-web-app-capable" content="yes">"#,
            #"<meta name="apple-mobile-web-app-title" content="Cling">"#,
            // Not black-translucent: that puts the page under the clock, and the soft band iOS 26 draws over the top
            // of an installed app makes whatever sits there unreadable either way.
            #"<meta name="apple-mobile-web-app-status-bar-style" content="default">"#,
            // With credentials, so the manifest can carry the link that signs the app in (see `manifest`).
            #"<link rel="manifest" href="/manifest.webmanifest?v=\#(version)" crossorigin="use-credentials">"#,
            #"<link rel="apple-touch-icon" href="/apple-touch-icon.png?v=\#(version)">"#,
        ]
        for dark in [false, true] {
            for device in devices {
                for landscape in [false, true] {
                    let (width, height) = splashSize(device, landscape: landscape)
                    let media = "(prefers-color-scheme: \(dark ? "dark" : "light")) and (device-width: \(device.width)px) and (device-height: \(device.height)px) and (-webkit-device-pixel-ratio: \(device.scale)) and (orientation: \(landscape ? "landscape" : "portrait"))"
                    tags.append(#"<link rel="apple-touch-startup-image" media="\#(media)" href="/splash/\#(width)x\#(height)-\#(dark ? "dark" : "light").png?v=\#(version)">"#)
                }
            }
        }
        return tags.joined(separator: "\n")
    }

    /// `startURL` is the pairing link for a browser that already has the key: iOS gives an installed app cookies of
    /// its own, so the app has to sign itself in each time it opens rather than count on Safari's. Its `id` stays put
    /// so a new key doesn't make it a different app.
    static func manifest(name: String, startURL: String, version: String) -> Data {
        let manifest: [String: Any] = [
            "id": "/",
            "name": name,
            "short_name": "Cling",
            "start_url": startURL,
            "scope": "/",
            "display": "standalone",
            "background_color": lightBackground,
            "theme_color": lightBackground,
            "icons": [
                ["src": "/icon-192.png?v=\(version)", "sizes": "192x192", "type": "image/png", "purpose": "any"],
                ["src": "/icon-512.png?v=\(version)", "sizes": "512x512", "type": "image/png", "purpose": "any"],
                ["src": "/icon-maskable-512.png?v=\(version)", "sizes": "512x512", "type": "image/png", "purpose": "maskable"],
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    /// Caches what draws the page, so a Mac out of reach answers with a page saying so instead of the browser's error,
    /// which in an installed app has no way back. Everything else (searches, files, downloads, video with its byte
    /// ranges) goes to the network untouched. Browsers allow a service worker over HTTPS only, so this runs on the
    /// Tailscale name and on this Mac's own 127.0.0.1.
    static func serviceWorker(version: String) -> String {
        """
        const VERSION = "cling-\(version)";
        const SHELL = ["/offline", "/assets/cling-web.css?v=\(version)", "/assets/cling-web.js?v=\(version)", "/assets/htmx.min.js?v=\(version)", "/icon.png"];

        self.addEventListener("install", (event) => {
            event.waitUntil(caches.open(VERSION).then((cache) => cache.addAll(SHELL)).then(() => self.skipWaiting()));
        });

        self.addEventListener("activate", (event) => {
            event.waitUntil(
                caches.keys()
                    .then((keys) => Promise.all(keys.filter((key) => key !== VERSION).map((key) => caches.delete(key))))
                    .then(() => self.clients.claim())
            );
        });

        self.addEventListener("fetch", (event) => {
            const request = event.request;
            if (request.method !== "GET") return;
            const url = new URL(request.url);
            if (url.origin !== self.location.origin) return;
            if (request.mode === "navigate" && (url.pathname === "/" || url.pathname.startsWith("/pair/"))) {
                event.respondWith(fetch(request).catch(() => caches.match("/offline")));
            } else if (url.pathname.startsWith("/assets/")) {
                event.respondWith(caches.match(request).then((hit) => hit || fetch(request)));
            }
        });
        """
    }

    /// The pixel size and appearance a /splash/ name asks for, when it is one of the launch screens `head` links to.
    /// Anything else is refused, so nobody can make the Mac draw images of any size.
    static func splashSpec(_ name: String) -> (width: Int, height: Int, dark: Bool)? {
        let parts = name.split(separator: "-")
        guard parts.count == 2, ["light", "dark"].contains(parts[1]) else { return nil }
        let size = parts[0].split(separator: "x").compactMap { Int($0) }
        guard size.count == 2 else { return nil }
        let known = devices.contains { device in
            [false, true].contains { splashSize(device, landscape: $0) == (size[0], size[1]) }
        }
        return known ? (size[0], size[1], parts[1] == "dark") : nil
    }

    private static func splashSize(_ device: Device, landscape: Bool) -> (Int, Int) {
        let (width, height) = (device.width * device.scale, device.height * device.scale)
        return landscape ? (height, width) : (width, height)
    }
}

// MARK: - WebAppArt

/// Draws the app's icons and launch screens from Cling's icon, once each, off the main thread.
final class WebAppArt: @unchecked Sendable {
    init(icon: CGImage?) {
        source = icon
        cache.totalCostLimit = 48 << 20
    }

    /// The Mac icon as drawn in the Dock: its rounded square with the transparent margin and shadow around it. For
    /// browsers that show an icon as it is, like Chrome's app launcher.
    func icon(size: Int) -> Data? {
        cached("icon-\(size)") { [self] in
            render(width: size, height: size, opaque: false) { context in
                context.draw(self.source!, in: CGRect(x: 0, y: 0, width: size, height: size))
            }
        }
    }

    /// Square and opaque, cut to the rounded square: iPhones and Android round the corners themselves, and fill
    /// transparency with black. The corners take the frame's own colour so their rounding shows no seam.
    func fullBleedIcon(size: Int) -> Data? {
        cached("full-\(size)") { [self] in
            render(width: size, height: size, opaque: true) { context in
                context.setFillColor(Self.frameColor)
                context.fill(CGRect(x: 0, y: 0, width: size, height: size))
                self.drawBody(in: context, rect: CGRect(x: 0, y: 0, width: size, height: size))
            }
        }
    }

    func splash(width: Int, height: Int, dark: Bool) -> Data? {
        cached("splash-\(width)x\(height)-\(dark)") { [self] in
            render(width: width, height: height, opaque: true) { context in
                let background = dark ? CGColor(gray: 0, alpha: 1) : CGColor(srgbRed: 0.961, green: 0.961, blue: 0.969, alpha: 1)
                let foreground = dark ? CGColor(srgbRed: 0.961, green: 0.961, blue: 0.969, alpha: 1) : CGColor(srgbRed: 0.114, green: 0.114, blue: 0.122, alpha: 1)
                context.setFillColor(background)
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))

                let short = CGFloat(min(width, height))
                // A third of the short side on a phone; less on an iPad, where that much looks oversized.
                let side = (short * (short < 1400 ? 0.30 : 0.22)).rounded()
                let fontSize = (short * 0.052).rounded()
                let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, fontSize, nil)
                let title = NSAttributedString(string: "Cling", attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font as Any,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): foreground,
                ])
                let line = CTLineCreateWithAttributedString(title)
                let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
                let gap = (fontSize * 0.7).rounded()

                // Centred as one block, icon over name; Core Graphics counts y from the bottom.
                let block = side + gap + bounds.height
                let iconRect = CGRect(x: ((CGFloat(width) - side) / 2).rounded(), y: ((CGFloat(height) + block) / 2 - side).rounded(), width: side, height: side)
                context.saveGState()
                context.addPath(CGPath(roundedRect: iconRect, cornerWidth: side * 0.2237, cornerHeight: side * 0.2237, transform: nil))
                context.clip()
                context.setFillColor(Self.frameColor)
                context.fill(iconRect)
                self.drawBody(in: context, rect: iconRect)
                context.restoreGState()

                context.textPosition = CGPoint(x: (CGFloat(width) - bounds.width) / 2 - bounds.minX, y: iconRect.minY - gap - bounds.maxY)
                CTLineDraw(line, context)
            }
        }
    }

    /// The frame around the icon's artwork, sampled from its edge.
    private static let frameColor = CGColor(srgbRed: 0.898, green: 0.878, blue: 0.882, alpha: 1)

    private let source: CGImage?
    private let cache = NSCache<NSString, NSData>()

    /// The rounded square of a macOS icon: 824 of its 1024 points, starting 100 in, the rest being margin and shadow.
    private func drawBody(in context: CGContext, rect: CGRect) {
        guard let source else { return }
        let scale = rect.width / 824
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: rect.minX - 100 * scale, y: rect.minY - 100 * scale, width: 1024 * scale, height: 1024 * scale))
    }

    private func cached(_ key: String, _ make: () -> Data?) -> Data? {
        if let hit = cache.object(forKey: key as NSString) {
            return hit as Data
        }
        guard source != nil, let data = make() else { return nil }
        cache.setObject(data as NSData, forKey: key as NSString, cost: data.count)
        return data
    }

    private func render(width: Int, height: Int, opaque: Bool, draw: (CGContext) -> Void) -> Data? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        draw(context)
        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
