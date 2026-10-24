import Darwin
import Dispatch
import Foundation
import PDProtocol
import Synchronization

/// A bounded, nonblocking UDP socket bound only to IPv4 loopback. Closing wakes readers and
/// dispatch closes the descriptor after its read handler has stopped (no descriptor reuse race).
public final class RelayLoopbackSocket: @unchecked Sendable {
    public let port: UInt16
    public let packets: AsyncThrowingStream<(data: Data, port: UInt16), any Error>
    private let continuation: AsyncThrowingStream<(data: Data, port: UInt16), any Error>.Continuation
    private let descriptor: Mutex<Int32>
    private let source: any DispatchSourceRead

    public init() throws {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
            Darwin.close(fd)
            throw POSIXError(.EIO)
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else {
            Darwin.close(fd)
            throw POSIXError(.EIO)
        }
        port = UInt16(bigEndian: address.sin_port)
        descriptor = Mutex(fd)
        let stream = AsyncThrowingStream<(data: Data, port: UInt16), any Error>.makeStream(
            bufferingPolicy: .bufferingNewest(256))
        packets = stream.stream
        continuation = stream.continuation
        source = DispatchSource.makeReadSource(
            fileDescriptor: fd, queue: DispatchQueue(label: "com.pocketdesk.relay.udp"))
        source.setCancelHandler { Darwin.close(fd) }
        source.setEventHandler { [weak self] in self?.drain() }
        source.resume()
    }
    deinit { close() }
    public func close() {
        let open = descriptor.withLock { fd in
            let wasOpen = fd >= 0
            fd = -1
            return wasOpen
        }
        if open {
            continuation.finish()
            source.cancel()
        }
    }
    public func send(_ data: Data, to port: UInt16) throws {
        guard !data.isEmpty, data.count <= RelayPacket.maximumPayload else { return }
        try descriptor.withLock { fd in
            guard fd >= 0 else { throw RelayError.closed }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            address.sin_port = port.bigEndian
            let sent = data.withUnsafeBytes { bytes in
                withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            if sent < 0, errno != EAGAIN, errno != ENOBUFS { throw POSIXError(.EIO) }
        }
    }
    private func drain() {
        for _ in 0..<64 {
            let result: (Data, UInt16)? = descriptor.withLock { fd in
                guard fd >= 0 else { return nil }
                var bytes = [UInt8](repeating: 0, count: RelayPacket.maximumPayload + 1)
                var address = sockaddr_in()
                var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                let count = withUnsafeMutablePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(fd, &bytes, bytes.count, 0, $0, &length)
                    }
                }
                guard count > 0, count <= RelayPacket.maximumPayload, address.sin_addr.s_addr == inet_addr("127.0.0.1")
                else { return nil }
                return (Data(bytes.prefix(count)), UInt16(bigEndian: address.sin_port))
            }
            guard let result else { return }
            continuation.yield(result)
        }
    }
}
