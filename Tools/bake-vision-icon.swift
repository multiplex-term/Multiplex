#!/usr/bin/env swift
// Bakes the visionOS circular icon (Assets.xcassets/AppIcon.solidimagestack)
// from the Icon Composer source of truth (AppIcon.icon).
//
//   swift Tools/bake-vision-icon.swift
//
// Icon Composer has no visionOS target, but its circle format (watchOS) is
// the same composition visionOS wants: artwork auto-scaled 0.94x into the
// disc, glass/specular/shadow/translucency baked per icon.json. This script
// renders three variants of the document with Icon Composer's own renderer
// (ictool, inside Icon Composer.app) and unblends them into stack layers:
//
//   Back   = fill-only render, opacified over the fill color
//   Middle = unblend(fill+carrier render  vs  fill render)
//   Front  = unblend(full render          vs  fill+carrier render)
//
// so Back over Middle over Front recomposites pixel-exact to ictool's full
// circle render (verified at the end; re-run after editing AppIcon.icon).
//
// ictool picks the PNG format per content (the glass renders come out
// 16-bit Display P3, the flat fill render 8-bit sRGB), so every input is
// normalized into 16-bit Display P3 and the math stays there (an 8-bit
// sRGB detour would gamut-clip the tally red and band the specular
// gradients — it measurably breaks the recomposite).

// A developer script, run by hand and never linked into a shipping target:
// its inputs are `AppIcon.icon` and Icon Composer's own renderer, both of
// which are either present and well-formed or the bake is meaningless. Trapping
// on the spot with a stack trace is the intended failure mode — recovering
// would only produce a wrong icon quietly.
// swiftlint:disable force_try force_cast

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let size = 1024

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
    exit(1)
}

func run(_ tool: String, _ arguments: [String]) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    let out = Pipe()
    process.standardOutput = out
    process.standardError = out
    try! process.run()
    process.waitUntilExit()
    let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    // ictool prints "{\n\n}" on success; anything longer is a diagnostic
    if process.terminationStatus != 0 || text.count > 8 {
        fail("\(tool) \(arguments.joined(separator: " "))\n\(text)")
    }
}

// MARK: locate repo + ictool

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
let repo = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let iconDocument = repo.appendingPathComponent("AppIcon.icon")
let stack = repo.appendingPathComponent("Assets.xcassets/AppIcon.solidimagestack")
guard FileManager.default.fileExists(atPath: iconDocument.path) else {
    fail("AppIcon.icon not found next to Tools/ — run from the Multiplex repo")
}

let developerDir = { () -> String in
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
    process.arguments = ["-p"]
    let pipe = Pipe()
    process.standardOutput = pipe
    try! process.run()
    process.waitUntilExit()
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)!
        .trimmingCharacters(in: .whitespacesAndNewlines)
}()
// The ictool in Developer/usr/bin is an actool shim without --export-image;
// the real renderer ships inside Icon Composer.app.
let ictoolCandidates = [
    developerDir + "/../Applications/Icon Composer.app/Contents/Executables/ictool",
    "/Applications/Icon Composer.app/Contents/Executables/ictool",
]
guard let ictool = ictoolCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
else { fail("Icon Composer's ictool not found (looked in \(ictoolCandidates))") }

// MARK: render document variants (circle format = watchOS platform)

let debugDir = ProcessInfo.processInfo.environment["BAKE_DEBUG_DIR"]
let work = debugDir.map(URL.init(fileURLWithPath:)) ?? FileManager.default.temporaryDirectory
    .appendingPathComponent("multiplex-icon-bake-\(ProcessInfo.processInfo.globallyUniqueString)")
try? FileManager.default.removeItem(at: work)
try! FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
defer { if debugDir == nil { try? FileManager.default.removeItem(at: work) } }

let document = try! JSONSerialization.jsonObject(
    with: Data(contentsOf: iconDocument.appendingPathComponent("icon.json"))) as! [String: Any]
let groups = document["groups"] as! [[String: Any]]

func variant(_ name: String, keepingGroups keep: (String) -> Bool) -> URL {
    let package = work.appendingPathComponent("\(name).icon")
    try! FileManager.default.copyItem(at: iconDocument, to: package)
    var doc = document
    doc["groups"] = groups.filter { group in
        let layers = group["layers"] as! [[String: Any]]
        return layers.contains { keep($0["name"] as! String) }
    }
    let json = try! JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys])
    try! json.write(to: package.appendingPathComponent("icon.json"))
    return package
}

func render(_ package: URL, to name: String) -> URL {
    let png = work.appendingPathComponent(name)
    run(ictool, [package.path, "--export-image", "--output-file", png.path,
                 "--platform", "watchOS", "--rendition", "Default",
                 "--width", "\(size)", "--height", "\(size)", "--scale", "1"])
    return png
}

print("rendering circle format via \(ictool)")
let bgPNG = render(variant("bg") { _ in false }, to: "bg.png")
let bgCarrierPNG = render(variant("bgcarrier") { $0 != "node" }, to: "bgcarrier.png")
let fullPNG = render(iconDocument, to: "full.png")

// MARK: pixel plumbing — 16-bit, in the renders' own colorspace, premultiplied

typealias Pixels = [Double] // size*size*4, premultiplied RGBA in [0,1]

let workingSpace = CGColorSpace(name: CGColorSpace.displayP3)!

func load(_ url: URL) -> Pixels {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { fail("cannot read \(url.path)") }
    var words = [UInt16](repeating: 0, count: size * size * 4)
    let context = CGContext(
        data: &words, width: size, height: size, bitsPerComponent: 16, bytesPerRow: size * 8,
        space: workingSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    return words.map { Double($0) / 65535.0 }
}

func write(_ pixels: Pixels, to url: URL) {
    var words = [UInt16](repeating: 0, count: size * size * 4)
    for i in 0..<words.count { words[i] = UInt16((pixels[i] * 65535.0).rounded()) }
    let context = CGContext(
        data: &words, width: size, height: size, bitsPerComponent: 16, bytesPerRow: size * 8,
        space: workingSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)!
    let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    guard CGImageDestinationFinalize(destination) else { fail("cannot write \(url.path)") }
}

/// Solves `over = layer ⊕ under` for the smallest layer that recomposites
/// exactly: per pixel the minimal alpha keeping premultiplied channels in
/// gamut, with a small floor so rounding noise doesn't become a haze layer.
func unblend(over: Pixels, under: Pixels) -> Pixels {
    var layer = Pixels(repeating: 0, count: size * size * 4)
    let noise = 0.5 / 255.0
    for p in stride(from: 0, to: layer.count, by: 4) {
        let deltas = (0..<4).map { abs(over[p + $0] - under[p + $0]) }
        if deltas.max()! <= noise { continue }
        var alpha = 0.0
        let underAlpha = under[p + 3], overAlpha = over[p + 3]
        if underAlpha < 1.0 { // outside/rim: alpha equation pins the layer alpha
            alpha = (overAlpha - underAlpha) / (1.0 - underAlpha)
        }
        for c in 0..<3 {
            let u = under[p + c], o = over[p + c]
            if o < u, u > 0 { alpha = max(alpha, (u - o) / u) }          // layer ≥ 0
            if o > u, u < 1 { alpha = max(alpha, (o - u) / (1.0 - u)) }  // layer ≤ alpha
        }
        alpha = min(max(alpha, 0), 1)
        for c in 0..<3 { layer[p + c] = min(max(over[p + c] - under[p + c] * (1.0 - alpha), 0), alpha) }
        layer[p + 3] = alpha
    }
    return layer
}

func composite(_ layer: Pixels, over under: Pixels) -> Pixels {
    var out = Pixels(repeating: 0, count: size * size * 4)
    for p in stride(from: 0, to: out.count, by: 4) {
        let alpha = layer[p + 3]
        for c in 0..<4 { out[p + c] = layer[p + c] + under[p + c] * (1.0 - alpha) }
    }
    return out
}

// MARK: bake

let bg = load(bgPNG), bgCarrier = load(bgCarrierPNG), full = load(fullPNG)

// icon.json fill (extended sRGB), converted into the renders' colorspace —
// only backfills the corners the circle render leaves transparent
let fillJSON = (document["fill"] as! [String: Any])["solid"] as! String
let fillComponents = fillJSON.split(separator: ":")[1].split(separator: ",").map { Double($0)! }
let fillColor = CGColor(
    colorSpace: CGColorSpace(name: CGColorSpace.extendedSRGB)!,
    components: fillComponents.map { CGFloat($0) })!
    .converted(to: workingSpace, intent: .defaultIntent, options: nil)!
var opaqueFill = Pixels(repeating: 1, count: size * size * 4)
for p in stride(from: 0, to: opaqueFill.count, by: 4) {
    for c in 0..<3 { opaqueFill[p + c] = Double(fillColor.components![c]) }
}

let back = composite(bg, over: opaqueFill)             // opaque: corners = flat fill

// Adding a group doesn't just add its shape: the renderer re-lights the
// whole disc and re-rasterizes edges with sub-pixel differences, so a raw
// unblend(full vs fill+carrier) leaks faint carrier-edge tracings into the
// front layer — hairlines that would parallax-ghost above the M on
// visionOS. Confine the front layer to the bead's neighborhood (found from
// its opaque core, so edited geometry keeps working) and fold everything
// else into the middle layer by unblending against "full minus front",
// which keeps the flattened stack pixel-exact for any front mask.
var front = unblend(over: full, under: bgCarrier)
// The bead + its shadow form the one THICK region: opening (erode+dilate
// by 2) kills the hairlines, and the largest connected component of what
// survives is the bead blob, wherever the artwork puts it.
let threshold = 0.2, kernel = 2
var mask = [Bool](repeating: false, count: size * size)
for i in 0..<mask.count { mask[i] = front[i * 4 + 3] > threshold }
func erode(_ input: [Bool]) -> [Bool] {
    var output = [Bool](repeating: false, count: size * size)
    for y in kernel..<(size - kernel) {
        for x in kernel..<(size - kernel) {
            var all = true
            for dy in -kernel...kernel {
                for dx in -kernel...kernel where !input[(y + dy) * size + (x + dx)] { all = false }
            }
            output[y * size + x] = all
        }
    }
    return output
}
func dilate(_ input: [Bool]) -> [Bool] {
    var output = [Bool](repeating: false, count: size * size)
    for y in kernel..<(size - kernel) {
        for x in kernel..<(size - kernel) {
            var any = false
            for dy in -kernel...kernel {
                for dx in -kernel...kernel where input[(y + dy) * size + (x + dx)] { any = true }
            }
            output[y * size + x] = any
        }
    }
    return output
}
let opened = dilate(erode(mask))
var component = [Int](repeating: 0, count: size * size)
var largest = (label: 0, count: 0)
var nextLabel = 1
for start in 0..<component.count where opened[start] && component[start] == 0 {
    var stack = [start], count = 0
    component[start] = nextLabel
    while let i = stack.popLast() {
        count += 1
        let x = i % size, y = i / size
        for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
        where nx >= 0 && nx < size && ny >= 0 && ny < size {
            let n = ny * size + nx
            if opened[n] && component[n] == 0 { component[n] = nextLabel; stack.append(n) }
        }
    }
    if count > largest.count { largest = (nextLabel, count) }
    nextLabel += 1
}
if largest.count > 0 {
    var beadX = 0.0, beadY = 0.0
    for i in 0..<component.count where component[i] == largest.label {
        beadX += Double(i % size); beadY += Double(i / size)
    }
    beadX /= Double(largest.count); beadY /= Double(largest.count)
    var blobRadius = 0.0
    for i in 0..<component.count where component[i] == largest.label {
        blobRadius = max(blobRadius, hypot(Double(i % size) - beadX, Double(i / size) - beadY))
    }
    let keepRadius = blobRadius + 40.0, feather = 20.0
    print(String(format: "front = bead blob at (%.0f,%.0f) r%.0f, kept to r%.0f",
                 beadX, beadY, blobRadius, keepRadius))
    for y in 0..<size {
        for x in 0..<size {
            let radius = hypot(Double(x) - beadX, Double(y) - beadY)
            if radius <= keepRadius { continue }
            let keep = radius >= keepRadius + feather
                ? 0.0 : (keepRadius + feather - radius) / feather
            let p = (y * size + x) * 4
            for c in 0..<4 { front[p + c] *= keep }
        }
    }
}

// full with the front layer lifted off: the middle target
var carrierTarget = bgCarrier
for p in stride(from: 0, to: carrierTarget.count, by: 4) {
    let alpha = front[p + 3]
    if alpha >= 0.995 { continue }               // fully covered: keep the render's value
    for c in 0..<4 {
        carrierTarget[p + c] = min(max((full[p + c] - front[p + c]) / (1.0 - alpha), 0), 1)
    }
}
var middle = unblend(over: carrierTarget, under: bg)

// The renders also re-draw the disc's edge highlight slightly differently
// per variant, which would bake a faint ring into the middle layer — and a
// floating ring parallaxes against the back layer's rim as a double edge.
// The rim belongs to the back layer alone (artwork tops out near r≈460).
let rimStart = 503.0, rimEnd = 506.0
for y in 0..<size {
    for x in 0..<size {
        let radius = hypot(Double(x) - 511.5, Double(y) - 511.5)
        if radius <= rimStart { continue }
        let keep = radius >= rimEnd ? 0.0 : (rimEnd - radius) / (rimEnd - rimStart)
        let p = (y * size + x) * 4
        for c in 0..<4 { middle[p + c] *= keep }
    }
}

let outputs: [(Pixels, String)] = [
    (back, "Back.solidimagestacklayer/Content.imageset/background.png"),
    (middle, "Middle.solidimagestacklayer/Content.imageset/carrier.png"),
    (front, "Front.solidimagestacklayer/Content.imageset/node.png"),
]
for (pixels, relative) in outputs {
    let url = stack.appendingPathComponent(relative)
    write(pixels, to: url)
    print("wrote \(url.path)")
}

// MARK: verify — reload what was written, restack, diff against the full render

let writtenBack = load(stack.appendingPathComponent(outputs[0].1))
let restacked = composite(load(stack.appendingPathComponent(outputs[2].1)),
                          over: composite(load(stack.appendingPathComponent(outputs[1].1)),
                                          over: writtenBack))
let reference = composite(full, over: writtenBack)
var maxInside = 0.0, maxRim = 0.0, meanDiff = 0.0
for y in 0..<size {
    for x in 0..<size {
        let p = (y * size + x) * 4
        var d = 0.0
        for c in 0..<3 { d = max(d, abs(restacked[p + c] - reference[p + c])) }
        meanDiff += d
        if hypot(Double(x) - 511.5, Double(y) - 511.5) <= rimStart {
            maxInside = max(maxInside, d)
        } else {
            maxRim = max(maxRim, d)
        }
    }
}
meanDiff /= Double(size * size)
print(String(format: "restack vs ictool full render: max %.2f/255 inside r%.0f " +
             "(rim ring %.2f/255, under the system crop), mean %.4f/255",
             maxInside * 255, rimStart, maxRim * 255, meanDiff * 255))
if maxInside > 2.5 / 255.0 { fail("restacked layers drifted from the reference render") }
print("ok")

// swiftlint:enable force_try force_cast
