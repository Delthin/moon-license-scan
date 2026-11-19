///|
/// A local scan session whose callers can only access the directory opened at
/// startup. An earlier report can be compared but cannot grant file access.
pub struct Session {
  priv boundary : @local.Root
  priv scanner : Scanner
  priv mut current : Report?
  priv mut closed : Bool
}

///|
pub fn Session::open(directory : String) -> Session raise {
  let boundary = @local.Root::open(directory)
  if !boundary.is_directory() {
    boundary.close()
    raise InvalidInput("server root must be a directory")
  }
  { boundary, scanner: Scanner::new(), current: None, closed: false, }
}

///|
pub fn Session::close(self : Session) -> Unit {
  self.boundary.close()
  self.current = None
  self.closed = true
}

///|
pub fn Session::scan(
  self : Session,
  options~ : ScanOptions = ScanOptions::default(),
) -> Report raise {
  if self.closed {
    raise InvalidInput("scan session is closed")
  }
  let report = self.scanner.scan_at(self.boundary, options)
  self.current = Some(report)
  report
}

///|
pub fn Session::report(self : Session) -> Report raise ScanError {
  guard self.current is Some(report) else {
    raise InvalidInput("scan the authorized directory first")
  }
  report
}

///|
pub fn Session::preview(self : Session, id : String) -> Preview raise {
  self.scanner.preview_at(self.boundary, self.report(), id)
}

///|
pub fn Session::compare(self : Session, previous : Report) -> Json raise {
  compare(previous, self.report())
}

///|
pub fn Session::notice(self : Session) -> Json raise {
  self.scanner.notice_at(self.boundary, self.report())
}
