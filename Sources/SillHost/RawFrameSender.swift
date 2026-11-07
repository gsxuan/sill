import Foundation
import CoreVideo
import CoreMedia
import CoreImage
import Accelerate
import StreamProtocol

/// 「极致」模式（SILL_RAW_FRAMES=1）：不经过 VideoToolbox，捕获到的一帧像素原样发给客户端。
///
/// 为什么值得这么做：Intel 被控端的 HEVC 硬件编码器在 3024×1898 上只能吐 25–28 帧/秒，
/// 采集明明跑到了 115 帧——瓶颈全在编码器。跳过编码等于把这块硬件的上限整个拿掉，
/// 代价是每帧 width×height×4 字节（3024×1898 = 22.9 MB）。雷雳 4 网桥实测 0.4 ms、40 Gb/s，
/// 60 fps 需要 11 Gb/s，塞得下；局域网/Wi-Fi 则完全不够，所以这个模式只在直连时开。
///
/// 一帧只做一次内存拷贝：直接往 `Data(bytesNoCopy:)` 自己分配的缓冲里按行拷像素，
/// 拿到 `Data` 就立刻交出去（发送完成后由 deallocator 释放），不做中间态拼接。
/// 行宽（stride）在拷贝时被收紧成 width×4，CVPixelBuffer 的 64 字节对齐填充不上网。
final class RawFrameSender {
    private let picture: LockPolicy.Picture
    private weak var server: StreamServer?
    /// 丢掉 alpha：屏幕像素的 alpha 恒为 255，发它白白多占 25% 带宽。
    /// `SILL_RAW_ALPHA=1` 可以退回 BGRA（调试或将来要透明通道时用）。
    private let stripAlpha: Bool = ProcessInfo.processInfo.environment["SILL_RAW_ALPHA"] != "1"

    /// 只在需要转换（捕获端给的不是 BGRA）时用：GPU 上把 420v 之类转成 BGRA。
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false, .cacheIntermediates: false])
    private var convertPool: CVPixelBufferPool?
    private var warnedFormat: OSType?

    private let lock = NSLock()
    private var nextFrameID: UInt64 = 0
    private(set) var sentFrames = 0
    private(set) var droppedFrames = 0
    private(set) var bytesSent = 0

    init(server: StreamServer, picture: LockPolicy.Picture) {
        self.server = server
        self.picture = picture
    }

    /// 从捕获队列调用（SCK 的 sample handler 队列，串行）。一行一帧，绝不排队：
    /// 这一帧打包完就交出去，下一帧来了再打包新的。
    func send(_ pixelBuffer: CVPixelBuffer) {
        guard let payload = pack(pixelBuffer) else { return }
        lock.lock()
        sentFrames += 1
        bytesSent += payload.count
        lock.unlock()
        server?.broadcastRaw(payload, picture: picture)
    }

    /// CVPixelBuffer → 一条完整的 kind 45 消息（14 字节 StreamMessage 头 + 32 字节 RawFrameHeader
    /// + 像素）。一次分配、一次写入：`Data(bytesNoCopy:)` 交出去之后由发送完成的 deallocator 释放，
    /// 中途不再有第二份 20+ MB 的副本。
    private func pack(_ pb: CVPixelBuffer) -> Data? {
        let width = CVPixelBufferGetWidth(pb)
        let height = CVPixelBufferGetHeight(pb)
        guard width > 0, height > 0, width <= 16384, height <= 16384 else { return nil }
        let bytesPerPixel = stripAlpha ? 3 : 4
        let stride = width * bytesPerPixel
        let format = stripAlpha ? RawFrameHeader.formatBGR8 : RawFrameHeader.formatBGRA8
        let payloadLength = RawFrameHeader.length + stride * height
        let total = StreamMessage.headerLength + payloadLength

        lock.lock()
        nextFrameID &+= 1
        let id = nextFrameID
        lock.unlock()

        let mem = UnsafeMutableRawPointer.allocate(byteCount: total, alignment: 64)
        var handedOff = false
        defer { if !handedOff { mem.deallocate() } }

        // 14 字节流消息头：kind(1) + 时间戳(8, 大端) + keyframe(1) + 载荷长度(4, 大端)。
        // 原始帧每一帧都是完整的画面，所以永远标 keyframe：客户端的等待逻辑据此直接放行。
        mem.storeBytes(of: StreamMessageKind.rawFrame.rawValue, toByteOffset: 0, as: UInt8.self)
        var timestamp = Date().timeIntervalSince1970.bitPattern.bigEndian
        withUnsafeBytes(of: &timestamp) { memcpy(mem + 1, $0.baseAddress!, 8) }
        mem.storeBytes(of: UInt8(1), toByteOffset: 9, as: UInt8.self)
        var length = UInt32(payloadLength).bigEndian
        withUnsafeBytes(of: &length) { memcpy(mem + 10, $0.baseAddress!, 4) }

        var header = Data(capacity: RawFrameHeader.length)
        RawFrameHeader(width: width, height: height, stride: stride, format: format, frameID: id).encoded(into: &header)
        header.withUnsafeBytes { src in
            memcpy(mem + StreamMessage.headerLength, src.baseAddress!, RawFrameHeader.length)
        }
        let dst = mem.advanced(by: StreamMessage.headerLength + RawFrameHeader.length)

        // 源可能是 SCK 直接给的 BGRA，也可能是转换出来的 BGRA：两种情况后面的处理一样。
        let source: CVPixelBuffer
        if CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA, !CVPixelBufferIsPlanar(pb) {
            source = pb
        } else {
            guard let converted = convert(pb, width: width, height: height) else { return nil }
            source = converted
        }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(source) else { return nil }
        let srcStride = CVPixelBufferGetBytesPerRow(source)

        if stripAlpha {
            // Accelerate 的 SIMD 版 BGRA→BGR：23 MB 读 / 17 MB 写一帧，单核也只要 1–2 ms，
            // 换回来的是每帧少发 6 MB（25%）。试过按行切片并行，实测毫无提升——
            // Intel 被控端的瓶颈不在这一步（原本就是 465% CPU、多核在跑），
            // 而在网桥本身约 10.3 Gbps 的上限，所以保持单线程，少一层调度开销。
            var src = vImage_Buffer(data: base, height: vImagePixelCount(height),
                                    width: vImagePixelCount(width), rowBytes: srcStride)
            var out = vImage_Buffer(data: dst, height: vImagePixelCount(height),
                                    width: vImagePixelCount(width), rowBytes: stride)
            guard vImageConvert_BGRA8888toRGB888(&src, &out, vImage_Flags(kvImageNoFlags)) == kvImageNoError else {
                return nil
            }
        } else if srcStride == stride {
            memcpy(dst, base, stride * height)
        } else {
            // 行宽被 64 字节对齐撑开时逐行收紧，填充字节不上网。
            for y in 0..<height {
                memcpy(dst + y * stride, base + y * srcStride, stride)
            }
        }

        handedOff = true
        // 不复制：Data 直接接管这块内存，最后一次引用消失时 free（发送完成后）。
        return Data(bytesNoCopy: mem, count: total, deallocator: .custom { p, _ in p.deallocate() })
    }

    private func convert(_ pb: CVPixelBuffer, width: Int, height: Int) -> CVPixelBuffer? {
        let type = CVPixelBufferGetPixelFormatType(pb)
        if warnedFormat != type {
            warnedFormat = type
            print("Raw: 捕获格式 \(fourCC(type)) 不是 BGRA，正在 GPU 上转换（这条路径更慢）")
        }
        if convertPool == nil {
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                kCVPixelBufferCGImageCompatibilityKey: true,
            ]
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
            convertPool = pool
        }
        var out: CVPixelBuffer?
        guard let pool = convertPool,
              CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess,
              let out else { return nil }
        let image = CIImage(cvPixelBuffer: pb)
        ciContext.render(image, to: out, bounds: CGRect(x: 0, y: 0, width: width, height: height),
                         colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return out
    }

    private func fourCC(_ type: OSType) -> String {
        let bytes = [UInt8((type >> 24) & 0xFF), UInt8((type >> 16) & 0xFF),
                     UInt8((type >> 8) & 0xFF), UInt8(type & 0xFF)]
        let text = String(bytes: bytes, encoding: .ascii) ?? "?"
        return text.trimmingCharacters(in: .whitespaces)
    }
}
