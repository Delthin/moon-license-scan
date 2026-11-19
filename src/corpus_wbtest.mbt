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
      prefix.write_stringview(normalized[i])
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
      let (expression, flags) = spdx_parse(rule.expression[:], true)
      assert_eq(expression, Some(rule.expression))
      assert_eq(flags, if rule.expression.has_prefix("LicenseRef-") {
        ["unresolved_license_ref"]
      } else {
        []
      })
      for id in rule.expression.split(" OR ") {
        expressions[id.to_owned()] = ()
      }
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
  assert_eq(expressions.length(), 83)
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

///|
test "generic disclaimers do not match and contradictory SPDX stays separate" {
  let scanner = Scanner::new()
  let generic = "The software is provided as is, without warranty of any kind. Creative Commons is not a law firm and does not provide legal advice."
  let (hits, review, complete) = scanner.find("fixture.c", generic, 256)
  assert_true(complete)
  assert_true(hits.is_empty())
  assert_true(review.is_empty())

  guard @rules.corpus().iter().find_first(rule => rule.id == "bsd-3-pcre-cambridge")
    is Some(pcre) else { fail("missing PCRE source header rule") }
  let text = "// SPDX-License-Identifier: MIT\n" + pcre.pattern
  let (hits, review, complete) = scanner.find("fixture.c", text, 256)
  assert_true(complete)
  assert_eq(hits.map(hit => (hit.kind, hit.expression)), [
    ("spdx", "MIT"),
    ("text", "BSD-3-Clause"),
  ])
  assert_eq(review, ["multiple_license_indications"])

  let (altered, review, _) = scanner.find(
    "fixture.c",
    pcre.pattern.replace_all(
      old="University of Cambridge",
      new="University of Oxford",
    ),
    256,
  )
  assert_true(altered.is_empty())
  assert_eq(review, ["ambiguous_rule_match"])
}

///|
test "named license notices stay local fragments and links alone are not grants" {
  let scanner = Scanner::new()
  let source =
    #|// Released under MIT License. Please refer to license.txt for details
    #|// See http://www.boost.org/LICENSE_1_0.txt
    #|// MIT License
  let (hits, review, complete) = scanner.find("source.c", source, 256)
  assert_true(complete)
  assert_true(review.is_empty())
  assert_eq(
    hits.map(hit => (hit.expression, hit.kind, hit.start_line, hit.end_line)),
    [("MIT", "fragment", 1, 1)],
  )
}
