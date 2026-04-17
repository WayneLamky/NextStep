#!/usr/bin/env swift
//
// apply-icon-from-source.swift
//
// 拿一张 Gemini / Midjourney 出的宽幅或方形原图，裁成 1024×1024 正方形
// (围绕"内容重心"居中)，然后生成 10 张标准 macOS app icon 尺寸写进
// AppIcon.appiconset。
//
// 用法:
//   swift scripts/apply-icon-from-source.swift icon-source.png [centerXFraction] [centerYFraction]
//
// centerXFraction / centerYFraction 是可选的，默认 0.60 / 0.50 —— 也就是
// 围绕源图 60% 宽、50% 高那个点裁正方形。我们这张 sage staircase 的
// staircase 重心在画面右侧，60% 刚好。
//

import AppKit

// MARK: - Config
let iconsetPath = "/Users/claw/Desktop/Mac Weight/NextStep/Resources/Assets.xcassets/AppIcon.appiconset"

// MARK: - Args
let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: apply-icon-from-source.swift <source.png> [cxFrac=0.60] [cyFrac=0.50]")
    exit(1)
}
let sourcePath = args[1]
let cxFrac = args.count > 2 ? (Double(args[2]) ?? 0.60) : 0.60
let cyFrac = args.count > 3 ? (Double(args[3]) ?? 0.50) : 0.50

// MARK: - Load source
guard let src = NSImage(contentsOfFile: sourcePath) else {
    print("❌ 打不开源图: \(sourcePath)")
    exit(1)
}
let srcW = src.size.width
let srcH = src.size.height
print("源图: \(Int(srcW))×\(Int(srcH))")

// MARK: - Crop a centered square
let cropSize = min(srcW, srcH)
let centerX = srcW * CGFloat(cxFrac)
let centerY = srcH * CGFloat(cyFrac)
var cropX = centerX - cropSize / 2
var cropY = centerY - cropSize / 2
// clamp so crop stays inside source
cropX = max(0, min(srcW - cropSize, cropX))
cropY = max(0, min(srcH - cropSize, cropY))
let cropRect = NSRect(x: cropX, y: cropY, width: cropSize, height: cropSize)
print("裁切矩形 (源图坐标): origin=(\(Int(cropX)), \(Int(cropY))), size=\(Int(cropSize))")

// MARK: - Render 1024×1024 base
let base = NSImage(size: NSSize(width: 1024, height: 1024))
base.lockFocus()
NSGraphicsContext.current?.imageInterpolation = .high
src.draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024),
         from: cropRect,
         operation: .copy,
         fraction: 1.0)
base.unlockFocus()

// MARK: - Emit 10 sizes
let sizes: [(filename: String, px: Int)] = [
    ("icon_16x16.png",      16),
    ("icon_16x16@2x.png",   32),
    ("icon_32x32.png",      32),
    ("icon_32x32@2x.png",   64),
    ("icon_128x128.png",    128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png",    256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png",    512),
    ("icon_512x512@2x.png", 1024),
]

for (filename, px) in sizes {
    let resized = NSImage(size: NSSize(width: px, height: px))
    resized.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    base.draw(in: NSRect(x: 0, y: 0, width: px, height: px),
              from: NSRect(x: 0, y: 0, width: 1024, height: 1024),
              operation: .copy,
              fraction: 1.0)
    resized.unlockFocus()

    guard
        let tiff = resized.tiffRepresentation,
        let rep  = NSBitmapImageRep(data: tiff),
        let png  = rep.representation(using: .png, properties: [:])
    else {
        print("❌ encode 失败: \(filename)")
        continue
    }

    let url = URL(fileURLWithPath: iconsetPath + "/" + filename)
    do {
        try png.write(to: url)
        print("✅ \(filename) (\(px)×\(px))")
    } catch {
        print("❌ 写入失败 \(filename): \(error)")
    }
}

print("done.")
