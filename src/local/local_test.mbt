///|
fn assert_rejected(action : () -> Unit raise) -> Unit raise {
  try action() catch {
    _ => ()
  } noraise {
    _ => fail("expected filesystem boundary to reject the operation")
  }
}

///|
async test "bounded lists and anchored reads" {
  let fixture = @test_fs.tmpdir(prefix="moon-license-scan")
  defer @test_fs.rmdir(fixture, recursive=true)
  @test_fs.mkdir(fixture + "/scan/sub", recursive=true)
  @test_fs.write_binary(fixture + "/scan/sub/café.txt", b"0123456789")
  let scope = @local.Root::open(fixture + "/scan/.")
  defer scope.close()
  assert_true(scope.is_directory())
  let (entries, complete) = scope.list("", 1)
  assert_true(complete)
  assert_eq(entries.length(), 1)
  assert_eq(entries[0].path, "sub")
  assert_eq(entries[0].kind, "directory")
  let (empty, complete) = scope.list("", 0)
  assert_false(complete)
  assert_true(empty.is_empty())
  let (children, complete) = scope.list("sub", 3)
  assert_true(complete)
  assert_eq(children.length(), 1)
  assert_eq(children[0].path, "sub/café.txt")
  assert_eq(children[0].kind, "file")
  assert_eq(scope.read("sub/café.txt", 3), b"0123")
  assert_eq(scope.read("sub/café.txt", 0), b"0")
  assert_eq(scope.read("sub/café.txt", 10), b"0123456789")
  assert_rejected(() => ignore(scope.read("sub", 3)))
  assert_rejected(() => ignore(scope.read("sub/../sub/café.txt", 3)))
  assert_rejected(() => ignore(scope.read("/sub/café.txt", 3)))
  assert_rejected(() => ignore(scope.read("sub//café.txt", 3)))
  assert_rejected(() => ignore(scope.read("sub/café.txt\u0000", 3)))
  assert_rejected(() => ignore(scope.read("sub/café.txt", -1)))

  let single = @local.Root::open(fixture + "/scan/sub/café.txt")
  defer single.close()
  assert_false(single.is_directory())
  assert_eq(single.file_name(), "café.txt")
  @test_fs.rename(
    fixture + "/scan/sub/café.txt",
    fixture + "/scan/sub/original",
  )
  @test_fs.write_binary(fixture + "/scan/sub/café.txt", b"replacement")
  assert_eq(single.read("café.txt", 2), b"012")
  assert_rejected(() => ignore(single.read("original", 2)))

  @test_fs.rename(fixture + "/scan", fixture + "/original-scan")
  @test_fs.mkdir(fixture + "/scan/sub", recursive=true)
  @test_fs.write_binary(fixture + "/scan/sub/café.txt", b"second replacement")
  assert_eq(scope.read("sub/café.txt", 2), b"rep")
  let (renamed, complete) = scope.list("sub", 4)
  assert_true(complete)
  assert_true(renamed.any(entry => entry.path == "sub/original"))
  scope.close()
  scope.close()
  assert_rejected(() => ignore(scope.list("", 1)))
}

///|
async test "reject link and special-file roots and descendants" {
  let fixture = @test_fs.tmpdir(prefix="moon-license-scan")
  defer @test_fs.rmdir(fixture, recursive=true)
  let scan = fixture + "/scan"
  let external = fixture + "/outside"
  let jump = scan + "/jump"
  @test_fs.mkdir(scan)
  @test_fs.mkdir(external)
  @test_fs.write_binary(external + "/secret", b"outside")
  let windows = fixture.contains("\\") || fixture.contains(":")
  if windows {
    assert_eq(
      @test_process.run(
        "powershell.exe",
        [
          "-NoProfile", "-NonInteractive", "-Command", "$ErrorActionPreference='Stop'; $null = New-Item -ItemType Junction -Path $env:MOON_LS_JUMP -Target $env:MOON_LS_OUTSIDE",
        ],
        extra_env={ "MOON_LS_JUMP": jump, "MOON_LS_OUTSIDE": external },
      ).exit_code,
      0,
    )
  } else {
    @test_fs.symlink(jump, target=external)
    @test_fs.symlink(scan + "/file-link", target=external + "/secret")
    assert_eq(@test_process.run("mkfifo", [scan + "/pipe"]).exit_code, 0)
  }
  defer (if windows { @test_fs.rmdir(jump) } else { @test_fs.remove(jump) })
  let root = @local.Root::open(scan)
  defer root.close()
  let (entries, complete) = root.list("", 5)
  assert_true(complete)
  assert_true(
    entries.any(entry => entry.path == "jump" && entry.kind == "link"),
  )
  assert_rejected(() => ignore(root.list("jump", 1)))
  assert_rejected(() => ignore(root.read("jump/secret", 3)))
  for suffix in ["", "/", "/.", "//.//"] {
    assert_rejected(() => @local.Root::open(jump + suffix).close())
  }
  if windows {
    assert_rejected(() => ignore(root.read("jump\\secret", 3)))
    assert_rejected(() => ignore(root.read("jump:secret", 3)))
  } else {
    assert_true(
      entries.any(entry => entry.path == "file-link" && entry.kind == "link"),
    )
    assert_true(
      entries.any(entry => entry.path == "pipe" && entry.kind == "other"),
    )
    assert_rejected(() => @local.Root::open(scan + "/file-link").close())
    assert_rejected(() => @local.Root::open(scan + "/pipe").close())
    assert_rejected(() => ignore(root.read("file-link", 3)))
    assert_rejected(() => ignore(root.read("pipe", 3)))
  }
}
