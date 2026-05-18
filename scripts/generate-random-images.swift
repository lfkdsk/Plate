#!/usr/bin/env swift
//
// Generates a batch of large random JPEG images with unique content
// (different SHA-256 per file) and randomized EXIF capture dates spread over
// the past year. Used to stress-test Plate's import / grid / DB at scale.
//
// Usage:
//   scripts/generate-random-images.swift <output-dir> [count=500] [megapixels=24]
//
// Each image alternates landscape / portrait so the justified grid sees a mix.
// Generation parallelises across cores via `DispatchQueue.concurrentPerform`.

import Foundation
import ImageIO
import CoreGraphics

let args = CommandLine.arguments
guard args.count >= 2 else {
    let exe = (args[0] as NSString).lastPathComponent
    print("Usage: \(exe) <output-dir> [count=500] [megapixels=24]")
    exit(1)
}

let outDir   = args[1]
let count    = args.count > 2 ? (Int(args[2]) ?? 500) : 500
let mp       = args.count > 3 ? (Int(args[3]) ?? 24)  : 24

// Pick canonical landscape dims for the requested megapixel count.
// 24MP ≈ 6000×4000, 100MP ≈ 12240×8160 etc.
let landscapeW = Int((Double(mp) * 1_000_000.0 * 1.5).squareRoot().rounded())
let landscapeH = Int(Double(landscapeW) * 2.0 / 3.0)

try? FileManager.default.createDirectory(at: URL(fileURLWithPath: outDir),
                                          withIntermediateDirectories: true)

let cs = CGColorSpaceCreateDeviceRGB()
let exifDF: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy:MM:dd HH:mm:ss"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
}()

func randomDateInLastYear() -> String {
    let secondsInYear: TimeInterval = 365 * 24 * 3600
    let past = Date().addingTimeInterval(-TimeInterval.random(in: 0...secondsInYear))
    return exifDF.string(from: past)
}

func generateImage(index: Int) {
    let landscape = index % 2 == 0
    let w = landscape ? landscapeW : landscapeH
    let h = landscape ? landscapeH : landscapeW

    guard let ctx = CGContext(
        data: nil,
        width: w,
        height: h,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: cs,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else { return }

    // Background — random low-saturation hue.
    let bg = CGColor(
        red:   CGFloat.random(in: 0.10...0.45),
        green: CGFloat.random(in: 0.10...0.45),
        blue:  CGFloat.random(in: 0.10...0.45),
        alpha: 1.0
    )
    ctx.setFillColor(bg)
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

    // ~40 random rectangles — gives the image enough byte-level entropy that
    // SHA-256 differs reliably, and the JPEG encoder produces a real-photo-
    // sized file rather than near-zero.
    for _ in 0..<40 {
        ctx.setFillColor(CGColor(
            red:   CGFloat.random(in: 0.30...1.0),
            green: CGFloat.random(in: 0.30...1.0),
            blue:  CGFloat.random(in: 0.30...1.0),
            alpha: CGFloat.random(in: 0.35...0.85)
        ))
        let rw = CGFloat.random(in: CGFloat(w) * 0.05 ... CGFloat(w) * 0.35)
        let rh = CGFloat.random(in: CGFloat(h) * 0.05 ... CGFloat(h) * 0.35)
        let x  = CGFloat.random(in: -rw * 0.2 ... CGFloat(w) - rw * 0.8)
        let y  = CGFloat.random(in: -rh * 0.2 ... CGFloat(h) - rh * 0.8)
        ctx.fill(CGRect(x: x, y: y, width: rw, height: rh))
    }

    guard let cgImage = ctx.makeImage() else { return }

    let url = URL(fileURLWithPath: "\(outDir)/IMG_\(String(format: "%05d", index)).JPG")
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL, "public.jpeg" as CFString, 1, nil
    ) else { return }

    let props: [CFString: Any] = [
        kCGImageDestinationLossyCompressionQuality: 0.78,
        kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifDateTimeOriginal: randomDateInLastYear()
        ] as [CFString: Any]
    ]
    CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
    CGImageDestinationFinalize(dest)
}

let start = Date()
print("Generating \(count) images (~\(mp)MP, \(landscapeW)×\(landscapeH) landscape / \(landscapeH)×\(landscapeW) portrait) → \(outDir)")

let printLock = NSLock()
var done = 0
DispatchQueue.concurrentPerform(iterations: count) { i in
    generateImage(index: i + 1)
    printLock.lock()
    done += 1
    if done % 25 == 0 || done == count {
        print(String(format: "  [%4d/%d]", done, count))
    }
    printLock.unlock()
}

let elapsed = Date().timeIntervalSince(start)
print(String(format: "Done — %d images in %.1fs (%.1f img/s)",
             count, elapsed, Double(count) / elapsed))
