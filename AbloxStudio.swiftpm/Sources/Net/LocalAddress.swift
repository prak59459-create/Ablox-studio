import Foundation

/// This iPad's address on the local network, for an invitation that joins
/// without the list (`JoinTicket`).
enum LocalAddress {

    /// The Wi-Fi address (IPv4), or another active one; nil with none.
    static func current() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }

        var found: [(name: String, address: String)] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = entry.ifa_flags
            guard flags & UInt32(IFF_UP) != 0, flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = host.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            found.append((String(cString: entry.ifa_name), text))
        }
        // en0 is Wi-Fi on an iPad; bridge100 is its own hotspot.
        let preferred = found.first { $0.name == "en0" }
            ?? found.first { $0.name.hasPrefix("en") || $0.name.hasPrefix("bridge") }
        return preferred?.address
    }
}
