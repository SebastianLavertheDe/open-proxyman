// 生成 App 图标：蓝色渐变圆角方块 + 白色宇航员头盔（原创绘制）
// 用法: swift Scripts/make_icon.swift  然后自动生成 Resources/AppIcon.icns
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit

let size = 1024
let canvas = CGDataCreate(size)
func CGDataCreate(_ side: Int) -> CGContext {
    let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    return ctx
}

let ctx = canvas

// 背景：透明
ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))

// 圆角方块（macOS 图标网格：824x824 居中，圆角 ~185）
let content = CGRect(x: 100, y: 100, width: 824, height: 824)
let radius: CGFloat = 185
let path = CGPath(roundedRect: content, cornerWidth: radius, cornerHeight: radius, transform: nil)

// 蓝色渐变
ctx.addPath(path)
ctx.clip()
let colors = [
    CGColor(red: 0.24, green: 0.66, blue: 0.98, alpha: 1),
    CGColor(red: 0.06, green: 0.40, blue: 0.85, alpha: 1),
] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 100, y: 924), end: CGPoint(x: 924, y: 100), options: [])

// 内描边高光
ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.35))
ctx.setLineWidth(14)
let inner = content.insetBy(dx: 22, dy: 22)
ctx.addPath(CGPath(roundedRect: inner, cornerWidth: radius - 20, cornerHeight: radius - 20, transform: nil))
ctx.strokePath()

// ---------- 头盔 ----------
let cx: CGFloat = 512

// 底座环
ctx.setFillColor(CGColor(red: 0.92, green: 0.95, blue: 0.99, alpha: 1))
ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: CGColor(red: 0, green: 0.15, blue: 0.4, alpha: 0.45))
ctx.fillEllipse(in: CGRect(x: cx - 250, y: 218, width: 500, height: 120))
ctx.setShadow(offset: .zero, blur: 0, color: nil)

// 头盔主体（白色球壳）
ctx.setFillColor(CGColor(red: 0.97, green: 0.985, blue: 1.0, alpha: 1))
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 24, color: CGColor(red: 0, green: 0.15, blue: 0.4, alpha: 0.35))
ctx.fillEllipse(in: CGRect(x: cx - 240, y: 300, width: 480, height: 470))
ctx.setShadow(offset: .zero, blur: 0, color: nil)

// 左右耳件
ctx.setFillColor(CGColor(red: 0.88, green: 0.92, blue: 0.97, alpha: 1))
ctx.fillEllipse(in: CGRect(x: cx - 282, y: 520, width: 90, height: 120))
ctx.fillEllipse(in: CGRect(x: cx + 192, y: 520, width: 90, height: 120))

// 面罩（深色）
let visorRect = CGRect(x: cx - 175, y: 430, width: 350, height: 300)
ctx.setFillColor(CGColor(red: 0.07, green: 0.13, blue: 0.22, alpha: 1))
ctx.fillEllipse(in: visorRect)

// 面罩渐变高光
ctx.saveGState()
ctx.addPath(CGPath(ellipseIn: visorRect, transform: nil))
ctx.clip()
let visorGrad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                           colors: [
                            CGColor(red: 0.13, green: 0.22, blue: 0.36, alpha: 1),
                            CGColor(red: 0.05, green: 0.09, blue: 0.16, alpha: 1),
                           ] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(visorGrad, start: CGPoint(x: visorRect.minX, y: visorRect.maxY), end: CGPoint(x: visorRect.maxX, y: visorRect.minY), options: [])
// 反光点
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.5))
ctx.fillEllipse(in: CGRect(x: visorRect.minX + 40, y: visorRect.maxY - 90, width: 56, height: 30))
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.25))
ctx.fillEllipse(in: CGRect(x: visorRect.minX + 60, y: visorRect.maxY - 130, width: 26, height: 14))
ctx.restoreGState()

// 头盔顶部高光弧
ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.85))
ctx.setLineWidth(20)
ctx.setLineCap(.round)
ctx.addArc(center: CGPoint(x: cx - 60, y: 640), radius: 170,
           startAngle: .pi * 0.65, endAngle: .pi * 1.05, clockwise: false)
ctx.strokePath()

// ---------- 导出 ----------
let image = ctx.makeImage()!
let outDir = URL(fileURLWithPath: "Resources/icon.iconset", isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func writePNG(_ px: Int, name: String) {
    guard let scaled = image.resized(to: px) else { return }
    let url = outDir.appendingPathComponent(name)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, scaled, nil)
    CGImageDestinationFinalize(dest)
}

// iconset 规范命名：icon_16x16 / icon_16x16@2x / ...
for name in ["icon_16x16", "icon_16x16@2x", "icon_32x32", "icon_32x32@2x", "icon_128x128", "icon_128x128@2x", "icon_256x256", "icon_256x256@2x", "icon_512x512", "icon_512x512@2x"] {
    var base = name.hasSuffix("@2x") ? name.replacingOccurrences(of: "@2x", with: "") : name
    base = base.replacingOccurrences(of: "icon_", with: "").replacingOccurrences(of: "x", with: " ")
    let parts = base.split(separator: " ")
    let px = Int(parts[0])! * (name.contains("@2x") ? 2 : 1)
    writePNG(px, name: name + ".png")
}

extension CGImage {
    func resized(to px: Int) -> CGImage? {
        let w = px, h = px
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .high
        ctx.draw(self, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}

print("图标 PNG 已生成于 Resources/icon.iconset")
