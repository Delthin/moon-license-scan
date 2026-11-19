///|
test "curated rule excerpts match without accepting their incomplete prefix" {
  let scanner = Scanner::new()
  let expressions : Map[String, Unit] = Map([])
  let mut ambiguous_count = 0
  for rule in @rules.corpus() {
    let (found, review, complete) = scanner.find(
      "license_fixture.c",
      rule.pattern,
      256,
    )
    assert_true(complete)
    let normalized = words(rule.pattern).map(word => word.value)
    let prefix = StringBuilder()
    for i in 0..<(normalized.length() - 1) {
      if i != 0 {
        prefix.write_char(' ')
      }
      prefix.write_string(normalized[i])
    }
    let (near, near_review, near_complete) = scanner.find(
      "license_fixture.c",
      prefix.to_string(),
      256,
    )
    assert_true(near_complete)
    if rule.kind == "ambiguous" {
      ambiguous_count += 1
      if !found.is_empty() ||
        !review.contains("ambiguous_rule_match") ||
        !near_review.is_empty() {
        fail(
          "ambiguous rule must flag only the complete shared excerpt: \{rule.id}",
        )
      }
    } else {
      expressions[rule.expression] = ()
      if !review.is_empty() ||
        !found.iter().any(hit => hit.rule_id == rule.id) ||
        found
        .iter()
        .any(hit => hit.expression != rule.expression || hit.kind == "spdx") {
        fail("incorrect evidence for curated rule: \{rule.id}")
      }
      if near.iter().any(hit => hit.rule_id == rule.id) {
        fail("a shortened excerpt matched the exact rule: \{rule.id}")
      }
    }
  }
  assert_eq(expressions.length(), 30)
  assert_eq(ambiguous_count, 2)
}

///|
test "GNU headers do not infer a version or an upgrade permission" {
  let scanner = Scanner::new()
  let fixtures = [
    ("/* GNU General Public License */", []),
    (
      "/* You may redistribute or modify it under the terms of the GNU General Public License version 2, as published by the Free Software Foundation. */",
      [],
    ),
    (
      "/* You may redistribute or modify it under the terms of the GNU General Public License version 2 only, as published by the Free Software Foundation. */",
      ["GPL-2.0-only"],
    ),
    (
      "/* This program is free software under the GNU General Public License, version 2 or later. */",
      ["GPL-2.0-or-later"],
    ),
  ]
  for (text, expected) in fixtures {
    let (hits, review, complete) = scanner.find("gnu_fixture.c", text, 256)
    assert_true(complete)
    assert_true(review.is_empty())
    assert_eq(hits.map(hit => hit.expression), expected)
  }
}
