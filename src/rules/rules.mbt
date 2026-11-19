///|
/// One evidence pattern derived from a pinned ScanCode source file.
pub(all) struct RuleSource {
  id : String
  expression : String
  pattern : String
  kind : String
  source : String
  sha256 : String
  notice : String?
  anchor : Int32
}

///|
/// Identifies the ScanCode release and local rule selection.
pub fn version() -> String {
  "scancode-32.5.0-curated.5"
}
