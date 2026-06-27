import Foundation
import Network
import Darwin

/// A tiny local web server. The Mac shows a URL/QR; the iPhone opens it on the same Wi-Fi, takes
/// photos of a letter, and uploads them — they arrive as a new letter. No companion app needed.
///
/// All state is touched only on `queue`, so it's safe to mark @unchecked Sendable.
final class CaptureServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "combray.capture")
    private var listener: NWListener?
    private var batches: [String: [(Int, URL)]] = [:]
    private var statuses: [String: String] = [:]   // batch id -> received|transcribing|saved|done|error
    let port: UInt16 = 8787

    /// Called (off the main actor) when the server URL becomes available or goes away.
    var onURL: (@Sendable (String?) -> Void)?
    /// Called (off the main actor) with a finished batch's id and uploaded image files.
    var onLetter: (@Sendable (String, [URL]) -> Void)?

    /// Updates the status the phone polls for (so the user sees progress without looking at the Mac).
    func setStatus(_ batch: String, _ status: String) {
        queue.async { self.statuses[batch] = status }
    }

    func start() { queue.async { self.startLocked() } }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            self.onURL?(nil)
        }
    }

    private func startLocked() {
        guard listener == nil else { onURL?(currentURL()); return }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            l.newConnectionHandler = { [weak self] conn in
                guard let self else { return }
                conn.start(queue: self.queue)
                self.receive(conn, buffer: Data())
            }
            l.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                if case .ready = state { self.onURL?(self.currentURL()) }
            }
            l.start(queue: queue)
            self.listener = l
        } catch {
            onURL?(nil)
        }
    }

    private func currentURL() -> String? {
        guard let ip = Self.wifiIPAddress() else { return nil }
        return "http://\(ip):\(port)/"
    }

    // MARK: - HTTP

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let sep = buf.range(of: Data("\r\n\r\n".utf8)) {
                let header = String(decoding: buf[buf.startIndex..<sep.lowerBound], as: UTF8.self)
                let length = Self.contentLength(header)
                let bodyStart = sep.upperBound
                let available = buf.distance(from: bodyStart, to: buf.endIndex)
                if available >= length {
                    let body = buf.subdata(in: bodyStart..<(bodyStart + length))
                    self.route(conn, header: header, body: body)
                    return
                }
            }
            if (isComplete || error != nil) && buffer.isEmpty { conn.cancel(); return }
            if error != nil { conn.cancel(); return }
            self.receive(conn, buffer: buf)
        }
    }

    private func route(_ conn: NWConnection, header: String, body: Data) {
        let firstLine = header.split(separator: "\r\n").first.map(String.init) ?? ""
        let parts = firstLine.split(separator: " ")
        let method = parts.first.map(String.init) ?? "GET"
        let path = parts.count > 1 ? String(parts[1]) : "/"
        let q = Self.query(path)

        if method == "GET", path == "/" || path.hasPrefix("/?") {
            respond(conn, "200 OK", "text/html; charset=utf-8", Data(Self.html.utf8))
        } else if method == "POST", path.hasPrefix("/upload") {
            let batch = q["b"] ?? "default"
            let index = Int(q["i"] ?? "0") ?? 0
            saveUpload(batch: batch, index: index, data: body)
            respond(conn, "200 OK", "text/plain", Data("ok".utf8))
        } else if method == "POST", path.hasPrefix("/done") {
            let batch = q["b"] ?? "default"
            let urls = (batches[batch] ?? []).sorted { $0.0 < $1.0 }.map { $0.1 }
            batches[batch] = nil
            statuses[batch] = "received"
            if !urls.isEmpty { onLetter?(batch, urls) }
            respond(conn, "200 OK", "text/plain", Data("done".utf8))
        } else if method == "GET", path.hasPrefix("/status") {
            let batch = q["b"] ?? "default"
            let s = statuses[batch] ?? "none"
            respond(conn, "200 OK", "application/json", Data("{\"status\":\"\(s)\"}".utf8))
        } else {
            respond(conn, "404 Not Found", "text/plain", Data("not found".utf8))
        }
    }

    private func saveUpload(batch: String, index: Int, data: Data) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("combray-upload/\(batch)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(index).jpg")
        if (try? data.write(to: url)) != nil {
            batches[batch, default: []].append((index, url))
        }
    }

    private func respond(_ conn: NWConnection, _ status: String, _ type: String, _ body: Data) {
        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    // MARK: - Helpers

    private static func contentLength(_ header: String) -> Int {
        for line in header.split(separator: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                return Int(line.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        return 0
    }

    private static func query(_ path: String) -> [String: String] {
        guard let q = path.split(separator: "?", maxSplits: 1).dropFirst().first else { return [:] }
        var out: [String: String] = [:]
        for pair in q.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { out[String(kv[0])] = String(kv[1]) }
        }
        return out
    }

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

    static let html = """
    <!doctype html><html><head><meta charset=utf-8>
    <meta name=viewport content="width=device-width,initial-scale=1,maximum-scale=1">
    <title>Combray</title>
    <style>
      body{font-family:-apple-system,system-ui;margin:0;padding:24px;background:#fff;color:#1a1a1a}
      h1{font-size:30px;margin:0 0 4px}
      p{font-size:17px;color:#666;margin:0 0 14px}
      .btn{font-size:21px;font-weight:600;padding:18px;border-radius:16px;border:0;display:block;width:100%;
        box-sizing:border-box;margin:12px 0;text-align:center;background:#cda22c;color:#fff}
      .btn.secondary{background:#fff;color:#9a7a1e;border:2px solid #cda22c}
      #strip{display:flex;overflow-x:auto;gap:12px;padding:6px 0}
      .thumb{position:relative;flex:0 0 auto;width:120px;text-align:center}
      .thumb img{width:120px;height:150px;object-fit:cover;border-radius:12px;border:1px solid #ddd;display:block}
      .thumb .x{position:absolute;top:6px;right:6px;width:28px;height:28px;line-height:26px;border-radius:50%;
        background:rgba(0,0,0,.6);color:#fff;font-size:18px;text-align:center}
      .thumb .lbl{font-size:15px;color:#555;margin-top:6px;font-weight:600}
      #status{font-size:18px;color:#555;text-align:center;margin-top:10px}
    </style></head><body>
    <h1>Combray</h1>
    <p>Photograph each page — they appear below as you go.</p>
    <div id=strip></div>
    <label class=btn for=f>Take / add a photo</label>
    <input id=f type=file accept="image/*" capture="environment" multiple style="display:none">
    <button class=btn id=send>Send to Mac</button>
    <button class="btn secondary" id=clear>Start over</button>
    <div id=status></div>
    <script>
      let files=[];
      const strip=document.getElementById('strip'),send=document.getElementById('send'),status=document.getElementById('status');
      function render(){
        strip.innerHTML='';
        files.forEach((file,i)=>{
          const d=document.createElement('div');d.className='thumb';
          const img=document.createElement('img');img.src=URL.createObjectURL(file);d.appendChild(img);
          const x=document.createElement('div');x.className='x';x.textContent='×';
          x.onclick=()=>{files.splice(i,1);render();};d.appendChild(x);
          const lbl=document.createElement('div');lbl.className='lbl';lbl.textContent='Image '+(i+1);d.appendChild(lbl);
          strip.appendChild(d);
        });
        send.textContent=files.length?('Send '+files.length+' to Mac'):'Send to Mac';
      }
      document.getElementById('f').onchange=e=>{for(const file of e.target.files)files.push(file);e.target.value='';render();};
      document.getElementById('clear').onclick=()=>{files=[];render();status.textContent='';};
      const labels={received:'Sent ✓ — queued on your Mac',transcribing:'Transcribing…',saved:'Saved ✓ on your Mac',done:'Done ✓ — transcribed',error:'Saved, but transcription failed'};
      function poll(b){const iv=setInterval(async()=>{try{const r=await fetch('/status?b='+b);const j=await r.json();if(labels[j.status])status.textContent=labels[j.status];if(['done','saved','error'].includes(j.status))clearInterval(iv);}catch(e){}},1500);}
      send.onclick=async()=>{
        if(!files.length){alert('Add at least one photo first');return;}
        const b='b'+Date.now(),n=files.length;
        for(let i=0;i<n;i++){status.textContent='Uploading '+(i+1)+'/'+n+'…';
          await fetch('/upload?b='+b+'&i='+i,{method:'POST',body:files[i]});}
        await fetch('/done?b='+b,{method:'POST'});
        status.textContent='Sent '+n+' photo(s) ✓';files=[];render();poll(b);
      };
      render();
    </script></body></html>
    """
}
