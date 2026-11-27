///|
/// Installed version of the scanner and its entry points.
pub const VERSION : String = "0.1.1"

///|
/// Bounds and explicit exclusion prefixes for a filesystem scan. Prefixes use
/// slash-separated root-relative paths; Git ignore rules are not consulted.
#derive(Eq, ToJson, FromJson)
pub(all) struct ScanOptions {
  max_file_bytes : Int32
  max_total_bytes : Int32
  max_entries : Int32
  max_findings : Int32
  exclude : Array[String]
}

///|
pub fn ScanOptions::default() -> ScanOptions {
  {
    max_file_bytes: 2 * 1024 * 1024,
    max_total_bytes: 64 * 1024 * 1024,
    max_entries: 12000,
    max_findings: 4000,
    exclude: [".git"],
  }
}

///|
/// Decode a JSON scan-options object. Omitted fields use the same defaults
/// as the SDK. An explicit exclude list replaces the default list.
pub fn ScanOptions::parse_options(input : Json) -> ScanOptions raise ScanError {
  guard input is Object(fields) else {
    raise InvalidInput("scan options must be an object")
  }
  for key, _ in fields {
    if !(key
      is ("max_file_bytes"
      | "max_total_bytes"
      | "max_entries"
      | "max_findings"
      | "exclude")) {
      raise InvalidInput("unknown scan option")
    }
  }
  fn integer(key : String, fallback : Int32) -> Int32 raise ScanError {
    guard fields.get(key) is Some(value) else { return fallback }
    guard value is Number(n, repr~) &&
      n >= 1.0 &&
      n <= 2147483647.0 &&
      n == n.to_int().to_double() &&
      !(repr is Some(token) &&
      (token.contains(".") || token.contains("e") || token.contains("E"))) else {
      raise InvalidInput("expected a positive integer for " + key)
    }
    n.to_int()
  }
  let defaults = ScanOptions::default()
  let exclude = match fields.get("exclude") {
    None => defaults.exclude
    Some(Array(items) as value) if items.length() <= 128 =>
      @json.from_json(value) catch {
        _ => raise InvalidInput("exclude must be an array of path prefixes")
      }
    _ =>
      raise InvalidInput("exclude must be an array of up to 128 path prefixes")
  }
  let options = {
    max_file_bytes: integer("max_file_bytes", defaults.max_file_bytes),
    max_total_bytes: integer("max_total_bytes", defaults.max_total_bytes),
    max_entries: integer("max_entries", defaults.max_entries),
    max_findings: integer("max_findings", defaults.max_findings),
    exclude,
  }
  validate_options(options)
  options
}

///|
/// One independent license indication. Line positions are 1-based and inclusive.
#derive(Eq, ToJson, FromJson)
pub(all) struct Finding {
  id : String
  expression : String
  kind : String
  scope : String
  rule_id : String
  start_line : Int32
  end_line : Int32
  evidence_sha256 : String
}

///|
/// A file or skipped path, together with its scan outcome.
#derive(Eq, ToJson, FromJson)
pub(all) struct FileResult {
  path : String
  status : String
  reason : String?
  sha256 : String?
  bytes : Int32
  findings : Array[Finding]
  review : Array[String]
}

///|
/// Portable scan snapshot. It contains no absolute paths or source contents.
#derive(Eq, ToJson, FromJson)
pub(all) struct Report {
  schema_version : Int32
  rules_version : String
  directory : Bool
  options : ScanOptions
  enumeration_complete : Bool
  entries : Int32
  bytes_read : Int32
  files : Array[FileResult]
  diagnostics : Array[String]
}

///|
#derive(Debug)
pub suberror ScanError {
  InvalidInput(String)
  StaleEvidence
  UnknownEvidence
  LimitExceeded(String)
}

///|
let schema_version : Int32 = 1

///|
fn rules_version() -> String {
  @rules.version() + "-spdx329-scan2"
}

///|
let report_limit : Int32 = 16 * 1024 * 1024

///|
fn hash_bytes(data : Bytes) -> String {
  @crypto.bytes_to_hex_string(@crypto.sha256(data))
}

///|
fn hash_text(text : String) -> String {
  hash_bytes(@utf8.encode(text[:]))
}
