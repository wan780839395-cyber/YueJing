#include "KokoroBZip.h"
#include <bzlib.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

struct KokoroBZip {
    FILE *file;
    BZFILE *stream;
    int ended;
};

void kokoro_bzip_close(KokoroBZip *reader) {
    if (!reader) return;
    if (reader->stream) {
        int status;
        BZ2_bzReadClose(&status, reader->stream);
    }
    if (reader->file) fclose(reader->file);
    free(reader);
}

KokoroBZip *kokoro_bzip_open(int fd) {
    KokoroBZip *reader = calloc(1, sizeof(*reader));
    if (!reader) return NULL;
    int copy = dup(fd);
    if (copy < 0 || !(reader->file = fdopen(copy, "rb"))) {
        if (copy >= 0) close(copy);
        free(reader);
        return NULL;
    }
    int status;
    reader->stream = BZ2_bzReadOpen(&status, reader->file, 0, 0, NULL, 0);
    if (status == BZ_OK && reader->stream) return reader;
    kokoro_bzip_close(reader);
    return NULL;
}

int kokoro_bzip_read(KokoroBZip *reader, void *buffer, int length) {
    if (!reader || !buffer || length <= 0 || length > 256 * 1024) return -1;
    if (reader->ended) return 0;
    int status;
    int n = BZ2_bzRead(&status, reader->stream, buffer, length);
    if (status == BZ_OK) return n == length ? n : -1;
    if (status != BZ_STREAM_END || n < 0 || n > length) return -1;
    // Reject a concatenated stream or trailing bytes, including libbz2 read-ahead.
    void *unused;
    int count;
    BZ2_bzReadGetUnused(&status, reader->stream, &unused, &count);
    if (status != BZ_OK || count != 0 || fgetc(reader->file) != EOF || ferror(reader->file)) return -1;
    reader->ended = 1;
    return n;
}
