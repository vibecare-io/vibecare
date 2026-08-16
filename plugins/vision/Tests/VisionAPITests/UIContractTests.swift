import Testing
import Foundation
@testable import VisionAPI

// The plugin HTTP contract's two hard rules are properties of the shipped
// HTML, and nothing else in the build checks them: a leading-slash URL or a
// `localStorage` call compiles fine, ships fine, and breaks only once the page
// is actually mounted behind core's proxy alongside another plugin. So they
// are checked here, against the real file, by reading it off disk.
//
// `#filePath` rather than `Bundle.module`: under `swift test` the resource
// bundle belongs to `VisionAPI`, not to this test target, and `Bundle.main` is
// the xctest runner. The source tree is the honest thing to assert about
// anyway — this is a review of what a human wrote, not of what SwiftPM copied.

private func shippedUI() throws -> String {
    let testFile = URL(fileURLWithPath: #filePath)                 // Tests/VisionAPITests/UIContractTests.swift
    let packageRoot = testFile.deletingLastPathComponent()          // Tests/VisionAPITests
        .deletingLastPathComponent()                                // Tests
        .deletingLastPathComponent()                                // plugins/vision
    let html = packageRoot
        .appendingPathComponent("Sources/VisionAPI/ui/index.html")
    return try String(contentsOf: html, encoding: .utf8)
}

/// Every URL the page fetches must be relative. Core reverse-proxies the
/// plugin under a mount point it is never told, so a leading slash escapes the
/// plugin's namespace entirely and lands on core's own routes — which answers
/// with something plausible rather than an error, making this a silent break
/// rather than a loud one.
@Test func everyURLInTheShippedUIIsRelative() throws {
    let html = try shippedUI()
    let forbidden = [
        #"fetch("/"#, #"fetch('/"#,           // absolute fetch target
        #"EventSource("/"#, #"EventSource('/"#,
        #"src="/"#, #"src='/"#,               // absolute <img>/<script> source
        #"href="/"#, #"href='/"#,
        #"= "/"#,                              // an absolute path assigned to .src
        "http://", "https://",                 // and nothing off-host at all
    ]
    for needle in forbidden {
        #expect(html.contains(needle) == false, "ui/index.html must not contain \(needle)")
    }
    // Positive control: the relative forms the page actually uses. Without
    // these, a page that fetched nothing at all would pass the checks above.
    #expect(html.contains(#"getJSON("api/state")"#))
    #expect(html.contains(#"EventSource("api/events")"#))
    #expect(html.contains(#"img.src = "preview.mjpeg""#))
}

/// Every plugin shares one web origin in v1, so there is no such thing as
/// private storage in this page: anything written here is readable and
/// clobberable by every other plugin's tab.
///
/// The search is deliberately blunt — a plain substring over the whole file,
/// with no attempt to tell code from comment. Parsing JavaScript to find out
/// whether an occurrence is "real" is both more work and less safe than
/// banning the spelling outright, so `index.html` documents these APIs in
/// English instead. (This check has already fired once, on that file's own
/// comment.)
@Test func theShippedUIUsesNoBrowserStorage() throws {
    let html = try shippedUI()
    for needle in ["localStorage", "sessionStorage", "document.cookie", "indexedDB"] {
        #expect(html.contains(needle) == false, "ui/index.html must not use \(needle)")
    }
}

/// The overlay reproduces the `<img>`'s aspect-FILL mapping. If either side
/// switches to `contain` — or if the canvas keeps `cover` while the image does
/// not — the overlay slides off the face by exactly the cropped margin, which
/// reads as a landmark bug and is not one.
@Test func theShippedUIMapsTheOverlayWithAspectFill() throws {
    let html = try shippedUI()
    #expect(html.contains("object-fit: cover"))
    #expect(html.contains("object-fit: contain") == false)
    // The mapping itself: dispW/dispH chosen by comparing the view aspect to
    // the frame aspect, then a plain offset+scale with y DOWN.
    #expect(html.contains("viewAspect > fa ? w : h * fa"))
    #expect(html.contains("viewAspect > fa ? w / fa : h"))
    #expect(html.contains("t.ox + x * t.dispW"))
    #expect(html.contains("t.oy + y * t.dispH"))
}

/// The mask is 3072 cells per frame. Drawn as SVG rects that is 3072 DOM
/// nodes per frame, which no browser holds at frame rate — it must be a real
/// canvas, and its bit order must match `MaskDTO`'s (and the proto's)
/// MSB-first, row-major packing.
@Test func theShippedUIDecodesTheMaskOntoACanvasWithTheProtoBitOrder() throws {
    let html = try shippedUI()
    #expect(html.contains("getContext(\"2d\")"))
    #expect(html.contains("0x80 >> (i & 7)"))
    #expect(html.contains("row * mask.cols + col"))
    #expect(html.contains("createElementNS") == false)   // i.e. no SVG overlay
}

/// Vision has no feature toggles: the user turns a feature on in the plugin
/// that owns it. A switch here would be a fourth control plane the demand
/// floor could not gate — the exact thing §5 rejected — and it would appear
/// first as a checkbox in this file.
@Test func theShippedUIOffersNoModelToggles() throws {
    let html = try shippedUI()
    #expect(html.contains(#"type="checkbox""#) == false)
    #expect(html.contains("class=\"switch\"") == false)
    // The one control the tab does have.
    #expect(html.contains(#"id="device-select""#))
}
