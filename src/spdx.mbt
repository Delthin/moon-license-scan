///|
fn reference_part(value : StringView) -> Bool {
  if value.is_empty() {
    return false
  }
  for i in 0..<value.length() {
    let unit = value[i]
    if !ascii_word(unit) && unit != 45 && unit != 46 {
      return false
    }
  }
  true
}

///|
fn valid_id_part(value : StringView) -> Bool {
  !value.is_empty() && ascii_word(value[0]) && reference_part(value)
}

///|
fn valid_spdx_id(value : StringView, exception : Bool) -> Bool {
  if value == "AND" || value == "OR" || value == "WITH" {
    return false
  }
  if !exception && value.has_prefix("DocumentRef-") {
    return match value.split_once(":") {
      Some((doc, license)) =>
        reference_part(doc[12:]) && license.has_prefix("LicenseRef-") &&
        reference_part(license[11:])
      None => false
    }
  }
  if value.has_prefix("LicenseRef-") {
    return !exception && reference_part(value[11:])
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
  check : (Int32, Bool) -> Unit,
) -> Int32 {
  if depth > 16 {
    return -1
  }
  let mut i = first
  for ;; {
    match tokens.get(i) {
      Some("(") => {
        i = expression_end(tokens, i + 1, depth + 1, check)
        if i < 0 || tokens.get(i) != Some(")") {
          return -1
        }
        i += 1
      }
      Some(id) if valid_spdx_id(id, false) => {
        check(i, false)
        i += 1
        if tokens.get(i) == Some("WITH") {
          match tokens.get(i + 1) {
            Some(exception) if valid_spdx_id(exception, true) => {
              check(i + 1, true)
              i += 2
            }
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
fn spdx_parse(text : StringView, checked : Bool) -> (String?, Array[String]) {
  if text.is_empty() || text.length() > 512 {
    return (None, ["invalid_spdx_label"])
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
  let flags : Array[String] = []
  let canonical : Map[Int32, String] = Map([])
  fn flag(reason : String) -> Unit {
    if !flags.contains(reason) { flags.push(reason) }
  }
  fn check(i : Int32, exception : Bool) -> Unit {
    if !checked { return }
    let token = tokens[i]
    if !exception && (token.has_prefix("LicenseRef-") || token.has_prefix("DocumentRef-")) {
      flag("unresolved_license_ref")
      return
    }
    let plus = token.has_suffix("+")
    let name = if plus { token[:token.length() - 1] } else { token }
    match @spdx_catalog.lookup(name, exception) {
      Some((name, deprecated)) => {
        if deprecated { flag("deprecated_spdx_id") }
        canonical[i] = if plus { name + "+" } else { name }
      }
      None => flag("unknown_spdx_id")
    }
  }
  if expression_end(tokens, 0, 0, check) != tokens.length() {
    return (None, ["invalid_spdx_label"])
  }
  if flags.contains("unknown_spdx_id") {
    return (None, flags)
  }
  let output = StringBuilder()
  for i, token in tokens {
    if i > 0 && tokens[i - 1] != "(" && token != ")" {
      output.write_char(' ')
    }
    match canonical.get(i) {
      Some(value) => output.write_string(value)
      None => output.write_stringview(token)
    }
  }
  let normalized = output.to_string()
  if normalized.length() <= 512 {
    (Some(normalized), flags)
  } else {
    (None, ["invalid_spdx_label"])
  }
}

///|
fn spdx_expression(text : StringView) -> String? {
  // Previously serialized reports can be parsed without applying today's catalog.
  spdx_parse(text, false).0
}

///|
fn spdx_labels(text : String) -> (Array[Match], Array[String], Bool) {
  let labels : Array[Match] = []
  let flags : Array[String] = []
  let mut complete = true
  let marker = "SPDX-License-Identifier:"
  each_line(text, (line, raw) => {
    let mut value = if line == 1 && raw.has_prefix("\u{FEFF}") {
      raw[1:].trim()
    } else {
      raw.trim()
    }
    for prefix in ["//", "/*", "<!--", "(*", "--", "#", "*", ";", "%", "!"] {
      if value.has_prefix(prefix) {
        value = value[prefix.length():].trim()
        break
      }
    }
    if value.has_prefix(marker) {
      value = value[marker.length():].trim()
      for suffix in ["*/", "-->", "*)"] {
        if value.has_suffix(suffix) {
          value = value[:value.length() - suffix.length()].trim()
          break
        }
      }
      let (expression, warnings) = spdx_parse(value, true)
      for warning in warnings {
        if !flags.contains(warning) { flags.push(warning) }
      }
      if expression is Some(expression) {
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
      }
    }
  })
  (labels, flags, complete)
}
