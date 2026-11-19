#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0600
#endif
#include <windows.h>
#include <winternl.h>
#include <stddef.h>
#include <wchar.h>

typedef HANDLE native_handle;
#define INVALID_HANDLE INVALID_HANDLE_VALUE
#define WIN_PATH_UNITS 32768

typedef NTSTATUS (NTAPI *create_file_fn)(PHANDLE, ACCESS_MASK, POBJECT_ATTRIBUTES,
  PIO_STATUS_BLOCK, PLARGE_INTEGER, ULONG, ULONG, ULONG, ULONG, PVOID, ULONG);

enum {
  NT_FILE_OPEN = 1,
  NT_DIRECTORY = 0x00000001,
  NT_SYNCHRONOUS = 0x00000020,
  NT_NOT_DIRECTORY = 0x00000040,
  NT_OPEN_REPARSE_POINT = 0x00200000,
  NT_DONT_REPARSE = 0x00001000,
};

static const DWORD share = FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE;
static void native_close(native_handle file) { CloseHandle(file); }

static enum kind attributes_kind(DWORD attributes) {
  if ((attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) return LINK;
  if ((attributes & FILE_ATTRIBUTE_DEVICE) != 0) return OTHER;
  return (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0 ? DIRECTORY : REGULAR;
}

static native_handle inspect_handle(native_handle file, enum kind required,
                                    enum kind *kind, int32_t *error) {
  if (file == INVALID_HANDLE) {
    *error = (int32_t)GetLastError();
    return INVALID_HANDLE;
  }
  BY_HANDLE_FILE_INFORMATION info;
  if (GetFileType(file) != FILE_TYPE_DISK) {
    *error = ERROR_INVALID_FUNCTION;
  } else if (!GetFileInformationByHandle(file, &info)) {
    *error = (int32_t)GetLastError();
  } else {
    *kind = attributes_kind(info.dwFileAttributes);
    if ((*kind == REGULAR || *kind == DIRECTORY) && (required == INVALID || required == *kind)) {
      return file;
    }
    *error = *kind == LINK ? ERROR_CANT_ACCESS_FILE : ERROR_INVALID_FUNCTION;
  }
  CloseHandle(file);
  return INVALID_HANDLE;
}

static int namespace_path(const WCHAR *path) {
  return path[0] == L'\\' && path[1] == L'\\' &&
         (path[2] == L'?' || path[2] == L'.') && path[3] == L'\\';
}

static native_handle native_open_root(const char *path, enum kind *kind, int32_t *error) {
  WCHAR input[WIN_PATH_UNITS], full[WIN_PATH_UNITS];
  if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, input, WIN_PATH_UNITS)) {
    *error = (int32_t)GetLastError();
    return INVALID_HANDLE;
  }
  for (WCHAR *ch = input; *ch; ++ch) {
    if (*ch == L'/') *ch = L'\\';
  }
  if (namespace_path(input)) {
    *error = ERROR_INVALID_NAME;
    return INVALID_HANDLE;
  }
  DWORD len = GetFullPathNameW(input, WIN_PATH_UNITS, full, NULL);
  if (len == 0 || len >= WIN_PATH_UNITS - 8) {
    *error = len == 0 ? (int32_t)GetLastError() : ERROR_FILENAME_EXCED_RANGE;
    return INVALID_HANDLE;
  }

  size_t prefix_len, skip;
  if (full[0] == L'\\' && full[1] == L'\\' && !namespace_path(full)) {
    const WCHAR *server_end = wcschr(full + 2, L'\\');
    const WCHAR *share_end = server_end ? wcschr(server_end + 1, L'\\') : NULL;
    int share_len = server_end ? (int)((share_end ? share_end : full + len) - (server_end + 1)) : 0;
    if (share_len == 0 || wcschr(full + 2, L':') != NULL ||
        (share_len == 4 && CompareStringOrdinal(server_end + 1, 4, L"pipe", 4, TRUE) == CSTR_EQUAL) ||
        (share_len == 8 && CompareStringOrdinal(server_end + 1, 8, L"mailslot", 8, TRUE) == CSTR_EQUAL)) {
      *error = ERROR_INVALID_NAME;
      return INVALID_HANDLE;
    }
    memcpy(input, L"\\\\?\\UNC\\", 8 * sizeof(WCHAR));
    prefix_len = 8;
    skip = 2;
  } else if (len >= 3 && full[1] == L':' && full[2] == L'\\' && wcschr(full + 2, L':') == NULL) {
    memcpy(input, L"\\\\?\\", 4 * sizeof(WCHAR));
    prefix_len = 4;
    skip = 0;
  } else {
    *error = ERROR_INVALID_NAME;
    return INVALID_HANDLE;
  }
  // A trailing separator must not hide that the final path component is a reparse point.
  while (len > 3 && full[len - 1] == L'\\') --len;
  memcpy(input + prefix_len, full + skip, (len - skip) * sizeof(WCHAR));
  input[prefix_len + len - skip] = L'\0';
  native_handle file = CreateFileW(input, GENERIC_READ, share, NULL, OPEN_EXISTING,
                                 FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, NULL);
  return inspect_handle(file, INVALID, kind, error);
}

static native_handle native_open_child(native_handle parent, const char *name,
                                       enum kind kind, int32_t *error) {
  WCHAR component[WIN_PATH_UNITS];
  int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, name, -1, component, WIN_PATH_UNITS);
  if (length == 0) {
    *error = (int32_t)GetLastError();
    return INVALID_HANDLE;
  }
  create_file_fn create_file = (create_file_fn)(void (*)(void))
    GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "NtCreateFile");
  if (create_file == NULL) {
    *error = ERROR_PROC_NOT_FOUND;
    return INVALID_HANDLE;
  }
  // Name contains exactly one component. RootDirectory anchors it to the
  // parent handle even if any directory in its original pathname is moved.
  UNICODE_STRING relative = { (USHORT)((length - 1) * sizeof(WCHAR)),
                              (USHORT)((length - 1) * sizeof(WCHAR)), component };
  OBJECT_ATTRIBUTES object = { 0 };
  object.Length = sizeof(object);
  object.RootDirectory = parent;
  object.ObjectName = &relative;
  object.Attributes = NT_DONT_REPARSE;
  IO_STATUS_BLOCK status;
  native_handle file = INVALID_HANDLE;
  ACCESS_MASK access = FILE_READ_DATA | FILE_READ_ATTRIBUTES | SYNCHRONIZE;
  ULONG options = NT_SYNCHRONOUS | NT_OPEN_REPARSE_POINT |
                  (kind == DIRECTORY ? NT_DIRECTORY : NT_NOT_DIRECTORY);
  NTSTATUS result = create_file(&file, access, &object, &status, NULL, 0, share,
                               NT_FILE_OPEN, options, NULL, 0);
  if (result < 0) {
    *error = (int32_t)result;
    return INVALID_HANDLE;
  }
  enum kind actual;
  return inspect_handle(file, kind, &actual, error);
}

static int32_t native_read(native_handle file, int32_t offset, uint8_t *buffer,
                           int32_t limit, int32_t *error) {
  OVERLAPPED position = { 0 };
  position.Offset = (DWORD)offset;
  DWORD count;
  if (!ReadFile(file, buffer, (DWORD)limit, &count, &position)) {
    DWORD code = GetLastError();
    if (code == ERROR_HANDLE_EOF) return 0;
    *error = (int32_t)code;
    return -1;
  }
  return (int32_t)count;
}

typedef struct {
  native_handle handle;
  DWORD offset;
  BOOL restart;
  union {
    FILE_ID_BOTH_DIR_INFO aligned;
    uint8_t bytes[16384];
  } buffer;
} native_cursor;

static void native_cursor_open(native_handle parent, native_cursor *cursor, int32_t *error) {
  cursor->offset = sizeof(cursor->buffer.bytes);
  cursor->restart = TRUE;
  cursor->handle = ReOpenFile(parent, FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES, share,
                              FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT);
  enum kind kind;
  cursor->handle = inspect_handle(cursor->handle, DIRECTORY, &kind, error);
}

static void native_cursor_close(native_cursor *cursor) {
  if (cursor->handle != INVALID_HANDLE) {
    CloseHandle(cursor->handle);
    cursor->handle = INVALID_HANDLE;
  }
}

static moonbit_bytes_t native_cursor_next(native_cursor *cursor, int32_t *error) {
  const DWORD capacity = sizeof(cursor->buffer.bytes);
  const DWORD header = offsetof(FILE_ID_BOTH_DIR_INFO, FileName);
  for (;;) {
    if (cursor->offset == capacity) {
      FILE_INFO_BY_HANDLE_CLASS info = cursor->restart ? FileIdBothDirectoryRestartInfo : FileIdBothDirectoryInfo;
      if (!GetFileInformationByHandleEx(cursor->handle, info, cursor->buffer.bytes, capacity)) {
        DWORD code = GetLastError();
        if (code != ERROR_NO_MORE_FILES && code != ERROR_FILE_NOT_FOUND) *error = (int32_t)code;
        return NULL;
      }
      cursor->restart = FALSE;
      cursor->offset = 0;
    }
    const FILE_ID_BOTH_DIR_INFO *entry = (const void *)(cursor->buffer.bytes + cursor->offset);
    DWORD next = entry->NextEntryOffset;
    DWORD available = capacity - cursor->offset;
    if (next != 0 && (next % 8 != 0 || next < header || next > available - header)) {
      *error = ERROR_INVALID_DATA;
      return NULL;
    }
    DWORD size = next ? next : available;
    if (entry->FileNameLength == 0 || entry->FileNameLength % sizeof(WCHAR) != 0 ||
        entry->FileNameLength > size - header) {
      *error = ERROR_INVALID_DATA;
      return NULL;
    }
    cursor->offset = next ? cursor->offset + next : capacity;
    int count = (int)(entry->FileNameLength / sizeof(WCHAR));
    const WCHAR *name = entry->FileName;
    if (name[0] == L'.' && (count == 1 || (count == 2 && name[1] == L'.'))) continue;
    char utf8[16384 * 2];
    int length = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, name, count, utf8, sizeof(utf8), NULL, NULL);
    if (length == 0) {
      *error = (int32_t)GetLastError();
      return NULL;
    }
    return entry_bytes(attributes_kind(entry->FileAttributes), utf8, length);
  }
}
