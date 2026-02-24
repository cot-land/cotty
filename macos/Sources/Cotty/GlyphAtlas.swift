import Metal
import CoreText
import CoreGraphics
import AppKit

struct GlyphInfo {
    var atlasX: UInt16 = 0
    var atlasY: UInt16 = 0
    var width: UInt16 = 0
    var height: UInt16 = 0
}

/// Rasterizes ASCII glyphs into a Metal texture atlas.
/// Copies Ghostty's per-glyph rendering approach (coretext.zig renderGlyph).
/// Index 0 = solid white cell (cursor/backgrounds).
/// Index 1-95 = ASCII 32-126.
class GlyphAtlas {
    let texture: MTLTexture
    let cellWidth: Int
    let cellHeight: Int
    let atlasWidth: Int
    let atlasHeight: Int
    let ascent: CGFloat
    let descent: CGFloat

    private var glyphs: [UInt8: GlyphInfo] = [:]
    private static let cols = 16

    var solidInfo: GlyphInfo {
        GlyphInfo(atlasX: 0, atlasY: 0, width: UInt16(cellWidth), height: UInt16(cellHeight))
    }

    init(device: MTLDevice, font: CTFont) {
        ascent = ceil(CTFontGetAscent(font))
        descent = ceil(CTFontGetDescent(font))
        let leading = ceil(CTFontGetLeading(font))
        cellHeight = Int(ascent + descent + leading)

        // Monospace advance width
        var mGlyph: CGGlyph = 0
        var mAdv = CGSize.zero
        var mCh: UniChar = 0x4D // 'M'
        CTFontGetGlyphsForCharacters(font, &mCh, &mGlyph, 1)
        CTFontGetAdvancesForGlyphs(font, .horizontal, &mGlyph, &mAdv, 1)
        cellWidth = Int(ceil(mAdv.width))

        // Atlas grid: 96 cells (1 solid + 95 ASCII), 16 columns
        let totalCells = 96
        let rows = (totalCells + Self.cols - 1) / Self.cols
        atlasWidth = Self.cols * cellWidth
        atlasHeight = rows * cellHeight

        // Atlas bitmap (top-left origin, R8)
        var atlasData = [UInt8](repeating: 0, count: atlasWidth * atlasHeight)

        // Index 0: solid white cell (top-left corner)
        for y in 0..<cellHeight {
            for x in 0..<cellWidth {
                atlasData[y * atlasWidth + x] = 255
            }
        }

        // Render each ASCII glyph into its own context (Ghostty pattern)
        for ascii: UInt8 in 32...126 {
            let idx = Int(ascii - 32) + 1
            let col = idx % Self.cols
            let row = idx / Self.cols

            var ch = UniChar(ascii)
            var g: CGGlyph = 0
            let found = CTFontGetGlyphsForCharacters(font, &ch, &g, 1)
            guard found else { continue }

            // Per-glyph RGBA context (let CG manage memory)
            guard let ctx = CGContext(
                data: nil,
                width: cellWidth,
                height: cellHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { continue }

            // Match Ghostty's rendering settings
            ctx.setAllowsAntialiasing(true)
            ctx.setShouldAntialias(true)
            ctx.setAllowsFontSmoothing(true)
            ctx.setShouldSmoothFonts(false)
            ctx.setAllowsFontSubpixelPositioning(true)
            ctx.setShouldSubpixelPositionFonts(true)

            // Draw white glyph on transparent black
            ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            // CGContext is bottom-left origin; baseline at y=descent
            var pos = CGPoint(x: 0, y: descent)
            CTFontDrawGlyphs(font, &g, &pos, 1, ctx)

            // Copy R channel to atlas, flipping Y (CG bottom-up → atlas top-down)
            guard let data = ctx.data else { continue }
            let bpr = ctx.bytesPerRow
            let ptr = data.bindMemory(to: UInt8.self, capacity: cellHeight * bpr)

            let dstCol = col * cellWidth
            let dstRow = row * cellHeight
            for y in 0..<cellHeight {
                for x in 0..<cellWidth {
                    let pixel = ptr[y * bpr + x * 4] // R channel, no Y flip (CG nil-data is top-down)
                    atlasData[(dstRow + y) * atlasWidth + dstCol + x] = pixel
                }
            }

            glyphs[ascii] = GlyphInfo(
                atlasX: UInt16(dstCol),
                atlasY: UInt16(dstRow),
                width: UInt16(cellWidth),
                height: UInt16(cellHeight)
            )
        }

        // Create R8 Metal texture
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: atlasWidth,
            height: atlasHeight,
            mipmapped: false
        )
        desc.usage = .shaderRead
        texture = device.makeTexture(descriptor: desc)!
        atlasData.withUnsafeBytes { ptr in
            texture.replace(
                region: MTLRegion(
                    origin: MTLOrigin(x: 0, y: 0, z: 0),
                    size: MTLSize(width: atlasWidth, height: atlasHeight, depth: 1)
                ),
                mipmapLevel: 0,
                withBytes: ptr.baseAddress!,
                bytesPerRow: atlasWidth
            )
        }

        // Debug: save atlas as PNG
        Self.saveAtlasDebug(atlasData, width: atlasWidth, height: atlasHeight)
    }

    func lookup(_ ascii: UInt8) -> GlyphInfo {
        glyphs[ascii] ?? solidInfo
    }

    private static func saveAtlasDebug(_ data: [UInt8], width: Int, height: Int) {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 1,
            hasAlpha: false,
            isPlanar: false,
            colorSpaceName: .deviceWhite,
            bytesPerRow: width,
            bitsPerPixel: 8
        ) else { return }

        guard let bitmapData = rep.bitmapData else { return }
        data.withUnsafeBytes { src in
            memcpy(bitmapData, src.baseAddress!, width * height)
        }

        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: "/tmp/cotty_atlas.png"))
            print("Atlas saved to /tmp/cotty_atlas.png (\(width)x\(height))")
        }
    }
}
