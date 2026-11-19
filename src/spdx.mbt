///|
fn valid_id_part(value : StringView) -> Bool {
  if value.length() == 0 || !ascii_word(value[0]) {
    return false
  }
  for i in 1..<value.length() {
    let unit = value[i]
    if !ascii_word(unit) && unit != 45 && unit != 46 {
      return false
    }
  }
  true
}

///|
fn valid_spdx_id(value : StringView, exception : Bool) -> Bool {
  if value == "AND" || value == "OR" || value == "WITH" {
    return false
  }
  if !exception && value.has_prefix("DocumentRef-") {
    return match value.split(":").collect() {
      [doc, license] =>
        doc.length() > 12 &&
        valid_id_part(doc[12:]) &&
        license.has_prefix("LicenseRef-") &&
        license.length() > 11 &&
        valid_id_part(license[11:])
      _ => false
    }
  }
  if value.has_prefix("LicenseRef-") {
    return !exception && value.length() > 11 && valid_id_part(value[11:])
  }
  if !exception && value.has_suffix("+") {
    valid_id_part(value[:value.length() - 1])
  } else {
    valid_id_part(value)
  }
}

///|
fn expression_end(
  tokens : Array[StringView],
  first : Int32,
  depth : Int32,
) -> Int32 {
  if depth > 16 {
    return -1
  }
  let mut i = first
  for ;; {
    match tokens.get(i) {
      Some("(") => {
        i = expression_end(tokens, i + 1, depth + 1)
        if i < 0 || tokens.get(i) != Some(")") {
          return -1
        }
        i += 1
      }
      Some(id) if valid_spdx_id(id, false) => {
        i += 1
        if tokens.get(i) == Some("WITH") {
          match tokens.get(i + 1) {
            Some(exception) if valid_spdx_id(exception, true) => i += 2
            _ => return -1
          }
        }
      }
      _ => return -1
    }
    match tokens.get(i) {
      Some("AND") | Some("OR") => i += 1
      _ => return i
    }
  }
}

///|
fn spdx_expression(text : StringView) -> String? {
  if text.length() == 0 || text.length() > 512 {
    return None
  }
  let tokens : Array[StringView] = []
  let mut start = 0
  for i in 0..<text.length() {
    let ch = text[i]
    if ch == 32 || ch == 9 || ch == 40 || ch == 41 {
      if start < i {
        tokens.push(text[start:i])
      }
      if ch == 40 || ch == 41 {
        tokens.push(text[i:i + 1])
      }
      start = i + 1
    }
  }
  if start < text.length() {
    tokens.push(text[start:])
  }
  if expression_end(tokens, 0, 0) != tokens.length() {
    return None
  }
  let canonical = StringBuilder()
  for i, token in tokens {
    if i > 0 && tokens[i - 1] != "(" && token != ")" {
      canonical.write_char(' ')
    }
    canonical.write_stringview(token)
  }
  let normalized = canonical.to_string()
  if normalized.length() <= 512 {
    Some(normalized)
  } else {
    None
  }
}

///|
fn spdx_labels(text : String) -> (Array[Match], Bool, Bool) {
  let labels : Array[Match] = []
  let mut invalid = false
  let mut complete = true
  let marker = "SPDX-License-Identifier:"
  each_line(text, (line, raw) => {
    let mut value = if line == 1 && raw.has_prefix("\u{FEFF}") {
      raw[1:].trim()
    } else {
      raw.trim()
    }
    for prefix in ["//", "/*", "<!--", "--", "#", "*", ";", "%", "!"] {
      if value.has_prefix(prefix) {
        value = value[prefix.length():].trim()
        break
      }
    }
    if value.has_prefix(marker) {
      value = value[marker.length():].trim()
      for suffix in ["*/", "-->"] {
        if value.has_suffix(suffix) {
          value = value[:value.length() - suffix.length()].trim()
          break
        }
      }
      match spdx_expression(value) {
        Some(expression) =>
          if labels.length() < 256 {
            labels.push({
              expression,
              kind: "spdx",
              rule_id: "spdx-label",
              start_line: line,
              end_line: line,
              start_word: -1,
              end_word: -1,
            })
          } else {
            complete = false
          }
        None => invalid = true
      }
    }
  })
  (labels, invalid, complete)
}
