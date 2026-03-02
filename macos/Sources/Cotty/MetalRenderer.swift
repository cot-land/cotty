import CCottyCore
import Foundation
import Metal
import QuartzCore
import CoreText
import simd

class MetalRenderer {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let pipelineState: MTLRenderPipelineState
    private(set) var atlas: GlyphAtlas
    private(set) var scaleFactor: CGFloat

    var cellWidthPoints: CGFloat { CGFloat(atlas.cellWidth) / scaleFactor }
    var cellHeightPoints: CGFloat { CGFloat(atlas.cellHeight) / scaleFactor }

    // Must match Metal shader layout exactly (20 bytes)
    struct CellData {
        var gridX: UInt16
        var gridY: UInt16
        var atlasX: UInt16
        var atlasY: UInt16
        var glyphW: UInt16
        var glyphH: UInt16
        var offX: Int16
        var offY: Int16
        var r: UInt8
        var g: UInt8
        var b: UInt8
        var a: UInt8
    }

    struct Uniforms {
        var projection: simd_float4x4
        var cellSize: SIMD2<Float>
        var atlasSize: SIMD2<Float>
        var padding: SIMD2<Float>
    }

    init(device: MTLDevice, scaleFactor: CGFloat = 2.0) {
        self.device = device
        self.scaleFactor = scaleFactor
        self.commandQueue = device.makeCommandQueue()!

        // Create atlas at display resolution using Theme font
        let fontSize = Theme.shared.fontSize * scaleFactor
        let font = CTFontCreateWithName(Theme.shared.fontName as CFString, fontSize, nil)
        self.atlas = GlyphAtlas(device: device, font: font)

        // Compile shaders from source
        let shaderSrc = """
        #include <metal_stdlib>
        using namespace metal;

        struct Uniforms {
            float4x4 projection;
            float2 cellSize;
            float2 atlasSize;
            float2 padding;
        };

        struct Cell {
            packed_ushort2 gridPos;
            packed_ushort2 atlasPos;
            packed_ushort2 glyphSize;
            packed_short2 offset;
            packed_uchar4 color;
        };

        struct VOut {
            float4 position [[position]];
            float2 texCoord;
            float4 color;
        };

        vertex VOut cellVertex(
            uint vid [[vertex_id]],
            uint iid [[instance_id]],
            constant Uniforms& u [[buffer(0)]],
            constant Cell* cells [[buffer(1)]]
        ) {
            float2 corner = float2(vid & 1, (vid >> 1) & 1);
            Cell c = cells[iid];

            float2 origin = u.padding + u.cellSize * float2(ushort2(c.gridPos));
            float2 sz = float2(ushort2(c.glyphSize));
            float2 off = float2(short2(c.offset));
            float2 pos = origin + off + sz * corner;

            VOut out;
            out.position = u.projection * float4(pos, 0.0, 1.0);
            out.texCoord = (float2(ushort2(c.atlasPos)) + sz * corner) / u.atlasSize;
            out.color = float4(uchar4(c.color)) / 255.0;
            return out;
        }

        fragment float4 cellFragment(
            VOut in [[stage_in]],
            texture2d<float> atlas [[texture(0)]]
        ) {
            constexpr sampler s(mag_filter::nearest, min_filter::nearest);
            float a = atlas.sample(s, in.texCoord).r;
            return float4(in.color.rgb * a, in.color.a * a);
        }
        """

        let library = try! device.makeLibrary(source: shaderSrc, options: nil)
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "cellVertex")
        desc.fragmentFunction = library.makeFunction(name: "cellFragment")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        desc.colorAttachments[0].isBlendingEnabled = true
        // Premultiplied alpha blending (shader outputs premultiplied)
        desc.colorAttachments[0].sourceRGBBlendFactor = .one
        desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        desc.colorAttachments[0].sourceAlphaBlendFactor = .one
        desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        self.pipelineState = try! device.makeRenderPipelineState(descriptor: desc)
    }

    /// Recreate the glyph atlas with the current Theme font size.
    func rebuildAtlas() {
        let fontSize = Theme.shared.fontSize * scaleFactor
        let font = CTFontCreateWithName(Theme.shared.fontName as CFString, fontSize, nil)
        atlas = GlyphAtlas(device: device, font: font)
    }

    /// Update the scale factor (e.g. when moving between Retina and non-Retina displays).
    /// Rebuilds the atlas if the scale actually changed.
    func updateScaleFactor(_ newScale: CGFloat) {
        guard newScale != scaleFactor else { return }
        scaleFactor = newScale
        rebuildAtlas()
    }

    func render(
        layer: CAMetalLayer,
        surface: CottySurface,
        scrollPixelOffset: CGFloat,
        cursorVisible: Bool
    ) {
        guard let drawable = layer.nextDrawable() else { return }

        let drawW = Float(layer.drawableSize.width)
        let drawH = Float(layer.drawableSize.height)
        let scale = Float(layer.contentsScale)
        let pad = Float(Theme.shared.paddingPoints) * scale

        let cellW = Float(atlas.cellWidth)
        let cellH = Float(atlas.cellHeight)

        // Smooth scroll: convert point offset to pixel offset, find first visible line
        let scrollPx = Float(scrollPixelOffset) * scale
        let firstLine = max(0, Int(floor(scrollPx / cellH)))
        let fracPx = scrollPx - Float(firstLine) * cellH  // sub-line pixel offset

        let totalLines = surface.lineCount
        let visibleLines = Int(ceil((drawH + fracPx) / cellH)) + 1
        let lastLine = min(firstLine + visibleLines, totalLines)

        // Build cell instances
        var cells: [CellData] = []

        for lineIdx in firstLine..<lastLine {
            let row = lineIdx - firstLine
            let lineLen = surface.lineLength(lineIdx)
            let lineStart = surface.lineStartOffset(lineIdx)
            for col in 0..<lineLen {
                let ch = surface.charAt(lineStart + col)
                let g = atlas.lookup(UInt32(ch))
                cells.append(CellData(
                    gridX: UInt16(col), gridY: UInt16(row),
                    atlasX: g.atlasX, atlasY: g.atlasY,
                    glyphW: g.width, glyphH: g.height,
                    offX: 0, offY: 0,
                    r: Theme.shared.fgR, g: Theme.shared.fgG, b: Theme.shared.fgB, a: 0xFF
                ))
            }
        }

        // Cursor (beam: narrow solid rect, Monokai orange)
        let cursorLine = surface.cursorLine
        let cursorCol = surface.cursorCol
        if cursorVisible && cursorLine >= firstLine && cursorLine < lastLine {
            let row = cursorLine - firstLine
            let solid = atlas.solidInfo
            cells.append(CellData(
                gridX: UInt16(cursorCol), gridY: UInt16(row),
                atlasX: solid.atlasX, atlasY: solid.atlasY,
                glyphW: UInt16(max(2, atlas.cellWidth / 8)),
                glyphH: solid.height,
                offX: 0, offY: 0,
                r: Theme.shared.cursorR, g: Theme.shared.cursorG, b: Theme.shared.cursorB, a: 0xFF
            ))
        }

        // Orthographic projection: top-left origin, drawable pixels
        let proj = simd_float4x4(
            SIMD4<Float>(2.0 / drawW, 0, 0, 0),
            SIMD4<Float>(0, -2.0 / drawH, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(-1, 1, 0, 1)
        )
        var uniforms = Uniforms(
            projection: proj,
            cellSize: SIMD2<Float>(cellW, cellH),
            atlasSize: SIMD2<Float>(Float(atlas.atlasWidth), Float(atlas.atlasHeight)),
            padding: SIMD2<Float>(pad, pad - fracPx)
        )

        // Render pass — Monokai Remastered background
        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = drawable.texture
        passDesc.colorAttachments[0].loadAction = .clear
        passDesc.colorAttachments[0].storeAction = .store
        passDesc.colorAttachments[0].clearColor = MTLClearColor(
            red: Theme.shared.bgR, green: Theme.shared.bgG, blue: Theme.shared.bgB, alpha: Theme.shared.bgOpacity
        )

        let cmdBuf = commandQueue.makeCommandBuffer()!
        let enc = cmdBuf.makeRenderCommandEncoder(descriptor: passDesc)!

        if !cells.isEmpty {
            let cellBuf = device.makeBuffer(
                bytes: cells,
                length: cells.count * MemoryLayout<CellData>.stride,
                options: .storageModeShared
            )!

            enc.setRenderPipelineState(pipelineState)
            enc.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.setVertexBuffer(cellBuf, offset: 0, index: 1)
            enc.setFragmentTexture(atlas.texture, index: 0)

            enc.drawPrimitives(
                type: .triangleStrip,
                vertexStart: 0,
                vertexCount: 4,
                instanceCount: cells.count
            )
        }

        enc.endEncoding()
        cmdBuf.present(drawable)
        cmdBuf.commit()
    }

    func renderTerminal(
        layer: CAMetalLayer,
        surface: CottySurface,
        cursorVisible: Bool,
        cursorShape: Int = 0
    ) {
        guard let drawable = layer.nextDrawable() else { return }

        let drawW = Float(layer.drawableSize.width)
        let drawH = Float(layer.drawableSize.height)
        let scale = Float(layer.contentsScale)
        let pad = Float(Theme.shared.paddingPoints) * scale

        let cellW = Float(atlas.cellWidth)
        let cellH = Float(atlas.cellHeight)

        let rows = surface.terminalRows
        let cols = surface.terminalCols
        let cursorRow = surface.terminalCursorRow
        let cursorCol = surface.terminalCursorCol

        var cells: [CellData] = []

        // Read cells directly from the raw buffer to avoid per-cell FFI overhead.
        // Cell layout: 8 x Int64 (codepoint, fg_type, fg_val, bg_type, bg_val, flags, ul_type, ul_val)
        guard let basePtr = surface.terminalCellsPtr else { return }
        let palettePtr = surface.terminalPalettePtr
        let cellStride = 64 // 8 fields * 8 bytes each
        let solid = atlas.solidInfo

        // Default colors from theme for COLOR_NONE resolution
        let defFgR = Theme.shared.fgR, defFgG = Theme.shared.fgG, defFgB = Theme.shared.fgB
        let defBgR = UInt8(clamping: Int(Theme.shared.bgR * 255.0))
        let defBgG = UInt8(clamping: Int(Theme.shared.bgG * 255.0))
        let defBgB = UInt8(clamping: Int(Theme.shared.bgB * 255.0))

        for row in 0..<rows {
            for col in 0..<cols {
                let offset = (row * cols + col) * cellStride
                let cellPtr = basePtr + offset

                let codepoint = cellPtr.load(fromByteOffset: 0, as: Int64.self)
                let fgType = cellPtr.load(fromByteOffset: 8, as: Int64.self)
                let fgVal = cellPtr.load(fromByteOffset: 16, as: Int64.self)
                let bgType = cellPtr.load(fromByteOffset: 24, as: Int64.self)
                let bgVal = cellPtr.load(fromByteOffset: 32, as: Int64.self)

                let flags = cellPtr.load(fromByteOffset: 40, as: Int64.self)
                let isInverse = flags & 4 != 0
                let isDim = flags & 16 != 0

                // Bold-as-bright is applied in Cot at cell write time (terminal.cot putChar)
                // Resolve FIRST, then swap for inverse (Ghostty: generic.zig:2827-2873)
                var (fgR, fgG, fgB) = resolveColor(fgType, fgVal, palettePtr, defFgR, defFgG, defFgB)
                var (bgR, bgG, bgB) = resolveColor(bgType, bgVal, palettePtr, defBgR, defBgG, defBgB)

                if isInverse {
                    let tmp = (fgR, fgG, fgB)
                    (fgR, fgG, fgB) = (bgR, bgG, bgB)
                    (bgR, bgG, bgB) = tmp
                }

                // DIM: use alpha instead of RGB halving (Ghostty: faint_opacity)
                let fgAlpha: UInt8 = isDim ? 0x80 : 0xFF

                // Background cell — render if explicit bg OR inverse (inverse always needs bg)
                if bgType != 0 || isInverse {
                    cells.append(CellData(
                        gridX: UInt16(col), gridY: UInt16(row),
                        atlasX: solid.atlasX, atlasY: solid.atlasY,
                        glyphW: solid.width, glyphH: solid.height,
                        offX: 0, offY: 0,
                        r: bgR, g: bgG, b: bgB, a: 0xFF
                    ))
                }

                // Selection overlay (between background and foreground)
                if flags & 8 != 0 {
                    cells.append(CellData(
                        gridX: UInt16(col), gridY: UInt16(row),
                        atlasX: solid.atlasX, atlasY: solid.atlasY,
                        glyphW: solid.width, glyphH: solid.height,
                        offX: 0, offY: 0,
                        r: Theme.shared.selR, g: Theme.shared.selG, b: Theme.shared.selB, a: Theme.shared.selA
                    ))
                }

                let isHidden = flags & 256 != 0  // CELL_HIDDEN

                // Foreground glyph (skip if hidden)
                if codepoint >= 32 && !isHidden {
                    let isBold = flags & 1 != 0
                    let isItalic = flags & 32 != 0
                    let g = atlas.lookupStyled(UInt32(codepoint), bold: isBold, italic: isItalic)
                    cells.append(CellData(
                        gridX: UInt16(col), gridY: UInt16(row),
                        atlasX: g.atlasX, atlasY: g.atlasY,
                        glyphW: g.width, glyphH: g.height,
                        offX: 0, offY: 0,
                        r: fgR, g: fgG, b: fgB, a: fgAlpha
                    ))
                }

                // Text decorations: underline, strikethrough, overline
                let hasUnderline = flags & 2 != 0      // CELL_UNDERLINE
                let hasDoubleUL = flags & 1024 != 0     // CELL_DOUBLE_UNDERLINE
                let hasStrike = flags & 64 != 0         // CELL_STRIKETHROUGH
                let hasOverline = flags & 512 != 0      // CELL_OVERLINE

                if hasUnderline || hasDoubleUL || hasStrike || hasOverline {
                    // Decoration color: custom underline color if set, else fg color
                    var decR = fgR, decG = fgG, decB = fgB
                    if flags & 2048 != 0 {  // CELL_CUSTOM_UL_COLOR
                        let ulType = cellPtr.load(fromByteOffset: 48, as: Int64.self)
                        let ulVal = cellPtr.load(fromByteOffset: 56, as: Int64.self)
                        (decR, decG, decB) = resolveColor(ulType, ulVal, palettePtr, fgR, fgG, fgB)
                    }

                    let lineH = UInt16(max(1, atlas.cellHeight / 14))
                    let cellH = Int16(atlas.cellHeight)

                    if hasUnderline {
                        cells.append(CellData(
                            gridX: UInt16(col), gridY: UInt16(row),
                            atlasX: solid.atlasX, atlasY: solid.atlasY,
                            glyphW: solid.width, glyphH: lineH,
                            offX: 0, offY: cellH - Int16(lineH),
                            r: decR, g: decG, b: decB, a: fgAlpha
                        ))
                    }

                    if hasDoubleUL {
                        // Two thin lines near the bottom
                        let gap = max(lineH, 1)
                        cells.append(CellData(
                            gridX: UInt16(col), gridY: UInt16(row),
                            atlasX: solid.atlasX, atlasY: solid.atlasY,
                            glyphW: solid.width, glyphH: lineH,
                            offX: 0, offY: cellH - Int16(lineH),
                            r: decR, g: decG, b: decB, a: fgAlpha
                        ))
                        cells.append(CellData(
                            gridX: UInt16(col), gridY: UInt16(row),
                            atlasX: solid.atlasX, atlasY: solid.atlasY,
                            glyphW: solid.width, glyphH: lineH,
                            offX: 0, offY: cellH - Int16(lineH) - Int16(gap) - Int16(lineH),
                            r: decR, g: decG, b: decB, a: fgAlpha
                        ))
                    }

                    if hasStrike {
                        cells.append(CellData(
                            gridX: UInt16(col), gridY: UInt16(row),
                            atlasX: solid.atlasX, atlasY: solid.atlasY,
                            glyphW: solid.width, glyphH: lineH,
                            offX: 0, offY: cellH / 2,
                            r: decR, g: decG, b: decB, a: fgAlpha
                        ))
                    }

                    if hasOverline {
                        cells.append(CellData(
                            gridX: UInt16(col), gridY: UInt16(row),
                            atlasX: solid.atlasX, atlasY: solid.atlasY,
                            glyphW: solid.width, glyphH: lineH,
                            offX: 0, offY: 0,
                            r: decR, g: decG, b: decB, a: fgAlpha
                        ))
                    }
                }
            }
        }

        // Cursor rendering — shape-aware (block, underline, bar)
        if cursorVisible && cursorRow >= 0 && cursorRow < rows && cursorCol >= 0 && cursorCol < cols {
            let cursorW: UInt16
            let cursorH: UInt16
            let cursorOffY: Int16
            // cursorShape: 0=default(block), 1=blinking block, 2=steady block,
            // 3=blinking underline, 4=steady underline, 5=blinking bar, 6=steady bar
            if cursorShape == 3 || cursorShape == 4 {
                // Underline: full width, thin height at bottom
                cursorW = solid.width
                cursorH = UInt16(max(2, atlas.cellHeight / 8))
                cursorOffY = Int16(atlas.cellHeight) - Int16(cursorH)
            } else if cursorShape == 5 || cursorShape == 6 {
                // Bar: narrow width, full height
                cursorW = UInt16(max(2, atlas.cellWidth / 8))
                cursorH = solid.height
                cursorOffY = 0
            } else {
                // Block (0, 1, 2): full cell
                cursorW = solid.width
                cursorH = solid.height
                cursorOffY = 0
            }
            cells.append(CellData(
                gridX: UInt16(cursorCol), gridY: UInt16(cursorRow),
                atlasX: solid.atlasX, atlasY: solid.atlasY,
                glyphW: cursorW, glyphH: cursorH,
                offX: 0, offY: cursorOffY,
                r: Theme.shared.cursorR, g: Theme.shared.cursorG, b: Theme.shared.cursorB, a: 0x80
            ))
        }

        let proj = simd_float4x4(
            SIMD4<Float>(2.0 / drawW, 0, 0, 0),
            SIMD4<Float>(0, -2.0 / drawH, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(-1, 1, 0, 1)
        )
        var uniforms = Uniforms(
            projection: proj,
            cellSize: SIMD2<Float>(cellW, cellH),
            atlasSize: SIMD2<Float>(Float(atlas.atlasWidth), Float(atlas.atlasHeight)),
            padding: SIMD2<Float>(pad, pad)
        )

        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = drawable.texture
        passDesc.colorAttachments[0].loadAction = .clear
        passDesc.colorAttachments[0].storeAction = .store
        passDesc.colorAttachments[0].clearColor = MTLClearColor(
            red: Theme.shared.bgR, green: Theme.shared.bgG, blue: Theme.shared.bgB, alpha: Theme.shared.bgOpacity
        )

        let cmdBuf = commandQueue.makeCommandBuffer()!
        let enc = cmdBuf.makeRenderCommandEncoder(descriptor: passDesc)!

        if !cells.isEmpty {
            let cellBuf = device.makeBuffer(
                bytes: cells,
                length: cells.count * MemoryLayout<CellData>.stride,
                options: .storageModeShared
            )!

            enc.setRenderPipelineState(pipelineState)
            enc.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.setVertexBuffer(cellBuf, offset: 0, index: 1)
            enc.setFragmentTexture(atlas.texture, index: 0)

            enc.drawPrimitives(
                type: .triangleStrip,
                vertexStart: 0,
                vertexCount: 4,
                instanceCount: cells.count
            )
        }

        enc.endEncoding()
        cmdBuf.present(drawable)
        cmdBuf.commit()
    }

    /// Render the inspector cell grid into its own Metal layer.
    /// Same cell rendering logic as the terminal, but no cursor or selection.
    func renderInspector(
        layer: CAMetalLayer,
        surface: CottySurface
    ) {
        guard let drawable = layer.nextDrawable() else { return }

        let drawW = Float(layer.drawableSize.width)
        let drawH = Float(layer.drawableSize.height)
        let scale = Float(layer.contentsScale)
        let pad = Float(Theme.shared.paddingPoints) * scale

        let cellW = Float(atlas.cellWidth)
        let cellH = Float(atlas.cellHeight)

        // Read inspector grid under terminal lock
        surface.lockTerminal()
        let inspRows = surface.inspectorRows
        let inspCols = surface.inspectorCols
        guard let inspBase = surface.inspectorCellsPtr else {
            surface.unlockTerminal()
            return
        }

        var cells: [CellData] = []
        let solid = atlas.solidInfo
        let inspStride = 64  // 8 fields * 8 bytes

        for row in 0..<inspRows {
            for col in 0..<inspCols {
                let offset = (row * inspCols + col) * inspStride
                let cellPtr = inspBase + offset

                let codepoint = cellPtr.load(fromByteOffset: 0, as: Int64.self)
                let fgType = cellPtr.load(fromByteOffset: 8, as: Int64.self)
                let fgVal = cellPtr.load(fromByteOffset: 16, as: Int64.self)
                let bgType = cellPtr.load(fromByteOffset: 24, as: Int64.self)
                let bgVal = cellPtr.load(fromByteOffset: 32, as: Int64.self)

                // Inspector always uses COLOR_RGB, resolve directly
                let (fgR, fgG, fgB) = resolveColor(fgType, fgVal, nil, 200, 200, 200)
                let (bgR, bgG, bgB) = resolveColor(bgType, bgVal, nil, 0, 0, 0)

                // Background — skip COLOR_NONE
                if bgType != 0 {
                    cells.append(CellData(
                        gridX: UInt16(col), gridY: UInt16(row),
                        atlasX: solid.atlasX, atlasY: solid.atlasY,
                        glyphW: solid.width, glyphH: solid.height,
                        offX: 0, offY: 0,
                        r: bgR, g: bgG, b: bgB, a: 0xFF
                    ))
                }

                // Foreground glyph
                if codepoint >= 32 {
                    let g = atlas.lookup(UInt32(codepoint))
                    cells.append(CellData(
                        gridX: UInt16(col), gridY: UInt16(row),
                        atlasX: g.atlasX, atlasY: g.atlasY,
                        glyphW: g.width, glyphH: g.height,
                        offX: 0, offY: 0,
                        r: fgR, g: fgG, b: fgB, a: 0xFF
                    ))
                }
            }
        }
        surface.unlockTerminal()

        // Orthographic projection
        let proj = simd_float4x4(
            SIMD4<Float>(2.0 / drawW, 0, 0, 0),
            SIMD4<Float>(0, -2.0 / drawH, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(-1, 1, 0, 1)
        )
        var uniforms = Uniforms(
            projection: proj,
            cellSize: SIMD2<Float>(cellW, cellH),
            atlasSize: SIMD2<Float>(Float(atlas.atlasWidth), Float(atlas.atlasHeight)),
            padding: SIMD2<Float>(pad, pad)
        )

        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = drawable.texture
        passDesc.colorAttachments[0].loadAction = .clear
        passDesc.colorAttachments[0].storeAction = .store
        // Dark inspector background
        passDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0.098, green: 0.098, blue: 0.118, alpha: 1.0)

        let cmdBuf = commandQueue.makeCommandBuffer()!
        let enc = cmdBuf.makeRenderCommandEncoder(descriptor: passDesc)!

        if !cells.isEmpty {
            let cellBuf = device.makeBuffer(
                bytes: cells,
                length: cells.count * MemoryLayout<CellData>.stride,
                options: .storageModeShared
            )!

            enc.setRenderPipelineState(pipelineState)
            enc.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.setVertexBuffer(cellBuf, offset: 0, index: 1)
            enc.setFragmentTexture(atlas.texture, index: 0)

            enc.drawPrimitives(
                type: .triangleStrip,
                vertexStart: 0,
                vertexCount: 4,
                instanceCount: cells.count
            )
        }

        enc.endEncoding()
        cmdBuf.present(drawable)
        cmdBuf.commit()
    }

    /// Resolve a semantic color (type + value) to an RGB tuple.
    /// - type 0 (COLOR_NONE): use the provided default color
    /// - type 1 (COLOR_PALETTE): look up palette index (val) → RGB from palette pointer
    /// - type 2 (COLOR_RGB): unpack val as (r << 16 | g << 8 | b)
    private func resolveColor(
        _ type: Int64, _ val: Int64,
        _ palette: UnsafeRawPointer?,
        _ defR: UInt8, _ defG: UInt8, _ defB: UInt8
    ) -> (UInt8, UInt8, UInt8) {
        if type == 0 { return (defR, defG, defB) }  // COLOR_NONE
        if type == 1, let pal = palette {  // COLOR_PALETTE
            let base = Int(val) * 3
            let r = UInt8(clamping: pal.load(fromByteOffset: base * 8, as: Int64.self))
            let g = UInt8(clamping: pal.load(fromByteOffset: (base + 1) * 8, as: Int64.self))
            let b = UInt8(clamping: pal.load(fromByteOffset: (base + 2) * 8, as: Int64.self))
            return (r, g, b)
        }
        // COLOR_RGB (type == 2) or palette without pointer — unpack
        return (UInt8((val >> 16) & 0xFF), UInt8((val >> 8) & 0xFF), UInt8(val & 0xFF))
    }
}
