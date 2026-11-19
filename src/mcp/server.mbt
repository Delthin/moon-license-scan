///|
priv struct Wire {
  mut chunk : Bytes
  mut offset : Int32
}

///|
priv enum Frame {
  End
  OverLimit
  Message(Bytes)
}

///|
async fn Wire::next(self : Wire) -> Frame {
  let line = @buffer.Buffer(size_hint=256)
  let mut full = false
  for ;; {
    if self.offset == self.chunk.length() {
      guard @stdio.stdin.read_some(max_len=4096) is Some(chunk) else {
        return End
      }
      self.chunk = chunk
      self.offset = 0
    }
    let b = self.chunk[self.offset]
    self.offset += 1
    if b == b'\n' {
      return if full { OverLimit } else { Message(line.to_bytes()) }
    }
    if !full {
      if line.length() >= 16 * 1024 * 1024 + 65536 {
        full = true
        line.reset()
      } else {
        line.write_byte(b)
      }
    }
  }
}

///|
fn success(id : Json, value : Json) -> Json {
  { "jsonrpc": "2.0", "id": id, "result": value }
}

///|
fn failure(id : Json, code : Int32, message : String) -> Json {
  {
    "jsonrpc": "2.0",
    "id": id,
    "error": { "code": Json(code), "message": Json(message) },
  }
}

///|
fn page(report : @scan.Report, offset : Int32, limit : Int32) -> Json {
  let last = (offset + limit).min(report.files.length())
  let files : Array[@scan.FileResult] = []
  for i in offset..<last {
    files.push(report.files[i])
  }
  {
    "schema_version": Json(report.schema_version),
    "rules_version": Json(report.rules_version),
    "directory": Json(report.directory),
    "options": Json(report.options),
    "enumeration_complete": Json(report.enumeration_complete),
    "entries": Json(report.entries),
    "bytes_read": Json(report.bytes_read),
    "diagnostics": Json(report.diagnostics),
    "file_count": Json(report.files.length()),
    "offset": Json(offset),
    "next_offset": if last < report.files.length() {
      Json(last)
    } else {
      Json::null()
    },
    "files": Json(files),
  }
}

///|
fn tool(
  name : String,
  description : String,
  properties : Json,
  required : Array[String],
) -> Json {
  {
    "name": Json(name),
    "description": Json(description),
    "annotations": { "readOnlyHint": true, "openWorldHint": false },
    "inputSchema": {
      "type": "object",
      "properties": properties,
      "required": Json(required),
      "additionalProperties": false,
    },
  }
}

///|
fn catalog() -> Json {
  {
    "tools": [
      tool(
        "license_scan",
        "Scan the startup directory and return the first page of evidence.",
        {
          "options": {
            "type": "object",
            "additionalProperties": false,
            "properties": {
              "max_file_bytes": { "type": "integer", "minimum": 1 },
              "max_total_bytes": { "type": "integer", "minimum": 1 },
              "max_entries": { "type": "integer", "minimum": 1 },
              "max_findings": { "type": "integer", "minimum": 1 },
              "exclude": { "type": "array", "items": { "type": "string" } },
            },
          },
        },
        [],
      ),
      tool(
        "license_report",
        "Read a page of the current report by offset.",
        {
          "offset": { "type": "integer", "minimum": 0 },
          "limit": { "type": "integer", "minimum": 1, "maximum": 50 },
        },
        [],
      ),
      tool(
        "license_preview",
        "Read verified source lines for a current evidence ID.",
        { "id": { "type": "string", "pattern": "^[a-f0-9]{64}$" } },
        ["id"],
      ),
      tool(
        "license_compare",
        "Compare a previous JSON report with the current scan.",
        { "previous": { "type": "object" } },
        ["previous"],
      ),
      tool(
        "license_notice",
        "Export deduplicated declaration candidates and review items.",
        {},
        [],
      ),
    ],
  }
}

///|
priv suberror InvalidArguments

///|
fn permitted(
  args : Map[String, Json],
  names : Array[String],
) -> Unit raise InvalidArguments {
  for key, _ in args {
    if !names.contains(key) {
      raise InvalidArguments
    }
  }
}

///|
fn bounded(
  args : Map[String, Json],
  key : String,
  default : Int32,
  low : Int32,
  high : Int32,
) -> Int32 raise InvalidArguments {
  guard args.get(key) is Some(value) else { return default }
  guard value is Number(x, ..) &&
    x >= low.to_double() &&
    x <= high.to_double() &&
    x == x.to_int().to_double() else {
    raise InvalidArguments
  }
  x.to_int()
}

///|
fn invoke(
  session : @scan.Session,
  name : String,
  args : Map[String, Json],
) -> Json raise {
  match name {
    "license_scan" => {
      permitted(args, ["options"])
      let options : @scan.ScanOptions = match args.get("options") {
        None => @scan.ScanOptions::default()
        Some(value) => @scan.ScanOptions::parse_options(value)
      }
      page(session.scan(options~), 0, 20)
    }
    "license_report" => {
      permitted(args, ["offset", "limit"])
      let report = session.report()
      page(
        report,
        bounded(args, "offset", 0, 0, report.files.length()),
        bounded(args, "limit", 20, 1, 50),
      )
    }
    "license_preview" => {
      permitted(args, ["id"])
      guard args.get("id") is Some(String(id)) && id.length() == 64 else {
        raise InvalidArguments
      }
      for ch in id {
        if !(('a' <= ch && ch <= 'f') || ('0' <= ch && ch <= '9')) {
          raise InvalidArguments
        }
      }
      Json(session.preview(id))
    }
    "license_compare" => {
      permitted(args, ["previous"])
      guard args.get("previous") is Some(Object(_) as previous) else {
        raise InvalidArguments
      }
      session.compare(@scan.parse_report(previous.stringify()))
    }
    "license_notice" => {
      permitted(args, [])
      session.notice()
    }
    _ => raise InvalidArguments
  }
}

///|
fn tool_error(message : String) -> Json {
  { "isError": true, "content": [{ "type": "text", "text": Json(message) }] }
}

///|
fn tool_result(value : Json) -> Json {
  let text = value.stringify()
  if text.length() > 16 * 1024 * 1024 {
    return tool_error("Result exceeds the transport limit; narrow the scan.")
  }
  let message = if text.length() <= 65536 {
    text
  } else {
    "Read the structuredContent field for the complete result."
  }
  {
    "structuredContent": value,
    "content": [{ "type": "text", "text": Json(message) }],
  }
}

///|
fn valid_id(id : Json) -> Bool {
  match id {
    String(value) => value.length() <= 128
    Number(value, ..) =>
      value >= -2147483648.0 &&
      value <= 2147483647.0 &&
      value == value.to_int().to_double()
    _ => false
  }
}

///|
priv enum Stage {
  AwaitInitialize
  AwaitInitialized
  Ready
}

///|
priv struct Server {
  session : @scan.Session
  mut stage : Stage
}

///|
fn Server::dispatch(self : Server, request : Json) -> Json? {
  let null_id = Json::null()
  guard request is Object(fields) &&
    fields.get("jsonrpc") == Some(Json("2.0")) &&
    fields.get("method") is Some(String(rpc_method)) else {
    return Some(failure(null_id, -32600, "Invalid request"))
  }
  let params = fields.get("params").unwrap_or(Json::empty_object())
  guard fields.get("id") is Some(id) else {
    if rpc_method == "notifications/initialized" &&
      self.stage is AwaitInitialized &&
      params is Object(_) {
      self.stage = Ready
    }
    return None
  }
  guard valid_id(id) else {
    return Some(failure(null_id, -32600, "Invalid request ID"))
  }
  guard params is Object(_) else {
    return Some(failure(id, -32602, "Invalid params"))
  }
  if rpc_method == "ping" {
    return Some(success(id, Json::empty_object()))
  }
  if rpc_method == "initialize" {
    guard self.stage is AwaitInitialize &&
      params
      is {
        "protocolVersion": String(version),
        "capabilities": Object(_),
        "clientInfo": { "name": String(_), "version": String(_), .. },
        ..
      } else {
      return Some(failure(id, -32602, "Invalid initialize request"))
    }
    self.stage = AwaitInitialized
    let version = if version == "2025-06-18" { version } else { "2025-11-25" }
    return Some(
      success(id, {
        "protocolVersion": Json(version),
        "serverInfo": { "name": "moon-license-scan", "version": "0.1.1" },
        "capabilities": { "tools": {} },
      }),
    )
  }
  guard self.stage is Ready else {
    return Some(failure(id, -32000, "Initialize the MCP session first"))
  }
  match rpc_method {
    "tools/list" => Some(success(id, catalog()))
    "tools/call" => {
      guard params is { "name": String(name), .. } &&
        params is Object(params) &&
        params.get("arguments").unwrap_or(Json::empty_object())
        is Object(arguments) else {
        return Some(
          failure(id, -32602, "Expected a tool name and an arguments object"),
        )
      }
      let result = tool_result(invoke(self.session, name, arguments)) catch {
        InvalidArguments =>
          return Some(failure(id, -32602, "Unknown tool or invalid arguments"))
        @scan.StaleEvidence =>
          tool_error("Evidence has changed. Scan again before opening it.")
        @scan.UnknownEvidence =>
          tool_error("Unknown evidence ID in the current scan.")
        @scan.InvalidInput(message) => tool_error(message)
        _ =>
          tool_error(
            "Unable to complete this operation within the startup directory.",
          )
      }
      Some(success(id, result))
    }
    _ => Some(failure(id, -32601, "Method not found"))
  }
}

///|
pub async fn serve(root : String) -> Unit {
  let session = @scan.Session::open(root)
  defer session.close()
  let server : Server = { session, stage: AwaitInitialize, }
  let wire : Wire = { chunk: b"", offset: 0, }
  for ;; {
    let reply = match wire.next() {
      End => return
      OverLimit =>
        Some(failure(Json::null(), -32600, "Message exceeds input limit"))
      Message(bytes) =>
        server.dispatch(
          @json.parse(
            @utf8.decode(bytes[:]),
            reject_duplicate_keys=true,
            max_nesting_depth=17,
            preserve_number_repr=true,
          ),
        ) catch {
          _ => Some(failure(Json::null(), -32700, "Invalid JSON"))
        }
    }
    if reply is Some(value) {
      @stdio.stdout.write(value.stringify() + "\n")
    }
  }
}
