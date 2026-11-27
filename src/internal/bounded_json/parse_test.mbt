///|
test "input depth counts containers and preserves strict parsing" {
  for limit in [16, 17] {
    for (open, close) in [("[", "]"), ("{\"child\":", "}")] {
      let exact = open.repeat(limit) + "null" + close.repeat(limit)
      assert_eq(@bounded_json.parse(exact[:], limit).stringify(), exact)
      for leaf in ["[null]", "[]", "{}"] {
        let excessive = open.repeat(limit) + leaf + close.repeat(limit)
        let accepted = try @bounded_json.parse(excessive[:], limit) catch {
          _ => false
        } noraise {
          _ => true
        }
        assert_false(accepted)
      }
    }
  }
  let text = "{\"text\":\"[{}]\",\"number\":1.00000000000000000001}"
  assert_eq(@bounded_json.parse(text[:], 1).stringify(), text)
  let quoted =
    #|{"text":"escaped quote: \" [{}] and backslash: \\"}
  assert_eq(@bounded_json.parse(quoted[:], 1).stringify(), quoted)
  let duplicate = "{\"key\":1,\"k\\u0065y\":2}"
  let accepted = try @bounded_json.parse(duplicate[:], 1) catch {
    _ => false
  } noraise {
    _ => true
  }
  assert_false(accepted)
}
