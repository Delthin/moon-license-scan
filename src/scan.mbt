///|
fn validate_options(options : ScanOptions) -> Unit raise ScanError {
  if options.max_file_bytes < 1 ||
    options.max_file_bytes > 16 * 1024 * 1024 ||
    options.max_total_bytes < 1 ||
    options.max_total_bytes > 512 * 1024 * 1024 ||
    options.max_entries < 1 ||
    options.max_entries > 50000 ||
    options.max_findings < 1 ||
    options.max_findings > 20000 ||
    options.exclude.length() > 128 {
    raise InvalidInput("invalid scan bounds")
  }
  let seen : Set[String] = Set([])
  for prefix in options.exclude {
    if !relative_path(prefix) || prefix.length() > 1024 || seen.contains(prefix) {
      raise InvalidInput("invalid or duplicate exclusion prefix")
    }
    seen.add(prefix)
  }
}

///|
fn relative_path(path : String) -> Bool {
  if path == "" ||
    path.length() > 4096 ||
    path.contains("\\") ||
    path.contains(":") {
    return false
  }
  for ch in path {
    if ch.to_int() < 32 || ch.to_int() == 127 {
      return false
    }
  }
  for part in path.split("/") {
    if part == "" || part == "." || part == ".." {
      return false
    }
  }
  true
}

///|
fn ScanOptions::excludes(self : ScanOptions, path : String) -> Bool {
  for item in self.exclude {
    if path == item || path.has_prefix(item + "/") {
      return true
    }
  }
  false
}

///|
fn contains_nul(data : Bytes) -> Bool {
  for byte in data {
    if byte == 0 {
      return true
    }
  }
  false
}

///|
fn skipped(path : String, reason : String, bytes~ : Int32 = 0) -> FileResult {
  {
    path,
    status: "skipped",
    reason: Some(reason),
    sha256: None,
    bytes,
    findings: [],
    review: [],
  }
}

///|
/// Synchronously scan a locally authorized path. The report does not expose the
/// absolute root or the source text. Call preview for a specific evidence ID.
pub fn Scanner::scan(
  self : Scanner,
  root : String,
  options~ : ScanOptions = ScanOptions::default(),
) -> Report raise {
  let boundary = @local.Root::open(root)
  defer boundary.close()
  self.scan_at(boundary, options)
}

///|
fn Scanner::scan_at(
  self : Scanner,
  boundary : @local.Root,
  options : ScanOptions,
) -> Report raise {
  validate_options(options)
  let directory = boundary.is_directory()
  let initial : @local.Entry = if directory {
    { path: "", kind: "directory", }
  } else {
    { path: boundary.file_name(), kind: "file", }
  }
  let queue : Array[@local.Entry] = [initial]
  let files : Array[FileResult] = []
  let diagnostics : Array[String] = []
  let mut bytes_read = 0
  let mut entries = 0
  let mut findings = 0
  let mut estimated_output = 0
  let mut enumeration_complete = true
  let mut unsupported_path = false
  while queue.pop() is Some(entry) {
    let path = entry.path
    if path != "" {
      if entries >= options.max_entries {
        enumeration_complete = false
        diagnostics.push("entry_limit")
        break
      }
      entries += 1
      if !relative_path(path) {
        enumeration_complete = false
        if !unsupported_path {
          diagnostics.push("unsupported_path")
          unsupported_path = true
        }
        continue
      }
    }
    let result = if options.excludes(path) {
      skipped(path, "excluded")
    } else if entry.kind == "directory" {
      let budget = options.max_entries - entries - queue.length()
      if budget <= 0 {
        enumeration_complete = false
        skipped(path, "entry_limit")
      } else {
        let listed = Some(boundary.list(path, budget)) catch { _ => None }
        match listed {
          Some((children, complete)) => {
            children.sort_by((a, b) => b.path.compare(a.path))
            queue.append(children)
            if !complete {
              enumeration_complete = false
              if !diagnostics.contains("entry_limit") {
                diagnostics.push("entry_limit")
              }
            }
            continue
          }
          None => {
            enumeration_complete = false
            if path == "" {
              diagnostics.push("root_unreadable")
              continue
            }
            skipped(path, "directory_unreadable")
          }
        }
      }
    } else if entry.kind != "file" {
      if entry.kind == "unreadable" {
        enumeration_complete = false
      }
      skipped(path, entry.kind)
    } else if bytes_read >= options.max_total_bytes {
      skipped(path, "total_byte_limit")
    } else if findings >= options.max_findings {
      skipped(path, "finding_limit")
    } else {
      let remaining = options.max_total_bytes - bytes_read
      let total_bound = remaining <= options.max_file_bytes
      let data = Some(
        if total_bound {
          boundary.read_with_limit(path, remaining)
        } else {
          let raw = boundary.read(path, options.max_file_bytes)
          (raw, raw.length() <= options.max_file_bytes)
        },
      ) catch {
        _ => None
      }
      match data {
        None => skipped(path, "read_failed")
        Some((raw, complete)) => {
          let bytes = raw.length()
          bytes_read += bytes
          if !complete {
            skipped(
              path,
              if total_bound {
                "total_byte_limit"
              } else {
                "file_byte_limit"
              },
              bytes~,
            )
          } else if contains_nul(raw) {
            skipped(path, "binary", bytes~)
          } else {
            match (Some(@utf8.decode(raw[:])) catch { _ => None }) {
              None => skipped(path, "invalid_utf8", bytes~)
              Some(text) => {
                let (evidence, review, complete) = self.find(
                  path,
                  text,
                  (options.max_findings - findings).min(256),
                )
                findings += evidence.length()
                {
                  path,
                  bytes,
                  sha256: Some(hash_bytes(raw)),
                  findings: evidence,
                  review,
                  status: if !complete {
                    "partial"
                  } else if !review.is_empty() {
                    "review"
                  } else {
                    "scanned"
                  },
                  reason: if complete {
                    None
                  } else {
                    Some("finding_limit")
                  },
                }
              }
            }
          }
        }
      }
    }
    estimated_output += 512 + path.length() * 6
    for finding in result.findings {
      estimated_output += 512 + finding.expression.length() * 6
    }
    if estimated_output > report_limit - 1024 * 1024 {
      enumeration_complete = false
      diagnostics.push("output_limit")
      break
    }
    files.push(result)
  }
  files.sort_by((a, b) => a.path.compare(b.path))
  {
    schema_version,
    rules_version: @rules.version(),
    directory,
    options,
    enumeration_complete,
    entries,
    bytes_read,
    files,
    diagnostics,
  }
}

///|
/// A bounded copy of the matching source lines as they appear in the file.
#derive(ToJson)
pub(all) struct Preview {
  path : String
  start_line : Int32
  end_line : Int32
  text : String
}

///|
fn verified_text(
  boundary : @local.Root,
  current : Report,
  file : FileResult,
) -> String raise {
  validate_options(current.options)
  if current.schema_version != schema_version ||
    current.rules_version != @rules.version() ||
    boundary.is_directory() != current.directory ||
    !relative_path(file.path) ||
    current.options.excludes(file.path) {
    raise StaleEvidence
  }
  guard file.sha256 is Some(expected) else { raise UnknownEvidence }
  let raw = boundary.read(file.path, current.options.max_file_bytes)
  if raw.length() > current.options.max_file_bytes ||
    raw.length() != file.bytes ||
    hash_bytes(raw) != expected ||
    contains_nul(raw) {
    raise StaleEvidence
  }
  @utf8.decode(raw[:])
}

///|
fn Scanner::verify_finding(
  self : Scanner,
  file : FileResult,
  hit : Finding,
  text : String,
) -> Unit raise ScanError {
  let (findings, _, _) = self.find(file.path, text, 256)
  if !findings.contains(hit) {
    raise UnknownEvidence
  }
}

///|
/// Reopen and verify a specific current finding before returning source text.
pub fn Scanner::preview(
  self : Scanner,
  root : String,
  current : Report,
  id : String,
) -> Preview raise {
  let boundary = @local.Root::open(root)
  defer boundary.close()
  self.preview_at(boundary, current, id)
}

///|
fn Scanner::preview_at(
  self : Scanner,
  boundary : @local.Root,
  current : Report,
  id : String,
) -> Preview raise {
  for file in current.files {
    for hit in file.findings {
      if hit.id != id {
        continue
      }
      let text = verified_text(boundary, current, file)
      self.verify_finding(file, hit, text)
      guard excerpt(text, hit.start_line, hit.end_line) is Some(content) else {
        raise LimitExceeded("evidence preview exceeds the display limit")
      }
      return {
        path: file.path,
        start_line: hit.start_line,
        end_line: hit.end_line,
        text: content,
      }
    }
  }
  raise UnknownEvidence
}
