import Foundation
import SwiftSoup

struct DocumentRewriter {
    let mapper: URLMapper
    func resolve(_ value: String, base: URL) -> URL? {
        guard let url = URL(string:value,relativeTo:base)?.absoluteURL, ["http","https"].contains(url.scheme) else { return nil }
        return url
    }
    func html(_ data: Data, base: URL) throws -> (Data, [URL], [String]) {
        guard let text = String(data:data,encoding:.utf8) else { throw ArchiveError.unsupported("HTML-Zeichencodierung wird nicht unterstützt.") }
        let doc = try SwiftSoup.parse(text, base.absoluteString)
        _ = doc.outputSettings().prettyPrint(pretty:false)
        let actualBase = try doc.select("base[href]").first().flatMap { resolve(try $0.attr("href"), base:base) } ?? base
        var discovered: [URL] = []; var issues: [String] = []
        for element in try doc.select("[href], [src], [action], [poster], [data]").array() {
            for attribute in ["href","src","action","poster","data"] where element.hasAttr(attribute) {
                let value = try element.attr(attribute)
                if let u = resolve(value,base:actualBase) {
                    if element.tagName() != "form" { discovered.append(u) }
                    try element.attr(attribute,mapper.local(u).absoluteString)
                } else if value.lowercased().hasPrefix("javascript:"), !Self.isNoOpJavaScript(value) { issues.append("JavaScript-Navigation muss zur Laufzeit geprüft werden.") }
            }
            if element.tagName() == "base" { try element.attr("href",mapper.local(actualBase).absoluteString) }
        }
        for el in try doc.select("[srcset]").array() {
            let parts = try el.attr("srcset").split(separator:",").map { item -> String in
                let words = item.split(whereSeparator: { $0.isWhitespace }); guard let first = words.first, let u = resolve(String(first),base:actualBase) else { return String(item) }
                discovered.append(u); return ([mapper.local(u).absoluteString] + words.dropFirst().map(String.init)).joined(separator:" ")
            }
            try el.attr("srcset",parts.joined(separator:", "))
        }
        for el in try doc.select("style, [style]").array() {
            if el.tagName() == "style" { let result = css(Data(try el.html().utf8),base:actualBase); discovered += result.1; try el.html(String(decoding:result.0,as:UTF8.self)) }
            if el.hasAttr("style") { let result = css(Data(try el.attr("style").utf8),base:actualBase); discovered += result.1; try el.attr("style",String(decoding:result.0,as:UTF8.self)) }
        }
        // A site may tighten its CSP. We keep it and report incompatibility rather than erase it.
        for el in try doc.select("meta[http-equiv]").array() where (try el.attr("http-equiv")).lowercased() == "refresh" { issues.append("Automatischer Seitenwechsel wird nicht unterstützt."); try el.remove() }
        if try doc.select("object, embed").size() > 0 { issues.append("Eingebettete Plugins werden nicht unterstützt.") }
        // The generated static kit has no original JavaScript to reveal its
        // collapsed Jimdo navigation. Keep its saved links directly accessible.
        if try doc.select("header .offline-menu").size() > 0, try doc.select("header .G4Yk_").size() > 0 {
            try doc.select("header .offline-menu").remove()
            try doc.head()?.append("""
            <style id="offline-visible-navigation">
            header .DyyGf { padding-right:0!important; flex-wrap:wrap!important; }
            header .G4Yk_ { display:block!important; position:relative!important; left:auto!important; right:auto!important; bottom:auto!important; width:100%!important; max-width:100%!important; height:auto!important; opacity:1!important; visibility:visible!important; transform:none!important; overflow:visible!important; background:transparent!important; }
            header .G4Yk_ .bEi0A { width:100%!important; padding:8px 0!important; }
            header .G4Yk_ ul { display:flex!important; flex-wrap:wrap!important; gap:12px!important; padding:8px 16px!important; margin:0!important; list-style:none!important; }
            header .G4Yk_ li, header .G4Yk_ .ZuOGq { display:block!important; width:auto!important; }
            </style>
            """)
        }
        return (Data(try doc.outerHtml().utf8),discovered,issues)
    }
    static func isNoOpJavaScript(_ value: String) -> Bool {
        let compact = value.lowercased().filter { !$0.isWhitespace }
        return ["javascript:void(0)", "javascript:void(0);", "javascript:void0", "javascript:void0;"].contains(compact)
    }
    func links(_ data: Data, base: URL) throws -> [URL] { try html(data,base:base).1 }
    func css(_ data: Data, base: URL) -> (Data,[URL]) {
        let input = Array(String(decoding:data,as:UTF8.self)); var output = ""; var urls: [URL] = []; var i = 0
        while i < input.count {
            if i+1 < input.count, input[i] == "/", input[i+1] == "*" {
                repeat { output.append(input[i]); i += 1 } while i < input.count && !(i > 1 && input[i-2] == "*" && input[i-1] == "/")
                continue
            }
            // Ordinary CSS strings (e.g. content:"url(...)") are not resource URLs.
            if input[i]=="\"" || input[i]=="'" {
                let quote=input[i]; output.append(quote); i+=1
                while i<input.count { let ch=input[i]; output.append(ch); i+=1
                    if ch=="\\",i<input.count { output.append(input[i]); i+=1 } else if ch==quote { break }
                }
                continue
            }
            let remaining = String(input[i..<min(i+8,input.count)]).lowercased()
            let isURL = remaining.hasPrefix("url(")
            let isImport = remaining.hasPrefix("@import")
            if isURL || isImport {
                let prefix = isURL ? 4 : 7; output += String(input[i..<min(i+prefix,input.count)]); i += prefix
                while i < input.count && input[i].isWhitespace { output.append(input[i]); i += 1 }
                if isImport, i < input.count, input[i] != "\"", input[i] != "'" { continue }
                let quote: Character? = i < input.count && ["\"","'"].contains(input[i]) ? input[i] : nil
                if let q = quote { output.append(q); i += 1 }
                var value = ""
                while i < input.count && input[i] != (quote ?? ")") {
                    if input[i] == "\\", i+1 < input.count {
                        i+=1
                        if input[i].isHexDigit {
                            var hex=""; while i<input.count,hex.count<6,input[i].isHexDigit { hex.append(input[i]); i+=1 }
                            if let code=UInt32(hex,radix:16),let scalar=Unicode.Scalar(code) { value.append(Character(scalar)) }
                            if i<input.count,input[i].isWhitespace { i+=1 }
                        } else if input[i]=="\n" || input[i]=="\r" { i+=1 }
                        else { value.append(input[i]); i+=1 }
                    } else { value.append(input[i]); i += 1 }
                }
                if let u = resolve(value.trimmingCharacters(in:.whitespacesAndNewlines),base:base) { urls.append(u); output += mapper.local(u).absoluteString } else { output += value }
                if i < input.count { output.append(input[i]); i += 1 }
            } else { output.append(input[i]); i += 1 }
        }
        return (Data(output.utf8),urls)
    }
}
