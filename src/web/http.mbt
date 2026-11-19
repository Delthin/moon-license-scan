///|
const HEADER_LIMIT : Int32 = 8192

///|
const REPORT_LIMIT : Int32 = 16 * 1024 * 1024

///|
priv struct Request {
  verb : String
  target : String
  headers : Map[String, String]
}

///|
priv suberror RequestError {
  BadRequest
  Forbidden
  NotFound
  MethodNotAllowed
  TooLarge
  HeadersTooLarge
  WrongContentType
  LengthRequired
}

///|
fn http_token(value : StringView) -> Bool {
  if value.length() == 0 {
    return false
  }
  for c in value {
    if !(c
      is ('a'..<='z'
      | 'A'..<='Z'
      | '0'..<='9'
      | '!'
      | '#'
      | '$'
      | '%'
      | '&'
      | '\''
      | '*'
      | '+'
      | '-'
      | '.'
      | '^'
      | '_'
      | '`'
      | '|'
      | '~')) {
      return false
    }
  }
  true
}

///|
fn parse_head(head : String) -> Request raise RequestError {
  let lines = head.split("\r\n").collect()
  guard lines.get(0) is Some(start) &&
    start.split(" ").collect() is [verb, target, "HTTP/1.1"] &&
    http_token(verb) &&
    target.has_prefix("/") else {
    raise BadRequest
  }
  for c in target {
    if !(c is ('!'..<='~')) {
      raise BadRequest
    }
  }
  let headers : Map[String, String] = Map([])
  for i in 1..<lines.length() {
    let line = lines[i]
    guard line.find(":") is Some(colon) else { raise BadRequest }
    let name = line[:colon]
    let value = line[colon + 1:]
    guard http_token(name) else { raise BadRequest }
    for c in value {
      if !(c is ('\t' | ' '..<='~')) {
        raise BadRequest
      }
    }
    let name = name.to_owned().to_lower()
    guard !headers.contains(name) else { raise BadRequest }
    headers[name] = value.trim(chars=" \t").to_owned()
  }
  { verb: verb.to_owned(), target: target.to_owned(), headers, }
}

///|
async fn read_head(conn : @socket.Tcp) -> (Request, Bytes) {
  // This endpoint handles one bounded HTTP/1.1 message per connection.
  let buf = FixedArray::make(HEADER_LIMIT, b'\x00')
  for used = 0, next = 0; used < HEADER_LIMIT; {
    let n = conn.read(buf, offset=used, max_len=HEADER_LIMIT - used)
    guard n > 0 else { raise BadRequest }
    let end = used + n
    for i in next..<(end - 3) {
      if buf[i] == b'\r' &&
        buf[i + 1] == b'\n' &&
        buf[i + 2] == b'\r' &&
        buf[i + 3] == b'\n' {
        let bytes = Bytes::from_array(buf[:end])
        let head = @utf8.decode(bytes[:i]) catch { _ => raise BadRequest }
        return (parse_head(head), bytes[i + 4:].to_owned())
      }
    }
    continue end, (end - 3).max(0)
  }
  raise HeadersTooLarge
}

///|
fn check_origin(req : Request, host : String) -> Unit raise RequestError {
  guard req.headers.get("host") == Some(host) else { raise Forbidden }
  let origin = req.headers.get("origin")
  let site = req.headers.get("sec-fetch-site")
  guard origin is None || origin == Some("http://\{host}") else {
    raise Forbidden
  }
  guard site is (None | Some("same-origin")) ||
    (req.verb == "GET" && site is Some("none")) else {
    raise Forbidden
  }
  if req.verb == "POST" && site is Some(_) && origin is None {
    raise Forbidden
  }
}

///|
fn body_length(req : Request) -> Int32 raise RequestError {
  guard !req.headers.contains("transfer-encoding") &&
    !req.headers.contains("content-encoding") &&
    !req.headers.contains("expect") else {
    raise BadRequest
  }
  let raw = match req.headers.get("content-length") {
    Some(raw) => raw
    None if req.verb == "GET" => "0"
    None => raise LengthRequired
  }
  guard !raw.is_empty() else { raise BadRequest }
  let max = match req.target {
    "/api/compare" => REPORT_LIMIT + 32
    "/api/scan" => 1024 * 1024
    _ => 1024
  }
  let mut length = 0
  for c in raw {
    guard c is ('0'..<='9') else { raise BadRequest }
    length = length * 10 + c.to_int() - '0'.to_int()
    if length > max {
      raise TooLarge
    }
  }
  if req.verb == "GET" {
    guard length == 0 else { raise BadRequest }
  } else {
    let mime = req.headers.get("content-type").unwrap_or("").to_lower()
    guard mime is ("application/json" | "application/json; charset=utf-8") else {
      raise WrongContentType
    }
  }
  length
}

///|
async fn read_json(conn : @socket.Tcp, prefix : Bytes, length : Int32) -> Json {
  guard prefix.length() <= length else { raise BadRequest }
  let bytes = if prefix.length() == length {
    prefix
  } else {
    let tail = conn.read_exactly(length - prefix.length())
    prefix + tail
  }
  let text = @utf8.decode(bytes[:]) catch { _ => raise BadRequest }
  @json.parse(
    text[:],
    max_nesting_depth=17,
    reject_duplicate_keys=true,
    preserve_number_repr=true,
  ) catch {
    _ => raise BadRequest
  }
}

///|
priv struct Response {
  status : String
  content_type : String
  body : String
}

///|
fn json_reply(status : String, data : Json) -> Response {
  {
    status,
    content_type: "application/json; charset=utf-8",
    body: data.stringify(),
  }
}

///|
fn error_reply(status : String, message : String) -> Response {
  json_reply(status, { "error": Json(message) })
}

///|
async fn send_response(conn : @socket.Tcp, response : Response) -> Unit {
  let body = @utf8.encode(response.body[:])
  let head = "HTTP/1.1 \{response.status}\r\nContent-Type: \{response.content_type}\r\nContent-Length: \{body.length()}\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nX-Frame-Options: DENY\r\nReferrer-Policy: same-origin\r\nContent-Security-Policy: default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'\r\n\r\n"
  conn.write(@utf8.encode(head[:]))
  conn.write(body)
}
