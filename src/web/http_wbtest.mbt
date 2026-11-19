///|
async fn exchange(addr : @socket.Addr, raw : String, status : String) -> String {
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
    reply[split + 4:].to_owned()
  })
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
      let prefix = "POST /api/\{path} HTTP/1.1\r\nHost: \{host}\r\nContent-Type: application/json\r\nContent-Length: \{body.length()}\r\n"
      exchange(addr, prefix + extra + "\r\n" + body, status)
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
    let report = post("scan", "{}", "200", browser)
    guard @json.parse(report[:])
      is { "files": [{ "findings": [{ "id": String(id), .. }], .. }], .. } else {
      fail("expected one finding in the authorized directory")
    }
    let imported = report.replace_all(old=id, new=foreign)
    let comparison = post(
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
    let preview = post("preview", "{\"id\":\"\{id}\"}", "200", browser)
    guard @json.parse(preview[:])
      is { "path": "license.txt", "text": String(text), .. } else {
      fail("expected source evidence from the current scan")
    }
    assert_true(text.contains("SPDX-License-Identifier: MIT"))
    let notice = post("notice", "{}", "200", browser)
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
    let scoped = post(
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
    assert_eq(session.report().to_json().stringify(), scoped)
    ignore(post("preview", "{\"id\":\"\{id}\"}", "200", browser))
  })
}
