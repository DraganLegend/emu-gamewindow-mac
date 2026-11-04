import Darwin
import Foundation
import Metal
import QuartzCore

/// Fast frame path : the Emulator
/// writes RGBA pixels straight into a file mapping we own (`ImageTransport.MMAP`),
/// and Metal copies them on the GPU into a private texture for display. Opt-in
/// with `--fast-path`; the gRPC/CGImage path stays the default and fallback.
final class FrameMapping: @unchecked Sendable {
    static let pageSize = Int(getpagesize())
    let path: String
    let length: Int
    let pointer: UnsafeMutableRawPointer
    private let fd: Int32
    private let device: dev_t
    private let inode: ino_t
    private var removed = false

    /// `file:///…` as the Emulator expects for an mmap handle.
    var handle: String { "file://" + path }

    /// Room for either orientation of a `width`×`height` RGBA display, page-rounded.
    static func regionBytes(width: Int, height: Int) -> Int? {
        guard (1...4096).contains(width), (1...4096).contains(height) else { return nil }
        let side = max(width, height)
        let raw = side * side * 4
        return (raw + pageSize - 1) / pageSize * pageSize
    }

    /// `hw.lcd.width`/`hw.lcd.height` from the AVD config (read-only).
    static func avdDisplay(configText: String) -> (Int, Int)? {
        var width: Int?, height: Int?
        for line in configText.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            if parts[0] == "hw.lcd.width" { width = Int(parts[1]) }
            if parts[0] == "hw.lcd.height" { height = Int(parts[1]) }
        }
        guard let width, let height else { return nil }
        return (width, height)
    }

    /// A new private file (never an existing path or a link), sized and mapped shared.
    init(path: String, length: Int) throws {
        guard length > 0, length % Self.pageSize == 0 else { throw SessionFailure.keyWriteFailed }
        let fd = open(path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw SessionFailure.keyExistsOrInaccessible }
        var info = stat()
        guard fstat(fd, &info) == 0, ftruncate(fd, off_t(length)) == 0,
              let base = mmap(nil, length, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0), base != MAP_FAILED else {
            close(fd); unlink(path); throw SessionFailure.keyWriteFailed
        }
        self.path = path; self.length = length; self.pointer = base; self.fd = fd
        self.device = info.st_dev; self.inode = info.st_ino
    }

    /// Unmap and remove exactly this file (same inode), once.
    func remove() {
        guard !removed else { return }
        removed = true
        munmap(pointer, length); close(fd)
        var info = stat()
        if lstat(path, &info) == 0, info.st_dev == device, info.st_ino == inode { unlink(path) }
    }

    deinit { remove() }

    /// A copy of the current frame (for screenshots); nil if it does not fit.
    func copyFrame(width: Int, height: Int) -> Data? {
        guard width > 0, height > 0, width * height * 4 <= length else { return nil }
        return Data(bytes: pointer, count: width * height * 4)
    }
}

/// GPU side: source buffer (no-copy over the mapping when Metal accepts it,
/// else a shared buffer refreshed by one memcpy per frame) → blit into a
/// private RGBA texture → one quad drawn with the view's rotation/flip.
final class MetalFrameRenderer: @unchecked Sendable {
    enum Mode: String, Sendable { case noCopy = "metal-nocopy", copy = "metal-copy" }

    let device: MTLDevice
    let mode: Mode
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private let source: MTLBuffer
    private let sourcePointer: UnsafeRawPointer
    private let sourceLength: Int
    private var texture: MTLTexture?

    static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct VOut { float4 pos [[position]]; float2 uv; };
    struct Params { uint turns; uint flip; };
    vertex VOut v_main(uint vid [[vertex_id]]) {
        float2 p[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
        VOut o; o.pos = float4(p[vid], 0, 1);
        o.uv = float2((p[vid].x + 1) * 0.5, 1 - (p[vid].y + 1) * 0.5);
        return o;
    }
    fragment float4 f_main(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]],
                           sampler s [[sampler(0)]], constant Params& p [[buffer(0)]]) {
        // Display shows the picture turned `turns` quarter turns clockwise (GameGeometry.turn):
        // sample the picture at turn(display, 4 - turns).
        float2 d = in.uv, q = d;
        uint k = (4 - (p.turns % 4)) % 4;
        if (k == 1) q = float2(1 - d.y, d.x);
        else if (k == 2) q = float2(1 - d.x, 1 - d.y);
        else if (k == 3) q = float2(d.y, 1 - d.x);
        if (p.flip != 0) q.y = 1 - q.y;
        return float4(tex.sample(s, q).rgb, 1);
    }
    """

    /// `pointer`/`length` is the frame source (page-aligned for the no-copy mode).
    init?(pointer: UnsafeMutableRawPointer, length: Int, outputFormat: MTLPixelFormat = .bgra8Unorm,
          device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device, let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.shader, options: nil),
              let vertex = library.makeFunction(name: "v_main"), let fragment = library.makeFunction(name: "f_main") else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex; descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = outputFormat
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear; samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge; samplerDescriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else { return nil }
        let aligned = Int(bitPattern: pointer) % FrameMapping.pageSize == 0 && length % FrameMapping.pageSize == 0
        if aligned, let buffer = device.makeBuffer(bytesNoCopy: pointer, length: length, options: .storageModeShared, deallocator: nil) {
            source = buffer; mode = .noCopy
        } else if let buffer = device.makeBuffer(length: length, options: .storageModeShared) {
            source = buffer; mode = .copy
        } else { return nil }
        self.device = device; self.queue = queue; self.pipeline = pipeline; self.sampler = sampler
        self.sourcePointer = UnsafeRawPointer(pointer); self.sourceLength = length
    }

    /// Nearest-neighbour variant for pixel-exact tests.
    func useNearestSampling() -> MetalFrameRenderer { nearest = true; return self }
    private var nearest = false
    private lazy var nearestSampler: MTLSamplerState? = {
        let d = MTLSamplerDescriptor(); d.minFilter = .nearest; d.magFilter = .nearest
        return device.makeSamplerState(descriptor: d)
    }()

    /// Encodes: refresh source (copy mode), blit into the private texture, draw
    /// into `target` with rotation/flip. Returns the committed command buffer.
    @discardableResult
    func render(width: Int, height: Int, turns: Int, flip: Bool, into target: MTLTexture,
                drawable: MTLDrawable? = nil) -> MTLCommandBuffer? {
        let bytes = width * height * 4
        // A buffer→texture blit has no row-alignment requirement beyond whole pixels.
        guard width > 0, height > 0, bytes <= sourceLength else { return nil }
        if mode == .copy { source.contents().copyMemory(from: sourcePointer, byteCount: bytes) }
        if texture?.width != width || texture?.height != height {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
            d.storageMode = .private; d.usage = [.shaderRead]
            texture = device.makeTexture(descriptor: d)
        }
        guard let texture, let commands = queue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: source, sourceOffset: 0, sourceBytesPerRow: width * 4, sourceBytesPerImage: bytes,
                  sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: texture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let draw = commands.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        var params: (UInt32, UInt32) = (UInt32(((turns % 4) + 4) % 4), flip ? 1 : 0)
        draw.setRenderPipelineState(pipeline)
        draw.setFragmentTexture(texture, index: 0)
        draw.setFragmentSamplerState(nearest ? (nearestSampler ?? sampler) : sampler, index: 0)
        draw.setFragmentBytes(&params, length: MemoryLayout<(UInt32, UInt32)>.size, index: 0)
        draw.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        draw.endEncoding()
        if let drawable { commands.present(drawable) }
        commands.commit()
        return commands
    }
}
