///|
fn report_integers(value : Json) -> Unit raise ScanError {
  match value {
    Number(_, repr=Some(token)) =>
      if token.contains(".") || token.contains("e") || token.contains("E") {
        raise InvalidInput("report numbers must be integers")
      }
    Array(items) =>
      for item in items {
        report_integers(item)
      }
    Object(fields) =>
      for _, item in fields {
        report_integers(item)
      }
    _ => ()
  }
}

///|
fn report_sha256(value : String) -> Bool {
  if value.length() != 64 {
    return false
  }
  for i in 0..<value.length() {
    let ch = value[i]
    if !((ch >= 48 && ch <= 57) || (ch >= 97 && ch <= 102)) {
      return false
    }
  }
  true
}

///|
fn fully_scanned(file : FileResult) -> Bool {
  file.status == "scanned" || file.status == "review"
}

///|
fn validate_report(report : Report) -> Unit raise ScanError {
  if report.schema_version != schema_version {
    raise InvalidInput("unsupported report schema")
  }
  validate_options(report.options)
  if !valid_id_part(report.rules_version[:]) ||
    report.rules_version.length() > 128 ||
    report.entries < report.files.length() ||
    report.entries > report.options.max_entries ||
    report.bytes_read < 0 ||
    report.bytes_read > report.options.max_total_bytes ||
    (
      !report.directory &&
      (
        report.entries > 1 ||
        (report.enumeration_complete && report.files.length() != 1)
      )
    ) {
    raise InvalidInput("invalid report counts or rules version")
  }
  for diagnostic in report.diagnostics {
    if diagnostic == "" || diagnostic.length() > 1024 {
      raise InvalidInput("invalid report diagnostic")
    }
  }
  let paths : Map[String, Unit] = Map([])
  let ids : Map[String, Unit] = Map([])
  let mut bytes = 0
  let mut findings = 0
  for file in report.files {
    if !relative_path(file.path) ||
      (!report.directory && file.path.contains("/")) ||
      paths.contains(file.path) {
      raise InvalidInput("invalid or duplicate report path")
    }
    paths[file.path] = ()
    if file.bytes < 0 ||
      file.bytes > report.options.max_file_bytes + 1 ||
      file.bytes > report.bytes_read - bytes ||
      file.findings.length() > 256 ||
      file.findings.length() > report.options.max_findings - findings {
      raise InvalidInput("invalid file counts in report")
    }
    bytes += file.bytes
    findings += file.findings.length()
    match (file.status, file.reason, file.sha256) {
      ("skipped", Some(reason), None) => {
        if !file.findings.is_empty() ||
          !file.review.is_empty() ||
          (reason == "excluded") != report.options.excludes(file.path) ||
          (
            report.enumeration_complete &&
            ["directory_unreadable", "entry_limit", "unreadable"].contains(
              reason,
            )
          ) {
          raise InvalidInput("invalid skipped file record")
        }
        match reason {
          "excluded"
          | "directory_unreadable"
          | "read_failed"
          | "finding_limit"
          | "entry_limit"
          | "link"
          | "other"
          | "unreadable" =>
            if file.bytes != 0 {
              raise InvalidInput("invalid skipped file byte count")
            }
          "file_byte_limit" =>
            if file.bytes != report.options.max_file_bytes + 1 {
              raise InvalidInput("invalid file limit record")
            }
          "total_byte_limit" | "binary" | "invalid_utf8" => ()
          _ => raise InvalidInput("invalid skipped file reason")
        }
      }
      ("scanned" | "review", None, Some(digest))
      | ("partial", Some("finding_limit"), Some(digest)) =>
        if report.options.excludes(file.path) ||
          !report_sha256(digest) ||
          file.bytes > report.options.max_file_bytes ||
          (file.status == "scanned" && !file.review.is_empty()) ||
          (file.status == "review" && file.review.is_empty()) {
          raise InvalidInput("invalid scanned file record")
        }
      _ => raise InvalidInput("invalid report file status")
    }
    for note in file.review {
      if note == "" || note.length() > 1024 {
        raise InvalidInput("invalid file review reason")
      }
    }
    let scope = if project_license(file.path) { "project" } else { "file" }
    for hit in file.findings {
      if !report_sha256(hit.id) ||
        !report_sha256(hit.evidence_sha256) ||
        ids.contains(hit.id) ||
        hit.scope != scope ||
        hit.start_line < 1 ||
        hit.end_line < hit.start_line ||
        hit.end_line > file.bytes ||
        spdx_expression(hit.expression[:]) != Some(hit.expression) ||
        hit.rule_id.length() > 128 ||
        !valid_id_part(hit.rule_id[:]) {
        raise InvalidInput("invalid or duplicate report finding")
      }
      match hit.kind {
        "spdx" =>
          if hit.rule_id != "spdx-label" || hit.start_line != hit.end_line {
            raise InvalidInput("invalid SPDX finding")
          }
        "text" | "fragment" => ()
        _ => raise InvalidInput("invalid finding kind")
      }
      ids[hit.id] = ()
    }
  }
  if report.enumeration_complete && bytes != report.bytes_read {
    raise InvalidInput("report byte total does not match file records")
  }
}

///|
/// Import a versioned scan snapshot for comparison. Source text is never read.
pub fn parse_report(text : String) -> Report raise {
  if text.length() > report_limit ||
    @utf8.encode(text[:]).length() > report_limit {
    raise LimitExceeded("report exceeds 16 MiB")
  }
  let json = @json.parse(
    text[:],
    max_nesting_depth=16,
    reject_duplicate_keys=true,
    preserve_number_repr=true,
  ) catch {
    _ => raise InvalidInput("invalid report JSON")
  }
  report_integers(json)
  let report : Report = @json.from_json(json) catch {
    _ => raise InvalidInput("invalid report structure")
  }
  validate_report(report)
  report
}

///|
fn comparison_block(
  report : Report,
  files : Map[String, FileResult],
  path : String,
) -> String? {
  if report.options.excludes(path) {
    return Some("excluded")
  }
  if files.get(path) is Some(file) {
    return if fully_scanned(file) {
      None
    } else {
      Some(file.reason.unwrap_or(file.status))
    }
  }
  if !report.directory {
    return Some("outside_single_file_scope")
  }
  if !report.enumeration_complete {
    return Some("enumeration_incomplete")
  }
  let mut parent = path[:]
  while parent.rev_split_once("/") is Some((ancestor, _)) {
    if files.get(ancestor.to_owned()) is Some(file) && !fully_scanned(file) {
      return Some("ancestor_not_scanned")
    }
    parent = ancestor
  }
  None
}

///|
fn evidence_json(path : String, hit : Finding) -> Json {
  { "path": Json(path), "finding": Json(hit) }
}

///|
fn compare_path(
  path : String,
  before : Array[Finding],
  after : Array[Finding],
  added : Array[Json],
  removed : Array[Json],
  changed : Array[Json],
  unchanged : Array[Json],
) -> Unit {
  let exact : Map[(String, String, String), Array[Finding]] = Map([])
  for i in 0..<after.length() {
    let hit = after[after.length() - 1 - i]
    exact
    .get_or_init((hit.kind, hit.expression, hit.evidence_sha256), () => [])
    .push(hit)
  }
  let kept : Map[String, Unit] = Map([])
  let unmatched_before : Map[(String, String), Array[Finding]] = Map([])
  let unmatched_after : Map[(String, String), Array[Finding]] = Map([])
  for hit in before {
    let key = (hit.kind, hit.expression, hit.evidence_sha256)
    if exact.get(key) is Some(matches) && matches.pop() is Some(current) {
      kept[current.id] = ()
      unchanged.push({
        "path": Json(path),
        "previous": Json(hit),
        "current": Json(current),
      })
    } else {
      unmatched_before
      .get_or_init((hit.kind, hit.expression), () => [])
      .push(hit)
    }
  }
  for hit in after {
    if !kept.contains(hit.id) {
      unmatched_after
      .get_or_init((hit.kind, hit.expression), () => [])
      .push(hit)
    }
  }
  for key, old_group in unmatched_before {
    match unmatched_after.get(key) {
      Some(new_group) =>
        changed.push({
          "path": Json(path),
          "previous": Json(old_group),
          "current": Json(new_group),
        })
      None =>
        for hit in old_group {
          removed.push(evidence_json(path, hit))
        }
    }
  }
  for key, new_group in unmatched_after {
    if !unmatched_before.contains(key) {
      for hit in new_group {
        added.push(evidence_json(path, hit))
      }
    }
  }
}

///|
fn lost_scan_coverage(file : FileResult) -> Bool {
  // Intentional exclusions and non-text entries remain outside scan scope.
  file.reason
  is Some(
    "directory_unreadable"
    | "unreadable"
    | "read_failed"
    | "file_byte_limit"
    | "total_byte_limit"
    | "finding_limit"
    | "entry_limit"
  )
}

///|
/// Compare evidence only where both snapshots establish coverage of the path.
/// A line-number change alone does not change the identity of an indication.
pub fn compare(previous : Report, current : Report) -> Json {
  let added : Array[Json] = []
  let removed : Array[Json] = []
  let changed : Array[Json] = []
  let unchanged : Array[Json] = []
  let not_comparable : Array[Json] = []
  let reasons : Array[String] = []
  if previous.schema_version != schema_version ||
    current.schema_version != schema_version {
    reasons.push("schema_mismatch")
  }
  if previous.rules_version != current.rules_version {
    reasons.push("rules_mismatch")
  }
  if previous.directory != current.directory ||
    (
      !previous.directory &&
      previous.files.get(0).map(file => file.path) !=
      current.files.get(0).map(file => file.path)
    ) {
    reasons.push("scope_mismatch")
  }
  let status = if !reasons.is_empty() {
    "incomparable"
  } else {
    let before : Map[String, FileResult] = Map([])
    let after : Map[String, FileResult] = Map([])
    let paths : Map[String, Unit] = Map([])
    for file in previous.files {
      before[file.path] = file
      if !file.findings.is_empty() || lost_scan_coverage(file) {
        paths[file.path] = ()
      }
    }
    for file in current.files {
      after[file.path] = file
      if !file.findings.is_empty() || lost_scan_coverage(file) {
        paths[file.path] = ()
      }
    }
    let order : Array[String] = []
    for path, _ in paths {
      order.push(path)
    }
    order.sort()
    for path in order {
      let previous_block = comparison_block(previous, before, path)
      let current_block = comparison_block(current, after, path)
      if previous_block is Some(_) || current_block is Some(_) {
        not_comparable.push({
          "path": Json(path),
          "previous_reason": previous_block
          .map(Json::string)
          .unwrap_or(Json::null()),
          "current_reason": current_block
          .map(Json::string)
          .unwrap_or(Json::null()),
        })
      } else {
        compare_path(
          path,
          before.get(path).map(file => file.findings).unwrap_or([]),
          after.get(path).map(file => file.findings).unwrap_or([]),
          added,
          removed,
          changed,
          unchanged,
        )
      }
    }
    let previous_excludes = Set::from_array(previous.options.exclude)
    let current_excludes = Set::from_array(current.options.exclude)
    if previous_excludes != current_excludes {
      reasons.push("exclusion_scope_changed")
    }
    if !previous.enumeration_complete {
      reasons.push("previous_enumeration_incomplete")
    }
    if !current.enumeration_complete {
      reasons.push("current_enumeration_incomplete")
    }
    if reasons.is_empty() && not_comparable.is_empty() {
      "comparable"
    } else {
      "partial"
    }
  }
  {
    "status": Json(status),
    "reasons": Json(reasons),
    "added": Json(added),
    "removed": Json(removed),
    "changed": Json(changed),
    "unchanged": Json(unchanged),
    "not_comparable": Json(not_comparable),
  }
}

///|
fn copyright_holder_line(line : StringView) -> Bool {
  if line.length() > 512 || line.contains("[") || line.contains("]") {
    return false
  }
  let holder = match line.split_once("<") {
    None => line
    Some((name, suffix)) => {
      guard suffix.split_once(">") is Some((email, trailing)) &&
        words(trailing.to_owned()).is_empty() &&
        email.split_once("@") is Some((user, domain)) &&
        !user.is_empty() &&
        !domain.is_empty() &&
        !email.contains(" ") &&
        !email.contains("\t") &&
        !email.contains("<") &&
        !domain.contains("@") else {
        return false
      }
      name
    }
  }
  let terms = words(holder.to_owned()).map(word => word.value)
  if terms.get(0) != Some("copyright") {
    return false
  }
  let index = if terms.get(1) == Some("c") { 2 } else { 1 }
  guard terms.get(index) is Some(year) else { return false }
  if year.length() != 4 {
    return false
  }
  for i in 0..<4 {
    if year[i] < 48 || year[i] > 57 {
      return false
    }
  }
  for i in (index + 1)..<terms.length() {
    let term = terms[i]
    match term {
      "all"
      | "rights"
      | "reserved"
      | "the"
      | "copyright"
      | "holder"
      | "holders"
      | "year"
      | "name"
      | "author"
      | "your" => continue
      _ => ()
    }
    for j in 0..<term.length() {
      if term[j] >= 97 && term[j] <= 122 {
        return true
      }
    }
  }
  false
}

///|
fn notice_source(
  text : String,
  hit : Finding,
  rule : CompiledRule,
) -> (String, Int32)? {
  if rule.source.kind != "text" || hit.start_line <= 1 {
    return None
  }
  guard excerpt(text, hit.start_line, hit.end_line) is Some(body) else {
    return None
  }
  if words(body).map(word => word.value) != rule.words {
    return None
  }
  let first = (hit.start_line - 6).max(1)
  guard excerpt(text, first, hit.start_line - 1) is Some(prefix) else {
    return None
  }
  let lines = prefix.split("\n").collect()
  let mut start = hit.start_line
  for i in 0..<lines.length() {
    let line = lines.length() - i - 1
    if copyright_holder_line(lines[line]) {
      start = first + line
    } else {
      let terms = words(lines[line].to_owned()).map(word => word.value)
      // Do not export a subset when another adjacent attribution is unresolved.
      if terms.get(0) == Some("copyright") {
        return None
      }
      if !terms.is_empty() && terms != ["all", "rights", "reserved"] {
        break
      }
    }
  }
  if start == hit.start_line {
    return None
  }
  excerpt(text, start, hit.end_line).map(content => (content, start))
}

///|
/// Assemble copyable notice candidates from verified evidence in a current scan.
/// Identical texts share an entry, and each matching source remains listed.
pub fn Scanner::notice(
  self : Scanner,
  root : String,
  current : Report,
) -> Json raise {
  let boundary = @local.Root::open(root)
  defer boundary.close()
  self.notice_at(boundary, current)
}

///|
fn Scanner::notice_at(
  self : Scanner,
  boundary : @local.Root,
  current : Report,
) -> Json raise {
  if current.rules_version != @rules.version() {
    raise StaleEvidence
  }
  validate_report(current)
  if boundary.is_directory() != current.directory {
    raise StaleEvidence
  }
  let review : Array[Json] = []
  let sources : Map[String, Array[Json]] = Map([])
  let mut size = 0
  fn reserve(bytes : Int32) -> Unit raise ScanError {
    if bytes > report_limit - size {
      raise LimitExceeded("notice exceeds 16 MiB")
    }
    size += bytes
  }
  fn needs_review(
    file : FileResult,
    reasons : Array[String],
  ) -> Unit raise ScanError {
    let row : Json = {
      "path": Json(file.path),
      "status": Json(file.status),
      "reasons": Json(reasons),
    }
    reserve(row.stringify().length() * 3 + 2)
    review.push(row)
  }
  for file in current.files {
    if !fully_scanned(file) {
      needs_review(file, [file.reason.unwrap_or(file.status)])
      continue
    }
    if !file.review.is_empty() ||
      file.findings
      .iter()
      .any(hit => hit.expression != file.findings[0].expression) {
      needs_review(
        file,
        if file.review.is_empty() {
          ["multiple_license_indications"]
        } else {
          file.review
        },
      )
      continue
    }
    if file.findings.is_empty() {
      needs_review(file, ["unknown_license"])
      continue
    }
    let candidates : Array[(Finding, CompiledRule)] = []
    for hit in file.findings {
      for rule in self.rules {
        if rule.source.id == hit.rule_id &&
          rule.source.expression == hit.expression &&
          rule.source.kind == hit.kind &&
          (hit.kind == "text" || rule.source.notice is Some(_)) {
          candidates.push((hit, rule))
          break
        }
      }
    }
    if candidates.is_empty() {
      needs_review(file, ["no_complete_license_text"])
      continue
    }
    let source = Some(verified_text(boundary, current, file)) catch {
      _ => None
    }
    guard source is Some(text) else {
      needs_review(file, ["stale_evidence"])
      continue
    }
    // Check the entire set so a forged report cannot omit a conflicting finding.
    let (actual, flags, complete) = self.find(file.path, text, 256)
    if !complete || !flags.is_empty() || actual != file.findings {
      needs_review(file, ["stale_or_incomplete_evidence"])
      continue
    }
    let mut unresolved = false
    for candidate in candidates {
      let (hit, rule) = candidate
      let entry = match notice_source(text, hit, rule) {
        Some((content, start)) => Some((content, start, "source"))
        None =>
          rule.source.notice.map(content => (content, hit.start_line, "rule"))
      }
      guard entry is Some((content, start, origin)) else {
        unresolved = true
        continue
      }
      if !sources.contains(content) {
        reserve(Json(content).stringify().length() * 3 + 32)
        sources[content] = []
      }
      let row : Json = {
        "path": Json(file.path),
        "id": Json(hit.id),
        "expression": Json(hit.expression),
        "rule_id": Json(hit.rule_id),
        "start_line": Json(start),
        "end_line": Json(hit.end_line),
        "origin": Json(origin),
      }
      reserve(row.stringify().length() * 3 + 2)
      sources[content].push(row)
    }
    if unresolved {
      needs_review(file, ["unverified_complete_license_text"])
    }
  }
  let entries : Array[Json] = []
  for text, locations in sources {
    entries.push({ "text": Json(text), "sources": Json(locations) })
  }
  {
    "entries": Json(entries),
    "review": Json(review),
    "enumeration_complete": Json(current.enumeration_complete),
    "diagnostics": Json(current.diagnostics),
  }
}
