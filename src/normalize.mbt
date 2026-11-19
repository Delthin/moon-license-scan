///|
priv struct Word {
  value : StringView
  line : Int32
}

///|
fn ascii_word(code : UInt16) -> Bool {
  (code >= 65 && code <= 90) ||
  (code >= 97 && code <= 122) ||
  (code >= 48 && code <= 57)
}

///|
fn words(text : String) -> Array[Word] {
  let output : Array[Word] = []
  let mut line = 1
  let mut start = -1
  for i in 0..<text.length() {
    let code = text[i]
    if ascii_word(code) {
      if start < 0 {
        start = i
      }
    } else {
      if start >= 0 {
        output.push({ value: text[start:i].to_lower(), line, })
        start = -1
      }
      if code == 10 ||
        (code == 13 && (i + 1 == text.length() || text[i + 1] != 10)) {
        line += 1
      }
    }
  }
  if start >= 0 {
    output.push({ value: text[start:].to_lower(), line, })
  }
  output
}

///|
fn each_line(text : String, visit : (Int32, StringView) -> Unit) -> Unit {
  let mut start = 0
  let mut line = 1
  for i in 0..<text.length() {
    let code = text[i]
    if code == 13 || (code == 10 && (i == 0 || text[i - 1] != 13)) {
      visit(line, text[start:i])
      line += 1
      start = if code == 13 && i + 1 < text.length() && text[i + 1] == 10 {
        i + 2
      } else {
        i + 1
      }
    }
  }
  if start < text.length() {
    visit(line, text[start:])
  }
}

///|
fn excerpt(text : String, start : Int32, end : Int32) -> String? {
  let result = StringBuilder()
  let mut seen = 0
  let mut size = 0
  each_line(text, (line, segment) => {
    if line >= start && line <= end && size <= 32768 {
      size += segment.length() + 1
      if size <= 32768 {
        if seen > 0 {
          result.write_char('\n')
        }
        result.write_stringview(segment)
        seen += 1
      }
    }
  })
  if seen == end - start + 1 && seen > 0 {
    Some(result.to_string())
  } else {
    None
  }
}
