import CryptoKit
import Foundation

/// A self-contained file:// reader. Only verified, archive-relative attachments
/// become URLs; message text is data and never participates in HTML or script.
enum WeChatHTMLPreview {
    struct Batch {
        let transcript: WeChatNativeArchive.Transcript?
        let prefix: String
        let paths: [String]
    }

    struct Attachment: Encodable {
        let name: String
        let href: String
        let kind: String
    }

    struct Part: Encodable {
        var text: String? = nil
        var file: Attachment? = nil
    }

    struct Message: Encodable {
        let sender: String
        let day: String
        let time: String
        let parts: [Part]
    }

    struct Supplement: Encodable {
        let title: String
        let text: String?
        let files: [Attachment]
    }

    struct Document: Encodable {
        let chat: String
        let messages: [Message]
        let supplements: [Supplement]
        let unparsedBatches: Int
        let defaultSelfSender: String?
    }

    static func render(chat: String, batches: [Batch], selfSender: String? = nil, timeZone: TimeZone = .current,
                       checkCancellation: () throws -> Void = {}) throws -> String {
        let day = DateFormatter(), time = DateFormatter()
        for formatter in [day, time] {
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
        }
        day.dateFormat = "yyyy-MM-dd"
        time.dateFormat = "HH:mm"
        let marker = try NSRegularExpression(pattern: #"^\[(?:图片|视频|文件|语音|音频|表情|image|video|file|voice|audio|sticker)\][ \t]*(.+)$"#,
                                             options: .caseInsensitive)
        var timeline: [(date: Date, order: Int, message: Message)] = []
        var supplements: [Supplement] = []
        var unparsedBatches = 0
        for (index, batch) in batches.enumerated() {
            try checkCancellation()
            var files: [String: Attachment] = [:]
            for path in batch.paths where path != batch.transcript?.path {
                if let attachment = attachment(path, prefix: batch.prefix) { files[path] = attachment }
            }
            // WeChat's native TXT names an attachment by basename, while the
            // ZIP keeps it in 聊天记录内的图片、视频和文件/. Never choose an ambiguous match.
            let byName = Dictionary(grouping: files.keys, by: { ($0 as NSString).lastPathComponent })
            var used = Set<String>()
            if let records = batch.transcript?.records, !records.isEmpty {
                for record in records {
                    try checkCancellation()
                    var parts: [Part] = [], textLines: [String] = []
                    func flushText() {
                        if !textLines.isEmpty {
                            parts.append(Part(text: textLines.joined(separator: "\n")))
                            textLines.removeAll(keepingCapacity: true)
                        }
                    }
                    for line in record.text.components(separatedBy: "\n") {
                        try checkCancellation()
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        let match = marker.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed))
                        var reference = match.map { (trimmed as NSString).substring(with: $0.range(at: 1)) } ?? trimmed
                        if reference.hasPrefix("./") { reference.removeFirst(2) }
                        let path: String?
                        if files[reference] != nil { path = reference }
                        else if !reference.contains("/"), let candidates = byName[reference], candidates.count == 1 {
                            path = candidates[0]
                        } else { path = nil }
                        if let path, let file = files[path] {
                            flushText()
                            parts.append(Part(file: file))
                            used.insert(path)
                        } else { textLines.append(line) }
                    }
                    flushText()
                    timeline.append((record.date, timeline.count, Message(sender: record.sender, day: day.string(from: record.date),
                                                                          time: time.string(from: record.date), parts: parts)))
                }
                let unused = batch.paths.filter { !used.contains($0) }.compactMap { files[$0] }
                if !unused.isEmpty {
                    supplements.append(Supplement(title: "第 \(index + 1) 批 · 其他附件", text: nil, files: unused))
                }
            } else {
                unparsedBatches += 1
                supplements.append(Supplement(title: "第 \(index + 1) 批 · 原始记录（未识别时间）",
                                               text: batch.transcript?.body, files: batch.paths.compactMap { files[$0] }))
            }
        }
        try checkCancellation()
        timeline.sort { $0.date == $1.date ? $0.order < $1.order : $0.date < $1.date }
        // Account nicknames may differ from a group's display name. Only an
        // exact sender match can establish the default viewing perspective.
        let defaultSelfSender = selfSender.flatMap { candidate in
            !candidate.isEmpty && timeline.contains(where: { $0.message.sender == candidate }) ? candidate : nil
        }
        let document = Document(chat: chat, messages: timeline.map(\.message), supplements: supplements,
                                unparsedBatches: unparsedBatches, defaultSelfSender: defaultSelfSender)
        let encoded = try JSONEncoder().encode(document)
        // Escape HTML raw-text terminators, including mixed-case </script>.
        // Escaping quotes as HTML entities would corrupt this JSON data block.
        let json = String(decoding: encoded, as: UTF8.self)
            .replacingOccurrences(of: "&", with: "\\u0026")
            .replacingOccurrences(of: "<", with: "\\u003c")
            .replacingOccurrences(of: ">", with: "\\u003e")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        let digest = Data(SHA256.hash(data: Data(script.utf8))).base64EncodedString()
        try checkCancellation()
        return """
        <!doctype html>
        <html lang="zh-CN">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'sha256-\(digest)'; style-src 'unsafe-inline'; img-src 'self' file: data:; media-src 'self' file:; base-uri 'none'; form-action 'none'; connect-src 'none'; object-src 'none'; frame-src 'none'">
        <meta name="referrer" content="no-referrer">
        <title>\(escape(chat)) · 聊天记录</title>
        <style>\(style)</style>
        </head>
        <body>
        <div class="reader">
          <aside class="sidebar" aria-label="聊天记录导航">
            <div class="brand"><span class="brand-mark" aria-hidden="true">渡</span><div>聊天记录<small>由渡口导出 · 离线预览</small></div></div>
            <label class="search"><span aria-hidden="true">⌕</span><input id="search" type="search" placeholder="搜索昵称或聊天内容" aria-label="搜索昵称或聊天内容"></label>
            <div class="nav-heading">时间线</div>
            <nav id="dates" aria-label="按日期查看"></nav>
            <div class="sidebar-footer"><a href="%E8%81%8A%E5%A4%A9%E8%AE%B0%E5%BD%95.txt" download>查看原始文字 ↗</a><p>附件随 ZIP 保存在本地</p></div>
          </aside>
          <main>
            <header class="chat-header"><div class="chat-heading"><h1 id="chat-title">\(escape(chat))</h1><p id="summary">正在读取聊天记录…</p></div><label class="perspective">右侧发言人<select id="self" aria-label="右侧发言人" title="选择自己的昵称，将消息显示在右侧"><option value="">未选择</option></select></label></header>
            <div class="toolbar"><span id="filter-label">全部聊天记录</span><button id="clear" hidden>清除筛选</button><button id="latest">最新消息 ↓</button></div>
            <div class="conversation" id="conversation" tabindex="0" aria-label="聊天时间线">
              <div id="messages" role="list" aria-label="消息"></div>
              <p id="empty" class="empty" hidden>没有找到匹配的聊天记录</p>
              <button id="more" class="more" hidden>继续加载</button>
              <section id="supplements" aria-label="其他原始记录和附件"></section>
            </div>
            <footer class="statusbar"><span id="count" role="status" aria-live="polite"></span><span>聊天记录仅供浏览</span></footer>
          </main>
        </div>
        <dialog id="lightbox" aria-label="查看图片"><button id="close-image" aria-label="关闭图片">×</button><img id="full-image" alt=""><a id="download-image" download>保存原图</a></dialog>
        <noscript><p class="noscript">启用浏览器 JavaScript 可查看聊天气泡。也可直接打开压缩包里的「聊天记录.txt」。</p></noscript>
        <script id="chat-data" type="application/json">\(json)</script>
        <script>\(script)</script>
        </body>
        </html>
        """
    }

    private static func attachment(_ path: String, prefix: String) -> Attachment? {
        let fullPath = prefix + "/" + path
        let components = fullPath.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !fullPath.contains(":"), !fullPath.contains("\\"),
              !fullPath.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let href = components.map { String($0).addingPercentEncoding(withAllowedCharacters: allowed)! }.joined(separator: "/")
        let ext = (path as NSString).pathExtension.lowercased()
        let kind: String
        switch ext {
        case "jpg", "jpeg", "png", "gif", "webp", "bmp", "avif": kind = "image"
        case "mp4", "m4v", "mov", "webm", "ogv": kind = "video"
        case "mp3", "m4a", "wav", "ogg", "aac", "flac", "opus": kind = "audio"
        default: kind = "file"
        }
        return Attachment(name: (path as NSString).lastPathComponent, href: href, kind: kind)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static let style = #"""
    :root{color-scheme:light;--ink:#252927;--muted:#858a86;--line:#e0e3df;--green:#07a464;--canvas:#f1f2ef}
    *{box-sizing:border-box}body{margin:0;background:#e5e8e3;color:var(--ink);font:14px/1.55 -apple-system,BlinkMacSystemFont,"PingFang SC","Microsoft YaHei",sans-serif}
    button,input,select{font:inherit;color:inherit}button,a,input,select{-webkit-tap-highlight-color:transparent}button,select{cursor:pointer}button{border:0;background:none}a{color:inherit;text-decoration:none}a:hover{text-decoration:underline}button:focus-visible,a:focus-visible,input:focus-visible,select:focus-visible{outline:2px solid var(--green);outline-offset:3px}[hidden]{display:none!important}
    .reader{display:grid;grid-template-columns:242px minmax(0,1fr);height:100dvh;max-width:1500px;margin:auto;background:var(--canvas)}
    .sidebar{display:flex;flex-direction:column;min-height:0;padding:30px 18px 20px;background:#fafbf9;border-right:1px solid var(--line)}
    .brand{display:flex;align-items:center;gap:11px;font-weight:600;font-size:15px;padding:0 8px 26px}.brand-mark{display:grid;place-items:center;width:38px;height:38px;background:#e1f0e6;border-radius:11px;font-size:19px;color:#308858}.brand small{display:block;font-size:11px;font-weight:400;color:var(--muted);margin-top:2px;letter-spacing:.4px}
    .search{display:flex;align-items:center;gap:7px;background:#ecefea;border-radius:7px;padding:7px 10px;color:#767f77}.search span{font-size:21px;line-height:1}.search input{min-width:0;width:100%;border:0;outline:none;background:transparent;font-size:12px;padding:3px 0}.search:focus-within{box-shadow:0 0 0 2px #07a46460}
    .nav-heading{font-size:11px;color:var(--muted);padding:25px 10px 10px;letter-spacing:1.5px}#dates{overflow:auto;min-height:0;flex:1}.date-link{display:flex;align-items:center;justify-content:space-between;width:100%;padding:10px 12px;border-radius:7px;font-size:12px;text-align:left;margin-bottom:3px}.date-link:hover{background:#edf0eb}.date-link.active{background:#e2ece3;color:#287c4b;font-weight:600}.date-link span{color:#939b92;font:11px ui-monospace,monospace}.date-link.active span{color:#5f9570}
    .sidebar-footer{border-top:1px solid var(--line);margin-top:18px;padding:16px 10px 0;font-size:11px;color:#687668}.sidebar-footer p{margin:4px 0 0;color:#969e94}
    main{display:flex;flex-direction:column;min-width:0;min-height:0}.chat-header{display:flex;align-items:center;justify-content:space-between;gap:18px;min-height:106px;padding:25px 34px 21px;border-bottom:1px solid var(--line);background:#f8f9f6}.chat-heading{min-width:0}h1{font-size:19px;line-height:1.4;font-weight:600;margin:0;overflow-wrap:anywhere}.chat-heading p{color:var(--muted);font-size:11px;margin:7px 0 0}.perspective{display:flex;flex-direction:column;gap:5px;font-size:10px;color:var(--muted);flex-shrink:0}.perspective select{max-width:150px;background:#fff;border:1px solid var(--line);border-radius:5px;padding:4px 24px 4px 8px;font-size:11px;color:#596459}
    .toolbar{display:flex;align-items:center;gap:12px;min-height:42px;padding:9px 34px;font-size:11px;color:var(--muted)}#filter-label{flex:1}.toolbar button{font-size:11px;color:#648569;padding:3px 0}.conversation{flex:1;min-height:0;overflow:auto;overscroll-behavior:contain;padding:0 34px 30px;scrollbar-gutter:stable}#messages{max-width:940px;margin:auto}.day-marker{display:flex;justify-content:center;padding:24px 0 22px;color:#91978f;font-size:11px;letter-spacing:.3px}.message{display:flex;align-items:flex-start;gap:10px;margin-bottom:22px;content-visibility:auto;contain-intrinsic-size:auto 80px}.avatar{display:grid;place-items:center;width:37px;height:37px;border-radius:5px;flex:0 0 37px;font-size:15px;font-weight:500;color:#54745a;background:#dce7d9}.avatar[data-palette="1"]{background:#dde6ec;color:#5a728a}.avatar[data-palette="2"]{background:#eae1d5;color:#8c7659}.avatar[data-palette="3"]{background:#e5e0ed;color:#7d6b8b}.message-body{min-width:0;max-width:min(76%,640px)}.sender{font-size:11px;color:#8c938a;margin:-3px 0 5px;overflow-wrap:anywhere}.sender time{font-size:10px;color:#a1a69e;margin-left:9px;font-variant-numeric:tabular-nums}.bubble{position:relative;display:table;min-width:30px;max-width:100%;padding:10px 13px;background:#fff;border:1px solid #e5e7e2;border-radius:5px;box-shadow:0 1px 1px #00000003}.bubble:before{content:"";position:absolute;left:-5px;top:13px;width:8px;height:8px;transform:rotate(45deg);background:inherit;border-left:1px solid #e5e7e2;border-bottom:1px solid #e5e7e2}.text-part{white-space:pre-wrap;overflow-wrap:anywhere;margin:0;line-height:1.7;font-size:14px}.text-part+.attachment,.attachment+.text-part,.attachment+.attachment{margin-top:10px}.message.self{flex-direction:row-reverse}.self .message-body{display:flex;flex-direction:column;align-items:flex-end}.self .sender{text-align:right}.self .bubble{background:#95ec69;border-color:#8fdf68}.self .bubble:before{left:auto;right:-5px;border:0;border-right:1px solid #8fdf68;border-top:1px solid #8fdf68}.self .avatar{background:#d4e9c9;color:#4d7c42}
    .attachment{display:block;max-width:100%;min-width:0}.image-button{display:block;padding:0;text-align:left;max-width:100%}.image-button img{display:block;max-width:100%;max-height:330px;min-height:40px;border-radius:3px;object-fit:contain;background:#e6e9e2}.attachment video{display:block;max-width:100%;width:320px;max-height:330px;border-radius:4px;background:#222}.attachment audio{display:block;width:280px;max-width:100%}.file-card{display:flex;align-items:center;gap:12px;min-width:min(230px,100%);padding:10px 4px}.file-icon{display:grid;place-items:center;flex:0 0 39px;height:45px;border:1px solid #dce1d6;border-radius:4px;background:#f4f6f0;color:#788a70;font-size:10px;font-weight:600}.file-label{min-width:0;overflow-wrap:anywhere;font-size:12px}.file-label small{display:block;color:#91988a;font-size:10px;margin-top:3px}.media-link{display:block;color:#89917f;font-size:10px;margin-top:6px;overflow-wrap:anywhere}.media-error{color:#8d7750;font-size:11px;margin:5px 0}.empty{text-align:center;color:var(--muted);padding:80px 20px}.more{display:block;margin:20px auto;padding:8px 22px;border:1px solid var(--line);background:#fff;border-radius:6px;font-size:12px;color:#66815c}.more:hover{background:#f6f8f2}#supplements{max-width:940px;margin:24px auto 0}#supplements details{border:1px solid var(--line);border-radius:6px;padding:12px 16px;margin:10px 0;background:#f9faf7;font-size:12px}#supplements summary{cursor:pointer;color:#6b7866}#supplements pre{white-space:pre-wrap;overflow-wrap:anywhere;font:12px/1.8 inherit}#supplements .attachment{max-width:420px;margin-top:12px}.statusbar{display:flex;justify-content:space-between;gap:10px;padding:8px 34px;border-top:1px solid var(--line);font-size:10px;color:#a0a59b;background:#f8f9f6}
    dialog{position:fixed;max-width:94vw;max-height:94vh;border:0;border-radius:10px;background:#202520;color:white;padding:34px 20px 16px}dialog::backdrop{background:#111b11cc}#full-image{display:block;max-width:85vw;max-height:78vh;object-fit:contain}#close-image{position:absolute;right:6px;top:0;color:#fff;font-size:26px;width:32px;height:32px}#download-image{display:block;text-align:center;font-size:12px;margin-top:12px}.noscript{position:fixed;bottom:60px;left:20px;right:20px;padding:20px;background:#fff;border:1px solid #ccc}
    @media(min-width:1500px){.reader{border-left:1px solid var(--line);border-right:1px solid var(--line)}}
    @media(max-width:760px){.reader{grid-template-columns:180px minmax(0,1fr)}.sidebar{padding:22px 10px 16px}.brand{padding:0 5px 20px;font-size:13px;gap:7px}.brand small{font-size:9px}.brand-mark{width:31px;height:31px}.chat-header{padding:20px;gap:10px}.conversation{padding:0 16px 24px}.toolbar,.statusbar{padding-left:20px;padding-right:20px}.message-body{max-width:calc(100% - 55px)}.perspective select{max-width:110px}.statusbar>span:last-child{display:none}}
    @media(max-width:540px){.reader{display:flex;flex-direction:column}.sidebar{flex-shrink:0;display:block;border-right:0;border-bottom:1px solid var(--line);padding:12px 16px 8px}.brand,.nav-heading,.sidebar-footer{display:none}.search{padding:4px 10px}#dates{display:flex;overflow-x:auto;gap:5px;padding-top:8px}.date-link{white-space:nowrap;width:auto;flex-shrink:0;gap:10px;padding:5px 9px;font-size:11px;margin:0}.reader main{flex:1}.chat-header{min-height:85px;padding:15px 18px}h1{font-size:16px}.chat-heading p{font-size:10px}.toolbar{padding:7px 18px;min-height:36px}.day-marker{padding:18px 0}.message{gap:8px}.avatar{width:32px;height:32px;flex-basis:32px}.bubble{padding:9px 11px}.text-part{font-size:13px}.perspective{font-size:9px}}
    @media(prefers-reduced-motion:reduce){*{scroll-behavior:auto!important}}
    """#

    private static let script = #"""
    (() => {
      'use strict';
      const data = JSON.parse(document.getElementById('chat-data').textContent);
      const $ = id => document.getElementById(id);
      const messages = data.messages;
      let selectedDay = '', query = '', selfSender = '', filtered = messages, shown = 0, rangeStart = 0, lastDay = '';
      const pageSize = 200;
      function el(tag, className, text) {
        const node = document.createElement(tag);
        if (className) node.className = className;
        if (text !== undefined) node.textContent = text;
        return node;
      }
      const senders = [...new Set(messages.map(m => m.sender))];
      for (const [index, sender] of senders.entries()) {
        const option = el('option', '', sender);
        // An index distinguishes an actual nickname from the empty choice.
        option.value = String(index + 1);
        $('self').append(option);
      }
      const defaultSelfIndex = senders.indexOf(data.defaultSelfSender);
      if (defaultSelfIndex >= 0) {
        selfSender = senders[defaultSelfIndex];
        $('self').value = String(defaultSelfIndex + 1);
      }
      $('chat-title').textContent = data.chat;
      $('summary').textContent = `${messages.length.toLocaleString()} 条消息 · ${senders.length} 位发言人` +
        (messages.length ? ` · ${messages[0].day} — ${messages[messages.length - 1].day}` : '');
      if (data.unparsedBatches) {
        $('summary').textContent = (messages.length ? $('summary').textContent + ' · ' : '') +
          `${data.unparsedBatches} 批记录未识别时间，可在页末查看原文和附件`;
      }
      const dayCounts = new Map();
      messages.forEach(m => dayCounts.set(m.day, (dayCounts.get(m.day) || 0) + 1));
      function dateButton(day, count) {
        const button = el('button', 'date-link', day || '全部日期');
        button.append(el('span', '', count.toLocaleString()));
        button.dataset.day = day;
        button.addEventListener('click', () => { selectedDay = day; filter(); });
        $('dates').append(button);
      }
      dateButton('', messages.length);
      dayCounts.forEach((count, day) => dateButton(day, count));
      function attachment(file) {
        const wrap = el('div', 'attachment');
        const link = el('a', file.kind === 'file' ? 'file-card' : 'media-link');
        link.href = file.href;
        link.setAttribute('download', file.name);
        if (file.kind === 'image') {
          const button = el('button', 'image-button');
          button.setAttribute('aria-label', `查看图片：${file.name}`);
          const img = el('img');
          img.src = file.href; img.alt = file.name; img.loading = 'lazy'; img.decoding = 'async';
          button.append(img);
          button.addEventListener('click', () => {
            $('full-image').src = file.href; $('full-image').alt = file.name;
            $('download-image').href = file.href; $('download-image').download = file.name;
            $('lightbox').showModal();
          });
          img.addEventListener('error', () => {
            button.hidden = true;
            wrap.prepend(el('p', 'media-error', '图片无法预览，可打开原文件查看。'));
          }, {once:true});
          wrap.append(button);
        } else if (file.kind === 'video' || file.kind === 'audio') {
          const media = el(file.kind);
          media.src = file.href; media.controls = true; media.preload = 'none';
          if (file.kind === 'video') media.setAttribute('playsinline', '');
          media.setAttribute('aria-label', file.name);
          media.addEventListener('error', () => {
            wrap.append(el('p', 'media-error', '浏览器无法播放此格式，可打开原文件查看。'));
          }, {once:true});
          wrap.append(media);
        }
        if (file.kind === 'file') {
          link.append(el('span', 'file-icon', file.name.split('.').pop().slice(0,4).toUpperCase()));
          const label = el('span', 'file-label', file.name);
          label.append(el('small', '', '打开 / 保存文件'));
          link.append(label);
        } else link.textContent = file.name + ' ↗';
        wrap.append(link);
        return wrap;
      }
      function message(m) {
        const row = el('article', 'message' + (selfSender && m.sender === selfSender ? ' self' : ''));
        row.setAttribute('role', 'listitem');
        const avatar = el('div', 'avatar', Array.from(m.sender.trim())[0] || '·');
        avatar.dataset.palette = String(senders.indexOf(m.sender) % 4);
        avatar.setAttribute('aria-hidden', 'true');
        const body = el('div', 'message-body');
        const sender = el('div', 'sender', m.sender);
        const time = el('time', '', m.time); time.dateTime = m.day + 'T' + m.time;
        sender.append(time);
        const bubble = el('div', 'bubble');
        m.parts.forEach(part => bubble.append(part.file ? attachment(part.file) : el('p', 'text-part', part.text)));
        body.append(sender, bubble); row.append(avatar, body);
        return row;
      }
      function appendPage() {
        const end = Math.min(shown + pageSize, filtered.length);
        const fragment = document.createDocumentFragment();
        for (; shown < end; shown++) {
          const m = filtered[shown];
          if (m.day !== lastDay) { fragment.append(el('div', 'day-marker', m.day)); lastDay = m.day; }
          fragment.append(message(m));
        }
        $('messages').append(fragment);
        $('more').hidden = shown >= filtered.length;
        $('count').textContent = `${rangeStart ? (rangeStart + 1).toLocaleString() + '–' : ''}${shown.toLocaleString()} / ${filtered.length.toLocaleString()} 条消息`;
      }
      function filter() {
        filtered = messages.filter(m => (!selectedDay || m.day === selectedDay) && (!query ||
          m.sender.toLocaleLowerCase().includes(query) || m.parts.some(p => (p.text ?? p.file?.name ?? '').toLocaleLowerCase().includes(query))));
        shown = 0; rangeStart = 0; lastDay = '';
        $('messages').replaceChildren();
        $('empty').hidden = filtered.length > 0 || (!messages.length && data.supplements.length > 0);
        $('filter-label').textContent = selectedDay || '全部聊天记录';
        if (query) $('filter-label').textContent += ` · 搜索“${$('search').value.trim()}”`;
        $('clear').hidden = !selectedDay && !query;
        $('supplements').hidden = !!selectedDay || !!query;
        document.querySelectorAll('.date-link').forEach(b => {
          const active = b.dataset.day === selectedDay;
          b.classList.toggle('active', active); b.setAttribute('aria-pressed', String(active));
        });
        appendPage(); $('conversation').scrollTop = 0;
      }
      data.supplements.forEach(s => {
        const details = el('details');
        details.append(el('summary', '', s.title + (s.files.length ? ` · ${s.files.length} 个附件` : '')));
        if (s.text) details.append(el('pre', '', s.text));
        s.files.forEach(f => details.append(attachment(f)));
        if (!messages.length) details.open = true;
        $('supplements').append(details);
      });
      let searchTimer;
      $('search').addEventListener('input', () => {
        clearTimeout(searchTimer);
        searchTimer = setTimeout(() => { query = $('search').value.trim().toLocaleLowerCase(); filter(); }, 150);
      });
      $('self').addEventListener('change', () => { selfSender = senders[Number($('self').value) - 1] || ''; filter(); });
      $('clear').addEventListener('click', () => { clearTimeout(searchTimer); selectedDay = ''; query = ''; $('search').value = ''; filter(); });
      $('more').addEventListener('click', appendPage);
      if ('IntersectionObserver' in window) {
        new IntersectionObserver(entries => {
          if (entries.some(e => e.isIntersecting) && !$('more').hidden) appendPage();
        }, {root:$('conversation'), rootMargin:'400px'}).observe($('more'));
      }
      $('latest').addEventListener('click', () => {
        if (!filtered.length) return;
        // Jump to the final page without constructing every earlier media node.
        $('messages').replaceChildren(); lastDay = ''; shown = Math.max(0, filtered.length - pageSize); rangeStart = shown;
        if (shown) $('messages').append(el('p', 'day-marker', `显示最后 ${pageSize} 条；选择日期可查看更早记录`));
        appendPage(); $('conversation').scrollTop = $('conversation').scrollHeight;
      });
      $('close-image').addEventListener('click', () => $('lightbox').close());
      $('lightbox').addEventListener('click', e => { if (e.target === $('lightbox')) $('lightbox').close(); });
      $('lightbox').addEventListener('close', () => $('full-image').removeAttribute('src'));
      filter();
    })();
    """#
}
