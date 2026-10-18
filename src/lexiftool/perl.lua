--------------------------------------------------------------------------------
-- File:         lexiftool/perl.lua
--
-- Description:  Perl builtin primitives with Perl semantics (facade)
--------------------------------------------------------------------------------

-- Purpose: a single seam through which the ported Image::ExifTool code calls
-- every Perl builtin primitive (substr, unpack, ord, length, join, ...) with
-- Perl semantics. Ported modules call ONLY this facade for such operations and
-- never the raw string/table/math APIs (see doc/conventions.md §3a).
--
-- Conventions (Perl, not Lua):
--   * string offsets and array indices are 0-based (as in Perl);
--   * unpack template codes, counts and byte order follow Perl templates;
--   * the `off`-position unpack form also returns the final position.
--
-- Performance: frequently used library functions are bound to local aliases
-- at the top of the file so hot paths avoid repeated table lookups. A faster
-- backend (e.g. an FFI/carray implementation) may be selected by the caller
-- through the LEXIFTOOL_BACKEND global.
--
-- Configuration: the backend is selected through the global LEXIFTOOL_BACKEND
-- (set by the caller, e.g. `lua -e "LEXIFTOOL_BACKEND='carray'" ...`).
-- Environment variables are never read. The backend is selected exactly once
-- when this module loads (below), so ported modules may freely bind a facade
-- function to a local alias at the top of their file (`local unpack =
-- perl.unpack`) to avoid table lookups on hot paths; the backend is fixed at
-- module load, so already-bound aliases can never be invalidated.

-- Frequently used library functions as local aliases (see above).
local sbyte = string.byte
local schar = string.char
local srep = string.rep
local spack = string.pack
local smatch = string.match
local sfind = string.find
local sformat = string.format
local ssub = string.sub
local slower = string.lower
local supper = string.upper
local sgsub = string.gsub
local sgmatch = string.gmatch
local sunpack = string.unpack
local tconcat = table.concat
local tsort = table.sort
local tremove = table.remove
local tunpack = table.unpack
local tpack = table.pack
local mmax = math.max
local mmin = math.min
local mfloor = math.floor
local mtype = math.type
local mtointeger = math.tointeger

-- PCRE2 backend for perl.matches/subst/split/findAll/eachMatch/eachSplit
-- (see doc/api.md, doc/conventions.md §6): lpcre, which takes a Lua
-- string or a carray as subject (a carray without copying; gsub edits it in
-- place) and caches compiled patterns itself (LRU, see LPCRE_CACHE_SIZE).
local lpcre = require('lpcre')
local lpcreFind = lpcre.find
local lpcreTest = lpcre.test
local lpcreMatchpos = lpcre.matchpos
local lpcreFindmatch = lpcre.findmatch
local lpcreGsub = lpcre.gsub
local lpcreNew = lpcre.new

-- The port's own C module for the Perl builtins standard Lua lacks ($^O,
-- %ENV writes, tzset, chmod, truncate, %SIG, Term::ReadKey); mandatory
-- (src/lexiftool/sys.c, built by `make sys`).
local sys = require('lexiftool.sys')

local perl = {}

-- Numbers print with '.' (Perl's LC_NUMERIC=C). Perl keeps LC_NUMERIC at "C"
-- outside `use locale`, which upstream never uses, so its numbers always
-- print with '.'. Lua's string.format/tostring follow the process's global
-- C locale, which an embedding host may have set (e.g. de_DE: "1,5"). The
-- facade never sets a locale: it reads the decimal point the C library
-- currently uses (DECPT) and, where it is not '.', replaces it with '.' in
-- the formatted number -- in perlStr, in perl.sprintf's float conversions
-- and in the other float-to-string paths below. With the usual '.' this
-- costs one comparison. DECPT is read when this module loads and again by
-- perl.localeRefresh() (called by ExifTool.new and by the C API for each
-- command); a host that changes its locale between two calls without one
-- of those formats with the stale value.
local DECPT = sys.decimal_point()

-- Strings sort and compare as unsigned bytes (Perl's sort/cmp/lt outside
-- `use locale`). Lua's `<` on two strings goes through strcoll, i.e. the
-- LC_COLLATE order of the process's global C locale, which an embedding host
-- may have set (de_DE: "a A b B", Perl: "A B a b"). Under "C"/"POSIX" and
-- the codepoint-ordered "C.UTF-8" (glibc, musl) strcoll is strcmp and the
-- native `<` is already Perl's order (BYTE_ORDER);
-- otherwise perl.sort/perl.tsort/perl.lt/perl.cmp compare through
-- sys.strless/sys.strcmp. Like DECPT, the facade only reads the locale
-- (os.setlocale with a nil locale queries it), at module load and in
-- perl.localeRefresh().
local function collateIsBytes()
    local c = os.setlocale(nil, 'collate')
    return c == 'C' or c == 'POSIX' or c == 'C.UTF-8' or c == 'C.utf8'
end
local BYTE_ORDER = collateIsBytes()
local strless, strcmp = sys.strless, sys.strcmp

-- Case changes touch ASCII letters only (Perl's lc/uc/ucfirst/lcfirst
-- outside `use locale` on a byte string). Lua's string.lower/upper go
-- through tolower/toupper, i.e. the LC_CTYPE of the process's global C
-- locale: a single-byte locale (de_DE ISO-8859-15, Windows cp1252) also
-- maps bytes >= 0x80 ("\xc4" -> "\xe4"), a Turkish one maps 'I' to a
-- dotless i. CASE_ASCII says whether string.lower/upper change exactly
-- A-Z/a-z under the current LC_CTYPE (always so under "C" and the UTF-8
-- locales); then they are used as they are, otherwise the facade maps the
-- ASCII letters through the tables below. Like DECPT, read at module load
-- and in perl.localeRefresh().
local TO_LOWER, TO_UPPER = {}, {}
for c = 65, 90 do
    TO_LOWER[schar(c)] = schar(c + 32)
    TO_UPPER[schar(c + 32)] = schar(c)
end
local ALL_BYTES
do
    local t = {}
    for c = 0, 255 do t[c + 1] = schar(c) end
    ALL_BYTES = table.concat(t)
end
local ALL_LOWER = sgsub(ALL_BYTES, '[A-Z]', TO_LOWER)
local ALL_UPPER = sgsub(ALL_BYTES, '[a-z]', TO_UPPER)
local function caseIsAscii()
    return slower(ALL_BYTES) == ALL_LOWER and supper(ALL_BYTES) == ALL_UPPER
end
local CASE_ASCII = caseIsAscii()
local function asciiLower(s)
    if CASE_ASCII then return slower(s) end
    return (sgsub(s, '[A-Z]', TO_LOWER))
end
local function asciiUpper(s)
    if CASE_ASCII then return supper(s) end
    return (sgsub(s, '[a-z]', TO_UPPER))
end

-- A number formatted by the C library with '.' as its decimal point (only
-- called when DECPT ~= '.'; DECPT may be more than one byte)
local function fixDec(s)
    local i = sfind(s, DECPT, 1, true)
    if not i then return s end
    return ssub(s, 1, i - 1) .. '.' .. ssub(s, i + #DECPT)
end

-- A carray is Perl's mutable string scalar (doc/api.md §4).  Its
-- metatable is protected, so getmetatable() answers with the name.
local function isCarray(x)
    return type(x) == 'userdata' and getmetatable(x) == 'carray'
end
perl.isCarray = isCarray

local backend = 'lua'

-- Cache of parsed unpack format strings (template codes are static).
local FMT_CACHE = {}

-- Compiled PCRE2 patterns.  A pattern that is fixed in the ported source
-- (perl.matches & Co.) is handed to lpcre as the string itself and compiled
-- through lpcre's pattern cache, keyed by the pattern string.  A pattern
-- built at runtime from data (Perl `/$var/`: tag names, -if expressions,
-- interpolated conditions; the *Dyn functions) would only evict those from
-- the cache, so it is compiled into a regex object of its own, outside the
-- cache (lpcre's NOCACHE flag "n"), once per call -- or once for good where
-- the caller holds on to it (compileEdit, eval).
--
-- Cache size, measured: one
-- CLI call on one file uses up to ~360 distinct literal patterns, one
-- process over all 194 test images 806 (282703 lookups) -- with lpcre's
-- default of 256 that run recompiles 542 evicted patterns, with 1024 none.
local LPCRE_CACHE_SIZE = 1024
lpcre.cache(LPCRE_CACHE_SIZE)

-- A pattern that does not compile dies as Perl's regex compiler does, with
-- the reason (in PCRE2's words, not Perl's) and the pattern marked where the
-- compiler stopped: "missing closing parenthesis in regex; marked by
-- <-- HERE in m/( <-- HERE / at (eval) line 1."
local function dynamic(pat)
    if type(pat) == 'string' then
        local ok, re = pcall(lpcreNew, pat, 'n')
        if ok then return re end
        local why, off = tostring(re):match('%((.*) at offset (%d+)%)$')
        if not why then error(re, 0) end
        off = tonumber(off)
        error(why .. ' in regex; marked by <-- HERE in m/' .. pat:sub(1, off) .. ' <-- HERE ' ..
              pat:sub(off + 1) .. '/ at (eval) line 1.\n', 0)
    end
    return pat -- (already a regex object)
end

-- Mapping of Perl unpack codes to Lua format letters. Perl's l/L are always
-- 32 bits and q/Q always 64 (unlike Lua's 'l'/'L', which are C longs), so
-- they map to Lua's explicitly sized native-endian codes.
local LUAFMT = {
  c = 'b', C = 'B', s = 'h', S = 'H', n = '>H', v = '<H',
  i = 'i', I = 'I', l = 'i4', L = 'I4', N = '>I', V = '<I',
  q = 'i8', Q = 'I8',
  f = 'f', d = 'd',
}

-- Size in bytes of each fixed-size Perl unpack code.
local SIZE = {
  c = 1, C = 1, s = 2, S = 2, n = 2, v = 2,
  i = 4, I = 4, N = 4, V = 4, l = 4, L = 4,
  q = 8, Q = 8,
  f = 4, d = 8,
}

-- Return the name of the active backend.
function perl.backend()
    return backend
end

-- Backend selection from the caller-set global LEXIFTOOL_BACKEND. This runs
-- once, at module load, before any ported module binds facade functions to
-- local aliases; the backend can no longer be changed afterwards.
if _G.LEXIFTOOL_BACKEND then
    backend = _G.LEXIFTOOL_BACKEND
    if backend ~= 'lua' then
        error('perl: unknown backend: ' .. tostring(backend))
    end
end

-- Perl truthiness: undef, 0, '0' and '' are all false, everything else is
-- true. Lua disagrees on three of those four (only nil and false are falsy
-- there), so every ported boolean test on a Perl value goes through this.
-- A carray (Perl's mutable scalar, doc/api.md §4) is tested by its bytes,
-- like the scalar it stands for: empty or "0" is false.
function perl.truthy(v)
    if v == nil or v == false or v == 0 or v == '0' or v == '' then return false end
    if type(v) == 'userdata' and isCarray(v) then
        local n = v:len()
        return n > 1 or (n == 1 and v:get(1) ~= 48)
    end
    return true
end

-- Perl length() - bytes in a string, or bytes in a carray buffer.
function perl.length(x)
    if type(x) == "string" then return #x end
    if x == nil then return nil end -- (length undef is undef)
    if type(x) == "number" then
        -- the length of the number's string form (Perl stringifies an NV
        -- with %.15g, an IV exactly)
        if mtype(x) == 'integer' then return #string.format('%d', x) end
        if x ~= x then return 3 end                          -- 'NaN'
        if x == math.huge then return 3 end                  -- 'Inf'
        if x == -math.huge then return 4 end                 -- '-Inf'
        local s = string.format('%.15g', x)
        if DECPT ~= '.' then s = fixDec(s) end
        return #s
    end
    if perl.isUV(x) then return #tostring(x) end -- (a UV, see perl.uv)
    return x:len()  -- carray
end

-- Perl substr() - extract or replace a substring.
-- Inputs: 0) string (read-only) or carray (mutable), 1) 0-based offset
--            (negative = from the end), 2) optional length (negative = length
--            from the end; defaults to the rest), 3) optional replacement
-- Returns: the extracted substring.
-- The replacement (4-arg) form mutates its argument, so it only accepts a
-- carray (a Lua string is immutable and is an error here), matching Perl's
-- mutating-string-scalar semantics. carray's 1-based methods are reached via
-- the 0-based Perl offsets used throughout this facade.
function perl.substr(s, off, len, repl)
    -- (Perl numifies the offset and length: a numeric string such as an XMP
    --  value "152" is a valid length)
    if type(off) == 'string' then off = perl.num(off) end
    if type(len) == 'string' then len = perl.num(len) end
    -- (a number -- or a UV -- is read through its string form, as Perl
    --  stringifies the scalar; only the read form can take one)
    if repl == nil and (type(s) == 'number' or perl.isUV(s)) then s = perl.str(s) end
    if type(s) == "string" then
        if repl ~= nil then
            error("perl.substr: replacement requires a mutable carray, not a Lua string")
        end
        local n = #s
        if off < 0 then off = n + off end
        if off < 0 then off = 0 elseif off > n then off = n end
        local a = off
        local b
        if len == nil then
            b = n - 1
        elseif len < 0 then
            b = n + len - 1
        else
            b = a + len - 1
        end
        if b < a then return '' end
        return ssub(s, a + 1, b + 1)
    end
    -- carray (mutable)
    local n = s:len()
    if off < 0 then off = n + off end
    if off < 0 then off = 0 elseif off > n then off = n end
    local a = off
    local b
    if len == nil then
        b = n - 1
    elseif len < 0 then
        b = n + len - 1
    else
        b = a + len - 1
    end
    if b >= n then b = n - 1 end
    -- (the replacement may itself be a carray; carray's set/insert take both)
    local rlen = repl ~= nil and perl.length(repl)
    if b < a then
        if repl ~= nil and rlen > 0 then s:insert(a + 1, repl) end
        return ''
    end
    local got = s:tostring(a + 1, b + 1)
    if repl ~= nil and rlen == b - a + 1 then
        -- same-length replacement: overwrite in place (what Perl's lvalue
        -- substr amounts to here) instead of an O(n) remove + insert --
        -- Set16u/Set32u patch offsets this way, in loops over large buffers
        s:set(a + 1, repl)
    elseif repl ~= nil then
        s:remove(a + 1, b + 1)
        if rlen > 0 then s:insert(a + 1, repl) end
    end
    return got
end

-- Perl array element access (0-based index; negative = from the end).
function perl.at(list, i)
    local n = #list
    if i < 0 then i = n + i end
    if i < 0 or i >= n then return nil end
    return list[i + 1]
end

-- Perl join() - concatenate list elements with a separator.
-- (Perl stringifies each element: a float with an integral value joins as
--  "708", not table.concat's "708.0", and a UV object as its digits; so any
--  non-string element takes the perl.str path.)
function perl.join(sep, list)
    for i = 1, #list do
        if type(list[i]) ~= 'string' then
            local strs = {}
            for k = 1, #list do strs[k] = perl.str(list[k]) end
            return tconcat(strs, sep)
        end
    end
    return tconcat(list, sep)
end

-- Perl index() - 0-based position of the first occurrence of substr in s at
-- or after the 0-based position pos (default 0), or -1 if not found.
-- (A pos below 0 counts as 0 and one past the end as the end, as in Perl;
--  an empty substr is found at pos.)
function perl.index(s, sub, pos)
    s = perl.str(s)
    sub = perl.str(sub)
    pos = pos or 0
    if pos < 0 then pos = 0 elseif pos > #s then pos = #s end
    local i = sfind(s, sub, pos + 1, true)
    if i == nil then return -1 end
    return i - 1
end

-- Perl rindex() - 0-based position of the last occurrence of substr in s
-- that starts at or before the 0-based position pos (default: the end), or
-- -1 if not found.  (An empty substr is found at pos, or at the end.)
function perl.rindex(s, sub, pos)
    s = perl.str(s)
    sub = perl.str(sub)
    local maxStart = #s - #sub
    if pos ~= nil and pos < maxStart then maxStart = pos end
    if maxStart < 0 then return #sub == 0 and 0 or -1 end
    for i = maxStart + 1, 1, -1 do
        if s:sub(i, i + #sub - 1) == sub then return i - 1 end
    end
    return -1
end

-- Perl keys() - the keys of a hash, as a list (in no particular order, as in
-- Perl).
function perl.keys(h)
    local list = {}
    for k in pairs(h) do list[#list + 1] = k end
    return list
end

-- Perl sort() - returns a new list sorted by cmp(a, b), a Perl sort block
-- returning <0/0/>0 (`$a <=> $b`, `$a cmp $b`), or by default in Perl's
-- string order (each element stringified like Perl: a key 10 sorts before 9;
-- bytewise whatever the host's LC_COLLATE, see BYTE_ORDER).
-- With a sort block the order is stable, as Perl's mergesort is: elements the
-- block calls equal keep their input order (table.sort is not stable).
function perl.sort(list, cmp)
    local out = {}
    for i = 1, #list do out[i] = list[i] end
    if cmp then
        local deco = {}
        for i = 1, #out do deco[i] = { out[i], i } end
        tsort(deco, function(a, b)
            local c = cmp(a[1], b[1])
            if c ~= 0 then return c < 0 end
            return a[2] < b[2]
        end)
        for i = 1, #deco do out[i] = deco[i][1] end
    elseif BYTE_ORDER then
        tsort(out, function(a, b) return perl.str(a) < perl.str(b) end)
    else
        tsort(out, function(a, b) return strless(perl.str(a), perl.str(b)) end)
    end
    return out
end

-- In-place sort of a Lua list (port: the facade's stand-in for table.sort,
-- which ported code never calls directly). With lt(a, b) it is table.sort;
-- a comparator that orders strings compares them with perl.lt/perl.cmp.
-- Without one, a list of strings sorts bytewise as Perl's default sort does,
-- whatever the host's LC_COLLATE (see BYTE_ORDER), and a list of numbers
-- numerically as table.sort does. Not stable, like table.sort.
function perl.tsort(list, lt)
    if lt then
        tsort(list, lt)
    elseif BYTE_ORDER or type(list[1]) ~= 'string' then
        tsort(list)
    else
        tsort(list, strless)
    end
end

-- Perl lt - true when the stringified a sorts before the stringified b, as
-- unsigned bytes (Perl outside `use locale`; see BYTE_ORDER). `$a gt $b` is
-- perl.lt(b, a).
function perl.lt(a, b)
    if type(a) ~= 'string' then a = perl.str(a) end
    if type(b) ~= 'string' then b = perl.str(b) end
    if BYTE_ORDER then return a < b end
    return strless(a, b)
end

-- Perl cmp - -1, 0 or 1 for the stringified a and b, as unsigned bytes
-- (Perl outside `use locale`; see BYTE_ORDER).
function perl.cmp(a, b)
    if type(a) ~= 'string' then a = perl.str(a) end
    if type(b) ~= 'string' then b = perl.str(b) end
    if BYTE_ORDER then
        if a < b then return -1 elseif a == b then return 0 end
        return 1
    end
    return strcmp(a, b)
end

-- Perl reverse() in LIST context - returns the arguments in reverse order.
-- (Perl's scalar-context reverse, which reverses a string, is Lua's own
--  s:reverse() and needs no facade.)
function perl.reverse(...)
    local a = { ... }
    local r = {}
    for i = #a, 1, -1 do r[#r + 1] = a[i] end
    return tunpack(r)
end

-- Perl defined() - true if the value is not undef.
function perl.D(x)
    return x ~= nil
end

-- Perl exists() - true if key is present in the hash.
function perl.E(h, k)
    return h ~= nil and h[k] ~= nil
end

-- Match p (a pattern string from the ported source, or a regex object)
-- against s, starting at the 0-based offset pos. Returns the captures (like
-- Perl's $1, $2, ...; or true if pat has no capturing groups), plus the
-- 0-based end offset of the match (Perl pos() semantics) - or nil on no
-- match.  s may be a Lua string or a carray (Perl's mutable scalar,
-- doc/api.md §4), which lpcre matches in place, without a copy.
--
-- A group that took no part in the match is nil, as Perl's $N is undef
-- (lpcre returns it as nil, so the captures need no translation).  The
-- price: when the FIRST group is such a group, the first return value of a
-- successful match is nil, so a match can only be tested for in boolean
-- context through perl.isMatch (doc/conventions.md §6;
-- tools/verify_matchbool.lua enforces it).  The trailing end offset is never
-- nil, so `{ matches(...) }` is empty exactly when nothing matched.
--
-- lpcre.matchpos returns exactly this shape (the captures, or true without
-- groups, then the 1-based inclusive end of the match, which is Perl's
-- 0-based pos()), so the call is a plain tail call.
-- (a number subject -- or a UV -- is matched in its Perl string form: lpcre
--  would stringify it the Lua way, %.14g and the locale's decimal point)
local function doMatches(p, s, pos)
    if s == nil then return nil end -- (Perl: undef =~ /pat/ is simply false)
    if type(s) ~= 'string' and s ~= nil and not isCarray(s) then s = perl.str(s) end
    return lpcreMatchpos(s, p, (pos or 0) + 1)
end

-- Perl `$s =~ /pat/` (no /g) in list context - pat is a literal pattern
-- from the ported source, compiled through lpcre's pattern cache.
function perl.matches(s, pat, pos)
    return doMatches(pat, s, pos)
end

-- Same as perl.matches, but for pat built at runtime (e.g. Perl `/$var/`):
-- compiles pat on every call, outside the pattern cache.
function perl.matchesDyn(s, pat, pos)
    return doMatches(dynamic(pat), s, pos)
end

-- Perl `$s =~ /pat/` (no /g) in scalar (boolean) context: true if p matches
-- s from the 0-based offset pos, else false - whatever the captures are.
-- On a match the captures follow (nil for a group that took no part, as in
-- doMatches; no end offset), so a Perl test that goes on to read $1 ports
-- as `local ok, c1 = isMatch(...)`.
--
-- Without groups that is exactly lpcre.test's boolean (no captures, no
-- positions converted).  NCAPT answers the number of groups (also for the
-- /g loops below): for a literal pattern kept per pattern string (bounded
-- by the patterns in the source; the regex object comes from lpcre's cache,
-- where the match compiles it anyway), a regex object of a *Dyn call is
-- asked each time, not kept.
local NCAPT = setmetatable({}, { __index = function(t, p)
    if type(p) ~= 'string' then return p:ncapt() end
    local n = lpcreNew(p):ncapt()
    t[p] = n
    return n
end })
local function isMatchResult(st, _, ...)
    if not st then return false end
    return true, ...
end
local function doIsMatch(p, s, pos)
    if s == nil then return false end
    if type(s) ~= 'string' and s ~= nil and not isCarray(s) then s = perl.str(s) end
    if NCAPT[p] == 0 then return lpcreTest(s, p, (pos or 0) + 1) end
    return isMatchResult(lpcreFind(s, p, (pos or 0) + 1))
end

-- pat is a literal pattern from the ported source, compiled through
-- lpcre's pattern cache.
function perl.isMatch(s, pat, pos)
    return doIsMatch(pat, s, pos)
end

-- Same as perl.isMatch, but for pat built at runtime: compiles pat on every
-- call, outside the pattern cache.
function perl.isMatchDyn(s, pat, pos)
    return doIsMatch(dynamic(pat), s, pos)
end

-- The subject of a /g loop: a string or a carray as it is, anything else
-- stringified as Perl does; plus its length.
local function gSubject(s)
    if type(s) == 'string' then return s, #s end
    if isCarray(s) then return s, s:len() end
    s = perl.str(s)
    return s, #s
end

-- One match of p in s from the 1-based position pos, packed: { st, en,
-- captures..., n = 2 + number of groups } (a group that took no part is
-- nil), or nil.  The /g loops below need the count, which `#` cannot give
-- for a list with nil holes.
local function findPacked(s, p, pos)
    local ret = tpack(lpcreFind(s, p, pos))
    if not ret[1] then return nil end
    return ret
end

-- Iterate all non-overlapping matches of p in s (Perl `while ($s =~ /pat/g)
-- { ... }`, or a drop-in for Lua's own string.gmatch). Returns the captures
-- per match (or the whole match when pat has no capturing groups), never a
-- position; advances past empty matches by one byte to avoid an infinite
-- loop, like string.gmatch.
-- A group that took no part in the match is nil (Perl's undef), as with
-- perl.matches - except the first, which is yielded as false: a nil first
-- value would end the caller's for loop.  tools/verify_matchbool.lua keeps
-- literal patterns whose first group can stay unset away from eachMatch.
-- Without groups lpcre.findmatch hands over the match text itself (for a
-- carray without a separate copy of the bytes), and nothing is packed.
local function doEachMatch(p, s)
    local n
    s, n = gSubject(s)
    local pos = 1
    if NCAPT[p] == 0 then
        return function()
            if pos > n + 1 then return nil end
            local st, en, m = lpcreFindmatch(s, p, pos)
            if not st then return nil end
            pos = (en >= st) and (en + 1) or (st + 1)
            return m
        end
    end
    return function()
        if pos > n + 1 then return nil end
        local ret = findPacked(s, p, pos)
        if not ret then return nil end
        local st, en = ret[1], ret[2]
        pos = (en >= st) and (en + 1) or (st + 1)
        if ret[3] == nil then ret[3] = false end
        return tunpack(ret, 3, ret.n)
    end
end

-- pat is a literal pattern from the ported source, compiled through
-- lpcre's pattern cache.
function perl.eachMatch(s, pat)
    return doEachMatch(pat, s)
end

-- Same as perl.eachMatch, but for pat built at runtime: compiles pat once
-- per call, outside the pattern cache.
function perl.eachMatchDyn(s, pat)
    return doEachMatch(dynamic(pat), s)
end

-- Perl `my @all = $s =~ /pat/g` in list context - collects every value
-- perl.eachMatch would yield into a flat array (captures from every match,
-- or the whole match text per match when pat has no capturing groups).
--
-- A Lua array cannot hold undef, so here (as in the fields split
-- intersperses) a group that took no part in the match is false.
-- tools/verify_matchbool.lua keeps literal patterns with such groups away
-- from findAll, split and eachSplit (and from subst with a replacement
-- function).
local function doFindAll(p, s)
    local out = {}
    local n
    s, n = gSubject(s)
    local pos = 1
    local whole = NCAPT[p] == 0 -- (the match text, as in doEachMatch)
    while pos <= n + 1 do
        if whole then
            local st, en, m = lpcreFindmatch(s, p, pos)
            if not st then break end
            pos = (en >= st) and (en + 1) or (st + 1)
            out[#out + 1] = m
        else
            local ret = findPacked(s, p, pos)
            if not ret then break end
            local st, en = ret[1], ret[2]
            pos = (en >= st) and (en + 1) or (st + 1)
            for i = 3, ret.n do
                local v = ret[i]
                if v == nil then v = false end
                out[#out + 1] = v
            end
        end
    end
    return out
end

-- pat is a literal pattern from the ported source, compiled through
-- lpcre's pattern cache.
function perl.findAll(s, pat)
    return doFindAll(pat, s)
end

-- Same as perl.findAll, but for pat built at runtime: compiles pat once
-- per call, outside the pattern cache.
function perl.findAllDyn(s, pat)
    return doFindAll(dynamic(pat), s)
end

-- Translate a Perl replacement string into the one lpcre.gsub understands
-- (string.gsub's syntax).  The two syntaxes disagree twice over, and both
-- ways silently: lpcre spells a backreference `%1` (so a copied-over Perl
-- `$1` inserts those two literal characters), and lpcre gives `%` a meaning
-- Perl does not (so a literal percent sign is an error or eaten).  Keeping
-- the ported source in Perl's spelling is the whole point of this facade, so
-- the translation happens here rather than at ~650 call sites:
--
--   `%`  -> `%%`       (lpcre's escape; Perl has no metacharacter here)
--   `$1` -> `%1`       and `${1}` likewise, up to $9 - lpcre has no %10
--   `$&` -> `%0`       (the whole match)
--   `\$` -> `$`        (Perl's escape for a literal dollar sign)
--   `\\` -> `\`        (Perl's escape for a literal backslash)
--   `\+` -> `+`        (any other backslashed punctuation: the character)
--
-- Anything else keeps its `$`, as in Perl, where `$` before a non-digit is
-- just a dollar sign unless it names a variable - and a ported replacement
-- cannot name one.
local REPL_CACHE = {}
local function perlRepl(repl)
    local r = REPL_CACHE[repl]
    if r ~= nil then return r end
    -- one left-to-right pass, so that `\$1` is consumed as an escaped dollar
    -- sign before the `$1` rule can see it
    local out, i, n = {}, 1, #repl
    while i <= n do
        local c = ssub(repl, i, i)
        if c == '%' then
            out[#out + 1] = '%%'         -- lpcre's escape; a plain % in Perl
            i = i + 1
        elseif c == '\\' and ssub(repl, i + 1, i + 1) == '$' then
            out[#out + 1] = '$'          -- Perl's escape for a literal $
            i = i + 2
        elseif c == '\\' and ssub(repl, i + 1, i + 1) == '\\' then
            out[#out + 1] = '\\'         -- Perl's escape for a literal \
            i = i + 2
        elseif c == '\\' and smatch(repl, '^[^A-Za-z0-9 \t\n\r\f\v]', i + 1) then
            -- any other backslashed punctuation is the character itself in
            -- Perl's double-quotish replacement (`s/ \d+/ \\d\+/` gives " \d+")
            local p = ssub(repl, i + 1, i + 1)
            out[#out + 1] = p == '%' and '%%' or p
            i = i + 2
        elseif c == '$' then
            local d = smatch(repl, '^%$([1-9])', i)
            local w = 2
            if not d then
                d = smatch(repl, '^%${([1-9])}', i)
                w = 4
            end
            if d then
                out[#out + 1] = '%' .. d
                i = i + w
            elseif ssub(repl, i + 1, i + 1) == '&' then
                out[#out + 1] = '%0'     -- the whole match
                i = i + 2
            else
                out[#out + 1] = '$'      -- a dollar sign naming nothing
                i = i + 1
            end
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
    r = tconcat(out)
    REPL_CACHE[repl] = r
    return r
end

-- Perl `$s =~ s/pat/repl/[g]` - replaces the first match, or every match
-- when flag is 'g'. Returns the substituted string.  repl is either a Perl
-- replacement string (see perlRepl above) or a function, which lpcre calls
-- with the captures (nil for a group that took no part) - Perl's /e, where
-- the port needs real code.
-- On a carray (a mutable scalar, doc/api.md §4) lpcre substitutes in
-- place, as in Perl, and the carray itself is returned, so the call site
-- reads `buf = subst(buf, ...)` either way.
local function doSubst(p, s, repl, flag)
    if type(repl) == 'string' then
        repl = perlRepl(repl)
    elseif type(repl) == 'function' then
        -- (a number the /e code returns is inserted in its Perl string form)
        local f = repl
        repl = function(...)
            local r = f(...)
            if type(r) == 'number' then return perl.str(r) end
            return r
        end
    end
    -- (likewise a number subject, see doMatches)
    if type(s) ~= 'string' and s ~= nil and not isCarray(s) then s = perl.str(s) end
    if flag == 'g' then
        return (lpcreGsub(s, p, repl))
    end
    return (lpcreGsub(s, p, repl, 1))
end

-- pat is a literal pattern from the ported source, compiled through
-- lpcre's pattern cache.
function perl.subst(s, pat, repl, flag)
    return doSubst(pat, s, repl, flag)
end

-- Same as perl.subst, but for pat built at runtime: compiles pat on every
-- call, outside the pattern cache.
function perl.substDyn(s, pat, repl, flag)
    return doSubst(dynamic(pat), s, repl, flag)
end

-- Perl `split /pat/, s[, limit]` - pat is a regex separator; captures in pat
-- are interspersed into the result (Perl semantics). Without limit (or
-- limit == 0), trailing empty fields are stripped; a positive limit caps the
-- number of fields (the last one keeps the untouched remainder of s); a
-- negative limit behaves like no limit but keeps trailing empty fields.
local function doSplit(p, s, limit)
    local result = {}
    local pos = 1
    local count = 0
    while not (limit and limit > 0 and count >= limit - 1) do
        local ret = findPacked(s, p, pos)
        -- (a zero-width match where the field starts separates nothing:
        --  Perl looks one character further, so `split //` yields the
        --  characters and never a leading empty field)
        if ret and ret[2] < ret[1] and ret[1] == pos then
            if pos > #s then break end
            ret = findPacked(s, p, pos + 1)
        end
        if not ret then break end
        local st, en = ret[1], ret[2]
        result[#result + 1] = ssub(s, pos, st - 1)
        for i = 3, ret.n do
            local v = ret[i]
            if v == nil then v = false end
            result[#result + 1] = v
        end
        pos = (en >= st) and (en + 1) or st
        count = count + 1
    end
    result[#result + 1] = ssub(s, pos)
    if not limit or limit == 0 then
        while #result > 0 and result[#result] == '' do
            tremove(result)
        end
    end
    return result
end

-- pat is a literal pattern from the ported source,
-- compiled through lpcre's pattern cache.
-- A pattern of exactly one space is Perl's special awk mode (`split ' ',
-- $s`): split on runs of whitespace after skipping leading whitespace, so
-- "  a b" yields ('a', 'b') and not ('', 'a', 'b').
function perl.split(pat, s, limit)
    -- (Perl stringifies the operand: a number or undef splits as its string)
    if type(s) ~= 'string' then s = perl.str(s) end
    if pat == ' ' then
        return doSplit([[\s+]], (s:gsub('^[ \t\n\r\f\v]+', '')), limit)
    end
    return doSplit(pat, s, limit)
end

-- Same as perl.split, but for pat built at runtime: compiles pat on every
-- call, outside the pattern cache.
function perl.splitDyn(pat, s, limit)
    if type(s) ~= 'string' then s = perl.str(s) end
    -- (since Perl 5.18 any pattern expression that evaluates to the single
    --  space string selects the awk mode too, as in perl.split above)
    if pat == ' ' then
        return doSplit([[\s+]], (s:gsub('^[ \t\n\r\f\v]+', '')), limit)
    end
    return doSplit(dynamic(pat), s, limit)
end

-- Streaming sibling of perl.split: same semantics (capture interspersion,
-- trailing-empty-field stripping when limit is nil/0, limit/negative-limit
-- behavior identical to doSplit) but never materializes the full result
-- array, and yields plain values only (no running index - see
-- conventions.md §6). Trailing empties can only be identified in hindsight
-- (once a later non-empty value proves they weren't trailing), so they are
-- buffered in `pending` - a small, bounded buffer of only the empty values
-- seen since the last non-empty one, not the whole result.
local function doEachSplit(p, s, limit)
    local strip = not limit or limit == 0
    return coroutine.wrap(function()
        local pending = {}
        local function emit(v)
            if strip and v == '' then
                pending[#pending + 1] = v
                return
            end
            if strip and #pending > 0 then
                for i = 1, #pending do coroutine.yield(pending[i]) end
                pending = {}
            end
            coroutine.yield(v)
        end
        local pos = 1
        local count = 0
        while not (limit and limit > 0 and count >= limit - 1) do
            local ret = findPacked(s, p, pos)
            -- (a zero-width match where the field starts separates nothing:
            --  Perl looks one character further, so `split //` yields the
            --  characters and never a leading empty field)
            if ret and ret[2] < ret[1] and ret[1] == pos then
                if pos > #s then break end
                ret = findPacked(s, p, pos + 1)
            end
            if not ret then break end
            local st, en = ret[1], ret[2]
            emit(ssub(s, pos, st - 1))
            for i = 3, ret.n do
                local v = ret[i]
                if v == nil then v = false end
                emit(v)
            end
            pos = (en >= st) and (en + 1) or st
            count = count + 1
        end
        emit(ssub(s, pos))
        -- any values still in `pending` here were trailing empties (strip
        -- active) - drop them for good, mirroring doSplit's stripping loop.
    end)
end

-- pat is a literal pattern from the ported source,
-- compiled through lpcre's pattern cache.
function perl.eachSplit(pat, s, limit)
    if pat == ' ' then -- Perl's awk mode, see perl.split
        return doEachSplit([[\s+]], (s:gsub('^[ \t\n\r\f\v]+', '')), limit)
    end
    return doEachSplit(pat, s, limit)
end

-- Same as perl.eachSplit, but for pat built at runtime: compiles pat on
-- every call, outside the pattern cache.
function perl.eachSplitDyn(pat, s, limit)
    return doEachSplit(dynamic(pat), s, limit)
end

-- Perl ord() - byte value at position (1-based here, matching Perl + 1 call
-- via the 0-based facade convention; Perl's ord() has no position argument
-- but exiftool uses "ord substr($s,$i,1)").
function perl.ord(s, i)
    -- Perl's ord() of undef or of an empty string (as substr() past the end
    -- of a scalar, or a short $raf->Read() at EOF, produces) is 0, not undef
    if s == nil then return 0 end
    return sbyte(s, i or 1) or 0
end

-- Expand a tr/// search or replacement list into its byte values: backslash
-- escapes (\\ \- \n \t \r \f \b \e \a \0 \NNN \xHH, any other \c is c itself)
-- and a-z style ranges, as perlop describes them.
local TR_ESC = { n = 10, t = 9, r = 13, f = 12, b = 8, e = 27, a = 7 }
local function trList(spec)
    local chars = {}
    local i, n = 1, #spec
    local isLit = {}   -- the char came from an escape (a '\-' is no range)
    while i <= n do
        local c = ssub(spec, i, i)
        local b
        if c == '\\' and i < n then
            local e = ssub(spec, i + 1, i + 1)
            if TR_ESC[e] then
                b = TR_ESC[e]; i = i + 2
            elseif e == 'x' then
                local hex = smatch(spec, '^%x%x?', i + 2) or ''
                b = tonumber(hex, 16) or 0; i = i + 2 + #hex
            elseif smatch(e, '[0-7]') then
                local oct = smatch(spec, '^[0-7][0-7]?[0-7]?', i + 1)
                b = tonumber(oct, 8); i = i + 1 + #oct
            else
                b = sbyte(e); i = i + 2
            end
            chars[#chars + 1] = b
            isLit[#chars] = true
        else
            chars[#chars + 1] = sbyte(c)
            i = i + 1
        end
    end
    -- expand ranges ("a-z"; a leading or trailing '-' is literal)
    local out = {}
    local k = 1
    while k <= #chars do
        if chars[k + 1] == 45 and not isLit[k + 1] and chars[k + 2] and k + 2 <= #chars then
            for b = chars[k], chars[k + 2] do out[#out + 1] = b end
            k = k + 3
        else
            out[#out + 1] = chars[k]
            k = k + 1
        end
    end
    return out
end

-- Perl `$s =~ tr/SEARCH/REPLACE/cdsr` (y/// is the same operator) on a byte
-- string. search/repl are the lists as written between the delimiters;
-- flags may contain c (complement), d (delete found but unreplaced
-- characters) and s (squeeze runs translated to the same character).
-- Returns the new string and the number of characters matched (Perl's
-- return value; with /r Perl returns the string instead -- the caller picks).
-- On a carray the translation happens in place, directly on its bytes (a
-- tr never lengthens the scalar: the result is written over the bytes
-- already read, then the carray is cut to the new length), and the carray
-- itself is returned in place of the new string.
--
-- Like Perl, which compiles a tr/// once, the lists are compiled once per
-- (search, repl, flags) into trCompile's translator and kept in TR_CACHE
-- (the call sites pass literals, so the cache stays small).  A string
-- without /s is translated by one string.gsub with a character class of
-- exactly the search set and a byte -> replacement table: gsub's match
-- count is Perl's return value (every character of the search set counts,
-- deleted or mapped to itself alike).  /s and the in-place carray form keep
-- the byte loop over the same map.
local TR_CHUNK = 4096 -- bytes of a carray translated per get/set round
local TR_CACHE = {}   -- flags -> search -> repl -> translator
-- ASCII punctuation is escaped with '%' in a Lua character class (any of
-- them may be magic there); every other byte stands for itself
local function trClassChar(b)
    if (b >= 33 and b <= 47) or (b >= 58 and b <= 64) or (b >= 91 and b <= 96) or (b >= 123 and b <= 126) then
        return '%' .. schar(b)
    end
    return schar(b)
end
-- character class body for a set of bytes (the keys of `set`, whatever
-- their values -- a deleted character maps to false), runs of three or more
-- as ranges where both ends need no escape
local function trClassBody(set)
    local parts = {}
    local b = 0
    while b <= 255 do
        if set[b] ~= nil then
            local e = b
            while e < 255 and set[e + 1] ~= nil do e = e + 1 end
            if e - b >= 2 and #trClassChar(b) == 1 and #trClassChar(e) == 1 then
                parts[#parts + 1] = schar(b) .. '-' .. schar(e)
            else
                for c = b, e do parts[#parts + 1] = trClassChar(c) end
            end
            b = e + 1
        else
            b = b + 1
        end
    end
    return tconcat(parts)
end
local function trCompile(search, repl, flags)
    local complement = flags:find('c', 1, true)
    local delete = flags:find('d', 1, true)
    local squeeze = flags:find('s', 1, true)
    local from = trList(search)
    local to = trList(repl)
    local inList = {}
    for _, b in ipairs(from) do inList[b] = true end
    if complement then
        from = {}
        for b = 0, 255 do
            if not inList[b] then from[#from + 1] = b end
        end
    end
    -- an empty replacement list is the search list (unless /d)
    if #to == 0 and not delete then
        for k = 1, #from do to[k] = from[k] end
    end
    -- a short replacement list repeats its last character (unless /d)
    if not delete and #to < #from then
        local last = to[#to]
        for k = #to + 1, #from do to[k] = last end
    end
    local map = {}
    local gmap = {}
    for k, b in ipairs(from) do
        if map[b] == nil then -- (first occurrence wins)
            map[b] = to[k] or false
            gmap[schar(b)] = to[k] and schar(to[k]) or ''
        end
    end
    -- the class matches exactly the keys of map
    local class
    if #from == 0 then
        class = nil                              -- nothing can match
    elseif complement then
        local body = trClassBody(inList)
        class = body == '' and '.' or ('[^' .. body .. ']')
    else
        class = '[' .. trClassBody(map) .. ']'
    end
    return { map = map, gmap = gmap, class = class, squeeze = squeeze }
end
function perl.tr(s, search, repl, flags)
    -- (Perl stringifies the operand: `$val =~ tr/ /./` on a number)
    local inPlace = isCarray(s)
    if not inPlace and type(s) ~= 'string' then s = perl.str(s) end
    flags = flags or ''
    local byFlags = TR_CACHE[flags]
    if not byFlags then byFlags = {} TR_CACHE[flags] = byFlags end
    local bySearch = byFlags[search]
    if not bySearch then bySearch = {} byFlags[search] = bySearch end
    local tt = bySearch[repl]
    if not tt then tt = trCompile(search, repl, flags) bySearch[repl] = tt end
    if not inPlace and not tt.squeeze then
        if not tt.class then return s, 0 end
        return sgsub(s, tt.class, tt.gmap)
    end
    local map, squeeze = tt.map, tt.squeeze
    local count = 0
    local lastTo -- last character appended through a translation (for /s)
    if inPlace then
        local n = s:len()
        local w = 1 -- where the next result byte goes (never past the read position)
        for i = 1, n, TR_CHUNK do
            local vals = { s:get(i, mmin(i + TR_CHUNK - 1, n)) }
            local k = 0
            local changed = false
            for r = 1, #vals do
                local b = vals[r]
                local m = map[b]
                if m == nil then
                    k = k + 1
                    vals[k] = b
                    lastTo = nil
                else
                    count = count + 1
                    changed = true
                    if m then
                        if not (squeeze and lastTo == m) then
                            k = k + 1
                            vals[k] = m
                        end
                        lastTo = m
                    end
                end
            end
            if k > 0 and (changed or w ~= i) then s:set(w, tunpack(vals, 1, k)) end
            w = w + k
        end
        if w - 1 ~= n then s:setlen(w - 1) end
        return s, count
    end
    local out = {}
    for k = 1, #s do
        local b = sbyte(s, k)
        local m = map[b]
        if m == nil then
            out[#out + 1] = schar(b)
            lastTo = nil
        else
            count = count + 1
            if m then
                if not (squeeze and lastTo == m) then out[#out + 1] = schar(m) end
                lastTo = m
            end
        end
    end
    return tconcat(out), count
end

-- Compile a string of Perl code that edits $_ with tr///, y/// and s///
-- statements separated by ';' (the form the Filter option and the
-- advanced-formatting expressions of the exiftool documentation use, e.g.
-- 'tr/ /_/;tr/0-9/#/' or 's/\s+$//'). Returns a function that takes the
-- value of $_ and returns the new one -- or nil when the code uses anything
-- beyond this subset (the caller then treats it as an eval that failed to
-- compile, which leaves $_ untouched).
local COMPILED_CODE = {}
function perl.compileEdit(code)
    local cached = COMPILED_CODE[code]
    if cached ~= nil then return cached or nil end
    local ops = {}
    local i, n = 1, #code
    -- read one delimited part starting after the opening delimiter at i
    -- (with a bracketing delimiter -- `tr(a)(b)`, perlop "Quote and
    --  Quote-like Operators" -- `open` is the opening bracket: nested pairs
    --  of it stay part of the text, and the part ends at the matching close)
    local function part(delim, open)
        local buf = {}
        local depth = 0
        while i <= n do
            local c = ssub(code, i, i)
            if c == '\\' and i < n then
                local e = ssub(code, i + 1, i + 1)
                -- an escaped delimiter is the plain character
                buf[#buf + 1] = (e == delim or e == open) and e or (c .. e)
                i = i + 2
            elseif open and c == open then
                depth = depth + 1
                buf[#buf + 1] = c
                i = i + 1
            elseif c == delim and depth > 0 then
                depth = depth - 1
                buf[#buf + 1] = c
                i = i + 1
            elseif c == delim then
                i = i + 1
                return tconcat(buf)
            else
                buf[#buf + 1] = c
                i = i + 1
            end
        end
        return nil
    end
    local CLOSE = { ['('] = ')', ['['] = ']', ['{'] = '}', ['<'] = '>' }
    local ok = true
    while true do
        i = (smatch(code, '^[ \t\n\r\f\v;]*()', i))
        if i > n then break end
        local op = smatch(code, '^(tr)[^A-Za-z0-9_ \t\n\r\f\v]', i) or smatch(code, '^([ys])[^A-Za-z0-9_ \t\n\r\f\v]', i)
        if not op then ok = false break end
        i = i + #op
        local delim = ssub(code, i, i)
        i = i + 1
        local a, b
        if CLOSE[delim] then
            -- bracketed form: the second part has its own brackets, which
            -- may follow after whitespace (`tr(a) (b)`, `s{a}{b}`)
            a = part(CLOSE[delim], delim)
            if a then
                i = (smatch(code, '^[ \t\n\r\f\v]*()', i))
                local delim2 = ssub(code, i, i)
                if CLOSE[delim2] then
                    i = i + 1
                    b = part(CLOSE[delim2], delim2)
                end
            end
        else
            a = part(delim)
            b = a and part(delim)
        end
        if not b then ok = false break end
        local fl = smatch(code, '^[A-Za-z]*', i)
        i = i + #fl
        if op == 's' then
            if fl:find('[^gimsx]') then ok = false break end -- (no /e, /r, ...)
            -- (Perl's /imsx are lpcre's compile flag letters as well; the
            --  code comes from data, so the regex is compiled once, here,
            --  outside the pattern cache)
            local mods = fl:gsub('g', '')
            local okc, re = pcall(lpcreNew, a, mods .. 'n')
            if not okc then ok = false break end
            local global = fl:find('g', 1, true) and 'g' or nil
            ops[#ops + 1] = function(v) return perl.substDyn(v, re, b, global) end
        else
            if fl:find('[^cds]') then ok = false break end
            ops[#ops + 1] = function(v) return (perl.tr(v, a, b, fl)) end
        end
    end
    local fn
    if ok then
        fn = function(v)
            for k = 1, #ops do v = ops[k](v) end
            return v
        end
    end
    COMPILED_CODE[code] = fn or false
    return fn
end

-- Perl chr() - single byte from a code.  Perl numifies the argument (a
-- string of digits, a float is truncated); a code above 255 is a wide
-- character in Perl, which this byte-string port represents by its UTF-8
-- encoding (what Perl itself prints for it).
function perl.chr(n)
    n = perl.int(perl.num(n))
    if n > 255 then return utf8.char(n) end
    if n < 0 then n = 0xfffd return utf8.char(n) end
    return schar(n)
end

-- The 64-bit pattern Perl's integer conversions (%d %i %u %o %x %X %b %B %c)
-- format for a number: an IV as is; an NV truncated toward zero, clamped the
-- way Perl casts it (beyond the UV range: all bits set; in the upper half of
-- the UV range: that UV, i.e. negative as a Lua integer; below the IV range:
-- IV_MIN), and a UV object (perl.uv) its bits. perl: printf '%d|%d|%d', 1e20,
-- 1e19, -1e20 gives -1|-8446744073709551616|-9223372036854775808.
local TWO63 = 2.0^63
local TWO64 = 2.0^64
local UV = {} -- the metatable of Perl UVs (perl.uv, below)
local function toIV(n)
    if mtype(n) == 'integer' then return n end
    if getmetatable(n) == UV then return n.iv end
    if n >= TWO64 then return -1 end
    if n >= TWO63 then return mtointeger(n - TWO64) end
    if n < -TWO63 then return math.mininteger end
    if n >= 0 then return mtointeger(mfloor(n)) end
    return mtointeger(-mfloor(-n))
end

-- Decimal digits of a 64-bit pattern read as unsigned (Perl's UV), which
-- Lua's %d cannot print for values with the top bit set.
local function udec(iv)
    if iv >= 0 then return sformat('%d', iv) end
    local q = (iv >> 1) // 5            -- the unsigned value divided by 10
    return sformat('%d%d', q, iv - q * 10)
end

-- Perl UVs: unsigned integers from 2^63 to 2^64-1.
--
-- Perl keeps an integer as a signed IV or, when it does not fit, as an
-- unsigned UV, and its integer arithmetic stays exact as long as the result
-- fits either one: `$hi * 4294967296 + $lo` (Get64u) is exact up to 2^64-1,
-- printing 13830554455654793216 where a Lua integer has wrapped to
-- -4616189618054758400. A Lua integer already carries the right 64 bits, it
-- only lacks Perl's "unsigned" flag, and a negative integer alone cannot say
-- whether it was meant as an IV or a UV. perl.uv() supplies that flag at the
-- place where upstream's arithmetic produces a UV: it takes the (wrapped) Lua
-- integer and returns it unchanged when it is below 2^63, otherwise a UV
-- object holding the bit pattern. A UV object behaves like Perl's UV:
--   * it stringifies exactly (perl.str, tostring, `..`, sprintf %s/%u; %d
--     and %x see the bit pattern, as in Perl);
--   * comparisons (< <= > >=) with any number are exact the way Perl's are:
--     integer against integer (IV, UV or an integral NV inside the IV/UV
--     range), otherwise as doubles;
--   * + - * % // and unary minus give an exact IV/UV while the result fits
--     and a double (NV) once it does not; / is exact for an exact integer
--     quotient of a dividend above 2^53 (Perl's PERL_TRY_UV_DIVIDE) and a
--     double otherwise; ^ is a double;
--   * & | ~ << >> and the unary ~ work on the 64 bits and return a UV again.
-- The objects are interned (one per value), so == between two UVs, rawequal
-- and their use as table keys work too. A UV object is a Lua table: `type()`
-- says 'table', and `.ref` is '' (Perl's ref() of a number), so the port's
-- reference tests (`type(v) == 'table' and v.ref == nil` for an ARRAY ref,
-- `v.ref == 'SCALAR'`) do not take it for one. What does not work, by Lua's
-- rules: `==` against a plain number (always false; no UV equals an IV, and
-- an NV equal to one is a rounding coincidence), tonumber()/math.* and a raw
-- string.format('%d'). See doc/conventions.md §3b.
local UV_CACHE = setmetatable({}, { __mode = 'v' })

local function newUV(iv)
    local u = UV_CACHE[iv]
    if not u then
        u = setmetatable({ iv = iv, ref = '' }, UV)
        UV_CACHE[iv] = u
    end
    return u
end

-- Mark the result of an integer expression as Perl's UV: a Lua integer
-- below 2^63 (or any other value) is returned as it is, a negative integer
-- -- the wrapped bit pattern of a value from 2^63 to 2^64-1 -- becomes a UV
-- object. Use it only where the true result is known to lie in 0..2^64-1,
-- as for upstream's `$hi * 4294967296 + $lo` with two unsigned 32-bit words.
function perl.uv(n)
    if mtype(n) == 'integer' and n < 0 then return newUV(n) end
    return n
end

-- Is the value a UV object (perl.uv)?
function perl.isUV(v)
    return getmetatable(v) == UV
end

local INT_MIN = math.mininteger
local TWO53 = 0x20000000000000
local ult = math.ult

-- Unsigned floor division of two 64-bit patterns (b ~= 0), the recipe from
-- the Lua manual.
local function udiv(a, b)
    if b < 0 then return ult(a, b) and 0 or 1 end
    local q = ((a >> 1) // b) << 1
    local r = a - q * b
    if not ult(r, b) then q = q + 1 end
    return q
end

-- The double nearest to a 64-bit pattern read as unsigned, rounded once like
-- Perl's (NV) cast of a UV.
local function unv(iv)
    if iv >= 0 then return iv + 0.0 end
    return ((iv >> 1) | (iv & 1)) * 2.0
end

-- A Perl value as a double (NV).
local function nv(x)
    if getmetatable(x) == UV then return unv(x.iv) end
    if type(x) == 'number' then return x + 0.0 end
    if x == nil then return 0.0 end
    return perl.num(x) + 0.0
end

-- Sign and magnitude (a 64-bit pattern read as unsigned) of a value taking
-- part in Perl's integer arithmetic -- an IV, a UV or an integral NV inside
-- the IV/UV range (Perl's SvIV_please) -- or nil for any other value.
local function uvParts(x)
    if getmetatable(x) == UV then return false, x.iv end
    if type(x) ~= 'number' then
        if x == nil then return false, 0 end
        x = perl.num(x)
    end
    if mtype(x) == 'integer' then
        if x < 0 then return true, -x end
        return false, x
    end
    if x ~= x or x < -TWO63 or x >= TWO64 or x % 1 ~= 0 then return nil end
    if x >= TWO63 then return false, mtointeger(x - TWO64) end
    if x >= 0 then return false, mtointeger(x) end
    if x == -TWO63 then return true, INT_MIN end
    return true, mtointeger(-x)
end

-- The Perl value with the given sign and magnitude: an IV, a UV, or an NV
-- when a negative value is below the IV range.
local function fromParts(neg, mag)
    if not neg then
        if mag >= 0 then return mag end
        return newUV(mag)
    end
    if mag >= 0 or mag == INT_MIN then return -mag end
    return -unv(mag)
end

-- Perl `$a + $b` (flip: `$a - $b`)
local function add(a, b, flip)
    local na, ma = uvParts(a)
    local nb, mb = uvParts(b)
    if ma and mb then
        if flip then nb = not nb end
        if na == nb then
            local sum = ma + mb
            if not ult(sum, ma) then return fromParts(na, sum) end
        elseif not ult(ma, mb) then
            return fromParts(na, ma - mb)
        else
            return fromParts(nb, mb - ma)
        end
    end
    if flip then return nv(a) - nv(b) end
    return nv(a) + nv(b)
end

-- Perl's numeric comparison: -1, 0, 1, or nil for NaN.
local function cmp(a, b)
    local na, ma = uvParts(a)
    local nb, mb = uvParts(b)
    if ma and mb then
        if na ~= nb then
            if ma == 0 and mb == 0 then return 0 end
            return na and -1 or 1
        end
        if ma == mb then return 0 end
        local less = ult(ma, mb)
        if na then less = not less end
        return less and -1 or 1
    end
    local x, y = nv(a), nv(b)
    if x < y then return -1 end
    if x > y then return 1 end
    if x == y then return 0 end
    return nil
end

-- The 64 bits a Perl bit operation works on.
local function uvBits(x)
    if getmetatable(x) == UV then return x.iv end
    if type(x) ~= 'number' then
        if x == nil then return 0 end
        x = perl.num(x)
    end
    return toIV(x)
end

UV.__name = 'UV'
UV.__tostring = function(a) return udec(a.iv) end
UV.__concat = function(a, b)
    return (getmetatable(a) == UV and udec(a.iv) or perl.str(a)) ..
           (getmetatable(b) == UV and udec(b.iv) or perl.str(b))
end
UV.__eq = function(a, b)
    return getmetatable(a) == UV and getmetatable(b) == UV and a.iv == b.iv
end
UV.__lt = function(a, b) return cmp(a, b) == -1 end
UV.__le = function(a, b)
    local c = cmp(a, b)
    return c == -1 or c == 0
end
UV.__add = function(a, b) return add(a, b) end
UV.__sub = function(a, b) return add(a, b, true) end
UV.__unm = function(a) return fromParts(true, a.iv) end
UV.__mul = function(a, b)
    local na, ma = uvParts(a)
    local nb, mb = uvParts(b)
    if ma and mb then
        if ma == 0 or mb == 0 then return 0 end
        if not ult(udiv(-1, ma), mb) then return fromParts(na ~= nb, ma * mb) end
    end
    return nv(a) * nv(b)
end
UV.__div = function(a, b)
    local na, ma = uvParts(a)
    local nb, mb = uvParts(b)
    if ma and mb and mb ~= 0 and not ult(ma, mb) and ult(TWO53, ma) then
        local q = udiv(ma, mb)
        if q * mb == ma then return fromParts(na ~= nb, q) end
    end
    return nv(a) / nv(b)
end
UV.__mod = function(a, b)
    local na, ma = uvParts(a)
    local nb, mb = uvParts(b)
    if ma and mb and mb ~= 0 then
        -- (the result takes the sign of the right operand, as in Perl)
        local r = ma - udiv(ma, mb) * mb
        if na ~= nb and r ~= 0 then r = mb - r end
        return fromParts(nb, r)
    end
    return nv(a) % nv(b)
end
UV.__idiv = function(a, b)
    local na, ma = uvParts(a)
    local nb, mb = uvParts(b)
    if ma and mb and mb ~= 0 then
        local q = udiv(ma, mb)
        if na ~= nb and q * mb ~= ma then q = q + 1 end
        return fromParts(na ~= nb, q)
    end
    return nv(a) // nv(b)
end
UV.__pow = function(a, b) return nv(a) ^ nv(b) end
UV.__band = function(a, b) return perl.uv(uvBits(a) & uvBits(b)) end
UV.__bor = function(a, b) return perl.uv(uvBits(a) | uvBits(b)) end
UV.__bxor = function(a, b) return perl.uv(uvBits(a) ~ uvBits(b)) end
UV.__shl = function(a, b) return perl.uv(uvBits(a) << uvBits(b)) end
UV.__shr = function(a, b) return perl.uv(uvBits(a) >> uvBits(b)) end
UV.__bnot = function(a) return perl.uv(~uvBits(a)) end

local INF = math.huge

-- Perl's `use warnings` for numification.  Upstream runs with warnings on,
-- and a conversion that numifies a non-numeric string -- "undef" from a
-- rational with a zero denominator, "2.971 1" from a two-value field --
-- warns; GetValue and friends catch that through $SIG{'__WARN__'} and show
-- it as "Warning = ValueConv Tag: Argument "undef" isn't numeric in
-- division (/)".  The operator names below are Perl's own (perldiag, op.c),
-- keyed by the Perl operator spelling a call site passes to perl.num.
local NUM_OPS = {
    ['+'] = 'addition (+)',          ['-'] = 'subtraction (-)',
    ['*'] = 'multiplication (*)',    ['/'] = 'division (/)',
    ['%'] = 'modulus (%)',           ['**'] = 'exponentiation (**)',
    ['neg'] = 'negation (-)',
    ['=='] = 'numeric eq (==)',      ['!='] = 'numeric ne (!=)',
    ['<'] = 'numeric lt (<)',        ['>'] = 'numeric gt (>)',
    ['<='] = 'numeric le (<=)',      ['>='] = 'numeric ge (>=)',
    ['<=>'] = 'numeric comparison (<=>)',
    ['&'] = 'bitwise and (&)',       ['|'] = 'bitwise or (|)',
    ['^'] = 'bitwise xor (^)',       ['<<'] = 'left bitshift (<<)',
    ['>>'] = 'right bitshift (>>)',
    -- (named builtins report their name: int, abs, sqrt, log, exp, sprintf)
}

-- Perl's looks_like_number for a string: optional surrounding whitespace,
-- a sign, digits with an optional fraction (or a bare fraction) and
-- exponent, or Inf/Infinity/NaN in any case; "0 but true" is exempt.
local function looksLikeNumber(s)
    local body = smatch(s, '^[ \t\n\r\f\v]*[-+]?(.-)[ \t\n\r\f\v]*$')
    local mant, rest = smatch(body, '^(%d*%.?%d*)(.*)$')
    if sfind(mant, '%d') then
        return rest == '' or smatch(rest, '^[eE][-+]?%d+$') ~= nil
    end
    local w = asciiLower(body)
    return w == 'inf' or w == 'infinity' or w == 'nan' or s == '0 but true'
end

-- The argument as Perl's not_a_number() shows it: control characters as
-- \n \r \f \\ \0 or ^X, a byte >= 0x80 as "M-" plus its 7-bit form (the C
-- locale, where no high byte is printable -- the harness runs with
-- LC_ALL=C), cut with "..." once 56 characters are written.
local function notANumberDisplay(s)
    local out, n, i, len = {}, 0, 1, #s
    while i <= len and n < 56 do
        local c = sbyte(s, i)
        local piece = ''
        if c >= 0x80 then
            piece = 'M-'
            c = c & 0x7f
        end
        if c == 10 then piece = piece .. '\\n'
        elseif c == 13 then piece = piece .. '\\r'
        elseif c == 12 then piece = piece .. '\\f'
        elseif c == 92 then piece = piece .. '\\\\'
        elseif c == 0 then piece = piece .. '\\0'
        elseif c >= 32 and c < 127 then piece = piece .. schar(c)
        else piece = piece .. '^' .. schar(c ~ 64)
        end
        out[#out + 1] = piece
        n = n + #piece
        i = i + 1
    end
    if i <= len then out[#out + 1] = '...' end
    return table.concat(out)
end

-- warn like Perl does when string s is numified by operator op
local function warnNotNumeric(s, op)
    if not looksLikeNumber(s) then
        perl.warn('Argument "' .. notANumberDisplay(s) .. "\" isn't numeric in " ..
                  (NUM_OPS[op] or op))
    end
end
perl.warnNotNumeric = warnNotNumeric

-- Numeric value of a string the way Perl's numification reads it: the
-- leading decimal number ("12abc" is 12, " 12" is 12, "1e3" is 1000),
-- "Inf"/"Infinity"/"NaN" (any case, optionally signed) as the special
-- values, and anything else 0 -- a hex string is *not* a number ("0x1A" is
-- 0; Lua's tonumber() accepts hex, so it is only trusted for strings without
-- an 'x').
local function numStr(v)
    local n = tonumber(v)
    if n and not sfind(v, '[xX]') then return n end
    local sign, rest = smatch(v, '^[ \t\n\r\f\v]*([-+]?)(.*)')
    local lr = asciiLower(ssub(rest, 1, 3))
    if lr == 'inf' then return sign == '-' and -INF or INF end
    if lr == 'nan' then return 0 / 0 end
    local num = smatch(rest, '^%d*%.?%d*[eE][-+]?%d+') or smatch(rest, '^%d*%.?%d*')
    n = tonumber(num)
    if not n then return 0 end
    return sign == '-' and -n or n
end

-- Perl scalar numification (what `$s + 0` does): a string contributes its
-- leading numeric prefix (numStr), and anything else is 0 -- never nil, so
-- arithmetic on a non-numeric value yields a number instead of raising, as
-- in Perl.  `op` is the Perl operator the numification stands for ('/' for
-- `$val / 2`, '+', '*', '<', 'int', ... see NUM_OPS): with it, a string
-- that is not a number warns as under Perl's `use warnings` ("Argument
-- "undef" isn't numeric in division (/)"), through perl.warn and so through
-- a $SIG{'__WARN__'} handler.  Without `op` no warning is issued (the call
-- site numifies where the Perl line has no operator of its own).  undef
-- numifies silently: Perl's "Use of uninitialized value $name" names the
-- variable, which only the call site knows.
function perl.num(v, op)
    local t = type(v)
    if t == 'number' then return v end
    if t == 'string' then
        if op then warnNotNumeric(v, op) end
        return numStr(v)
    end
    if getmetatable(v) == UV then return v end
    if v == true then return 1 end
    if t == 'userdata' and isCarray(v) then
        v = v:tostring()
        if op then warnNotNumeric(v, op) end
        return numStr(v)
    end
    return 0
end

-- Perl int() - the integer part of a number, truncated toward zero (not
-- floored: int(-39.8) is -39); the argument is numified like Perl does
-- (and warns "isn't numeric in int" like it).
function perl.int(v)
    local n = perl.num(v, 'int')
    if getmetatable(n) == UV then return n end
    if n >= 0 then return math.floor(n) end
    return math.ceil(n)
end

-- Perl scalar stringification (what `"$v"` does): undef is '', an IV prints
-- exactly, an NV with %.15g ($Config{nvgformat} on standard 64-bit builds;
-- Lua's tostring() would add '.0' to integral floats and use 14 digits), and
-- the special values as Perl spells them: 'Inf', '-Inf', 'NaN', and -0.0 as
-- '0'. Booleans (a Lua-side stand-in for Perl's 1/'' results) print as Perl's
-- true/false values.
local function perlStr(v)
    local t = type(v)
    if t == 'string' then return v end
    if t == 'number' then
        if mtype(v) == 'integer' then return sformat('%d', v) end
        if v ~= v then return 'NaN' end
        if v == INF then return 'Inf' end
        if v == -INF then return '-Inf' end
        if v == 0 then return '0' end
        if DECPT == '.' then return sformat('%.15g', v) end
        return fixDec(sformat('%.15g', v))
    end
    if v == nil or v == false then return '' end
    if v == true then return '1' end
    if isCarray(v) then return v:tostring() end -- (a mutable scalar's bytes)
    -- a scalar reference (`{ ref = 'SCALAR', value = ... }`) in its Perl string
    -- form, "SCALAR(0x55d0c8a3b2c8)" -- the address is the Lua table's
    if t == 'table' and getmetatable(v) == nil and rawget(v, 'ref') == 'SCALAR' then
        local addr = smatch(tostring(v), '(%x+)$') or '0'
        return 'SCALAR(0x' .. asciiLower(smatch(addr, '^0*(.-.)$')) .. ')'
    end
    return tostring(v)
end
perl.str = perlStr

-- Perl lc() - lower-case the stringified value (undef is '').
function perl.lc(s)
    return asciiLower(perlStr(s))
end

-- Perl uc() - upper-case the stringified value.
function perl.uc(s)
    return asciiUpper(perlStr(s))
end

-- Perl ucfirst()/lcfirst() - change the case of the first character only.
function perl.ucfirst(s)
    s = perlStr(s)
    return asciiUpper(ssub(s, 1, 1)) .. ssub(s, 2)
end

function perl.lcfirst(s)
    s = perlStr(s)
    return asciiLower(ssub(s, 1, 1)) .. ssub(s, 2)
end

-- Perl quotemeta(): backslash every character that is not a word character
-- (ASCII letters, digits, underscore), so the result matches literally in a
-- regex (`\Q...\E`).  Bytes >= 0x80 are escaped too, as Perl does for a
-- byte string. (The class is spelled out: Lua's %w follows LC_CTYPE.)
function perl.quotemeta(s)
    s = perlStr(s)
    return (sgsub(s, '[^A-Za-z0-9_]', '\\%0'))
end

-- Perl chomp: remove one trailing record separator rs (Perl's `$/`, default
-- "\n") from s.  Returns the chomped string and the number of characters
-- removed (Perl's return value); a Lua string is a value, so the caller
-- assigns it back (`buff = chomp(buff, rs)`).
function perl.chomp(s, rs)
    rs = rs or '\n'
    if s == nil then return nil, 0 end
    s = perlStr(s)
    local n = #rs
    if n > 0 and #s >= n and s:sub(-n) == rs then
        return s:sub(1, -n - 1), n
    end
    return s, 0
end

-- (port: output into buffers, for an embedding host -- doc/capi.md)
-- Perl's STDOUT and STDERR are the process's.  A host that runs the script
-- in-process (main.lua's `session`) takes each command's output as values
-- instead: perl.redirect(fh, buf) makes every write to the handle fh append
-- its bytes to the Lua table buf (the host table.concat's it), and
-- perl.redirect(fh, nil) ends that.  "Every write" is perl.print,
-- perl.printf and perl.warn, which look at the switch themselves, and also
-- a direct fh:write() -- the verbose output of the modules that still write
-- to their TextOut handle that way: the first call replaces the `write`
-- method of the Lua file handles of this Lua state by one that consults the
-- switch first.  The bytes are kept as they are (binary output, -b).  Until
-- the first call none of this exists, so the command-line tool writes to
-- its handles exactly as before.
local REDIRECT = setmetatable({}, { __mode = 'k' })
local redirectHooked = false

-- the arguments of a file:write() into a buffer, converted as file:write does
local function bufferWrite(buf, ...)
    for i = 1, select('#', ...) do
        local v = select(i, ...)
        if type(v) == 'number' then
            if mtype(v) == 'integer' then
                v = tostring(v)
            else
                v = sformat('%.14g', v)
                if DECPT ~= '.' then v = fixDec(v) end
            end
        elseif type(v) ~= 'string' then
            error("bad argument #" .. i .. " to 'write' (string expected, got " .. type(v) .. ")", 3)
        end
        buf[#buf + 1] = v
    end
end

function perl.redirect(fh, buf)
    if not redirectHooked then
        redirectHooked = true
        local methods = getmetatable(io.stdout).__index
        local realWrite = methods.write
        methods.write = function(f, ...)
            local b = REDIRECT[f]
            if b == nil then return realWrite(f, ...) end
            bufferWrite(b, ...)
            return f
        end
    end
    REDIRECT[fh] = buf
end

-- Perl %SIG.  $SIG{'__WARN__'}: a caller that upstream wraps in
-- `local $SIG{'__WARN__'} = \&SetWarning` sets perl.SIG.__WARN__ for the
-- duration of the call (and puts the old value back), so a warn() deep inside
-- a conversion reaches it.  Any other key is a real signal ($SIG{INT} =
-- \&handler, 'IGNORE', 'DEFAULT' or undef): assigning it installs the
-- handler through lexiftool.sys.signal, which runs it -- with the signal name
-- as argument, as Perl does -- at the next safe point between two Lua
-- instructions (Perl's "safe signals").  A name this platform has no signal
-- for is stored but installs nothing (Perl: "No such signal" under -w only).
local sigStore = {}
perl.SIG = setmetatable({}, {
    __index = sigStore,
    __newindex = function(_, name, handler)
        sigStore[name] = handler
        if name ~= '__WARN__' and name ~= '__DIE__' then
            sys.signal(name, handler)
        end
    end,
})

-- Perl warn(): the arguments joined; a message without a trailing newline gets
-- Perl's " at (eval) line 1." tail (which CleanWarning strips again).  Calls
-- the __WARN__ handler if one is set, prints to stderr otherwise.  Returns 1
-- like Perl, so `warn(...) and return undef` reads the same.
function perl.warn(...)
    local args = { ... }
    for i = 1, #args do args[i] = perl.str(args[i]) end
    local msg = table.concat(args)
    if msg == '' then msg = "Warning: something's wrong" end
    if msg:sub(-1) ~= '\n' then msg = msg .. ' at (eval) line 1.\n' end
    local handler = perl.SIG.__WARN__
    if handler then
        handler(msg)
    else
        local buf = REDIRECT[io.stderr]     -- (perl.redirect)
        if buf then buf[#buf + 1] = msg else io.stderr:write(msg) end
    end
    return 1
end

-- Perl die(): raised as a tagged error object, so the code standing in for
-- upstream's `eval` of a conversion string (GetValue) can catch exactly a
-- Perl-level die and leave the value undefined, while a genuine Lua error (a
-- port bug) still propagates. The message is Perl's, including the
-- " at (eval) line 1." tail that CleanWarning strips.
local PerlDie = {}
PerlDie.__tostring = function(e) return e.msg end
function perl.die(msg)
    error(setmetatable({ msg = msg }, PerlDie), 0)
end

-- true if a caught error is a perl.die (and not a Lua error)
function perl.isDie(e)
    return getmetatable(e) == PerlDie
end

-- true if a caught error is perl.eval's "Perl syntax unsupported in
-- lexiftool" -- valid Perl outside the subset perl.eval interprets, which a
-- caller reports loudly rather than as an ordinary failed eval
function perl.isUnsupported(e)
    return getmetatable(e) == PerlDie and e.unsupported ~= nil
end

-- Perl log(): natural logarithm; like Perl it dies for 0 and negative
-- numbers ("Can't take log of 0") instead of returning -inf/nan.
function perl.log(x)
    local n = perl.num(x, 'log')
    if n <= 0 then perl.die("Can't take log of " .. perl.str(n) .. ' at (eval) line 1.\n') end
    return math.log(n)
end

-- Perl hex() - the number a hex string stands for: an optional leading "0x"
-- or "x", underscores between digits ignored, conversion stopping at the
-- first non-hex character; '' and undef are 0.
function perl.hex(s)
    local h = perlStr(s):gsub('^0?[xX]', '', 1)
    h = h:match('^[%x_]*'):gsub('_', '')
    return tonumber(h, 16) or 0
end

-- Perl oct(): interprets a string as octal, or as hex with a leading "0x"/
-- "x", or as binary with a leading "0b"/"b" (leading whitespace and
-- underscores ignored; stops at the first invalid digit).
function perl.oct(s)
    s = perlStr(s):gsub('^[ \t\n\r\f\v]+', '')
    if smatch(s, '^0?[xX]') then return perl.hex(s) end
    local b = smatch(s, '^0?[bB]([01_]*)')
    if b then return tonumber((b:gsub('_', '')), 2) or 0 end
    local o = smatch(s, '^[0-7_]*'):gsub('_', '')
    return tonumber(o, 8) or 0
end

-- Perl numification of a scalar for sprintf's numeric conversions: undef is
-- 0, a string reads as perl.num reads it and warns like Perl's sprintf
-- ("Argument "x" isn't numeric in sprintf").
local function numify(v)
    local t = type(v)
    if t == 'number' then return v end
    return perl.num(v, 'sprintf')
end

-- Binary digits of a 64-bit pattern read as unsigned (%b/%B).
local function bdigits(iv)
    if iv == 0 then return '0' end
    local d = {}
    while iv ~= 0 do
        d[#d + 1] = (iv & 1 == 1) and '1' or '0'
        iv = iv >> 1
    end
    return string.reverse(tconcat(d))
end

-- Pad a formatted field to the given width: left-justified with spaces
-- ('-'), zero-filled after `keep` leading characters (a sign or radix
-- prefix, '0'), or right-justified with spaces.
local function padField(s, width, left, zero, keep)
    local n = width - #s
    if n <= 0 then return s end
    if left then return s .. srep(' ', n) end
    if zero then
        keep = keep or 0
        return ssub(s, 1, keep) .. srep('0', n) .. ssub(s, keep + 1)
    end
    return srep(' ', n) .. s
end

-- Perl's spelling of an infinite/NaN value in any numeric conversion: 'Inf',
-- '-Inf', 'NaN' (never C's 'inf'/'-nan'); '+' or ' ' turn +Inf into '+Inf'
-- (NaN never gets a sign), precision is ignored and the '0' flag pads in
-- front of the sign. perl: printf '%06d|%+g|% f|%.2f', -Inf, Inf, Inf, Inf
-- gives 00-Inf|+Inf|+Inf|Inf.
local function infNan(n, d)
    local s
    if n ~= n then
        s = 'NaN'
    elseif n > 0 then
        s = (d.plus or d.space) and '+Inf' or 'Inf'
    else
        s = '-Inf'
    end
    return padField(s, d.width, d.left, d.zero, 0)
end

-- One integer conversion (d i u o x X b B) of a 64-bit pattern, C-style:
-- precision is the minimum digit count (and suppresses the '0' flag), '#'
-- adds the radix prefix, '+'/' ' only apply to the signed conversions.
local function fmtInt(d, iv, plus, space, width, prec)
    local conv = d.conv
    if d.size == 'h' then
        iv = iv & 0xFFFF
        if (conv == 'd' or conv == 'i') and iv >= 0x8000 then iv = iv - 0x10000 end
    elseif d.size == 'hh' then
        iv = iv & 0xFF
        if (conv == 'd' or conv == 'i') and iv >= 0x80 then iv = iv - 0x100 end
    end
    local prefix, digits = ''
    if conv == 'd' or conv == 'i' then
        if iv < 0 then
            prefix = '-'
            digits = ssub(sformat('%d', iv), 2)
        else
            prefix = plus and '+' or space and ' ' or ''
            digits = sformat('%d', iv)
        end
    elseif conv == 'u' then
        digits = udec(iv)
    elseif conv == 'x' or conv == 'X' then
        digits = sformat(conv == 'x' and '%x' or '%X', iv)
        if d.alt and iv ~= 0 then prefix = conv == 'x' and '0x' or '0X' end
    elseif conv == 'o' then
        digits = sformat('%o', iv)
    else -- b, B
        digits = bdigits(iv)
        if d.alt and iv ~= 0 then prefix = conv == 'b' and '0b' or '0B' end
    end
    if prec then
        if prec == 0 and iv == 0 then
            digits = ''
        elseif #digits < prec then
            digits = srep('0', prec - #digits) .. digits
        end
    end
    if conv == 'o' and d.alt and ssub(digits, 1, 1) ~= '0' then
        digits = '0' .. digits
    end
    return padField(prefix .. digits, width, d.left, d.zero and not prec, #prefix)
end

-- Parse a Perl sprintf format into a plan (cached per format string). The
-- grammar follows perldoc -f sprintf:
--   %[N$][flags][vector][width][.precision][size]conversion
-- with flags from "-+ #0", vector "v", "*v" or "*N$v", width/precision as
-- digits, "*" or "*N$", size one of hh h ll l q L V z t j. A directive that
-- does not parse is copied to the output verbatim, as Perl does ("%y" stays
-- "%y"). `plan.kinds`, when present, says the format is also a valid Lua
-- format with identical semantics as long as every argument has the listed
-- kind (see perl.sprintf).
local SPRINTF_CACHE = {}
local FAST_KIND = {
    d = 'int', i = 'int', x = 'int', X = 'int', o = 'int',
    c = 'chr',
    e = 'flt', E = 'flt', f = 'flt', g = 'flt', G = 'flt', a = 'flt', A = 'flt',
    s = 'str',
}
local SYNONYM = { D = 'd', U = 'u', O = 'o', F = 'F' }
local INT_CONV = { d = true, i = true, u = true, o = true, x = true, X = true, b = true, B = true }
local FLT_CONV = { e = true, E = true, f = true, F = true, g = true, G = true, a = true, A = true }
local SIZES = { hh = true, h = true, ll = true, l = true, q = true, L = true,
                V = true, z = true, t = true, j = true }

-- Parse "N$" at position p: the index and the position after it, or nil.
local function argIndex(fmt, p)
    local n, q = smatch(fmt, '^([1-9]%d*)%$()', p)
    if n then return tonumber(n), q end
end

-- Parse a width/precision field at p: digits, '*' or '*N$'. Returns the
-- value (number, '*' or {index}) and the position after it.
local function starOrNum(fmt, p)
    if ssub(fmt, p, p) == '*' then
        local idx, q = argIndex(fmt, p + 1)
        if idx then return { idx }, q end
        return '*', p + 1
    end
    local n, q = smatch(fmt, '^(%d+)()', p)
    if n then return tonumber(n), q end
    return nil, p
end

-- The general (slow) path, defined below.
local sprintfSlow

-- Argument checks of the fast path, by kind: the argument values for which
-- Lua's string.format prints exactly what Perl's sprintf does.
local FAST_CHECK = {
    int = 'mtype(%s) == "integer"',
    any = '(type(%s) == "string" or mtype(%s) == "integer")',
    str = '(mtype(%s) == "integer" or type(%s) == "string" and not sfind(%s, "\\0", 1, true))',
    flt = '(type(%s) == "number" and %s == %s and %s ~= INF and %s ~= -INF)',
    chr = '(mtype(%s) == "integer" and %s >= 0 and %s <= 255)',
}

-- Build the function perl.sprintf calls for one parsed format. Without
-- `kinds` (the format is not a Lua format with Perl semantics) it always
-- takes the slow path; otherwise it is generated code that checks each
-- argument against its kind and hands the call to string.format when all
-- pass -- inline checks instead of a loop over select(), which made the fast
-- path cost twice a raw string.format. A fast format consumes exactly one
-- argument per directive, so surplus arguments (which Perl ignores) are
-- dropped here. While the decimal point is not '.' (see DECPT) a format with
-- a float conversion formats directive by directive instead, each float
-- through fixDec (the format's literal text and %s arguments may contain
-- the same character, so the whole result cannot be repaired);
-- perl.localeRefresh drops the cached runners when DECPT changes, so with
-- '.' the fast path stays the single string.format call.
local function makeRunner(plan, kinds)
    local nk = kinds and #kinds
    if not kinds or nk > 100 then
        return function(_, ...) return sprintfSlow(plan, ...) end
    end
    if nk == 0 then
        return function(fmt) return sformat(fmt) end
    end
    local params, conds = {}, {}
    local hasFlt = false
    for k = 1, nk do
        local a = 'a' .. k
        params[k] = a
        conds[k] = (FAST_CHECK[kinds[k]]:gsub('%%s', a))
        if kinds[k] == 'flt' then hasFlt = true end
    end
    local list = tconcat(params, ', ')
    local result = 'sformat(fmt, ' .. list .. ')'
    if hasFlt and DECPT ~= '.' then
        local items = plan.items
        if #items > 120 then
            return function(_, ...) return sprintfSlow(plan, ...) end
        end
        local parts, k = {}, 0
        for i = 1, #items do
            local d = items[i]
            if type(d) == 'string' then
                parts[#parts + 1] = sformat('%q', d)
            elseif d.conv == '%' then
                parts[#parts + 1] = "'%'"
            else
                k = k + 1
                local one = 'sformat(' .. sformat('%q', d.spec) .. ', a' .. k .. ')'
                parts[#parts + 1] = kinds[k] == 'flt' and 'fixDec(' .. one .. ')' or one
            end
        end
        result = tconcat(parts, ' .. ')
    end
    local code = 'local sformat, slow, plan, mtype, type, sfind, INF, fixDec = ...\n' ..
        'return function(fmt, ' .. list .. ')\n' ..
        '    if ' .. tconcat(conds, ' and ') .. ' then\n' ..
        '        return ' .. result .. '\n' ..
        '    end\n' ..
        '    return slow(plan, ' .. list .. ')\n' ..
        'end\n'
    return load(code, "=perl.sprintf", "t")(sformat, sprintfSlow,
                                           plan, mtype, type, sfind, INF, fixDec)
end

local function parseSprintf(fmt)
    local items, kinds, fast = {}, {}, true
    local pos, len = 1, #fmt
    while pos <= len do
        local pct = sfind(fmt, '%', pos, true)
        if not pct then
            items[#items + 1] = ssub(fmt, pos)
            break
        end
        if pct > pos then items[#items + 1] = ssub(fmt, pos, pct - 1) end
        local d = {}
        local p = pct + 1
        local idx, q = argIndex(fmt, p)
        if idx then d.index, p = idx, q end
        local flags = smatch(fmt, '^[-+ #0]*', p)
        p = p + #flags
        d.left = sfind(flags, '-', 1, true) ~= nil
        d.plus = sfind(flags, '+', 1, true) ~= nil
        d.space = sfind(flags, ' ', 1, true) ~= nil
        d.alt = sfind(flags, '#', 1, true) ~= nil
        d.zero = sfind(flags, '0', 1, true) ~= nil
        -- vector flag
        if ssub(fmt, p, p) == 'v' then
            d.vector, p = true, p + 1
        elseif ssub(fmt, p, p) == '*' then
            local vidx, vq = argIndex(fmt, p + 1)
            vq = vq or p + 1
            if ssub(fmt, vq, vq) == 'v' then
                d.vector, d.vjoin, p = true, vidx and { vidx } or '*', vq + 1
            end
        end
        d.width, p = starOrNum(fmt, p)
        if ssub(fmt, p, p) == '.' then
            d.prec, p = starOrNum(fmt, p + 1)
            d.prec = d.prec or 0
        end
        local size = ssub(fmt, p, p + 1)
        if not SIZES[size] then size = ssub(fmt, p, p) end
        if SIZES[size] then
            d.size, p = size, p + #size
        end
        local conv = ssub(fmt, p, p)
        conv = SYNONYM[conv] or conv
        local valid = conv == 's' or conv == 'c' or conv == '%' or
                      INT_CONV[conv] or FLT_CONV[conv]
        if d.vector and not INT_CONV[conv] then valid = false end
        if not valid or conv == '' then
            -- not a directive: copied verbatim up to and including the
            -- character that broke it
            items[#items + 1] = ssub(fmt, pct, p)
            fast = false
        else
            d.conv = conv
            items[#items + 1] = d
            -- is this directive a Lua directive with Perl's semantics?
            local spec = ssub(fmt, pct, p)
            d.spec = spec
            local kind = FAST_KIND[conv]
            if conv == '%' and spec == '%%' then
                kind = 'pct'
            elseif not kind or d.index or d.vector or d.size or
                   type(d.width) ~= 'number' and d.width ~= nil or
                   type(d.prec) ~= 'number' and d.prec ~= nil or
                   not pcall(sformat, spec, kind == 'str' and 's' or kind == 'flt' and 1.5 or 1) then
                kind = nil
            end
            if not kind then
                fast = false
            elseif kind ~= 'pct' then
                if kind == 'str' and spec == '%s' then kind = 'any' end
                kinds[#kinds + 1] = kind
            end
        end
        pos = p + 1
    end
    local run = makeRunner({ items = items }, fast and kinds or nil)
    SPRINTF_CACHE[fmt] = run
    return run
end

-- The general (slow) path: walk the plan with Perl's argument rules.
sprintfSlow = function(plan, ...)
    local args = { ... }
    local nextArg = 1
    local function take(spec)
        if type(spec) == 'table' then return args[spec[1]] end
        local v = args[nextArg]
        nextArg = nextArg + 1
        return v
    end
    local out = {}
    local items = plan.items
    for i = 1, #items do
        local d = items[i]
        if type(d) == 'string' then
            out[#out + 1] = d
        else
            local vjoin = d.vjoin and perlStr(take(d.vjoin)) or '.'
            local width, prec = d.width, d.prec
            local left = d.left
            if width and type(width) ~= 'number' then
                width = toIV(numify(take(width)))
                if width < 0 then width, left = -width, true end
            end
            if prec and type(prec) ~= 'number' then
                prec = toIV(numify(take(prec)))
                if prec < 0 then prec = nil end
            end
            width = width or 0
            local dd = d
            if left ~= d.left then
                dd = setmetatable({ left = left }, { __index = d })
            end
            local conv = d.conv
            local s
            if conv == '%' then
                s = padField('%', width, left, d.zero, 0)
            else
                local v
                if d.index then v = args[d.index] else v = take() end
                if conv == 's' then
                    s = perlStr(v)
                    if prec and #s > prec then s = ssub(s, 1, prec) end
                    s = padField(s, width, left, d.zero, 0)
                elseif conv == 'c' then
                    local n = numify(v)
                    if n ~= n or n == INF or n == -INF then
                        error("Cannot printf " .. perlStr(n) .. " with 'c'", 3)
                    end
                    local iv = toIV(n)
                    if iv < 0 then
                        error('Use of code point ' .. sformat('0x%X', iv) .. ' is not allowed', 3)
                    end
                    s = iv < 256 and schar(iv) or utf8.char(iv)
                    s = padField(s, width, left, d.zero, 0)
                elseif d.vector then
                    -- %vd: the ordinals of the string's bytes, each one
                    -- formatted with this directive, joined by '.' (or the
                    -- '*v' argument); '+'/' ' only apply to the first
                    local str = perlStr(v)
                    local parts = {}
                    for k = 1, #str do
                        parts[k] = fmtInt(dd, sbyte(str, k), k == 1 and d.plus,
                                          k == 1 and d.space, width, prec)
                    end
                    s = tconcat(parts, vjoin)
                else
                    local n = numify(v)
                    if n ~= n or n == INF or n == -INF then
                        s = infNan(n, { plus = d.plus, space = d.space, width = width,
                                        left = left, zero = d.zero })
                    elseif INT_CONV[conv] then
                        s = fmtInt(dd, toIV(n), d.plus, d.space, width, prec)
                    else
                        -- float conversions: C semantics, which Lua's format
                        -- has; only the field width is applied here (Lua
                        -- caps it at 99), precision is capped at Lua's 99
                        local spec = '%' .. (d.plus and '+' or '') .. (d.space and ' ' or '') ..
                                     (d.alt and '#' or '') ..
                                     (prec and '.' .. mmin(prec, 99) or '') ..
                                     (conv == 'F' and 'f' or conv)
                        s = sformat(spec, nv(n))
                        if DECPT ~= '.' then s = fixDec(s) end
                        local keep = 0
                        local c1 = ssub(s, 1, 1)
                        if c1 == '-' or c1 == '+' or c1 == ' ' then keep = 1 end
                        if conv == 'a' or conv == 'A' then keep = keep + 2 end
                        s = padField(s, width, left, d.zero, keep)
                    end
                end
            end
            out[#out + 1] = s
        end
    end
    return tconcat(out)
end

-- Perl sprintf(). Formats like Perl, not like Lua's string.format: numeric
-- conversions numify their argument ("12abc" is 12, undef is 0) and %d/%x/...
-- truncate a non-integral number instead of raising; %s stringifies like
-- Perl ("1", not "1.0"; undef is ''); Inf/NaN print as 'Inf'/'-Inf'/'NaN';
-- %u, %b/%B, the vector flag (%vd), explicit indexes (%2$s), '*' widths and
-- precisions, size modifiers (%hd) and the '0' flag on %s work; a missing
-- argument counts as undef; an invalid directive is copied verbatim.
-- Fast path: when the format is also a valid Lua format with the same
-- meaning and each argument already has a kind Lua formats exactly like Perl
-- (an integer for %d, a finite number for %f, a string or integer for %s,
-- ...), this is a single string.format call.
-- Known differences: %c of a code point above 255 gives its UTF-8 bytes and
-- %vd works on bytes (lexiftool strings are byte strings); %n and %p are not
-- supported (copied verbatim); a float precision above 99 is capped at 99.
function perl.sprintf(fmt, ...)
    return (SPRINTF_CACHE[fmt] or parseSprintf(fmt))(fmt, ...)
end

-- Re-read the decimal point (see DECPT), the collation (see BYTE_ORDER) and
-- the case mapping (see CASE_ASCII) of the process's current C locale; when
-- the decimal point changed, the cached sprintf runners are rebuilt on their
-- next use.
-- Port addition, no Perl counterpart: called by ExifTool.new and by the C
-- API before each command, so a host's locale never shows in the output.
function perl.localeRefresh()
    BYTE_ORDER = collateIsBytes()
    CASE_ASCII = caseIsAscii()
    local d = sys.decimal_point()
    if d ~= DECPT then
        DECPT = d
        for k in pairs(SPRINTF_CACHE) do SPRINTF_CACHE[k] = nil end
    end
end

-- Days since 1970-01-01 for a civil date (Howard Hinnant's algorithm); the
-- calendar arithmetic behind timegm/gmtime below, which must not go through
-- os.time/os.date: those follow the local zone and reject dates outside the
-- platform's time_t range.
local function daysFromCivil(year, month, day)
    year = year - (month <= 2 and 1 or 0)
    local era = (year >= 0 and year // 400) or ((year - 399) // 400)
    local yoe = year - era * 400
    local doy = ((153 * (month + (month > 2 and -3 or 9))) + 2) // 5 + day - 1
    local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return era * 146097 + doe - 719468
end

-- Inverse of daysFromCivil: civil date from days since 1970-01-01
local function civilFromDays(z)
    z = z + 719468
    local era = (z >= 0 and z // 146097) or ((z - 146096) // 146097)
    local doe = z - era * 146097
    local yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    local y = yoe + era * 400
    local doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    local mp = (5 * doy + 2) // 153
    local d = doy - (153 * mp + 2) // 5 + 1
    local m = mp + (mp < 10 and 3 or -9)
    return y + (m <= 2 and 1 or 0), m, d
end

-- Time::Local::timegm($sec,$min,$hour,$mday,$mon,$year) - Unix time for a
-- UTC date. $mon is 0-based; a year below 1000 is an offset from 1900, as
-- Time::Local treats it. Out-of-range month/day values normalize, like Perl's.
function perl.timegm(sec, min, hour, mday, mon, year)
    if year < 1000 then year = year + 1900 end
    year = year + mon // 12
    mon = mon % 12
    return (daysFromCivil(year, mon + 1, mday) * 86400) + hour * 3600 + min * 60 + sec
end

-- Time::Local's two-digit year window, fixed when the module loads (as
-- Time::Local 1.35 computes $Breakpoint/$Century/$NextCentury).
local tlThisYear = os.date('*t').year - 1900
local tlBreakpoint = (tlThisYear + 50) % 100
local tlNextCentury = tlThisYear - tlThisYear % 100
if tlBreakpoint < 50 then tlNextCentury = tlNextCentury + 100 end
local tlCentury = tlNextCentury - 100
local tlMonthDays = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

-- Time::Local's croak: a Perl die naming the caller of perl.timelocal (as
-- Carp::croak names the first caller outside Time::Local), so the eval
-- around a conversion catches it like Perl's ("Day '30' out of range 1..28")
local function tlCroak(msg)
    local info = debug.getinfo(4, 'Sl') or { source = '=?', currentline = 0 }
    perl.die(msg .. ' at ' .. info.source:sub(2) .. ' line ' .. info.currentline .. '.\n')
end

-- Time::Local::timegm with its year munging and range checks (the croak
-- is tlCroak); the base of perl.timelocal below.
local function tlTimegm(sec, min, hour, mday, month, year)
    local subsec = sec - perl.int(sec)
    sec = perl.int(sec)
    if year >= 1000 then
        year = year - 1900
    elseif year < 100 and year >= 0 then
        year = year + ((year > tlBreakpoint) and tlCentury or tlNextCentury)
    end
    if month > 11 or month < 0 then
        tlCroak("Month '" .. perl.str(month) .. "' out of range 0..11")
    end
    local md = tlMonthDays[month + 1]
    local y = year + 1900
    if month == 1 and (y % 4 == 0 and (y % 100 ~= 0 or y % 400 == 0)) then md = md + 1 end
    if mday > md or mday < 1 then
        tlCroak("Day '" .. perl.str(mday) .. "' out of range 1.." .. md)
    end
    if hour > 23 or hour < 0 then tlCroak("Hour '" .. perl.str(hour) .. "' out of range 0..23") end
    if min > 59 or min < 0 then tlCroak("Minute '" .. perl.str(min) .. "' out of range 0..59") end
    if sec >= 60 or sec < 0 then tlCroak("Second '" .. perl.str(sec) .. "' out of range 0..59") end
    return (sec + 60 * min + 3600 * hour + 86400 * daysFromCivil(y, month + 1, mday)) + subsec
end

-- Time::Local's _timegm(localtime($t)): the local wall-clock time of $t read
-- back as if it were UTC (no munging, no checks).
local function tlLocalAsGm(t)
    local lt = perl.localtime(t)
    return lt[1] + 60 * lt[2] + 3600 * lt[3] + 86400 * daysFromCivil(lt[6] + 1900, lt[5] + 1, lt[4])
end

-- Time::Local::timelocal($sec,$min,$hour,$mday,$mon,$year) (Time::Local
-- 1.35, line for line) - Unix time for a local date. $mon is 0-based; a
-- year of 1000 or more is the full year, 0..99 a two-digit year in
-- Time::Local's rolling century window, anything else an offset from 1900.
-- DST is resolved through localtime() round trips like the original does
-- (a time in a DST gap moves forward, an ambiguous one takes the earlier
-- (DST) instant); fractional seconds survive.
function perl.timelocal(sec, min, hour, mday, mon, year)
    local subsec = sec - perl.int(sec)
    sec = perl.int(sec)
    local ref_t = tlTimegm(sec, min, hour, mday, mon, year)
    local loc_for_ref_t = tlLocalAsGm(ref_t)
    local zone_off = loc_for_ref_t - ref_t
    if zone_off == 0 then return loc_for_ref_t + subsec end
    -- Adjust for timezone
    local loc_t = ref_t - zone_off
    -- Are we close to a DST change or are we done
    local dst_off = ref_t - tlLocalAsGm(loc_t)
    -- If this evaluates to true, it means that the value in $loc_t is
    -- the _second_ hour after a DST change where the local time moves
    -- backward.
    if dst_off == 0 and ((ref_t - 3600) - tlLocalAsGm(loc_t - 3600) < 0) then
        return (loc_t - 3600) + subsec
    end
    -- Adjust for DST change
    loc_t = loc_t + dst_off
    if dst_off > 0 then return loc_t + subsec end
    -- If the original date was a non-existent gap in a forward DST jump, we
    -- should now have the wrong answer - undo the DST adjustment
    local lt = perl.localtime(loc_t)
    if lt[1] ~= sec or lt[2] ~= min or lt[3] ~= hour then loc_t = loc_t - dst_off end
    return loc_t + subsec
end

-- Perl gmtime() in list context - the broken-down UTC time as a 1-based array
-- in Perl's own field order: sec, min, hour, mday, mon (0-based), year-1900,
-- wday, yday. (Perl's list is 0-based; Lua arrays are 1-based, so field N of
-- Perl's `@t` is `t[N+1]` here -- the call sites index it that way.)
function perl.gmtime(time)
    local days = time // 86400
    local rem = time - days * 86400
    local y, m, d = civilFromDays(days)
    local wday = (days + 4) % 7                 -- 1970-01-01 was a Thursday
    local yday = days - daysFromCivil(y, 1, 1)
    return { rem % 60, (rem // 60) % 60, rem // 3600, d, m - 1, y - 1900, wday, yday }
end

-- Time::Piece->strptime($string, $format) (Time::Piece 1.36, Piece.xs
-- _strptime, a FreeBSD strptime), the strptime library exiftool's
-- InverseDateTime uses when POSIX::strptime is missing.  Time::Piece is a
-- core Perl module, so Perl always has it; this is its parser line for line
-- (names from TP_LOCALE, see perl.TimePieceUseLocale), followed by the
-- normalisation Piece.xs applies to the result (my_mini_mktime).
-- Returns: sec, min, hour, mday, _mon (0-based), _year (year-1900) -- what
-- `$t->sec, $t->min, $t->hour, $t->mday, $t->_mon, $t->_year` give;
-- dies "Error parsing time" like Time::Piece, and warns about garbage after
-- the parsed part.
-- (the locale data of Time::Piece: _default_locale, or what use_locale reads)
local TP_LOCALE = {
    month = { 'January', 'February', 'March', 'April', 'May', 'June', 'July',
              'August', 'September', 'October', 'November', 'December' },
    mon = { 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec' },
    weekday = { 'Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday' },
    wday = { 'Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat' },
    AM = 'AM', PM = 'PM', am = 'am', pm = 'pm',
}
-- Time::Piece->use_locale(): month/day names and AM/PM from strftime in the
-- locale of the environment (LC_TIME), which Perl adopts at startup and
-- perl.strftime reads into a locale object of its own (the process locale
-- is never switched). Piece.xs _get_localization starts at Sun, 01 Jan 2012
-- 03:00:00 and steps the weekday, then the month; PM is the same at 18:00.
function perl.TimePieceUseLocale()
    local loc = { month = {}, mon = {}, weekday = {}, wday = {} }
    for i = 0, 6 do
        loc.wday[i + 1] = perl.strftime('%a', 0, 0, 3, 1 + i, 0, 112)
        loc.weekday[i + 1] = perl.strftime('%A', 0, 0, 3, 1 + i, 0, 112)
    end
    for i = 0, 11 do
        loc.mon[i + 1] = perl.strftime('%b', 0, 0, 3, 1, i, 112)
        loc.month[i + 1] = perl.strftime('%B', 0, 0, 3, 1, i, 112)
    end
    loc.AM = perl.strftime('%p', 0, 0, 3, 1, 0, 112)
    loc.PM = perl.strftime('%p', 0, 0, 18, 1, 0, 112)
    -- If AM and PM are the same, set both to ''
    if loc.PM == '' or loc.AM == '' or loc.PM == loc.AM then
        loc.PM, loc.AM = '', ''
    end
    loc.pm, loc.am = asciiLower(loc.PM), asciiLower(loc.AM)
    -- Set globals. If anything is weird just use original
    for _, k in ipairs({ 'weekday', 'wday', 'month', 'mon' }) do
        if #loc[k] < (#TP_LOCALE[k]) then loc[k] = TP_LOCALE[k] end
    end
    TP_LOCALE = loc
end
local function tpSpace(c) return c ~= '' and sfind(' \t\n\r\f\v', c, 1, true) ~= nil end
local function tpDigit(c) return c ~= '' and sfind('0123456789', c, 1, true) ~= nil end
-- (case-insensitive prefix compare, strncasecmp(buf, name, strlen(name)))
local function tpPrefix(str, b, name)
    return asciiLower(ssub(str, b, b + #name - 1)) == asciiLower(name)
end
local tpParse
tpParse = function(str, b, fmt, tm, gotGMT)
    local p = 1
    local function ch(i) return ssub(str, i, i) end
    -- read up to len digits at b
    local function digits(len)
        local i = 0
        while len > 0 and tpDigit(ch(b)) do
            i = i * 10 + (sbyte(str, b) - 48)
            b = b + 1
            len = len - 1
        end
        return i
    end
    -- (after a number followed by whitespace, skip the format up to its
    --  next whitespace -- the FreeBSD quirk)
    local function skipFmt()
        if ch(b) ~= '' and tpSpace(ch(b)) then
            while p <= #fmt and not tpSpace(ssub(fmt, p, p)) do p = p + 1 end
        end
    end
    local function sub(f)
        b = tpParse(str, b, f, tm, gotGMT)
        return b ~= nil
    end
    while p <= #fmt do
        if b > #str then break end
        local c = ssub(fmt, p, p)
        p = p + 1
        if c ~= '%' then
            if tpSpace(c) then
                while b <= #str and tpSpace(ch(b)) do b = b + 1 end
            else
                if c ~= ch(b) then return nil end
                b = b + 1
            end
            goto continue
        end
        do
            local Ealternative, Oalternative = 0, 0
            ::label::
            c = ssub(fmt, p, p)
            p = p + 1
            if c == '' or c == '%' then
                if ch(b) ~= '%' then return nil end
                b = b + 1
            elseif c == '+' then
                if not sub('%c') then return nil end
            elseif c == 'C' then
                if not tpDigit(ch(b)) then return nil end
                local i = digits(2)     -- (XXX This will break for 3-digit centuries.)
                if i < 19 then return nil end
                tm.year = i * 100 - 1900
            elseif c == 'c' then
                if not sub('%a %d %b %Y %I:%M:%S %p %Z') then return nil end
            elseif c == 'D' then
                if not sub('%m/%d/%y') then return nil end
            elseif c == 'E' then
                if Ealternative == 0 and Oalternative == 0 then
                    Ealternative = Ealternative + 1
                    goto label
                end
            elseif c == 'O' then
                if Ealternative == 0 and Oalternative == 0 then
                    Oalternative = Oalternative + 1
                    goto label
                end
            elseif c == 'F' then
                if not sub('%Y-%m-%d') then return nil end
            elseif c == 'R' then
                if not sub('%H:%M') then return nil end
            elseif c == 'r' or c == 'X' then
                if not sub('%I:%M:%S %p') then return nil end
            elseif c == 'n' or c == 't' then
                if not tpSpace(ch(b)) then return nil end
                while tpSpace(ch(b)) do b = b + 1 end
            elseif c == 'T' then
                if not sub('%H:%M:%S') then return nil end
            elseif c == 'x' then
                if not sub('%a %d %b %Y') then return nil end
            elseif c == 'j' then
                if not tpDigit(ch(b)) then return nil end
                local i = digits(3)
                if i < 1 or i > 366 then return nil end
                tm.yday = i - 1
                tm.mday = 0
            elseif c == 'M' or c == 'S' then
                if ch(b) ~= '' and not tpSpace(ch(b)) then
                    if not tpDigit(ch(b)) then return nil end
                    local i = digits(2)
                    if c == 'M' then
                        if i > 59 then return nil end
                        tm.min = i
                    else
                        if i > 60 then return nil end
                        tm.sec = i
                    end
                    skipFmt()
                end
            elseif c == 'H' or c == 'I' or c == 'k' or c == 'l' then
                if not tpDigit(ch(b)) then return nil end
                local i = digits(2)
                if c == 'H' or c == 'k' then
                    if i > 23 then return nil end
                elseif i > 12 then
                    return nil
                end
                tm.hour = i
                skipFmt()
            elseif c == 'p' or c == 'P' then
                -- (XXX This is bogus if parsed before hour-related specifiers.)
                -- (strncasecmp with the length of the lower-case name)
                local am, pm = TP_LOCALE.am, TP_LOCALE.pm
                if tpPrefix(str, b, am) or tpPrefix(str, b, ssub(TP_LOCALE.AM, 1, #am)) then
                    if tm.hour > 12 then return nil end
                    if tm.hour == 12 then tm.hour = 0 end
                    b = b + #am
                elseif tpPrefix(str, b, pm) or tpPrefix(str, b, ssub(TP_LOCALE.PM, 1, #pm)) then
                    if tm.hour > 12 then return nil end
                    if tm.hour ~= 12 then tm.hour = tm.hour + 12 end
                    b = b + #pm
                else
                    return nil
                end
            elseif c == 'A' or c == 'a' then
                local names = c == 'A' and TP_LOCALE.weekday or TP_LOCALE.wday
                local i = 1
                while i <= 7 and not tpPrefix(str, b, names[i]) do i = i + 1 end
                if i > 7 then return nil end
                tm.wday = i - 1
                b = b + #names[i]
            elseif c == 'U' or c == 'V' or c == 'W' then
                if not tpDigit(ch(b)) then return nil end
                if digits(2) > 53 then return nil end
                skipFmt()
            elseif c == 'u' or c == 'w' then
                if not tpDigit(ch(b)) then return nil end
                local i = sbyte(str, b) - 48
                if i > 6 + (c == 'u' and 1 or 0) then return nil end
                if i == 7 then i = 0 end
                tm.wday = i
                b = b + 1
                skipFmt()
            elseif c == 'd' or c == 'e' then
                if not tpDigit(ch(b)) then return nil end
                local i = digits(2)
                if i > 31 then return nil end
                tm.mday = i
                skipFmt()
            elseif c == 'B' or c == 'b' or c == 'h' then
                -- (the C locale has no alternative month names: %OB matches nothing)
                local names = c == 'B' and TP_LOCALE.month or TP_LOCALE.mon
                local i = 1
                if Oalternative == 0 then
                    while i <= 12 and not tpPrefix(str, b, names[i]) do i = i + 1 end
                elseif c ~= 'B' then
                    i = 13
                end
                if i > 12 then return nil end
                tm.mon = i - 1
                b = b + (Oalternative == 0 and #names[i] or 0)
            elseif c == 'm' then
                if not tpDigit(ch(b)) then return nil end
                local i = digits(2)
                if i < 1 or i > 12 then return nil end
                tm.mon = i - 1
                skipFmt()
            elseif c == 's' then
                local num = smatch(str, '^[ \t\n\r\f\v]*[-+]?%d+', b)
                if not num then return nil end   -- (strtol converts nothing)
                b = b + #num
                local t = perl.gmtime(tonumber(num))    -- (*got_GMT is never 1 here)
                tm.sec, tm.min, tm.hour, tm.mday, tm.mon, tm.year, tm.wday, tm.yday =
                    t[1], t[2], t[3], t[4], t[5], t[6], t[7], t[8]
            elseif c == 'Y' or c == 'y' then
                if ch(b) ~= '' and not tpSpace(ch(b)) then
                    if not tpDigit(ch(b)) then return nil end
                    local i = digits(c == 'Y' and 4 or 2)
                    if c == 'Y' then i = i - 1900 end
                    if c == 'y' and i < 69 then i = i + 100 end
                    if i < 0 then return nil end
                    tm.year = i
                    skipFmt()
                end
            elseif c == 'Z' then
                local e = b
                while smatch(ch(e), '^[A-Z]$') do e = e + 1 end
                if e > b then
                    if ssub(str, b, e - 1) == 'GMT' then gotGMT[1] = 1 end
                    if gotGMT[1] ~= 1 then return nil end
                    b = e
                end
            elseif c == 'z' then
                local sign = 1
                if ch(b) ~= '+' then
                    if ch(b) == '-' then sign = -1 else return nil end
                end
                b = b + 1
                local i = 0
                for _ = 1, 4 do
                    if not tpDigit(ch(b)) then return nil end
                    i = i * 10 + (sbyte(str, b) - 48)
                    b = b + 1
                end
                tm.hour = tm.hour - sign * (i // 100)
                tm.min = tm.min - sign * (i % 100)
                gotGMT[1] = 1
            end
            -- (any other conversion character is ignored, as in the C switch)
        end
        ::continue::
    end
    return b
end
function perl.TimePieceStrptime(str, fmt)
    str, fmt = perlStr(str), perlStr(fmt)
    -- sensible defaults (the struct is zeroed first)
    local tm = { sec = 0, min = 0, hour = 0, mday = 1, mon = 0, year = 70, wday = 4, yday = 0 }
    local b = tpParse(str, 1, fmt, tm, { 0 })
    if not b then perl.die('Error parsing time at Time/Piece.pm line 584.\n') end
    if b <= #str then
        perl.warn('Garbage at end of string in strptime: ' .. ssub(str, b) .. ' at Time/Piece.pm line 584.\n')
        perl.warn('Perhaps a format flag did not match the actual input? at Time/Piece.pm line 584.\n')
    end
    -- normalise (my_mini_mktime): a given yday with no month & mday dominates
    local days
    if tm.yday >= 0 and tm.mday <= 0 and tm.mon <= 0 then
        days = daysFromCivil(tm.year + 1900, 1, 1) + tm.yday
    else
        days = daysFromCivil(tm.year + 1900 + tm.mon // 12, tm.mon % 12 + 1, tm.mday)
    end
    local secs, sec = 0, tm.sec
    if sec < 0 or sec > 60 then secs, sec = sec, 0 end
    secs = secs + 60 * tm.min + 3600 * tm.hour
    days = days + secs // 86400
    secs = secs % 86400
    local y, m, d = civilFromDays(days)
    return sec + secs % 60, (secs // 60) % 60, secs // 3600, d, m - 1, y - 1900
end

-- File type bits of st_mode, as used by stat(2) (and by the FilePermissions
-- tag's PrintConv, ExifTool.pm:1519-1526).
local S_IFMT = {
    file = 0x8000,          -- 0100000 regular
    directory = 0x4000,     -- 0040000
    link = 0xa000,          -- 0120000 symlink
    socket = 0xc000,        -- 0140000
    ['block device'] = 0x6000,  -- 0060000
    ['char device'] = 0x2000,   -- 0020000
    ['named pipe'] = 0x1000,    -- 0010000 FIFO
    fifo = 0x1000,
}

-- Rebuild the numeric permission bits from lfs's "rwxr-xr-x" string. lfs does
-- not expose st_mode numerically, but that string carries every bit: the three
-- rwx triples, and the set-user-ID/set-group-ID/sticky bits folded into the
-- execute positions as s/S/t/T (lower case = execute also set).
local function permissionBits(perms)
    if type(perms) ~= 'string' or #perms < 9 then return nil end
    local bits = 0
    local special = { [3] = 0x800, [6] = 0x400, [9] = 0x200 } -- setuid, setgid, sticky
    for i = 1, 9 do
        local c = perms:sub(i, i)
        if c ~= '-' then
            -- 'S' and 'T' mean the special bit is set but execute is NOT
            if c ~= 'S' and c ~= 'T' then
                bits = bits | (1 << (9 - i))
            end
            if c == 's' or c == 'S' or c == 't' or c == 'T' then
                bits = bits | special[i]
            end
        end
    end
    return bits
end

-- Perl opendir/readdir - the entries of a directory, name-sorted and without
-- '.' and '..'. Returns nil when the path cannot be opened as a directory.
function perl.readdir(path)
    local lfs = require('lfs')
    local ok, iter, obj = pcall(lfs.dir, path)
    if not ok then return nil end
    local names = {}
    for name in iter, obj do
        if name ~= '.' and name ~= '..' then names[#names + 1] = name end
    end
    -- Deliberately NOT sorted: upstream processes directory entries in readdir
    -- order, and -progress numbers the files in exactly that order.
    return names
end

-- File::Glob::bsd_glob(PATTERN) - expand a path with shell wildcards, in the
-- order File::Glob returns it (byte order; case-insensitive on Windows,
-- where exiftool imports ':nocase'). '*' and '?' match within one path
-- component; as the extension Win32::FindFile provides to exiftool, '**'
-- crosses any number of directory levels. exiftool only ever passes a
-- wildcard in the last component (main.lua's FindFileWindows rejects the
-- rest, upstream's HasWildcards check), but the general form is implemented
-- here. As File::Glob does, a wildcard does not match a leading '.' (only a
-- pattern component that itself begins with '.' matches such names), unless
-- matchDot is set -- (port: Win32::FindFile::FindFile matches them, so
-- FindFileWindows passes it). A pattern without any wildcard is resolved
-- like bsd_glob does: the name itself if it exists.
-- Returns a list, never nil -- an empty pattern (or no match) is empty, as
-- bsd_glob() in list context.
function perl.bsd_glob(pattern, matchDot)
    local lfs = require('lfs')
    if type(pattern) ~= 'string' then return {} end
    local nocase = perl.osname() == 'MSWin32'
    if nocase then pattern = sgsub(pattern, '\\', '/') end  -- Windows accepts both separators

    -- split off the root and keep it verbatim in the result: a Windows drive
    -- "C:/", a drive-relative "z:" (the working directory on that drive), a
    -- UNC "//" or POSIX "/"; otherwise the pattern is relative to the current
    -- directory and matching names are relative too
    local root, rest = '', pattern
    if nocase and smatch(rest, '^[A-Za-z]:/') then
        root, rest = ssub(rest, 1, 2) .. '/', ssub(rest, 4)
    elseif nocase and smatch(rest, '^[A-Za-z]:') then
        root, rest = ssub(rest, 1, 2), ssub(rest, 3)
    elseif ssub(rest, 1, 2) == '//' then
        root, rest = '//', ssub(rest, 3)
    elseif ssub(rest, 1, 1) == '/' then
        root, rest = '/', ssub(rest, 2)
    end
    local comps = {}
    for comp in sgmatch(rest, '[^/]+') do comps[#comps + 1] = comp end

    -- one component's glob translated to a PCRE (no '/' in the matches)
    local function globRegex(comp)
        local out = {}
        local i, n = 1, #comp
        while i <= n do
            local c = ssub(comp, i, i)
            if c == '*' then
                out[#out + 1] = '[^/]*'
            elseif c == '?' then
                out[#out + 1] = '[^/]'
            elseif c == '[' then
                local j = sfind(comp, ']', i + 1, true)
                if j then
                    local cls = ssub(comp, i + 1, j - 1)
                    if ssub(cls, 1, 1) == '!' then cls = '^' .. ssub(cls, 2) end
                    out[#out + 1] = '[' .. cls .. ']'
                    i = j
                else
                    out[#out + 1] = '\\['    -- unterminated class: literal '['
                end
            elseif smatch(c, '^[A-Za-z0-9/_%-]$') then
                out[#out + 1] = c
            else
                out[#out + 1] = '\\' .. c
            end
            i = i + 1
        end
        return tconcat(out)
    end

    local function entries(dirpath)
        local dir = dirpath == '' and '.' or dirpath
        local ok, iter, obj = pcall(lfs.dir, dir)
        if not ok then return {} end
        local names = {}
        for name in iter, obj do
            if name ~= '.' and name ~= '..' then names[#names + 1] = name end
        end
        return names
    end

    local out = {}
    local function scan(dirpath, i)
        if i > #comps then
            local cand = dirpath
            if not smatch(cand, '^[A-Za-z]:/$') and cand ~= '/' then cand = sgsub(cand, '/+$', '') end
            if cand ~= '' and lfs.attributes(cand) then out[#out + 1] = cand end
            return
        end
        local comp = comps[i]
        if comp == '**' then
            scan(dirpath, i + 1)                        -- matches zero levels
            for _, name in ipairs(entries(dirpath)) do
                local full = dirpath .. name
                if (matchDot or ssub(name, 1, 1) ~= '.') and
                    lfs.attributes(full, 'mode') == 'directory'
                then
                    scan(full .. '/', i)
                end
            end
        elseif not smatch(comp, '[*?[]') then
            local full = dirpath .. comp
            if lfs.attributes(full) then scan(full .. '/', i + 1) end
        else
            local re = '^' .. globRegex(comp) .. '$'
            if nocase then re = '(?i)' .. re end
            -- (a leading '.' is matched only explicitly, or with matchDot)
            local dotOk = matchDot or ssub(comp, 1, 1) == '.'
            for _, name in ipairs(entries(dirpath)) do
                if (dotOk or ssub(name, 1, 1) ~= '.') and perl.isMatchDyn(name, re) then
                    scan(dirpath .. name .. '/', i + 1)
                end
            end
        end
    end
    scan(root, 1)
    if nocase then
        tsort(out, function(a, b) return perl.lt(asciiLower(a), asciiLower(b)) end)
    else
        perl.tsort(out)
    end
    return out
end

-- Perl's $? (CHILD_ERROR): the status of the last backtick command or
-- system() call, as Perl encodes it -- the exit code shifted left by 8, the
-- signal number for a killed child, -1 if the program could not be started.
perl.CHILD_ERROR = 0

-- (status triple of io.popen():close() / os.execute() -> Perl's $?)
local function childError(ok, how, code)
    if how == 'signal' then return code end
    if ok and code == nil then return 0 end   -- (Lua 5.1-style true)
    return (code or 0) << 8
end

-- Quote one word for /bin/sh (system LIST runs a program without a shell in
-- Perl; the port has only the shell, so each argument is quoted verbatim).
local function shQuote(word)
    return "'" .. sgsub(perl.str(word), "'", [['\'']]) .. "'"
end

-- Where the standard output and error of a child process go: nil (inherit)
-- or a path. Perl reopens its STDOUT/STDERR (`open(STDOUT, '>', $path)`);
-- Lua cannot reopen the standard handles, and the only writers that matter
-- between such an open and its restore are child processes, so the
-- redirection is carried to the command lines that perl.system builds.
local stdoutPath, stderrPath

-- Perl `open(STDOUT, '>', $out); open(STDERR, '>', $err)` for the child
-- processes started by perl.system; nil restores the inherited handle.
-- Returns: the previous (stdout, stderr) setting, to hand back later like
--          Perl's `open($oldout, ">&STDOUT")` ... `open(STDOUT, ">&", $oldout)`.
function perl.redirectStdio(out, err)
    local oldout, olderr = stdoutPath, stderrPath
    stdoutPath, stderrPath = out, err
    return oldout, olderr
end

-- Perl `cmd` (qx//): runs cmd through /bin/sh and returns its output -- as
-- one string, or with wantarray as the list of lines, each with its "\n"
-- (Perl's list context). Sets perl.CHILD_ERROR like $?.
function perl.qx(cmd, wantarray)
    local fh = io.popen(cmd, 'r')
    if not fh then
        perl.CHILD_ERROR = -1
        if wantarray then return {} end
        return nil
    end
    local out = fh:read('a') or ''
    perl.CHILD_ERROR = childError(fh:close())
    if not wantarray then return out end
    local lines = {}
    for line in sgmatch(out, '[^\n]*\n?') do
        if line ~= '' then lines[#lines + 1] = line end
    end
    return lines
end

-- Port-only helper for the LIST form of perl.system below: resolves a bare
-- program name the way execvp()/CreateProcess() would (PATH, and on
-- Windows PATHEXT), so "the program does not exist" can be told apart from
-- "the program ran and exited non-zero" *before* a shell is ever started --
-- the LIST form never starts one in Perl either, so there is no shell exit
-- code to read, and a shell's own code for "not found" is not portable: sh
-- uses 126/127, cmd.exe (Windows, where perl.system always goes through a
-- shell, see below) has no equivalent convention.
local isWindows = package.config:sub(1, 1) == '\\'
local function programExists(name)
    local lfs = require('lfs')
    local hasDir = isWindows and smatch(name, '[/\\:]') or ssub(name, 1, 1) == '/' or
        smatch(name, '^%.%.?/')
    local exts = { '' }
    if isWindows then
        for ext in sgmatch(perl.str(os.getenv('PATHEXT')) ~= '' and os.getenv('PATHEXT')
            or '.COM;.EXE;.BAT;.CMD', '[^;]+') do
            exts[#exts + 1] = ext
        end
    end
    local function tryDir(dir)
        for _, ext in ipairs(exts) do
            if lfs.attributes((dir and (dir .. (isWindows and '\\' or '/')) or '') .. name .. ext) then
                return true
            end
        end
        return false
    end
    if hasDir then return tryDir(nil) end
    for dir in sgmatch(os.getenv('PATH') or '', '[^' .. (isWindows and ';' or ':') .. ']+') do
        if tryDir(dir) then return true end
    end
    return false
end

-- Perl system(LIST): one argument is a shell command line, several are a
-- program and its arguments (quoted for the shell here). Returns the status
-- like Perl ($?, also stored in perl.CHILD_ERROR): 0 on success, -1 if the
-- program could not be started -- POSIX: the shell's 126/127 for a program
-- that is missing or not executable, which Perl reports as -1 for the LIST
-- form; missing is caught before that too (see programExists), since it is
-- the only part of "not started" a shell's exit code cannot portably tell
-- from "ran and failed" (Windows' cmd.exe has nothing like 126/127).
function perl.system(...)
    local args = { ... }
    local cmd
    if #args == 1 then
        cmd = perl.str(args[1])
    else
        if not programExists(perl.str(args[1])) then
            perl.CHILD_ERROR = -1
            return -1
        end
        local words = {}
        for k = 1, #args do words[k] = shQuote(args[k]) end
        cmd = tconcat(words, ' ')
    end
    if stdoutPath then cmd = cmd .. ' >' .. shQuote(stdoutPath) end
    if stderrPath then cmd = cmd .. ' 2>' .. shQuote(stderrPath) end
    local status = childError(os.execute(cmd))
    if #args > 1 and (status == 126 << 8 or status == 127 << 8) then status = -1 end
    perl.CHILD_ERROR = status
    return status
end

-- Perl stat() - filesystem attributes for a file path (via luafilesystem).
-- Returns: nil on failure, otherwise a table with size/mtime/atime/ctime/mode
-- (mode is the lfs type string), permissions (the rwx string) and modeNum,
-- the numeric st_mode that FilePermissions stores as its raw value.
function perl.stat(path)
    local lfs = require('lfs')
    local attr = lfs.attributes(path)
    if not attr then return nil end
    local bits = permissionBits(attr.permissions)
    return {
        size = attr.size,
        mtime = attr.modification,
        atime = attr.access,
        ctime = attr.change,
        mode = attr.mode,
        permissions = attr.permissions,
        modeNum = bits and (bits | (S_IFMT[attr.mode] or S_IFMT.file)) or nil,
        -- (stat fields 0, 1, 3-6, 11 and 12 of Perl's list: dev, ino,
        --  nlink, uid, gid, rdev, blksize, blocks; lfs has no blksize and
        --  blocks on Windows, where Perl's are '' too)
        dev = attr.dev,
        ino = attr.ino,
        nlink = attr.nlink,
        uid = attr.uid,
        gid = attr.gid,
        rdev = attr.rdev,
        blksize = attr.blksize,
        blocks = attr.blocks,
    }
end

-- Perl file test operators (-e, -f, -d, -p, -r, -s, -l) on a path.
-- Inputs: 0) operator letter, 1) path
-- Returns: true/false like Perl (-s: the size if non-zero, else false)
function perl.filetest(op, path)
    local attr = require('lfs').attributes(path)
    if not attr then return false end
    if op == 'e' then return true end
    if op == 'f' then return attr.mode == 'file' end
    if op == 'd' then return attr.mode == 'directory' end
    if op == 'p' then return attr.mode == 'named pipe' end
    if op == 'r' then
        -- (readable by this process: lfs has no access(2), opening tells)
        local fh = io.open(path, 'rb')
        if not fh then return false end
        fh:close()
        return true
    end
    if op == 's' then return attr.size > 0 and attr.size or false end
    if op == 'l' then
        local lattr = require('lfs').symlinkattributes(path)
        return lattr ~= nil and lattr.mode == 'link'
    end
    error('perl.filetest: unsupported operator -' .. tostring(op))
end

-- Perl unlink LIST - delete files. Returns the number of files deleted.
function perl.unlink(...)
    local n = 0
    for k = 1, select('#', ...) do
        local file = select(k, ...)
        -- (Windows: DeleteFileW through lexiftool.sys, so Unicode names work)
        if sys.unlink then
            if sys.unlink(file) then n = n + 1 end
        elseif os.remove(file) then
            n = n + 1
        end
    end
    return n
end

-- Perl chmod MODE, LIST - set the permission bits of files. Returns the
-- number of files changed. Lua (and luafilesystem) have no chmod; it is
-- lexiftool.sys.chmod (on Windows only the read-only flag, as in Perl).
function perl.chmod(mode, ...)
    local n = 0
    for k = 1, select('#', ...) do
        if sys.chmod(perl.int(mode), perl.str((select(k, ...)))) then n = n + 1 end
    end
    return n
end

-- Perl getpwuid/getpwnam/getgrgid/getgrnam in scalar context: the user or
-- group name for a numeric id, or the id for a name -- undef when there is
-- none. lexiftool.sys calls the real libc functions (nil on Windows,
-- where Perl does not implement these either, see sys.c); int() because
-- Perl's %systemTags pass the value as ExifTool stored it, which may be a
-- string read back from a tag.
function perl.getpwuid(uid) return sys.getpwuid and sys.getpwuid(perl.int(uid)) end
function perl.getpwnam(name) return sys.getpwnam and sys.getpwnam(perl.str(name)) end
function perl.getgrgid(gid) return sys.getgrgid and sys.getgrgid(perl.int(gid)) end
function perl.getgrnam(name) return sys.getgrnam and sys.getgrnam(perl.str(name)) end

-- Perl chown UID, GID, LIST - change the owner and group of files (-1 leaves
-- that id alone, as in Perl). Returns the number of files changed. Goes
-- through lexiftool.sys (chown(2); a no-op that still counts on Windows,
-- like Perl's), not through chown(1): a child process would inherit the
-- environment of the caller, and the test harness injects a stat shim there.
function perl.chown(uid, gid, ...)
    local n = 0
    for k = 1, select('#', ...) do
        local path = select(k, ...)
        if sys.chown(path, perl.int(uid), perl.int(gid)) then n = n + 1 end
    end
    return n
end

-- Perl rename OLDNAME, NEWNAME - rename (move) a file. Returns true on
-- success, false otherwise (Perl's 1 / '').
function perl.rename(old, new)
    -- (Windows: MoveFileExW through lexiftool.sys, so Unicode names work)
    if sys.rename then
        return sys.rename(old, new) and true or false
    end
    return os.rename(old, new) and true or false
end

-- Perl utime ATIME, MTIME, LIST - set the access and modification times of
-- files (Unix seconds, fractions allowed). Returns the number of files
-- changed. Only file names are supported: Perl's futimes form, a filehandle
-- in LIST, has no counterpart in Lua and counts as a failure (0), so a
-- caller that falls back to the name -- as Writer.pl's SetFileTime does --
-- takes that path. The times are truncated to whole seconds (Perl keeps the
-- microseconds where utimes() is available; luafilesystem cannot).
function perl.utime(atime, mtime, ...)
    local lfs = require('lfs')
    atime, mtime = perl.int(perl.num(atime)), perl.int(perl.num(mtime))
    local n = 0
    for k = 1, select('#', ...) do
        local file = select(k, ...)
        if type(file) == 'string' and lfs.touch(file, atime, mtime) then n = n + 1 end
    end
    return n
end

-- Perl mkdir PATH, MODE - create a directory. Returns true on success.
function perl.mkdir(path, mode)
    return sys.mkdir(path, mode) and true or false
end

-- Perl link OLDFILE, NEWFILE - create a hard link. Returns true on success.
function perl.link(old, new)
    return require('lfs').link(old, new) and true or false
end

-- Perl symlink OLDFILE, NEWFILE - create a symbolic link. Returns true on
-- success.
function perl.symlink(old, new)
    return require('lfs').link(old, new, true) and true or false
end

-- Perl Cwd::abs_path(PATH) - the absolute path of an existing file, with
-- "." and ".." and (POSIX) symbolic links resolved -- lexiftool.sys's
-- realpath(3), not implemented on Windows (Cwd.pm does not resolve NTFS
-- reparse points there either; the manual "."/".." normalization below is
-- then as good a match). Returns nil if the file does not exist.
function perl.abs_path(path)
    local lfs = require('lfs')
    if not lfs.attributes(path) then return nil end
    if sys.realpath then return sys.realpath(path) end
    -- Windows: absolute paths are "D:\..." (a drive letter, no leading
    -- slash) or "\\server\share\..." (UNC); lfs.currentdir() is the same
    -- shape. Splitting/rejoining on '/' only, and always prepending one,
    -- both silently assume the POSIX shape below and corrupt a Windows
    -- path (e.g. "." becomes "/D:\a\lexiftool\lexiftool").
    local sep = package.config:sub(1, 1)
    local drive = ''
    if sep == '\\' then
        if ssub(path, 1, 2) == '\\\\' then
            drive = '\\\\'
            path = ssub(path, 3)
        elseif ssub(path, 2, 2) == ':' then
            drive = ssub(path, 1, 2)
            path = ssub(path, 3)
        else
            path = lfs.currentdir() .. sep .. path
            drive = ssub(path, 1, 2)
            path = ssub(path, 3)
        end
    elseif ssub(path, 1, 1) ~= '/' then
        path = lfs.currentdir() .. '/' .. path
    end
    local parts = {}
    for part in sgmatch(path, '[^/\\]+') do
        if part == '..' then
            parts[#parts] = nil
        elseif part ~= '.' then
            parts[#parts + 1] = part
        end
    end
    return drive .. sep .. tconcat(parts, sep)
end

-- Perl binmode FILEHANDLE[, LAYER] - a Lua file's CRT translation mode on
-- Windows: no LAYER is binary (no translation), ':crlf' is Perl's default
-- text layer ('\n' written as CR/LF). It is a property of the OS file
-- descriptor that no reopening in another io.open mode could change after
-- the fact, hence sys.setmode -- a no-op on POSIX, which has no such
-- distinction, like Perl's own binmode there. ExifTool:Open opens every file
-- binary ('rb'/'wb'), so binmode(FH) after it changes nothing; where upstream
-- writes through an open() WITHOUT binmode -- Perl's text mode, CR/LF line
-- ends on Windows -- the port calls binmode(FH, ':crlf') right after the
-- open (main.lua). STDIN/STDOUT/STDERR start in text mode, as Perl's do. A
-- handle that is no (open) Lua file is not touched: undef, as Perl's
-- binmode on an unopened handle.
function perl.binmode(fh, layer)
    if io.type(fh) ~= 'file' then return nil end
    return sys.setmode(fh, layer == ':crlf')
end

-- Perl time() - the current Unix time in whole seconds.
function perl.time()
    return os.time()
end

-- Perl localtime() in list context - the broken-down local time in Perl's
-- field order, 1-based like perl.gmtime: sec, min, hour, mday, mon (0-based),
-- year-1900, wday, yday, isdst.
function perl.localtime(time)
    if time == nil then time = os.time() end
    local t = os.date('*t', time)
    return { t.sec, t.min, t.hour, t.day, t.month - 1, t.year - 1900, t.wday - 1, t.yday - 1,
             t.isdst and 1 or 0 }
end

-- POSIX::strftime($fmt, $sec, $min, $hour, $mday, $mon, $year, $wday, $yday,
-- $isdst) - the platform's own libc strftime (lexiftool.sys, which mirrors
-- Perl 5.42's POSIX.xs/locale.c: mktime normalization with isdst -1, the
-- LC_TIME locale Perl takes from the environment -- read into a locale
-- object of its own, the process locale is never switched -- and its buffer
-- loop), so a conversion
-- the C library knows works as in Perl and one it rejects fails as in Perl
-- -- where os.date would raise for anything outside Lua's own list (on
-- Windows that includes %C and %e). $mon is 0-based, $year is an offset
-- from 1900; $wday and $yday are ignored, as POSIX.xs ignores them, and so
-- is $isdst (upstream never passes it; -1 is the default). On failure the
-- result is the empty string, like POSIX::strftime's (errno is EINVAL then).
function perl.strftime(fmt, sec, min, hour, mday, mon, year)
    return sys.strftime(perl.str(fmt), perl.int(sec), perl.int(min), perl.int(hour),
                        perl.int(mday), perl.int(mon), perl.int(year)) or ''
end

-- Perl $^O - the operating system name ('MSWin32', 'linux', 'darwin',
-- 'cygwin', 'freebsd', ...), fixed when lexiftool.sys was compiled, as
-- Perl's is when perl was.
local osname = sys.platform()
function perl.osname()
    return osname
end

-- Perl `$ENV{NAME}` (read) - the process environment, undef for a variable
-- that is not set.  Only for the call sites where upstream itself reads
-- %ENV (CONTRIBUTING.md "Configuration": the .ExifTool_config lookup in
-- lexiftool.lua); lexiftool reads no environment of its own.
function perl.getenv(name)
    return os.getenv(name)
end

-- Perl `$ENV{NAME} = VALUE` - writes the process environment (the C
-- runtime's copy, which tzset and os.getenv read).  Only for the call sites
-- where upstream itself writes %ENV (CONTRIBUTING.md "Configuration"); there is
-- no unsetenv because upstream never deletes from %ENV.
function perl.setenv(name, value)
    return sys.setenv(perl.str(name), perl.str(value))
end

-- POSIX::tzset() (and Time::Piece::_tzset() on Windows) - makes localtime
-- re-read TZ after perl.setenv('TZ', ...).
function perl.tzset()
    return sys.tzset()
end

-- Term::ReadKey (the two calls the exiftool script makes): ReadMode sets
-- the terminal mode of STDIN by name or number (Term::ReadKey's %modes),
-- ReadKey(0) reads one key in it. Returns the key, or undef at end of input.
-- POSIX: 'cbreak' (3) reads without echo and without waiting for RETURN;
-- lexiftool.sys switches the terminal for the duration of that one read and
-- back (termios, ignored for STDIN that is no terminal, as Term::ReadKey
-- ignores it), so ReadMode(0) ("restore") has nothing left to do there.
-- Windows: as Term::ReadKey's Win32 branch -- ReadMode sets the console mode
-- of STDIN (sys.readmode) and croaks when STDIN is no console
-- ("GetConsoleMode failed, LastError=|N| at FILE line N.": the XS's croak
-- names the line of Term::ReadKey's ReadMode that calls it, so FILE/N are
-- this file's sys.readmode line; uncaught this is a die; "Unknown terminal
-- mode" is Carp's croak, from the caller's line), and ReadKey reads console
-- key events (Win32PeekChar, sys.peekchar) in mode 3 and above, otherwise
-- getc STDIN.
local readModes = { restore = 0, normal = 1, noecho = 2, cbreak = 3, raw = 4, ['ultra-raw'] = 5 }
local currentMode = 0
perl.TermReadKey = {
    ReadMode = function(mode)
        local m = readModes[asciiLower(tostring(mode))]
        if m ~= nil then
            currentMode = m
        elseif sfind(tostring(mode), '^%d') then
            currentMode = math.tointeger(tonumber(smatch(tostring(mode), '^%d+'))) or 0
        else
            local info = debug.getinfo(2, 'Sl')
            perl.die("Unknown terminal mode `" .. tostring(mode) .. "' at " ..
                ssub(info.source, 2) .. ' line ' .. info.currentline .. '.\n')
        end
        if sys.readmode then
            -- (SetReadMode($CurrentMode, $fh): the XS croaks, and Perl_croak
            --  names the Perl line that called it -- Term/ReadKey.pm's own
            --  line, here the one of the sys.readmode call)
            local info, ok, err = debug.getinfo(1, 'Sl'), sys.readmode(currentMode)
            if not ok then
                perl.die(err .. ' at ' .. ssub(info.source, 2) .. ' line ' ..
                    info.currentline .. '.\n')
            end
        end
    end,
    ReadKey = function(delay)
        if sys.peekchar then
            if perl.truthy(delay) or currentMode >= 3 then return sys.peekchar() end
            return io.stdin:read(1)
        end
        if currentMode == 3 then return sys.readkey_noecho() end
        return io.stdin:read(1)
    end,
}

-- The exit status of a die nothing catches (perl.c my_failure_exit): errno
-- if it is set, else the high byte of $? (perl.CHILD_ERROR), else 255.
function perl.dieExitStatus()
    local eno = sys.errno() & 255
    if eno ~= 0 then return eno end
    local exitstatus = (math.tointeger(perl.CHILD_ERROR) or 0) >> 8 & 255
    if exitstatus ~= 0 then return exitstatus end
    return 255
end

-- Perl `eval { require Module::Name }` - true if the module loads, plus the
-- loaded module (where Perl would call Module::Name::func, the Lua calls
-- module.func).  A Perl module name maps to the Lua module of the same name
-- with '.' for '::' (Win32::API -> Win32.API); none of the Perl-only ones
-- exist here.  Exceptions, the modules the port provides itself:
--   Time::Piece    the facade's own (strptime is perl.TimePieceStrptime,
--                  _tzset is perl.tzset)
--   Term::ReadKey  perl.TermReadKey, over lexiftool.sys
--   IO::Uncompress::Brotli / IO::Compress::Brotli
--                  unbro / bro over the optional rock lbrotli (below);
--                  without it both are missing, as upstream without the
--                  Perl modules
local PROVIDED_MODULES = {
    ['Time::Piece']   = true,
    ['Term::ReadKey'] = true,
}

-- IO::Uncompress::Brotli::unbro($buffer [, $max_size]) and
-- IO::Compress::Brotli::bro($buffer [, $quality [, $lgwin]]) of
-- IO-Compress-Brotli, over lbrotli (https://github.com/osch/lua-lbrotli).
-- $buffer may be a string or a carray (read in place); the result is a
-- string. unbro ignores data after the end of the Brotli stream and fails
-- for output beyond max_size, as the XS does; bro's defaults are the XS's
-- (quality 11, window 22, generic mode). Errors are raised (callers wrap
-- them in pcall as upstream wraps them in eval), with the XS's texts:
-- "Error in BrotliDecoderDecompress" with max_size, otherwise lbrotli's
-- "Error in BrotliDecoderDecompressStream: <reason>". `version` is the
-- libbrotli version, for -ver -v. Returns nil when lbrotli is missing.
local function loadBrotli()
    local ok, lbrotli = pcall(require, 'lbrotli')
    if not ok then return nil end
    local decompress, compress = lbrotli.decompress, lbrotli.compress
    return {
        unbro = function(buffer, maxSize)
            if maxSize == nil then
                return decompress(buffer, { allowtrailing = true })
            end
            local okD, out = pcall(decompress, buffer, { maxsize = maxSize, allowtrailing = true })
            if not okD then error('Error in BrotliDecoderDecompress', 0) end
            return out
        end,
        bro = function(buffer, quality, lgwin)
            return compress(buffer, { quality = quality or 11, lgwin = lgwin or 22 })
        end,
        version = (lbrotli.version()),
    }
end
-- Time::HiRes::gettimeofday() (list context: seconds, microseconds, here as
-- a table { sec, usec } for `@startTime`) and tv_interval(\@start[, \@end])
-- (the seconds between them as a float, to now without an end), over the
-- wall clock of lexiftool.sys.
local function loadHiRes()
    if not sys.gettimeofday then return nil end
    local function gettimeofday() return { sys.gettimeofday() } end
    return {
        gettimeofday = gettimeofday,
        tv_interval = function(t0, t1)
            t1 = t1 or gettimeofday()
            return (t1[1] - t0[1]) + (t1[2] - t0[2]) / 1e6
        end,
    }
end

local MODULE_LOADERS = {
    ['IO::Uncompress::Brotli'] = loadBrotli,
    ['IO::Compress::Brotli']   = loadBrotli,
    ['Time::HiRes']            = loadHiRes,
}
local loadedModules = {}
function perl.evalRequire(name)
    if PROVIDED_MODULES[name] then return true end
    local loader = MODULE_LOADERS[name]
    if loader then
        local mod = loadedModules[name]
        if mod == nil then
            mod = loader() or false
            loadedModules[name] = mod
        end
        if not mod then return false end
        return true, mod
    end
    local ok, mod = pcall(require, (name:gsub('::', '.')))
    if not ok then return false end
    return true, mod
end

-- Perl truncate(FILEHANDLE, LENGTH) - shortens an open file (Lua file
-- handle; its buffer is flushed first).  Returns 1 on success, or nil plus
-- the error text, so upstream's `eval { truncate(...) } or $err = 1` call
-- sites see a false result.
function perl.truncate(fh, len)
    local ok, err = sys.ftruncate(fh, len)
    if not ok then return nil, err end
    return 1
end

-- Perl $$ - the process ID. Standard Lua cannot ask for it; /proc/self is
-- the process that opens it (Linux), elsewhere the shell's $PPID is.
local pid
function perl.pid()
    if pid then return pid end
    local fh = io.open('/proc/self/stat', 'r')
    if fh then
        pid = tonumber(smatch(fh:read('l') or '', '^(%d+)'))
        fh:close()
    end
    if not pid then pid = tonumber(smatch(perl.qx('echo $PPID') or '', '(%d+)')) or 0 end
    return pid
end

-- Perl rand(EXPR) - a random fractional number from 0 up to (not including)
-- EXPR (default 1).
local seeded
function perl.rand(n)
    if not seeded then
        math.randomseed(os.time(), perl.pid())
        seeded = true
    end
    return math.random() * (n or 1)
end

-- Hex lookup table for unpack 'H' templates. (Perl's 'H*' produces lowercase
-- hex digits, e.g. the JUMBF JUMDType value "800000aa00389b71".)
local HEX = '0123456789abcdef'

-- Convert a byte string to its hex representation (Perl `unpack 'H*'`).
-- Inputs: 0) byte string; Returns: hex string
local function hexstr(s)
    local out = {}
    for i = 1, #s do
        local b = sbyte(s, i)
        out[#out + 1] = ssub(HEX, (b // 16) + 1, (b // 16) + 1)
        out[#out + 1] = ssub(HEX, (b % 16) + 1, (b % 16) + 1)
    end
    return tconcat(out)
end

-- Strip trailing NULs and whitespace (Perl `unpack 'A*'` semantics:
-- pp_pack.c strips while the byte is NUL or isSPACE, i.e. also \t \n \v
-- \f \r -- perl: unpack('A4', "ab\t\n") is "ab").
local function stripTrail(s)
    return (s:gsub('[\0 \t\n\r\f\v]+$', ''))
end

-- Parse an unpack format string into a token list (cached per format).
-- Supports the codes in LUAFMT plus a/A/Z/H and the position codes @/x/X
-- with explicit counts or '*'.
local function tokenize(fmt)
    local tokens = FMT_CACHE[fmt]
    if tokens then return tokens end
    tokens = {}
    local i = 1
    while i <= #fmt do
        local c = ssub(fmt, i, i)
        if c == ' ' or c == '(' or c == ')' then
            i = i + 1
        elseif c:match('%d') then
            error('perl.unpack: unexpected number in format: ' .. fmt, 2)
        else
            local code = c
            local count
            local j = i + 1
            local cj = ssub(fmt, j, j)
            if cj == '*' then
                count = '*'
                j = j + 1
            else
                local start = j
                while ssub(fmt, j, j):match('%d') do
                    j = j + 1
                end
                if j > start then
                    count = tonumber(ssub(fmt, start, j - 1))
                end
            end
            tokens[#tokens + 1] = { code = code, count = count }
            i = j
        end
    end
    FMT_CACHE[fmt] = tokens
    return tokens
end

-- Number of bytes a template reads from its start, or nil when that depends
-- on the data ('*' counts, 'Z', bit strings, absolute '@'/back-up 'X').
local SPAN_CACHE = {}
local function fixedSpan(fmt)
    local span = SPAN_CACHE[fmt]
    if span ~= nil then return span or nil end
    span = 0
    for _, tok in ipairs(tokenize(fmt)) do
        local code, count = tok.code, tok.count or 1
        if count == '*' then span = false break end
        if SIZE[code] then
            span = span + SIZE[code] * count
        elseif code == 'x' or code == 'a' or code == 'A' then
            span = span + count
        elseif code == 'H' then
            span = span + (count + 1) // 2
        else
            span = false
            break
        end
    end
    SPAN_CACHE[fmt] = span
    return span or nil
end

-- Fast path for the templates that make up nearly every unpack call (the
-- Get8u/Get16u/Get32u family, ReadValue's "$fmt$count"/"$fmt*", `x4N`):
-- an optional leading skip ('x' with a count) followed by one fixed-size
-- numeric code, or a run of the same code ('NN' reads like 'N2' -- a short
-- string loses the trailing values either way).  The template is compiled
-- once into a reader closure (cached per template string, false for every
-- other template, which takes the general token loop below); the closure
-- implements exactly the general loop's semantics for that shape, without
-- a result table for a single value.
-- Reader: (s, pos, withOff, base) with s a Lua string and pos 0-based;
-- returns the values, plus the end position (+ base, the offset of s in a
-- carray it was copied from) when withOff is set.
local UNPACK_FAST = {}
local function compileUnpackFast(fmt)
    local tokens = tokenize(fmt)
    local i, skip = 1, 0
    local first = tokens[1]
    if first and first.code == 'x' then
        if first.count == '*' then return false end
        skip = first.count or 1
        i = 2
    end
    local tok = tokens[i]
    if not tok then return false end
    local code = tok.code
    local lf, size = LUAFMT[code], SIZE[code]
    if not lf then return false end
    local count = tok.count or 1
    for j = i + 1, #tokens do
        local t = tokens[j]
        if t.code ~= code or t.count == '*' or count == '*' then return false end
        count = count + (t.count or 1)
    end
    if count == 1 then
        return function(s, pos, withOff, base)
            pos = pos + skip
            if pos + size > #s then
                if withOff then return pos + base end
                return
            end
            if withOff then return (sunpack(lf, s, pos + 1)), pos + size + base end
            return (sunpack(lf, s, pos + 1))
        end
    end
    if count == '*' then
        return function(s, pos, withOff, base)
            pos = pos + skip
            local n = #s
            local c = pos < n and (n - pos) // size or 0
            if c == 0 then
                if withOff then return pos + base end
                return
            end
            if code == 'C' and not withOff then return sbyte(s, pos + 1, pos + c) end
            local vals = { sunpack(srep(lf, c), s, pos + 1) }
            if withOff then
                vals[c + 1] = pos + c * size + base
                return tunpack(vals, 1, c + 1)
            end
            return tunpack(vals, 1, c)
        end
    end
    local rep, span = srep(lf, count), count * size
    return function(s, pos, withOff, base)
        pos = pos + skip
        local n = #s
        local c, f = count, rep
        if pos + span > n then
            c = pos < n and (n - pos) // size or 0
            if c == 0 then
                if withOff then return pos + base end
                return
            end
            f = srep(lf, c)
        end
        local vals = { sunpack(f, s, pos + 1) }
        if withOff then
            vals[c + 1] = pos + c * size + base
            return tunpack(vals, 1, c + 1)
        end
        return tunpack(vals, 1, c)
    end
end

-- Perl unpack() - decode a string per a Perl template.
-- Inputs: 0) format string, 1) byte string, 2) optional 0-based offset
-- Returns: one value per template element; when `off` is given the final
--          position is returned as the last value.
function perl.unpack(fmt, s, off)
    -- (a negative offset is an error in Perl -- "'x' outside of string";
    --  the facade returns no values, which reads as undef)
    if off ~= nil and off < 0 then
        return
    end
    if type(s) == 'string' then
        local fast = UNPACK_FAST[fmt]
        if fast == nil then
            fast = compileUnpackFast(fmt)
            UNPACK_FAST[fmt] = fast
        end
        if fast then
            if off == nil then return fast(s, 0) end
            return fast(s, off, true, 0)
        end
    end
    if type(s) == 'userdata' then
        -- carray (a mutable buffer, Perl's scalar behind a reference): copy
        -- out only the bytes a fixed-size template can read rather than the
        -- whole buffer -- Get16u & Co. read single values from large ones
        local span = fixedSpan(fmt)
        local base = off or 0
        if span then
            local len = s:len()
            local last = base + span
            if last > len then last = len end
            local piece = base < last and s:tostring(base + 1, last) or ''
            if off == nil then return perl.unpack(fmt, piece) end
            local fast = UNPACK_FAST[fmt]
            if fast then return fast(piece, 0, true, base) end
            local res = { perl.unpack(fmt, piece, 0) }
            res[#res] = res[#res] + base
            return tunpack(res)
        end
        s = s:tostring()
    end
    -- (Perl stringifies the data argument: unpack('N', 100) unpacks "100")
    if type(s) ~= 'string' then s = perlStr(s) end
    local pos = off or 0
    local n = #s
    local results = {}
    for _, tok in ipairs(tokenize(fmt)) do
        local code = tok.code
        local count = tok.count or 1
        if code == '@' then
            pos = count
        elseif code == 'x' then
            pos = pos + count
        elseif code == 'X' then
            pos = mmax(0, pos - count)
        else
            local lf = LUAFMT[code]
            if lf then
                local size = SIZE[code]
                if count == 1 and pos + size <= n then
                    -- (one value: no result table for string.unpack)
                    results[#results + 1] = sunpack(lf, s, pos + 1)
                    pos = pos + size
                    goto nextToken
                end
                if count == '*' then
                    if pos >= n then
                        count = 0
                    else
                        count = (n - pos) // size
                    end
                elseif pos + count * size > n then
                    -- Perl returns only the values the data holds (unpack('N3',
                    -- 8 bytes) is 2 values, unpack('N', "100") none) where
                    -- string.unpack would raise "data string too short"
                    count = pos >= n and 0 or (n - pos) // size
                end
                if count > 0 then
                    local vals = { sunpack(srep(lf, count), s, pos + 1) }
                    local lastpos = tremove(vals)
                    for i = 1, #vals do
                        results[#results + 1] = vals[i]
                    end
                    pos = lastpos - 1
                end
            elseif code == 'a' or code == 'A' then
                local len
                if count == '*' then
                    len = n - pos
                else
                    len = mmin(count, n - pos)
                end
                local v = len > 0 and ssub(s, pos + 1, pos + len) or ''
                results[#results + 1] = code == 'A' and stripTrail(v) or v
                pos = pos + len
            elseif code == 'Z' then
                local nullpos = s:find('\0', pos + 1, true)
                local star = (count == '*')
                local lim = star and (n - pos) or (count or 1)
                lim = mmin(lim, n - pos)
                local terminated = nullpos and nullpos - pos <= lim
                if terminated then
                    results[#results + 1] = ssub(s, pos + 1, nullpos - 1)
                else
                    results[#results + 1] = ssub(s, pos + 1, pos + lim)
                end
                -- 'Z*' consumes up to and including the NUL, but 'Zn' always
                -- consumes exactly n bytes -- the number is the field width,
                -- not a maximum (perl: unpack('NZ64N', ...) reads 72 bytes)
                if star and terminated then
                    pos = nullpos
                else
                    pos = pos + lim
                end
            elseif code == 'H' then
                local len
                if count == '*' then
                    len = n - pos
                else
                    len = mmin(count // 2, n - pos)
                end
                local v = len > 0 and ssub(s, pos + 1, pos + len) or ''
                results[#results + 1] = hexstr(v)
                pos = pos + len
            elseif code == 'b' or code == 'B' then
                -- bit string: 'b' takes the bits of each byte in ascending
                -- order (lsb first), 'B' in descending order; the count is in
                -- bits, '*' takes all remaining bytes
                local bits
                if count == '*' then
                    bits = (n - pos) * 8
                else
                    bits = mmin(count, (n - pos) * 8)
                end
                local out = {}
                for i = 0, bits - 1 do
                    local byte = sbyte(s, pos + 1 + i // 8)
                    local bit = i % 8
                    if code == 'B' then bit = 7 - bit end
                    out[#out + 1] = ((byte >> bit) & 1 == 1) and '1' or '0'
                end
                results[#results + 1] = table.concat(out)
                pos = pos + (bits + 7) // 8
            else
                error('perl.unpack: unsupported format code ' .. code .. ' in ' .. fmt, 2)
            end
        end
        ::nextToken::
    end
    if off ~= nil then
        results[#results + 1] = pos
    end
    return tunpack(results)
end

-- Perl packs an integer code the way C casts: a float is truncated toward
-- zero, and a value outside the code's range wraps around modulo its size
-- (with a "Character in 'n' format wrapped" warning) -- Lua's string.pack
-- raises an error for both.  Recompose relies on it: Charset.pm packs code
-- points above 0xffff with 'n*'.  f/d pass through untouched.
local function packInt(code, v)
    local size = SIZE[code]
    if code == 'f' or code == 'd' or not size then return v end
    -- (Perl numifies a string by its numeric prefix: "0x10" is 0, not 16)
    if type(v) ~= 'number' then v = perl.num(v) end
    if mtype(v) == 'float' then
        if v ~= v or v == math.huge or v == -math.huge then return 0 end
        v = mtointeger(v < 0 and math.ceil(v) or mfloor(v)) or 0
    end
    if size < 8 then
        local bits = size * 8
        -- (Perl warns when a 'C' or 'c' value does not fit its byte)
        if (code == 'C' and (v < 0 or v > 255)) or (code == 'c' and (v < -128 or v > 127)) then
            perl.warn("Character in '" .. code .. "' format wrapped in pack")
        end
        v = v & ((1 << bits) - 1)
        -- signed codes take the two's-complement value
        if code == 'c' or code == 's' or code == 'i' or code == 'l' then
            if v >= (1 << (bits - 1)) then v = v - (1 << bits) end
        end
    end
    return v
end

-- Perl pack() - the numeric fixed-size codes perl.unpack maps through LUAFMT,
-- plus the 'a'/'A' string codes (NUL- resp. space-padded to the given width,
-- truncated when longer; 'a*'/'A*' take the string as it is) and the 'H' hex
-- string code.  'Z' is not needed yet.
-- Inputs: 0) format, 1..n) values
-- Returns: packed binary string
--
-- Fast path (as UNPACK_FAST): a template that is one fixed-size numeric code
-- without a count (DoPackStd's 'n'/'N'/'v'/'V'/'C', Set16u & Co.) packs its
-- first argument directly; an integer within the code's range needs no
-- packInt (whose wrap/truncation it would leave unchanged anyway).
local PACK_FAST = {}
local function compilePackFast(fmt)
    local tokens = tokenize(fmt)
    local tok = tokens[1]
    if #tokens ~= 1 or tok.count ~= nil then return false end
    local code = tok.code
    local lf, size = LUAFMT[code], SIZE[code]
    if not lf then return false end
    if code == 'f' or code == 'd' then
        return function(v) return spack(lf, v or 0) end
    end
    local lo, hi = math.mininteger, math.maxinteger
    if size < 8 then
        local bits = size * 8
        if code == 'c' or code == 's' or code == 'i' or code == 'l' then
            lo, hi = -(1 << (bits - 1)), (1 << (bits - 1)) - 1
        else
            lo, hi = 0, (1 << bits) - 1
        end
    end
    return function(v)
        if mtype(v) == 'integer' and v >= lo and v <= hi then return spack(lf, v) end
        return spack(lf, packInt(code, v or 0))
    end
end

function perl.pack(fmt, ...)
    local fast = PACK_FAST[fmt]
    if fast == nil then
        fast = compilePackFast(fmt)
        PACK_FAST[fmt] = fast
    end
    if fast then return (fast(...)) end
    local vals = { ... }
    local vi = 1 -- index of the next value to consume (Perl consumes @_)
    local out = {}
    for _, tok in ipairs(tokenize(fmt)) do
        local code = tok.code
        local count = tok.count or 1
        if code == '@' or code == 'x' or code == 'X' then
            error('perl.pack: unsupported format code ' .. code .. ' in ' .. fmt, 2)
        else
            local lf = LUAFMT[code]
            if lf then
                -- (vi is 1-based, so the remaining count includes vals[vi]
                --  itself -- without the +1 a '*' repeat dropped the last
                --  value, e.g. pack('C*',65,66,67) gave "AB")
                if count == '*' then count = #vals - vi + 1 end
                for _ = 1, count do
                    out[#out + 1] = spack(lf, packInt(code, vals[vi] or 0))
                    vi = vi + 1
                end
            elseif code == 'H' then
                -- hex string, high nybble first; the count is in nybbles
                -- ('*' = the whole string), an odd count pads the last low
                -- nybble with 0; a letter maps like Perl's ((c & 15) + 9) & 15
                local v = perlStr(vals[vi])
                vi = vi + 1
                local n = count == '*' and #v or count
                local bytes = {}
                local function nyb(b)
                    if (b >= 65 and b <= 90) or (b >= 97 and b <= 122) then return ((b & 15) + 9) & 15 end
                    return b & 15
                end
                for k = 1, n, 2 do
                    local hi, lo = sbyte(v, k) or 48, sbyte(v, k + 1) or 48
                    if k + 1 > n then lo = 48 end
                    bytes[#bytes + 1] = schar(nyb(hi) << 4 | nyb(lo))
                end
                out[#out + 1] = tconcat(bytes)
            elseif code == 'U' then
                -- a character number per value, stored as its UTF-8 bytes
                -- (strings are bytes throughout the port, so Perl's C0 and
                --  U0 modes come out the same here)
                if count == '*' then count = #vals - vi + 1 end
                for _ = 1, count do
                    out[#out + 1] = utf8.char(perl.int(vals[vi] or 0))
                    vi = vi + 1
                end
            elseif code == 'a' or code == 'A' then
                local v = perlStr(vals[vi])
                vi = vi + 1
                if count ~= '*' then
                    if #v > count then
                        v = ssub(v, 1, count)
                    else
                        v = v .. srep(code == 'A' and ' ' or '\0', count - #v)
                    end
                end
                out[#out + 1] = v
            elseif code == 'u' then
                -- uuencoded string: lines of up to 45 bytes (a count of 3 or
                -- more sets the line length, rounded down to a multiple of
                -- 3), each a length character plus 4 characters per 3 bytes
                -- and a newline; Perl's map writes 0 as '`', not ' '
                local v = perlStr(vals[vi])
                vi = vi + 1
                local lineLen = 45
                if count ~= '*' and count > 2 then lineLen = count - count % 3 end
                local function uu(n) return n == 0 and '`' or schar(32 + n) end
                for i = 1, #v, lineLen do
                    local chunk = ssub(v, i, i + lineLen - 1)
                    local line = { uu(#chunk) }
                    for j = 1, #chunk, 3 do
                        local a, b, c = sbyte(chunk, j, j + 2)
                        b, c = b or 0, c or 0
                        line[#line + 1] = uu(a >> 2) .. uu(((a & 3) << 4) | (b >> 4)) ..
                                          uu(((b & 15) << 2) | (c >> 6)) .. uu(c & 63)
                    end
                    out[#out + 1] = tconcat(line) .. '\n'
                end
            else
                error('perl.pack: unsupported format code ' .. code .. ' in ' .. fmt, 2)
            end
        end
    end
    return tconcat(out)
end


-- Perl ref() - the kind of reference a value is, by the shapes the port
-- gives Perl's references: '' for a plain value (and for a UV object, which
-- stands for a number), 'SCALAR' for `{ ref = 'SCALAR', value = ... }`,
-- 'GLOB' for a file handle, 'CODE' for a function, 'HASH' for a table with
-- keys but no first element (or with the `_ordered_keys_` list OrderedKeys
-- reads), and 'ARRAY' for any other table -- an empty table included, since
-- the port's empty list and empty hash look the same.
function perl.ref(v)
    local t = type(v)
    if t == 'function' then return 'CODE' end
    if io.type(v) then return 'GLOB' end
    if t ~= 'table' or getmetatable(v) == UV then return '' end
    if v.ref == 'SCALAR' then return 'SCALAR' end
    if v._ordered_keys_ then return 'HASH' end
    if v[1] == nil and next(v) ~= nil then return 'HASH' end
    return 'ARRAY'
end

-- Perl shift ARRAY - removes and returns the first element (undef for an
-- empty array).
function perl.shift(list)
    return tremove(list, 1)
end

-- Perl unshift ARRAY, LIST - prepends the list (in its order); returns the
-- new number of elements.  (An undef element cannot be stored in a Lua
-- array, so a nil argument is skipped.)
function perl.unshift(list, ...)
    local n = select('#', ...)
    for i = n, 1, -1 do
        local v = select(i, ...)
        if v ~= nil then table.insert(list, 1, v) end
    end
    return #list
end

-- Perl push ARRAY, LIST - appends the list; returns the new number of
-- elements.  (A nil argument is skipped, as in perl.unshift.)
function perl.push(list, ...)
    local n = select('#', ...)
    for i = 1, n do
        local v = select(i, ...)
        if v ~= nil then list[#list + 1] = v end
    end
    return #list
end

-- Perl `grep /pat/, LIST` - the elements of the list (a Lua array) that
-- match the literal pattern pat (cached like perl.matches).
function perl.grep(pat, list)
    local out = {}
    for i = 1, #list do
        if doIsMatch(pat, perlStr(list[i])) then out[#out + 1] = list[i] end
    end
    return out
end

-- Same as perl.grep, but for pat built at runtime (Perl `grep /$var/`):
-- compiled once per call, outside the pattern cache.
function perl.grepDyn(pat, list)
    pat = dynamic(pat)
    local out = {}
    for i = 1, #list do
        if doIsMatch(pat, perlStr(list[i])) then out[#out + 1] = list[i] end
    end
    return out
end

-- Perl's magic string increment (`++$s` on a string that is not a number):
-- 'a' -> 'b', 'az' -> 'ba', 'zz' -> 'aaa', 'Az9' -> 'Ba0' -- a string of
-- letters followed by digits counts up in place, carrying leftwards; any
-- other value is numified and incremented by 1.
function perl.increment(s)
    if type(s) ~= 'string' or s == '' or not smatch(s, '^[a-zA-Z]*[0-9]*$') then
        return perl.num(s) + 1
    end
    local chars = {}
    for i = 1, #s do chars[i] = ssub(s, i, i) end
    local i = #chars
    while i >= 1 do
        local c = chars[i]
        if c == 'z' then chars[i] = 'a'
        elseif c == 'Z' then chars[i] = 'A'
        elseif c == '9' then chars[i] = '0'
        else
            chars[i] = schar(sbyte(c) + 1)
            return tconcat(chars)
        end
        i = i - 1
    end
    -- carried past the first character: prepend one of its kind
    local first = ssub(s, 1, 1)
    local lead = smatch(first, '%d') and '1' or (smatch(first, '[A-Z]') and 'A' or 'a')
    return lead .. tconcat(chars)
end

-- Perl's $| (OUTPUT_AUTOFLUSH), per file handle: Perl sets it for the
-- currently selected handle (`$| = 1`), IO::Handle per handle
-- (`STDOUT->autoflush(1)`).  Setting it to a true value flushes the handle
-- at once, as Perl does, and makes perl.print flush after every print.
-- Standard Lua has no hook into a handle's buffering beyond setvbuf, which
-- cannot be undone portably (a terminal's line buffering is not knowable),
-- so the flag lives here and perl.print honours it.
-- Inputs: 0) file handle, 1) new value (omitted: only read the setting)
-- Returns: the previous setting (0 or 1), so `my $save = $|` ports as
--          `local save = autoflush(io.stdout)`
local AUTOFLUSH = setmetatable({}, { __mode = 'k' })
function perl.autoflush(fh, val)
    local old = AUTOFLUSH[fh] or 0
    if val ~= nil then
        if perl.truthy(val) then
            AUTOFLUSH[fh] = 1
            fh:flush()
        else
            AUTOFLUSH[fh] = nil
        end
    end
    return old
end

-- Perl print FILEHANDLE LIST - writes the list, each element stringified
-- like Perl (perl.str: a float 2 prints "2", undef ''), and flushes
-- afterwards if autoflush is set for the handle.  Returns 1 on success and
-- '' on a write error, like Perl's print.
-- (the bytes are counted per handle for perl.tell; a handle switched to a
--  buffer by perl.redirect gets them there instead)
local PRINTED = setmetatable({}, { __mode = 'k' })
function perl.print(fh, ...)
    local n = select('#', ...)
    local ok = true
    local len = 0
    local buf = REDIRECT[fh]    -- (perl.redirect)
    for i = 1, n do
        local v = select(i, ...)
        if type(v) ~= 'string' then v = perlStr(v) end
        if buf then
            buf[#buf + 1] = v
        elseif not fh:write(v) then
            ok = false
        end
        len = len + #v
    end
    PRINTED[fh] = (PRINTED[fh] or 0) + len
    if AUTOFLUSH[fh] and not buf then fh:flush() end
    return ok and 1 or ''
end

-- Perl tell FILEHANDLE.  PerlIO keeps the position itself: where the handle
-- started plus every byte that went through it.  On a plain file that is
-- the OS file position, which file:seek('cur') (C ftell) answers; a pipe or
-- a character device has none -- lseek fails, or answers 0 for ever like
-- /dev/null -- but Perl still counts (perl -e 'print "x" x 100;
-- print STDERR tell STDOUT' >/dev/null prints 100, through a pipe as well),
-- so there it is the count of the bytes perl.print wrote to the handle (as
-- for a handle perl.redirect has switched to a buffer).
-- Returns -1 on error, like Perl.
function perl.tell(fh)
    if REDIRECT[fh] == nil and sys.isreg(fh) then return fh:seek('cur') or -1 end
    return PRINTED[fh] or 0
end

-- Perl printf FILEHANDLE FORMAT, LIST - perl.print of perl.sprintf.
function perl.printf(fh, fmt, ...)
    return perl.print(fh, perl.sprintf(fmt, ...))
end

-- Perl sysread FILEHANDLE, SCALAR, LENGTH, OFFSET - reads what the handle has
-- available and appends it to the buffer at offset (the end of the buffer
-- here).  Lua's io library has no unbuffered read: a read of LENGTH bytes
-- blocks on a pipe until all of them have arrived.  A line read returns as
-- soon as one complete line (or the data before EOF) is there, which is what
-- the one caller (the -stay_open ARGFILE reader) needs -- it only acts on
-- complete lines.  At end of file the EOF indicator of the stream is cleared
-- again (fseek), so that a later call sees data appended to a growing file,
-- as Perl's sysread does.
-- Returns: 0) the new buffer, 1) number of bytes read (0 at end of file),
--          or undef on a read error
function perl.sysread(fh, buff, len, offset) -- luacheck: ignore 212
    local ok, data, err = pcall(fh.read, fh, 'L')
    if not ok or err then return buff, nil end
    if data == nil then
        fh:seek('cur', 0)   -- (clear the EOF indicator; fails harmlessly on a pipe)
        return buff, 0
    end
    if offset then buff = ssub(buff, 1, offset) end
    return buff .. data, #data
end

-- Perl `select(undef, undef, undef, $time)` - sleep for the given number of
-- seconds (fractions allowed).  Standard Lua has no sleep; lexiftool.sys's
-- sleep_ms (nanosleep, or Sleep on Windows) does it, to the millisecond.
function perl.select(_r, _w, _e, time)
    time = tonumber(time)
    if time and time > 0 then
        sys.sleep_ms(math.floor(time * 1000 + 0.5))
    end
    return 0
end

-- Perl eval STRING, for the places exiftool evaluates Perl code typed by
-- the user: the -if condition (after InsertTagValues has replaced the tags
-- by `$info{'TAG'}` variables) and the advanced formatting expressions
-- "${TAG;EXPR}" (code that edits $_).  Lua cannot run Perl, so this is an
-- interpreter for the part of the language such code uses:
--   terms      numbers, '...', "...", q(...) and qq(...) strings (the
--              double-quoted ones interpolating $name, ${name}, $name{key},
--              $$name{key}, $name[N], $1.. and @name), $name, $name{key},
--              $$name{key}, $name[EXPR], @name, the capture variables
--              $1..$N of the last successful match, undef, ( ... ) and
--              (LIST), `my $x`/`my @a`/`my ($x, @a)` (variables of this
--              eval), method calls $obj->Name(ARGS), function calls NAME(...)
--              or NAME LIST, a bare /re/ (matches $_; in list context the
--              captures, with /g all matches), s/re/repl/flags,
--              tr/a/b/flags and y/a/b/flags (on $_, or on a variable bound
--              with =~)
--   operators  ++ -- ** ! unary - + =~ !~ (with /re/flags or
--              m<d>re<d>flags) * / % x + - . << >> < > <= >= lt gt le ge
--              == != <=> eq ne cmp & | ^ && || // ?: = .= += -= *= /= **=
--              ||= &&= //= , => not and or xor -- with Perl's precedence,
--              short-circuit evaluation and scalar/list context (an array
--              in scalar context is its count, a literal list its last
--              element)
--   statements separated by ';', each with an optional `if COND` or
--              `unless COND` modifier, and the block forms `if (COND)
--              {...} elsif (COND) {...} else {...}`, `unless (COND) {...}`
--              and `{...}`; the value is that of the last one
--   builtins   defined length lc uc lcfirst ucfirst int abs ord chr hex
--              oct sqrt exp log scalar substr index rindex sprintf join
--              split push unshift, plus the functions passed in funcs
--              (exiftool's End/EndDir, DateFmt, ShiftTime, NoDups, SetTags)
-- Inputs: 0) code, 1) variables by name (a scalar, or a hash table for
--         $name{key} and $$name{key}, or a sequence for @name; assignments
--         and s///, tr/// write back into this table, so the caller reads
--         the new $_ as vars._ -- `my` variables stay inside the eval),
--         2) functions by name
-- Returns: the value of the last statement (in scalar context); dies
--          (perl.die) with Perl's message for a syntax error ("syntax error
--          at (eval 1) line 1, near ...") and with "Perl syntax unsupported
--          in lexiftool: WHAT (near "...") at (eval 1) line 1." for valid
--          Perl outside this subset -- the die object then carries
--          `unsupported` (perl.isUnsupported), so a caller can say so
--          loudly instead of treating it as an ordinary failed eval
local PerlList = {}     -- metatable of a list value: split, (A, B), @array
local function newList(t, n, literal)
    t.n = n or #t
    t.literal = literal     -- (a literal list: the comma operator's value)
    return setmetatable(t, PerlList)
end
-- scalar context: an array or a function's list gives its count, a literal
-- list its last element (Perl's comma operator)
local function sc(v)
    if getmetatable(v) ~= PerlList then return v end
    if v.literal then return v[v.n] end
    return v.n
end
-- list context: append the elements of v to the list out
local function flatInto(out, v)
    if getmetatable(v) == PerlList then
        for i = 1, v.n do
            out.n = out.n + 1
            out[out.n] = v[i]
        end
    else
        out.n = out.n + 1
        out[out.n] = v
    end
    return out
end
local function intVal(v)
    local n = perl.num(v)
    n = n < 0 and math.ceil(n) or math.floor(n)
    return math.tointeger(n) or 0
end
local EVAL_FUNCS = {
    defined = function(v) return v ~= nil and 1 or '' end,
    length = function(v) return perl.length(v) end,
    lc = function(v) return perl.lc(v) end,
    uc = function(v) return perl.uc(v) end,
    lcfirst = function(v) return perl.lcfirst(v) end,
    ucfirst = function(v) return perl.ucfirst(v) end,
    int = function(v) return perl.int(v) end,
    abs = function(v) return math.abs(perl.num(v)) end,
    ord = function(v) return perl.ord(perlStr(v)) end,
    chr = function(v) return perl.chr(perl.num(v)) end,
    hex = function(v) return perl.hex(perlStr(v)) end,
    oct = function(v) return perl.oct(perlStr(v)) end,
    sqrt = function(v)
        local n = perl.num(v)
        if n < 0 then perl.die("Can't take sqrt of " .. perlStr(n) .. ' at (eval 1) line 1.\n') end
        return math.sqrt(n)
    end,
    exp = function(v) return math.exp(perl.num(v)) end,
    log = function(v) return perl.log(v) end,
    scalar = function(v) return v end,  -- (the argument is evaluated in scalar context)
    substr = function(s, off, len)
        return perl.substr(perlStr(s), intVal(off), len ~= nil and intVal(len) or nil)
    end,
    index = function(s, t, p) return perl.index(s, t, p ~= nil and intVal(p) or nil) end,
    rindex = function(s, t, p) return perl.rindex(s, t, p ~= nil and intVal(p) or nil) end,
    sprintf = function(fmt, ...) return perl.sprintf(fmt, ...) end,
    join = function(sep, ...)
        local t = tpack(...)
        local list = {}
        for i = 1, t.n do list[i] = t[i] == nil and '' or t[i] end
        return perl.join(sep, list)
    end,
}
-- (named unary operators: an argument without parentheses binds tighter
--  than a comparison, `length $x == 5` is `length($x) == 5`; without an
--  argument they act on $_)
local EVAL_NAMED_UNARY = { defined = 1, length = 1, lc = 1, uc = 1, lcfirst = 1,
                           ucfirst = 1, int = 1, abs = 1, ord = 1, chr = 1, hex = 1,
                           oct = 1, sqrt = 1, exp = 1, log = 1 }
-- (list operators: their arguments are flattened, and without parentheses
--  they take everything up to the next low-precedence operator)
local EVAL_LIST_OPS = { sprintf = 1, join = 1 }
-- Perl keywords and builtins this interpreter does not do (named in the
-- "unsupported" message rather than reported as unknown functions)
local EVAL_UNSUPPORTED = {
    ['local'] = 'local', our = 'our', sub = 'sub', ['for'] = 'for loop',
    foreach = 'foreach loop', ['while'] = 'while loop', ['until'] = 'until loop',
    ['do'] = 'do block', eval = 'eval', ['return'] = 'return', last = 'last',
    ['next'] = 'next', redo = 'redo', ['goto'] = 'goto', print = 'print',
    printf = 'printf', say = 'say', sort = 'sort', map = 'map', grep = 'grep',
    keys = 'keys', values = 'values', each = 'each', delete = 'delete',
    exists = 'exists', reverse = 'reverse', pop = 'pop', shift = 'shift',
    splice = 'splice', wantarray = 'wantarray', die = 'die', warn = 'warn',
    require = 'require', use = 'use', no = 'no', package = 'package',
    qw = 'qw()', pos = 'pos', lock = 'lock', chomp = 'chomp', chop = 'chop',
    sin = 'sin', cos = 'cos', atan2 = 'atan2', rand = 'rand',
    srand = 'srand', time = 'time', localtime = 'localtime', gmtime = 'gmtime',
    pack = 'pack', unpack = 'unpack', ref = 'ref', bless = 'bless',
    open = 'open', close = 'close', system = 'system', exec = 'exec',
    quotemeta = 'quotemeta',
}
-- binary operators: precedence (higher binds tighter) and associativity
-- ('L'eft, 'R'ight, 'N'on-associative), as in perlop
-- (assignment sits between `not` (3) and ?: (4), the comma operator
--  between `not` and assignment, see perlop)
local EVAL_BIN = {
    ['or'] = { 1, 'L' }, ['xor'] = { 1, 'L' }, ['and'] = { 2, 'L' },
    [','] = { 3.2, 'L' }, ['=>'] = { 3.2, 'L' },
    ['='] = { 3.5, 'R' }, ['.='] = { 3.5, 'R' }, ['+='] = { 3.5, 'R' },
    ['-='] = { 3.5, 'R' }, ['*='] = { 3.5, 'R' }, ['/='] = { 3.5, 'R' },
    ['**='] = { 3.5, 'R' }, ['||='] = { 3.5, 'R' }, ['&&='] = { 3.5, 'R' },
    ['//='] = { 3.5, 'R' },
    ['?'] = { 4, 'R' },
    ['||'] = { 5, 'L' }, ['//'] = { 5, 'L' }, ['&&'] = { 6, 'L' },
    ['|'] = { 6.4, 'L' }, ['^'] = { 6.4, 'L' }, ['&'] = { 6.7, 'L' },
    ['=='] = { 7, 'N' }, ['!='] = { 7, 'N' }, ['<=>'] = { 7, 'N' },
    ['eq'] = { 7, 'N' }, ['ne'] = { 7, 'N' }, ['cmp'] = { 7, 'N' },
    ['<'] = { 8, 'N' }, ['>'] = { 8, 'N' }, ['<='] = { 8, 'N' }, ['>='] = { 8, 'N' },
    ['lt'] = { 8, 'N' }, ['gt'] = { 8, 'N' }, ['le'] = { 8, 'N' }, ['ge'] = { 8, 'N' },
    ['<<'] = { 9.5, 'L' }, ['>>'] = { 9.5, 'L' },
    ['+'] = { 10, 'L' }, ['-'] = { 10, 'L' }, ['.'] = { 10, 'L' },
    ['*'] = { 11, 'L' }, ['/'] = { 11, 'L' }, ['%'] = { 11, 'L' }, ['x'] = { 11, 'L' },
    ['=~'] = { 12, 'L' }, ['!~'] = { 12, 'L' },
    ['**'] = { 14, 'R' },
}
-- (compound assignments: the binary operator they apply)
local EVAL_ASSIGN_OP = { ['.='] = '.', ['+='] = '+', ['-='] = '-', ['*='] = '*', ['/='] = '/',
                         ['**='] = '**', ['||='] = '||', ['&&='] = '&&', ['//='] = '//' }
-- (longest first, so that `**=` is not read as `**` and `=`)
local EVAL_OPS = { '<=>', '**=', '||=', '&&=', '//=', '**', '=~', '!~', '==', '!=', '<=', '>=',
                   '=>', '&&', '||', '//', '->', '++', '--', '.=', '+=', '-=', '*=', '/=',
                   '<<', '>>', '+', '-', '*', '/', '%', '.', '<', '>', '!', '?', ':', '(', ')',
                   ',', ';', '=', '&', '|', '^', '[', ']', '{', '}' }
-- (token kinds after which a '/' is the division operator, not a regex)
local EVAL_TERM_END = { num = 1, str = 1, istr = 1, var = 1, [')'] = 1, [']'] = 1,
                        regex = 1, array = 1 }
local EVAL_CLOSE = { ['('] = ')', ['['] = ']', ['{'] = '}', ['<'] = '>' }
local EVAL_ESC = { n = '\n', t = '\t', r = '\r', ['0'] = '\0', a = '\a', e = '\27', f = '\f' }
local function evalDie(code, pos)
    perl.die('syntax error at (eval 1) line 1, near "' .. ssub(code, pos, pos + 9) .. '"\n')
end
local function evalUnsupported(code, pos, what)
    local near = ssub(code, pos, pos + 19)
    error(setmetatable({ msg = 'Perl syntax unsupported in lexiftool: ' .. what .. ' (near "' ..
                           near .. '") at (eval 1) line 1.\n', unsupported = what }, PerlDie), 0)
end
local function boolVal(b) if b then return 1 end return '' end
local function cmpNum(a, b)
    a, b = perl.num(a), perl.num(b)
    if a < b then return -1 elseif a > b then return 1 end
    return 0
end
local function cmpStr(a, b)
    return perl.cmp(a, b)
end
function perl.eval(code, vars, funcs)
    code = perlStr(code)
    vars = vars or {}
    funcs = funcs or {}
    local pos, n = 1, #code
    local tok, tokVal       -- current token kind and value
    local tokPos            -- where the current token starts
    local lastKind          -- kind of the previous token (regex or division?)
    local lex, declared = {}, {}    -- `my` variables ('@name' for an array)
    local caps = {}         -- $1, $2, ... of the last successful match
    local function unsupported(what, at) evalUnsupported(code, at or tokPos or pos, what) end
    -- tokenizer ...........................................................
    local function skipWs()
        while true do
            pos = smatch(code, '^[ \t\n\r\f\v]*()', pos)
            if ssub(code, pos, pos) ~= '#' then return end
            pos = (sfind(code, '\n', pos, true) or n) + 1
        end
    end
    -- read a delimited part starting after the opening delimiter
    local function delimited(open)
        local close = EVAL_CLOSE[open] or open
        local buf, depth = {}, 0
        while pos <= n do
            local c = ssub(code, pos, pos)
            if c == '\\' and pos < n then
                buf[#buf + 1] = ssub(code, pos, pos + 1)
                pos = pos + 2
            elseif c == close and depth == 0 then
                pos = pos + 1
                return tconcat(buf)
            else
                if open ~= close then
                    if c == open then depth = depth + 1 elseif c == close then depth = depth - 1 end
                end
                buf[#buf + 1] = c
                pos = pos + 1
            end
        end
        evalDie(code, pos)
    end
    -- read the two parts of s/// or tr/// after the operator name (an
    -- escaped delimiter is the plain character; bracketing delimiters have
    -- a second bracketed part, which may follow after whitespace)
    local function twoParts()
        local d = ssub(code, pos, pos)
        pos = pos + 1
        local a, b
        if EVAL_CLOSE[d] then
            a = delimited(d)
            pos = smatch(code, '^[ \t\n\r\f\v]*()', pos)
            local d2 = ssub(code, pos, pos)
            if not EVAL_CLOSE[d2] then evalDie(code, pos) end
            pos = pos + 1
            b = delimited(d2)
        else
            a = delimited(d)
            b = delimited(d)
            local esc = '\\' .. d
            a = sgsub(a, esc:gsub('[!-/:-@[-`{-~]', '%%%0'), function() return d end)
            b = sgsub(b, esc:gsub('[!-/:-@[-`{-~]', '%%%0'), function() return d end)
        end
        local fl = smatch(code, '^[A-Za-z]*', pos)
        pos = pos + #fl
        return a, b, fl
    end
    local function nextTok()
        skipWs()
        lastKind = tok
        tokPos = pos
        if pos > n then tok, tokVal = 'eof', nil return end
        local c = ssub(code, pos, pos)
        -- a regex where a term is expected (after =~ or !~, or at the start
        -- of a statement or operand: not after a term)
        if c == '/' and not EVAL_TERM_END[lastKind] then
            pos = pos + 1
            local re = delimited('/')
            local fl = smatch(code, '^[A-Za-z]*', pos)
            pos = pos + #fl
            tok, tokVal = 'regex', { re, fl }
            return
        end
        local num = smatch(code, '^0[xX]%x+', pos)
        if num then
            pos = pos + #num
            tok, tokVal = 'num', tonumber(ssub(num, 3), 16)
            return
        end
        num = smatch(code, '^%d+%.?%d*[eE][-+]?%d+', pos) or smatch(code, '^%d+%.?%d*', pos) or
              smatch(code, '^%.%d+', pos)
        if num then
            if ssub(num, -1) == '.' and ssub(code, pos + #num, pos + #num) == '.' then
                unsupported('range operator ..')
            end
            pos = pos + #num
            tok, tokVal = 'num', perl.num(num)
            return
        end
        if c == "'" then
            pos = pos + 1
            local str = delimited("'")
            tok, tokVal = 'str', (sgsub(str, "\\([\\'])", '%1'))
            return
        end
        if c == '"' then
            pos = pos + 1
            tok, tokVal = 'istr', delimited('"')
            return
        end
        if c == '$' then
            -- $1, $2, ...: the captures of the last successful match
            local digits = smatch(code, '^%$(%d+)', pos)
            if digits then
                pos = pos + 1 + #digits
                tok, tokVal = 'var', { cap = tonumber(digits) }
                return
            end
            local deref, name = smatch(code, '^%$(%$?)([A-Za-z_][A-Za-z0-9_]*)', pos)
            if not name then
                local what = ssub(code, pos, pos + 1)
                if what == '$#' then unsupported('$#array (last index)') end
                if what == '${' or what == '$$' then unsupported('dereference ' .. what .. '...') end
                unsupported('special variable ' .. what)
            end
            pos = pos + 1 + #deref + #name
            if ssub(code, pos, pos + 1) == '::' then unsupported('package variable') end
            if deref == '' and ssub(code, pos, pos) == '[' then
                -- an array element: the index expression follows
                pos = pos + 1
                tok, tokVal = 'elem', name
                return
            end
            local key
            if ssub(code, pos, pos) == '{' then
                pos = pos + 1
                skipWs()
                local q = ssub(code, pos, pos)
                if q == "'" or q == '"' then
                    pos = pos + 1
                    key = delimited(q)
                else
                    key = smatch(code, '^[A-Za-z0-9_]+', pos)
                    if not key then unsupported('hash subscript with an expression', pos) end
                    pos = pos + #key
                end
                skipWs()
                if ssub(code, pos, pos) ~= '}' then
                    unsupported('hash subscript with an expression', pos)
                end
                pos = pos + 1
                if smatch(code, '^[ \t\n\r\f\v]*[{[]', pos) or smatch(code, '^[ \t\n\r\f\v]*%->[ \t\n\r\f\v]*[{[]', pos) then
                    unsupported('nested data structure')
                end
            elseif deref ~= '' then
                unsupported('dereference $$' .. name)
            end
            tok, tokVal = 'var', { name, key }
            return
        end
        if c == '@' then
            local name = smatch(code, '^@([A-Za-z_][A-Za-z0-9_]*)', pos)
            if not name then unsupported('array expression ' .. ssub(code, pos, pos + 1)) end
            pos = pos + 1 + #name
            if smatch(code, '^[{[]', pos) then unsupported('array slice @' .. name .. ssub(code, pos, pos)) end
            tok, tokVal = 'array', name
            return
        end
        if not EVAL_TERM_END[lastKind] then
            -- (characters that start a term Perl has but this subset lacks)
            if c == '%' and smatch(code, '^%%[A-Za-z_{$]', pos) then unsupported('hash variable %...') end
            if c == '&' then unsupported('&subroutine call') end
            if c == '<' then unsupported('<FILEHANDLE> or glob') end
        end
        if c == '\\' then unsupported('reference \\') end
        if c == '~' then unsupported('~ operator') end
        if c == '`' then unsupported('`command`') end
        local word = smatch(code, '^[A-Za-z_][A-Za-z0-9_]*', pos)
        if word then
            pos = pos + #word
            if ssub(code, pos, pos + 1) == '::' then unsupported('package name ' .. word .. '::') end
            local d = ssub(code, pos, pos)
            if word == 'm' or word == 'qr' then
                if d ~= '' and not smatch(d, '[A-Za-z0-9_ \t\n\r\f\v]') then
                    if word == 'qr' then unsupported('qr// object') end
                    pos = pos + 1
                    local re = delimited(d)
                    local fl = smatch(code, '^[A-Za-z]*', pos)
                    pos = pos + #fl
                    tok, tokVal = 'regex', { re, fl }
                    return
                end
            elseif word == 'q' or word == 'qq' then
                if d ~= '' and not smatch(d, '[A-Za-z0-9_ \t\n\r\f\v=,;)]') then
                    pos = pos + 1
                    local str = delimited(d)
                    if word == 'q' then
                        tok, tokVal = 'str', (sgsub(str, '\\([\\' .. d .. (EVAL_CLOSE[d] or '') .. '])', '%1'))
                    else
                        tok, tokVal = 'istr', str
                    end
                    return
                end
            elseif word == 's' or word == 'tr' or word == 'y' then
                if d ~= '' and not smatch(d, '[A-Za-z0-9_ \t\n\r\f\v=,;)]') then
                    local a, b, fl = twoParts()
                    tok, tokVal = word == 's' and 'subst' or 'trans', { a, b, fl }
                    return
                end
            end
            tok, tokVal = 'word', word
            return
        end
        for _, op in ipairs(EVAL_OPS) do
            if ssub(code, pos, pos + #op - 1) == op then
                pos = pos + #op
                tok, tokVal = op, nil
                return
            end
        end
        unsupported("character '" .. c .. "'")
    end
    -- variables ...........................................................
    -- (the table that holds a variable: the `my` variables, or the caller's)
    local function store(name)
        if declared[name] then return lex end
        return vars
    end
    -- the list value of @name (nil if it does not exist); a caller passes an
    -- array (exiftool's @val) as a plain sequence under its plain name
    local function getArray(name)
        local key = '@' .. name
        local st = store(key)
        local t = st[key]
        if t == nil and st == vars then
            local v = vars[name]
            if type(v) == 'table' and getmetatable(v) == nil and (v[1] ~= nil or next(v) == nil) then
                t = newList({ tunpack(v, 1, #v) }, #v)
                vars[key] = t
            end
        end
        return t
    end
    -- read and write a variable, given its descriptor: { name [, key] } for
    -- a scalar or hash element, { name, idx = fn } for an array element,
    -- { array = name }, { list = { descriptors } } for my (...), and
    -- { cap = N } for $N
    local setVar
    local function getVar(v)
        if v.array then return getArray(v.array) or newList({}, 0) end
        if v.list then
            local out = newList({}, 0, true)
            for _, d in ipairs(v.list) do flatInto(out, getVar(d)) end
            return out
        end
        if v.cap then return caps[v.cap] end
        if v.idx then
            local arr = getArray(v[1])
            if not arr then return nil end
            local i = intVal(sc(v.idx()))
            if i < 0 then i = i + arr.n end
            return arr[i + 1]
        end
        local val = store(v[1])[v[1]]
        if v[2] ~= nil then
            if type(val) ~= 'table' then return nil end
            return val[v[2]]
        end
        return val
    end
    setVar = function(v, val)
        if v.array then
            local out = flatInto(newList({}, 0), val)
            local key = '@' .. v.array
            store(key)[key] = out
            return out
        end
        if v.list then
            local src = flatInto(newList({}, 0), val)
            local i = 0
            for _, d in ipairs(v.list) do
                if d.array then         -- (an array takes the rest)
                    local rest = newList({}, 0)
                    for j = i + 1, src.n do flatInto(rest, src[j]) end
                    setVar(d, rest)
                    i = src.n
                else
                    i = i + 1
                    setVar(d, src[i])
                end
            end
            return newList({}, src.n)   -- (in scalar context: the number of values)
        end
        val = sc(val)
        if v.cap then perl.die('Modification of a read-only value attempted at (eval 1) line 1.\n') end
        if v.idx then
            local key = '@' .. v[1]
            local arr = getArray(v[1])
            if not arr then
                arr = newList({}, 0)
                store(key)[key] = arr
            end
            local i = intVal(sc(v.idx()))
            if i < 0 then i = i + arr.n end
            if i < 0 then perl.die('Modification of non-creatable array value attempted at (eval 1) line 1.\n') end
            arr[i + 1] = val
            if i + 1 > arr.n then arr.n = i + 1 end
            return val
        end
        local st = store(v[1])
        if v[2] ~= nil then
            if type(st[v[1]]) ~= 'table' then st[v[1]] = {} end
            st[v[1]][v[2]] = val
        else
            st[v[1]] = val
        end
        return val
    end
    local lvalues = setmetatable({}, { __mode = 'k' })  -- closure -> variable it reads
    local listForm = setmetatable({}, { __mode = 'k' }) -- closure -> its list-context form
    local function listOf(f) return (listForm[f] or f)() end
    -- double-quoted interpolation
    local function interp(str)
        str = sgsub(str, '\\(.)', function(e)
            if EVAL_ESC[e] then return EVAL_ESC[e] end
            if e == '$' then return '\1' end    -- (an escaped '$' or '@' stays literal)
            if e == '@' then return '\2' end
            return e
        end)
        str = sgsub(str, '%${([A-Za-z_][A-Za-z0-9_]*)}', function(name)
            return perlStr(sc(getVar({ name })))
        end)
        str = sgsub(str, "%$%$?([A-Za-z_][A-Za-z0-9_]*){'([^']*)'}", function(name, key)
            return perlStr(getVar({ name, key }))
        end)
        str = sgsub(str, '%$%$?([A-Za-z_][A-Za-z0-9_]*){([A-Za-z0-9_]*)}', function(name, key)
            return perlStr(getVar({ name, key }))
        end)
        str = sgsub(str, '%$([A-Za-z_][A-Za-z0-9_]*)%[(%-?%d+)%]', function(name, idx)
            return perlStr(getVar({ name, idx = function() return tonumber(idx) end }))
        end)
        str = sgsub(str, '%$(%d+)', function(d) return perlStr(caps[tonumber(d)]) end)
        str = sgsub(str, '%$([A-Za-z_][A-Za-z0-9_]*)', function(name)
            return perlStr(sc(getVar({ name })))
        end)
        str = sgsub(str, '@([A-Za-z_][A-Za-z0-9_]*)', function(name)
            local arr = getArray(name)
            if not arr then return nil end      -- (not an array: stays as it is)
            local list = {}
            for i = 1, arr.n do list[i] = arr[i] == nil and '' or arr[i] end
            return perl.join(' ', list)
        end)
        return (sgsub(sgsub(str, '\1', '$'), '\2', '@'))
    end
    -- parser: each parse function returns a closure that evaluates the node
    local expr
    -- a regex: returns the scalar matcher (true/false, sets $1..) and the
    -- list-context one (the captures, 1 without groups, () on no match;
    -- with /g every match)
    local function regexFn(re, fl)
        if smatch(fl, '[^imsxgo]') then unsupported('regex flag /' .. fl) end
        local global = sfind(fl, 'g', 1, true)
        local mods = sgsub(fl, '[go]', '')
        -- (Perl's /imsx are lpcre's compile flag letters as well; the code
        --  comes from data, so the regex stays outside the pattern cache)
        local ok, rx = pcall(lpcreNew, re, mods .. 'n')
        if not ok then
            perl.die('Invalid regular expression /' .. re .. '/ at (eval 1) line 1.\n')
        end
        local function subject(s)
            s = sc(s)
            if not isCarray(s) then s = perlStr(s) end
            return s
        end
        local function match(s)
            local r = tpack(doIsMatch(rx, subject(s)))
            if not r[1] then return false end
            caps = { tunpack(r, 2, r.n) }
            return true
        end
        local function matchList(s)
            s = subject(s)
            local out = newList({}, 0)
            if global then
                local init = 1
                while init <= #s + 1 do
                    local r = tpack(lpcreFind(s, rx, init))
                    if not r[1] then break end
                    if r.n > 2 then
                        for i = 3, r.n do flatInto(out, r[i]) end
                        caps = { tunpack(r, 3, r.n) }
                    else
                        flatInto(out, ssub(s, r[1], r[2]))
                    end
                    init = r[2] >= r[1] and r[2] + 1 or r[1] + 1
                end
                return out
            end
            local r = tpack(doIsMatch(rx, s))
            if not r[1] then return out end
            if r.n == 1 then return flatInto(out, 1) end
            caps = { tunpack(r, 2, r.n) }
            for i = 2, r.n do flatInto(out, r[i]) end
            return out
        end
        return match, matchList
    end
    -- s/// or tr/// on the variable v: returns a closure that edits it and
    -- yields Perl's value (the number of substitutions/characters, or '')
    local function editFn(kind, parts, v)
        local a, b, fl = parts[1], parts[2], parts[3]
        if kind == 'subst' then
            if smatch(fl, '[^gimsx]') then unsupported('s///' .. sgsub(fl, '[gimsx]', '') .. ' flag') end
            local mods = sgsub(fl, 'g', '')
            local ok, re = pcall(lpcreNew, a, mods .. 'n')
            if not ok then
                perl.die('Invalid regular expression /' .. a .. '/ at (eval 1) line 1.\n')
            end
            local repl = perlRepl(b)
            local global = sfind(fl, 'g', 1, true)
            return function()
                local val = sc(getVar(v))
                if val == nil then return '' end
                -- (a carray is substituted in place, see perl.subst)
                if not isCarray(val) then val = perlStr(val) end
                local new, count = lpcreGsub(val, re, repl, not global and 1 or nil)
                if count > 0 then setVar(v, new) return count end
                return ''
            end
        end
        if smatch(fl, '[^cds]') then unsupported('tr///' .. sgsub(fl, '[cds]', '') .. ' flag') end
        return function()
            local val = sc(getVar(v))
            if val == nil then return 0 end
            local new, count = perl.tr(val, a, b, fl)
            if new ~= perlStr(val) then setVar(v, new) end
            return count
        end
    end
    -- does the current token start a term (an argument without parentheses)?
    local function startsTerm()
        return tok == 'var' or tok == 'num' or tok == 'str' or tok == 'istr' or tok == '(' or
               tok == 'elem' or tok == 'array' or tok == 'regex' or tok == 'subst' or
               tok == 'trans' or (tok == 'word' and not EVAL_BIN[tokVal] and
                                  tokVal ~= 'if' and tokVal ~= 'unless')
    end
    -- the arguments of a call in parentheses (current token '(')
    local function callArgs()
        local args = {}
        nextTok()
        while tok ~= ')' do
            args[#args + 1] = expr(3.5)     -- (above the comma operator)
            if tok == ',' or tok == '=>' then
                nextTok()
            elseif tok ~= ')' then
                evalDie(code, pos)
            end
        end
        nextTok()
        return args
    end
    -- the flattened values of argument closures (list context)
    local function flatArgs(args)
        local a = newList({}, 0)
        for i = 1, #args do flatInto(a, listOf(args[i])) end
        return a
    end
    -- split /RE/, EXPR, LIMIT (current token: the word split)
    local function parseSplit()
        nextTok()
        local paren = tok == '('
        if paren then nextTok() end
        local rxPat, patFn, strFn, limFn
        if tok == 'regex' then
            local re, fl = tokVal[1], tokVal[2]
            if smatch(fl, '[^imsx]') then unsupported('split flag /' .. fl) end
            -- (/ / is a single space; only the string ' ' is the awk mode)
            if re == ' ' then re = '[ ]' end
            rxPat = (fl ~= '' and '(?' .. fl .. ')' or '') .. re
            nextTok()
        else
            patFn = expr(3.5)
        end
        if tok == ',' then
            nextTok()
            strFn = expr(3.5)
            if tok == ',' then
                nextTok()
                limFn = expr(3.5)
            end
        end
        if paren then
            if tok ~= ')' then evalDie(code, pos) end
            nextTok()
        end
        return function()
            local s
            if strFn then s = sc(strFn()) else s = getVar({ '_' }) end
            local pat = rxPat or perlStr(sc(patFn()))
            local lim = limFn and intVal(sc(limFn())) or nil
            local t = perl.splitDyn(pat, perlStr(s), lim)
            return newList(t, #t)
        end
    end
    -- push/unshift @array, LIST (current token: the word)
    local function parsePush(name)
        nextTok()
        local paren = tok == '('
        if paren then nextTok() end
        if tok ~= 'array' then unsupported(name .. ' on an array expression') end
        local d = { array = tokVal }
        nextTok()
        local args = {}
        while tok == ',' do
            nextTok()
            args[#args + 1] = expr(3.5)
        end
        if paren then
            if tok ~= ')' then evalDie(code, pos) end
            nextTok()
        end
        return function()
            local arr, items = getVar(d), flatArgs(args)
            local new = newList({}, 0)
            if name == 'unshift' then
                flatInto(new, items)
                flatInto(new, arr)
            else
                flatInto(new, arr)
                flatInto(new, items)
            end
            setVar(d, new)
            return new.n
        end
    end
    -- my $x, my @a, my ($x, @a) (current token: the word my)
    local function parseMy()
        nextTok()
        local function decl()
            if tok == 'var' and tokVal[1] and tokVal[2] == nil and not tokVal.cap then
                local name = tokVal[1]
                declared[name] = true
                nextTok()
                return { name }
            elseif tok == 'array' then
                local name = tokVal
                declared['@' .. name] = true
                nextTok()
                return { array = name }
            end
            unsupported('this kind of my declaration')
        end
        local d
        if tok == '(' then
            nextTok()
            local list = {}
            while tok ~= ')' do
                list[#list + 1] = decl()
                if tok == ',' then
                    nextTok()
                elseif tok ~= ')' then
                    evalDie(code, pos)
                end
            end
            nextTok()
            d = { list = list }
        else
            d = decl()
        end
        local function reset(v)
            if v.list then
                for _, e in ipairs(v.list) do reset(e) end
            elseif v.array then
                lex['@' .. v.array] = newList({}, 0)
            else
                lex[v[1]] = nil
            end
        end
        -- (a fresh variable each time the declaration runs)
        local f = function() reset(d) return getVar(d) end
        lvalues[f] = d
        return f
    end
    -- method calls on the value of closure f: f->Name(ARGS)->...
    local function methodCalls(f)
        while tok == '->' do
            nextTok()
            if tok ~= 'word' then
                unsupported('dereference ->' .. (tok == '{' and '{...}' or tok == '[' and '[...]' or
                                                 tostring(tok)))
            end
            local meth, obj = tokVal, f
            nextTok()
            local args = {}
            if tok == '(' then args = callArgs() end
            f = function()
                local o = sc(obj())
                local m = type(o) == 'table' and o[meth]
                if type(m) ~= 'function' then
                    perl.die('Can\'t locate object method "' .. meth .. '" at (eval 1) line 1.\n')
                end
                local a = flatArgs(args)
                return (m(o, tunpack(a, 1, a.n)))
            end
        end
        return f
    end
    local function primary()
        local t, v = tok, tokVal
        if t == 'num' or t == 'str' then
            nextTok()
            return function() return v end
        elseif t == 'istr' then
            nextTok()
            return function() return interp(v) end
        elseif t == 'var' then
            nextTok()
            local f = function() return getVar(v) end
            lvalues[f] = v
            if tok == '->' then return methodCalls(f) end
            return f
        elseif t == 'elem' then
            nextTok()
            local idx = expr(0)
            if tok ~= ']' then evalDie(code, pos) end
            nextTok()
            local d = { v, idx = idx }
            local f = function() return getVar(d) end
            lvalues[f] = d
            return f
        elseif t == 'array' then
            nextTok()
            local d = { array = v }
            local f = function() return getVar(d) end
            lvalues[f] = d
            return f
        elseif t == 'subst' or t == 'trans' then
            nextTok()
            return editFn(t, v, { '_' })
        elseif t == 'word' and v == 'undef' then
            nextTok()
            if tok == '(' then
                nextTok()
                if tok ~= ')' then unsupported('undef(EXPR)') end
                nextTok()
            end
            return function() return nil end
        elseif t == 'word' and v == 'my' then
            return parseMy()
        elseif t == 'word' and v == 'split' and not funcs.split then
            return parseSplit()
        elseif t == 'word' and (v == 'push' or v == 'unshift') and not funcs[v] then
            return parsePush(v)
        elseif t == 'regex' then
            -- a bare /re/ matches $_
            nextTok()
            local m, ml = regexFn(v[1], v[2])
            local f = function() return boolVal(m(getVar({ '_' }))) end
            listForm[f] = function() return ml(getVar({ '_' })) end
            return f
        elseif t == '(' then
            nextTok()
            if tok == ')' then
                nextTok()
                return function() return newList({}, 0, true) end
            end
            local e = expr(0)
            if tok ~= ')' then evalDie(code, pos) end
            nextTok()
            return e
        elseif t == 'word' then
            local fn = funcs[v] or EVAL_FUNCS[v]
            if not fn then
                if EVAL_UNSUPPORTED[v] then unsupported(EVAL_UNSUPPORTED[v]) end
                if v == 'if' or v == 'unless' or v == 'else' or v == 'elsif' then evalDie(code, pos) end
                unsupported('function ' .. v .. '()')
            end
            nextTok()
            local isList = EVAL_LIST_OPS[v] or funcs[v] ~= nil
            local args = {}
            if tok == '(' then
                args = callArgs()
            elseif EVAL_NAMED_UNARY[v] and startsTerm() then
                args[1] = expr(9)
            elseif isList and startsTerm() then
                -- (a list operator without parentheses takes everything up
                --  to the next low-precedence operator)
                args[1] = expr(3.5)
                while tok == ',' or tok == '=>' do
                    nextTok()
                    args[#args + 1] = expr(3.5)
                end
            end
            local unaryDefault = EVAL_NAMED_UNARY[v] and #args == 0
            return function()
                if unaryDefault then return fn(sc(getVar({ '_' }))) end   -- ($_ by default)
                if isList then
                    local a = flatArgs(args)
                    return fn(tunpack(a, 1, a.n))
                end
                local a = {}
                for i = 1, #args do a[i] = sc(args[i]()) end
                return fn(tunpack(a, 1, #args))
            end
        elseif t == '{' then
            unsupported('anonymous hash {...}')
        elseif t == '[' then
            unsupported('anonymous array [...]')
        end
        evalDie(code, pos)
    end
    -- ++/-- on the variable behind closure e (prefix: the new value,
    -- postfix: the old one; ++ on a non-numeric string is Perl's magic
    -- increment)
    local function incDec(op, e, prefix)
        local v = lvalues[e]
        if not v then unsupported(op .. ' on an expression') end
        return function()
            local old = sc(getVar(v))
            local new
            if op == '++' then
                new = type(old) == 'string' and old ~= '' and not smatch(old, '^[ \t\n\r\f\v]*[-+]?[%d.]') and
                      perl.increment(old) or perl.num(old) + 1
            else
                new = perl.num(old) - 1
            end
            setVar(v, new)
            if prefix then return new end
            return old == nil and (op == '++' and 0 or nil) or old
        end
    end
    local function unary()
        if tok == '!' then
            nextTok()
            local e = unary()
            return function() return boolVal(not perl.truthy(sc(e()))) end
        elseif tok == '-' then
            nextTok()
            local e = unary()
            return function() return -perl.num(sc(e())) end
        elseif tok == '+' then
            nextTok()
            return unary()
        elseif tok == '++' or tok == '--' then
            local op = tok
            nextTok()
            return incDec(op, unary(), true)
        elseif tok == 'word' and tokVal == 'not' then
            nextTok()
            local e = expr(3)
            return function() return boolVal(not perl.truthy(sc(e()))) end
        end
        local p = primary()
        if tok == '++' or tok == '--' then
            local op = tok
            nextTok()
            return incDec(op, p, false)
        end
        return p
    end
    local function binary(op, l0, r0)
        if op == ',' or op == '=>' then
            return function()
                local out = newList({}, 0, true)
                flatInto(out, listOf(l0))
                flatInto(out, listOf(r0))
                return out
            end
        end
        local function l() return sc(l0()) end
        local function r() return sc(r0()) end
        if op == 'or' or op == '||' then
            return function() local v = l() if perl.truthy(v) then return v end return r() end
        elseif op == 'and' or op == '&&' then
            return function() local v = l() if not perl.truthy(v) then return v end return r() end
        elseif op == '//' then
            return function() local v = l() if v ~= nil then return v end return r() end
        elseif op == 'xor' then
            return function() return boolVal(perl.truthy(l()) ~= perl.truthy(r())) end
        elseif op == '==' then return function() return boolVal(cmpNum(l(), r()) == 0) end
        elseif op == '!=' then return function() return boolVal(cmpNum(l(), r()) ~= 0) end
        elseif op == '<=>' then return function() return cmpNum(l(), r()) end
        elseif op == '<' then return function() return boolVal(cmpNum(l(), r()) < 0) end
        elseif op == '>' then return function() return boolVal(cmpNum(l(), r()) > 0) end
        elseif op == '<=' then return function() return boolVal(cmpNum(l(), r()) <= 0) end
        elseif op == '>=' then return function() return boolVal(cmpNum(l(), r()) >= 0) end
        elseif op == 'eq' then return function() return boolVal(cmpStr(l(), r()) == 0) end
        elseif op == 'ne' then return function() return boolVal(cmpStr(l(), r()) ~= 0) end
        elseif op == 'cmp' then return function() return cmpStr(l(), r()) end
        elseif op == 'lt' then return function() return boolVal(cmpStr(l(), r()) < 0) end
        elseif op == 'gt' then return function() return boolVal(cmpStr(l(), r()) > 0) end
        elseif op == 'le' then return function() return boolVal(cmpStr(l(), r()) <= 0) end
        elseif op == 'ge' then return function() return boolVal(cmpStr(l(), r()) >= 0) end
        elseif op == '+' then return function() return perl.num(l()) + perl.num(r()) end
        elseif op == '-' then return function() return perl.num(l()) - perl.num(r()) end
        elseif op == '*' then return function() return perl.num(l()) * perl.num(r()) end
        elseif op == '/' then
            return function()
                local a = perl.num(l())
                local d = perl.num(r())
                if d == 0 then perl.die('Illegal division by zero at (eval 1) line 1.\n') end
                return a / d
            end
        elseif op == '%' then
            return function()
                local a = perl.int(l())
                local d = perl.int(r())
                if d == 0 then perl.die('Illegal modulus zero at (eval 1) line 1.\n') end
                return a % d
            end
        elseif op == '**' then return function() return perl.num(l()) ^ perl.num(r()) end
        elseif op == '.' then return function() return perlStr(l()) .. perlStr(r()) end
        elseif op == '&' then return function() return intVal(l()) & intVal(r()) end
        elseif op == '|' then return function() return intVal(l()) | intVal(r()) end
        elseif op == '^' then return function() return intVal(l()) ~ intVal(r()) end
        elseif op == '<<' then return function() return intVal(l()) << intVal(r()) end
        elseif op == '>>' then return function() return intVal(l()) >> intVal(r()) end
        end
        -- (op == 'x')
        return function() return srep(perlStr(l()), perl.int(r())) end
    end
    expr = function(minPrec)
        local left = unary()
        while true do
            local op = tok
            if op == 'word' then op = tokVal end
            local info = EVAL_BIN[op]
            if not info or info[1] < minPrec then break end
            local prec, assoc = info[1], info[2]
            nextTok()
            local l = left
            if (op == ',' or op == '=>') and (tok == ')' or tok == ';' or tok == 'eof' or tok == ']') then
                -- (a trailing comma)
                left = binary(',', l, function() return newList({}, 0, true) end)
            elseif op == '?' then
                local a = expr(3.5)     -- (the middle operand may be an assignment)
                if tok ~= ':' then evalDie(code, pos) end
                nextTok()
                local b = expr(4)
                left = function() if perl.truthy(sc(l())) then return a() end return b() end
            elseif op == '=' then
                local v = lvalues[l]
                if not v then unsupported('assignment to an expression') end
                local r = expr(prec)
                if v.array or v.list then
                    left = function() return setVar(v, listOf(r)) end
                else
                    left = function() return setVar(v, r()) end
                end
            elseif EVAL_ASSIGN_OP[op] then
                local v = lvalues[l]
                if not v or v.array or v.list then unsupported(op .. ' on this kind of target') end
                local apply = binary(EVAL_ASSIGN_OP[op], function() return getVar(v) end, expr(prec))
                left = function() return setVar(v, apply()) end
            elseif (op == '=~' or op == '!~') and (tok == 'subst' or tok == 'trans') then
                local v = lvalues[l]
                if not v then unsupported(op .. ' s/// or tr/// on an expression') end
                if op == '!~' then evalDie(code, pos) end
                local kind, parts = tok, tokVal
                nextTok()
                left = editFn(kind, parts, v)
            elseif op == '=~' or op == '!~' then
                if tok ~= 'regex' then unsupported(op .. ' with a pattern expression') end
                local m, ml = regexFn(tokVal[1], tokVal[2])
                nextTok()
                local neg = op == '!~'
                left = function()
                    local r = m(l())
                    if neg then r = not r end
                    return boolVal(r)
                end
                if not neg then listForm[left] = function() return ml(l()) end end
            else
                left = binary(op, l, expr(assoc == 'R' and prec or prec + 1))
            end
            if assoc == 'N' then
                local o2 = tok == 'word' and tokVal or tok
                if EVAL_BIN[o2] and EVAL_BIN[o2][1] == prec then evalDie(code, pos) end
            end
        end
        return left
    end
    -- statements: EXPR [if COND | unless COND], the block forms of if/unless
    -- and bare blocks, separated by ';'
    local statements
    local function block()
        if tok ~= '{' then evalDie(code, pos) end
        nextTok()
        local stmts = statements('}')
        nextTok()
        return function()
            local r
            for k = 1, #stmts do r = stmts[k]() end
            return r
        end
    end
    local function condition()
        if tok ~= '(' then evalDie(code, pos) end
        nextTok()
        local c = expr(0)
        if tok ~= ')' then evalDie(code, pos) end
        nextTok()
        return c
    end
    local function statement()
        if tok == 'word' and (tokVal == 'if' or tokVal == 'unless') then
            local neg = tokVal == 'unless'
            nextTok()
            local conds, bodies = { condition() }, {}
            bodies[1] = block()
            while tok == 'word' and tokVal == 'elsif' do
                nextTok()
                conds[#conds + 1] = condition()
                bodies[#bodies + 1] = block()
            end
            local elseBody
            if tok == 'word' and tokVal == 'else' then
                nextTok()
                elseBody = block()
            end
            return function()
                local r
                for k = 1, #conds do
                    r = sc(conds[k]())
                    if perl.truthy(r) ~= (k == 1 and neg) then return bodies[k]() end
                end
                if elseBody then return elseBody() end
                return r
            end, true
        elseif tok == '{' then
            return block(), true
        end
        local e = expr(0)
        if tok == 'word' and (tokVal == 'if' or tokVal == 'unless') then
            local neg = tokVal == 'unless'
            nextTok()
            local c, body = expr(0), e
            e = function()
                local r = sc(c())
                if perl.truthy(r) ~= neg then return body() end
                return r
            end
        elseif tok == 'word' and (tokVal == 'for' or tokVal == 'foreach' or tokVal == 'while' or
                                  tokVal == 'until') then
            unsupported('statement modifier ' .. tokVal)
        end
        return e, false
    end
    statements = function(endTok)
        local stmts = {}
        while true do
            while tok == ';' do nextTok() end
            if tok == endTok then break end
            if tok == 'eof' then evalDie(code, pos) end
            local e, isBlock = statement()
            stmts[#stmts + 1] = e
            if not isBlock and tok ~= ';' and tok ~= endTok then
                if tok == 'word' or tok == 'var' or tok == '{' then evalDie(code, tokPos) end
                evalDie(code, pos)
            end
        end
        return stmts
    end
    nextTok()
    local stmts = statements('eof')
    local rtn
    for k = 1, #stmts do rtn = stmts[k]() end
    return sc(rtn)
end

return perl
