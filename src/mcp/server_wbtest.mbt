///|
test "large multibyte replies return a bounded error with the request ID" {
  let value = success(Json(123), Json("界".repeat(140)))
  let reply = encode_reply(value, limit=256)
  assert_true(reply.length() < 256)
  let response = @json.parse(@utf8.decode(reply[:]))
  guard response is { "id": 123, "result": { "isError": true, .. }, .. } else {
    fail("a UTF-8 overflow must return a tool error for the same request")
  }
}
