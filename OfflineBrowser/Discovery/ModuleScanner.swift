import Foundation

/// Reads module specifiers outside comments/ordinary strings, never rewrites arbitrary JS strings.
struct ModuleScanner {
    static func transform(_ source: String, base: URL, mapper: URLMapper) -> (String,[URL]) {
        let c=Array(source); var i=0; var output=""; var urls:[URL]=[]; var module=false; var expect=false; var regexAllowed=true
        while i<c.count {
            if i+1<c.count, c[i]=="/", c[i+1]=="/" { repeat { output.append(c[i]); i+=1 } while i<c.count && c[i] != "\n"; continue }
            if i+1<c.count, c[i]=="/", c[i+1]=="*" { repeat { output.append(c[i]); i+=1 } while i<c.count && !(i>1 && c[i-2]=="*" && c[i-1]=="/"); continue }
            if c[i]=="/",regexAllowed {
                output.append(c[i]); i+=1; var escaped=false; var characterClass=false
                while i<c.count {
                    let ch=c[i]; output.append(ch); i+=1
                    if escaped { escaped=false; continue }
                    if ch=="\\" { escaped=true; continue }
                    if ch=="[" { characterClass=true } else if ch=="]" { characterClass=false }
                    else if ch=="/",!characterClass { while i<c.count,c[i].isLetter { output.append(c[i]); i+=1 }; break }
                    if ch=="\n" { break }
                }
                regexAllowed=false; continue
            }
            if c[i]=="\"" || c[i]=="'" || c[i]=="`" {
                let quote=c[i]; output.append(quote); i+=1; var value=""; var escaped=false
                while i<c.count && (c[i] != quote || escaped) { let ch=c[i]; value.append(ch); i+=1; if escaped { escaped=false } else if ch=="\\" { escaped=true } }
                if expect, quote != "`", !value.contains("\\"), let u=URL(string:value,relativeTo:base)?.absoluteURL, ["http","https"].contains(u.scheme), value.hasPrefix(".") || value.hasPrefix("/") || value.contains("://") { urls.append(u); output += mapper.local(u).absoluteString } else { output += value }
                if i<c.count { output.append(quote); i+=1 }; expect=false; regexAllowed=false; continue
            }
            if c[i].isLetter || c[i]=="_" || c[i]=="$" {
                let begin=i; repeat { i+=1 } while i<c.count && (c[i].isLetter || c[i].isNumber || c[i]=="_" || c[i]=="$")
                let word=String(c[begin..<i]); output += word
                let before=output.dropLast(word.count).last(where:{ !$0.isWhitespace })
                let after=c[i...].first(where:{ !$0.isWhitespace })
                if word=="import",before != ".",after != ":" { module=true; expect=true }
                else if word=="export",before != ".",after != ":" { module=true; expect=false }
                else if word=="default",module { module=false; expect=false }
                else if word=="from" && module { expect=true }
                else if !["type","as"].contains(word) { expect=false }
                regexAllowed=["return","throw","case","yield","await","else","do","in","of"].contains(word)
                continue
            }
            if (c[i]=="(" || c[i]=="."),module,expect { module=false }
            if c[i]==";" { module=false; expect=false }
            if !c[i].isWhitespace { regexAllowed = ![")","]"].contains(c[i]) && !c[i].isNumber }
            output.append(c[i]); i+=1
        }
        return (output,urls)
    }
}
