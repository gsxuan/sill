import Foundation
import Darwin
import StreamProtocol

/// 可选 UDP 视频通道（本地融合版新增，不改动上游 TCP 协议）。
///
/// 控制面（hello / windowList / selectSource / input / viewport / ping）继续走 TCP，保证有序可靠；
/// 只有 HEVC 帧和参数集额外走 UDP 数据报。客户端向本端口发一个 4 字节注册包，源地址即被登记。
/// 每帧切成 ≤1200 字节的片，带 magic/frameID/index/count；丢片即丢整帧，等下一个关键帧，
/// 这正是低延迟链路想要的行为（不排队、不重传旧画面）。
///
/// 由环境变量 SILL_UDP_PORT 启用；不设置时这个类完全不参与，行为与上游一致。
final class UDPFanout {
    private static let magic: [UInt8] = [0x53, 0x55, 0x44, 0x31] // "SUD1"
    private static let chunkSize = 1200
    private static let peerTTL: TimeInterval = 20

    private let fd: Int32
    private let queue = DispatchQueue(label: "sill.udp.host", qos: .userInteractive)
    private let lock = NSLock()
    private var peers: [sockaddr_in] = []
    private var lastSeen: [String: Date] = [:]
    private var frameID: UInt32 = 0
    private var started = false

    init?(port: UInt16) {
        let s = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        guard s >= 0 else { return nil }
        fd = s
        var reuse: Int32 = 1
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse,
                              socklen_t(MemoryLayout.size(ofValue: reuse)))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = 0   // INADDR_ANY
        let bound = withUnsafeMutablePointer(to: &addr) { p -> Int32 in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { q in
                Darwin.bind(fd, q, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { Darwin.close(fd); return nil }
        var rcv: Int32 = 2 << 20
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcv,
                              socklen_t(MemoryLayout.size(ofValue: rcv)))
    }

    func start() {
        guard !started else { return }
        started = true
        queue.async { [self] in
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 2048)
            defer { buf.deallocate() }
            while true {
                var from = sockaddr_in()
                var len = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = withUnsafeMutablePointer(to: &from) { p -> Int in
                    p.withMemoryRebound(to: sockaddr.self, capacity: 1) { q in
                        Darwin.recvfrom(fd, buf, 2048, 0, q, &len)
                    }
                }
                guard n >= 4 else { continue }
                let bytes = Array(UnsafeBufferPointer(start: buf, count: n))
                guard Array(bytes.prefix(4)) == Self.magic else { continue }
                register(from)
            }
        }
    }

    private func key(_ a: sockaddr_in) -> String {
        "\(a.sin_addr.s_addr):\(a.sin_port)"
    }

    private func register(_ addr: sockaddr_in) {
        let k = key(addr)
        lock.lock(); defer { lock.unlock() }
        let isNew = !peers.contains { key($0) == k }
        lastSeen[k] = Date()
        if isNew {
            peers.append(addr)
            print("UDP 客户端已注册：\(k)")
        }
    }

    /// 把一条完整的 StreamMessage 分片广播给所有注册过的客户端。
    func send(_ message: StreamMessage) {
        guard message.kind == .frame || message.kind == .parameterSets else { return }
        lock.lock()
        frameID &+= 1
        let id = frameID
        let now = Date()
        let targets = peers.filter { lastSeen[key($0)].map { now.timeIntervalSince($0) < Self.peerTTL } ?? false }
        if targets.count != peers.count { peers = targets }
        lock.unlock()
        guard !targets.isEmpty else { return }

        let bytes = [UInt8](message.serialized())
        let count = max(1, (bytes.count + Self.chunkSize - 1) / Self.chunkSize)
        guard count <= Int(UInt16.max) else { return }
        for i in 0..<count {
            let start = i * Self.chunkSize
            let end = min(start + Self.chunkSize, bytes.count)
            var packet = Data(capacity: 12 + (end - start))
            packet.append(contentsOf: Self.magic)
            packet.append(contentsOf: be(id))
            packet.append(contentsOf: be(UInt16(i)))
            packet.append(contentsOf: be(UInt16(count)))
            packet.append(contentsOf: bytes[start..<end])
            for target in targets { send(packet, to: target) }
        }
    }

    private func be<T: FixedWidthInteger>(_ v: T) -> [UInt8] {
        var big = v.bigEndian
        return withUnsafeBytes(of: &big) { Array($0) }
    }

    private func send(_ data: Data, to addr: sockaddr_in) {
        var a = addr
        data.withUnsafeBytes { raw in
            _ = withUnsafeMutablePointer(to: &a) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { q in
                    Darwin.sendto(fd, raw.baseAddress, data.count, 0, q,
                                  socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }
}
