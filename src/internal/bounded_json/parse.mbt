///|
pub fn parse(input : StringView, max_depth : Int32) -> Json raise {
  // RC1 has no hard parser depth limit; reject excessive nesting before parsing.
  let mut depth = 0
  let mut quoted = false
  let mut escaped = false
  for c in input {
    if quoted {
      if escaped {
        escaped = false
      } else if c == '\\' {
        escaped = true
      } else if c == '"' {
        quoted = false
      }
    } else {
      match c {
        '"' => quoted = true
        '[' | '{' => {
          depth += 1
          guard depth <= max_depth else {
            fail("JSON nesting exceeds the input limit")
          }
        }
        ']' | '}' => depth -= 1
        _ => ()
      }
    }
  }
  @json.parse(input, reject_duplicate_keys=true, preserve_number_repr=true)
}
