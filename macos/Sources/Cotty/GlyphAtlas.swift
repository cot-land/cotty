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

/// Rasterizes glyphs into a Metal texture atlas with on-demand Unicode support.
/// Copies Ghostty's per-glyph rendering approach (coretext.zig renderGlyph).
/// Index 0 = solid white cell (cursor/backgrounds).
/// Index 1-95 = ASCII 32-126 (pre-rendered).
/// Index 96+ = Unicode glyphs (rendered on demand).
class GlyphAtlas {
    private(set) var texture: MTLTexture
    let device: MTLDevice
    let font: CTFont
    let cellWidth: Int
    let cellHeight: Int
    private(set) var atlasWidth: Int
    private(set) var atlasHeight: Int
    let ascent: CGFloat
    let descent: CGFloat

    private var glyphs: [UInt32: GlyphInfo] = [:]
    private static let cols = 32
    private var nextSlot: Int = 96
    private var totalSlots: Int

    var solidInfo: GlyphInfo {
        GlyphInfo(atlasX: 0, atlasY: 0, width: UInt16(cellWidth), height: UInt16(cellHeight))
    }

    init(device: MTLDevice, font: CTFont) {
        self.device = device
        self.font = font
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

        // Atlas grid: 32 columns, enough rows for 1024 glyphs initially
        let initialSlots = 1024
        totalSlots = initialSlots
        let rows = (initialSlots + Self.cols - 1) / Self.cols
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

        // Pre-render ASCII glyphs
        for ascii: UInt8 in 32...126 {
            let idx = Int(ascii - 32) + 1
            let col = idx % Self.cols
            let row = idx / Self.cols

            guard let bitmap = Self.renderGlyphBitmap(font: font, codepoint: UInt32(ascii),
                                                       cellWidth: cellWidth, cellHeight: cellHeight,
                                                       descent: descent) else { continue }

            let dstCol = col * cellWidth
            let dstRow = row * cellHeight
            for y in 0..<cellHeight {
                for x in 0..<cellWidth {
                    atlasData[(dstRow + y) * atlasWidth + dstCol + x] = bitmap[y * cellWidth + x]
                }
            }

            glyphs[UInt32(ascii)] = GlyphInfo(
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
    }

    func lookup(_ codepoint: UInt32) -> GlyphInfo {
        if let info = glyphs[codepoint] { return info }
        if codepoint < 32 { return solidInfo }
        return renderAndCache(codepoint)
    }

    private func renderAndCache(_ codepoint: UInt32) -> GlyphInfo {
        guard nextSlot < totalSlots else { return solidInfo }

        // Try primary font first, then fall back to system font for the codepoint
        var bitmap = Self.renderGlyphBitmap(font: font, codepoint: codepoint,
                                            cellWidth: cellWidth, cellHeight: cellHeight,
                                            descent: descent)
        if bitmap == nil {
            if let fallback = Self.fallbackFont(for: codepoint, primaryFont: font) {
                bitmap = Self.renderGlyphBitmap(font: fallback, codepoint: codepoint,
                                                cellWidth: cellWidth, cellHeight: cellHeight,
                                                descent: descent)
            }
        }
        guard let bitmap else {
            glyphs[codepoint] = solidInfo
            return solidInfo
        }

        let col = nextSlot % Self.cols
        let row = nextSlot / Self.cols
        let dstX = col * cellWidth
        let dstY = row * cellHeight
        nextSlot += 1

        // Upload to texture
        bitmap.withUnsafeBytes { ptr in
            texture.replace(
                region: MTLRegion(
                    origin: MTLOrigin(x: dstX, y: dstY, z: 0),
                    size: MTLSize(width: cellWidth, height: cellHeight, depth: 1)
                ),
                mipmapLevel: 0,
                withBytes: ptr.baseAddress!,
                bytesPerRow: cellWidth
            )
        }

        let info = GlyphInfo(
            atlasX: UInt16(dstX),
            atlasY: UInt16(dstY),
            width: UInt16(cellWidth),
            height: UInt16(cellHeight)
        )
        glyphs[codepoint] = info
        return info
    }

    /// Find a fallback font that contains the given codepoint.
    private static func fallbackFont(for codepoint: UInt32, primaryFont: CTFont) -> CTFont? {
        let utf16: [UniChar]
        if codepoint <= 0xFFFF {
            utf16 = [UniChar(codepoint)]
        } else {
            let u = codepoint - 0x10000
            utf16 = [UniChar(0xD800 + (u >> 10)), UniChar(0xDC00 + (u & 0x3FF))]
        }
        let str = NSString(characters: utf16, length: utf16.count)
        let fallback = CTFontCreateForString(primaryFont, str, CFRange(location: 0, length: str.length))
        // Only use if it's actually different from the primary font
        let fallbackName = CTFontCopyPostScriptName(fallback) as String
        let primaryName = CTFontCopyPostScriptName(primaryFont) as String
        if fallbackName == primaryName { return nil }
        return fallback
    }

    /// Render a single glyph into a cellWidth x cellHeight R8 bitmap.
    private static func renderGlyphBitmap(font: CTFont, codepoint: UInt32,
                                           cellWidth: Int, cellHeight: Int,
                                           descent: CGFloat) -> [UInt8]? {
        // Convert codepoint to UTF-16
        var chars: [UniChar]
        if codepoint <= 0xFFFF {
            chars = [UniChar(codepoint)]
        } else {
            let u = codepoint - 0x10000
            chars = [UniChar(0xD800 + (u >> 10)), UniChar(0xDC00 + (u & 0x3FF))]
        }

        var glyphBuf = [CGGlyph](repeating: 0, count: chars.count)
        guard CTFontGetGlyphsForCharacters(font, &chars, &glyphBuf, chars.count) else { return nil }

        guard let ctx = CGContext(
            data: nil,
            width: cellWidth,
            height: cellHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        ctx.setAllowsFontSmoothing(true)
        ctx.setShouldSmoothFonts(false)
        ctx.setAllowsFontSubpixelPositioning(true)
        ctx.setShouldSubpixelPositionFonts(true)

        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        var pos = CGPoint(x: 0, y: descent)
        CTFontDrawGlyphs(font, &glyphBuf, &pos, 1, ctx)

        guard let data = ctx.data else { return nil }
        let bpr = ctx.bytesPerRow
        let ptr = data.bindMemory(to: UInt8.self, capacity: cellHeight * bpr)

        var bitmap = [UInt8](repeating: 0, count: cellWidth * cellHeight)
        for y in 0..<cellHeight {
            for x in 0..<cellWidth {
                bitmap[y * cellWidth + x] = ptr[y * bpr + x * 4]
            }
        }
        return bitmap
    }
}
