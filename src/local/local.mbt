///|
/// An open directory or regular file. Closing the root invalidates its reads.
pub struct Root {
  priv file : NativeFile
  priv directory : Bool
  priv name : String
  priv mut closed : Bool
}

///|
/// One immediate child, with a slash-separated path relative to the scan root.
/// A name that cannot be represented as UTF-8 uses a non-openable path.
pub(all) struct Entry {
  path : String
  kind : String
}

///|
priv suberror LocalError {
  InvalidPath(String)
  InvalidLimit
  ClosedRoot
  NotDirectory
  Filesystem(String, Int32)
}

///|
impl Show for LocalError with fn to_string(self) {
  match self {
    InvalidPath(_) => "invalid filesystem path"
    InvalidLimit => "invalid filesystem limit"
    ClosedRoot => "scan root is closed"
    NotDirectory => "scan root is not a directory"
    Filesystem(operation, code) => "\{operation} failed (OS code \{code})"
  }
}

///|
fn encode_path(path : StringView) -> Bytes raise {
  // The native Windows path limit is 32,767 UTF-16 units; allow their UTF-8 form.
  if path.is_empty() || path.length() > 32767 || path.contains("\u0000") {
    raise InvalidPath(path.to_owned())
  }
  let bytes = @utf8.encode(path)
  if @utf8.decode(bytes[:]) != path.to_owned() {
    raise InvalidPath(path.to_owned())
  }
  bytes
}

///|
fn components(path : String) -> Iter[StringView] raise {
  ignore(encode_path(path[:]))
  let windows = native_windows()
  if path
    .split("/")
    .any(part => {
      part == "" ||
      part == "." ||
      part == ".." ||
      (windows && (part.contains("\\") || part.contains(":")))
    }) {
    raise InvalidPath(path)
  }
  path.split("/")
}

///|
fn check_file(file : NativeFile, operation : String) -> Unit raise {
  let code = native_file_error(file)
  if code != 0 {
    raise Filesystem(operation, code)
  }
}

///|
/// Open the selected directory or regular file without following a final link.
/// The caller authorizes this root path, including any aliases in its parents.
/// Once open, every descendant component is resolved without following links.
pub fn Root::open(path : String) -> Root raise {
  let windows = native_windows()
  let separators = if windows { "/\\" } else { "/" }
  let selected = for selected = path[:].trim_end(chars=separators) {
    if selected.has_suffix("/.") || (windows && selected.has_suffix("\\.")) {
      continue selected[:selected.length() - 2].trim_end(chars=separators)
    }
    break selected
  }
  let original = encode_path(path[:])
  let file = if selected.length() == path.length() ||
    (
      windows &&
      (
        selected.is_empty() ||
        (selected.length() == 2 && selected.get_char(1) == Some(':'))
      )
    ) {
    // Keep the separator on Windows drive roots: C:/ and C: differ.
    native_root(original)
  } else {
    native_root(encode_path(if selected.is_empty() { "/" } else { selected }))
  }
  check_file(file, "open root")
  let directory = native_kind(file) == 2
  if !directory && selected.length() != path.length() {
    native_close(file)
    raise NotDirectory
  }
  let name = if directory {
    ""
  } else {
    let slash = selected.rev_find("/").unwrap_or(-1)
    let start = if windows {
      let backslash = selected.rev_find("\\").unwrap_or(-1)
      if slash < 0 && backslash < 0 && selected.get_char(1) == Some(':') {
        2
      } else {
        @cmp.maximum(slash, backslash) + 1
      }
    } else {
      slash + 1
    }
    selected[start:].to_owned()
  }
  { file, directory, name, closed: false, }
}

///|
/// Close the root. It is safe to call this more than once.
pub fn Root::close(self : Root) -> Unit {
  self.closed = true
  native_close(self.file)
}

///|
pub fn Root::is_directory(self : Root) -> Bool {
  self.directory
}

///|
/// Return the selected file's basename, or an empty string for a directory.
pub fn Root::file_name(self : Root) -> String {
  self.name
}

///|
fn Root::resolve(
  self : Root,
  path : String,
  directory : Bool,
) -> NativeFile raise {
  if self.closed {
    raise ClosedRoot
  }
  if !self.directory {
    if !directory && self.name == path {
      ignore(components(path))
      return self.file
    }
    if directory {
      raise NotDirectory
    }
    raise InvalidPath(path)
  }
  if directory && path == "" {
    return self.file
  }
  let parts = components(path)
  for part in parts; parent = self.file, offset = 0 {
    let next_offset = offset + part.length() + 1
    let child = native_child(
      parent,
      @utf8.encode(part),
      directory || next_offset <= path.length(),
    )
    if offset != 0 {
      native_close(parent)
    }
    check_file(child, if directory { "open directory" } else { "open file" })
    continue child, next_offset
  } nobreak {
    parent
  }
}

///|
fn decode_entry(prefix : String, entry : Bytes) -> Entry {
  let name = @utf8.decode(entry[1:]) catch { _ => "" }
  if name == "" {
    // NUL cannot be part of a native name and is rejected by path validation.
    return { path: prefix + "\u0000", kind: "unreadable", }
  }
  let kind = match entry[0] {
    b'\x01' => "file"
    b'\x02' => "directory"
    b'\x03' => "link"
    b'\x04' => "other"
    _ => "unreadable"
  }
  { path: prefix + name, kind, }
}

///|
/// List at most limit immediate children. The second result indicates EOF;
/// an exact-limit directory can be complete. Use "" for the root directory.
pub fn Root::list(
  self : Root,
  relative_directory : String,
  limit : Int32,
) -> (Array[Entry], Bool) raise {
  if limit < 0 {
    raise InvalidLimit
  }
  let parent = self.resolve(relative_directory, true)
  let directory = native_directory(parent)
  if relative_directory != "" {
    native_close(parent)
  }
  defer native_directory_close(directory)
  let open_code = native_directory_error(directory)
  if open_code != 0 {
    raise Filesystem("open directory cursor", open_code)
  }
  let entries : Array[Entry] = []
  let prefix = if relative_directory == "" {
    ""
  } else {
    relative_directory + "/"
  }
  for ;; {
    let entry = native_next(directory)
    let code = native_directory_error(directory)
    if code != 0 {
      raise Filesystem("list directory", code)
    }
    if entry.is_empty() {
      return (entries, true)
    }
    if entries.length() == limit {
      return (entries, false)
    }
    entries.push(decode_entry(prefix, entry))
  }
  (entries, false)
}

///|
/// Read the first max_bytes + 1 bytes at most. One extra byte signals overflow
/// without reading the rest of the file. A single-file root uses file_name().
pub fn Root::read(
  self : Root,
  relative_file : String,
  max_bytes : Int32,
) -> Bytes raise {
  if max_bytes < 0 || max_bytes == 2147483647 {
    raise InvalidLimit
  }
  let file = self.resolve(relative_file, false)
  defer (if self.directory { native_close(file) })
  read_prefix(file, max_bytes + 1)
}

///|
/// Read at most max_bytes and report completeness without spending a probe byte.
pub fn Root::read_with_limit(
  self : Root,
  relative_file : String,
  max_bytes : Int32,
) -> (Bytes, Bool) raise {
  if max_bytes < 0 {
    raise InvalidLimit
  }
  let file = self.resolve(relative_file, false)
  defer (if self.directory { native_close(file) })
  let raw = read_prefix(file, max_bytes)
  if raw.length() < max_bytes {
    return (raw, true)
  }
  // If the size cannot be confirmed, count the bytes and treat the read as incomplete.
  (raw, native_size(file) == max_bytes.to_int64())
}

///|
fn read_prefix(file : NativeFile, limit : Int32) -> Bytes raise {
  let chunk = FixedArray::make(@cmp.minimum(limit, 8192), b'\x00')
  let bytes = @buffer.Buffer()
  for offset = 0; offset < limit; {
    let count = native_read(
      file,
      offset,
      chunk,
      @cmp.minimum(chunk.length(), limit - offset),
    )
    if count < 0 {
      raise Filesystem("read file", native_file_error(file))
    }
    if count == 0 {
      break
    }
    bytes.write_bytes(Bytes::from_array(chunk[:count])[:])
    continue offset + count
  }
  bytes.to_bytes()
}
