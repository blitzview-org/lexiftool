/*------------------------------------------------------------------------------
 * File:         standalone/blob.c
 *
 * Description:  Puts blob.bin (all embedded modules and data files, written
 *               by genembed.lua) into the executable's read-only data as the
 *               symbol lx_blob, via the assembler's .incbin -- some 5 MB
 *               compressed (15 MB with SA_COMPRESS=0), which as a C array
 *               initializer would take the compilers minutes and gigabytes. Must be compiled with the directory
 *               holding blob.bin as the current directory (build.sh does).
 *               Object formats: ELF (Linux), Mach-O (macOS: leading
 *               underscore on C symbols), PE/COFF (Windows x64: none).
 *------------------------------------------------------------------------------
 */

#include "embedded.h"

#if defined(__APPLE__)
#  define LX_SECTION ".section __TEXT,__const"
#  define LX_SYM     "_lx_blob"
#elif defined(_WIN32)
#  define LX_SECTION ".section .rdata,\"dr\""
#  define LX_SYM     "lx_blob"
#else
#  define LX_SECTION ".section .rodata.lx_blob,\"a\""
#  define LX_SYM     "lx_blob"
#endif

__asm__(
    LX_SECTION "\n"
    ".globl " LX_SYM "\n"
    ".p2align 4\n"
    LX_SYM ":\n"
    ".incbin \"blob.bin\"\n"
    ".byte 0\n"
    ".text\n"
);
