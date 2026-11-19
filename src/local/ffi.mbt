///|
type NativeFile

///|
priv type NativeDirectory

///|
extern "c" fn native_windows() -> Bool = "moon_ls_windows"

///|
#borrow(path)
extern "c" fn native_root(path : Bytes) -> NativeFile = "moon_ls_root"

///|
#borrow(parent, component)
extern "c" fn native_child(
  parent : NativeFile,
  component : Bytes,
  directory : Bool,
) -> NativeFile = "moon_ls_child"

///|
#borrow(file)
extern "c" fn native_kind(file : NativeFile) -> Int32 = "moon_ls_kind"

///|
#borrow(file)
extern "c" fn native_file_error(file : NativeFile) -> Int32 = "moon_ls_file_error"

///|
#borrow(file)
extern "c" fn native_close(file : NativeFile) -> Unit = "moon_ls_close"

///|
#borrow(file)
extern "c" fn native_size(file : NativeFile) -> Int64 = "moon_ls_size"

///|
#borrow(file, buffer)
extern "c" fn native_read(
  file : NativeFile,
  offset : Int32,
  buffer : FixedArray[Byte],
  limit : Int32,
) -> Int32 = "moon_ls_read"

///|
#borrow(file)
extern "c" fn native_directory(file : NativeFile) -> NativeDirectory = "moon_ls_directory"

///|
#borrow(directory)
extern "c" fn native_directory_error(directory : NativeDirectory) -> Int32 = "moon_ls_directory_error"

///|
#borrow(directory)
extern "c" fn native_next(directory : NativeDirectory) -> Bytes = "moon_ls_next"

///|
#borrow(directory)
extern "c" fn native_directory_close(directory : NativeDirectory) -> Unit = "moon_ls_directory_close"
