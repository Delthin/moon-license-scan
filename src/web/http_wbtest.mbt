///|
async fn exchange_response(
  addr : @socket.Addr,
  raw : String,
  status : String,
) -> (String, String) {
  @async.with_timeout(3000, () => {
    let conn = @socket.Tcp::connect(addr)
    defer conn.close()
    conn.write(@utf8.encode(raw[:]))
    let reply = conn.read_all().text()
    guard reply.find("\r\n\r\n") is Some(split) else {
      fail("missing HTTP response headers")
    }
    let headers = reply[:split]
    assert_true(headers.has_prefix("HTTP/1.1 \{status}"))
    assert_true(headers.contains("Cache-Control: no-store"))
    assert_true(headers.contains("X-Content-Type-Options: nosniff"))
    assert_true(headers.contains("frame-ancestors 'none'"))
    assert_false(headers.contains("Access-Control-Allow-Origin"))
    (headers.to_owned(), reply[split + 4:].to_owned())
  })
}

///|
async fn exchange(addr : @socket.Addr, raw : String, status : String) -> String {
  let (_, body) = exchange_response(addr, raw, status)
  body
}

///|
fn scan_revision(headers : String) -> String raise {
  for line in headers.split("\r\n") {
    if line.split_once(": ") is Some((name, value)) &&
      name == SCAN_REVISION_HEADER &&
      !value.is_empty() {
      return value.to_owned()
    }
  }
  fail("missing scan revision")
}

///|
async test "loopback HTTP protects and reviews one scan session" {
  let root = @test_fs.tmpdir(prefix="moon-license-web")
  defer @test_fs.rmdir(root, recursive=true)
  @test_fs.write_file(root + "/license.txt", b"SPDX-License-Identifier: MIT\n")
  let session = @scan.Session::open(root)
  defer session.close()
  let listener = @socket.TcpServer(
    @socket.Addr::parse("127.0.0.1:0"),
    dual_stack=false,
  )
  let addr = listener.addr
  let host = "127.0.0.1:\{addr.port()}"
  @async.with_task_group(group => {
    group.spawn_bg(no_wait=true, () => serve_session(session, listener, host))
    let get = "GET / HTTP/1.1\r\nHost: \{host}\r\n"
    let html = exchange(addr, get + "Sec-Fetch-Site: none\r\n\r\n", "200")
    assert_true(html.contains("src=\"/app.js\""))
    assert_true(html.contains(">.git</textarea>"))
    let script = exchange(
      addr,
      "GET /app.js HTTP/1.1\r\nHost: \{host}\r\n\r\n",
      "200",
    )
    assert_true(script.contains(".textContent"))
    let denied = exchange(
      addr,
      "GET / HTTP/1.1\r\nHost: localhost:\{addr.port()}\r\n\r\n",
      "403",
    )
    assert_false(denied.contains(root))
    ignore(exchange(addr, get + "hOsT: \{host}\r\n\r\n", "400"))
    let long = "a".repeat(HEADER_LIMIT - get.length())
    ignore(exchange(addr, get + long, "431"))
    let foreign = "0".repeat(64)
    let preview_body = "{\"id\":\"\{foreign}\"}"
    let post = (path : String, body : String, status : String, extra : String) => {
      let prefix = "POST /api/\{path} HTTP/1.1\r\nHost: \{host}\r\nContent-Type: application/json\r\nContent-Length: \{@utf8.encode(body[:]).length()}\r\n"
      exchange_response(addr, prefix + extra + "\r\n" + body, status)
    }
    ignore(post("preview", preview_body, "409", ""))
    ignore(
      post(
        "scan",
        "{}",
        "403",
        "Origin: http://\{host}\r\nSec-Fetch-Site: same-site\r\n",
      ),
    )
    ignore(
      post(
        "scan", "{}", "403", "Origin: null\r\nSec-Fetch-Site: same-origin\r\n",
      ),
    )
    ignore(post("scan", "{}", "403", "Origin: https://example.invalid\r\n"))
    ignore(post("scan", "{}", "400", "Transfer-Encoding: chunked\r\n"))
    let over_scan_limit = 1024 * 1024 + 1
    ignore(
      exchange(
        addr,
        "POST /api/scan HTTP/1.1\r\nHost: \{host}\r\nContent-Type: application/json\r\nContent-Length: \{over_scan_limit}\r\n\r\n",
        "413",
      ),
    )
    ignore(post("preview", " ".repeat(1025), "413", ""))
    ignore(post("notice", " ".repeat(1025), "413", ""))
    ignore(post("scan", "{\"root\":\"untrusted\"}", "400", ""))
    let browser = "Origin: http://\{host}\r\nSec-Fetch-Site: same-origin\r\n"
    let (first_headers, report) = post("scan", "{}", "200", browser)
    let first_revision = scan_revision(first_headers)
    let first = browser + "\{SCAN_REVISION_HEADER}: \{first_revision}\r\n"
    guard @json.parse(report[:])
      is { "files": [{ "findings": [{ "id": String(id), .. }], .. }], .. } else {
      fail("expected one finding in the authorized directory")
    }
    let imported = report.replace_all(old=id, new=foreign)
    let (_, comparison) = post(
      "compare",
      "{\"previous\":" + imported + "}",
      "200",
      browser,
    )
    guard @json.parse(comparison[:]) is { "status": "comparable", .. } else {
      fail("expected the imported report to compare")
    }
    ignore(post("preview", preview_body, "404", browser))
    ignore(
      post(
        "compare",
        "{\"previous\":{},\"previous\":" + report + "}",
        "400",
        browser,
      ),
    )
    let valid_preview = "{\"id\":\"\{id}\"}"
    let (_, preview) = post("preview", valid_preview, "200", first)
    guard @json.parse(preview[:])
      is { "path": "license.txt", "text": String(text), .. } else {
      fail("expected source evidence from the current scan")
    }
    assert_true(text.contains("SPDX-License-Identifier: MIT"))
    let (_, notice) = post("notice", "{}", "200", first)
    assert_true(
      @json.parse(notice[:])
      is { "entries": [], "review": [{ "path": "license.txt", .. }], .. },
    )
    @test_fs.write_file(
      root + "/excluded.txt",
      b"SPDX-License-Identifier: MIT\n",
    )
    let options : Json = {
      "exclude": ["excluded.txt"],
      "max_file_bytes": 1024,
      "max_total_bytes": 2048,
      "max_entries": 100,
      "max_findings": 2,
    }
    let (second_headers, scoped) = post(
      "scan",
      " ".repeat(1025) + Json({ "options": options }).stringify(),
      "200",
      browser,
    )
    guard @json.parse(scoped[:])
      is { "options": effective, "files": Array(files), .. } else {
      fail("expected a scan report")
    }
    assert_eq(effective, options)
    assert_true(
      files.any(file => {
        file
        is {
          "path": "excluded.txt",
          "status": "skipped",
          "reason": "excluded",
          "findings": [],
          ..
        }
      }),
    )
    for
      invalid in [
        "{\"options\":{},\"root\":\"untrusted\"}", "{\"options\":{\"max_findings\":0}}",
        "{\"options\":{\"max_findings\":1.0000000000000001}}", "{\"options\":{\"exclude\":[\"../outside\"]}}",
      ] {
      ignore(post("scan", invalid, "400", browser))
    }
    assert_eq(Json(session.report()).stringify(), scoped)
    let second_revision = scan_revision(second_headers)
    assert_true(first_revision != second_revision)
    let second = browser + "\{SCAN_REVISION_HEADER}: \{second_revision}\r\n"
    let valid_compare = "{\"previous\":" + report + "}"
    for
      (operation, body) in [
        ("preview", valid_preview),
        ("notice", "{}"),
        ("compare", valid_compare),
      ] {
      let (_, stale) = post(operation, body, "409", first)
      assert_true(stale.contains("The current scan has changed"))
      ignore(post(operation, body, "200", second))
      ignore(post(operation, body, "200", browser))
    }
  })
}

///|
test "HTTP response limit counts UTF-8 bytes" {
  let prefix = "界".repeat(REPORT_LIMIT / 3)
  let response : Response = {
    status: "200 OK",
    content_type: "application/json",
    body: prefix + "a",
    scan_revision: Some("test-revision"),
  }
  let (accepted, bytes) = encode_response(response)
  assert_eq(accepted.status, "200 OK")
  assert_eq(bytes.length(), REPORT_LIMIT)
  let (rejected, bytes) = encode_response({ ..response, body: prefix + "aa", })
  assert_eq(rejected.status, "413 Content Too Large")
  assert_eq(rejected.scan_revision, None)
  assert_true(bytes.length() < 1024)
}
