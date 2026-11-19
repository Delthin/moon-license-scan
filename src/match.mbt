///|
struct CompiledRule {
  source : @rules.RuleSource
  words : Array[StringView]
  anchor : Int32
}

///|
priv struct Match {
  expression : String
  kind : String
  rule_id : String
  start_line : Int32
  end_line : Int32
  start_word : Int32
  end_word : Int32
}

///|
/// Reuse a scanner for repeated local scans without recompiling the corpus.
pub struct Scanner {
  priv rules : Array[CompiledRule]
  priv index : Map[StringView, Map[StringView, Array[Int32]]]
}

///|
pub fn Scanner::new() -> Scanner {
  let rules = []
  let index : Map[StringView, Map[StringView, Array[Int32]]] = Map([])
  for n, source in @rules.corpus() {
    let sequence = words(source.pattern).map(word => word.value)
    let anchor = source.anchor
    let first = sequence[anchor]
    let second = sequence[anchor + 1]
    let tails = match index.get(first) {
      Some(tails) => tails
      None => {
        let tails = Map([])
        index[first] = tails
        tails
      }
    }
    match tails.get(second) {
      Some(ids) => ids.push(n)
      None => tails[second] = [n]
    }
    rules.push({ source, words: sequence, anchor, })
  }
  { rules, index, }
}

///|
fn matches_at(rule : CompiledRule, input : Array[Word], start : Int32) -> Bool {
  for i in 0..<rule.words.length() {
    if input[start + i].value != rule.words[i] {
      return false
    }
  }
  true
}

///|
fn Scanner::body_matches(
  self : Scanner,
  input : Array[Word],
) -> (Array[Match], Bool) {
  let positions : Array[Array[Int32]?] = Array::make(self.rules.length(), None)
  for i in 0..<(input.length() - 1) {
    guard self.index.get(input[i].value) is Some(tails) &&
      tails.get(input[i + 1].value) is Some(ids) else {
      continue
    }
    for id in ids {
      if positions[id] is Some(starts) && starts.length() > 256 {
        continue
      }
      let rule = self.rules[id]
      let start = i - rule.anchor
      if start >= 0 &&
        start + rule.words.length() <= input.length() &&
        matches_at(rule, input, start) {
        match positions[id] {
          Some(starts) => starts.push(start)
          None => positions[id] = Some([start])
        }
      }
    }
  }
  // Apply the evidence cap in corpus order, independent of index discovery order.
  let out : Array[Match] = []
  for id, rule in self.rules {
    guard positions[id] is Some(starts) else { continue }
    for start in starts {
      if out.length() >= 256 {
        return (out, false)
      }
      let end = start + rule.words.length() - 1
      out.push({
        expression: rule.source.expression,
        kind: rule.source.kind,
        rule_id: rule.source.id,
        start_line: input[start].line,
        end_line: input[end].line,
        start_word: start,
        end_word: end,
      })
    }
  }
  (out, true)
}

///|
// GNU license appendices show a grant with an unfilled copyright holder.
// Ignore only the adjacent grant; a later real grant in the same file remains evidence.
fn suppress_gnu_examples(text : String, candidates : Array[Match]) -> Array[Match] {
  fn gnu_grant(hit : Match) -> Bool {
    hit.kind == "fragment" && (
      hit.expression.has_prefix("GPL-") || hit.expression.has_prefix("LGPL-") ||
      hit.expression.has_prefix("AGPL-")
    )
  }
  if !text.contains("<year>") || !candidates.any(gnu_grant) {
    return candidates
  }
  let template_lines : Set[Int32] = Set([])
  each_line(text, (line, raw) => {
    if raw.contains("<year>") &&
      (raw.contains("<name of author>") || raw.contains("<name of copyright holder>")) {
      template_lines.add(line)
    }
  })
  candidates.filter(hit => {
    if gnu_grant(hit) {
      for offset in 1..<=4 {
        if template_lines.contains(hit.start_line - offset) {
          return false
        }
      }
    }
    true
  })
}

///|
fn consolidate(candidates : Array[Match]) -> (Array[Match], Bool) {
  candidates.sort_by((a, b) => {
    if a.start_word != b.start_word {
      a.start_word - b.start_word
    } else if a.end_word != b.end_word {
      b.end_word - a.end_word
    } else {
      a.rule_id.compare(b.rule_id)
    }
  })
  let out : Array[Match] = []
  let mut ambiguous = false
  for item in candidates {
    let mut redundant = false
    for kept in out {
      if item.start_word > kept.end_word || item.end_word < kept.start_word {
        continue
      }
      if item.expression == kept.expression {
        redundant = true
        break
      }
      if item.start_word >= kept.start_word &&
        item.end_word <= kept.end_word &&
        (
          item.kind == "ambiguous" ||
          (kept.kind == "text" && item.kind == "fragment")
        ) {
        redundant = true
        break
      }
      if item.start_word == kept.start_word && item.end_word == kept.end_word {
        ambiguous = true
      }
    }
    if !redundant {
      if item.kind == "ambiguous" {
        ambiguous = true
      } else {
        out.push(item)
      }
    }
  }
  (out, ambiguous)
}

///|
fn project_license(path : String) -> Bool {
  if path.contains("/") {
    return false
  }
  let name = path.to_lower()
  for exact in ["license", "licence", "copying"] {
    if name == exact ||
      name.has_prefix(exact + ".") ||
      name.has_prefix(exact + "-") {
      return true
    }
  }
  false
}

///|
fn Scanner::find(
  self : Scanner,
  path : String,
  text : String,
  maximum : Int32,
) -> (Array[Finding], Array[String], Bool) {
  let input = words(text)
  let (found, body_complete) = self.body_matches(input)
  let (matched, ambiguous) = consolidate(suppress_gnu_examples(text, found))
  let (explicit, review, explicit_complete) = spdx_labels(text)
  if ambiguous {
    review.push("ambiguous_rule_match")
  }
  let result : Array[Finding] = []
  let line_fingerprints : Map[(String, String, String), Int32] = Map([])
  let file_scope = if project_license(path) { "project" } else { "file" }
  fn add(hit : Match, fingerprint : String) -> Unit {
    if result.length() >= maximum {
      return
    }
    let key = (hit.kind, hit.expression, fingerprint)
    let n = line_fingerprints.get(key).unwrap_or(0)
    line_fingerprints[key] = n + 1
    let id = hash_text(
      Json((path, hit.kind, hit.expression, fingerprint, n)).stringify(),
    )
    result.push({
      id,
      expression: hit.expression,
      kind: hit.kind,
      scope: file_scope,
      rule_id: hit.rule_id,
      start_line: hit.start_line,
      end_line: hit.end_line,
      evidence_sha256: fingerprint,
    })
  }
  for hit in explicit {
    add(hit, hash_text(hit.expression))
  }
  for hit in matched {
    let content = StringBuilder()
    for i in hit.start_word..<=hit.end_word {
      if i != hit.start_word {
        content.write_char(' ')
      }
      content.write_stringview(input[i].value)
    }
    add(hit, hash_text(content.to_string()))
  }
  if result.is_empty() &&
    file_scope == "project" &&
    body_complete &&
    explicit_complete {
    review.push("unrecognized_project_license")
  }
  let mut first_expression = ""
  for hit in result {
    if first_expression == "" {
      first_expression = hit.expression
    }
    if first_expression != hit.expression {
      review.push("multiple_license_indications")
      break
    }
  }
  result.sort_by((a, b) => {
    if a.start_line != b.start_line {
      a.start_line - b.start_line
    } else if a.end_line != b.end_line {
      a.end_line - b.end_line
    } else {
      a.id.compare(b.id)
    }
  })
  (
    result,
    review,
    body_complete &&
    explicit_complete &&
    matched.length() + explicit.length() <= maximum,
  )
}
