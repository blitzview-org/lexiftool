/*------------------------------------------------------------------------------
 * File:         standalone/embedded.h
 *
 * Description:  Index of the data embedded in the standalone executable.
 *               blob.c places the bytes of OUTDIR/blob.bin (written by
 *               genembed.lua) in the executable's read-only data as
 *               lx_blob; the generated embedded_index.c describes the
 *               entries in it. The table ends with an entry whose name is
 *               NULL. An entry with ulen > 0 is compressed (len bytes in
 *               the blob, ulen bytes once decoded; the codec, zstd, is
 *               LX_CODEC of the generated embedded_codec.h); ulen 0 means
 *               stored as is.
 *------------------------------------------------------------------------------
 */

#ifndef LX_EMBEDDED_H
#define LX_EMBEDDED_H

#include <stddef.h>

enum lx_kind {
    LX_MAIN = 1,    /* the launcher chunk (bytecode) */
    LX_MODULE,      /* a Lua module (bytecode), name = module name */
    LX_FILE         /* a data file, name = path below the virtual root */
};

struct lx_entry {
    int         kind;
    const char* name;
    size_t      offset;     /* into lx_blob */
    size_t      len;        /* bytes in lx_blob */
    size_t      ulen;       /* uncompressed length, 0 = not compressed */
};

extern const struct lx_entry lx_entries[];
extern const size_t lx_blob_size;
extern const unsigned char lx_blob[];

#endif
