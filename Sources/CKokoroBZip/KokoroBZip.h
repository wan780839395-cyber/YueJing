#pragma once

typedef struct KokoroBZip KokoroBZip;
// Takes a duplicate of fd at its current position; caller retains fd.
KokoroBZip *kokoro_bzip_open(int fd);
// Short read only at the end of a single, CRC-checked stream; negative on error.
int kokoro_bzip_read(KokoroBZip *reader, void *buffer, int length);
void kokoro_bzip_close(KokoroBZip *reader);
