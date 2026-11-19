///|
priv suberror StartupError {
  InvalidPort
  RootUnavailable
  ListenUnavailable
}

///|
fn static_reply(content_type : String, body : String) -> Response {
  { status: "200 OK", content_type, body, }
}

///|
fn api_reply(
  session : @scan.Session,
  target : String,
  body : Json,
) -> Response raise RequestError {
  if target == "/api/scan" {
    let options = match body {
      Object(fields) if fields.is_empty() => @scan.ScanOptions::default()
      Object(fields) if fields.length() == 1 &&
        fields.get("options") is Some(input) =>
        @scan.ScanOptions::parse_options(input) catch {
          @scan.InvalidInput(message) =>
            return error_reply("400 Bad Request", message)
          _ => raise BadRequest
        }
      _ => raise BadRequest
    }
    return json_reply("200 OK", session.scan(options~).to_json()) catch {
      _ =>
        error_reply(
          "500 Internal Server Error", "The authorized directory could not be scanned.",
        )
    }
  }
  // Validate the caller's data even when there is no active scan.
  guard body is Object(fields) else { raise BadRequest }
  match target {
    "/api/preview" => {
      guard fields.length() == 1 &&
        fields.get("id") is Some(String(id)) &&
        id.length() == 64 else {
        raise BadRequest
      }
      for c in id {
        if !(c is ('0'..<='9' | 'a'..<='f')) {
          raise BadRequest
        }
      }
      guard has_current(session) else { return scan_first() }
      json_reply("200 OK", session.preview(id).to_json()) catch {
        @scan.UnknownEvidence =>
          error_reply("404 Not Found", "Evidence is not in the current scan.")
        @scan.LimitExceeded(_) =>
          error_reply(
            "413 Content Too Large", "The evidence is too large to preview.",
          )
        _ =>
          error_reply(
            "409 Conflict", "The evidence is no longer readable as scanned. Scan again.",
          )
      }
    }
    "/api/compare" => {
      guard fields.length() == 1 &&
        fields.get("previous") is Some(Object(_) as previous) else {
        raise BadRequest
      }
      guard has_current(session) else { return scan_first() }
      let parsed = @scan.parse_report(previous.stringify()) catch {
        @scan.LimitExceeded(_) =>
          return error_reply(
            "413 Content Too Large", "The previous report is larger than 16 MiB.",
          )
        _ =>
          return error_reply(
            "400 Bad Request", "The previous report's version or contents are invalid.",
          )
      }
      json_reply("200 OK", session.compare(parsed)) catch {
        @scan.LimitExceeded(_) =>
          error_reply("413 Content Too Large", "The comparison is too large.")
        _ =>
          error_reply("400 Bad Request", "These reports could not be compared.")
      }
    }
    "/api/notice" => {
      guard fields.is_empty() else { raise BadRequest }
      guard has_current(session) else { return scan_first() }
      json_reply("200 OK", session.notice()) catch {
        @scan.LimitExceeded(_) =>
          error_reply(
            "413 Content Too Large", "The notice candidates are too large.",
          )
        _ =>
          error_reply(
            "409 Conflict", "Notice candidates could not be verified. Scan again.",
          )
      }
    }
    _ => raise NotFound
  }
}

///|
fn has_current(session : @scan.Session) -> Bool {
  ignore(session.report()) catch {
    _ => return false
  }
  true
}

///|
fn scan_first() -> Response {
  error_reply("409 Conflict", "Scan the authorized directory first.")
}

///|
async fn route(
  session : @scan.Session,
  host : String,
  conn : @socket.Tcp,
) -> Response {
  let (req, prefix) = @async.with_timeout(5000, () => read_head(conn))
  check_origin(req, host)
  match req.target {
    "/" | "/app.js" | "/app.css" => {
      guard req.verb == "GET" else { raise MethodNotAllowed }
      ignore(body_length(req))
      guard prefix.is_empty() else { raise BadRequest }
      match req.target {
        "/" => static_reply("text/html; charset=utf-8", page)
        "/app.js" => static_reply("text/javascript; charset=utf-8", script)
        _ => static_reply("text/css; charset=utf-8", style)
      }
    }
    "/api/scan" | "/api/preview" | "/api/compare" | "/api/notice" => {
      guard req.verb == "POST" else { raise MethodNotAllowed }
      let length = body_length(req)
      let body = @async.with_timeout(15000, () => {
        read_json(conn, prefix, length)
      })
      api_reply(session, req.target, body)
    }
    _ => raise NotFound
  }
}

///|
fn request_error(error : Error) -> Response {
  match error {
    Forbidden =>
      error_reply(
        "403 Forbidden", "This local address or request origin is not allowed.",
      )
    NotFound => error_reply("404 Not Found", "This route does not exist.")
    MethodNotAllowed =>
      error_reply(
        "405 Method Not Allowed", "This method is not allowed for the route.",
      )
    TooLarge =>
      error_reply("413 Content Too Large", "The request body is too large.")
    HeadersTooLarge =>
      error_reply(
        "431 Request Header Fields Too Large", "The request headers are too large.",
      )
    WrongContentType =>
      error_reply(
        "415 Unsupported Media Type", "Send an application/json body.",
      )
    LengthRequired =>
      error_reply("411 Length Required", "Send a Content-Length header.")
    @async.TimeoutError =>
      error_reply("408 Request Timeout", "The request timed out.")
    _ => error_reply("400 Bad Request", "The request is invalid.")
  }
}

///|
/// Open one authorized directory and serve its review workbench on IPv4
/// loopback until cancelled. Port 0 chooses an available port. The actual
/// address is printed after the listener has started.
pub async fn serve(root : String, port : Int32) -> Unit {
  guard port >= 0 && port <= 65535 else { raise InvalidPort }
  let session = @scan.Session::open(root) catch { _ => raise RootUnavailable }
  defer session.close()
  let addr = @socket.Addr::parse("127.0.0.1:\{port}")
  let listener = @socket.TcpServer(addr, dual_stack=false) catch {
    _ => raise ListenUnavailable
  }
  let host = "127.0.0.1:\{listener.addr.port()}"
  println("License review: http://\{host}")
  serve_session(session, listener, host)
}

///|
async fn serve_session(
  session : @scan.Session,
  listener : @socket.TcpServer,
  host : String,
) -> Unit {
  listener.run_forever(max_connections=4, (conn, _) => {
    let response = route(session, host, conn) catch {
      error => request_error(error)
    }
    @async.with_timeout(15000, () => send_response(conn, response))
  })
}
