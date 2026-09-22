#!/usr/bin/env swift
// Turns the Markdown release notes in Resources/ReleaseNotes into the two
// published forms. The same file is shared by Charker, Dukou and AutoCodeBar;
// everything app-specific is read from Resources/Info.plist (CFBundleName,
// SUFeedURL) or from the appcast, apart from the brand colours below.
//
//   release-notes.swift sparkle <version> <build> <yyyy-mm-dd> <out-dir>
//       <App>-<version>.html and <App>-<version>.zh.html for Sparkle's update
//       window. Full documents (so generate_appcast links rather than embeds
//       them), styled inline, no script: Sparkle runs release notes with
//       JavaScript off and should not have to fetch anything else.
//
//   release-notes.swift history <appcast.xml> <out-file>
//       The bilingual version history page that Sparkle's "Version History"
//       button opens (sparkle:fullReleaseNotesLink).
//
// Notes are written as <version>.md (English) and <version>.zh.md: an
// optional "# App x.y.z" title, an optional one-line summary, then "## New" /
// "## Improvements" / "## Fixes" sections (or 新功能 / 改进 / 修复) of "- "
// items. Keep them short: the change itself, not where to find it.

import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let notesDirectory = root.appendingPathComponent("Resources/ReleaseNotes")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("release-notes: \(message)\n".utf8))
    exit(1)
}

let info: [String: Any] = {
    let url = root.appendingPathComponent("Resources/Info.plist")
    guard let data = try? Data(contentsOf: url),
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    else { fail("cannot read \(url.path)") }
    return plist
}()
let appName = info["CFBundleName"] as? String ?? { fail("Info.plist has no CFBundleName") }()
/// GitHub Pages serves the notes and the history page next to the appcast.
let siteURL: String = {
    guard let feed = info["SUFeedURL"] as? String, let url = URL(string: feed) else {
        fail("Info.plist has no SUFeedURL")
    }
    return url.deletingLastPathComponent().absoluteString
}()

/// The "New" colour doubles as the accent, matching each app's site.
let brand: (light: String, dark: String) = [
    "Charker": ("#0a78a0", "#5bcef5"),
    "Dukou": ("#16865f", "#58d8a8"),
    "AutoCodeBar": ("#0f8175", "#54d6c8"),
][appName] ?? ("#0a78a0", "#5bcef5")

enum Language: String, CaseIterable {
    case en, zh

    var htmlLang: String { self == .zh ? "zh-Hans" : "en" }
    var fileSuffix: String { self == .zh ? ".zh" : "" }

    func date(year: Int, month: Int, day: Int) -> String {
        switch self {
        case .zh: return "\(year)年\(month)月\(day)日"
        case .en:
            let names = ["January", "February", "March", "April", "May", "June", "July",
                         "August", "September", "October", "November", "December"]
            return "\(names[month - 1]) \(day), \(year)"
        }
    }
}

struct Release {
    var version: String
    var build: String
    var year: Int, month: Int, day: Int

    var isoDate: String { String(format: "%04d-%02d-%02d", year, month, day) }
}

// MARK: - Markdown subset

func escape(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}

func inline(_ text: String) -> String {
    var html = escape(text)
    let rules: [(String, String)] = [
        (#"`([^`]+)`"#, "<code>$1</code>"),
        (#"\*\*([^*]+)\*\*"#, "<strong>$1</strong>"),
        (#"\[([^\]]+)\]\((https?://[^\s)]+)\)"#, #"<a href="$2">$1</a>"#),
    ]
    for (pattern, template) in rules {
        html = html.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
    }
    return html
}

/// The colour a section's label takes, from its heading in either language.
func tone(of heading: String) -> String {
    switch heading.lowercased() {
    case "新功能", "新增", "new", "new features", "features": return "new"
    case "改进", "优化", "improvements", "improved", "changes": return "improved"
    case "修复", "fixes", "fixed", "bug fixes": return "fixed"
    default: return "other"
    }
}

/// Summary paragraphs, then sections. A heading-less list is a section too.
func renderNotes(_ markdown: String) -> String {
    var source = markdown
    // generate_appcast prepends a signing note to files it signed.
    if let range = source.range(of: #"<!--[\s\S]*?-->"#, options: .regularExpression) {
        source.removeSubrange(range)
    }
    var html = ""
    var inSection = false
    var listTag: String?

    func closeList() {
        if let tag = listTag { html += "</\(tag)>" }
        listTag = nil
    }
    func openSection(_ heading: String?) {
        closeList()
        if inSection { html += "</section>" }
        let kind = heading.map(tone(of:)) ?? "other"
        html += "<section class=\"\(kind)\">"
        if let heading { html += "<h3><span class=\"tag\">\(inline(heading))</span></h3>" }
        inSection = true
    }

    for rawLine in source.components(separatedBy: .newlines) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.isEmpty { closeList(); continue }
        if line.hasPrefix("# ") { continue }
        if line.hasPrefix("## ") || line.hasPrefix("### ") {
            openSection(String(line.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces))
            continue
        }
        var item: String?
        var tag = "ul"
        if line.hasPrefix("- ") || line.hasPrefix("* ") {
            item = String(line.dropFirst(2))
        } else if let match = line.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
            item = String(line[match.upperBound...])
            tag = "ol"
        }
        if let item {
            if !inSection { openSection(nil) }
            if listTag != tag { closeList(); html += "<\(tag)>"; listTag = tag }
            html += "<li>\(inline(item))</li>"
            continue
        }
        closeList()
        html += inSection ? "<p>\(inline(line))</p>" : "<p class=\"summary\">\(inline(line))</p>"
    }
    closeList()
    if inSection { html += "</section>" }
    return html
}

func notesSource(version: String, language: Language) -> String? {
    let url = notesDirectory.appendingPathComponent("\(version)\(language.fileSuffix).md")
    return try? String(contentsOf: url, encoding: .utf8)
}

// MARK: - Shared look

/// Tokens and release-block styles shared by the update window and the history
/// page, so a version looks the same in both places.
let releaseCSS = """
:root {
  color-scheme: light dark;
  --bg: #ffffff; --ink: #1d1d1f; --text: #3a3a3c; --muted: #86868b;
  --line: #e5e5ea; --soft: #f2f2f5;
  --new: \(brand.light); --improved: #6a4fd0; --fixed: #1c8a4a; --other: #6e6e73;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #1e1e20; --ink: #f5f5f7; --text: #d1d1d6; --muted: #8e8e93;
    --line: #38383c; --soft: #2a2a2e;
    --new: \(brand.dark); --improved: #b4a2ff; --fixed: #62d28c; --other: #aeaeb2;
  }
}
* { box-sizing: border-box; }
html { background: var(--bg); }
body {
  margin: 0;
  color: var(--text);
  font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "PingFang SC", "Helvetica Neue", sans-serif;
  -webkit-font-smoothing: antialiased;
  text-rendering: optimizeLegibility;
}
a { color: var(--new); text-underline-offset: 3px; }
h1, h2, h3 { margin: 0; }
.version { color: var(--ink); font-weight: 700; letter-spacing: -0.015em; }
.meta { margin: 2px 0 0; color: var(--muted); font-variant-numeric: tabular-nums; }
.summary { margin: 12px 0 0; color: var(--ink); }
section { --tone: var(--other); }
section.new { --tone: var(--new); }
section.improved { --tone: var(--improved); }
section.fixed { --tone: var(--fixed); }
.tag {
  display: inline-block;
  padding: 1px 9px 2px;
  border-radius: 999px;
  background: color-mix(in srgb, var(--tone) 14%, transparent);
  color: var(--tone);
  font-size: 11px;
  font-weight: 650;
  letter-spacing: 0.02em;
  line-height: 18px;
}
section ul, section ol { margin: 0; padding: 0; list-style: none; }
section ol { counter-reset: item; }
section li { position: relative; padding-left: 16px; }
section ul > li::before {
  content: "";
  position: absolute;
  left: 3px;
  top: 0.62em;
  width: 5px;
  height: 5px;
  border-radius: 50%;
  background: var(--tone);
}
section ol > li { counter-increment: item; padding-left: 20px; }
section ol > li::before {
  content: counter(item) ".";
  position: absolute;
  left: 0;
  color: var(--tone);
  font-weight: 600;
  font-variant-numeric: tabular-nums;
}
section p { margin: 8px 0 0; }
code {
  padding: 0 4px;
  border-radius: 4px;
  background: var(--soft);
  font: 0.9em/1.4 ui-monospace, SFMono-Regular, Menlo, monospace;
}
"""

// MARK: - Sparkle update window

let sparkleCSS = """
body { padding: 16px 20px 20px; font-size: 13px; line-height: 1.55; }
.version { font-size: 17px; line-height: 1.3; }
.meta { font-size: 11.5px; }
.summary { font-size: 13.5px; line-height: 1.5; }
section { margin-top: 16px; }
h3 { margin-bottom: 6px; }
section li { margin: 5px 0; }
"""

func sparkleDocument(_ release: Release, _ language: Language, _ notes: String) -> String {
    let meta = "Build \(release.build) · " + language.date(year: release.year, month: release.month, day: release.day)
    return """
    <!DOCTYPE html>
    <html lang="\(language.htmlLang)">
    <head>
    <meta charset="utf-8">
    <meta name="color-scheme" content="light dark">
    <title>\(appName) \(release.version)</title>
    <style>
    \(releaseCSS)
    \(sparkleCSS)
    </style>
    </head>
    <body>
    <article>
    <header>
    <h1 class="version">\(appName) \(release.version)</h1>
    <p class="meta"><time datetime="\(release.isoDate)">\(meta)</time></p>
    </header>
    \(renderNotes(notes))
    </article>
    </body>
    </html>

    """
}

// MARK: - Version history page

let historyCSS = """
body { font-size: 16px; line-height: 1.7; }
.page { width: min(720px, calc(100% - 44px)); margin-inline: auto; }
.top { display: flex; justify-content: space-between; align-items: baseline; gap: 16px; padding-block: 24px; }
.brand { color: var(--ink); font-size: 20px; font-weight: 700; letter-spacing: -0.03em; text-decoration: none; }
.top nav { display: flex; gap: 18px; font-size: 14px; }
.top nav a, .switch { color: var(--muted); text-decoration: none; }
.top nav a:hover, .switch:hover { color: var(--ink); }
.switch { padding: 0; border: 0; background: none; font: inherit; cursor: pointer; }
main { padding-block: 40px 72px; }
.title { color: var(--ink); font-size: clamp(40px, 9vw, 60px); line-height: 1.05; letter-spacing: -0.05em; }
.intro { margin: 16px 0 48px; color: var(--muted); font-size: 18px; }
.release { padding-block: 36px 40px; border-top: 1px solid var(--line); scroll-margin-top: 24px; }
.heading { display: flex; flex-wrap: wrap; align-items: center; gap: 8px 12px; }
.heading .version { font-size: 28px; line-height: 1.2; letter-spacing: -0.03em; }
.heading .version a { color: inherit; text-decoration: none; }
.current {
  padding: 1px 10px 2px;
  border-radius: 999px;
  background: var(--new);
  color: var(--bg);
  font-size: 12px;
  font-weight: 700;
}
.release .meta { font-size: 14px; }
.release .summary { font-size: 17px; }
.release section { margin-top: 22px; }
.release h3 { margin-bottom: 8px; }
.release .tag { font-size: 12px; line-height: 20px; }
.release li { margin: 7px 0; padding-left: 18px; }
footer { padding-block: 22px 42px; border-top: 1px solid var(--line); color: var(--muted); font-size: 14px; }
footer a { color: inherit; }
:focus-visible { outline: 2px solid var(--new); outline-offset: 3px; }
html:not([data-lang="en"]) [lang="en"].i18n,
html[data-lang="en"] [lang="zh-Hans"].i18n { display: none; }
@media (max-width: 520px) {
  main { padding-top: 28px; }
  .intro { margin-bottom: 36px; }
  .release { padding-block: 28px 32px; }
  .heading .version { font-size: 24px; }
}
"""

/// Both languages are rendered; the reader's system language picks one before
/// first paint, and the switch in the header flips it. Without script the page
/// stays Chinese, like the rest of the site.
let languageScript = """
(() => {
  const root = document.documentElement;
  const param = new URLSearchParams(location.search).get('lang');
  let stored = null;
  try { stored = localStorage.getItem('release-notes-lang'); } catch (_) {}
  const system = (navigator.languages || [navigator.language || '']).some((l) => /^zh/i.test(l)) ? 'zh' : 'en';
  root.dataset.lang = (param === 'en' || param === 'zh') ? param : (stored || system);
  root.lang = root.dataset.lang === 'en' ? 'en' : 'zh-CN';
  window.switchLanguage = () => {
    const next = root.dataset.lang === 'en' ? 'zh' : 'en';
    root.dataset.lang = next;
    root.lang = next === 'en' ? 'en' : 'zh-CN';
    try { localStorage.setItem('release-notes-lang', next); } catch (_) {}
  };
})();
"""

func both(_ tag: String, zh: String, en: String, className: String = "") -> String {
    let classes = className.isEmpty ? "i18n" : "i18n \(className)"
    return "<\(tag) class=\"\(classes)\" lang=\"zh-Hans\">\(zh)</\(tag)><\(tag) class=\"\(classes)\" lang=\"en\">\(en)</\(tag)>"
}

func historyDocument(_ releases: [Release], releasesPage: String) -> String {
    var articles = ""
    for (index, release) in releases.enumerated() {
        let anchor = "v\(release.version)"
        var body = ""
        for language in Language.allCases {
            let notes = notesSource(version: release.version, language: language)
                ?? notesSource(version: release.version, language: .en)
                ?? ""
            let current = index == 0
                ? "<span class=\"current\">\(language == .zh ? "当前版本" : "Current Version")</span>"
                : ""
            let date = language.date(year: release.year, month: release.month, day: release.day)
            body += """
            <div class="i18n" lang="\(language.htmlLang)">
            <div class="heading"><h2 class="version"><a href="#\(anchor)">Version \(release.version)</a></h2>\(current)</div>
            <p class="meta">Build \(release.build) · <time datetime="\(release.isoDate)">\(date)</time></p>
            \(renderNotes(notes))
            </div>

            """
        }
        articles += "<article class=\"release\" id=\"\(anchor)\">\n\(body)</article>\n"
    }

    return """
    <!doctype html>
    <html lang="zh-CN">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>\(appName) 版本历史 · Version History</title>
    <meta name="description" content="\(appName) 的版本更新记录。\(appName) release notes and version history.">
    <meta name="theme-color" content="#ffffff" media="(prefers-color-scheme: light)">
    <meta name="theme-color" content="#1e1e20" media="(prefers-color-scheme: dark)">
    <link rel="canonical" href="\(siteURL)updates.html">
    <script>
    \(languageScript)
    </script>
    <style>
    \(releaseCSS)
    \(historyCSS)
    </style>
    </head>
    <body>
    <div class="page">
    <header class="top">
    <a class="brand" href="./">\(appName)</a>
    <nav>
    <button class="switch" type="button" onclick="switchLanguage()">\(both("span", zh: "English", en: "中文"))</button>
    <a href="./">\(both("span", zh: "返回首页", en: "Home"))</a>
    </nav>
    </header>
    <main>
    \(both("h1", zh: "版本历史", en: "Version History", className: "title"))
    \(both("p", zh: "\(appName) 每个版本的变化。", en: "What changed in each version of \(appName).", className: "intro"))
    \(articles)
    </main>
    <footer><a href="\(releasesPage)">GitHub Releases</a></footer>
    </div>
    </body>
    </html>

    """
}

// MARK: - Appcast

func releases(fromAppcast url: URL) -> (list: [Release], releasesPage: String) {
    guard let document = try? XMLDocument(contentsOf: url, options: []) else {
        fail("cannot read appcast \(url.path)")
    }
    let months = ["Jan": 1, "Feb": 2, "Mar": 3, "Apr": 4, "May": 5, "Jun": 6,
                  "Jul": 7, "Aug": 8, "Sep": 9, "Oct": 10, "Nov": 11, "Dec": 12]
    let items = (try? document.nodes(forXPath: "//item")) ?? []
    let parsed: [Release] = items.compactMap { node in
        guard let item = node as? XMLElement else { return nil }
        func child(_ name: String) -> String? {
            item.elements(forName: name).first?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let version = child("sparkle:shortVersionString"),
              let build = child("sparkle:version"),
              let published = child("pubDate") else { return nil }
        // "Sun, 20 Sep 2026 05:24:15 +0900": the day as the publisher saw it.
        let parts = published.split(separator: " ")
        guard parts.count >= 4, let day = Int(parts[1]), let month = months[String(parts[2])],
              let year = Int(parts[3]) else { return nil }
        return Release(version: version, build: build, year: year, month: month, day: day)
    }
    // "https://github.com/<owner>/<repo>/releases/download/<tag>/<file>"
    let enclosure = (try? document.nodes(forXPath: "//item/enclosure/@url"))?.first?.stringValue ?? ""
    let releasesPage = enclosure.range(of: "/releases/download/").map {
        String(enclosure[..<$0.lowerBound]) + "/releases"
    } ?? siteURL
    let sorted = parsed.sorted {
        $0.version.compare($1.version, options: .numeric) == .orderedDescending
    }
    return (sorted, releasesPage)
}

// MARK: - Entry point

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "sparkle":
    guard arguments.count == 5 else {
        fail("usage: sparkle <version> <build> <yyyy-mm-dd> <out-dir>")
    }
    let dateParts = arguments[3].split(separator: "-").compactMap { Int($0) }
    guard dateParts.count == 3 else { fail("date must be yyyy-mm-dd") }
    let release = Release(
        version: arguments[1], build: arguments[2],
        year: dateParts[0], month: dateParts[1], day: dateParts[2]
    )
    let output = URL(fileURLWithPath: arguments[4], isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    guard notesSource(version: release.version, language: .en) != nil else {
        fail("missing Resources/ReleaseNotes/\(release.version).md")
    }
    for language in Language.allCases {
        guard let notes = notesSource(version: release.version, language: language) else { continue }
        let file = output.appendingPathComponent("\(appName)-\(release.version)\(language.fileSuffix).html")
        try sparkleDocument(release, language, notes).write(to: file, atomically: true, encoding: .utf8)
        print(file.path)
    }
case "history":
    guard arguments.count == 3 else { fail("usage: history <appcast.xml> <out-file>") }
    let feed = releases(fromAppcast: URL(fileURLWithPath: arguments[1]))
    guard !feed.list.isEmpty else { fail("the appcast lists no releases") }
    for release in feed.list where notesSource(version: release.version, language: .en) == nil {
        fail("missing Resources/ReleaseNotes/\(release.version).md")
    }
    let output = URL(fileURLWithPath: arguments[2])
    try historyDocument(feed.list, releasesPage: feed.releasesPage)
        .write(to: output, atomically: true, encoding: .utf8)
    print(output.path)
default:
    fail("usage: release-notes.swift sparkle|history …")
}
