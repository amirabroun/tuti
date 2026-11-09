import Foundation

/// Breaks a finalized dictation into paragraphs: a blank line after every `every` sentence
/// enders. Pure and deterministic — the locked text never goes back through the LLM, and the
/// clean pass has already punctuated everything.
func paragraphs(_ text: String, every endersPerBreak: Int = 3) -> String {
    let chars = Array(text)
    var out = ""
    var enders = 0
    var previousDot = false
    var afterBreak = false  // swallow the whitespace that followed the inserted break
    for (i, ch) in chars.enumerated() {
        if afterBreak {
            if ch.isWhitespace { continue }
            afterBreak = false
        }
        let isDot = ch == "." || ch == "…"
        if isDot {
            let prev = i > 0 ? chars[i - 1] : nil
            let next = i + 1 < chars.count ? chars[i + 1] : nil
            // a run of dots is one end, and "3.5" is no end at all
            if previousDot || (ch == "." && prev?.isNumber == true && next?.isNumber == true) {
                out.append(ch)
                continue
            }
            previousDot = true
        } else {
            previousDot = false
        }
        if isDot || ch == "!" || ch == "?" || ch == "؟" {
            enders += 1
            out.append(ch)
            if enders % endersPerBreak == 0 {
                out.append("\n\n")
                afterBreak = true
            }
        } else {
            out.append(ch)
        }
    }
    return out.trimmingCharacters(in: .whitespacesAndNewlines)
}
