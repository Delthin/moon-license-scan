///|
extern "C" fn exit(code : Int32) -> Unit = "exit"

///|
suberror Usage {
  Usage(String)
}

///|
let help : String =
  #|Usage: moon-license-scan COMMAND
  #|
  #|  scan PATH [--json] [--output FILE] [--exclude PATH]...
  #|  preview PATH REPORT ID [--output FILE]
  #|  compare PREVIOUS CURRENT [--output FILE]
  #|  notice PATH REPORT [--output FILE]
  #|  mcp DIRECTORY
  #|  serve DIRECTORY [--port PORT]
  #|
  #|Scan limits: --max-file-bytes N, --max-total-bytes N, --max-entries N,
  #|             --max-findings N. Paths in --exclude are root-relative prefixes.
  #|Keep --json reports for preview and comparison. --output creates a new file.

///|
fn number(flag : String, value : String) -> Int32 raise Usage {
  let result = @string.parse_int(value[:]) catch {
    _ => raise Usage("Expected a positive integer after " + flag)
  }
  if result <= 0 {
    raise Usage("Expected a positive integer after " + flag)
  }
  result
}

///|
fn report_from(path : String) -> @scan.Report raise {
  let root = @local.Root::open(path)
  defer root.close()
  guard !root.is_directory() else { raise Usage("Expected a report file") }
  let bytes = root.read(root.file_name(), 16 * 1024 * 1024)
  guard bytes.length() <= 16 * 1024 * 1024 else {
    raise Usage("Report exceeds 16 MiB")
  }
  @scan.parse_report(@utf8.decode(bytes[:]))
}

///|
async fn emit(content : String, output : String?) -> Unit {
  guard output is Some(path) else {
    @stdio.stdout.write(content + "\n")
    return
  }
  let temporary = path + ".moon-license-scan-\{@env.now()}"
  let file = @fs.open(
    temporary,
    mode=WriteOnly,
    create_mode=CreateNew,
    permission=0o600,
  )
  let mut committed = false
  defer (if !committed { @fs.remove(temporary) catch { _ => () } })
  {
    defer file.close()
    file.write(content + "\n")
    file.sync()
  }
  @fs.rename(temporary, path, replace=false)
  committed = true
}

///|
fn render(report : @scan.Report) -> String {
  let out = StringBuilder()
  let mut count = 0
  for file in report.files {
    count += file.findings.length()
    for hit in file.findings {
      out.write_string(
        "\{file.path}:\{hit.start_line}-\{hit.end_line}  \{hit.expression}  [\{hit.kind}, \{hit.scope}]  \{hit.id}\n",
      )
    }
    if file.reason is Some(reason) {
      out.write_string("\{file.path}  \{file.status}: \{reason}\n")
    }
    if !file.review.is_empty() {
      let flags = file.review.join(", ")
      out.write_string("\{file.path}  review: \{flags}\n")
    }
  }
  for diagnostic in report.diagnostics {
    out.write_string("scan: \{diagnostic}\n")
  }
  let complete = if report.enumeration_complete {
    "complete"
  } else {
    "incomplete"
  }
  out.write_string(
    "\{count} evidence records; \{report.entries} entries visited; enumeration \{complete}.",
  )
  out.to_string()
}

///|
async fn scan_command(path : String, flags : ArrayView[String]) -> Unit {
  let defaults = @scan.ScanOptions::default()
  let mut max_file_bytes = defaults.max_file_bytes
  let mut max_total_bytes = defaults.max_total_bytes
  let mut max_entries = defaults.max_entries
  let mut max_findings = defaults.max_findings
  let exclude = defaults.exclude
  let mut output = None
  let mut json = false
  for i = 0; i < flags.length(); {
    let flag = flags[i]
    if flag == "--json" {
      json = true
      continue i + 1
    }
    guard flags.get(i + 1) is Some(value) && !value.is_empty() else {
      raise Usage("Expected a value after " + flag)
    }
    match flag {
      "--exclude" => exclude.push(value)
      "--output" => output = Some(value)
      "--max-file-bytes" => max_file_bytes = number(flag, value)
      "--max-total-bytes" => max_total_bytes = number(flag, value)
      "--max-entries" => max_entries = number(flag, value)
      "--max-findings" => max_findings = number(flag, value)
      _ => raise Usage("Unknown option: " + flag)
    }
    continue i + 2
  }
  let options : @scan.ScanOptions = {
    max_file_bytes,
    max_total_bytes,
    max_entries,
    max_findings,
    exclude,
  }
  let report = @scan.Scanner::new().scan(path, options~)
  emit(if json { Json(report).stringify() } else { render(report) }, output)
}

///|
fn output_flag(args : ArrayView[String]) -> String? raise Usage {
  match args {
    [] => None
    ["--output", path] if !path.is_empty() => Some(path)
    _ => raise Usage("Expected only an optional --output FILE")
  }
}

///|
async fn run(args : Array[String]) -> Unit {
  match args[:] {
    [_] | [_, "--help"] | [_, "-h"] => @stdio.stdout.write(help + "\n")
    [_, "scan", path, .. flags] => scan_command(path, flags)
    [_, "mcp", path] => @mcp.serve(path)
    [_, "serve", path] => @web.serve(path, 0)
    [_, "serve", path, "--port", value] => {
      let port = @string.parse_int(value[:]) catch {
        _ => raise Usage("Expected a port from 0 to 65535")
      }
      guard 0 <= port && port <= 65535 else {
        raise Usage("Expected a port from 0 to 65535")
      }
      @web.serve(path, port)
    }
    [_, "preview", path, report_path, id, .. flags] => {
      let output = output_flag(flags)
      let current = report_from(report_path)
      emit(
        Json(@scan.Scanner::new().preview(path, current, id)).stringify(),
        output,
      )
    }
    [_, "compare", previous, current, .. flags] => {
      let output = output_flag(flags)
      emit(
        @scan.compare(report_from(previous), report_from(current)).stringify(),
        output,
      )
    }
    [_, "notice", path, report_path, .. flags] => {
      let output = output_flag(flags)
      emit(
        @scan.Scanner::new().notice(path, report_from(report_path)).stringify(),
        output,
      )
    }
    _ => raise Usage("Invalid command. Run moon-license-scan --help.")
  }
}

///|
async fn main {
  run(@env.args()) catch {
    Usage(message) => {
      @stdio.stderr.write(message + "\n")
      exit(2)
    }
    error => {
      @stdio.stderr.write("moon-license-scan: \{error}\n")
      exit(1)
    }
  }
}
