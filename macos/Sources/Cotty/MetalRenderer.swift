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
        let fontSize = Theme.fontSize * scaleFactor
        let font = CTFontCreateWithName(Theme.fontName as CFString, fontSize, nil)
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
        buffer: GapBuffer,
        cursor: Cursor,
        scrollPixelOffset: CGFloat,
        cursorVisible: Bool
    ) {
        guard let drawable = layer.nextDrawable() else { return }

        let drawW = Float(layer.drawableSize.width)
        let drawH = Float(layer.drawableSize.height)
        let scale = Float(layer.contentsScale)
        let pad = Float(Theme.paddingPoints) * scale

        let cellW = Float(atlas.cellWidth)
        let cellH = Float(atlas.cellHeight)

        // Smooth scroll: convert point offset to pixel offset, find first visible line
        let scrollPx = Float(scrollPixelOffset) * scale
        let firstLine = max(0, Int(floor(scrollPx / cellH)))
        let fracPx = scrollPx - Float(firstLine) * cellH  // sub-line pixel offset

        let totalLines = buffer.lineCount()
        let visibleLines = Int(ceil((drawH + fracPx) / cellH)) + 1
        let lastLine = min(firstLine + visibleLines, totalLines)

        // Build cell instances
        var cells: [CellData] = []

        for lineIdx in firstLine..<lastLine {
            let row = lineIdx - firstLine
            let content = buffer.lineAt(lineIdx)
            for (col, ch) in content.utf8.enumerated() {
                let g = atlas.lookup(ch)
                cells.append(CellData(
                    gridX: UInt16(col), gridY: UInt16(row),
                    atlasX: g.atlasX, atlasY: g.atlasY,
                    glyphW: g.width, glyphH: g.height,
                    offX: 0, offY: 0,
                    r: Theme.fgR, g: Theme.fgG, b: Theme.fgB, a: 0xFF
                ))
            }
        }

        // Cursor (beam: narrow solid rect, Monokai orange)
        if cursorVisible && cursor.line >= firstLine && cursor.line < lastLine {
            let row = cursor.line - firstLine
            let solid = atlas.solidInfo
            cells.append(CellData(
                gridX: UInt16(cursor.col), gridY: UInt16(row),
                atlasX: solid.atlasX, atlasY: solid.atlasY,
                glyphW: UInt16(max(2, atlas.cellWidth / 8)),
                glyphH: solid.height,
                offX: 0, offY: 0,
                r: Theme.cursorR, g: Theme.cursorG, b: Theme.cursorB, a: 0xFF
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
            red: Theme.bgR, green: Theme.bgG, blue: Theme.bgB, alpha: 1.0
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
