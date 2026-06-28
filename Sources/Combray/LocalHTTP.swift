import Foundation
import Network
import Darwin

/// Shared plumbing for the app's tiny local servers (iPhone capture, the web viewer, the OAuth
/// callback): one place that formats HTTP responses, parses query strings, and finds the Wi-Fi
/// address — so the three servers don't each carry their own copy.
enum LocalHTTP {
    /// Sends a complete HTTP/1.1 response and closes the connection.
    static func respond(_ conn: NWConnection, _ status: String, _ type: String, _ body: Data) {
        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    /// Parses the `?a=b&c=d` query out of a request path.
    static func query(_ path: String) -> [String: String] {
        guard let q = path.split(separator: "?", maxSplits: 1).dropFirst().first else { return [:] }
        var out: [String: String] = [:]
        for pair in q.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { out[String(kv[0])] = String(kv[1]) }
        }
        return out
    }

    /// The `Content-Length` declared in a request header block (0 if absent).
    static func contentLength(_ header: String) -> Int {
        for line in header.split(separator: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                return Int(line.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        return 0
    }

    /// The Mac's Wi-Fi (en0) IPv4 address, for building a LAN URL a phone on the same network can reach.
    static func wifiIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            let flags = Int32(cur.pointee.ifa_flags)
            if let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
               (flags & (IFF_UP | IFF_RUNNING)) == (IFF_UP | IFF_RUNNING) {
                let name = String(cString: cur.pointee.ifa_name)
                if name == "en0" {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host,
                                socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                    address = String(cString: host)
                }
            }
            ptr = cur.pointee.ifa_next
        }
        freeifaddrs(ifaddr)
        return address
    }
}
