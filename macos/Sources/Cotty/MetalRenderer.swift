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
    let atlas: GlyphAtlas
    let scaleFactor: CGFloat

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
            red: Theme.shared.bgR, green: Theme.shared.bgG, blue: Theme.shared.bgB, alpha: 1.0
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
        inspectorActive: Bool = false,
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
        // Cell layout: 8 x Int64 (codepoint, fg_r, fg_g, fg_b, bg_r, bg_g, bg_b, flags)
        guard let basePtr = surface.terminalCellsPtr else { return }
        let cellStride = 64 // 8 fields * 8 bytes each
        let solid = atlas.solidInfo

        for row in 0..<rows {
            for col in 0..<cols {
                let offset = (row * cols + col) * cellStride
                let cellPtr = basePtr + offset

                let codepoint = cellPtr.load(fromByteOffset: 0, as: Int64.self)
                let fg_r = cellPtr.load(fromByteOffset: 8, as: Int64.self)
                let fg_g = cellPtr.load(fromByteOffset: 16, as: Int64.self)
                let fg_b = cellPtr.load(fromByteOffset: 24, as: Int64.self)
                let bg_r = cellPtr.load(fromByteOffset: 32, as: Int64.self)
                let bg_g = cellPtr.load(fromByteOffset: 40, as: Int64.self)
                let bg_b = cellPtr.load(fromByteOffset: 48, as: Int64.self)

                let flags = cellPtr.load(fromByteOffset: 56, as: Int64.self)

                // Apply CELL_INVERSE: swap fg/bg
                var drawFgR = fg_r, drawFgG = fg_g, drawFgB = fg_b
                var drawBgR = bg_r, drawBgG = bg_g, drawBgB = bg_b
                if flags & 4 != 0 {  // CELL_INVERSE
                    drawFgR = bg_r; drawFgG = bg_g; drawFgB = bg_b
                    drawBgR = fg_r; drawBgG = fg_g; drawBgB = fg_b
                }

                // Apply CELL_DIM: halve foreground brightness
                if flags & 16 != 0 {  // CELL_DIM
                    drawFgR = drawFgR / 2
                    drawFgG = drawFgG / 2
                    drawFgB = drawFgB / 2
                }

                // Background cell (skip black)
                if drawBgR != 0 || drawBgG != 0 || drawBgB != 0 {
                    cells.append(CellData(
                        gridX: UInt16(col), gridY: UInt16(row),
                        atlasX: solid.atlasX, atlasY: solid.atlasY,
                        glyphW: solid.width, glyphH: solid.height,
                        offX: 0, offY: 0,
                        r: UInt8(clamping: drawBgR), g: UInt8(clamping: drawBgG),
                        b: UInt8(clamping: drawBgB), a: 0xFF
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

                // Foreground glyph
                if codepoint >= 32 {
                    let g = atlas.lookup(UInt32(codepoint))
                    cells.append(CellData(
                        gridX: UInt16(col), gridY: UInt16(row),
                        atlasX: g.atlasX, atlasY: g.atlasY,
                        glyphW: g.width, glyphH: g.height,
                        offX: 0, offY: 0,
                        r: UInt8(clamping: drawFgR), g: UInt8(clamping: drawFgG),
                        b: UInt8(clamping: drawFgB), a: 0xFF
                    ))
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

        // Inspector overlay — rendered at the bottom of the terminal
        if inspectorActive {
            let inspRows = Int(cotty_inspector_rows())
            let inspCols = Int(cotty_inspector_cols())
            let inspPtr = cotty_inspector_cells_ptr()
            if inspPtr != 0 && inspRows > 0 && inspCols > 0 {
                let inspBase = UnsafeRawPointer(bitPattern: Int(inspPtr))!
                let inspStride = 64  // 8 fields * 8 bytes
                let startRow = max(0, rows - inspRows)

                for ir in 0..<inspRows {
                    let termRow = startRow + ir
                    if termRow >= rows { break }
                    for ic in 0..<min(inspCols, cols) {
                        let offset = (ir * inspCols + ic) * inspStride
                        let cellPtr = inspBase + offset

                        let cp = cellPtr.load(fromByteOffset: 0, as: Int64.self)
                        let i_fg_r = cellPtr.load(fromByteOffset: 8, as: Int64.self)
                        let i_fg_g = cellPtr.load(fromByteOffset: 16, as: Int64.self)
                        let i_fg_b = cellPtr.load(fromByteOffset: 24, as: Int64.self)
                        let i_bg_r = cellPtr.load(fromByteOffset: 32, as: Int64.self)
                        let i_bg_g = cellPtr.load(fromByteOffset: 40, as: Int64.self)
                        let i_bg_b = cellPtr.load(fromByteOffset: 48, as: Int64.self)

                        // Background
                        if i_bg_r != 0 || i_bg_g != 0 || i_bg_b != 0 {
                            cells.append(CellData(
                                gridX: UInt16(ic), gridY: UInt16(termRow),
                                atlasX: solid.atlasX, atlasY: solid.atlasY,
                                glyphW: solid.width, glyphH: solid.height,
                                offX: 0, offY: 0,
                                r: UInt8(clamping: i_bg_r), g: UInt8(clamping: i_bg_g),
                                b: UInt8(clamping: i_bg_b), a: 0xFF
                            ))
                        }

                        // Foreground glyph
                        if cp >= 32 {
                            let g = atlas.lookup(UInt32(cp))
                            cells.append(CellData(
                                gridX: UInt16(ic), gridY: UInt16(termRow),
                                atlasX: g.atlasX, atlasY: g.atlasY,
                                glyphW: g.width, glyphH: g.height,
                                offX: 0, offY: 0,
                                r: UInt8(clamping: i_fg_r), g: UInt8(clamping: i_fg_g),
                                b: UInt8(clamping: i_fg_b), a: 0xFF
                            ))
                        }
                    }
                }
            }
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
            red: Theme.shared.bgR, green: Theme.shared.bgG, blue: Theme.shared.bgB, alpha: 1.0
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
}
