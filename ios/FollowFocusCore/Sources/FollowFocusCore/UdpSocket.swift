import Foundation

enum UdpError: Error, CustomStringConvertible {
  case socketFailed(Int32)
  case bindFailed(Int32)
  case badAddress(String)
  case sendFailed(Int32)

  var description: String {
    switch self {
    case .socketFailed(let e): return "UDP socket() 失败 errno=\(e)"
    case .bindFailed(let e): return "UDP bind() 失败 errno=\(e)"
    case .badAddress(let h): return "不是合法的 IPv4 地址：\(h)"
    case .sendFailed(let e): return "UDP sendto() 失败 errno=\(e)"
    }
  }
}

/// 极简 UDP 套接字：绑定通配地址、可发广播、非阻塞收包。
///
/// 用 BSD socket 而不是 Network.framework，是为了和原先 Dart 的行为一致：
/// 内核按目标自己挑出口网卡、能发广播、能收任意源的回复。
///
/// 刻意不绑定具体网卡地址：地址会随 Wi-Fi 切换失效，Apple 也明确不建议去猜本机 IP。
final class UdpSocket {
  private(set) var fd: Int32 = -1
  private(set) var localPort: UInt16 = 0
  private var source: DispatchSourceRead?
  private let queue: DispatchQueue

  /// 收到一个包：字节 + 发件人 IP。
  var onPacket: (([UInt8], String) -> Void)?
  var onError: ((Error) -> Void)?

  init(queue: DispatchQueue = DispatchQueue(label: "ff.udp")) {
    self.queue = queue
  }

  deinit { close() }

  func open() throws {
    close()
    let fd = socket(AF_INET, SOCK_DGRAM, 0)
    guard fd >= 0 else { throw UdpError.socketFailed(errno) }
    self.fd = fd

    // 广播：桌面/模拟器上发现板子用得到；iOS 上开了也不会让广播合法（缺 entitlement）。
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &one, socklen_t(MemoryLayout<Int32>.size))
    // 非阻塞：收包走 poll / read source，绝不因为没数据卡住。
    _ = fcntl(fd, F_SETFL, O_NONBLOCK)

    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = 0  // 交给内核挑一个空闲端口
    addr.sin_addr = in_addr(s_addr: 0)  // INADDR_ANY

    let rc = withUnsafePointer(to: &addr) { p in
      p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard rc == 0 else {
      let e = errno
      close()
      throw UdpError.bindFailed(e)
    }

    var actual = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &actual) { p in
      p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getsockname(fd, $0, &len)
      }
    }
    localPort = UInt16(bigEndian: actual.sin_port)
  }

  /// 开始收包（回调驱动）。发现流程不用它，自己轮询 [tryReceive]。
  func startReceiving() {
    guard source == nil, fd >= 0 else { return }
    let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
    src.setEventHandler { [weak self] in self?.drain() }
    // The source owns this exact descriptor, even after this socket is reopened or released.
    let descriptor = fd
    src.setCancelHandler { Darwin.close(descriptor) }
    source = src
    src.resume()
  }

  /// cancel 处理器负责关 fd，所以只在没装 source 时直接关。
  func close() {
    let descriptor = fd
    fd = -1
    localPort = 0
    if let source {
      source.cancel()
      self.source = nil
    } else if descriptor >= 0 {
      Darwin.close(descriptor)
    }
  }

  func send(_ bytes: [UInt8], to host: String, port: UInt16) throws {
    guard fd >= 0 else { throw UdpError.socketFailed(EBADF) }
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    // 只收数字 IP：设备地址来自回包源地址，板子的 SoftAP 地址也是数字，永远不需要 DNS。
    guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else {
      throw UdpError.badAddress(host)
    }
    let rc = withUnsafePointer(to: &addr) { p in
      p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
        bytes.withUnsafeBufferPointer { bp in
          sendto(
            fd, bp.baseAddress, bp.count, 0, sp,
            socklen_t(MemoryLayout<sockaddr_in>.size))
        }
      }
    }
    guard rc >= 0 else { throw UdpError.sendFailed(errno) }
  }

  /// 取一个已到达的包；没有就返回 nil。非阻塞。
  ///
  /// 连发件人端口一起返回：控制链路只用 IP（端口是固件固定的），但假板子/测试
  /// 要回到发起方的临时端口。
  func tryReceive() -> (bytes: [UInt8], from: String, fromPort: UInt16)? {
    guard fd >= 0 else { return nil }
    var buf = [UInt8](repeating: 0, count: 2048)
    var from = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let n = withUnsafeMutablePointer(to: &from) { fp in
      fp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
        buf.withUnsafeMutableBufferPointer { bp in
          recvfrom(fd, bp.baseAddress, bp.count, 0, sp, &len)
        }
      }
    }
    guard n > 0 else { return nil }
    return (
      Array(buf[0..<n]), Self.ipString(from.sin_addr), UInt16(bigEndian: from.sin_port)
    )
  }

  /// 等可读或超时。发现流程用它代替固定 sleep。
  func waitReadable(timeout: TimeInterval) {
    guard fd >= 0 else { return }
    var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    _ = poll(&p, 1, Int32((timeout * 1000).rounded()))
  }

  private func drain() {
    // Yield to cancellation even if packets arrive continuously.
    for _ in 0..<64 {
      guard let packet = tryReceive() else { break }
      onPacket?(packet.bytes, packet.from)
    }
  }

  private static func ipString(_ addr: in_addr) -> String {
    var a = addr
    var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
    guard inet_ntop(AF_INET, &a, &buf, socklen_t(INET_ADDRSTRLEN)) != nil else {
      return ""
    }
    return String(cString: buf)
  }
}
