#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <moonbit.h>
#include <stdint.h>
#include <string.h>

enum kind { INVALID, REGULAR, DIRECTORY, LINK, OTHER, UNREADABLE };

static moonbit_bytes_t entry_bytes(enum kind kind, const char *name, int32_t len) {
  moonbit_bytes_t result = moonbit_make_bytes_raw(len + 1);
  result[0] = (uint8_t)kind;
  memcpy(result + 1, name, (size_t)len);
  return result;
}

#ifdef _WIN32
#include "windows_local.h"
#else
#include "posix_local.h"
#endif

typedef struct {
  native_handle handle;
  enum kind kind;
  int32_t error;
} local_file;

typedef struct {
  native_cursor cursor;
  int32_t error;
} local_directory;

MOONBIT_FFI_EXPORT void moon_ls_close(void *ptr) {
  local_file *file = ptr;
  if (file->handle != INVALID_HANDLE) {
    native_close(file->handle);
    file->handle = INVALID_HANDLE;
  }
}

static local_file *new_file(void) {
  local_file *file = moonbit_make_external_object(moon_ls_close, sizeof(*file));
  file->handle = INVALID_HANDLE;
  file->kind = INVALID;
  file->error = 0;
  return file;
}

MOONBIT_FFI_EXPORT int32_t moon_ls_windows(void) {
#ifdef _WIN32
  return 1;
#else
  return 0;
#endif
}

MOONBIT_FFI_EXPORT void *moon_ls_root(moonbit_bytes_t path) {
  local_file *file = new_file();
  file->handle = native_open_root((const char *)path, &file->kind, &file->error);
  return file;
}

MOONBIT_FFI_EXPORT void *moon_ls_child(void *ptr, moonbit_bytes_t name, int32_t directory) {
  const local_file *parent = ptr;
  local_file *file = new_file();
  file->kind = directory ? DIRECTORY : REGULAR;
  file->handle = native_open_child(parent->handle, (const char *)name, file->kind, &file->error);
  return file;
}

MOONBIT_FFI_EXPORT int32_t moon_ls_kind(const void *ptr) {
  return ((const local_file *)ptr)->kind;
}

MOONBIT_FFI_EXPORT int32_t moon_ls_file_error(const void *ptr) {
  return ((const local_file *)ptr)->error;
}

MOONBIT_FFI_EXPORT int32_t moon_ls_read(void *ptr, int32_t offset, uint8_t *buffer, int32_t limit) {
  local_file *file = ptr;
  return native_read(file->handle, offset, buffer, limit, &file->error);
}

MOONBIT_FFI_EXPORT void moon_ls_directory_close(void *ptr) {
  native_cursor_close(&((local_directory *)ptr)->cursor);
}

MOONBIT_FFI_EXPORT void *moon_ls_directory(const void *ptr) {
  const local_file *file = ptr;
  local_directory *directory = moonbit_make_external_object(moon_ls_directory_close, sizeof(*directory));
  directory->error = 0;
  native_cursor_open(file->handle, &directory->cursor, &directory->error);
  return directory;
}

MOONBIT_FFI_EXPORT int32_t moon_ls_directory_error(const void *ptr) {
  return ((const local_directory *)ptr)->error;
}

MOONBIT_FFI_EXPORT moonbit_bytes_t moon_ls_next(void *ptr) {
  local_directory *directory = ptr;
  if (directory->error == 0) {
    moonbit_bytes_t item = native_cursor_next(&directory->cursor, &directory->error);
    if (item != NULL) return item;
  }
  return moonbit_make_bytes(0, 0);
}
