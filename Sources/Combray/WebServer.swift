import Foundation
import Network
import Darwin
import CombrayCore

/// A tiny local web server that serves a read-only, browsable view of the whole archive
/// (image ↔ transcription, summary, notable quotes, meta, instant search) in the Combray look.
///
/// It reads the SAME data the native app does — the SQLite index + the `Letters/` folders — so there
/// is no separate copy and nothing to sync. It runs only while the app is open. "Show on web" opens
/// `http://localhost:<port>/` in the browser; the server also answers on the Mac's Wi-Fi address, so
/// a phone on the same network can view the archive too.
///
/// All state is touched only on `queue`, so it's safe to mark `@unchecked Sendable`.
final class WebServer: @unchecked Sendable {
    private let archive: Archive
    private let images: ImageStore
    private let queue = DispatchQueue(label: "combray.web")
    private var listener: NWListener?
    let port: UInt16 = 8788

    init(archive: Archive, images: ImageStore) {
        self.archive = archive
        self.images = images
    }

    var localURL: String { "http://localhost:\(port)/" }
    var lanURL: String? { CaptureServer.wifiIPAddress().map { "http://\($0):\(port)/" } }

    func start() { queue.async { self.startLocked() } }

    private func startLocked() {
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            l.newConnectionHandler = { [weak self] conn in
                guard let self else { return }
                conn.start(queue: self.queue)
                self.receive(conn, buffer: Data())
            }
            l.start(queue: queue)
            self.listener = l
        } catch {
            print("web server failed to start:", error)
        }
    }

    // MARK: - HTTP

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if buf.range(of: Data("\r\n\r\n".utf8)) != nil {
                let header = String(decoding: buf, as: UTF8.self)
                self.route(conn, header: header)
                return
            }
            if isComplete || error != nil { conn.cancel(); return }
            self.receive(conn, buffer: buf)
        }
    }

    private func route(_ conn: NWConnection, header: String) {
        let firstLine = header.split(separator: "\r\n").first.map(String.init) ?? ""
        let parts = firstLine.split(separator: " ")
        let path = parts.count > 1 ? String(parts[1]) : "/"
        let rawPath = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
        let q = Self.query(path)

        if rawPath == "/" {
            respondHTML(conn, indexHTML())
        } else if rawPath == "/l", let id = q["id"]?.removingPercentEncoding {
            respondHTML(conn, letterHTML(id: id))
        } else if rawPath == "/img", let rel = q["p"]?.removingPercentEncoding {
            serveImage(conn, relativePath: rel)
        } else {
            respond(conn, "404 Not Found", "text/plain; charset=utf-8", Data("Not found".utf8))
        }
    }

    private func serveImage(_ conn: NWConnection, relativePath: String) {
        // Confine to the archive root — never serve arbitrary files.
        let root = images.root.standardizedFileURL
        let target = root.appendingPathComponent(relativePath).standardizedFileURL
        guard target.path.hasPrefix(root.path), let data = try? Data(contentsOf: target) else {
            respond(conn, "404 Not Found", "text/plain", Data("no image".utf8)); return
        }
        let type = target.pathExtension.lowercased() == "png" ? "image/png" : "image/jpeg"
        respond(conn, "200 OK", type, data)
    }

    private func respondHTML(_ conn: NWConnection, _ html: String) {
        respond(conn, "200 OK", "text/html; charset=utf-8", Data(html.utf8))
    }

    private func respond(_ conn: NWConnection, _ status: String, _ type: String, _ body: Data) {
        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
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

    // MARK: - Pages

    /// The whole archive as a searchable grid of cards.
    private func indexHTML() -> String {
        let letters = (try? archive.allLetters()) ?? []
        var cards = ""
        for l in letters {
            let parties = try? archive.participants(forLetterId: l.id)
            let people = ([parties?.sender?.displayName].compactMap { $0 }
                          + (parties?.recipients.map(\.displayName) ?? [])).joined(separator: " ")
            let title = l.title ?? "Untitled"
            let date = l.dateValue ?? ""
            let summary = l.summary ?? ""
            let hay = Self.esc("\(title) \(people) \(summary) \(date)").lowercased()
            let pin = l.pinned ? "<span class=pin>\u{2605}</span>" : ""
            cards += """
            <a class=card href="/l?id=\(Self.urlq(l.id))" data-h="\(hay)">
              \(pin)<div class=ct>\(Self.esc(title))</div>
              <div class=cd>\(Self.esc(date.isEmpty ? "—" : date))</div>
              <div class=cs>\(Self.esc(String(summary.prefix(150))))</div>
            </a>
            """
        }
        let count = letters.count
        return Self.page(title: "Combray", body: """
        \(Self.header(subtitle: "\(count) document\(count == 1 ? "" : "s")"))
        <input id=q class=search placeholder="Search titles, people, summaries…" autocomplete=off>
        <div id=grid class=grid>\(cards)</div>
        <div id=empty class=empty hidden>Nothing matches that.</div>
        <script>
          const q=document.getElementById('q'),cards=[...document.querySelectorAll('.card')],empty=document.getElementById('empty');
          q.oninput=()=>{const t=q.value.trim().toLowerCase();let n=0;
            cards.forEach(c=>{const m=!t||c.dataset.h.includes(t);c.style.display=m?'':'none';if(m)n++;});
            empty.hidden=n>0;};
        </script>
        """)
    }

    /// One document: image(s) on the left, transcription + summary + quotes + meta on the right.
    private func letterHTML(id: String) -> String {
        guard let l = (try? archive.letter(id: id)) ?? nil else {
            return Self.page(title: "Not found", body: "\(Self.header(subtitle: "")) <p>That document isn’t here.</p>")
        }
        let parties = try? archive.participants(forLetterId: id)
        let pages = (try? archive.pages(forLetterId: id)) ?? []

        var imgs = ""
        for p in pages {
            imgs += "<img class=page src=\"/img?p=\(Self.urlq(p.imagePath))\" loading=lazy>"
        }
        if imgs.isEmpty { imgs = "<div class=noimg>No page images.</div>" }

        var meta = ""
        func metaRow(_ k: String, _ v: String?) {
            guard let v = Self.clean(v) else { return }
            meta += "<div class=mr><div class=mk>\(Self.esc(k))</div><div class=mv>\(Self.esc(v))</div></div>"
        }
        metaRow("Possible location", l.metaLocation)
        metaRow("Likely relationship", l.metaRelationship)
        metaRow("State of the relationship", l.metaRelationshipState)
        metaRow("Writer’s goals", l.metaWriterGoals)
        let metaCard = meta.isEmpty ? "" :
            "<div class=card2><h3>Meta — what it quietly reveals</h3>\(meta)</div>"

        let quotes = (l.notableQuotes ?? "").split(separator: "\n").map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let quotesCard = quotes.isEmpty ? "" :
            "<div class=card2><h3>Notable quotes</h3>" +
            quotes.map { "<p class=quote>\u{201C}\(Self.esc($0))\u{201D}</p>" }.joined() + "</div>"

        let summaryCard = Self.clean(l.summary).map {
            "<div class=card2><h3>Summary</h3><p>\(Self.esc($0))</p></div>"
        } ?? ""

        let from = parties?.sender?.displayName
        let to = parties?.recipients.map(\.displayName).joined(separator: ", ") ?? ""
        var line: [String] = []
        if let from = Self.clean(from) { line.append("From " + Self.esc(from)) }
        if let to = Self.clean(to) { line.append("To " + Self.esc(to)) }
        if let d = Self.clean(l.dateValue) { line.append(Self.esc(d)) }

        let body = Self.clean(l.transcription).map {
            "<pre class=transcript>\(Self.esc($0))</pre>"
        } ?? "<p class=muted>Not transcribed yet.</p>"

        return Self.page(title: l.title ?? "Document", body: """
        <a class=back href="/">\u{2190} All documents</a>
        <h1 class=doctitle>\(Self.esc(l.title ?? "Untitled"))</h1>
        <div class=metaline>\(line.joined(separator: " &middot; "))</div>
        <div class=split>
          <div class=pages>\(imgs)</div>
          <div class=right>
            <div class=card2><h3>Transcription</h3>\(body)</div>
            \(summaryCard)\(quotesCard)\(metaCard)
          </div>
        </div>
        """)
    }

    // MARK: - HTML helpers

    static func clean(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    static func esc(_ s: String) -> String {
        var out = ""
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(ch)
            }
        }
        return out
    }

    /// Percent-encode a value for a URL query.
    private static func urlq(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
    }

    private static func header(subtitle: String) -> String {
        """
        <header class=top>
          <svg class=logo viewBox="0 0 100 100" aria-hidden=true>
            <defs><linearGradient id=m x1=0 y1=0 x2=0 y2=1>
              <stop offset=0 stop-color="#fdda7c"/><stop offset=1 stop-color="#e3ab44"/></linearGradient></defs>
            <path d="M50 91 C37 91 30 79 28 59 C27 49 27 40 31 33 Q34 29 37 33 Q40 28 43 32 Q46.5 27 50 31 Q53.5 27 57 32 Q60 28 63 33 Q66 29 69 33 C73 40 73 49 72 59 C70 79 63 91 50 91 Z"
              fill="url(#m)" stroke="#6b450f" stroke-width=3 stroke-linejoin=round/>
            <g stroke="#8a5a1c" stroke-width=2 stroke-linecap=round opacity=.5 fill=none>
              <path d="M50 83 L43 35"/><path d="M50 84 L50 33"/><path d="M50 83 L57 35"/></g>
          </svg>
          <a href="/" class=word>Combray</a>
          <span class=sub>\(esc(subtitle))</span>
        </header>
        """
    }

    private static func page(title: String, body: String) -> String {
        """
        <!doctype html><html><head><meta charset=utf-8>
        <meta name=viewport content="width=device-width,initial-scale=1">
        <title>\(esc(title)) · Combray</title>
        <style>
          :root{--gold:#cda22c;--gold-deep:#9a7a1e;--ink:#211d16;--faint:#7c756a;--line:#ece4d5;
            --bg-1:#fffdf7;--bg-2:#f4e9d3;--card:#fffef9;--radius:16px}
          *{box-sizing:border-box}
          body{font-family:-apple-system,system-ui,sans-serif;margin:0;color:var(--ink);
            background:radial-gradient(130% 80% at 50% -10%,var(--bg-1),var(--bg-2));min-height:100vh;
            padding:26px 22px 60px}
          .wrap,header,.grid,.split,.search,.back,#empty,.doctitle,.metaline{
            max-width:1100px;margin-left:auto;margin-right:auto}
          header.top{display:flex;align-items:center;justify-content:center;gap:12px;margin:4px auto 22px}
          .logo{width:42px;height:42px;filter:drop-shadow(0 5px 11px rgba(150,110,20,.28))}
          .word{font:700 32px/1 Georgia,'Times New Roman',serif;color:var(--ink);text-decoration:none}
          .sub{color:var(--faint);font-size:15px}
          .search{display:block;width:100%;font-size:18px;padding:15px 18px;border-radius:var(--radius);
            border:1px solid var(--line);background:var(--card);margin-bottom:20px;outline:none}
          .search:focus{border-color:var(--gold)}
          .grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(250px,1fr));gap:16px}
          .card{position:relative;display:block;text-decoration:none;color:inherit;background:var(--card);
            border:1px solid var(--line);border-radius:var(--radius);padding:18px;
            box-shadow:0 8px 22px rgba(90,65,15,.07);transition:transform .12s,box-shadow .12s}
          .card:hover{transform:translateY(-2px);box-shadow:0 14px 30px rgba(90,65,15,.14);border-color:var(--gold)}
          .pin{position:absolute;top:12px;right:14px;color:var(--gold)}
          .ct{font-size:18px;font-weight:700;margin-bottom:4px;padding-right:14px}
          .cd{font-size:13px;color:var(--gold-deep);font-weight:600;margin-bottom:8px}
          .cs{font-size:14px;color:var(--faint);line-height:1.45}
          .empty{text-align:center;color:var(--faint);padding:40px;font-size:18px}
          .back{display:inline-block;color:var(--gold-deep);text-decoration:none;font-weight:600;margin-bottom:8px}
          .doctitle{font-size:30px;margin:6px 0 4px;text-align:center}
          .metaline{color:var(--faint);font-size:15px;margin-bottom:18px;text-align:center}
          .split{display:grid;grid-template-columns:1fr 1fr;gap:22px;align-items:start}
          @media(max-width:820px){.split{grid-template-columns:1fr}}
          .pages{display:flex;flex-direction:column;gap:14px}
          .page{width:100%;border-radius:14px;border:1px solid var(--line);box-shadow:0 8px 20px rgba(90,65,15,.12)}
          .noimg{color:var(--faint);padding:40px;text-align:center;background:var(--card);border-radius:14px}
          .right{display:flex;flex-direction:column;gap:18px}
          .card2{background:var(--card);border:1px solid var(--line);border-radius:var(--radius);padding:20px;
            box-shadow:0 8px 22px rgba(90,65,15,.07)}
          .card2 h3{margin:0 0 10px;font-size:15px;font-weight:700;color:var(--faint);
            text-transform:uppercase;letter-spacing:.04em}
          .transcript{font-family:-apple-system,system-ui,sans-serif;font-size:17px;line-height:1.6;
            white-space:pre-wrap;margin:0}
          .quote{font-style:italic;font-size:17px;margin:0 0 10px}
          .muted{color:var(--faint)}
          .mr{margin-bottom:12px}.mr:last-child{margin-bottom:0}
          .mk{font-size:13px;font-weight:700;color:var(--faint);text-transform:uppercase;letter-spacing:.04em}
          .mv{font-size:16px;margin-top:2px}
        </style></head><body>
        \(body)
        </body></html>
        """
    }
}
