#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <sys/stat.h>
#include <unistd.h>

typedef int native_handle;
#define INVALID_HANDLE (-1)
typedef struct { DIR *stream; } native_cursor;

static enum kind stat_kind(mode_t mode) {
  if (S_ISREG(mode)) return REGULAR;
  if (S_ISDIR(mode)) return DIRECTORY;
  if (S_ISLNK(mode)) return LINK;
  return OTHER;
}

static void native_close(native_handle file) { close(file); }

static native_handle open_item(native_handle parent, const char *name, enum kind required,
                               enum kind *kind, int32_t *error) {
  struct stat before, after;
  int fd;
  const int flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK | O_NOCTTY;

  if (required == DIRECTORY) {
    fd = openat(parent, name, flags | O_DIRECTORY);
    if (fd == -1) *error = errno;
    else *kind = DIRECTORY;
    return fd;
  }

#ifdef __linux__
  // O_PATH inspects the exact inode without opening a FIFO or a device.
  int metadata = openat(parent, name, O_PATH | O_CLOEXEC | O_NOFOLLOW);
  if (metadata == -1) {
    *error = errno;
    return -1;
  }
  if (fstat(metadata, &before) == -1) {
    *error = errno;
    close(metadata);
    return -1;
  }
#else
  if (fstatat(parent, name, &before, AT_SYMLINK_NOFOLLOW) == -1) {
    *error = errno;
    return -1;
  }
#endif
  *kind = stat_kind(before.st_mode);
  if ((*kind != REGULAR && *kind != DIRECTORY) || (required != INVALID && required != *kind)) {
    *error = *kind == LINK ? ELOOP : EINVAL;
    fd = -1;
  } else {
#ifdef __linux__
    // This magic link belongs to our process and names the already classified inode.
    char descriptor[64];
    snprintf(descriptor, sizeof(descriptor), "/proc/self/fd/%d", metadata);
    fd = open(descriptor, (flags & ~O_NOFOLLOW) | (*kind == DIRECTORY ? O_DIRECTORY : 0));
#else
    // macOS lacks O_PATH. Check the inode again after a nonblocking no-follow open.
    fd = openat(parent, name, flags | (*kind == DIRECTORY ? O_DIRECTORY : 0));
#endif
    if (fd == -1) {
      *error = errno;
    } else if (fstat(fd, &after) == -1) {
      *error = errno;
      close(fd);
      fd = -1;
    } else if (stat_kind(after.st_mode) != *kind || before.st_dev != after.st_dev ||
               before.st_ino != after.st_ino) {
      *error = EAGAIN;
      close(fd);
      fd = -1;
    }
  }
#ifdef __linux__
  close(metadata);
#endif
  return fd;
}

static native_handle native_open_root(const char *name, enum kind *kind, int32_t *error) {
  return open_item(AT_FDCWD, name, INVALID, kind, error);
}

static native_handle native_open_child(native_handle parent, const char *name,
                                       enum kind kind, int32_t *error) {
  enum kind actual;
  return open_item(parent, name, kind, &actual, error);
}

static int64_t native_size(native_handle file, int32_t *error) {
  struct stat info;
  if (fstat(file, &info) == -1) {
    *error = errno;
    return -1;
  }
  return (int64_t)info.st_size;
}

static int32_t native_read(native_handle file, int32_t offset, uint8_t *buffer,
                           int32_t limit, int32_t *error) {
  ssize_t count;
  do {
    count = pread(file, buffer, (size_t)limit, (off_t)offset);
  } while (count < 0 && errno == EINTR);
  if (count < 0) *error = errno;
  return (int32_t)count;
}

static void native_cursor_open(native_handle parent, native_cursor *cursor, int32_t *error) {
  // Open a separate file description so calls never share enumeration offsets.
  cursor->stream = NULL;
  int fd = openat(parent, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  if (fd == -1) {
    *error = errno;
    return;
  }
  cursor->stream = fdopendir(fd);
  if (cursor->stream == NULL) {
    *error = errno;
    close(fd);
  }
}

static void native_cursor_close(native_cursor *cursor) {
  if (cursor->stream != NULL) {
    closedir(cursor->stream);
    cursor->stream = NULL;
  }
}

static moonbit_bytes_t native_cursor_next(native_cursor *cursor, int32_t *error) {
  struct dirent *entry;
  do {
    errno = 0;
    entry = readdir(cursor->stream);
    if (entry == NULL) {
      *error = errno;
      return NULL;
    }
  } while (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0);

  struct stat info;
  enum kind kind = fstatat(dirfd(cursor->stream), entry->d_name, &info,
                           AT_SYMLINK_NOFOLLOW) == 0 ? stat_kind(info.st_mode) : UNREADABLE;
  return entry_bytes(kind, entry->d_name, (int32_t)strlen(entry->d_name));
}
