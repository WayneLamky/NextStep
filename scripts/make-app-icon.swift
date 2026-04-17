#!/usr/bin/env swift
//
// make-app-icon.swift
//
// 生成 NextStep 占位 App 图标，渲染到 Assets.xcassets/AppIcon.appiconset/
//
// 运行：
//   swift scripts/make-app-icon.swift
//
// 设计：
//   - macOS 风格圆角方形（23% 圆角半径，系统会按 squircle 裁剪）
//   - 琥珀 → 桃色径向渐变（和便利贴的暖色调一致）
//   - 中心绘制三张错位的圆角卡片，象征"并行项目的便利贴"
//   - 最上层卡片上有一道"下一步"勾号，强调产品哲学
//
// 之后用 Developer ID 做正式 1024 像素图标时，直接覆盖 icon_1024x1024.png
// 再重新跑这个脚本即可，或者交给设计稿。

import AppKit
import CoreGraphics
import Foundation

// MARK: - Constants

let outputDir = URL(
    fileURLWithPath: "NextStep/Resources/Assets.xcassets/AppIcon.appiconset",
    isDirectory: true
)

/// macOS AppIcon 要求的 10 个尺寸（点 × scale）。
/// 文件名约定：`icon_<W>x<H>[@2x].png`
let specs: [(name: String, pixel: Int)] = [
    ("icon_16x16.png",          16),
    ("icon_16x16@2x.png",       32),
    ("icon_32x32.png",          32),
    ("icon_32x32@2x.png",       64),
    ("icon_128x128.png",       128),
    ("icon_128x128@2x.png",    256),
    ("icon_256x256.png",       256),
    ("icon_256x256@2x.png",    512),
    ("icon_512x512.png",       512),
    ("icon_512x512@2x.png",   1024),
]

// MARK: - Color helpers

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: r/255, green: g/255, blue: b/255, alpha: a)
}

/// 卡片在画布上的几何，单位=像素。画布是 size×size。
struct CardGeom {
    let rect: CGRect
    let corner: CGFloat
    let fill: CGColor
    let strokeAlpha: CGFloat
}

// MARK: - 渲染

func renderIcon(size: Int) -> Data {
    let S = CGFloat(size)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bytesPerRow = size * 4
    guard let ctx = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("CGContext create failed for size \(size)")
    }

    // 透明背景
    ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))

    // ---- 1. 背景圆角方形 + 径向渐变 ----
    let bgRect = CGRect(x: 0, y: 0, width: S, height: S)
    let bgCorner = S * 0.225   // macOS squircle 近似
    let bgPath = CGPath(
        roundedRect: bgRect,
        cornerWidth: bgCorner,
        cornerHeight: bgCorner,
        transform: nil
    )
    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()

    // 暖色径向渐变：左上偏亮桃 → 右下偏深琥珀
    let gradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            color(255, 214, 170),  // 浅桃
            color(255, 176, 102),  // 琥珀
            color(227, 135,  64),  // 深琥珀
        ] as CFArray,
        locations: [0.0, 0.55, 1.0]
    )!
    ctx.drawRadialGradient(
        gradient,
        startCenter: CGPoint(x: S * 0.30, y: S * 0.72),
        startRadius: 0,
        endCenter:   CGPoint(x: S * 0.60, y: S * 0.30),
        endRadius:   S * 0.95,
        options: [.drawsAfterEndLocation]
    )

    // 内缘轻微暗角，让图标更立体
    ctx.setStrokeColor(color(120, 60, 20, 0.12))
    ctx.setLineWidth(max(S * 0.004, 0.5))
    ctx.addPath(bgPath)
    ctx.strokePath()
    ctx.restoreGState()

    // ---- 2. 三张错位卡片 ----
    // 相对大小：卡片宽 ~58% S，高 ~42% S
    let cardW = S * 0.58
    let cardH = S * 0.42
    let cardCorner = S * 0.08
    let centerX = S * 0.50
    let centerY = S * 0.50

    let cards: [CardGeom] = [
        // 背层（最远，偏斜）
        .init(
            rect: CGRect(
                x: centerX - cardW / 2 - S * 0.06,
                y: centerY - cardH / 2 + S * 0.12,
                width: cardW,
                height: cardH
            ),
            corner: cardCorner,
            fill: color(255, 255, 255, 0.40),
            strokeAlpha: 0.18
        ),
        // 中层
        .init(
            rect: CGRect(
                x: centerX - cardW / 2 + S * 0.02,
                y: centerY - cardH / 2 + S * 0.02,
                width: cardW,
                height: cardH
            ),
            corner: cardCorner,
            fill: color(255, 255, 255, 0.70),
            strokeAlpha: 0.22
        ),
        // 最上层（最清晰，承载 ✓ 符号）
        .init(
            rect: CGRect(
                x: centerX - cardW / 2 + S * 0.06,
                y: centerY - cardH / 2 - S * 0.09,
                width: cardW,
                height: cardH
            ),
            corner: cardCorner,
            fill: color(255, 253, 250, 0.98),
            strokeAlpha: 0.30
        ),
    ]

    for card in cards {
        let path = CGPath(
            roundedRect: card.rect,
            cornerWidth: card.corner,
            cornerHeight: card.corner,
            transform: nil
        )
        // 阴影
        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: 0, height: -S * 0.01),
            blur: S * 0.025,
            color: color(60, 30, 10, 0.28)
        )
        ctx.addPath(path)
        ctx.setFillColor(card.fill)
        ctx.fillPath()
        ctx.restoreGState()

        // 细描边
        ctx.saveGState()
        ctx.setStrokeColor(color(120, 60, 20, card.strokeAlpha))
        ctx.setLineWidth(max(S * 0.003, 0.5))
        ctx.addPath(path)
        ctx.strokePath()
        ctx.restoreGState()
    }

    // ---- 3. 最上层卡片上的 ✓ 勾号 ----
    // 勾号在最上层卡片的水平中线偏下一点
    let topCard = cards[2].rect
    let checkBaseline = topCard.minY + topCard.height * 0.55
    let checkLeft = topCard.minX + topCard.width * 0.22
    let checkMid  = topCard.minX + topCard.width * 0.42
    let checkRight = topCard.minX + topCard.width * 0.78

    let check = CGMutablePath()
    check.move(to: CGPoint(x: checkLeft,  y: checkBaseline))
    check.addLine(to: CGPoint(x: checkMid,   y: checkBaseline - topCard.height * 0.20))
    check.addLine(to: CGPoint(x: checkRight, y: checkBaseline + topCard.height * 0.22))

    ctx.saveGState()
    ctx.setStrokeColor(color(227, 135, 64))
    ctx.setLineWidth(S * 0.035)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.addPath(check)
    ctx.strokePath()
    ctx.restoreGState()

    // ---- 输出 PNG ----
    guard let cgImage = ctx.makeImage() else {
        fatalError("Failed to extract CGImage at size \(size)")
    }
    let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
    guard
        let tiff = nsImage.tiffRepresentation,
        let rep = NSBitmapImageRep(data: tiff),
        let png = rep.representation(using: .png, properties: [:])
    else {
        fatalError("PNG encoding failed at size \(size)")
    }
    return png
}

// MARK: - Main

let fm = FileManager.default
if !fm.fileExists(atPath: outputDir.path) {
    fputs("ERROR: 找不到 \(outputDir.path)。请在仓库根目录运行此脚本。\n", stderr)
    exit(1)
}

print("🎨 生成 NextStep 占位图标 →  \(outputDir.path)")
for spec in specs {
    let data = renderIcon(size: spec.pixel)
    let url = outputDir.appendingPathComponent(spec.name)
    try data.write(to: url, options: [.atomic])
    print("  • \(spec.name)  (\(spec.pixel)×\(spec.pixel), \(data.count) bytes)")
}

// Contents.json 补上 filename 字段
let contentsURL = outputDir.appendingPathComponent("Contents.json")
let contents: [String: Any] = [
    "images": [
        ["idiom": "mac", "scale": "1x", "size": "16x16",   "filename": "icon_16x16.png"],
        ["idiom": "mac", "scale": "2x", "size": "16x16",   "filename": "icon_16x16@2x.png"],
        ["idiom": "mac", "scale": "1x", "size": "32x32",   "filename": "icon_32x32.png"],
        ["idiom": "mac", "scale": "2x", "size": "32x32",   "filename": "icon_32x32@2x.png"],
        ["idiom": "mac", "scale": "1x", "size": "128x128", "filename": "icon_128x128.png"],
        ["idiom": "mac", "scale": "2x", "size": "128x128", "filename": "icon_128x128@2x.png"],
        ["idiom": "mac", "scale": "1x", "size": "256x256", "filename": "icon_256x256.png"],
        ["idiom": "mac", "scale": "2x", "size": "256x256", "filename": "icon_256x256@2x.png"],
        ["idiom": "mac", "scale": "1x", "size": "512x512", "filename": "icon_512x512.png"],
        ["idiom": "mac", "scale": "2x", "size": "512x512", "filename": "icon_512x512@2x.png"],
    ],
    "info": ["author": "xcode", "version": 1],
]
let json = try JSONSerialization.data(
    withJSONObject: contents,
    options: [.prettyPrinted, .sortedKeys]
)
try json.write(to: contentsURL, options: [.atomic])
print("✍️  更新 Contents.json")
print("✅ Done.")
