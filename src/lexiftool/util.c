/*------------------------------------------------------------------------------
 * File:         lexiftool/util.c
 *
 * Description:  Native C helper functions for data processing that are too
 *               slow in Lua (module `lexiftool.util`): base64, a protobuf
 *               reader and the HDRP key stream of Google maker notes, with
 *               the ciphers Nikon.Decrypt and Sony.Decipher as likely
 *               future additions. Kept apart from lexiftool.sys, which
 *               covers OS primitives ($^O, setenv, chmod, ...), not data
 *               processing. Each function here takes its data as a Lua
 *               string or as a carray (the mutable buffer the port uses
 *               for Perl's scalar references, read through lua-carray's C
 *               API, carray_capi.h).
 *
 *                 base64decode(data)  Image::ExifTool::XMP::DecodeBase64 in
 *                                     one pass: the data up to the first
 *                                     byte that is neither a base64
 *                                     character, '=' nor white space, with
 *                                     '=' and white space ignored, decoded
 *                                     in groups of four characters to three
 *                                     bytes, a trailing partial group to as
 *                                     many bytes as its bits fill (two
 *                                     characters: one byte, three: two; a
 *                                     single one: upstream's zero bytes, see
 *                                     the function)
 *                 pbRecord(data, pos) Image::ExifTool::Protobuf::ReadRecord
 *                                     at the 0-based position pos: buff,
 *                                     id, type, newpos, bit0 -- or false
 *                                     for a record the Lua version has to
 *                                     read (see below)
 *                 pbIsProtobuf(data)  Image::ExifTool::Protobuf::IsProtobuf:
 *                                     true, false, or nil for data the Lua
 *                                     version has to check
 *                 pbWalk(data, dirStart, dirEnd, dataPos, dirInfo, tagTbl,
 *                        et, dirName, cb)
 *                                     the record loop of
 *                                     Image::ExifTool::Protobuf::
 *                                     ProcessProtobuf at its top level,
 *                                     sub-messages included: pos, bit0
 *                                     (see util_pbWalk)
 *                 hdrpDecrypt(data)   the key stream of
 *                                     Image::ExifTool::Google::ProcessHDRP
 *                                     (xorshift64*, fixed seed) applied to
 *                                     the data after the "HDRP\x02" or
 *                                     "\x03" header: a string of the same
 *                                     length
 *                 truthy(v)           perl.truthy, Perl truthiness of a
 *                                     port value: nil, false, the number 0
 *                                     (integer or float, also -0.0), '' and
 *                                     '0' are false, a carray is tested by
 *                                     its bytes (empty or "0": false),
 *                                     everything else is true
 *                 gmtime64(time)      Perl_gmtime64_r (Perl's time64.c) of
 *                                     a time in seconds (a number within
 *                                     pp_gmtime's bounds): sec, min, hour,
 *                                     mday, mon (0-based), year (since
 *                                     1900), wday, yday as integers
 *                 rockVersion         the rock version ("scm-0", "X.Y.Z-N")
 *                                     as a string, present only in a
 *                                     LuaRocks build (see below)
 *
 * Port notes:   Optional in principle -- every function stands in for one
 *               Lua function of the port -- but required by the build like
 *               lexiftool.sys: perl.lua and the modules call it directly.
 *               Needs only the C runtime; the carray C API is a header
 *               (carray_capi.h, from lua-carray, MIT), the carray module
 *               itself is looked up through the metatable of the argument,
 *               so a build without carray support is not possible but a
 *               string argument never touches it.
 *
 *               base64decode is upstream's DecodeBase64 (XMP.pm) without
 *               its detour through uuencode: upstream rewrites the text to
 *               the uuencode alphabet (tr, which also drops '=' and white
 *               space), cuts it into chunks of 60 characters and unpacks
 *               each with a length byte of chunk * 3 / 4 -- integer
 *               division, so a partial chunk of r characters beyond the
 *               groups of four yields r * 3 / 4 bytes, missing characters
 *               reading as zero bits. This decoder produces the same bytes
 *               directly; a large base64 payload (the HDR data of a Google
 *               JPEG, tens of kilobytes) took a fifth of the file's time in
 *               the Lua version.
 *
 *               pbRecord and pbIsProtobuf are ReadRecord/IsProtobuf of
 *               Protobuf.pm (via the port's Protobuf.lua, which keeps its
 *               own reader as the fallback) for the values a lua_Integer
 *               holds exactly: a VarInt of up to 9 bytes is below 2^63. A
 *               record with a VarInt of 10 or more bytes (upstream's
 *               `$mult *= 128` past 2^63: UVs, doubles, the 33-byte limit)
 *               is not read here at all -- pbRecord returns false,
 *               pbIsProtobuf nil, and Protobuf.lua reads the record (or the
 *               whole buffer) the old way, so those semantics stay in one
 *               place. The data ends at its length, as in upstream (not at
 *               the directory end); lengths are compared as len > n - pos,
 *               the form that cannot overflow. On an error the position and
 *               bit 0 are what upstream leaves in $$dirInfo{Pos} and
 *               {Bit0}: past the bytes of a truncated VarInt, before the
 *               payload of a truncated fixed-size or LEN payload, after the
 *               header for the wire types 6 and 7. Profiled on the Google
 *               HDRP data of a JPEG (~23 000 records, half of them from
 *               IsProtobuf), the Lua reader was more than half of the
 *               file's time.
 *
 *               pbWalk walks ProcessProtobuf's records for Protobuf.lua when
 *               neither Unknown nor Verbose (nor HtmlDump) is set: a record
 *               the loop body (ProcessRecord there) would only read and
 *               skip -- no tag info and not LEN, an Unknown tag that is not
 *               LEN, or an Unknown LEN without (or with a false) IsProtobuf
 *               flag that it would not set -- is skipped here, an Unknown
 *               sub-message it would process (flag set, IsProtobuf true, no
 *               Format, no SubDirectory) is entered here, and every other
 *               record is handed to the Lua callback, which runs the loop
 *               body for it; a sub-message the callback finds (after
 *               AddTagToTable and setting the flag) comes back as a result
 *               and is entered here too, so the walker is never re-entered
 *               from its callback for a sub-message. Iterative: a fixed
 *               array of PBW_MAXDEPTH levels on the C stack, three Lua
 *               stack slots per level (prefix, and the level's data string
 *               and %subdir, made only when a record of the level goes to
 *               Lua). Upstream has no depth limit of its own, and neither
 *               has the Lua loop beyond the Lua stack (LUAI_MAXSTACK, more
 *               than 20 000 levels in Lua 5.4 and 5.5, with memory growing
 *               with the square of the depth); a sub-message below the
 *               walker's levels therefore goes to the callback, which then
 *               recurses in Lua as before -- no new limit, the same
 *               behaviour beyond it. The tag key is built as Lua's
 *               concatenation of the integer id makes it, the lookups are
 *               lua_gettable/lua_geti/lua_getfield (metamethods as in Lua),
 *               a value of an unexpected type goes to Lua; the reader is
 *               pb_read_record, which also skips a type-0 payload of 10 or
 *               more bytes (only its position is needed, upstream's 34-byte
 *               limit included). Google.jpg: of the ~11 100 records of
 *               the loop (~1450 ProcessProtobuf calls) 550 go to Lua in a
 *               fresh process (372 new Unknown sub-messages, 51 HandleTag),
 *               48 in a later command of a -stay_open session.
 *
 *               hdrpDecrypt is the loop of upstream's ProcessHDRP (Google.pm)
 *               from the padding to the removal of the padding: the data
 *               padded with zeros to a multiple of 8 bytes, unpacked as
 *               little-endian 32-bit words, each pair XORed with the low and
 *               the high half of the next xorshift64* key (seed
 *               0x2515606b4a7791cd, shifts 12/25/27, multiplier
 *               0x2545f4914f6cdd1d, all modulo 2^64), packed again and cut
 *               to the original length. Word i of the pair is byte i*4..i*4+3
 *               of the block and its key half is the little-endian bytes of
 *               the key, so each block is XORed bytewise with the key's
 *               eight bytes, least significant first; the bytes of a
 *               partial last block see the same bytes of their key, and the
 *               zero padding, which upstream encrypts and then removes, is
 *               never made. In Lua the unpack/pack 'V*' round trip took
 *               about 2 ms for the 28 KB block of a Google JPEG (here: 20
 *               microseconds), and table.unpack of all words is bounded by
 *               the Lua stack (~4 MB of data).
 *
 *               gmtime64 is the calendar arithmetic of Perl's own gmtime
 *               (time64.c, Perl_gmtime64_r; perl.lua's T64 has the rest of
 *               pp_gmtime and the localtime around it), formerly in Lua:
 *               ConvertUnixTime takes it for every local time through
 *               TimeZoneString, and the Lua version (a loop over the years
 *               since 2008 and the months, a table per call) was 2.2 of the
 *               9 microseconds of a call. Doubles as in time64.c, but
 *               floor/ceil/fmod are done here by integer conversion (see
 *               t64_floor), so the module still needs no libm; no state,
 *               only constant tables, and nothing of the C library's
 *               gmtime/localtime.
 *
 *               rockVersion is the version of the rockspec that built the
 *               module: the rockspec passes it as the define
 *               LEXIFTOOL_ROCK_VERSION=<version> (unquoted, a quoted string
 *               would not survive every compiler's command line), which is
 *               stringified here. src/lexiftool.lua makes the port version
 *               "<version> (LuaRocks)" from it when no build identity
 *               (_G.LEXIFTOOL_PORT_VERSION) is set. The Makefile, the
 *               standalone and the C API builds do not define it, so the
 *               field is absent there.
 *
 *               Windows (not driven by the Makefile):
 *                 MinGW: gcc -O2 -shared -I<lua>/include -o util.dll src/lexiftool/util.c <lua>/lua54.dll
 *                 MSVC:  cl /O2 /LD /I<lua>\include src\lexiftool\util.c <lua>\lua54.lib /Fe:util.dll
 *----------------------------------------------------------------------------*/

#include <stdint.h>
#include <string.h>

#include "lua.h"
#include "lauxlib.h"

#define CARRAY_CAPI_IMPLEMENT_GET_CAPI 1
#include "carray_capi.h"

#if defined(LEXIFTOOL_LUA_VERSION_NUM) && LEXIFTOOL_LUA_VERSION_NUM != LUA_VERSION_NUM
#  error "lua.h does not match the Lua version this module is built for (check LUA_INCDIR)"
#endif

/* The bytes of argument idx: a Lua string, or a carray of one-byte
 * elements read through its C API. The pointer is valid as long as the
 * argument stays on the stack and the carray is not modified. */
static const unsigned char* util_bytes_arg(lua_State* L, int idx, size_t* len) {
    if (lua_type(L, idx) == LUA_TSTRING) {
        return (const unsigned char*)lua_tolstring(L, idx, len);
    }
    if (lua_type(L, idx) == LUA_TUSERDATA) {
        const carray_capi* capi = carray_get_capi(L, idx, NULL);
        if (capi) {
            carray_info info;
            const carray* a = capi->toReadableCarray(L, idx, &info);
            if (a && info.elementSize == 1) {
                *len = info.elementCount;
                if (info.elementCount == 0) return (const unsigned char*)"";
                return (const unsigned char*)capi->getReadableElementPtr(a, 0, info.elementCount);
            }
        }
    }
    luaL_argerror(L, idx, "string or carray of bytes expected");
    return NULL;
}

/* base64decode(data) -> string: see the header. The table maps a byte to
 * its 6-bit value, B64_SKIP for '=' and white space (" \t\n\r\f", the set
 * of upstream's regex) and B64_END for anything else, where the data ends.
 * A constant with its initializer rather than filled at load time: the
 * module is opened once per lua_State, and the C API runs the states of
 * several sessions in parallel threads, so a table refilled by a second
 * luaopen while another thread decodes could be seen half done (B64_END
 * for a base64 character: the data cut short). Generated from the rules
 * above: every byte B64_END (65); then "A-Za-z0-9+/" -> 0..63; '=' and
 * " \t\n\r\f" -> B64_SKIP (64). */
enum { B64_SKIP = 64, B64_END = 65 };
static const unsigned char b64_table[256] = {
    /* 0x00 */ 65, 65, 65, 65, 65, 65, 65, 65, 65, 64, 64, 65, 64, 64, 65, 65,
    /* 0x10 */ 65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65,
    /* 0x20 */ 64, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 62, 65, 65, 65, 63,
    /* 0x30 */ 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 65, 65, 65, 64, 65, 65,
    /* 0x40 */ 65,  0,  1,  2,  3,  4,  5,  6,  7,  8,  9, 10, 11, 12, 13, 14,
    /* 0x50 */ 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 65, 65, 65, 65, 65,
    /* 0x60 */ 65, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40,
    /* 0x70 */ 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 65, 65, 65, 65, 65,
    /* 0x80 */ 65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65,
    /* 0x90 */ 65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65,
    /* 0xa0 */ 65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65,
    /* 0xb0 */ 65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65,
    /* 0xc0 */ 65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65,
    /* 0xd0 */ 65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65,
    /* 0xe0 */ 65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65,
    /* 0xf0 */ 65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65, 65
};

static int util_base64decode(lua_State* L) {
    size_t n, i, m = 0;              /* m: the base64 characters taken */
    const unsigned char* s = util_bytes_arg(L, 1, &n);
    luaL_Buffer b;
    unsigned q[4];
    int k = 0;
    luaL_buffinit(L, &b);
    for (i = 0; i < n; i++) {
        unsigned v = b64_table[s[i]];
        if (v == B64_SKIP) continue;
        if (v == B64_END) break;
        m++;
        q[k++] = v;
        if (k == 4) {
            char out[3];
            out[0] = (char)((q[0] << 2) | (q[1] >> 4));
            out[1] = (char)(((q[1] << 4) | (q[2] >> 2)) & 255);
            out[2] = (char)(((q[2] << 6) | q[3]) & 255);
            luaL_addlstring(&b, out, 3);
            k = 0;
        }
    }
    if (k > 1) {                     /* a partial group of k characters: k * 3 / 4 bytes */
        char out[2];
        size_t count = (size_t)(k * 3 / 4);      /* 2 -> 1, 3 -> 2 */
        while (k < 4) q[k++] = 0;                /* missing characters read as zero bits */
        out[0] = (char)((q[0] << 2) | (q[1] >> 4));
        out[1] = (char)(((q[1] << 4) | (q[2] >> 2)) & 255);
        luaL_addlstring(&b, out, count);
    } else if (k == 1 && m % 60 != 1) {
        /* upstream's quirk, kept for byte-identical output: a single
         * character beyond the groups of four is not reached by the chunk's
         * length byte (r * 3 / 4 = 0 bytes for it), so unpack 'u' takes it
         * for the length character of a second line and yields that many
         * zero bytes from the missing data -- unless it is a chunk of its
         * own (the 61st character): a length byte of ' ' ends the unpack
         * before it */
        unsigned i2;
        for (i2 = 0; i2 < q[0]; i2++) luaL_addchar(&b, '\0');
    }
    luaL_pushresult(&b);
    return 1;
}

/* ---- protobuf ----------------------------------------------------------- */

/* the values below 2^63 must be exact lua_Integers */
typedef char pb_check_lua_integer_64[sizeof(lua_Integer) == 8 ? 1 : -1];

enum { PB_OK, PB_FAIL, PB_LONG };   /* read, upstream's undef, fallback to Lua */

typedef struct {
    const unsigned char* s;
    size_t n;       /* the data length (upstream: length $$dataPt) */
    size_t pos;     /* upstream's $$dirInfo{Pos} */
    int bit0;       /* upstream's $$dirInfo{Bit0}, -1 while not set here */
} pb_reader;

/* upstream's VarInt: bit 0 of the first byte goes to bit0 as soon as it is
 * read; a truncated VarInt leaves pos past the bytes it read; PB_LONG once
 * a 10th byte would be needed (the value could exceed 2^63 - 1) */
static int pb_varint(pb_reader* r, uint64_t* out) {
    size_t pos = r->pos;
    uint64_t val;
    unsigned b;
    int k;
    if (pos >= r->n) return PB_FAIL;
    b = r->s[pos++];
    val = b & 0x7f;
    r->bit0 = (int)(val & 1);
    for (k = 1; b & 0x80; k++) {
        if (k == 9) return PB_LONG;
        if (pos >= r->n) { r->pos = pos; return PB_FAIL; }
        b = r->s[pos++];
        val |= (uint64_t)(b & 0x7f) << (7 * k);
    }
    r->pos = pos;
    *out = val;
    return PB_OK;
}

typedef struct {
    int hdr;            /* the header was read (id and type are set) */
    lua_Integer id;
    int type;
    uint64_t ival;      /* the payload of type 0 */
    size_t start, len;  /* the payload of the other types (len 0: '') */
} pb_record;

/* upstream's ReadRecord: PB_OK with the payload in rec, PB_FAIL for its
 * undef (rec->hdr tells whether id and type are known), PB_LONG */
static int pb_read_record(pb_reader* r, pb_record* rec) {
    uint64_t val, len;
    size_t need = 0;
    int st;
    rec->hdr = 0;
    rec->start = 0;
    rec->len = 0;
    st = pb_varint(r, &val);
    if (st != PB_OK) return st;
    rec->hdr = 1;
    rec->id = (lua_Integer)(val >> 3);
    rec->type = (int)(val & 7);
    switch (rec->type) {
    case 0:                             /* VarInt */
        return pb_varint(r, &rec->ival);
    case 1: need = 8; break;            /* 64-bit number */
    case 5: need = 4; break;            /* 32-bit number */
    case 2:                             /* string, bytes or protobuf */
        st = pb_varint(r, &len);
        if (st == PB_LONG) return st;
        /* upstream `if ($len)`: an unreadable or zero length is '' */
        if (st == PB_FAIL || len == 0) return PB_OK;
        if (len > r->n - r->pos) return PB_FAIL;
        need = (size_t)len;
        break;
    case 3: case 4:                     /* (deprecated start/end group) */
        return PB_OK;
    default:                            /* 6, 7: no payload, upstream's undef */
        return PB_FAIL;
    }
    if (need > r->n - r->pos) return PB_FAIL;
    rec->start = r->pos;
    rec->len = need;
    r->pos += need;
    return PB_OK;
}

/* pbRecord(data, pos) -> buff, id, type, newpos, bit0 | false: see the
 * header. buff is nil on upstream's undef, id and type then as far as they
 * were read; bit0 is nil when no byte was read. false (a VarInt of 10 or
 * more bytes, or a position that is no integer or negative) leaves the
 * record to the Lua reader. */
static int util_pbRecord(lua_State* L) {
    pb_reader r;
    pb_record rec;
    int isnum, st;
    lua_Integer pos;
    r.s = util_bytes_arg(L, 1, &r.n);
    pos = lua_tointegerx(L, 2, &isnum);
    if (!isnum || pos < 0) { lua_pushboolean(L, 0); return 1; }
    r.pos = (size_t)pos;
    r.bit0 = -1;
    if (r.pos > r.n) {              /* nothing to read: upstream's undef */
        lua_pushnil(L); lua_pushnil(L); lua_pushnil(L);
        lua_pushinteger(L, pos);
        lua_pushnil(L);
        return 5;
    }
    st = pb_read_record(&r, &rec);
    if (st == PB_LONG) { lua_pushboolean(L, 0); return 1; }
    if (st == PB_FAIL) lua_pushnil(L);
    else if (rec.type == 0) lua_pushinteger(L, (lua_Integer)rec.ival);
    else lua_pushlstring(L, (const char*)r.s + rec.start, rec.len);
    if (rec.hdr) {
        lua_pushinteger(L, rec.id);
        lua_pushinteger(L, rec.type);
    } else {
        lua_pushnil(L); lua_pushnil(L);
    }
    lua_pushinteger(L, (lua_Integer)r.pos);
    if (r.bit0 < 0) lua_pushnil(L); else lua_pushinteger(L, r.bit0);
    return 5;
}

/* pbIsProtobuf(data) -> true | false | nil: upstream's IsProtobuf (all
 * records read, ending exactly at the end of the data); nil leaves the
 * check to the Lua version (a VarInt of 10 or more bytes) */
static int util_pbIsProtobuf(lua_State* L) {
    pb_reader r;
    pb_record rec;
    r.s = util_bytes_arg(L, 1, &r.n);
    r.pos = 0;
    r.bit0 = -1;
    for (;;) {
        int st = pb_read_record(&r, &rec);
        if (st == PB_LONG) { lua_pushnil(L); return 1; }
        if (st == PB_FAIL) { lua_pushboolean(L, 0); return 1; }
        if (r.pos == r.n) { lua_pushboolean(L, 1); return 1; }
    }
}

/* ---- protobuf walker ---------------------------------------------------- */

/* upstream's VarInt for the payload of a type-0 record, of any length up
 * to its limit (34 bytes), by position only: PB_OK or PB_FAIL. bit0 is
 * that of the first byte, as upstream sets it. */
static int pb_skip_varint(pb_reader* r) {
    size_t pos = r->pos;
    unsigned b;
    int i = 0;
    if (pos >= r->n) return PB_FAIL;
    b = r->s[pos++];
    r->bit0 = (int)(b & 1);
    while (b & 0x80) {
        if (pos >= r->n) { r->pos = pos; return PB_FAIL; }
        b = r->s[pos++];
        if (!(b & 0x80)) break;
        if (++i > 32) { r->pos = pos; return PB_FAIL; }   /* upstream's limit */
    }
    r->pos = pos;
    return PB_OK;
}

/* pb_read_record, except that a type-0 payload of 10 or more bytes is
 * skipped (PB_OK, *noval = 1: rec->ival is not set) where pb_read_record
 * answers PB_LONG; PB_LONG remains for a header or a length of 10+ bytes */
static int pb_read_record_skip(pb_reader* r, pb_record* rec, int* noval) {
    size_t start = r->pos;
    int st = pb_read_record(r, rec);
    *noval = 0;
    if (st == PB_LONG && rec->hdr && rec->type == 0) {
        uint64_t v;
        r->pos = start;                 /* the header again, then the payload */
        if (pb_varint(r, &v) != PB_OK) return PB_LONG;
        *noval = 1;
        return pb_skip_varint(r);
    }
    return st;
}

/* upstream's IsProtobuf of s[0..n): 1 or 0, -1 for a header or a length of
 * 10 or more bytes (the Lua reader decides) */
static int pb_is_protobuf(const unsigned char* s, size_t n) {
    pb_reader r;
    pb_record rec;
    int noval;
    r.s = s; r.n = n; r.pos = 0; r.bit0 = -1;
    for (;;) {
        int st = pb_read_record_skip(&r, &rec, &noval);
        if (st == PB_LONG) return -1;
        if (st == PB_FAIL) return 0;
        if (r.pos == r.n) return 1;
    }
}

/* the levels the walker keeps itself; a sub-message one level deeper is
 * handed to the Lua loop with its recursion (mode 0 below) */
#define PBW_MAXDEPTH 64

/* the stack slots of pbWalk: its arguments, the current
 * et.ProtoPrefix[dirName], then three per level */
enum {
    PBW_DATA = 1, PBW_DIRSTART, PBW_DIREND, PBW_DATAPOS, PBW_DIRINFO,
    PBW_TAGTBL, PBW_ET, PBW_DIRNAME, PBW_CB, PBW_PROTOPRE, PBW_LEVELS
};
#define PBW_SLOTS 3     /* per level: prefix, data string, dirInfo (both lazy) */
#define PBW_EXTRA 16    /* working slots: tag key, tag info, fields, call */

typedef struct {
    const unsigned char* s;     /* the level's data (inside argument 1) */
    size_t n;                   /* its length */
    lua_Integer pos, end;       /* upstream's Pos and $dirEnd */
    lua_Integer dataPos;        /* upstream's $dataPos */
    int slot;                   /* its first stack slot (the prefix) */
} pbw_level;

enum { PBW_SKIP, PBW_DELEGATE, PBW_RECURSE };

/* slot PBW_PROTOPRE = et.ProtoPrefix[dirName], nil when there is none (a
 * nil dirName is not used as a key: every record goes to Lua then) */
static void pbw_protopre(lua_State* L) {
    if (lua_isnil(L, PBW_DIRNAME)) {
        lua_pushnil(L);
    } else if (lua_getfield(L, PBW_ET, "ProtoPrefix") == LUA_TTABLE) {
        lua_pushvalue(L, PBW_DIRNAME);
        lua_gettable(L, -2);
        lua_remove(L, -2);
    } else {
        lua_pop(L, 1);
        lua_pushnil(L);
    }
    lua_replace(L, PBW_PROTOPRE);
}

/* pushes the string a .. b .. tostring(id) .. c (a, b: stack indices of
 * strings, b may be 0 for none; id >= 0; c may be NULL), as Lua's
 * concatenation of the integer id makes it */
static void pbw_concat(lua_State* L, int a, int b, lua_Integer id, const char* c) {
    char digits[24];
    size_t nd = 0, la, lb = 0;
    const char* sa = lua_tolstring(L, a, &la);
    const char* sb = b ? lua_tolstring(L, b, &lb) : NULL;
    luaL_Buffer buf;
    do { digits[sizeof(digits) - 1 - nd++] = (char)('0' + id % 10); id /= 10; } while (id);
    luaL_buffinit(L, &buf);
    luaL_addlstring(&buf, sa, la);
    if (sb) luaL_addlstring(&buf, sb, lb);
    luaL_addlstring(&buf, digits + sizeof(digits) - nd, nd);
    if (c) luaL_addstring(&buf, c);
    luaL_pushresult(&buf);
}

/* what ProcessRecord would do with the record rec of level c (read
 * natively): PBW_SKIP when it would do nothing but read it (its `next`
 * before any side effect), PBW_RECURSE for an Unknown sub-message it would
 * process (ProcessProtobuf with "$prefix$id-"), PBW_DELEGATE for
 * everything else. Only reads: the tag table and the tag info, as
 * ProcessRecord does. */
static int pbw_decide(lua_State* L, const pbw_level* c, const pb_record* rec) {
    const unsigned char* p = c->s + rec->start;
    int top = lua_gettop(L), act = PBW_DELEGATE, unk;
    size_t lpre, lpfx;
    if (lua_type(L, PBW_PROTOPRE) != LUA_TSTRING) return PBW_DELEGATE;
    /* $buff =~ /\.proto$/ ($ also before a final newline) */
    if (rec->type == 2 && rec->len >= 6 &&
        (memcmp(p + rec->len - 6, ".proto", 6) == 0 ||
         (rec->len >= 7 && memcmp(p + rec->len - 7, ".proto\n", 7) == 0)))
        return PBW_DELEGATE;
    /* $tag = "$$et{ProtoPrefix}{$dirName}$prefix$id"; $$tagTbl{$tag},
     * plus the port's number key of a bare field number */
    lua_tolstring(L, PBW_PROTOPRE, &lpre);
    lua_tolstring(L, c->slot, &lpfx);
    pbw_concat(L, PBW_PROTOPRE, c->slot, rec->id, NULL);
    if (lua_gettable(L, PBW_TAGTBL) == LUA_TNIL && lpre == 0 && lpfx == 0) {
        lua_pop(L, 1);
        lua_geti(L, PBW_TAGTBL, rec->id);
    }
    if (!lua_toboolean(L, -1)) {
        /* no tag info: `next unless $type == 2 or $unknown`, else AddTagToTable */
        act = rec->type == 2 ? PBW_DELEGATE : PBW_SKIP;
    } else if (lua_type(L, -1) == LUA_TTABLE) {
        lua_getfield(L, -1, "Unknown");
        unk = lua_toboolean(L, -1);
        lua_pop(L, 1);
        if (rec->type != 2) {
            act = unk ? PBW_SKIP : PBW_DELEGATE;
        } else if (unk) {
            int t = lua_getfield(L, -1, "IsProtobuf");
            int isPb = lua_toboolean(L, -1);
            lua_pop(L, 1);
            if (isPb) {
                /* recursion unless IsProtobuf fails (the flag is reset),
                 * the Lua reader is needed, or a Format or SubDirectory
                 * takes it elsewhere */
                if (pb_is_protobuf(p, rec->len) == 1) {
                    int fmt, sub;
                    lua_getfield(L, -1, "Format");
                    fmt = lua_toboolean(L, -1);
                    sub = lua_getfield(L, -2, "SubDirectory") != LUA_TNIL;
                    lua_pop(L, 2);
                    act = fmt || sub ? PBW_DELEGATE : PBW_RECURSE;
                }
            } else if (t == LUA_TNIL) {
                /* the flag is set when $buff =~ /[^\x20-\x7e]/ and IsProtobuf */
                size_t i;
                act = PBW_SKIP;
                for (i = 0; i < rec->len; i++) {
                    if (p[i] < 0x20 || p[i] > 0x7e) {
                        if (pb_is_protobuf(p, rec->len) != 0) act = PBW_DELEGATE;
                        break;
                    }
                }
            } else {
                act = PBW_SKIP;     /* IsProtobuf false: `next unless ... $unknown` */
            }
        }
    }
    lua_settop(L, top);
    return act;
}

/* pushes a level for the data s[0..n) with prefix (the string on top of
 * the stack, which becomes its first slot) */
static void pbw_push(lua_State* L, pbw_level* lv, int depth, const unsigned char* s,
                     size_t n, lua_Integer dataPos) {
    pbw_level* c = &lv[depth];
    if (!lua_checkstack(L, PBW_SLOTS + PBW_EXTRA)) luaL_error(L, "pbWalk: no stack space");
    c->slot = lua_gettop(L);
    lua_pushnil(L);                 /* data string, made when needed */
    lua_pushnil(L);                 /* dirInfo, likewise */
    c->s = s;
    c->n = n;
    c->pos = 0;
    c->end = (lua_Integer)n;
    c->dataPos = dataPos;
}

/* cb(dirInfo, data, dataPos, dirEnd, pos, prefix, depth, mode) for level c
 * (see util_pbWalk); leaves its two results on the stack */
static void pbw_call(lua_State* L, pbw_level* c, int depth, int mode) {
    if (lua_isnil(L, c->slot + 1)) {
        lua_pushlstring(L, (const char*)c->s, c->n);
        lua_replace(L, c->slot + 1);
    }
    if (lua_isnil(L, c->slot + 2)) {
        /* upstream's %subdir: ( DataPt => \$buff, DataPos => $addr, DirName => $dirName ) */
        lua_createtable(L, 0, 4);
        lua_pushvalue(L, c->slot + 1);
        lua_setfield(L, -2, "DataPt");
        lua_pushinteger(L, c->dataPos);
        lua_setfield(L, -2, "DataPos");
        lua_pushvalue(L, PBW_DIRNAME);
        lua_setfield(L, -2, "DirName");
        lua_replace(L, c->slot + 2);
    }
    lua_pushvalue(L, PBW_CB);
    lua_pushvalue(L, c->slot + 2);
    lua_pushvalue(L, c->slot + 1);
    lua_pushinteger(L, c->dataPos);
    lua_pushinteger(L, c->end);
    lua_pushinteger(L, c->pos);
    lua_pushvalue(L, c->slot);
    lua_pushinteger(L, depth);
    lua_pushinteger(L, mode);
    lua_call(L, 8, 2);
}

/* pbWalk(data, dirStart, dirEnd, dataPos, dirInfo, tagTbl, et, dirName, cb)
 * -> pos, bit0: the record loop of ProcessProtobuf (top level, prefix '')
 * over the string data from dirStart while Pos < dirEnd, sub-messages
 * included, iteratively with a stack of levels of its own. A record it
 * would only read is skipped here and an Unknown sub-message it would
 * process is entered here (see pbw_decide); every other record goes to
 *   cb(dirInfo, data, dataPos, dirEnd, pos, prefix, depth, mode)
 * -- the level's dirInfo (the argument at depth 0, a table as upstream's
 * %subdir below), its data, $dataPos, $dirEnd, the record's position, the
 * level's prefix and depth -- which processes it in Lua (ProcessRecord)
 * and returns false for upstream's `last` or the new Pos; mode 1: the
 * record was read here, and an Unknown sub-message is not processed by
 * Lua but announced with a second result, its prefix ("$prefix$id-"),
 * and entered here; mode 0: Lua processes a sub-message itself (a record
 * with a VarInt of 10+ bytes, and at PBW_MAXDEPTH); mode -1: Lua
 * processes the rest of the level from its dirInfo's Pos (after a mode-0
 * record left a Pos that is no integer). Returns the final Pos of the top
 * level and its Bit0 as far as set here (nil where Lua left them in
 * dirInfo). */
static int util_pbWalk(lua_State* L) {
    pbw_level lv[PBW_MAXDEPTH];
    int depth = 0, lastBit0 = -1, havePos = 1;
    size_t n;
    const unsigned char* s;
    lua_Integer dirStart, dirEnd, dataPos;
    luaL_checktype(L, PBW_DATA, LUA_TSTRING);
    s = (const unsigned char*)lua_tolstring(L, PBW_DATA, &n);
    dirStart = luaL_checkinteger(L, PBW_DIRSTART);
    dirEnd = luaL_checkinteger(L, PBW_DIREND);
    dataPos = luaL_checkinteger(L, PBW_DATAPOS);
    luaL_checktype(L, PBW_DIRINFO, LUA_TTABLE);
    luaL_checkany(L, PBW_DIRNAME);
    luaL_checktype(L, PBW_CB, LUA_TFUNCTION);
    luaL_argcheck(L, dirStart >= 0, PBW_DIRSTART, "negative position");
    lua_settop(L, PBW_CB);
    lua_pushnil(L);
    pbw_protopre(L);
    lua_pushliteral(L, "");
    pbw_push(L, lv, 0, s, n, dataPos);
    lua_pushvalue(L, PBW_DATA);
    lua_replace(L, lv[0].slot + 1);
    lua_pushvalue(L, PBW_DIRINFO);
    lua_replace(L, lv[0].slot + 2);
    lv[0].pos = dirStart;
    lv[0].end = dirEnd;
    for (;;) {
        pbw_level* c = &lv[depth];
        pb_reader r;
        pb_record rec;
        int st = PB_FAIL, noval, act = PBW_DELEGATE;
        if (c->pos >= c->end) {             /* `last if $pos >= $dirEnd` */
            if (depth == 0) break;
            lua_settop(L, c->slot - 1);
            depth--;
            continue;
        }
        if (c->pos <= (lua_Integer)c->n) {  /* (beyond: upstream's undef) */
            r.s = c->s; r.n = c->n; r.pos = (size_t)c->pos; r.bit0 = -1;
            st = pb_read_record_skip(&r, &rec, &noval);
            if (st == PB_OK) act = pbw_decide(L, c, &rec);
        }
        if (act == PBW_RECURSE && depth + 1 < PBW_MAXDEPTH) {
            c->pos = (lua_Integer)r.pos;
            if (depth == 0) lastBit0 = r.bit0;
            /* $addr = $dataPos + $$dirInfo{Pos} - length($buff) */
            pbw_concat(L, c->slot, 0, rec.id, "-");
            pbw_push(L, lv, depth + 1, c->s + rec.start, rec.len,
                     (lua_Integer)((lua_Unsigned)c->dataPos + r.pos - rec.len));
            depth++;
            continue;
        }
        if (act == PBW_SKIP) {
            c->pos = (lua_Integer)r.pos;
            if (depth == 0) lastBit0 = r.bit0;
            continue;
        }
        /* to Lua */
        pbw_call(L, c, depth, st == PB_OK && depth + 1 < PBW_MAXDEPTH ? 1 : 0);
        if (depth == 0) lastBit0 = -1;
        pbw_protopre(L);                    /* a .proto record changes it */
        if (lua_isinteger(L, -2)) {
            c->pos = lua_tointeger(L, -2);
            if (!lua_isnil(L, -1)) {        /* the sub-message of a mode-1 record */
                if (lua_type(L, -1) != LUA_TSTRING || st != PB_OK || depth + 1 >= PBW_MAXDEPTH ||
                    rec.type != 2 || c->pos != (lua_Integer)r.pos)
                    return luaL_error(L, "pbWalk: unexpected sub-message from the callback");
                lua_remove(L, -2);
                pbw_push(L, lv, depth + 1, c->s + rec.start, rec.len,
                         (lua_Integer)((lua_Unsigned)c->dataPos + r.pos - rec.len));
                depth++;
                continue;
            }
            lua_pop(L, 2);
            continue;
        }
        if (lua_type(L, -2) == LUA_TNUMBER) {   /* a Pos that is no integer */
            lua_pop(L, 2);
            pbw_call(L, c, depth, -1);
            pbw_protopre(L);
        } else if (lua_type(L, -2) != LUA_TBOOLEAN || lua_toboolean(L, -2)) {
            return luaL_error(L, "pbWalk: unexpected result from the callback");
        }
        /* `last` (or the rest done in Lua): the level ends */
        if (depth == 0) { havePos = 0; break; }
        lua_settop(L, c->slot - 1);
        depth--;
    }
    if (havePos) lua_pushinteger(L, lv[0].pos); else lua_pushnil(L);
    if (lastBit0 < 0) lua_pushnil(L); else lua_pushinteger(L, lastBit0);
    return 2;
}

/* ---- HDRP --------------------------------------------------------------- */

/* hdrpDecrypt(data) -> string: see the header. uint64_t keeps the
 * arithmetic of upstream's `& 0xffffffffffffffff` (unsigned wraparound,
 * logical shifts by less than 64 bits). */
static int util_hdrpDecrypt(lua_State* L) {
    size_t n, i;
    const unsigned char* s = util_bytes_arg(L, 1, &n);
    uint64_t key = UINT64_C(0x2515606b4a7791cd);
    luaL_Buffer b;
    unsigned char* out;
    luaL_buffinit(L, &b);
    out = (unsigned char*)luaL_prepbuffsize(&b, n);
    for (i = 0; i < n; i += 8) {
        size_t j, m = n - i < 8 ? n - i : 8;
        key ^= key >> 12;
        key ^= key << 25;
        key ^= key >> 27;
        key *= UINT64_C(0x2545f4914f6cdd1d);
        for (j = 0; j < m; j++) out[i + j] = (unsigned char)(s[i + j] ^ (unsigned char)(key >> (8 * j)));
    }
    luaL_addsize(&b, n);
    luaL_pushresult(&b);
    return 1;
}

/* ---- gmtime64 ----------------------------------------------------------- */

/* The calendar of Perl_gmtime64_r (time64.c), as static const tables. */
static const int t64_days_in_month[2][12] = {
    { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 },
    { 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 },
};
static const int t64_julian_days_by_month[2][12] = {
    { 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334 },
    { 0, 31, 60, 91, 121, 152, 182, 213, 244, 274, 305, 335 },
};
static const int t64_length_of_year[2] = { 365, 366 };
#define T64_YEARS_IN_GREGORIAN_CYCLE 400
#define T64_DAYS_IN_GREGORIAN_CYCLE ((365 * 400) + 100 - 4 + 1)
/* days since the epoch on Jan 1st, 2008 GMT, and that year as a tm_year */
#define T64_CHEAT_DAYS (1199145600 / 24 / 60 / 60)
#define T64_CHEAT_YEARS 108
/* the bounds of pp_gmtime (TIME_LOWER_BOUND/UPPER_BOUND, pp_sys.c) */
#define T64_TIME_LOWER_BOUND (-67768100567755200.0)
#define T64_TIME_UPPER_BOUND 67767976233316800.0

/* IS_LEAP(n) of a tm_year n (years since 1900): 1 or 0 */
static int t64_is_leap(int64_t n) {
    int64_t y = n + 1900;
    return (y % 400 == 0) || (y % 4 == 0 && y % 100 != 0);
}

/* C's 32-bit int arithmetic on the year (two's-complement wraparound, the
 * port's T64.i32), computed in uint64_t, whose wraparound is defined */
static int64_t t64_i32(int64_t v) {
    return (int64_t)(((uint64_t)v + UINT64_C(0x80000000)) & UINT64_C(0xffffffff)) - INT64_C(0x80000000);
}

/* floor and ceil of a double x with |x| < 2^63, and the (int) cast of
 * fmod(x, y) for a positive integer y, all without the C math library
 * (which a module cannot count on being linked): the conversion to int64_t
 * truncates toward zero (C99 6.3.1.4); a double of 2^52 or more is
 * integral already. (int)fmod(x, y) is trunc(x - n*y) with n = trunc(x/y),
 * i.e. trunc(x) - n*y, and n = trunc(trunc(x)/y): C's integer remainder
 * of trunc(x). */
static double t64_floor(double x) {
    double t = (double)(int64_t)x;
    return t > x ? t - 1 : t;
}
static double t64_ceil(double x) {
    double t = (double)(int64_t)x;
    return t < x ? t + 1 : t;
}
static int64_t t64_imod(double x, int64_t y) {
    return (int64_t)x % y;
}

/* gmtime64(time) -> sec, min, hour, mday, mon, year, wday, yday: see the
 * header. Statement for statement Perl_gmtime64_r as the port had it in
 * Lua (the former T64.gmtime64_r of perl.lua, kept as the reference in
 * test_util.lua), in doubles as there, with floor/ceil/fmod as above;
 * the (int64_t) casts truncate toward zero like C's (int) and, within the
 * bounds, stay far inside int64_t. */
static int util_gmtime64(lua_State* L) {
    double time = luaL_checknumber(L, 1);
    int64_t year = 70;
    int64_t v_tm_sec, v_tm_min, v_tm_hour, v_tm_wday, v_tm_mon, cycles;
    double v_tm_tday, m;
    int leap;
    luaL_argcheck(L, time >= T64_TIME_LOWER_BOUND && time <= T64_TIME_UPPER_BOUND, 1,
                  "time out of bounds");

    v_tm_sec = t64_imod(time, 60);
    time = time >= 0 ? t64_floor(time / 60.0) : t64_ceil(time / 60.0);
    v_tm_min = t64_imod(time, 60);
    time = time >= 0 ? t64_floor(time / 60.0) : t64_ceil(time / 60.0);
    v_tm_hour = t64_imod(time, 24);
    time = time >= 0 ? t64_floor(time / 24.0) : t64_ceil(time / 24.0);
    v_tm_tday = time;

    /* WRAP (v_tm_sec, v_tm_min, 60) etc. */
    if (v_tm_sec < 0) { v_tm_min--; v_tm_sec += 60; }
    if (v_tm_min < 0) { v_tm_hour--; v_tm_min += 60; }
    if (v_tm_hour < 0) { v_tm_tday -= 1; v_tm_hour += 24; }

    v_tm_wday = t64_imod(v_tm_tday + 4.0, 7);
    if (v_tm_wday < 0) v_tm_wday += 7;
    m = v_tm_tday;

    if (m >= T64_CHEAT_DAYS) {
        year = T64_CHEAT_YEARS;
        m -= T64_CHEAT_DAYS;
    }

    if (m >= 0) {
        /* Gregorian cycles, this is huge optimization for distant times */
        cycles = (int64_t)t64_floor(m / (double)T64_DAYS_IN_GREGORIAN_CYCLE);
        if (cycles != 0) {
            m -= (double)cycles * (double)T64_DAYS_IN_GREGORIAN_CYCLE;
            year = t64_i32(year + cycles * T64_YEARS_IN_GREGORIAN_CYCLE);
        }

        /* Years */
        leap = t64_is_leap(year);
        while (m >= t64_length_of_year[leap]) {
            m -= t64_length_of_year[leap];
            year++;
            leap = t64_is_leap(year);
        }

        /* Months */
        v_tm_mon = 0;
        while (m >= t64_days_in_month[leap][v_tm_mon]) {
            m -= t64_days_in_month[leap][v_tm_mon];
            v_tm_mon++;
        }
    } else {
        year--;

        /* Gregorian cycles */
        cycles = (int64_t)t64_ceil((m / (double)T64_DAYS_IN_GREGORIAN_CYCLE) + 1);
        if (cycles != 0) {
            m -= (double)cycles * (double)T64_DAYS_IN_GREGORIAN_CYCLE;
            year = t64_i32(year + cycles * T64_YEARS_IN_GREGORIAN_CYCLE);
        }

        /* Years */
        leap = t64_is_leap(year);
        while (m < -t64_length_of_year[leap]) {
            m += t64_length_of_year[leap];
            year--;
            leap = t64_is_leap(year);
        }

        /* Months */
        v_tm_mon = 11;
        while (m < -t64_days_in_month[leap][v_tm_mon]) {
            m += t64_days_in_month[leap][v_tm_mon];
            v_tm_mon--;
        }
        m += t64_days_in_month[leap][v_tm_mon];
    }

    /* At this point m is less than a year so casting to an int is safe */
    lua_pushinteger(L, (lua_Integer)v_tm_sec);
    lua_pushinteger(L, (lua_Integer)v_tm_min);
    lua_pushinteger(L, (lua_Integer)v_tm_hour);
    lua_pushinteger(L, (lua_Integer)((int64_t)m + 1));
    lua_pushinteger(L, (lua_Integer)v_tm_mon);
    lua_pushinteger(L, (lua_Integer)year);
    lua_pushinteger(L, (lua_Integer)v_tm_wday);
    lua_pushinteger(L, (lua_Integer)(t64_julian_days_by_month[leap][v_tm_mon] + (int64_t)m));
    return 8;
}

/* truthy(v) -> boolean: see the header; perl.lua sets perl.truthy to it,
 * so the ported modules' `local truthy = perl.truthy` bind this function.
 * Exactly the Lua version it replaced:
 *   v == nil or v == false or v == 0 or v == '0' or v == '' -> false
 *   isCarray(v) (getmetatable(v) == 'carray') -> n = v:len();
 *     n > 1 or (n == 1 and v:get(1) ~= 48)
 *   else true.
 * v == 0 holds for the integer 0 and for 0.0 and -0.0, not for NaN (C's
 * comparison of doubles agrees). A carray of one-byte elements (what the
 * port makes) is read through its C API; any other carray, and a userdata
 * whose carray C API is missing or of another version, takes the Lua
 * version's path itself: the metatable check of getmetatable() and the
 * methods len/get called through the userdata's __index. No state. */
static int util_truthy(lua_State* L) {
    int r = 1;
    switch (lua_type(L, 1)) {
    case LUA_TNONE: case LUA_TNIL:
        r = 0;
        break;
    case LUA_TBOOLEAN:
        r = lua_toboolean(L, 1);
        break;
    case LUA_TNUMBER:
        if (lua_isinteger(L, 1)) r = lua_tointeger(L, 1) != 0;
        else r = lua_tonumber(L, 1) != 0.0;
        break;
    case LUA_TSTRING: {
        size_t n;
        const char* s = lua_tolstring(L, 1, &n);
        r = !(n == 0 || (n == 1 && s[0] == '0'));
        break;
    }
    case LUA_TUSERDATA: {
        const carray_capi* capi = carray_get_capi(L, 1, NULL);
        if (capi) {
            carray_info info;
            const carray* a = capi->toReadableCarray(L, 1, &info);
            if (a && info.elementSize == 1) {
                size_t n = info.elementCount;
                r = n > 1 || (n == 1 && *(const unsigned char*)capi->getReadableElementPtr(a, 0, 1) != 48);
                break;
            }
        }
        /* the Lua version's path: getmetatable(v) == 'carray' */
        if (luaL_getmetafield(L, 1, "__metatable") == LUA_TSTRING) {
            size_t mn;
            const char* m = lua_tolstring(L, -1, &mn);
            int isCarray = mn == 6 && memcmp(m, "carray", 6) == 0;
            lua_pop(L, 1);
            if (isCarray) {
                lua_settop(L, 1);
                lua_getfield(L, 1, "len");          /* v:len() -> 2 */
                lua_pushvalue(L, 1);
                lua_call(L, 1, 1);
                lua_pushinteger(L, 1);              /* 3 */
                if (lua_compare(L, 3, 2, LUA_OPLT)) {
                    r = 1;
                } else if (lua_compare(L, 2, 3, LUA_OPEQ)) {
                    lua_getfield(L, 1, "get");      /* v:get(1) -> 4 */
                    lua_pushvalue(L, 1);
                    lua_pushinteger(L, 1);
                    lua_call(L, 2, 1);
                    lua_pushinteger(L, 48);         /* 5 */
                    r = !lua_compare(L, 4, 5, LUA_OPEQ);
                } else {
                    r = 0;
                }
            }
        } else {
            lua_settop(L, 1);
        }
        break;
    }
    default:
        break;
    }
    lua_pushboolean(L, r);
    return 1;
}

static const luaL_Reg util_funcs[] = {
    { "base64decode", util_base64decode },
    { "pbRecord", util_pbRecord },
    { "pbIsProtobuf", util_pbIsProtobuf },
    { "pbWalk", util_pbWalk },
    { "hdrpDecrypt", util_hdrpDecrypt },
    { "gmtime64", util_gmtime64 },
    { "truthy", util_truthy },
    { NULL, NULL }
};

#if defined(LEXIFTOOL_ROCK_VERSION)
#  define UTIL_STRINGIFY(x) #x
#  define UTIL_TOSTRING(x) UTIL_STRINGIFY(x)
#endif

int luaopen_lexiftool_util(lua_State* L) {
    luaL_newlib(L, util_funcs);
#if defined(LEXIFTOOL_ROCK_VERSION)
    lua_pushliteral(L, UTIL_TOSTRING(LEXIFTOOL_ROCK_VERSION));
    lua_setfield(L, -2, "rockVersion");
#endif
    return 1;
}
