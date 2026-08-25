// CArchiveShim — the C declarations Dirnex needs from the system libarchive.
//
// macOS ships libarchive as `/usr/lib/libarchive.2.dylib` (libarchive 3.7.4 on macOS 26) and the
// SDK carries `usr/lib/libarchive.2.tbd`, so linking it adds **no dependency** — it is a system
// library exactly like `libSystem`. What the SDK does *not* ship is `archive.h`, so the prototypes
// are declared here by hand.
//
// Why link the library at all, when PLAN.md §2 chose `bsdtar` over libarchive and every other
// archive path in Dirnex shells out: **the passphrase**. `bsdtar` takes it only as `--passphrase`
// in argv, readable by any `ps` on the machine — the exact practice docs/NOTES.md forbids for
// `curl` — and its only alternative is an interactive prompt that, on a non-tty stdin, loops
// `Enter passphrase:` forever instead of failing (measured: 166 KB of prompts before the probe was
// killed). `archive_write_set_passphrase` takes a buffer we own and can wipe. That is the whole
// reason for this target, and it is why the exception is confined to the encrypted path: browsing
// and ordinary packing keep using `bsdtar`.
//
// Only the symbols Dirnex actually calls are declared. Each was checked against the SDK stub before
// being written down; a name that drifts fails at link time rather than silently at run time.
//
// The constants (`ARCHIVE_OK`, `AE_IFREG`, …) are deliberately *not* declared here. They are plain
// integers with no ABI, so they live on the Swift side in `LibArchive.swift` where they can carry
// doc comments and participate in `switch`, rather than arriving as imported C macros whose
// negative values import inconsistently.

#pragma once

#include <stdint.h>
#include <sys/types.h>

// libarchive's two public opaque types. Declared incomplete: nothing here dereferences them.
struct archive;
struct archive_entry;

// MARK: - Library identity

const char *archive_version_string(void);

// MARK: - Error reporting
//
// Both are valid on a read *and* a write handle, and `archive_error_string` may return NULL when
// nothing has failed — the Swift side treats that as "no detail", never as an empty message.

const char *archive_error_string(struct archive *);
int archive_errno(struct archive *);

// MARK: - Writing

struct archive *archive_write_new(void);
int archive_write_set_format_zip(struct archive *);

// The inner container for "hide file names". A tar rather than a second zip: tar stores bytes
// verbatim, so the outer zip's deflate is the only compression pass, and tar carries permissions and
// symlinks losslessly. `pax_restricted` is libarchive's own recommended default — plain ustar for
// anything that fits it, pax extensions only where a name or a size does not.
int archive_write_set_format_pax_restricted(struct archive *);
int archive_write_set_options(struct archive *, const char *options);
int archive_write_set_passphrase(struct archive *, const char *passphrase);
int archive_write_open_filename(struct archive *, const char *filename);
int archive_write_header(struct archive *, struct archive_entry *);
ssize_t archive_write_data(struct archive *, const void *buffer, size_t length);
int archive_write_finish_entry(struct archive *);
int archive_write_close(struct archive *);
int archive_write_free(struct archive *);

// MARK: - Reading

struct archive *archive_read_new(void);
int archive_read_support_format_all(struct archive *);
int archive_read_support_filter_all(struct archive *);
int archive_read_add_passphrase(struct archive *, const char *passphrase);
int archive_read_open_filename(struct archive *, const char *filename, size_t blockSize);
int archive_read_next_header(struct archive *, struct archive_entry **);
ssize_t archive_read_data(struct archive *, void *buffer, size_t length);

// Step over the current entry's data without reading it. On a seekable zip that is a *seek*, not a
// decrypt-and-discard, which is what makes extracting one member of a large encrypted archive cheap:
// measured on a 600 MB AES-256 archive, reading every entry's data takes 1.48 s while reaching a
// 6-byte member past six 100 MB ones takes **0.001 s**.
//
// The saving belongs to *not reading the data*, not to this call — `archive_read_next_header`
// already skips whatever is left of the previous entry, and measured against it this is identical
// (0.001 s either way, 3 rounds). It is called anyway so the decision is legible where it is made:
// a loop that reaches `continue` is choosing to leave an entry alone, which is not something the
// absence of a read can say.
//
// It says nothing about the passphrase, and that is the point rather than a shortcoming — a skipped
// entry is never decrypted, so a *wrong* passphrase makes this return `ARCHIVE_OK` in silence
// (probed). Only an entry whose data is actually read can answer that question.
int archive_read_data_skip(struct archive *);

int archive_read_free(struct archive *);

// Whether the archive holds encrypted entries. Answers before any passphrase is supplied, which is
// what lets Dirnex ask for one only when it is actually needed. The return is tri-state: > 0 yes,
// 0 no, and a negative value means the format cannot say without reading further.
int archive_read_has_encrypted_entries(struct archive *);

// MARK: - Entries

struct archive_entry *archive_entry_new(void);
void archive_entry_free(struct archive_entry *);

// Reading side. `_utf8` is used for the pathname because a zip's names are bytes with no declared
// encoding and the non-suffixed getter applies the process locale's charset conversion; the UTF-8
// spelling gives us the bytes to decode ourselves. It returns NULL when the name is not valid
// UTF-8, which the Swift side treats as an entry it will not extract rather than guessing.
const char *archive_entry_pathname_utf8(struct archive_entry *);

// A symlink's target, or NULL when the entry is not a symlink. Stored rather than followed: a
// symlink pointing at its own ancestor is a walk that never ends, and a symlink pointing outside
// the packed tree would silently pull in bytes the user did not select.
const char *archive_entry_symlink_utf8(struct archive_entry *);

int64_t archive_entry_size(struct archive_entry *);
mode_t archive_entry_filetype(struct archive_entry *);
mode_t archive_entry_perm(struct archive_entry *);
time_t archive_entry_mtime(struct archive_entry *);
int archive_entry_is_encrypted(struct archive_entry *);

// Writing side.
void archive_entry_set_pathname_utf8(struct archive_entry *, const char *);
void archive_entry_set_symlink_utf8(struct archive_entry *, const char *);
void archive_entry_set_size(struct archive_entry *, int64_t);
void archive_entry_set_filetype(struct archive_entry *, mode_t);
void archive_entry_set_perm(struct archive_entry *, mode_t);
void archive_entry_set_mtime(struct archive_entry *, time_t seconds, long nanoseconds);
