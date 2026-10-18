import Foundation
/// Heuristic discovery only. It never evaluates JavaScript or changes source code.
struct AssetStrings {
    static func urls(_ source:String, document:URL) -> [URL] {
        let chars=Array(source); var i=0; var result:[URL]=[]
        let extensions:Set<String>=["mp3","m4a","mp4","ogg","wav","jpg","jpeg","png","gif","webp","svg","woff","woff2","ttf","css","js","json","wasm","pdf"]
        while i<chars.count {
            if i+1<chars.count,chars[i]=="/",chars[i+1]=="/" { while i<chars.count && chars[i] != "\n" { i+=1 }; continue }
            if i+1<chars.count,chars[i]=="/",chars[i+1]=="*" { i+=2; while i+1<chars.count && !(chars[i]=="*" && chars[i+1]=="/") { i+=1 }; i=min(i+2,chars.count); continue }
            guard chars[i]=="\"" || chars[i]=="'" else { i+=1; continue }
            let quote=chars[i]; i+=1; var value=""
            while i<chars.count && chars[i] != quote {
                if chars[i]=="\\",i+1<chars.count { i+=1; value.append(chars[i]); i+=1 } else { value.append(chars[i]); i+=1 }
            }
            if i<chars.count { i+=1 }
            guard !value.contains(where:{$0.isWhitespace}), !value.contains("${"), let url=URL(string:value,relativeTo:document)?.absoluteURL, ["http","https"].contains(url.scheme), extensions.contains(url.pathExtension.lowercased()) else { continue }
            result.append(url)
        }
        return result
    }
}
