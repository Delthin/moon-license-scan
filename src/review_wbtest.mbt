///|
fn review_hit(id : String, fingerprint : String, line : Int32) -> Finding {
  {
    id: hash_text(id),
    expression: "MIT",
    kind: "text",
    rule_id: "mit-text",
    scope: "file",
    start_line: line,
    end_line: line,
    evidence_sha256: hash_text(fingerprint),
  }
}

///|
fn review_file(path : String, findings : Array[Finding]) -> FileResult {
  {
    path,
    status: "scanned",
    reason: None,
    sha256: Some(hash_text(path)),
    bytes: 500,
    findings,
    review: [],
  }
}

///|
fn review_report(files : Array[FileResult], complete~ : Bool = true) -> Report {
  {
    schema_version,
    rules_version: rules_version(),
    directory: true,
    options: ScanOptions::default(),
    enumeration_complete: complete,
    entries: files.length(),
    bytes_read: files.fold(init=0, (total, file) => total + file.bytes),
    files,
    diagnostics: [],
  }
}

///|
fn reject_report(text : String) -> Unit raise {
  try parse_report(text) catch {
    InvalidInput(_) | LimitExceeded(_) => ()
    err => raise err
  } noraise {
    _ => fail("malformed report was accepted")
  }
}

///|
test "report import validates canonical JSON, bounds and unique evidence" {
  let file = review_file("第三方/example.c", [review_hit("1", "same", 2)])
  let report = review_report([file])
  let text = Json(report).stringify()
  assert_true(parse_report(text) == report)
  reject_report("{\"schema_version\":1," + text[1:].to_owned())
  reject_report("{\"schema\\u005fversion\":1," + text[1:].to_owned())
  reject_report(
    "{\"extra\":" +
    "[".repeat(20) +
    "0" +
    "]".repeat(20) +
    "," +
    text[1:].to_owned(),
  )
  reject_report(
    text.replace_all(
      old="\"schema_version\":1",
      new="\"schema_version\":1.00000000000000000001",
    ),
  )
  reject_report("界".repeat(report_limit / 3 + 1))
  for
    invalid in [
      { ..report, schema_version: 99, },
      { ..report, bytes_read: 1, },
      { ..report, options: { ..report.options, max_file_bytes: 0, }, },
      {
        ..report,
        options: { ..report.options, exclude: ["vendor", "vendor"], },
      },
      review_report([{ ..file, path: "vendor/../example.c", }]),
      review_report([{ ..file, path: "C:\\example.c", }]),
      review_report([{ ..file, sha256: Some("invalid"), }]),
      review_report([
        {
          ..file,
          findings: [{ ..file.findings[0], end_line: file.bytes + 1, }],
        },
      ]),
      review_report([file, file]),
      review_report([file, { ..file, path: "other.c", }]),
    ] {
    reject_report(Json(invalid).stringify())
  }
}

///|
test "comparison pairs repeated fingerprints and groups only changed evidence" {
  let old = review_file("vendor/lib.c", [
    review_hit("repeat1", "duplicate", 5),
    review_hit("repeat2", "duplicate", 10),
    review_hit("old", "old terms", 15),
  ])
  let new = review_file("vendor/lib.c", [
    review_hit("repeat1", "duplicate", 20),
    review_hit("repeat2", "duplicate", 25),
    review_hit("new", "new terms", 30),
  ])
  let diff = compare(review_report([old]), review_report([new]))
  guard diff
    is {
      "status": "comparable",
      "added": [],
      "removed": [],
      "changed": [{ "previous": [old_hit], "current": [new_hit], .. }],
      "unchanged": [{ "previous": first, "current": moved, .. }, _],
      ..
    } else {
    fail("expected moved repeated text and one changed evidence group")
  }
  assert_eq((first, moved), (Json(old.findings[0]), Json(new.findings[0])))
  assert_eq((old_hit, new_hit), (Json(old.findings[2]), Json(new.findings[2])))
}

///|
test "only paths covered on both sides can have added or removed evidence" {
  let file = review_file("vendor/lib.c", [review_hit("1", "terms", 2)])
  let old = review_report([file])
  let empty = review_report([])
  guard compare(old, empty) is { "removed": [_], "not_comparable": [], .. } else {
    fail("complete deletion")
  }
  for
    current in [
      { ..empty, enumeration_complete: false, },
      { ..empty, options: { ..empty.options, exclude: ["vendor"], }, },
      { ..empty, options: { ..empty.options, exclude: ["vendor/lib.c"], }, },
      review_report([
        {
          ..file,
          status: "partial",
          reason: Some("finding_limit"),
          findings: [],
        },
      ]),
      review_report([
        {
          ..file,
          path: "vendor",
          status: "skipped",
          reason: Some("link"),
          sha256: None,
          bytes: 0,
          findings: [],
        },
      ]),
    ] {
    guard compare(old, current) is { "removed": [], "not_comparable": [_], .. } else {
      fail("false deletion")
    }
    guard compare(current, old) is { "added": [], "not_comparable": [_], .. } else {
      fail("false addition")
    }
  }
  let near = { ..empty, options: { ..empty.options, exclude: ["vend"], }, }
  guard compare(old, near) is { "removed": [_], .. } else {
    fail("excluded prefix must end at a component boundary")
  }
  guard compare(old, { ..empty, rules_version: "older", })
    is { "status": "incomparable", "removed": [], .. } else {
    fail("different rules were compared")
  }
}

///|
async test "comparison reports budget gaps without findings" {
  let root = @test_fs.tmpdir(prefix="moon-license-compare")
  defer @test_fs.rmdir(root, recursive=true)
  @test_fs.write_binary(root + "/unit.c", b"// SPDX-License-Identifier: MIT\n")
  let scanner = Scanner::new()
  let limited = scanner.scan(root, options={
    ..ScanOptions::default(),
    max_total_bytes: 1,
  })
  assert_true(limited.enumeration_complete)
  guard compare(limited, limited)
    is {
      "status": "partial",
      "added": [],
      "removed": [],
      "not_comparable": [
        {
          "path": "unit.c",
          "previous_reason": "total_byte_limit",
          "current_reason": "total_byte_limit",
          ..
        },
      ],
      ..
    } else {
    fail("directory enumeration does not prove file coverage")
  }
}

///|
test "notice uses real adjacent attribution and rejects fragments or extra source words" {
  let scanner = Scanner::new()
  guard scanner.rules.iter().find_first(rule => rule.source.id == "mit-text")
    is Some(rule) else {
    fail("MIT full-text rule is required")
  }
  let text = "Copyright (c) 2026 Example Collective\n\n" + rule.source.pattern
  let (hits, _, _) = scanner.find("unit.c", text, 256)
  guard hits is [hit] else { fail("MIT body is required") }
  assert_eq(notice_source(text, hit, rule), Some((text, 1)))
  let first = "Copyright (c) 2024 Alice Example <alice@example.org>\n"
  let both = first + text
  let (hits, _, _) = scanner.find("unit.c", both, 256)
  guard hits is [both_hit] else { fail("MIT body is required") }
  assert_eq(notice_source(both, both_hit, rule), Some((both, 1)))
  let unresolved = "Copyright (c) 2024 [Your Name]\n" + text
  assert_eq(notice_source(unresolved, both_hit, rule), None)
  let placeholder = "Copyright (c) 2026 [Your Name]\n\n" + rule.source.pattern
  assert_eq(notice_source(placeholder, hit, rule), None)
  let mixed = text + " unrelated code"
  assert_eq(notice_source(mixed, hit, rule), None)
  assert_eq(
    notice_source(text, hit, {
      ..rule,
      source: { ..rule.source, kind: "fragment", },
    }),
    None,
  )
}

///|
async test "notice deduplicates text and rejects a changed source" {
  let fixture = @test_fs.tmpdir(prefix="moon-license-review")
  defer @test_fs.rmdir(fixture, recursive=true)
  let scanner = Scanner::new()
  guard scanner.rules.iter().find_first(rule => rule.source.id == "mit-text")
    is Some(rule) else {
    fail("MIT full-text rule is required")
  }
  let text = "Copyright (c) 2026 Example Collective\n\n" +
    rule.source.pattern.trim_end().to_owned()
  let first = fixture + "/first.c"
  let second = fixture + "/second.c"
  @test_fs.write_binary(first, @utf8.encode(text[:]))
  @test_fs.write_binary(second, @utf8.encode(text[:]))
  let report = scanner.scan(fixture)
  assert_true(parse_report(Json(report).stringify()) == report)
  guard scanner.notice(fixture, report)
    is {
      "entries": [
        {
          "text": String(notice),
          "sources": [{ "path": "first.c", .. }, { "path": "second.c", .. }],
          ..
        },
      ],
      "review": [],
      ..
    } else {
    fail("identical notices must retain both source locations")
  }
  assert_eq(notice, text)
  @test_fs.write_binary(first, b"modified since scan")
  guard scanner.notice(fixture, report)
    is {
      "entries": [{ "sources": [{ "path": "second.c", .. }], .. }],
      "review": [{ "path": "first.c", "reasons": ["stale_evidence"], .. }],
      ..
    } else {
    fail("changed source file should be flagged but not exported")
  }
}
