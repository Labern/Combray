import Foundation
import Network

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
        guard let ip = LocalHTTP.wifiIPAddress() else { return nil }
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
                let length = LocalHTTP.contentLength(header)
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
        let q = LocalHTTP.query(path)

        if method == "GET", path == "/" || path.hasPrefix("/?") {
            LocalHTTP.respond(conn, "200 OK", "text/html; charset=utf-8", Data(Self.html.utf8))
        } else if method == "POST", path.hasPrefix("/upload") {
            let batch = q["b"] ?? "default"
            let index = Int(q["i"] ?? "0") ?? 0
            saveUpload(batch: batch, index: index, data: body)
            LocalHTTP.respond(conn, "200 OK", "text/plain", Data("ok".utf8))
        } else if method == "POST", path.hasPrefix("/done") {
            let batch = q["b"] ?? "default"
            let urls = (batches[batch] ?? []).sorted { $0.0 < $1.0 }.map { $0.1 }
            batches[batch] = nil
            statuses[batch] = "received"
            if !urls.isEmpty { onLetter?(batch, urls) }
            LocalHTTP.respond(conn, "200 OK", "text/plain", Data("done".utf8))
        } else if method == "GET", path.hasPrefix("/status") {
            let batch = q["b"] ?? "default"
            let s = statuses[batch] ?? "none"
            LocalHTTP.respond(conn, "200 OK", "application/json", Data("{\"status\":\"\(s)\"}".utf8))
        } else {
            LocalHTTP.respond(conn, "404 Not Found", "text/plain", Data("not found".utf8))
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

    static let html = """
    <!doctype html><html><head><meta charset=utf-8>
    <meta name=viewport content="width=device-width,initial-scale=1,maximum-scale=1,viewport-fit=cover">
    <meta name=theme-color content="#c79a27">
    <title>Combray</title>
    <style>
      /* Design tokens — swap these to re-theme the whole page. */
      :root{
        --gold:#cda22c; --gold-deep:#9a7a1e; --gold-soft:#f4e8c8;
        --grad-a:#e3bb49; --grad-b:#c79a27;
        --ink:#211d16; --faint:#7c756a; --line:#ece4d5;
        --bg-1:#fffdf7; --bg-2:#f4e9d3; --card:#fffef9; --radius:18px;
      }
      *{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
      body{font-family:-apple-system,system-ui,sans-serif;margin:0;padding:30px 20px 48px;color:var(--ink);
        background:radial-gradient(130% 80% at 50% -10%,var(--bg-1),var(--bg-2));min-height:100vh}
      .wrap{max-width:520px;margin:0 auto}
      .head{text-align:center;margin:4px 0 22px}
      .logo{width:64px;height:64px;display:block;margin:0 auto 8px;
        filter:drop-shadow(0 6px 14px rgba(150,110,20,.30))}
      .word{font:700 42px/1 Georgia,'Times New Roman',serif;letter-spacing:.4px}
      .tag{font-size:15px;color:var(--faint);margin-top:8px;line-height:1.4}
      .card{background:var(--card);border:1px solid var(--line);border-radius:24px;padding:20px;
        box-shadow:0 22px 60px rgba(90,65,15,.13)}
      .btn{font:600 21px/1 -apple-system,system-ui;padding:19px;border-radius:var(--radius);border:0;
        display:block;width:100%;margin:12px 0;text-align:center;color:#fff;cursor:pointer;user-select:none;
        background:linear-gradient(180deg,var(--grad-a),var(--grad-b));
        box-shadow:0 9px 22px rgba(199,154,39,.34);
        transition:transform .12s ease,box-shadow .12s ease,opacity .12s ease}
      .btn:active{transform:scale(.965);box-shadow:0 4px 11px rgba(199,154,39,.30)}
      .btn.secondary{background:#fff;color:var(--gold-deep);border:2px solid var(--gold);box-shadow:none}
      .btn.secondary:active{transform:scale(.965);background:var(--gold-soft)}
      #strip{display:flex;overflow-x:auto;gap:12px;padding:4px 0 10px;-webkit-overflow-scrolling:touch}
      #strip:empty{display:none}
      .thumb{position:relative;flex:0 0 auto;width:120px;text-align:center}
      .thumb img{width:120px;height:150px;object-fit:cover;border-radius:14px;border:1px solid var(--line);
        box-shadow:0 7px 18px rgba(90,65,15,.15);display:block}
      .thumb .x{position:absolute;top:7px;right:7px;width:28px;height:28px;line-height:26px;border-radius:50%;
        background:rgba(20,15,5,.62);color:#fff;font-size:18px;text-align:center;cursor:pointer;
        transition:transform .12s ease}
      .thumb .x:active{transform:scale(.82)}
      .thumb .lbl{font-size:14px;color:var(--faint);margin-top:7px;font-weight:600}
      .statusbar{text-align:center;margin-top:4px;min-height:26px}
      #status{font-size:16px;color:var(--gold-deep);font-weight:600}
      #status:not(:empty){display:inline-block;background:var(--gold-soft);padding:9px 16px;border-radius:999px}
      #status.err{color:#a23a2a;background:#f6ddd6}
      .shake{animation:shake .42s}
      @keyframes shake{10%,90%{transform:translateX(-2px)}30%,70%{transform:translateX(4px)}50%{transform:translateX(-6px)}}
    </style></head><body>
    <div class=wrap>
      <div class=head>
        <svg class=logo viewBox="0 0 100 100" aria-hidden=true>
          <defs><linearGradient id=mad x1=0 y1=0 x2=0 y2=1>
            <stop offset=0 stop-color="#fdda7c"/><stop offset=1 stop-color="#e3ab44"/></linearGradient></defs>
          <path d="M50 91 C37 91 30 79 28 59 C27 49 27 40 31 33 Q34 29 37 33 Q40 28 43 32 Q46.5 27 50 31 Q53.5 27 57 32 Q60 28 63 33 Q66 29 69 33 C73 40 73 49 72 59 C70 79 63 91 50 91 Z"
            fill="url(#mad)" stroke="#6b450f" stroke-width=3 stroke-linejoin=round/>
          <g stroke="#8a5a1c" stroke-width=2 stroke-linecap=round opacity=.5 fill=none>
            <path d="M50 83 L43 35"/><path d="M50 84 L50 33"/><path d="M50 83 L57 35"/>
            <path d="M49 82 L34 43"/><path d="M51 82 L66 43"/></g>
          <ellipse cx=43 cy=42 rx=6 ry=3 fill="#fff" opacity=.45/>
        </svg>
        <div class=word>Combray</div>
        <div class=tag>Photograph your letters — they fly straight to your Mac.</div>
      </div>
      <div class=card>
        <div id=strip></div>
        <label class=btn for=f>Take / add a photo</label>
        <input id=f type=file accept="image/*" capture=environment multiple style="display:none">
        <button class=btn id=send>Send to Mac</button>
        <button class="btn secondary" id=clear>Start over</button>
        <div class=statusbar><span id=status></span></div>
      </div>
    </div>
    <script>
      let files=[];
      const strip=document.getElementById('strip'),send=document.getElementById('send'),
            status=document.getElementById('status'),card=document.querySelector('.card');
      function setStatus(m){status.classList.remove('err');status.textContent=m;}
      function flash(m){status.textContent=m;status.classList.add('err');
        card.classList.remove('shake');void card.offsetWidth;card.classList.add('shake');}
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
      document.getElementById('clear').onclick=()=>{files=[];render();setStatus('');};
      const labels={received:'Sent ✓ — queued on your Mac',transcribing:'Transcribing…',saved:'Saved ✓ on your Mac',done:'Done ✓ — transcribed',error:'Saved, but transcription failed'};
      function poll(b){const iv=setInterval(async()=>{try{const r=await fetch('/status?b='+b);const j=await r.json();if(labels[j.status])setStatus(labels[j.status]);if(['done','saved','error'].includes(j.status))clearInterval(iv);}catch(e){}},1500);}
      send.onclick=async()=>{
        if(!files.length){flash('Add a photo first');return;}
        const b='b'+Date.now(),n=files.length;
        for(let i=0;i<n;i++){setStatus('Uploading '+(i+1)+'/'+n+'…');
          await fetch('/upload?b='+b+'&i='+i,{method:'POST',body:files[i]});}
        await fetch('/done?b='+b,{method:'POST'});
        setStatus('Sent '+n+' photo(s) ✓');files=[];render();poll(b);
      };
      render();
    </script></body></html>
    """
}
