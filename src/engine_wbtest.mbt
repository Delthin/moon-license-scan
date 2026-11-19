///|
test "word and evidence positions agree on BOM, CRLF and CR" {
  let text = "\u{FEFF}HeLLo world\r\n/* second * test */\rthird"
  assert_eq(words(text).map(word => (word.value.to_owned(), word.line)), [
    ("hello", 1),
    ("world", 1),
    ("second", 2),
    ("test", 2),
    ("third", 3),
  ])
  assert_eq(excerpt(text, 2, 3), Some("/* second * test */\nthird"))
}

///|
test "SPDX maintainer declarations are normalized, not confused with prose" {
  let text = "Mention SPDX-License-Identifier: MIT\r\n// SPDX-License-Identifier: ( MIT OR Apache-2.0 ) AND GPL-2.0-only WITH Classpath-exception-2.0\r\n/* SPDX-License-Identifier: MIT OR */"
  let (labels, review, complete) = spdx_labels(text)
  assert_true(complete)
  assert_eq(review, ["invalid_spdx_label"])
  assert_eq(labels.map(hit => (hit.expression, hit.start_line)), [
    ("(MIT OR Apache-2.0) AND GPL-2.0-only WITH Classpath-exception-2.0", 2),
  ])
}

///|
async test "UTF-8 BOM preserves first-line SPDX evidence across CRLF releases" {
  let fixture = @test_fs.tmpdir(prefix="moon-license-bom")
  defer @test_fs.rmdir(fixture, recursive=true)
  let path = fixture + "/file.c"
  let label = "// SPDX-License-Identifier: MIT"
  let text = label + "\r\nint x;\r\n"
  let scanner = Scanner::new()
  @test_fs.write_binary(path, @utf8.encode(text[:]))
  let previous = scanner.scan(path)
  let raw = @utf8.encode(("\u{FEFF}" + text)[:])
  @test_fs.write_binary(path, raw)
  let current = scanner.scan(path)
  guard current.files is [file] && file.findings is [hit] else {
    fail("expected one SPDX declaration after adding a BOM")
  }
  assert_eq(file.sha256, Some(hash_bytes(raw)))
  assert_eq((hit.expression, hit.start_line, hit.end_line), ("MIT", 1, 1))
  let preview = scanner.preview(path, current, hit.id)
  assert_eq((preview.start_line, preview.end_line), (1, 1))
  assert_eq(preview.text, "\u{FEFF}" + label)
  guard compare(previous, current)
    is {
      "status": "comparable",
      "added": [],
      "removed": [],
      "changed": [],
      "unchanged": [_],
      ..
    } else {
    fail("adding a BOM must not change the license evidence")
  }
}

///|
async test "UTF-16 scanning, saved report and verified preview agree" {
  let fixture = @test_fs.tmpdir(prefix="moon-license-utf16")
  defer @test_fs.rmdir(fixture, recursive=true)
  let path = fixture + "/unit.c"
  let label = "(* SPDX-License-Identifier: mit *)"
  let text = "中文\r\n" + label + "\r\n"
  let scanner = Scanner::new()
  for endianness in [@utf16.Little, @utf16.Big] {
    let raw = @utf16.encode(text[:], bom=true, endianness~)
    @test_fs.write_binary(path, raw)
    let report = parse_report(Json(scanner.scan(path)).stringify())
    guard report.files is [{ sha256: Some(digest), findings: [hit], .. }] else {
      fail("expected a canonical declaration in the UTF-16 input")
    }
    assert_eq(digest, hash_bytes(raw))
    assert_eq((hit.expression, hit.start_line, hit.end_line), ("MIT", 2, 2))
    assert_eq(scanner.preview(path, report, hit.id).text, label)
  }
  @test_fs.write_binary(path, b"\xFF\xFE\x2F")
  guard scanner.scan(path).files is [{ reason: Some("invalid_utf16"), .. }] else {
    fail("truncated UTF-16 cannot produce evidence")
  }
}

///|
test "unknown SPDX names are excluded while references and deprecated IDs need review" {
  let (labels, flags, complete) = spdx_labels(
    "# SPDX-License-Identifier: MIT-Typo\n# SPDX-License-Identifier: MIT WITH MIT\n# SPDX-License-Identifier: DocumentRef-vendor:LicenseRef-custom\n# SPDX-License-Identifier: GPL-2.0+\n",
  )
  assert_true(complete)
  assert_eq(labels.map(hit => hit.expression), ["DocumentRef-vendor:LicenseRef-custom", "GPL-2.0+"])
  assert_eq(flags, ["unknown_spdx_id", "unresolved_license_ref", "deprecated_spdx_id"])
}

///|
test "GNU appendix placeholders do not erase an independent actual grant" {
  let grant = "This library is free software; you can redistribute it and/or\n" +
    "modify it under the terms of the GNU Lesser General Public\n" +
    "License as published by the Free Software Foundation; either\n" +
    "version 2.1 of the License, or (at your option) any later version.\n"
  let source = "Copyright (C) 2007 F. Example\n\n" + grant +
    "\n<one line to give the library's name>\nCopyright (C) <year>  <name of author>\n\n" + grant
  let (findings, _, complete) = Scanner::new().find("legal.txt", source, 256)
  assert_true(complete)
  assert_eq(findings.map(hit => (hit.expression, hit.start_line)), [("LGPL-2.1-or-later", 4)])
}

///|
async test "an exact total byte budget retains complete license evidence" {
  let fixture = @test_fs.tmpdir(prefix="moon-license-budget")
  defer @test_fs.rmdir(fixture, recursive=true)
  let path = fixture + "/unit.c"
  let bytes = b"// SPDX-License-Identifier: MIT\n"
  @test_fs.write_binary(path, bytes)
  let scanner = Scanner::new()
  let options = { ..ScanOptions::default(), max_total_bytes: bytes.length(), }
  let exact = scanner.scan(path, options~)
  assert_eq(exact.bytes_read, bytes.length())
  guard exact.files is [{ findings: [{ expression: "MIT", .. }], .. }] else {
    fail("a complete file exactly at the total budget must be scanned")
  }
  let cap = bytes.length() - 1
  let shorter = scanner.scan(path, options={ ..options, max_total_bytes: cap, })
  assert_eq(shorter.bytes_read, cap)
  guard shorter.files
    is [{ findings: [], reason: Some("total_byte_limit"), .. }] else {
    fail("a truncated file may not produce findings")
  }
}

///|
test "rules retain independent body and explicit evidence and stable IDs" {
  let scanner = Scanner::new()
  guard scanner.rules
    .filter(rule => {
      rule.source.expression == "MIT" && rule.source.kind == "text"
    })
    .get(0)
    is Some(rule) else {
    fail("the offline corpus needs an MIT text rule")
  }
  let text = "// SPDX-License-Identifier: BSD-3-Clause\n/*\n" +
    rule.source.pattern +
    "\n*/"
  let (first, review, complete) = scanner.find("vendor/unit.c", text, 256)
  assert_true(complete)
  assert_true(review.contains("multiple_license_indications"))
  assert_eq(first.length(), 2)
  assert_eq((first[0].kind, first[0].start_line), ("spdx", 1))
  assert_eq(
    (first[1].expression, first[1].scope, first[1].start_line),
    ("MIT", "file", 3),
  )
  let (shifted, _, _) = scanner.find("vendor/unit.c", "\n" + text, 256)
  assert_eq(first.map(f => f.id), shifted.map(f => f.id))
  assert_eq(shifted[1].start_line, 4)
  let (limited, _, complete) = scanner.find("vendor/unit.c", text, 1)
  assert_true(limited == [first[0]])
  assert_false(complete)
}

///|
test "candidate indexing keeps the same order at the raw evidence cap" {
  let corpus = @rules.corpus()
  let input = words(
    corpus[1].pattern + "\n" + (corpus[0].pattern + "\n").repeat(257),
  )
  let (matches, complete) = Scanner::new().body_matches(input)
  assert_false(complete)
  assert_eq(matches.length(), 256)
  assert_true(matches.all(hit => hit.rule_id == corpus[0].id))
  assert_true(matches[0].start_word > 0)
}
