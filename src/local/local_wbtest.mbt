///|
test "unrepresentable native entries do not produce openable paths" {
  for record in [b"\x01\xff", b"\x00"] {
    let entry = decode_entry("sub/", record)
    assert_eq(entry.kind, "unreadable")
    let encoded = Some(encode_path(entry.path[:])) catch {
      InvalidPath(_) => None
      error => raise error
    }
    assert_true(encoded is None)
  }
  let valid = decode_entry("sub/", b"\x01\xef\xbb\xbfvalid")
  assert_eq(valid.path, "sub/\uFEFFvalid")
  assert_eq(valid.kind, "file")
}
