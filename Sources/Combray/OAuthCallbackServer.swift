import Foundation
import Network

/// A one-shot local HTTP server that catches the OAuth redirect (`http://localhost:<port>/callback?
/// code=…&state=…`) so the user never has to copy/paste a code. State is touched only on `queue`.
final class OAuthCallbackServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "combray.oauthcb")
    private var listener: NWListener?
    let port: UInt16

    /// Called (off the main actor) with the captured (code, state).
    var onCode: (@Sendable (String, String) -> Void)?

    init(port: UInt16 = 54545) { self.port = port }

    func start() {
        queue.async {
            guard self.listener == nil else { return }
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            guard let l = try? NWListener(using: params, on: NWEndpoint.Port(rawValue: self.port)!) else { return }
            l.newConnectionHandler = { [weak self] conn in
                guard let self else { return }
                conn.start(queue: self.queue)
                self.receive(conn, Data())
            }
            l.start(queue: self.queue)
            self.listener = l
        }
    }

    func stop() {
        queue.async { self.listener?.cancel(); self.listener = nil }
    }

    private func receive(_ conn: NWConnection, _ buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let sep = buf.range(of: Data("\r\n\r\n".utf8)) {
                let header = String(decoding: buf[buf.startIndex..<sep.lowerBound], as: UTF8.self)
                let firstLine = header.split(separator: "\r\n").first.map(String.init) ?? ""
                let path = firstLine.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                self.handle(path: path, conn: conn)
                return
            }
            if done || error != nil { conn.cancel(); return }
            self.receive(conn, buf)
        }
    }

    private func handle(path: String, conn: NWConnection) {
        var code = "", state = ""
        if let query = path.split(separator: "?", maxSplits: 1).dropFirst().first {
            for pair in query.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                guard kv.count == 2 else { continue }
                let value = String(kv[1]).removingPercentEncoding ?? String(kv[1])
                if kv[0] == "code" { code = value }
                if kv[0] == "state" { state = value }
            }
        }
        let page = """
        <html><head><meta charset=utf-8></head>
        <body style="font-family:-apple-system,system-ui;text-align:center;padding-top:90px;color:#1a1a1a">
        <h2>Signed in to Combray</h2><p>You can close this tab and return to the app.</p></body></html>
        """
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(page.utf8.count)\r\nConnection: close\r\n\r\n\(page)"
        conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in conn.cancel() })
        if !code.isEmpty { onCode?(code, state) }
    }
}
