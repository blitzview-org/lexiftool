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

-- The reference values perl.eval makes (see there): an array reference is
-- { arr = ARRAY } with the metatable ARef (ARRAY: the array itself), a hash
-- the code builds ({...}, `my %h`) carries the metatable PerlHash, so that
-- an empty one is still a HASH for perl.ref.
local ARef = {}
local PerlHash = {}
-- (a reference to an array or hash element, `\$h{key}`: the port's SCALAR
--  reference box { ref = 'SCALAR', value = ... }, whose value is the
--  element's -- read and written through c[k])
local ElemRef = {
    __index = function(t, key)
        if key == 'value' then return rawget(t, 'c')[rawget(t, 'k')] end
        return nil
    end,
    __newindex = function(t, key, v)
        if key ~= 'value' then return rawset(t, key, v) end
        local c, k = rawget(t, 'c'), rawget(t, 'k')
        c[k] = v
        if math.type(k) == 'integer' and type(rawget(c, 'n')) == 'number' and k > c.n then c.n = k end
    end,
}

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
    -- a number interpolated into a pattern (`/$noWarn/` with NoWarning set
    -- to 1) is its string form, as Perl stringifies it
    if type(pat) == 'number' then pat = perl.str(pat) end
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
    ['>>'] = 'right bitshift (>>)',  ['x'] = 'repeat (x)',
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
    if t == 'table' then
        local mt = getmetatable(v)
        local kind
        if (mt == nil or mt == ElemRef) and rawget(v, 'ref') == 'SCALAR' then
            kind = 'SCALAR'
        elseif mt == ARef then
            -- (an array reference shows the address of the array)
            kind, v = 'ARRAY', v.arr
        elseif mt == PerlHash then
            kind = 'HASH'
        end
        if kind then
            local addr = smatch(tostring(v), '(%x+)$') or '0'
            return kind .. '(0x' .. asciiLower(smatch(addr, '^0*(.-.)$')) .. ')'
        end
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
-- Perl's " at (eval) line 1." tail (which CleanWarning strips again) -- while
-- perl.eval runs user code, " at (eval 1) line 1." as Perl's eval of a string
-- says (exiftool's -if strips it as `s/ at \(eval .*//s`).  Calls the
-- __WARN__ handler if one is set, prints to stderr otherwise.  Returns 1
-- like Perl, so `warn(...) and return undef` reads the same.
local warnAt = ' at (eval) line 1.\n'
-- (set while perl.eval folds a constant expression: a function that takes
--  the warning instead of the handler, see fold in perl.eval)
local warnTrap
function perl.warn(...)
    local args = { ... }
    for i = 1, #args do args[i] = perl.str(args[i]) end
    local msg = table.concat(args)
    if msg == '' then msg = "Warning: something's wrong" end
    if msg:sub(-1) ~= '\n' then msg = msg .. warnAt end
    if warnTrap then
        warnTrap(msg)
        return 1
    end
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
-- calendar arithmetic behind Time::Piece's normalisation below (gmtime is
-- time64.c's own, timegm/timelocal use Time::Local's formula), which must
-- not go through os.time/os.date: those follow the local zone and reject
-- dates outside the platform's time_t range.
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

-- Time::Local (version 1.35, the module Perl ships; exiftool calls its
-- timegm and timelocal) -- module state, computed when the module loads,
-- and its private subs (one table: perl.lua is at Lua's limit of locals).
local TL = { }
TL.MonthDays = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

-- Determine breakpoint for rolling century
TL.ThisYear = os.date('*t').year - 1900
TL.Breakpoint = (TL.ThisYear + 50) % 100
TL.NextCentury = TL.ThisYear - TL.ThisYear % 100
if TL.Breakpoint < 50 then TL.NextCentury = TL.NextCentury + 100 end
TL.Century = TL.NextCentury - 100
TL.SecOff = 0

-- recent localtime()'s limit is the year 2**31 ($MaxDay = 365 * (2**31))
TL.MaxDay = 365 * 2147483648

-- %Cheat: the month-start cache of _daygm. Like the original it is keyed by
-- pack('ss', $month, $year) -- both truncated to signed 16 bits, so two
-- years 65536 apart share an entry and the later one reuses the earlier
-- one's value -- and refilled whenever the cached value is 0 (`||=`).
TL.Cheat = { }
TL.Epoc = 0

-- pack('s', $v): the integer value truncated to a signed 16-bit short
function TL.short(v)
    local n = perl.int(perl.num(v))
    if mtype(n) ~= 'integer' then n = math.tointeger(n) or 0 end
    return ((n + 32768) & 0xffff) - 32768
end

-- _daygm($_[3], $_[4], $_[5]): days since the epoch for mday/month/year
-- (year as an offset from 1900); Perl's int() truncates toward zero, also
-- for the years before 0 the formula reaches
function TL.daygm(mday, month, year)
    local key = TL.short(month) * 65536 + TL.short(year)
    local days = TL.Cheat[key]
    if not days or days == 0 then
        local m = perl.int(perl.num(month) + 10) % 12
        local y = perl.num(year) + 1900 - perl.int(m / 10)
        days = ((365 * y)
            + perl.int(y / 4)
            - perl.int(y / 100)
            + perl.int(y / 400)
            + perl.int(((m * 306) + 5) / 10))
            - TL.Epoc
        TL.Cheat[key] = days
    end
    return perl.num(mday) + days
end

-- Determine the EPOC day for this machine ($Epoc = _daygm(gmtime(0))),
-- then clear the cache as epoc has changed
TL.Epoc = TL.daygm(1, 0, 70)
TL.Cheat = { }

-- this file's chunk name, which TL.croak skips like Carp skips Time::Local
TL.SOURCE = debug.getinfo(1, 'S').source

-- Carp::croak() as Time::Local calls it: a Perl die whose message ends in
-- " at FILE line N.\n", naming the first caller outside the module (here:
-- outside this file), so the eval around a conversion catches it like
-- Perl's and CleanWarning reduces it to the bare text.
function TL.croak(msg)
    local level = 3
    local info = debug.getinfo(level, 'Sl')
    while info and (info.source == TL.SOURCE or info.what == 'C') do
        level = level + 1
        info = debug.getinfo(level, 'Sl')
    end
    info = info or { source = '=?', currentline = 0 }
    perl.die(msg .. ' at ' .. info.source:sub(2) .. ' line ' .. info.currentline .. '.\n')
end

-- Leap-year test of Time::Local (_is_leap_year)
function TL.isLeapYear(y)
    y = perl.int(y)
    if y % 4 ~= 0 then return false end
    if y % 100 ~= 0 then return true end
    if y % 400 ~= 0 then return false end
    return true
end

-- Time::Local::timegm($sec,$min,$hour,$mday,$mon,$year), line for line -
-- Unix time for a UTC date. $mon is 0-based; a year of 1000 or more is the
-- full year, 0..99 a two-digit year in the rolling century window, anything
-- else an offset from 1900. The arguments may be strings, as Perl's regex
-- captures are: they are compared numerically, and a croak quotes them as
-- given ("Day '00' out of range 1..31"). Out-of-range values croak (month
-- 0..11, day 1..days in that month, hour 0..23, minute 0..59, second
-- 0..59 after int()), and so does a day count beyond $MaxDay; fractional
-- seconds survive.
function perl.timegm(sec, min, hour, mday, month, year)
    local nsec = perl.num(sec)
    local subsec = nsec - perl.int(nsec)
    sec = perl.int(nsec)
    year = perl.num(year)

    if year >= 1000 then
        year = year - 1900
    elseif year < 100 and year >= 0 then
        year = year + ((year > TL.Breakpoint) and TL.Century or TL.NextCentury)
    end

    local nmon, nmday = perl.num(month), perl.num(mday)
    local nhour, nmin = perl.num(hour), perl.num(min)
    if nmon > 11 or nmon < 0 then
        TL.croak("Month '" .. perl.str(month) .. "' out of range 0..11")
    end
    local md = TL.MonthDays[perl.int(nmon) + 1]
    if nmon == 1 and TL.isLeapYear(year + 1900) then md = md + 1 end
    if nmday > md or nmday < 1 then
        TL.croak("Day '" .. perl.str(mday) .. "' out of range 1.." .. md)
    end
    if nhour > 23 or nhour < 0 then
        TL.croak("Hour '" .. perl.str(hour) .. "' out of range 0..23")
    end
    if nmin > 59 or nmin < 0 then
        TL.croak("Minute '" .. perl.str(min) .. "' out of range 0..59")
    end
    if sec >= 60 or sec < 0 then
        TL.croak("Second '" .. perl.str(sec) .. "' out of range 0..59")
    end

    local days = TL.daygm(mday, month, year)

    if math.abs(days) > TL.MaxDay then
        local msg = 'Day too big - abs(' .. perl.str(days) .. ') > ' .. perl.str(TL.MaxDay) .. '\n'
        year = year + 1900
        msg = msg .. 'Cannot handle date (' .. perl.str(sec) .. ', ' .. perl.str(min) .. ', ' ..
            perl.str(hour) .. ', ' .. perl.str(mday) .. ', ' .. perl.str(month) .. ', ' ..
            perl.str(year) .. ')'
        TL.croak(msg)
    end

    -- Adding in the $subsec value last seems to prevent floating point errors
    -- from creeping in.
    return (sec + TL.SecOff + (60 * nmin) + (3600 * nhour) + (86400 * days)) + subsec
end

-- Time::Local's _timegm(localtime($t)): the local wall-clock time of $t read
-- back as if it were UTC (no munging, no checks; the same month cache).
function TL.localAsGm(t)
    local lt = perl.localtime(t)
    return TL.SecOff + lt[1] + 60 * lt[2] + 3600 * lt[3] + 86400 * TL.daygm(lt[4], lt[5], lt[6])
end

-- Time::Local::timelocal($sec,$min,$hour,$mday,$mon,$year) (Time::Local
-- 1.35, line for line) - Unix time for a local date. $mon is 0-based; a
-- year of 1000 or more is the full year, 0..99 a two-digit year in
-- Time::Local's rolling century window, anything else an offset from 1900.
-- DST is resolved through localtime() round trips like the original does
-- (a time in a DST gap moves forward, an ambiguous one takes the earlier
-- (DST) instant); fractional seconds survive. The range checks and their
-- croak are perl.timegm's, reported for the caller of perl.timelocal.
function perl.timelocal(sec, min, hour, mday, mon, year)
    local nsec = perl.num(sec)
    local subsec = nsec - perl.int(nsec)
    sec = perl.int(nsec)
    local ref_t = perl.timegm(sec, min, hour, mday, mon, year)
    local loc_for_ref_t = TL.localAsGm(ref_t)
    local zone_off = loc_for_ref_t - ref_t
    if zone_off == 0 then return loc_for_ref_t + subsec end
    -- Adjust for timezone
    local loc_t = ref_t - zone_off
    -- Are we close to a DST change or are we done
    local dst_off = ref_t - TL.localAsGm(loc_t)
    -- If this evaluates to true, it means that the value in $loc_t is
    -- the _second_ hour after a DST change where the local time moves
    -- backward.
    if dst_off == 0 and ((ref_t - 3600) - TL.localAsGm(loc_t - 3600) < 0) then
        return (loc_t - 3600) + subsec
    end
    -- Adjust for DST change
    loc_t = loc_t + dst_off
    if dst_off > 0 then return loc_t + subsec end
    -- If the original date was a non-existent gap in a forward DST jump, we
    -- should now have the wrong answer - undo the DST adjustment
    local lt = perl.localtime(loc_t)
    if lt[1] ~= sec or lt[2] ~= perl.num(min) or lt[3] ~= perl.num(hour) then loc_t = loc_t - dst_off end
    return loc_t + subsec
end

-- Perl's own gmtime/localtime (time64.c and pp_sys.c's pp_gmtime of Perl
-- 5.42, in use since Perl 5.12), ported line for line, so that both give
-- Perl's result for any time and on every platform -- where Lua's os.date
-- fails for times its C library rejects (on Windows everything before 1970
-- and after the year 3000).
--  - pp_gmtime floors the argument (an NV), and gives the empty list for
--    NaN and for times beyond its bounds (TIME_LOWER_BOUND/UPPER_BOUND, the
--    years -2147481748 and 2147483647). Its "gmtime(...) too large/small/
--    failed" warnings are WARN_OVERFLOW ones, emitted only where warnings
--    are enabled: no caller in the port has them (the library has no
--    `use warnings`, and the exiftool script, which has, calls neither),
--    so none are emitted here.
--  - gmtime is time64.c's own calendar arithmetic (Perl_gmtime64_r; Perl
--    never uses the system's gmtime outside VMS), in doubles as there.
--  - localtime (Perl_localtime64_r) uses the system localtime within
--    LOCALTIME_MIN..LOCALTIME_MAX, the range Perl's build found the
--    system's localtime to handle (config.h, see T64.SYSTEM_LOCALTIME
--    below). Outside it, the UTC date's year is mapped to a "safe year"
--    in 2010..2037 with the same calendar (leap year, weekday of January
--    1st, and the neighbouring years' too), the system localtime is taken
--    there, and the year is shifted back -- so the zone rules of the safe
--    year apply, as in Perl. Here the system localtime is os.date('*t');
--    if it fails, the result is the empty list, as Perl's is.
-- (one table: perl.lua is at Lua's limit of locals)
local T64 = {}
T64.days_in_month = {
    { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 },
    { 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 },
}
T64.julian_days_by_month = {
    { 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334 },
    { 0, 31, 60, 91, 121, 152, 182, 213, 244, 274, 305, 335 },
}
T64.length_of_year = { 365, 366 }
-- Number of days in a 400 year Gregorian cycle
T64.years_in_gregorian_cycle = 400
T64.days_in_gregorian_cycle = (365 * 400) + 100 - 4 + 1
-- 28 year calendar cycle between 2010 and 2037
T64.SOLAR_CYCLE_LENGTH = 28
T64.safe_years = {
    2016, 2017, 2018, 2019,
    2020, 2021, 2022, 2023,
    2024, 2025, 2026, 2027,
    2028, 2029, 2030, 2031,
    2032, 2033, 2034, 2035,
    2036, 2037, 2010, 2011,
    2012, 2013, 2014, 2015,
}
-- Number of days since epoch on Jan 1st, 2008 GMT
T64.CHEAT_DAYS = 1199145600 // 24 // 60 // 60
T64.CHEAT_YEARS = 108
-- (pp_sys.c) The 32 bit int year limits the times we can represent to these
-- boundaries with a few days wiggle room to account for time zone offsets
T64.TIME_LOWER_BOUND = -67768100567755200.0    -- Sat Jan  3 00:00:00 -2147481748
T64.TIME_UPPER_BOUND = 67767976233316800.0     -- Sun Dec 29 12:00:00  2147483647

-- SYSTEM_LOCALTIME_MIN/MAX (time64_config.h): LOCALTIME_MIN/MAX of Perl's
-- config.h, which Configure probes on the build machine (the smallest and
-- largest time_t whose localtime() is not NULL, with a tm_year in
-- -1900..INT_MAX, i.e. from the year 0 on), and which win32/config.gc and
-- config.vc fix for the Windows builds:
--   POSIX (64-bit time_t: glibc, macOS, Cygwin): -62167219200 (0000-01-01
--     00:00:00 UTC) .. 67768036191676799 (the end of the year 2147485547),
--     above TIME_UPPER_BOUND, so only the lower limit is ever reached;
--   MSWin32: 0 .. 2147483647 (2038-01-19 03:14:07 UTC), the values of
--     config.gc, i.e. of the gcc build Strawberry Perl is (config_sh.PL
--     raises the maximum to 32535244799 only for an MSVC-built perl).
-- perl.localtimeSystemRange(min, max) replaces them (for tests: to take the
-- safe-year path on a POSIX system as Perl on Windows takes it).
if sys.platform() == 'MSWin32' then
    T64.SYSTEM_LOCALTIME_MIN, T64.SYSTEM_LOCALTIME_MAX = 0.0, 2147483647.0
else
    T64.SYSTEM_LOCALTIME_MIN, T64.SYSTEM_LOCALTIME_MAX = -62167219200.0, 67768036191676799.0
end
function perl.localtimeSystemRange(min, max)
    local oldMin, oldMax = T64.SYSTEM_LOCALTIME_MIN, T64.SYSTEM_LOCALTIME_MAX
    if min ~= nil then T64.SYSTEM_LOCALTIME_MIN, T64.SYSTEM_LOCALTIME_MAX = min + 0.0, max + 0.0 end
    return oldMin, oldMax
end

-- C's int arithmetic on the 32-bit Year (two's-complement wraparound) and
-- the (int) cast of a double (truncation toward zero)
function T64.i32(v)
    return ((v + 0x80000000) & 0xffffffff) - 0x80000000
end
function T64.int(x)
    return mtointeger(x >= 0 and mfloor(x) or math.ceil(x))
end
-- C's integer division (truncates toward zero)
function T64.div(a, b)
    local q = a // b
    if q < 0 and q * b ~= a then q = q + 1 end
    return q
end

-- IS_LEAP(n): n is a tm_year (years since 1900); 1 for a leap year, else 0
function T64.IS_LEAP(n)
    local y = n + 1900
    return ((y % 400 == 0) or (y % 4 == 0 and y % 100 ~= 0)) and 1 or 0
end

function T64.is_exception_century(year)
    return (year % 100 == 0) and (year % 400 ~= 0)
end

-- S_timegm64: seconds since the epoch for a broken-down UTC date (only the
-- year, mon, mday, hour, min and sec fields; tm_year since 1900)
function T64.timegm64(date)
    local days = 0
    local length_of_year = T64.length_of_year
    if date.tm_year > 70 then
        local year = 70
        while year < date.tm_year do
            days = days + length_of_year[T64.IS_LEAP(year) + 1]
            year = year + 1
        end
    elseif date.tm_year < 70 then
        local year = 69
        repeat
            days = days - length_of_year[T64.IS_LEAP(year) + 1]
            year = year - 1
        until year < date.tm_year
    end

    days = days + T64.julian_days_by_month[T64.IS_LEAP(date.tm_year) + 1][date.tm_mon + 1]
    days = days + date.tm_mday - 1

    -- Avoid overflowing the days integer
    local seconds = days + 0.0
    seconds = seconds * 60 * 60 * 24

    seconds = seconds + date.tm_hour * 60 * 60
    seconds = seconds + date.tm_min * 60
    seconds = seconds + date.tm_sec

    return seconds
end

-- The exceptional centuries without leap years cause the cycle to
-- shift by 16
function T64.cycle_offset(year)
    local start_year = 2000
    local year_diff = T64.i32(year - start_year)

    if year > start_year then year_diff = year_diff - 1 end

    local exceptions = T64.div(year_diff, 100)
    exceptions = exceptions - T64.div(year_diff, 400)

    return T64.i32(exceptions * 16)
end

-- For a given year after 2038, pick the latest possible matching
-- year in the 28 year calendar cycle.
--
-- A matching year...
-- 1) Starts on the same day of the week.
-- 2) Has the same leap year status.
--
-- This is so the calendars match up.
--
-- Also the previous year must match.  When doing Jan 1st you might
-- wind up on Dec 31st the previous year when doing a -UTC time zone.
--
-- Finally, the next year must have the same start day of week.  This
-- is for Dec 31st with a +UTC time zone.
-- It doesn't need the same leap year status since we only care about
-- January 1st.
function T64.safe_year(year)
    local year_cycle = T64.i32(year + T64.cycle_offset(year))

    -- Change non-leap xx00 years to an equivalent
    if T64.is_exception_century(year) then
        year_cycle = T64.i32(year_cycle + 11)
    end

    -- Also xx01 years, since the previous year will be wrong
    if T64.is_exception_century(T64.i32(year - 1)) then
        year_cycle = T64.i32(year_cycle + 17)
    end

    -- (C's %= keeps the dividend's sign, and a negative remainder gets
    -- SOLAR_CYCLE_LENGTH added: together Lua's %)
    year_cycle = year_cycle % T64.SOLAR_CYCLE_LENGTH
    return T64.safe_years[year_cycle + 1]
end

-- Perl_gmtime64_r: the broken-down UTC time of a time (a double), as a
-- struct TM (field names of struct tm, tm_year since 1900)
function T64.gmtime64_r(time)
    local fmod, floor, ceil, int = math.fmod, mfloor, math.ceil, T64.int
    local days_in_month, length_of_year = T64.days_in_month, T64.length_of_year
    local days_in_gregorian_cycle = T64.days_in_gregorian_cycle
    local year = 70

    local v_tm_sec = int(fmod(time, 60.0))
    time = time >= 0 and floor(time / 60.0) or ceil(time / 60.0)
    local v_tm_min = int(fmod(time, 60.0))
    time = time >= 0 and floor(time / 60.0) or ceil(time / 60.0)
    local v_tm_hour = int(fmod(time, 24.0))
    time = time >= 0 and floor(time / 24.0) or ceil(time / 24.0)
    local v_tm_tday = time

    -- WRAP (v_tm_sec, v_tm_min, 60) etc.
    if v_tm_sec < 0 then v_tm_min = v_tm_min - 1; v_tm_sec = v_tm_sec + 60 end
    if v_tm_min < 0 then v_tm_hour = v_tm_hour - 1; v_tm_min = v_tm_min + 60 end
    if v_tm_hour < 0 then v_tm_tday = v_tm_tday - 1; v_tm_hour = v_tm_hour + 24 end

    local v_tm_wday = int(fmod(v_tm_tday + 4.0, 7.0))
    if v_tm_wday < 0 then v_tm_wday = v_tm_wday + 7 end
    local m = v_tm_tday

    if m >= T64.CHEAT_DAYS then
        year = T64.CHEAT_YEARS
        m = m - T64.CHEAT_DAYS
    end

    local leap, v_tm_mon
    if m >= 0 then
        -- Gregorian cycles, this is huge optimization for distant times
        local cycles = int(floor(m / (days_in_gregorian_cycle + 0.0)))
        if cycles ~= 0 then
            m = m - (cycles * (days_in_gregorian_cycle + 0.0))
            year = T64.i32(year + cycles * T64.years_in_gregorian_cycle)
        end

        -- Years
        leap = T64.IS_LEAP(year)
        while m >= length_of_year[leap + 1] do
            m = m - length_of_year[leap + 1]
            year = year + 1
            leap = T64.IS_LEAP(year)
        end

        -- Months
        v_tm_mon = 0
        while m >= days_in_month[leap + 1][v_tm_mon + 1] do
            m = m - days_in_month[leap + 1][v_tm_mon + 1]
            v_tm_mon = v_tm_mon + 1
        end
    else
        year = year - 1

        -- Gregorian cycles
        local cycles = int(ceil((m / (days_in_gregorian_cycle + 0.0)) + 1))
        if cycles ~= 0 then
            m = m - (cycles * (days_in_gregorian_cycle + 0.0))
            year = T64.i32(year + cycles * T64.years_in_gregorian_cycle)
        end

        -- Years
        leap = T64.IS_LEAP(year)
        while m < -length_of_year[leap + 1] do
            m = m + length_of_year[leap + 1]
            year = year - 1
            leap = T64.IS_LEAP(year)
        end

        -- Months
        v_tm_mon = 11
        while m < -days_in_month[leap + 1][v_tm_mon + 1] do
            m = m + days_in_month[leap + 1][v_tm_mon + 1]
            v_tm_mon = v_tm_mon - 1
        end
        m = m + days_in_month[leap + 1][v_tm_mon + 1]
    end

    -- At this point m is less than a year so casting to an int is safe
    return {
        tm_sec = v_tm_sec, tm_min = v_tm_min, tm_hour = v_tm_hour,
        tm_mday = int(m) + 1, tm_mon = v_tm_mon, tm_year = year, tm_wday = v_tm_wday,
        tm_yday = T64.julian_days_by_month[leap + 1][v_tm_mon + 1] + int(m), tm_isdst = 0,
    }
end

-- Perl_localtime64_r: the broken-down local time of a time (a double) as a
-- struct TM, or nil where the system localtime fails
function T64.localtime64_r(time)
    local safe_time, gm_tm, orig_year
    local use_system = time <= T64.SYSTEM_LOCALTIME_MAX and time >= T64.SYSTEM_LOCALTIME_MIN

    -- Use the system localtime() if time_t is small enough
    if use_system then
        safe_time = time
    else
        gm_tm = T64.gmtime64_r(time)

        orig_year = gm_tm.tm_year

        if gm_tm.tm_year > (2037 - 1900) or gm_tm.tm_year < (1970 - 1900) then
            gm_tm.tm_year = T64.safe_year(gm_tm.tm_year + 1900) - 1900
        end

        safe_time = T64.timegm64(gm_tm)
    end

    -- (the system localtime: os.date over the C library's localtime)
    local ok, result = pcall(os.date, '*t', T64.int(safe_time))
    if not ok then return nil end

    local local_tm = {
        tm_sec = result.sec, tm_min = result.min, tm_hour = result.hour, tm_mday = result.day,
        tm_mon = result.month - 1, tm_year = result.year - 1900, tm_wday = result.wday - 1,
        tm_yday = result.yday - 1,
        -- (Lua leaves isdst out for a negative tm_isdst, "not known")
        tm_isdst = (result.isdst == nil and -1) or (result.isdst and 1) or 0,
    }

    if not use_system then
        local_tm.tm_year = orig_year

        local month_diff = local_tm.tm_mon - gm_tm.tm_mon

        -- When localtime is Dec 31st previous year and
        -- gmtime is Jan 1st next year.
        if month_diff == 11 then
            local_tm.tm_year = local_tm.tm_year - 1
        end

        -- When localtime is Jan 1st, next year and
        -- gmtime is Dec 31st, previous year.
        if month_diff == -11 then
            local_tm.tm_year = local_tm.tm_year + 1
        end

        -- GMT is Jan 1st, xx01 year, but localtime is still Dec 31st
        -- in a non-leap xx00.  There is one point in the cycle
        -- we can't account for which the safe xx00 year is a leap
        -- year.  So we need to correct for Dec 31st coming out as
        -- the 366th day of the year.
        if T64.IS_LEAP(local_tm.tm_year) == 0 and local_tm.tm_yday == 365 then
            local_tm.tm_yday = local_tm.tm_yday - 1
        end
    end

    return local_tm
end

-- pp_gmtime (also used for pp_localtime), list context: the struct TM of
-- the time (now without one) as Perl's nine-element list -- 1-based here:
-- sec, min, hour, mday, mon (0-based), year-1900, wday, yday, isdst --
-- or the empty list where Perl's is empty (see above).
function T64.pp_gmtime(isLocal, time)
    local when
    if time == nil then
        when = os.time() + 0.0
    else
        local input = perl.num(time) + 0.0
        -- (NaN: "too large", then "failed"; a floor that changes nothing
        --  else, since Time64_T is an NV)
        if input ~= input then return { } end
        when = mfloor(input) + 0.0
    end

    local tmbuf
    if T64.TIME_LOWER_BOUND > when or when > T64.TIME_UPPER_BOUND then
        return { }
    elseif isLocal then
        tmbuf = T64.localtime64_r(when)
    else
        tmbuf = T64.gmtime64_r(when)
    end
    if tmbuf == nil then return { } end

    return { tmbuf.tm_sec, tmbuf.tm_min, tmbuf.tm_hour, tmbuf.tm_mday, tmbuf.tm_mon,
             tmbuf.tm_year, tmbuf.tm_wday, tmbuf.tm_yday, tmbuf.tm_isdst }
end

-- Perl gmtime() in list context - the broken-down UTC time as a 1-based array
-- in Perl's own field order: sec, min, hour, mday, mon (0-based), year-1900,
-- wday, yday, isdst (0). (Perl's list is 0-based; Lua arrays are 1-based, so
-- field N of Perl's `@t` is `t[N+1]` here -- the call sites index it that
-- way.) Empty beyond Perl's bounds (pp_gmtime above).
function perl.gmtime(time)
    return T64.pp_gmtime(false, time)
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
-- year-1900, wday, yday, isdst; for any time as in Perl (pp_gmtime and
-- Perl_localtime64_r above: the system localtime within the range Perl's
-- build gives it, the safe-year mapping outside), empty beyond Perl's bounds.
-- Without a time, the current one.
function perl.localtime(time)
    return T64.pp_gmtime(true, time)
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
--                  unbro / bro over the rock compress.brotli (below), a
--                  required dependency: upstream's `eval { require ... }`
--                  checks always succeed
--   Compress::Raw::Lzma, IO::Uncompress::Bunzip2
--                  the same over compress.lzma / compress.bzip2 (below)
local PROVIDED_MODULES = {
    ['Time::Piece']   = true,
    ['Term::ReadKey'] = true,
}
local LOAD = {}     -- (the loaders, by module, see MODULE_LOADERS)

-- IO::Uncompress::Brotli::unbro($buffer [, $max_size]) and
-- IO::Compress::Brotli::bro($buffer [, $quality [, $lgwin]]) of
-- IO-Compress-Brotli, over compress.brotli (https://github.com/osch/lua-compress).
-- $buffer may be a string or a carray (read in place); the result is a
-- string. unbro ignores data after the end of the Brotli stream and fails
-- for output beyond max_size, as the XS does; bro's defaults are the XS's
-- (quality 11, window 22, generic mode). Errors are raised (callers wrap
-- them in pcall as upstream wraps them in eval), with the XS's texts:
-- "Error in BrotliDecoderDecompress" with max_size, otherwise
-- compress.brotli's "Error in BrotliDecoderDecompressStream: <reason>".
-- `version` is the libbrotli version, for -ver -v.
function LOAD.brotli()
    local brotli = require('compress.brotli')
    local decompress, compress = brotli.decompress, brotli.compress
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
        version = (brotli.version()),
    }
end
-- Compress::Raw::Lzma over compress.lzma (https://github.com/osch/lua-compress):
-- the raw decoder and the LZMA1 filter object, as 7Z.pm uses them, the
-- LZMA_* status constants and lzma_version_string().
--   Lzma.Filter.Lzma1([opts])  Lzma::Filter::Lzma1(%opts): the filter
--                              object (DictSize, Lc, Lp, Pb; the defaults
--                              are those of preset 6, as in Perl)
--   RawDecoder.new(opts)       Compress::Raw::Lzma::RawDecoder->new(%opts):
--                              returns ($z, $status); Filter (a filter object
--                              or a list of one), Properties, AppendOutput
--                              (default 0), ConsumeInput (default 1)
--   z:code(input, output)      $z->code($in, $out): returns the status.
--                              Perl's in/out semantics on carrays: with
--                              ConsumeInput the consumed bytes are removed
--                              from the input (a Lua string cannot change,
--                              so it is read only), and the output carray is
--                              emptied first unless AppendOutput is set.
--                              The decoded data is also returned as second
--                              value.
function LOAD.lzma()
    local lzma = require('compress.lzma')
    local Filter = {}
    Filter.Lzma1 = function(opts)
        opts = opts or {}
        return { filter = 'lzma1', dictSize = opts.DictSize, lc = opts.Lc, lp = opts.Lp, pb = opts.Pb }
    end
    local RawDecoder = {}
    RawDecoder.__index = RawDecoder
    function RawDecoder.new(opts)
        opts = opts or {}
        local filter = opts.Filter or { filter = 'lzma2' }
        if filter.filter == nil then filter = filter[1] end
        local dopts = { format = 'raw', filter = filter.filter }
        if opts.Properties ~= nil then
            dopts.properties = opts.Properties
        else
            dopts.dictSize, dopts.lc, dopts.lp, dopts.pb = filter.dictSize, filter.lc, filter.lp, filter.pb
        end
        local okD, d = pcall(lzma.decompressor, dopts)
        if not okD then return nil, lzma.LZMA_OPTIONS_ERROR end
        local consume = opts.ConsumeInput
        local self = {
            d = d,
            AppendOutput = opts.AppendOutput ~= nil and perl.truthy(opts.AppendOutput),
            ConsumeInput = consume == nil or perl.truthy(consume),
        }
        return setmetatable(self, RawDecoder), lzma.LZMA_OK
    end
    function RawDecoder:code(input, output)
        local out, status, consumed
        if isCarray(output) then
            if not self.AppendOutput then output:reset() end
            out, status, consumed = self.d:code(input, output)
        else
            out, status, consumed = self.d:code(input)
        end
        if self.ConsumeInput and isCarray(input) and consumed > 0 then
            input:remove(1, consumed)
        end
        return status, out
    end
    return {
        RawDecoder = RawDecoder,
        Lzma = { Filter = Filter },
        LZMA_OK = lzma.LZMA_OK,
        LZMA_STREAM_END = lzma.LZMA_STREAM_END,
        lzma_version_string = function() return (lzma.version()) end,
    }
end
-- IO::Uncompress::Bunzip2::bunzip2($input => $output) over compress.bzip2,
-- with the one-shot defaults of IO::Uncompress::Bunzip2: MultiStream 0
-- (data after the first stream is ignored) and Transparent 1 (input that
-- does not start with a bzip2 signature "BZh0".."BZh9" -- also input
-- shorter than 4 bytes -- is copied unchanged).  $input is a string, a
-- carray or a box { value = ... } (Perl's \$buff); $output is a box, whose
-- value becomes a carray with the output.  Returns 1 on success, else nil
-- with the reason in Bunzip2Error ($IO::Uncompress::Bunzip2::Bunzip2Error).
function LOAD.bunzip2()
    local bzip2 = require('compress.bzip2')
    local carray = require('carray')
    local mod = { Bunzip2Error = '' }
    mod.bunzip2 = function(input, output)
        if type(input) == 'table' then input = input.value end
        local out = carray.new('char')
        output.value = out
        mod.Bunzip2Error = ''
        if not perl.isMatch(perl.substr(input, 0, 4), [[^\x42\x5A\x68[\x30-\x39]$]]) then
            out:append(input)       -- (Transparent: not bzip2 data)
            return 1
        end
        local d = bzip2.decompressor()
        local _, status = d:decompress(input, out)
        if status ~= bzip2.BZ_STREAM_END then
            mod.Bunzip2Error = status == bzip2.BZ_OK and 'unexpected end of file' or perl.str(d:msg())
            return nil
        end
        return 1
    end
    -- (the libbz2 version, for -ver -v)
    mod.version = bzip2.version()
    return mod
end
-- Time::HiRes::gettimeofday() (list context: seconds, microseconds, here as
-- a table { sec, usec } for `@startTime`) and tv_interval(\@start[, \@end])
-- (the seconds between them as a float, to now without an end), over the
-- wall clock of lexiftool.sys.
function LOAD.hiRes()
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

-- Unicode::GCString (of the Unicode::LineBreak distribution), the part
-- exiftool uses: Unicode::GCString->new($str)->columns, the display width
-- of a character string in columns per UAX #11 (East Asian Width) over its
-- grapheme clusters per UAX #29.  The character properties are those of
-- the Perl module's own database (sombok, Unicode 8.0.0), generated into
-- lexiftool.GCStringData by tools/gen_gcstring_data.lua; the clustering and
-- width rules are sombok's _gcinfo (gcstring.c) with the options of a
-- GCString created without a LineBreak object: ambiguous width is narrow,
-- no LegacyCM, no ViramaAsJoiner.  The string is a Perl character string,
-- which in this port is the UTF-8 encoded Lua string; a malformed sequence
-- counts as U+FFFD, as Encode::decode_utf8 makes it.
-- `UNICODE_VERSION` and `VERSION` (the Unicode-LineBreak release whose data
-- it is) are for -ver -v.
function LOAD.gcString()
    local data = require('lexiftool.GCStringData')
    local starts, props = data.starts, data.props
    local nruns = #starts
    -- property kinds (GCStringData's numbering)
    local K_OTHER, K_CR, K_LF, K_CONTROL, K_EXT, K_PREPEND = 0, 1, 2, 3, 4, 5
    local K_L, K_V, K_T, K_LV, K_LVT, K_RI, K_SP = 6, 7, 8, 9, 10, 11, 12
    -- kind and columns of code point c (linebreak_charprop, with sombok's
    -- fixed blocks above the compact array)
    local function charprop(c)
        if c < 0x20000 then
            local lo, hi = 1, nruns
            while lo < hi do
                local mid = (lo + hi + 1) // 2
                if starts[mid] <= c then lo = mid else hi = mid - 1 end
            end
            local p = props[lo]
            return p // 3, p % 3
        elseif c <= 0x2FFFD or (0x30000 <= c and c <= 0x3FFFD) then
            return K_OTHER, 2       -- (Han: ID, wide)
        elseif c == 0xE0001 or (0xE0020 <= c and c <= 0xE007F) then
            return K_CONTROL, 0     -- (tags)
        elseif 0xE0100 <= c and c <= 0xE01EF then
            return K_EXT, 0         -- (variation selectors)
        elseif (0xF0000 <= c and c <= 0xFFFFD) or (0x100000 <= c and c <= 0x10FFFD) then
            return K_OTHER, 1       -- (private use: ambiguous)
        end
        return K_CONTROL, 1         -- (reserved)
    end
    local function isHangulCont(gcb, ngcb)
        return (gcb == K_L and (ngcb == K_L or ngcb == K_V or ngcb == K_LV or ngcb == K_LVT)) or
               ((gcb == K_LV or gcb == K_V) and (ngcb == K_V or ngcb == K_T)) or
               ((gcb == K_LVT or gcb == K_T) and ngcb == K_T)
    end
    -- the code points of a UTF-8 string
    local function decode(str)
        local cps, n, i, len = {}, 0, 1, #str
        while i <= len do
            local c = sbyte(str, i)
            local nexti = i + 1
            if c >= 0x80 then
                local ok, v = pcall(utf8.codepoint, str, i)
                if ok then
                    nexti = i + #utf8.char(v)
                    c = v
                else
                    c = 0xFFFD
                end
            end
            n = n + 1
            cps[n] = c
            i = nexti
        end
        return cps, n
    end
    -- the columns of the grapheme clusters of str (gcstring_columns over
    -- the clusters _gcinfo finds)
    local function columns(str)
        local cps, n = decode(str)
        local col, pos = 0, 1
        while pos <= n do
            local gcb, cols = charprop(cps[pos])
            local isSP = gcb == K_SP
            if isSP then gcb = K_OTHER end
            pos = pos + 1
            local gcol
            if gcb == K_V or gcb == K_T then
                gcol = 2    -- (isolated hangul jamo is wide)
            else
                gcol = cols
            end
            if gcb == K_CR then
                if pos <= n then
                    local ngcb, ncols = charprop(cps[pos])
                    if ngcb == K_LF then
                        pos = pos + 1
                        gcol = gcol + ncols
                    end
                end
            elseif gcb ~= K_LF and gcb ~= K_CONTROL then
                local pcol, ecol = 0, 0
                while pos <= n and not isSP do  -- (SP takes no extenders)
                    local ngcb, ncols = charprop(cps[pos])
                    if ngcb == K_SP then ngcb = K_OTHER end
                    if ngcb == K_CONTROL or ngcb == K_CR or ngcb == K_LF then
                        break                                   -- GB5
                    elseif isHangulCont(gcb, ngcb) then
                        gcol = 2                                -- GB6 - GB8
                    elseif gcb == K_RI and ngcb == K_RI then
                        gcol = gcol + ecol + ncols              -- GB8a
                        ecol = 0
                    elseif ngcb == K_EXT then
                        ecol = ecol + ncols                     -- GB9, GB9a
                    elseif gcb == K_PREPEND then
                        pcol = pcol + gcol                      -- GB9b
                        if ngcb == K_V or ngcb == K_T then gcol = 2 else gcol = ncols end
                    else
                        break                                   -- GB10
                    end
                    pos = pos + 1
                    gcb = ngcb
                end
                gcol = gcol + pcol + ecol
            end
            col = col + gcol
        end
        return col
    end
    local GCString = {}
    GCString.__index = GCString
    function GCString.new(str)
        return setmetatable({ str = perl.str(str) }, GCString)
    end
    function GCString:columns()
        return columns(self.str)
    end
    return {
        new = GCString.new,
        UNICODE_VERSION = data.UNICODE_VERSION,
        VERSION = data.LINEBREAK_VERSION,
    }
end
local MODULE_LOADERS = {
    ['Unicode::GCString']      = LOAD.gcString,
    ['Unicode::LineBreak']     = LOAD.gcString,
    ['IO::Uncompress::Brotli'] = LOAD.brotli,
    ['IO::Compress::Brotli']   = LOAD.brotli,
    ['Compress::Raw::Lzma']    = LOAD.lzma,
    ['IO::Uncompress::Bunzip2'] = LOAD.bunzip2,
    ['Time::HiRes']            = LOAD.hiRes,
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

-- Perl $$ - the process ID (lexiftool.sys: getpid, GetCurrentProcessId on
-- Windows).
function perl.pid()
    return sys.getpid()
end

-- Perl srand(EXPR) and rand(EXPR), with Perl's own generator (`perl
-- -V:randfunc` says Perl_drand48, the same 48-bit linear congruential
-- generator on every platform), so a seeded sequence -- srand(141) in
-- Plot.pm's Draw, srand(N) in a user's expression -- comes out as Perl's:
--   srand:  state = 0x330e + (seed << 16), seed taken as a 32-bit unsigned
--   rand:   state = (0x5deece66d * state + 0xb) mod 2^48; value state / 2^48
-- (the multiply overflows 64 bits, but Lua wraps modulo 2^64 and the low 48
--  bits -- the only ones the mask keeps -- come out the same).  rand seeds
-- itself on first use, as Perl does when srand was not called.
local randState
-- (Perl's seed(): an unpredictable value)
local function randSeed()
    local t = os.time()
    local c = mtointeger(math.floor(os.clock() * 1000000)) or 0
    return (t * 1000003 + c * 7919 + perl.pid() * 69069) & 0xffffffff
end
-- Perl srand(EXPR): seeds rand with EXPR (an unsigned integer; a value that
-- is not one warns "Integer overflow in srand" and seeds with UV_MAX) or,
-- without EXPR, with an unpredictable value.
-- Returns: the seed ("0 but true" for 0), as Perl does
function perl.srand(seed)
    local anum
    if seed ~= nil then
        -- (Perl's grok_number on the string form: the integer part of an
        --  unsigned decimal number, its sign dropped; the arithmetic wraps
        --  modulo 2^64, so a value above 2^63 keeps its unsigned bits)
        local s = perlStr(seed)
        local int, frac = smatch(s, '^[ \t\n\r\f\v]*[-+]?(%d*)(%.?%d*)[ \t\n\r\f\v]*$')
        local digit = int and smatch(int .. frac, '%d')
        if int then int = smatch(int, '^0*(.*)$') end
        if not digit or #int > 20 or
           (#int == 20 and int > '18446744073709551615') then
            perl.warn('Integer overflow in srand')
            anum = -1   -- (UV_MAX)
        else
            anum = 0
            for k = 1, #int do anum = anum * 10 + (sbyte(int, k) - 48) end
        end
    else
        anum = randSeed()
    end
    randState = 0x330e | ((anum & 0xffffffff) << 16)
    if anum == 0 then return '0 but true' end
    if anum < 0 then return perl.uv(anum) end
    return anum
end
function perl.rand(n)
    if not randState then randState = 0x330e | (randSeed() << 16) end
    n = n and perl.num(n) or 1
    if n == 0 then n = 1 end
    randState = (0x5deece66d * randState + 0xb) & 0xffffffffffff
    return randState / 2 ^ 48 * n
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
        if c == '(' then
            -- group: `(TEMPLATE)COUNT` stands for the template COUNT times,
            -- `(TEMPLATE)*` repeats it as long as data is left (one token
            -- the unpack loop expands at run time); no count is once
            local depth, j = 1, i + 1
            while j <= #fmt and depth > 0 do
                local cj = ssub(fmt, j, j)
                if cj == '(' then depth = depth + 1 elseif cj == ')' then depth = depth - 1 end
                j = j + 1
            end
            local inner = ssub(fmt, i + 1, j - 2)
            local start = j
            while ssub(fmt, j, j):match('[0-9]') do j = j + 1 end
            if ssub(fmt, j, j) == '*' and j == start then
                tokens[#tokens + 1] = { code = '(', group = inner, count = '*' }
                j = j + 1
            else
                local reps = j > start and tonumber(ssub(fmt, start, j - 1)) or 1
                local innerTokens = tokenize(inner)
                for _ = 1, reps do
                    for _, t in ipairs(innerTokens) do tokens[#tokens + 1] = t end
                end
            end
            i = j
        elseif c == ' ' or c == ')' then
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
        if code == '(' then
            -- `(TEMPLATE)*`: the group again while data is left
            while pos < n do
                local vals = { perl.unpack(tok.group, s, pos) }
                local newPos = tremove(vals)
                for i = 1, #vals do results[#results + 1] = vals[i] end
                if newPos <= pos then break end
                pos = newPos
            end
        elseif code == '@' then
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
-- the port's empty list and empty hash look the same; perl.eval's own
-- references say what they are (ARef: 'ARRAY', PerlHash: 'HASH').
function perl.ref(v)
    local t = type(v)
    if t == 'function' then return 'CODE' end
    if io.type(v) then return 'GLOB' end
    if t ~= 'table' then return '' end
    local mt = getmetatable(v)
    if mt == UV then return '' end
    if mt == ARef then return 'ARRAY' end
    if mt == PerlHash then return 'HASH' end
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
-- by `$info{'TAG'}` variables), the advanced formatting expressions
-- "${TAG;EXPR}" (code that edits $_) and the conversion strings of config
-- files.  Lua cannot run Perl, so this is an interpreter for the part of
-- the language such code uses:
--   terms      numbers, '...', "...", q(...), qq(...) and qw(...) strings
--              (the double-quoted ones interpolating $name, ${name},
--              $name{key}, $$name{key}, $name[N], $1.., $& and @name, with
--              the case modifiers \U \L \F \Q \E \u \l, and any longer
--              variable expression -- $a[$i], $h{a}{b}, $r->[0], @$r, @{...},
--              $#a -- compiled as code), $name, @name, %name, the elements
--              $name[EXPR] and $name{KEY} (a bareword alone is the key), the
--              slices @name[LIST] and @name{LIST}, $#name, the capture
--              variables $1..$N and $& of the last successful match, undef,
--              ( ... ), (LIST) and the list slice (LIST)[INDEXES], `my $x`,
--              `my @a`, `my %h`, `my ($x, @a, %h, undef)` (variables of this
--              eval), function calls NAME(...) or NAME LIST (NAME may be
--              package-qualified, A::B::NAME), method calls $obj->Name(ARGS),
--              class method calls A::B->Name(ARGS) and `new A::B(ARGS)`,
--              `do BLOCK`, a bare /re/ (matches $_; in list context the
--              captures, with /g all matches), s/re/repl/flags (also /r, and
--              /e: the replacement is code), tr/a/b/flags and y/a/b/flags (on
--              $_, or on a variable bound with =~); a pattern interpolates
--              like a double-quoted string (a '$' before ')' or '|' or at
--              the end is the anchor), a replacement too, per match
--   references \$x (the box { ref = 'SCALAR', value } the variable lives in
--              from then on), \@a and \%h, \$h{key} (a box that reads and
--              writes the element), [LIST] and {LIST} (anonymous arrays and
--              hashes), the dereferences $$r, ${EXPR}, @$r, @{EXPR}, %$r,
--              %{EXPR}, $#$r, $$r[I], $$r{K}, ${EXPR}[I], $r->[I], $r->{K}
--              and chains of subscripts (the arrow optional between two),
--              with Perl's autovivification and the errors of `use strict
--              refs`; an array reference is { arr = ARRAY } (ARef), a hash
--              the code makes a table with the metatable PerlHash, and a
--              Lua sequence or table of the caller's stands for an array or
--              hash reference -- what the code returns or passes to the
--              caller's functions gets the port's shapes back (EV.export)
--   operators  ++ -- ** ! unary - + \ =~ !~ (with /re/flags or
--              m<d>re<d>flags) * / % x + - . << >> < > <= >= lt gt le ge
--              == != <=> eq ne cmp & | ^ && || // .. ?: = .= += -= *= /=
--              **= ||= &&= //= , => not and or xor -- with Perl's
--              precedence, short-circuit evaluation and scalar/list context
--              (an array in scalar context is its count, a literal list its
--              last element; `..` and (LIST) x N are lists in list context)
--   statements separated by ';', each with an optional `if COND`, `unless
--              COND`, `for LIST`, `while COND` or `until COND` modifier
--              (`do BLOCK while COND` runs the block first), the block forms
--              `if (COND) {...} elsif (COND) {...} else {...}`, `unless
--              (COND) {...}`, `{...}`, and the loops `for`/`foreach [my]
--              [$var] (LIST) {...}` (the variable aliases each element, as
--              does $_ in map, grep and the modifier), `for (INIT; COND;
--              STEP) {...}`, `while (COND) {...}`, `until (COND) {...}`,
--              with `next` and `last` (also `next LABEL` for a loop with
--              `LABEL:`); `return EXPR` ends the code with that value, else
--              the value is that of the last statement
--   builtins   defined length lc uc lcfirst ucfirst int abs ord chr hex
--              oct sqrt exp log sin cos atan2 ref quotemeta scalar substr
--              index rindex sprintf join split push unshift shift pop
--              splice reverse rand srand (Perl's drand48) time localtime
--              gmtime pack unpack chomp chop exists delete die warn, sort
--              LIST and sort BLOCK LIST ($a/$b), map and grep (BLOCK LIST
--              and EXPR, LIST), keys, values and each (in Perl's string
--              order: Perl's own is unpredictable), require (through the
--              caller's CORE::GLOBAL::require), plus the functions in funcs
--              (exiftool's End/EndDir, DateFmt, ShiftTime, NoDups, SetTags,
--              the Image::ExifTool functions)
--   warnings   those of `perl -w` (exiftool's), through perl.warn with
--              Perl's text: "Use of uninitialized value NAME in OP" for an
--              undef operand (named as Perl's find_uninit_var does: the
--              variable when it is the only non-constant operand, else when
--              it exists, never an element reached through a reference)
--              and "Argument "..." isn't numeric in OP"; boolean context,
--              defined, length, .= += -= ||= &&= //= and ++/-- take undef
--              silently, as in Perl; and at compile time, before the code
--              runs, "Useless use of WHAT in void context" for a statement
--              whose value is thrown away (see voidUse below), "Found = in
--              conditional" and "Scalar value @a[...] better written as
--              $a[...]"
--   not done   sub, local, our, eval, wantarray, redo, goto, code
--              references, @_, the flip-flop .. in scalar context, \(LIST),
--              file and system functions, print -- reported as unsupported
--              (below); the `use strict` check of undeclared variables is
--              not made; an undef stored in a hash or array element does
--              not exist in Lua (the key is absent, the element a hole)
-- The code is compiled once (compileEval) and the compiled form kept by
-- code text and options, for the next eval of the same code -- -if runs one
-- condition for every file.
-- Inputs: 0) code, 1) variables by name (a scalar, or a hash table for
--         $name{key} and $$name{key}, or a sequence for @name -- with `n`
--         when it may have holes; assignments and s///, tr/// write back
--         into this table, so the caller reads the new $_ as vars._ -- `my`
--         variables stay inside the eval),
--         2) functions by name (a name that is not a builtin is looked up
--         here, package-qualified ones included -- a table with an
--         __index resolves a package's functions, see ExifTool.evalFuncs;
--         they may assign to their arguments with perl.setArg),
--         3) optional last successful match of the caller's scope, as
--         { $1, $2, ..., amp = $& }: Perl's capture variables are
--         dynamically scoped, so the code sees the caller's until it
--         matches itself (a failed match changes nothing),
--         4) optional options: `void` (the eval runs in void context, so
--         the value of the last statement is thrown away -- otherwise it is
--         taken in scalar context) and `globals` (the set of variable names
--         that are package variables in the caller, for the void-context
--         warning; the others count as `my` variables)
-- Returns: the value of the last statement or of `return` (in scalar
--          context, as the port's shapes: EV.export); dies
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
-- (a number truncated toward zero, as an integer where it fits)
local function trunc(n)
    if getmetatable(n) == UV then return n end
    n = n < 0 and math.ceil(n) or math.floor(n)
    return math.tointeger(n) or n
end
-- (op: the operator a non-numeric string warns about, see perl.num)
local function intVal(v, op)
    local n = perl.num(v, op)
    n = n < 0 and math.ceil(n) or math.floor(n)
    return math.tointeger(n) or 0
end
-- (what all compiled codes share: the metatables of a scalar variable that a
--  reference aliases -- { cell = box }, the box `\$name` gave out holds the
--  variable's value -- and of a loop control or return, raised as an error
--  object -- { ctl = 'next'|'last'|'return', label = LABEL, value = VALUE };
--  the array references by array, so that the same array gives the same one)
local EV = { Alias = {}, Ctl = {}, arefs = setmetatable({}, { __mode = 'kv' }),
             iters = setmetatable({}, { __mode = 'k' }) }
-- the reference to the array t
function EV.aref(t)
    local r = EV.arefs[t]
    if not r then
        r = setmetatable({ arr = t }, ARef)
        EV.arefs[t] = r
    end
    return r
end
-- the number of elements of an array: a PerlList, or a sequence of the
-- caller's (which gives its length as `n`, table.pack's way, when it may
-- have holes)
function EV.alen(t)
    if getmetatable(t) == PerlList then return t.n end
    local n = rawget(t, 'n')
    if mtype(n) == 'integer' then return n end
    return #t
end
-- a value as it leaves the code (the eval's value, an argument of the
-- caller's functions): an array reference and a hash the code made become
-- the port's shapes for them, a Lua sequence and a plain table
function EV.export(v, memo)
    if type(v) ~= 'table' then return v end
    local mt = getmetatable(v)
    if mt ~= ARef and mt ~= PerlHash then return v end
    if mt == ARef and getmetatable(v.arr) ~= PerlList then return v.arr end
    memo = memo or {}
    local out = memo[v]
    if out then return out end
    out = {}
    memo[v] = out
    if mt == ARef then
        local a = v.arr
        for i = 1, a.n do out[i] = EV.export(a[i], memo) end
    else
        for k, x in pairs(v) do out[k] = EV.export(x, memo) end
    end
    return out
end
local EVAL_FUNCS = {
    defined = function(v) return v ~= nil and 1 or '' end,
    length = function(v) return perl.length(v) end,
    lc = function(v) return perl.lc(v) end,
    uc = function(v) return perl.uc(v) end,
    lcfirst = function(v) return perl.lcfirst(v) end,
    ucfirst = function(v) return perl.ucfirst(v) end,
    int = function(v) return perl.int(v) end,
    abs = function(v) return math.abs(perl.num(v, 'abs')) end,
    ord = function(v) return perl.ord(perlStr(v)) end,
    chr = function(v) return perl.chr(perl.num(v, 'chr')) end,
    hex = function(v) return perl.hex(perlStr(v)) end,
    oct = function(v) return perl.oct(perlStr(v)) end,
    sqrt = function(v)
        local n = perl.num(v, 'sqrt')
        if n < 0 then perl.die("Can't take sqrt of " .. perlStr(n) .. ' at (eval 1) line 1.\n') end
        return math.sqrt(n)
    end,
    exp = function(v) return math.exp(perl.num(v, 'exp')) end,
    log = function(v) return perl.log(v) end,
    scalar = function(v) return v end,  -- (the argument is evaluated in scalar context)
    substr = function(s, off, len)
        s = perlStr(s)
        off = intVal(off, 'substr')
        if len ~= nil then len = intVal(len, 'substr') end
        -- (beyond either end of the string: undef and a warning, as
        --  Perl_translate_substr_offsets decides)
        local n = #s
        if off < 0 and n > 0 then off = off + n end
        if off > n then
            perl.warn('substr outside of string')
            return nil
        end
        local off2
        if len == nil then
            off2 = n
        elseif len < 0 then
            off2 = n + len
        elseif off < 0 then
            off2 = off + len
        else
            off2 = off + len < n and off + len or n
        end
        if off2 < 0 then
            if off < 0 then
                perl.warn('substr outside of string')
                return nil
            end
            off2 = 0
        elseif off < 0 then
            off = 0
        end
        if off2 < off then off2 = off end
        if off2 > n then off2 = n end
        return ssub(s, off + 1, off2)
    end,
    index = function(s, t, p) return perl.index(s, t, p ~= nil and intVal(p, 'index') or nil) end,
    rindex = function(s, t, p) return perl.rindex(s, t, p ~= nil and intVal(p, 'rindex') or nil) end,
    sprintf = function(fmt, ...) return perl.sprintf(fmt, ...) end,
    join = function(sep, ...)
        local t = tpack(...)
        local list = {}
        for i = 1, t.n do list[i] = t[i] == nil and '' or t[i] end
        return perl.join(sep, list)
    end,
    rand = function(n) return perl.rand(n) end,
    srand = function(...)
        -- (an undef argument seeds as Perl's SvPV of undef: '')
        if select('#', ...) > 0 then return perl.srand((...) == nil and '' or (...)) end
        return perl.srand()
    end,
    -- (an object: the class its metatable names as __perlClass, the
    --  package Perl blesses it into)
    ref = function(v)
        local r = perl.ref(v)
        if r == 'HASH' then
            local mt = getmetatable(v)
            if type(mt) == 'table' and rawget(mt, '__perlClass') then return mt.__perlClass end
        end
        return r
    end,
    quotemeta = function(v) return perl.quotemeta(v) end,
    sin = function(v) return math.sin(perl.num(v, 'sin')) end,
    cos = function(v) return math.cos(perl.num(v, 'cos')) end,
    atan2 = function(y, x) return math.atan(perl.num(y, 'atan2'), perl.num(x, 'atan2')) end,
    time = function() return perl.time() end,
    pack = function(fmt, ...) return perl.pack(perlStr(fmt), ...) end,
    -- (in list context all the values, in scalar context the first one)
    unpack = function(fmt, data)
        if type(data) ~= 'string' and type(data) ~= 'userdata' then data = perlStr(data) end
        return perl.unpack(perlStr(fmt), data)
    end,
}
-- (named unary operators: an argument without parentheses binds tighter
--  than a comparison, `length $x == 5` is `length($x) == 5`; without an
--  argument they act on $_)
local EVAL_NAMED_UNARY = { defined = 1, length = 1, lc = 1, uc = 1, lcfirst = 1,
                           ucfirst = 1, int = 1, abs = 1, ord = 1, chr = 1, hex = 1,
                           oct = 1, sqrt = 1, exp = 1, log = 1, rand = 1, srand = 1,
                           ref = 1, quotemeta = 1, sin = 1, cos = 1, scalar = 1 }
-- (the named unary operators that do not default to $_: rand is rand(1),
--  srand seeds unpredictably)
local EVAL_NO_DEFAULT = { rand = 1, srand = 1, scalar = 1 }
-- (list operators: their arguments are flattened, and without parentheses
--  they take everything up to the next low-precedence operator)
local EVAL_LIST_OPS = { sprintf = 1, join = 1, atan2 = 1, pack = 1, unpack = 1 }
-- (the builtins that warn "Use of uninitialized value ... in NAME" for an
--  undef argument, under the name Perl gives them; defined, length and
--  scalar take undef silently)
local EVAL_UNINIT = { lc = 'lc', uc = 'uc', lcfirst = 'lcfirst', ucfirst = 'ucfirst', int = 'int',
                      abs = 'abs', ord = 'ord', chr = 'chr', hex = 'hex', oct = 'oct', sqrt = 'sqrt',
                      exp = 'exp', log = 'log', substr = 'substr', index = 'index', rindex = 'rindex',
                      sprintf = 'sprintf', join = 'join or string', rand = 'rand', srand = 'srand',
                      quotemeta = 'quotemeta', sin = 'sin', cos = 'cos', atan2 = 'atan2', pack = 'pack',
                      unpack = 'unpack' }
-- (the builtins' names in "Useless use of NAME in void context"; scalar,
--  rand and srand do not warn there)
local EVAL_VOID = { defined = 'defined operator', length = 'length', lc = 'lc', uc = 'uc',
                    lcfirst = 'lcfirst', ucfirst = 'ucfirst', int = 'int', abs = 'abs', ord = 'ord',
                    chr = 'chr', hex = 'hex', oct = 'oct', sqrt = 'sqrt', exp = 'exp', log = 'log',
                    substr = 'substr', index = 'index', rindex = 'rindex', sprintf = 'sprintf',
                    join = 'join or string', ref = 'reference-type operator', quotemeta = 'quotemeta',
                    sin = 'sin', cos = 'cos', atan2 = 'atan2', time = 'time', pack = 'pack',
                    unpack = 'unpack' }
-- (the builtins Perl folds at compile time when their arguments are
--  constants)
local EVAL_FOLD = { length = 1, lc = 1, uc = 1, lcfirst = 1, ucfirst = 1, int = 1, abs = 1,
                    ord = 1, chr = 1, hex = 1, oct = 1, sqrt = 1, exp = 1, log = 1, sprintf = 1,
                    join = 1, quotemeta = 1, sin = 1, cos = 1, atan2 = 1, pack = 1 }
-- (the functions behind the case modifiers of a double-quoted string)
local EVAL_CASE_FUNC = { U = 'uc', L = 'lc', Q = 'quotemeta', F = 'fc', u = 'ucfirst', l = 'lcfirst' }
-- Perl keywords and builtins this interpreter does not do (named in the
-- "unsupported" message rather than reported as unknown functions)
local EVAL_UNSUPPORTED = {
    ['local'] = 'local', our = 'our', sub = 'sub', eval = 'eval', redo = 'redo', ['goto'] = 'goto',
    print = 'print', printf = 'printf', say = 'say', wantarray = 'wantarray', use = 'use',
    no = 'no', package = 'package', pos = 'pos', lock = 'lock', fc = 'fc', crypt = 'crypt',
    vec = 'vec', bless = 'bless', study = 'study', exit = 'exit', sleep = 'sleep', kill = 'kill',
    fork = 'fork', wait = 'wait', waitpid = 'waitpid', system = 'system', exec = 'exec',
    open = 'open', close = 'close', chdir = 'chdir', mkdir = 'mkdir', rmdir = 'rmdir',
    unlink = 'unlink', rename = 'rename', link = 'link', symlink = 'symlink',
    readlink = 'readlink', stat = 'stat', lstat = 'lstat', chmod = 'chmod', chown = 'chown',
    utime = 'utime', glob = 'glob', opendir = 'opendir', readdir = 'readdir',
    closedir = 'closedir', binmode = 'binmode', eof = 'eof', fileno = 'fileno', getc = 'getc',
    read = 'read', seek = 'seek', tell = 'tell', sysread = 'sysread', syswrite = 'syswrite',
    sysopen = 'sysopen', select = 'select', caller = 'caller', format = 'format',
    write = 'write', alarm = 'alarm', umask = 'umask', times = 'times', state = 'state',
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
    ['..'] = { 4.5, 'N' },
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
local EVAL_OPS = { '...', '<=>', '**=', '||=', '&&=', '//=', '**', '=~', '!~', '==', '!=', '<=', '>=',
                   '=>', '&&', '||', '//', '->', '++', '--', '.=', '+=', '-=', '*=', '/=',
                   '<<', '>>', '..', '+', '-', '*', '/', '%', '.', '<', '>', '!', '?', ':', '(', ')',
                   ',', ';', '=', '&', '|', '^', '[', ']', '{', '}' }
-- (token kinds after which a '/' is the division operator, not a regex)
local EVAL_TERM_END = { num = 1, str = 1, istr = 1, var = 1, [')'] = 1, [']'] = 1,
                        regex = 1, array = 1, hash = 1, qw = 1, lastidx = 1, aderef = 1 }
local EVAL_CLOSE = { ['('] = ')', ['['] = ']', ['{'] = '}', ['<'] = '>' }
local EVAL_ESC = { n = '\n', t = '\t', r = '\r', ['0'] = '\0', a = '\a', b = '\b', e = '\27', f = '\f' }
local function evalDie(code, pos)
    perl.die('syntax error at (eval 1) line 1, near "' .. ssub(code, pos, pos + 9) .. '"\n')
end
local function evalUnsupported(code, pos, what)
    local near = ssub(code, pos, pos + 19)
    error(setmetatable({ msg = 'Perl syntax unsupported in lexiftool: ' .. what .. ' (near "' ..
                           near .. '") at (eval 1) line 1.\n', unsupported = what }, PerlDie), 0)
end
local function boolVal(b) if b then return 1 end return '' end
-- Raises perl.eval's "Perl syntax unsupported in lexiftool: WHAT" error (see
-- perl.isUnsupported), for a function perl.eval calls that meets Perl it
-- cannot do (the require of a Perl module).
function perl.unsupported(what)
    error(setmetatable({ msg = 'Perl syntax unsupported in lexiftool: ' .. what .. ' at (eval 1) line 1.\n',
                         unsupported = what }, PerlDie), 0)
end
-- (assigns to argument k of the function perl.eval is calling, see perl.setArg)
local argAlias
-- Perl `$_[N] = VALUE` in a function that perl.eval calls (one of its funcs):
-- @_ aliases the caller's arguments, so this assigns to the variable passed
-- as argument N (0-based; Shift.pl's ShiftTime($val, $shift) shifts $val in
-- place this way).  Dies "Modification of a read-only value attempted" for
-- an argument that is not a variable, as Perl does.
function perl.setArg(n, val)
    if not argAlias then error('perl.setArg: not called from code perl.eval runs', 2) end
    argAlias(n, val)
end
local function cmpNum(a, b)
    if a < b then return -1 elseif a > b then return 1 end
    return 0
end
local function cmpStr(a, b)
    return perl.cmp(a, b)
end
-- Compiles the code for perl.eval: parses it into closures and returns the
-- function that runs them, run(vars, funcs, outer) -- the state of one run
-- (the caller's variables and functions, the `my` variables, the captures)
-- lives in upvalues that run sets and restores, so a compiled code runs any
-- number of times, and recursively.  Inputs: 0) code, 1) the functions
-- (only which names exist matters here: funcNames records them, since a
-- name that is neither a builtin nor a function is unsupported), 2) the
-- options (void, globals), 3) the list that takes the compile-time warnings
-- (perl.eval issues them at each run, as Perl compiles the string at each
-- eval), 4) the table that takes the function names looked up
local function compileEval(code, funcs, opts, compileWarns, funcNames)
    local globals = opts and opts.globals
    local vars = {}         -- (the caller's variables: set by run)
    local pos, n = 1, #code
    local tok, tokVal       -- current token kind and value
    local tokPos            -- where the current token starts
    local lastKind          -- kind of the previous token (regex or division?)
    local lex, declared = {}, {}    -- `my` variables ('@name' for an array)
    local caps = {}         -- $1, $2, ... of the last successful match
    local lastMatch         -- $&, the text it matched
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
            -- (1..3: the number before a range operator)
            if ssub(num, -1) == '.' and ssub(code, pos + #num, pos + #num) == '.' then
                num = ssub(num, 1, -2)
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
                tok, tokVal = 'var', { k = 'cap', cap = tonumber(digits) }
                return
            end
            -- $&: the text the last successful match matched
            if ssub(code, pos, pos + 1) == '$&' then
                pos = pos + 2
                tok, tokVal = 'var', { k = 'amp', amp = true }
                return
            end
            local c2 = ssub(code, pos + 1, pos + 1)
            if c2 == '#' then
                -- $#name, $#$name and $#{EXPR}: the last index of an array
                local deref, name = smatch(code, '^%$#(%$?)([A-Za-z_][A-Za-z0-9_]*)', pos)
                if name then
                    pos = pos + 2 + #deref + #name
                    tok, tokVal = 'lastidx', { name, deref = deref ~= '' or nil }
                    return
                end
                if ssub(code, pos + 2, pos + 2) == '{' then
                    pos = pos + 2
                    tok, tokVal = 'lastidx', false     -- (the block follows)
                    return
                end
                unsupported('special variable $#')
            end
            if c2 == '{' then
                -- ${name} is $name, ${ EXPR } dereferences what EXPR yields
                local name, after = smatch(code, '^%${[ \t]*([A-Za-z_][A-Za-z0-9_]*)[ \t]*}()', pos)
                if name then
                    pos = after
                    tok, tokVal = 'var', { name }
                    return
                end
                pos = pos + 1
                tok, tokVal = 'sderef', nil     -- (the block follows)
                return
            end
            -- $name, and $$name (what the reference in $name refers to); a
            -- subscript after the name is the parser's
            local deref, name = smatch(code, '^%$(%$?)([A-Za-z_][A-Za-z0-9_]*)', pos)
            if not name then
                if c2 == '$' then unsupported('dereference ' .. ssub(code, pos, pos + 2) .. '...') end
                unsupported('special variable ' .. ssub(code, pos, pos + 1))
            end
            pos = pos + 1 + #deref + #name
            if ssub(code, pos, pos + 1) == '::' then unsupported('package variable') end
            tok, tokVal = 'var', { name, deref = deref ~= '' or nil }
            return
        end
        if c == '@' then
            -- @name and @$name (an array, or the array a scalar refers to),
            -- @{ EXPR } (the array EXPR refers to)
            local deref, name = smatch(code, '^@(%$?)([A-Za-z_][A-Za-z0-9_]*)', pos)
            if name then
                pos = pos + 1 + #deref + #name
                if ssub(code, pos, pos + 1) == '::' then unsupported('package variable') end
                if name == '_' and deref == '' then unsupported('@_') end
                if deref ~= '' then
                    tok, tokVal = 'aderef', name
                else
                    tok, tokVal = 'array', name
                end
                return
            end
            if ssub(code, pos + 1, pos + 1) == '{' then
                pos = pos + 1
                tok, tokVal = 'aderef', false   -- (the block follows)
                return
            end
            unsupported('array expression ' .. ssub(code, pos, pos + 1))
        end
        if not EVAL_TERM_END[lastKind] then
            -- (characters that start a term Perl has but this subset lacks)
            if c == '%' then
                -- %name and %$name (a hash, or the hash a scalar refers to),
                -- %{ EXPR } (the hash EXPR refers to)
                local deref, name = smatch(code, '^%%(%$?)([A-Za-z_][A-Za-z0-9_]*)', pos)
                if name then
                    pos = pos + 1 + #deref + #name
                    if ssub(code, pos, pos + 1) == '::' then unsupported('package variable') end
                    if smatch(code, '^[{[]', pos) then
                        unsupported('key/value slice %' .. name .. ssub(code, pos, pos))
                    end
                    tok, tokVal = 'hash', { name, deref = deref ~= '' or nil }
                    return
                end
                if ssub(code, pos + 1, pos + 1) == '{' then
                    pos = pos + 1
                    tok, tokVal = 'hderef', nil     -- (the block follows)
                    return
                end
                if smatch(code, '^%%%$', pos) then unsupported('hash expression ' .. ssub(code, pos, pos + 1)) end
            end
            if c == '&' then unsupported('&subroutine call') end
            if c == '<' then unsupported('<FILEHANDLE> or glob') end
        end
        if c == '\\' then
            pos = pos + 1
            tok, tokVal = '\\', nil
            return
        end
        if c == '~' then unsupported('~ operator') end
        if c == '`' then unsupported('`command`') end
        local word = smatch(code, '^[A-Za-z_][A-Za-z0-9_]*', pos)
        if word then
            pos = pos + #word
            -- a package-qualified name (Image::ExifTool::ConvertFileSize):
            -- one word, which the caller's funcs resolve
            while ssub(code, pos, pos + 1) == '::' do
                local part = smatch(code, '^::([A-Za-z_][A-Za-z0-9_]*)', pos)
                if not part then unsupported('package name ' .. word .. '::') end
                word = word .. '::' .. part
                pos = pos + 2 + #part
            end
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
            elseif word == 'qw' then
                if d ~= '' and not smatch(d, '[A-Za-z0-9_ \t\n\r\f\v=,;)]') then
                    pos = pos + 1
                    local words = {}
                    for w in sgmatch(delimited(d), '[^ \t\n\r\f\v]+') do words[#words + 1] = w end
                    tok, tokVal = 'qw', words
                    return
                end
            elseif word == 'qx' then
                -- (a command, like `...`: never run)
                if d ~= '' and not smatch(d, '[A-Za-z0-9_ \t\n\r\f\v=,;)]') then
                    unsupported('qx' .. d .. '...' .. (EVAL_CLOSE[d] or d) .. ' command')
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
                if op == '...' then unsupported('... operator') end
                pos = pos + #op
                tok, tokVal = op, nil
                return
            end
        end
        unsupported("character '" .. c .. "'")
    end
    -- variables ...........................................................
    -- A variable or element is given by a descriptor; `k` says what it is:
    --   (none)    { name }            the scalar $name
    --   'h'       { name, key }       the element $name{key} of the hash %name
    --             { name, keyFn = F } (the key F yields), hkey: '%name' for
    --                                 a `my` hash
    --   'a'       { name, idx = F }   the element $name[F] of the array @name
    --   'elem'    { kind, base, key | keyFn | idx }
    --                                 an element of the array (kind 'ARRAY')
    --                                 or hash ('HASH') a reference refers
    --                                 to: base is { place = D } (the
    --                                 reference in the variable or element D,
    --                                 which an undef there becomes, as Perl
    --                                 autovivifies) or { fn = F } (the one F
    --                                 yields)
    --   'sderef'  { base }            $$name, ${EXPR}: what a SCALAR
    --                                 reference refers to
    --   'array'   { array = name }    @name
    --   'aderef'  { base }            @$name, @{EXPR}
    --   'hash'    { name, hkey }      %name
    --   'hderef'  { base }            %$name, %{EXPR}
    --   'aslice'  { array = name | base, idx = F }    @name[LIST]
    --   'hslice'  { hashD = D | base, keys = F }      @name{LIST}
    --   'lastidx' { array = name | base }             $#name
    --   'list'    { list = { descriptors } }          (A, B) and my (A, B)
    --   'skip'    {}                  undef in a list assignment
    --   'cap'     { cap = N }         $N;  'amp' { amp = true }: $&
    local Alias, Ctl, alen = EV.Alias, EV.Ctl, EV.alen
    local lvalues = setmetatable({}, { __mode = 'k' })  -- closure -> variable it reads
    local listForm = setmetatable({}, { __mode = 'k' }) -- closure -> its list-context form
    local function listOf(f) return (listForm[f] or f)() end
    local hasAlias = false      -- (compile time: the code takes a reference to a scalar variable)
    local aliasedVars = false   -- (run time: a caller's variable is aliased)
    -- (the table that holds a variable: the `my` variables, or the caller's)
    local function store(name)
        if declared[name] then return lex end
        return vars
    end
    -- the list value of @name (nil if it does not exist, unless create); a
    -- caller passes an array (exiftool's @val) as a plain sequence under its
    -- plain name
    local function getArray(name, create)
        local key = '@' .. name
        local st = store(key)
        local t = st[key]
        if t == nil and st == vars then
            local v = vars[name]
            if type(v) == 'table' and getmetatable(v) == nil and
               (v[1] ~= nil or next(v) == nil or mtype(rawget(v, 'n')) == 'integer') then
                local len = EV.alen(v)
                t = newList({ tunpack(v, 1, len) }, len)
                vars[key] = t
            end
        end
        if t == nil and create then
            t = newList({}, 0)
            st[key] = t
        end
        return t
    end
    -- the hash %name of descriptor d (nil if there is none, unless create);
    -- a caller passes a hash (exiftool's %info) under its plain name
    local function hashVar(d, create)
        local h
        if d.hkey then
            h = lex[d.hkey]
            if h == nil and create then
                h = setmetatable({}, PerlHash)
                lex[d.hkey] = h
            end
            return h
        end
        h = vars[d[1]]
        if type(h) == 'table' then return h end
        if h == nil and create then
            h = setmetatable({}, PerlHash)
            vars[d[1]] = h
        end
        return h
    end
    -- (what a reference used as KIND refers to; Perl's error for anything
    --  else -- the code runs under `use strict`, as upstream's evals do)
    local REF_NAME = { ARRAY = 'an ARRAY', HASH = 'a HASH', SCALAR = 'a SCALAR' }
    local function badRef(r, kind)
        if r == nil then
            perl.die("Can't use an undefined value as " .. REF_NAME[kind] .. ' reference at (eval 1) line 1.\n')
        end
        if type(r) ~= 'table' or getmetatable(r) == UV then
            -- (the string shown as Perl's %-32p does: at most 32 characters)
            local str = perlStr(r)
            local shown = #str > 32 and '"' .. ssub(str, 1, 32) .. '"...' or '"' .. str .. '"'
            perl.die("Can't use string (" .. shown .. ') as ' .. REF_NAME[kind] ..
                     ' ref while "strict refs" in use at (eval 1) line 1.\n')
        end
        perl.die('Not ' .. REF_NAME[kind] .. ' reference at (eval 1) line 1.\n')
    end
    local function asArray(r)
        if type(r) == 'table' then
            local mt = getmetatable(r)
            if mt == ARef then return r.arr end
            -- (a sequence of the caller's: the port's shape of an array reference)
            if mt == nil and r.ref == nil and (perl.ref(r) == 'ARRAY' or mtype(rawget(r, 'n')) == 'integer') then
                return r
            end
        end
        badRef(r, 'ARRAY')
    end
    local function asHash(r)
        if type(r) == 'table' then
            local mt = getmetatable(r)
            if mt == PerlHash then return r end
            -- (a table of the caller's that is no array, an empty one, an object)
            if mt == nil then
                if r.ref == nil and (next(r) == nil or perl.ref(r) == 'HASH') then return r end
            elseif mt ~= ARef and mt ~= UV and mt ~= PerlList and mt ~= Alias then
                return r
            end
        end
        badRef(r, 'HASH')
    end
    local function asScalar(r)
        if type(r) == 'table' and (getmetatable(r) == nil or getmetatable(r) == ElemRef) and r.ref == 'SCALAR' then
            return r
        end
        badRef(r, 'SCALAR')
    end
    local AS_REF = { ARRAY = asArray, HASH = asHash, SCALAR = asScalar }
    local NEW_REF = {
        ARRAY = function() return EV.aref(newList({}, 0)) end,
        HASH = function() return setmetatable({}, PerlHash) end,
        SCALAR = function() return { ref = 'SCALAR' } end,
    }
    local getVar, setVar
    -- the array, hash or scalar box (kind) a base refers to; create: an
    -- undef in the base's variable or element becomes a new one
    local function container(b, kind, create)
        local r
        if b.place then
            r = sc(getVar(b.place))
            if r == nil and create then
                r = NEW_REF[kind]()
                setVar(b.place, r)
            end
        else
            r = sc(b.fn())
        end
        return AS_REF[kind](r)
    end
    -- the array of an array descriptor ('array', 'aderef', and the 'aslice'
    -- and 'lastidx' ones), or nil
    local function arrayOf(d, create)
        if d.array then return getArray(d.array, create) end
        return container(d.base, 'ARRAY', create)
    end
    -- the hash of a hash descriptor ('hash', 'hderef'), or nil
    local function hashOf(d, create)
        if d.base then return container(d.base, 'HASH', create) end
        return hashVar(d.hashD or d, create)
    end
    -- the key of a hash element (an undef one warns, as Perl does)
    local varName = setmetatable({}, { __mode = 'k' })  -- closure -> function() name, exists
    local warnUninit
    local function keyOf(d)
        local key = d.key
        if key ~= nil then return key end
        if d[2] ~= nil then return d[2] end
        local v = sc(d.keyFn())
        if v == nil then
            warnUninit('hash element', varName[d.keyFn], true)
            return ''
        end
        return perlStr(v)
    end
    -- h[key], also where a table of the caller's has the number for a key
    -- that is an integer
    local function hget(h, key)
        local v = h[key]
        if v == nil and getmetatable(h) ~= PerlHash then
            local b = sbyte(key, 1)
            if b and (b <= 57 and b >= 48 or b == 45) then
                local num = mtointeger(tonumber(key))
                if num and sformat('%d', num) == key then v = h[num] end
            end
        end
        return v
    end
    -- the 0-based index of an array element (negative: from the end)
    local function indexOf(d, arr)
        local i = intVal(sc(d.idx()))
        if i < 0 then i = i + alen(arr) end
        return i
    end
    -- the value in c[k], and c[k] = val: a scalar variable a reference
    -- aliases holds its value in the box (see `\`); an array's length
    -- follows its last element
    local function cget(c, key)
        local val = c[key]
        if type(val) == 'table' and getmetatable(val) == Alias then return val.cell.value end
        return val
    end
    local function cset(c, key, val)
        local old = c[key]
        if type(old) == 'table' and getmetatable(old) == Alias then
            old.cell.value = val
        else
            c[key] = val
            if getmetatable(c) == PerlList and mtype(key) == 'integer' and key > c.n then c.n = key end
        end
        return val
    end
    -- where a scalar place is: the table and key (for an array element the
    -- 1-based index; nil for a negative index beyond the start), nil for a
    -- read-only one ($1, $&); its containers are created
    local function locate(d, create)
        local k = d.k
        if k == nil then return store(d[1]), d[1] end
        if k == 'h' then return hashVar(d, true), keyOf(d) end
        if k == 'a' then
            local arr = getArray(d[1], true)
            local i = indexOf(d, arr)
            return arr, i >= 0 and i + 1 or nil
        end
        if k == 'elem' then
            local c = container(d.base, d.kind, true)
            if d.kind == 'HASH' then return c, keyOf(d) end
            local i = indexOf(d, c)
            return c, i >= 0 and i + 1 or nil
        end
        if k == 'sderef' then return container(d.base, 'SCALAR', create), 'value' end
        return nil
    end
    -- the elements of a list as Perl assigns them to a hash
    local function fillHash(h, src, what)
        if src.n % 2 == 1 then
            perl.warn('Odd number of elements in ' .. (what or 'hash assignment') .. ' at (eval 1) line 1.\n')
        end
        for i = 1, src.n, 2 do
            local key = src[i]
            if key == nil then
                warnUninit(what or 'list assignment', nil, false)
                key = ''
            end
            h[perlStr(key)] = src[i + 1]
        end
        return h
    end
    -- replace the elements of the array arr (in place: a reference to it
    -- sees the new ones) by those of the list src
    local function fillArray(arr, src)
        local old = alen(arr)
        for i = 1, src.n do arr[i] = src[i] end
        for i = src.n + 1, old do arr[i] = nil end
        if getmetatable(arr) == PerlList then arr.n = src.n end
        return arr
    end
    -- (the keys of a hash in Perl's string order: Perl's own order is
    --  unpredictable, so this one is as good, and repeatable -- without the
    --  port's _ordered_keys_ list of a struct)
    -- (returns the key strings, and the table keys by key string)
    local function hashKeys(h)
        local list, orig = {}, {}
        if h then
            for k in pairs(h) do
                if k ~= '_ordered_keys_' then
                    local key = perlStr(k)
                    list[#list + 1] = key
                    orig[key] = k
                end
            end
        end
        return perl.sort(list, function(x, y) return perl.cmp(x, y) end), orig
    end
    -- a hash in list context: its keys and values
    local function hashList(h)
        local out = newList({}, 0)
        local list, orig = hashKeys(h)
        for _, k in ipairs(list) do
            flatInto(out, k)
            flatInto(out, h[orig[k]])
        end
        return out
    end
    local srcOf = setmetatable({}, { __mode = 'k' })    -- list copy -> the array (or { hash, keys }) it comes from
    -- the list value of an array (a copy of an array of the caller's, which
    -- remembers where its elements come from)
    local function arrayList(arr)
        if getmetatable(arr) == PerlList then return arr end
        local len = alen(arr)
        local out = newList({ tunpack(arr, 1, len) }, len)
        srcOf[out] = arr
        return out
    end
    -- read and write a variable, given its descriptor
    local GET, SET = {}, {}
    getVar = function(v)
        local k = v.k
        if k then return GET[k](v) end
        local val = store(v[1])[v[1]]
        if hasAlias and type(val) == 'table' and getmetatable(val) == Alias then return val.cell.value end
        return val
    end
    setVar = function(v, val)
        local k = v.k
        if k then return SET[k](v, val) end
        return cset(store(v[1]), v[1], sc(val))
    end
    GET.h = function(v)
        local h = hashVar(v)
        if type(h) ~= 'table' then return nil end
        return hget(h, keyOf(v))
    end
    SET.h = function(v, val)
        local h = hashVar(v, true)
        if type(h) ~= 'table' then badRef(h, 'HASH') end
        val = sc(val)
        h[keyOf(v)] = val
        return val
    end
    GET.a = function(v)
        local arr = getArray(v[1])
        if not arr then return nil end
        local i = indexOf(v, arr)
        if i < 0 then return nil end
        return arr[i + 1]
    end
    SET.a = function(v, val)
        val = sc(val)
        local arr = getArray(v[1], true)
        local i = indexOf(v, arr)
        if i < 0 then
            perl.die('Modification of non-creatable array value attempted, subscript ' ..
                     perlStr(i - alen(arr)) .. ' at (eval 1) line 1.\n')
        end
        return cset(arr, i + 1, val)
    end
    GET.elem = function(v)
        local c = container(v.base, v.kind, true)
        if v.kind == 'HASH' then return hget(c, keyOf(v)) end
        local i = indexOf(v, c)
        if i < 0 then return nil end
        return c[i + 1]
    end
    SET.elem = function(v, val)
        val = sc(val)
        local c = container(v.base, v.kind, true)
        if v.kind == 'HASH' then
            c[keyOf(v)] = val
            return val
        end
        local i = indexOf(v, c)
        if i < 0 then
            perl.die('Modification of non-creatable array value attempted, subscript ' ..
                     perlStr(i - alen(c)) .. ' at (eval 1) line 1.\n')
        end
        return cset(c, i + 1, val)
    end
    GET.sderef = function(v) return container(v.base, 'SCALAR', false).value end
    SET.sderef = function(v, val)
        val = sc(val)
        container(v.base, 'SCALAR', true).value = val
        return val
    end
    GET.cap = function(v) return caps[v.cap] end
    GET.amp = function() return lastMatch end
    SET.cap = function() perl.die('Modification of a read-only value attempted at (eval 1) line 1.\n') end
    SET.amp = SET.cap
    GET.skip = function() return nil end
    SET.skip = function() return nil end
    GET.array = function(v) return getArray(v.array) or newList({}, 0) end
    SET.array = function(v, val)
        local src = flatInto(newList({}, 0), val)
        return fillArray(getArray(v.array, true), src)
    end
    GET.aderef = function(v) return arrayList(container(v.base, 'ARRAY', false)) end
    SET.aderef = function(v, val)
        local src = flatInto(newList({}, 0), val)
        local arr = container(v.base, 'ARRAY', true)
        fillArray(arr, src)
        return arrayList(arr)
    end
    GET.hash = function(v) return hashList(hashVar(v)) end
    GET.hderef = function(v) return hashList(container(v.base, 'HASH', false)) end
    local function setHash(h, val)
        local src = flatInto(newList({}, 0), val)
        for key in pairs(h) do h[key] = nil end
        fillHash(h, src)
        return newList({}, src.n)   -- (in scalar context: the number of values)
    end
    SET.hash = function(v, val) return setHash(hashVar(v, true), val) end
    SET.hderef = function(v, val) return setHash(container(v.base, 'HASH', true), val) end
    -- (a slice: in scalar context its last element)
    GET.aslice = function(v)
        local arr = arrayOf(v, true)
        local ix = flatInto(newList({}, 0), listOf(v.idx))
        local out, len = newList({}, ix.n, true), alen(arr)
        for k = 1, ix.n do
            local i = intVal(ix[k])
            if i < 0 then i = i + len end
            if i >= 0 then out[k] = arr[i + 1] end
        end
        return out
    end
    GET.hslice = function(v)
        local h = hashOf(v, true)
        local keys = flatInto(newList({}, 0), listOf(v.keys))
        local out = newList({}, keys.n, true)
        for k = 1, keys.n do out[k] = hget(h, perlStr(keys[k])) end
        return out
    end
    SET.aslice = function(v, val)
        local src = flatInto(newList({}, 0), val)
        local arr = arrayOf(v, true)
        local ix = flatInto(newList({}, 0), listOf(v.idx))
        for k = 1, ix.n do
            local i = intVal(ix[k])
            if i < 0 then i = i + alen(arr) end
            if i < 0 then
                perl.die('Modification of non-creatable array value attempted, subscript ' ..
                         perlStr(i - alen(arr)) .. ' at (eval 1) line 1.\n')
            end
            cset(arr, i + 1, src[k])
        end
        return newList({}, src.n)
    end
    SET.hslice = function(v, val)
        local src = flatInto(newList({}, 0), val)
        local h = hashOf(v, true)
        local keys = flatInto(newList({}, 0), listOf(v.keys))
        for k = 1, keys.n do h[perlStr(keys[k])] = src[k] end
        return newList({}, src.n)
    end
    GET.lastidx = function(v)
        local arr
        if v.array then arr = getArray(v.array) else arr = container(v.base, 'ARRAY', true) end
        if not arr then return -1 end
        return alen(arr) - 1
    end
    SET.lastidx = function(v, val)
        local arr = arrayOf(v, true)
        local len, new = alen(arr), intVal(sc(val)) + 1
        if new < 0 then new = 0 end
        for i = new + 1, len do arr[i] = nil end
        if getmetatable(arr) == PerlList then arr.n = new end
        return new - 1
    end
    GET.list = function(v)
        local out = newList({}, 0, true)
        for _, d in ipairs(v.list) do flatInto(out, getVar(d)) end
        return out
    end
    -- (the places that take a list in an assignment: the rest of the values)
    local LIST_PLACE = { array = 1, aderef = 1, hash = 1, hderef = 1, aslice = 1, hslice = 1, list = 1 }
    SET.list = function(v, val)
        local src = flatInto(newList({}, 0), val)
        local i = 0
        for _, d in ipairs(v.list) do
            if d.k == 'array' or d.k == 'aderef' or d.k == 'hash' or d.k == 'hderef' then
                local rest = newList({}, 0)     -- (an array or hash takes the rest)
                for j = i + 1, src.n do flatInto(rest, src[j]) end
                setVar(d, rest)
                i = src.n
            elseif d.k == 'aslice' or d.k == 'hslice' then
                local cnt = flatInto(newList({}, 0), listOf(d.idx or d.keys)).n
                local part = newList({}, 0)
                for j = i + 1, i + cnt do flatInto(part, src[j]) end
                part.n = cnt
                setVar(d, part)
                i = i + cnt
            else
                i = i + 1
                setVar(d, src[i])
            end
        end
        return newList({}, src.n)   -- (in scalar context: the number of values)
    end
    -- void context ........................................................
    -- Perl's compile-time warning "Useless use of WHAT in void context"
    -- (op.c's scalarvoid) for a term whose value is thrown away: a
    -- statement other than the last one of the code (whose value the eval
    -- returns) or of a block (whose value is the block's), and what such a
    -- statement passes the void context on to -- both operands of `,`, the
    -- right one of && || // and or, both branches of ?:, the body of a
    -- statement modifier or of if/unless.  WHAT is the operator's name in
    -- Perl's op table, "a variable"/"private variable" (a package or a `my`
    -- one; the caller's variables are `my` ones in exiftool, except $_, the
    -- sort variables $a and $b and the names in globals), or "a constant
    -- (VALUE)" -- for a literal and for an operator Perl folds at compile
    -- time because its operands are literals (see fold), except 0 and 1
    -- and what a comparison or && || // folded.  Calls, assignments,
    -- matches and the other terms with side effects never warn.  A block
    -- warns about its statements when it is closed, the code about its own
    -- at the end of the compilation: all before anything runs, also for a
    -- statement that never runs, and not for code a literal condition makes
    -- unreachable (`... if 0`).
    local voidUse = setmetatable({}, { __mode = 'k' })  -- closure -> WHAT
    local voidKids = setmetatable({}, { __mode = 'k' }) -- closure -> closures it passes void context to
    local folded = setmetatable({}, { __mode = 'k' })   -- closure -> { value, quiet = no warning }
    -- is the variable of this name and sigil ('$', '@' or '%') a `my` one?
    local function isLexical(name, sigil)
        if declared[sigil == '@' and '@' .. name or name] then return true end
        if sigil == '$' and (name == 'a' or name == 'b') then return false end
        return not (name == '_' or (globals and globals[name]))
    end
    -- WHAT for a variable descriptor (see getVar)
    local function varUse(d)
        local k = d.k
        if k == nil then return isLexical(d[1], '$') and 'private variable' or 'a variable' end
        if k == 'h' or k == 'elem' and d.kind == 'HASH' then return 'hash element' end
        if k == 'a' or k == 'elem' then return 'array element' end
        if k == 'aslice' then return 'array slice' end
        if k == 'hslice' then return 'hash slice' end
        if k == 'lastidx' then return 'array length' end
        return 'a variable'
    end
    -- the constant string s as Perl's pv_pretty shows it in the warning:
    -- quoted, with \" \\ \t \n \r \f \v and octal escapes, at most 32
    -- characters of it and "..." after a longer one
    local PRETTY_ESC = { [9] = '\\t', [10] = '\\n', [11] = '\\v', [12] = '\\f', [13] = '\\r',
                         [34] = '\\"', [92] = '\\\\' }
    local function prettyConst(str)
        local out, len = {}, 0
        for i = 1, #str do
            local c = sbyte(str, i)
            local e = PRETTY_ESC[c]
            if not e then
                if c >= 32 and c < 127 then
                    e = schar(c)
                elseif smatch(ssub(str, i + 1, i + 1), '^[0-9]') then
                    e = sformat('\\%03o', c)     -- (a digit follows)
                else
                    e = sformat('\\%o', c)
                end
            end
            if len + #e > 32 then return '"' .. tconcat(out) .. '"...' end
            out[#out + 1] = e
            len = len + #e
        end
        return '"' .. tconcat(out) .. '"'
    end
    local function voidWarn(what)
        compileWarns[#compileWarns + 1] = 'Useless use of ' .. what .. ' in void context at (eval 1) line 1.\n'
    end
    -- warn for the closure f in void context
    local function inVoid(f)
        local c = folded[f]
        if c then
            if c.quiet then return end
            local v = c[1]
            if type(v) == 'string' then
                voidWarn('a constant (' .. prettyConst(v) .. ')')
            elseif v ~= 0 and v ~= 1 then
                voidWarn('a constant (' .. perlStr(v) .. ')')
            end
            return
        end
        local kids = voidKids[f]
        if kids then
            for _, k in ipairs(kids) do inVoid(k) end
        elseif voidUse[f] then
            voidWarn(voidUse[f])
        end
    end
    -- a closure used in scalar context: the left operand of a comma
    -- operator is then in void context (and the right one in scalar
    -- context), as is what passes its context on (see voidKids)
    local commaOf = setmetatable({}, { __mode = 'k' })  -- comma closure -> { left, right }
    local function scalarCtx(f)
        local c = commaOf[f]
        if c then
            inVoid(c[1])
            scalarCtx(c[2])
        elseif voidKids[f] then
            for _, k in ipairs(voidKids[f]) do scalarCtx(k) end
        end
        return f
    end
    -- statements in void context: all but the last one
    local function voidStatements(stmts)
        for k = 1, #stmts - 1 do inVoid(stmts[k]) end
    end
    -- Perl's constant folding: an operator whose operands (closures args)
    -- are all constants is evaluated at compile time, unless that warns or
    -- dies; the closure f then counts as the constant (quiet: a comparison
    -- or a logical operator, whose result does not warn in void context).
    -- Returns f.
    local function fold(f, args, quiet)
        for i = 1, #args do
            if not folded[args[i]] then return f end
        end
        local warned
        local oldTrap = warnTrap
        warnTrap = function() warned = true end
        local ok, v = pcall(f)
        warnTrap = oldTrap
        if ok and not warned and v ~= nil and (type(v) ~= 'table' or getmetatable(v) == UV) then
            folded[f] = { v, quiet = quiet }
        end
        return f
    end
    -- warnings ............................................................
    -- Perl's "Use of uninitialized value NAME in OP" (perl -w, which the
    -- exiftool script runs under): NAME is the variable that is undef, as
    -- Perl's find_uninit_var reports it -- given for an operand that is the
    -- only non-constant one of its operator; with several, only for a
    -- variable that exists (a scalar, a hash element of a hash the caller
    -- passes -- exiftool's %info holds every tag the expression names --,
    -- an array element inside the array), never for an element reached
    -- through a reference ($$self{X}).
    local constant = setmetatable({}, { __mode = 'k' }) -- closure -> true for a defined literal
    local function descName(d)
        local k = d.k
        if k == nil then return '$' .. d[1], true end
        if k == 'cap' then return '$' .. d.cap, true end
        if k == 'amp' then return '$&', true end
        if k == 'a' then
            -- (the index as Perl shows it, evaluated -- only an index
            --  without side effects: a literal or a plain variable)
            local i = d.idxNum
            if not i then
                if not (constant[d.idx] or varName[d.idx]) then return nil end
                i = intVal(sc(d.idx()))
            end
            local arr = getArray(d[1])
            local cnt = arr and alen(arr) or 0
            return '$' .. d[1] .. '[' .. perlStr(i) .. ']', i < cnt and i >= -cnt
        end
        if k == 'h' then
            local key = d[2]
            if key == nil then
                -- (a computed key: the same, a literal or a plain variable)
                if not (constant[d.keyFn] or varName[d.keyFn]) then return nil end
                key = sc(d.keyFn())
                if key == nil then return nil end
                key = perlStr(key)
            end
            return '$' .. d[1] .. '{"' .. key .. '"}', true
        end
        return nil
    end
    local function nameOf(d) return function() return descName(d) end end
    local NAME_ = nameOf({ '_' })
    -- warn for an undef value used in desc; nameFn names it (or nil),
    -- single: it is the only non-constant operand
    warnUninit = function(desc, nameFn, single)
        local name
        if nameFn then
            local nm, exists = nameFn()
            if nm and (single or exists) then name = nm end
        end
        perl.warn('Use of uninitialized value ' .. (name and name .. ' ' or '') .. 'in ' .. desc ..
                  ' at (eval 1) line 1.\n')
    end
    -- the operand value v (of closure f) as a number for operator op:
    -- warns for undef and for a string that is not a number, like Perl
    local function numArg(v, f, op, single)
        if v == nil then
            warnUninit(NUM_OPS[op] or op, varName[f], single)
            return 0
        end
        return perl.num(v, op)
    end
    -- the operand value v (of closure f) as a string for desc
    local function strArg(v, f, desc, single)
        if v == nil then
            warnUninit(desc, varName[f], single)
            return ''
        end
        return perlStr(v)
    end
    local expr, block, subCode, subExpr     -- (the parser, below)
    -- interpolation ........................................................
    -- A double-quoted string ('str'), a regex ('re': backslash sequences
    -- stay for the regex compiler, a '$' before ')' or '|' or at the end is
    -- the anchor) or a s/// replacement ('repl': \1 is $1) is compiled once
    -- into parts: literal text, variables ($name, ${name}, $name{key},
    -- $name{'key'}, $$name{key}, $name[N], $1.., $&, @name) and the case
    -- modifiers \U \L \F \Q \E \u \l.  Returns the function that builds the
    -- string (its argument: what an undef variable is used in, for the
    -- warning) and whether the text is constant, plus the number of
    -- variables and whether the text is one variable and nothing else.
    -- (the element $name{key} of %name, or of the hash $name refers to)
    local function interpHash(dr, name, key)
        if dr ~= '' then return { k = 'elem', kind = 'HASH', base = { place = { name } }, key = key } end
        return { k = 'h', name, key, hkey = declared['%' .. name] and '%' .. name or nil }
    end
    local INTERP_VAR = {
        { '^%${([A-Za-z_][A-Za-z0-9_]*)}()', function(name) return { name } end },
        { "^%$(%$?)([A-Za-z_][A-Za-z0-9_]*){'([^']*)'}()", interpHash },
        { '^%$(%$?)([A-Za-z_][A-Za-z0-9_]*){"([^"]*)"}()', interpHash },
        { '^%$(%$?)([A-Za-z_][A-Za-z0-9_]*){([A-Za-z0-9_]*)}()', interpHash },
        { '^%$([A-Za-z_][A-Za-z0-9_]*)%[(%-?%d+)%]()', function(name, idx)
            local num = tonumber(idx)
            local f = function() return num end
            constant[f] = true
            return { k = 'a', name, idx = f }
        end },
        { '^%$(%d+)()', function(d) return { k = 'cap', cap = tonumber(d) } end },
        { '^%$&()', function() return { k = 'amp', amp = true } end },
        { '^%$([A-Za-z_][A-Za-z0-9_]*)()', function(name) return { name } end },
    }
    -- (the position after the bracket at j and its match, or nil)
    local function bracketEnd(str, j)
        local open = ssub(str, j, j)
        local close, depth = EVAL_CLOSE[open], 0
        while j <= #str do
            local c = ssub(str, j, j)
            if c == '\\' then
                j = j + 1
            elseif c == open then
                depth = depth + 1
            elseif c == close then
                depth = depth - 1
                if depth == 0 then return j + 1 end
            end
            j = j + 1
        end
        return nil
    end
    -- the end (the position after it) of the variable expression at i in an
    -- interpolated string: $name, $$name or ${...} with the subscripts that
    -- follow ([...], {...}, ->[...], ->{...}; in a pattern only the ones
    -- after an arrow, as [ and { can be a character class or a quantifier
    -- there), @name, @$name or @{...} with one slice subscript; nil if there
    -- is none
    local function interpExtent(str, i, mode, noSub)
        local sigil, j = ssub(str, i, i), i + 1
        while ssub(str, j, j) == '$' do j = j + 1 end
        if ssub(str, j, j) == '{' then
            j = bracketEnd(str, j)
            if not j then return nil end
        else
            local name = smatch(str, '^[A-Za-z_][A-Za-z0-9_]*', j)
            if not name then return nil end
            j = j + #name
            if ssub(str, j, j + 1) == '::' then return nil end
        end
        while not noSub do
            local at, c = j, ssub(str, j, j)
            if ssub(str, j, j + 1) == '->' then
                at = j + 2
                c = ssub(str, at, at)
                if c ~= '[' and c ~= '{' then break end
            elseif (c ~= '[' and c ~= '{') or mode == 're' then
                break
            end
            local e = bracketEnd(str, at)
            if not e then break end
            j = e
            if sigil == '@' then break end      -- (a slice)
        end
        return j
    end
    local function compileInterp(str, mode)
        local parts, nVars, i, len = {}, 0, 1, #str
        local static = true
        local function lit(t)
            local last = parts[#parts]
            if last and last.lit then last.lit = last.lit .. t else parts[#parts + 1] = { lit = t } end
        end
        while i <= len do
            local c = ssub(str, i, i)
            if c == '\\' and i < len then
                local e = ssub(str, i + 1, i + 1)
                i = i + 2
                if sfind('ULFQEul', e, 1, true) then
                    parts[#parts + 1] = { ctl = e }
                    static = false
                elseif mode == 're' then
                    lit('\\' .. e)
                elseif mode == 'repl' and smatch(e, '^[1-9]') then
                    parts[#parts + 1] = { var = { cap = tonumber(e) } }
                    nVars = nVars + 1
                    static = false
                elseif e == 'x' then
                    local hex = smatch(str, '^{([0-9A-Fa-f]*)}', i)
                    if hex then
                        i = i + #hex + 2
                    else
                        hex = smatch(str, '^[0-9A-Fa-f]?[0-9A-Fa-f]?', i)
                        i = i + #hex
                    end
                    lit(perl.chr(tonumber(hex, 16) or 0))
                elseif smatch(e, '^[0-7]') then
                    local oct = e .. smatch(str, '^[0-7]?[0-7]?', i)
                    i = i + #oct - 1
                    lit(schar(tonumber(oct, 8) & 0xff))
                else
                    lit(EVAL_ESC[e] or e)
                end
            elseif c == '$' then
                local nx = ssub(str, i + 1, i + 1)
                local d, newPos
                if not (mode == 're' and (nx == '' or nx == ')' or nx == '|')) then
                    for _, form in ipairs(INTERP_VAR) do
                        local r = { smatch(str, form[1], i) }
                        if r[1] ~= nil then
                            newPos = tremove(r)
                            d = form[2](tunpack(r))
                            break
                        end
                    end
                end
                -- (a longer variable expression: compiled as code)
                local ext = d and d.k ~= 'cap' and d.k ~= 'amp' and interpExtent(str, i, mode)
                if nx == '#' and mode ~= 're' then
                    -- ($#name, $#$name, $#{...}: the last index)
                    ext = interpExtent(str, i + 1, mode, true)
                end
                if not d and nx == '{' and mode ~= 're' then ext = interpExtent(str, i, mode) end
                if not d and nx == '$' and mode ~= 're' then ext = interpExtent(str, i, mode) end
                if ext and ext > (newPos or i + 1) then
                    parts[#parts + 1] = { fn = subExpr(ssub(str, i, ext - 1)) }
                    nVars = nVars + 1
                    static = false
                    i = ext
                elseif d then
                    parts[#parts + 1] = { var = d }
                    nVars = nVars + 1
                    static = false
                    i = newPos
                else
                    lit('$')
                    i = i + 1
                end
            elseif c == '@' and smatch(str, '^@[$%[{]', i) and mode ~= 're' then
                -- (@$name, @{...}, and slices: compiled as code)
                local ext = interpExtent(str, i, mode)
                if ext then
                    parts[#parts + 1] = { fn = subExpr(ssub(str, i, ext - 1)), list = true }
                    nVars = nVars + 1
                    static = false
                    i = ext
                else
                    lit('@')
                    i = i + 1
                end
            elseif c == '@' and smatch(str, '^@[A-Za-z_][A-Za-z0-9_]*[[{]', i) and mode ~= 're' then
                local ext = interpExtent(str, i, mode)
                parts[#parts + 1] = { fn = subExpr(ssub(str, i, ext - 1)), list = true }
                nVars = nVars + 1
                static = false
                i = ext
            elseif c == '@' and smatch(str, '^@[A-Za-z_]', i) then
                local name = smatch(str, '^@([A-Za-z_][A-Za-z0-9_]*)', i)
                parts[#parts + 1] = { array = name }
                nVars = nVars + 1
                static = false
                i = i + 1 + #name
            else
                local run = smatch(str, '^[^\\$@]+', i) or c
                lit(run)
                i = i + #run
            end
        end
        local onlyVar = #parts == 1 and (parts[1].var ~= nil or parts[1].fn ~= nil and not parts[1].list)
        if static then
            local text = parts[1] and parts[1].lit or ''
            return function() return text end, true, 0, false
        end
        local single = nVars == 1
        return function(desc)
            local out, stack, caseMode, quote, pending = {}, {}, nil, 0, nil
            local function setModes()
                caseMode, quote = nil, 0
                for k = 1, #stack do
                    if stack[k] == 'Q' then quote = quote + 1 else caseMode = stack[k] end
                end
            end
            local function emit(t)
                if t == '' then return end
                if caseMode == 'U' then t = asciiUpper(t) elseif caseMode then t = asciiLower(t) end
                if pending then
                    local first = ssub(t, 1, 1)
                    t = (pending == 'u' and asciiUpper(first) or asciiLower(first)) .. ssub(t, 2)
                    pending = nil
                end
                for _ = 1, quote do t = perl.quotemeta(t) end
                out[#out + 1] = t
            end
            for _, part in ipairs(parts) do
                if part.lit then
                    emit(part.lit)
                elseif part.ctl then
                    local e = part.ctl
                    if e == 'u' or e == 'l' then
                        pending = e
                    elseif e == 'E' then
                        stack[#stack] = nil
                    else
                        -- (a case modifier ends the one before it: \U...\L)
                        if e ~= 'Q' and caseMode then stack[#stack] = nil end
                        stack[#stack + 1] = e
                    end
                    setModes()
                elseif part.array then
                    local arr = getArray(part.array)
                    if not arr then
                        emit('@' .. part.array)     -- (not an array: stays as it is)
                    else
                        local list = {}
                        for k = 1, arr.n do
                            if arr[k] == nil then
                                warnUninit('join or string', nameOf({ k = 'a', part.array, idxNum = k - 1 }), false)
                                list[k] = ''
                            else
                                list[k] = arr[k]
                            end
                        end
                        emit(perl.join(' ', list))
                    end
                elseif part.list then
                    local a, list = flatInto(newList({}, 0), listOf(part.fn)), {}
                    for k = 1, a.n do
                        if a[k] == nil then
                            warnUninit('join or string', nil, false)
                            list[k] = ''
                        else
                            list[k] = a[k]
                        end
                    end
                    emit(perl.join(' ', list))
                else
                    local val
                    if part.fn then val = sc(part.fn()) else val = sc(getVar(part.var)) end
                    if val == nil then
                        warnUninit(onlyVar and desc == 'concatenation (.) or string' and 'string' or desc,
                                   part.fn and varName[part.fn] or nameOf(part.var), single)
                        val = ''
                    end
                    emit(perlStr(val))
                end
            end
            return tconcat(out)
        end, false, nVars, onlyVar
    end
    -- parser: each parse function returns a closure that evaluates the node
    -- a regex pattern (interpolated like a double-quoted string, see
    -- compileInterp) with its flags: returns the function that yields the
    -- compiled regex -- compiled once for a pattern without variables, else
    -- at each use (a cache per distinct pattern text)
    local function patternFn(re, mods)
        local build, static = compileInterp(re, 're')
        local function compile(pat)
            local ok, rx = pcall(lpcreNew, pat, mods .. 'n')
            if not ok then
                perl.die('Invalid regular expression /' .. pat .. '/ at (eval 1) line 1.\n')
            end
            return rx
        end
        if static then
            local rx = compile(build())
            return function() return rx end
        end
        local cache = {}
        return function()
            local pat = build('regexp compilation')
            local rx = cache[pat]
            if not rx then
                rx = compile(pat)
                cache[pat] = rx
            end
            return rx
        end
    end
    -- record $& and the captures of the match r (lpcre.find's result) in s
    local function found(s, r)
        if r[2] < r[1] then
            lastMatch = ''
        elseif isCarray(s) then
            lastMatch = s:tostring(r[1], r[2])
        else
            lastMatch = ssub(s, r[1], r[2])
        end
        caps = { tunpack(r, 3, r.n) }
    end
    -- a regex: returns the scalar matcher (true/false, sets $1..) and the
    -- list-context one (the captures, 1 without groups, () on no match;
    -- with /g every match); both take the subject and the function naming
    -- it (for the warning about an undef subject, which matches as '')
    local function regexFn(re, fl)
        if smatch(fl, '[^imsxgo]') then unsupported('regex flag /' .. fl) end
        local global = sfind(fl, 'g', 1, true)
        -- (Perl's /imsx are lpcre's compile flag letters as well; the code
        --  comes from data, so the regex stays outside the pattern cache)
        local getRx = patternFn(re, sgsub(fl, '[go]', ''))
        local function subject(s, nameFn)
            s = sc(s)
            if s == nil then
                warnUninit('pattern match (m//)', nameFn, true)
                return ''
            end
            if not isCarray(s) then s = perlStr(s) end
            return s
        end
        local function match(s, nameFn)
            local rx = getRx()
            s = subject(s, nameFn)
            local r = tpack(lpcreFind(s, rx, 1))
            if not r[1] then return false end
            found(s, r)
            return true
        end
        local function matchList(s, nameFn)
            local rx = getRx()
            s = subject(s, nameFn)
            local out = newList({}, 0)
            if global then
                local init = 1
                local len = isCarray(s) and s:len() or #s
                while init <= len + 1 do
                    local r = tpack(lpcreFind(s, rx, init))
                    if not r[1] then break end
                    found(s, r)
                    if r.n > 2 then
                        for i = 3, r.n do flatInto(out, r[i]) end
                    else
                        flatInto(out, lastMatch)
                    end
                    init = r[2] >= r[1] and r[2] + 1 or r[1] + 1
                end
                return out
            end
            local r = tpack(lpcreFind(s, rx, 1))
            if not r[1] then return out end
            found(s, r)
            if r.n == 2 then return flatInto(out, 1) end
            for i = 3, r.n do flatInto(out, r[i]) end
            return out
        end
        return match, matchList
    end
    -- s/// or tr/// on the variable v: returns a closure that edits it and
    -- yields Perl's value (the number of substitutions/characters, or '';
    -- with s///r the new string)
    -- (pre: the closure to run first -- the assignment of `($x = $y) =~ s///`)
    local function editFn(kind, parts, v, pre)
        local a, b, fl = parts[1], parts[2], parts[3]
        local vName = nameOf(v)
        if kind == 'subst' then
            local _, nE = sgsub(fl, 'e', '')
            if nE > 1 then unsupported('s///ee') end
            if smatch(fl, '[^gimsxre]') then unsupported('s///' .. sgsub(fl, '[gimsxre]', '') .. ' flag') end
            local getRx = patternFn(a, sgsub(fl, '[gre]', ''))
            -- (the replacement is a double-quoted string, built per match;
            --  an undef variable that is all of it is used "in
            --  substitution (s///)" -- with /e it is code, run per match,
            --  whose undef value is used "in substitution iterator")
            local repl, replDesc
            if nE == 1 then
                local replCode = scalarCtx(subCode(b))
                -- (Perl says "in substitution (s///)" when the code is a
                --  plain scalar variable)
                local d = lvalues[replCode]
                local plain = d and d.k == nil
                local desc = plain and 'substitution (s///)' or 'substitution iterator'
                repl = function()
                    local r = sc(replCode())
                    if r == nil then
                        warnUninit(desc, varName[replCode], true)
                        return ''
                    end
                    return perlStr(r)
                end
            else
                local onlyVar
                repl, _, _, onlyVar = compileInterp(b, 'repl')
                replDesc = onlyVar and 'substitution (s///)' or 'concatenation (.) or string'
            end
            local global = sfind(fl, 'g', 1, true)
            local nondestructive = sfind(fl, 'r', 1, true)
            return function()
                if pre then pre() end
                local rx = getRx()
                local val = sc(getVar(v))
                if val == nil then
                    warnUninit('substitution (s///)', vName, true)
                    val = ''
                end
                val = isCarray(val) and val:tostring() or perlStr(val)
                -- every match from left to right; after an empty match the
                -- next one starts a character further on
                local out, init, last, count, len = {}, 1, 1, 0, #val
                while init <= len + 1 do
                    local r = tpack(lpcreFind(val, rx, init))
                    if not r[1] then break end
                    found(val, r)
                    out[#out + 1] = ssub(val, last, r[1] - 1)
                    out[#out + 1] = repl(replDesc)
                    count = count + 1
                    last = r[2] + 1
                    if not global then break end
                    if r[2] >= r[1] then
                        init = r[2] + 1
                    else
                        if r[1] > len then break end
                        out[#out + 1] = ssub(val, r[1], r[1])
                        last = r[1] + 1
                        init = r[1] + 1
                    end
                end
                if count == 0 then
                    if nondestructive then return val end
                    return ''
                end
                out[#out + 1] = ssub(val, last)
                if nondestructive then return tconcat(out) end
                setVar(v, tconcat(out))
                return count
            end
        end
        if smatch(fl, '[^cdsr]') then unsupported('tr///' .. sgsub(fl, '[cdsr]', '') .. ' flag') end
        local nondestructive = sfind(fl, 'r', 1, true)
        local trFlags = sgsub(fl, 'r', '')
        return function()
            if pre then pre() end
            local val = sc(getVar(v))
            if val == nil then
                -- (Perl names the variable here only when it is a `my` one)
                warnUninit('transliteration (tr///)', v[1] ~= '_' and vName or nil, true)
                val = ''
            end
            local new, count = perl.tr(val, a, b, trFlags)
            if nondestructive then return new end
            if new ~= perlStr(val) then setVar(v, new) end
            return count
        end
    end
    local NONDESTRUCTIVE = { subst = 'non-destructive substitution (s///r)',
                             trans = 'non-destructive transliteration (tr///r)' }
    local unary                 -- (below)
    local loopCtl = 0           -- (compile time: the number of next/last parsed so far)
    local pureRead = setmetatable({}, { __mode = 'k' })     -- closure -> true: it only reads a place
    local parenList = setmetatable({}, { __mode = 'k' })    -- closure -> true: a list in parentheses, qw()
    local doBlock = setmetatable({}, { __mode = 'k' })      -- do-BLOCK closure -> its block
    local constAssign = setmetatable({}, { __mode = 'k' })  -- closure -> true: `$x = CONSTANT`
    -- (Perl's compile-time warning for an assignment of a constant as a
    --  condition: of if/unless, ?:, and the left operand of && || // and or)
    local function condCheck(e)
        if constAssign[e] then
            compileWarns[#compileWarns + 1] = 'Found = in conditional, should be == at (eval 1) line 1.\n'
        end
        return e
    end
    -- (the words after which a list operator has no more arguments, and that
    --  are no label)
    local STMT_WORDS = { ['if'] = 1, unless = 1, ['while'] = 1, ['until'] = 1, ['for'] = 1,
                         foreach = 1, ['else'] = 1, elsif = 1 }
    -- (the tokens that start a term after a list operator, beyond startsTerm's)
    local LIST_TERM = { ['-'] = 1, ['+'] = 1, ['!'] = 1, ['++'] = 1, ['--'] = 1 }
    -- does the current token start a term (an argument without parentheses;
    -- listOp: of a list operator, which takes `-1` as its argument)?
    local function startsTerm(listOp)
        return tok == 'var' or tok == 'num' or tok == 'str' or tok == 'istr' or tok == '(' or
               tok == 'array' or tok == 'regex' or tok == 'subst' or tok == 'trans' or
               tok == 'hash' or tok == '\\' or tok == 'qw' or tok == 'aderef' or tok == 'hderef' or
               tok == 'sderef' or tok == 'lastidx' or tok == '[' or tok == '{' or
               (listOp and LIST_TERM[tok]) or
               (tok == 'word' and not EVAL_BIN[tokVal] and not STMT_WORDS[tokVal])
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
    -- the flattened values of argument closures (list context); with desc,
    -- an undef value among them warns as used in desc (after all are
    -- evaluated, as the builtin sees them)
    local function flatArgs(args, desc)
        local a = newList({}, 0)
        local vals = {}
        for i = 1, #args do
            vals[i] = listOf(args[i])
            flatInto(a, vals[i])
        end
        if desc then
            for i = 1, #args do
                local v = vals[i]
                if getmetatable(v) == PerlList then
                    local d = lvalues[args[i]]
                    for k = 1, v.n do
                        if v[k] == nil then
                            warnUninit(desc, d and d.k == 'array' and nameOf({ k = 'a', d.array, idxNum = k - 1 }), false)
                        end
                    end
                elseif v == nil then
                    warnUninit(desc, varName[args[i]], #args == 1)
                end
            end
        end
        return a
    end
    -- the elements of the lists args yields, for a loop or map/grep that
    -- aliases them: returns the elements, their number, and for each one
    -- the table and key it comes from (an array element, a hash value, a
    -- variable) or, ro, true for a literal
    local function aliasItems(args)
        local items, cs, ks, ro, cnt = {}, {}, {}, {}, 0
        local function addItems(a)
            local comma = commaOf[a]
            if comma then
                addItems(comma[1])
                addItems(comma[2])
                return
            end
            local d = lvalues[a]
            if d and (d.k == 'array' or d.k == 'aderef') then
                -- (an array: created, as Perl's foreach does)
                local arr = arrayOf(d, true)
                for j = 1, alen(arr) do
                    cnt = cnt + 1
                    items[cnt], cs[cnt], ks[cnt] = arr[j], arr, j
                end
                return
            end
            local v = listOf(a)
            if getmetatable(v) == PerlList then
                local src = srcOf[v]
                for j = 1, v.n do
                    cnt = cnt + 1
                    items[cnt] = v[j]
                    if src and src.hash then
                        cs[cnt], ks[cnt] = src.hash, src.keys[j]
                    else
                        cs[cnt], ks[cnt] = src or v, j
                    end
                end
            else
                cnt = cnt + 1
                items[cnt] = v
                if d and d.k ~= 'list' and not LIST_PLACE[d.k] and d.k ~= 'cap' and d.k ~= 'amp' then
                    cs[cnt], ks[cnt] = locate(d, true)
                elseif constant[a] then
                    ro[cnt] = true
                end
            end
        end
        for i = 1, #args do addItems(args[i]) end
        return items, cnt, cs, ks, ro
    end
    -- after the body ran with the element `item` in the variable st[name]:
    -- the variable's value goes back where the element came from, if it
    -- changed
    local function writeBack(st, name, item, c, key, readOnly)
        local now = st[name]
        if type(now) == 'table' and getmetatable(now) == Alias then now = now.cell.value end
        if rawequal(now, item) then return end
        if c then
            cset(c, key, now)
        elseif readOnly then
            perl.die('Modification of a read-only value attempted at (eval 1) line 1.\n')
        end
    end
    -- split /RE/, EXPR, LIMIT (current token: the word split)
    local function parseSplit()
        nextTok()
        local paren = tok == '('
        if paren then nextTok() end
        local rxPat, rxFn, patFn, strFn, limFn
        if tok == 'regex' then
            local re, fl = tokVal[1], tokVal[2]
            if smatch(fl, '[^imsx]') then unsupported('split flag /' .. fl) end
            -- (/ / is a single space; only the string ' ' is the awk mode)
            if re == ' ' then re = '[ ]' end
            local prefix = fl ~= '' and '(?' .. fl .. ')' or ''
            local build, static = compileInterp(re, 're')
            if static then
                rxPat = prefix .. build()
            else
                rxFn = function() return prefix .. build('regexp compilation') end
            end
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
            local pat = rxPat or (rxFn and rxFn()) or perlStr(sc(patFn()))
            local s
            if strFn then s = sc(strFn()) else s = getVar({ '_' }) end
            if s == nil then warnUninit('split', strFn and varName[strFn] or NAME_, true) end
            local lim = limFn and intVal(sc(limFn())) or nil
            local t = perl.splitDyn(pat, perlStr(s), lim)
            return newList(t, #t)
        end
    end
    -- the array operand of push, unshift, shift, pop, splice (@name,
    -- @$name, @{EXPR}); nil when there is none
    local function arrayOperand(name)
        if tok ~= 'array' and tok ~= 'aderef' then return nil end
        local e = unary()
        local d = lvalues[e]
        if not d or (d.k ~= 'array' and d.k ~= 'aderef') then unsupported(name .. ' on an array expression') end
        return d
    end
    -- push/unshift ARRAY, LIST (current token: the word): in place, as a
    -- reference to the array sees it
    local function parsePush(name)
        nextTok()
        local paren = tok == '('
        if paren then nextTok() end
        local d = arrayOperand(name)
        if not d then unsupported(name .. ' on an array expression') end
        local args = {}
        while tok == ',' or tok == '=>' do
            nextTok()
            args[#args + 1] = expr(3.5)
        end
        if paren then
            if tok ~= ')' then evalDie(code, pos) end
            nextTok()
        end
        return function()
            local items = flatArgs(args)
            local arr = arrayOf(d, true)
            local len = alen(arr)
            if name == 'unshift' then
                for i = len, 1, -1 do arr[i + items.n] = arr[i] end
                for i = 1, items.n do arr[i] = items[i] end
            else
                for i = 1, items.n do arr[len + i] = items[i] end
            end
            if getmetatable(arr) == PerlList then arr.n = len + items.n end
            return len + items.n
        end
    end
    -- shift/pop ARRAY (current token: the word): the element removed (undef
    -- for an empty array)
    local function parseShift(name)
        nextTok()
        local paren = tok == '('
        if paren then nextTok() end
        local d = arrayOperand(name)
        -- (without an array: @_ of a sub, or @ARGV)
        if not d then unsupported(name .. ' without an array') end
        if paren then
            if tok ~= ')' then evalDie(code, pos) end
            nextTok()
        end
        return function()
            local arr = arrayOf(d, true)
            local len = alen(arr)
            if len == 0 then return nil end
            local v
            if name == 'shift' then
                v = arr[1]
                for i = 1, len - 1 do arr[i] = arr[i + 1] end
            else
                v = arr[len]
            end
            arr[len] = nil
            if getmetatable(arr) == PerlList then arr.n = len - 1 end
            return v
        end
    end
    -- splice ARRAY, OFFSET, LENGTH, LIST (current token: the word): the
    -- elements removed, in scalar context the last of them
    local function parseSplice()
        nextTok()
        local paren = tok == '('
        if paren then nextTok() end
        local d = arrayOperand('splice')
        if not d then unsupported('splice without an array') end
        local args = {}
        while tok == ',' or tok == '=>' do
            nextTok()
            args[#args + 1] = expr(3.5)
        end
        if paren then
            if tok ~= ')' then evalDie(code, pos) end
            nextTok()
        end
        local f = function()
            local arr = arrayOf(d, true)
            local size = alen(arr)
            local off = args[1] and intVal(sc(args[1]())) or 0
            if off < 0 then off = off + size end
            if off > size then
                perl.warn('splice() offset past end of array at (eval 1) line 1.\n')
                off = size
            end
            if off < 0 then perl.die('Modification of non-creatable array value attempted, subscript ' ..
                                     perlStr(off - size) .. ' at (eval 1) line 1.\n') end
            local len = size - off
            if args[2] then
                len = intVal(sc(args[2]()))
                if len < 0 then len = size - off + len end
                if len < 0 then len = 0 end
                if off + len > size then len = size - off end
            end
            local new = newList({}, 0)
            for i = 3, #args do flatInto(new, listOf(args[i])) end
            local removed = newList({}, 0, true)
            for i = 1, len do
                removed.n = i
                removed[i] = arr[off + i]
            end
            local all = newList({}, 0)
            for i = 1, off do all.n = i all[i] = arr[i] end
            for i = 1, new.n do all.n = all.n + 1 all[all.n] = new[i] end
            for i = off + len + 1, size do all.n = all.n + 1 all[all.n] = arr[i] end
            fillArray(arr, all)
            return removed
        end
        return f
    end
    -- my $x, my @a, my %h, my ($x, @a, %h, undef) (current token: the word my)
    local function parseMy()
        nextTok()
        local function decl(inList)
            if tok == 'var' and tokVal[1] and not tokVal.deref and not tokVal.k then
                local name = tokVal[1]
                declared[name] = true
                nextTok()
                return { name }
            elseif tok == 'array' then
                local name = tokVal
                declared['@' .. name] = true
                nextTok()
                return { k = 'array', array = name }
            elseif tok == 'hash' and not tokVal.deref then
                local name = tokVal[1]
                declared['%' .. name] = true
                nextTok()
                return { k = 'hash', name, hkey = '%' .. name }
            elseif inList and tok == 'word' and tokVal == 'undef' then
                nextTok()
                return { k = 'skip' }
            end
            unsupported('this kind of my declaration')
        end
        local d
        if tok == '(' then
            nextTok()
            local list = {}
            while tok ~= ')' do
                list[#list + 1] = decl(true)
                if tok == ',' then
                    nextTok()
                elseif tok ~= ')' then
                    evalDie(code, pos)
                end
            end
            nextTok()
            d = { k = 'list', list = list }
        else
            d = decl()
        end
        local function reset(v)
            if v.k == 'list' then
                for _, e in ipairs(v.list) do reset(e) end
            elseif v.k == 'array' then
                lex['@' .. v.array] = newList({}, 0)
            elseif v.k == 'hash' then
                lex[v.hkey] = setmetatable({}, PerlHash)
            elseif v.k == nil then
                lex[v[1]] = nil
            end
        end
        -- (a fresh variable each time the declaration runs)
        local f = function() reset(d) return getVar(d) end
        lvalues[f] = d
        return f
    end
    -- a method call on the value of closure obj (current token: the method
    -- name after `->`): in list context all the values the method returns,
    -- else the first; the arguments leave the code (EV.export)
    local function methodCall(obj)
        local meth = tokVal
        nextTok()
        local args = {}
        if tok == '(' then args = callArgs() end
        local function call()
            local o = sc(obj())
            local m = type(o) == 'table' and o[meth]
            if type(m) ~= 'function' then
                perl.die('Can\'t locate object method "' .. meth .. '" at (eval 1) line 1.\n')
            end
            local a = flatArgs(args)
            for i = 1, a.n do a[i] = EV.export(a[i]) end
            return m(o, tunpack(a, 1, a.n))
        end
        local f = function() return (call()) end
        listForm[f] = function()
            local r = tpack(call())
            return newList(r, r.n)
        end
        return f
    end
    -- the closure that reads the place d
    local function placeFn(d)
        local f = function() return getVar(d) end
        lvalues[f] = d
        pureRead[f] = true
        varName[f] = nameOf(d)
        voidUse[f] = varUse(d)
        return f
    end
    -- {KEY} of a hash subscript (current token '{'): a bareword alone (or
    -- -bareword) is the key; returns the constant key or nil and the
    -- closure of the key expression
    local function closeTerm()
        -- (the token after a subscript: what follows a term, so that `/` is
        --  the division)
        tok = ']'
        nextTok()
    end
    local function hashSubscript()
        local w, after = smatch(code, '^[ \t\n\r\f\v]*(%-?[A-Za-z_][A-Za-z0-9_]*)[ \t\n\r\f\v]*}()', pos)
        if w then
            pos = after
            closeTerm()
            return w
        end
        nextTok()
        local e = expr(0)
        if tok ~= '}' then evalDie(code, pos) end
        closeTerm()
        local c = folded[e]
        if c and constant[e] then return perlStr(c[1]) end
        return nil, scalarCtx(e)
    end
    -- [INDEX] or {KEY} after a term (current token '[' or '{'): the element
    -- of what base refers to
    local function subscript(b)
        if tok == '[' then
            nextTok()
            local idx = scalarCtx(expr(0))
            if tok ~= ']' then evalDie(code, pos) end
            closeTerm()
            return { k = 'elem', kind = 'ARRAY', base = b, idx = idx }
        end
        local key, keyFn = hashSubscript()
        return { k = 'elem', kind = 'HASH', base = b, key = key, keyFn = keyFn }
    end
    -- (the places holding a scalar: a reference in them can be dereferenced
    --  with autovivification)
    local function scalarPlace(d)
        if not d then return false end
        local k = d.k
        return k == nil or k == 'h' or k == 'a' or k == 'elem' or k == 'sderef'
    end
    -- what follows a term f (place d): subscripts ->[...], ->{...} (and [...],
    -- {...} right after a subscript, where the arrow is optional), method
    -- calls ->Name(...)
    local function postfix(d, f)
        f = f or placeFn(d)
        local sub = d and (d.k == 'elem' or d.k == 'a' or d.k == 'h')
        while true do
            if tok == '->' then
                nextTok()
                if tok == 'word' then
                    f = methodCall(f)
                    d, sub = nil, false
                elseif tok == '[' or tok == '{' then
                    d = subscript(scalarPlace(d) and { place = d } or { fn = f })
                    f, sub = placeFn(d), true
                elseif tok == '(' then
                    unsupported('code reference call ->(...)')
                else
                    unsupported('dereference ->' .. tostring(tok))
                end
            elseif sub and (tok == '[' or tok == '{') then
                d = subscript({ place = d })
                f = placeFn(d)
            else
                return f
            end
        end
    end
    -- the block of ${...}, @{...}, %{...} (current token '{'): the base of
    -- the dereference (the place the block names, or its value), and the
    -- character right after the block
    local function derefBlock()
        nextTok()
        local e = expr(0)
        if tok ~= '}' then evalDie(code, pos) end
        local adj = ssub(code, pos, pos)
        closeTerm()
        local d = lvalues[e]
        if scalarPlace(d) then return { place = d }, adj end
        return { fn = scalarCtx(e) }, adj
    end
    -- the list of a slice subscript (current token '[' or '{'; a bareword
    -- alone in braces is the key)
    local function sliceList()
        if tok == '{' then
            local w, after = smatch(code, '^[ \t\n\r\f\v]*(%-?[A-Za-z_][A-Za-z0-9_]*)[ \t\n\r\f\v]*}()', pos)
            if w then
                pos = after
                closeTerm()
                local f = function() return w end
                constant[f] = true
                folded[f] = { w }
                return f
            end
        end
        local close = tok == '[' and ']' or '}'
        nextTok()
        local e = expr(0)
        if tok ~= close then evalDie(code, pos) end
        closeTerm()
        return e
    end
    -- an array term (@name: name; @$name, @{...}: base) and what follows it
    -- right away: a slice [...] or {...}
    -- (Perl's compile-time warning for a slice of one element, @a[1] or
    --  @h{a}: when the subscript's text has only word characters and
    --  ` \t$#+-'"`, and is one term -- shown when it is a constant)
    local function sliceWarn(name, open, list)
        local close = open == '[' and ']' or '}'
        if commaOf[list] or listForm[list] or parenList[list] then return end
        local shown = '...'
        local c = folded[list]
        if c then shown = type(c[1]) == 'string' and prettyConst(c[1]) or perlStr(c[1]) end
        compileWarns[#compileWarns + 1] = 'Scalar value @' .. name .. open .. shown .. close ..
            ' better written as $' .. name .. open .. shown .. close .. ' at (eval 1) line 1.\n'
    end
    local function sliceText()
        local e = bracketEnd(code, tokPos)
        local text = e and ssub(code, tokPos + 1, e - 2)
        return text and smatch(text, '^[ \t]*()') and not smatch(text, '^[ \t]*qw[^A-Za-z0-9_]') and
               smatch(text, '^[A-Za-z0-9_ \t$#+\'"-]*$') ~= nil
    end
    local function arrayTerm(name, b, adj)
        local d
        local warnSlice = name and (adj == '[' or adj == '{') and tok == adj and sliceText()
        if adj == '[' and tok == '[' then
            d = { k = 'aslice', array = name, base = b, idx = sliceList() }
        elseif adj == '{' and tok == '{' then
            if name then
                d = { k = 'hslice', hashD = { name, hkey = declared['%' .. name] and '%' .. name or nil },
                      keys = sliceList() }
            else
                d = { k = 'hslice', base = b, keys = sliceList() }
            end
        elseif name then
            d = { k = 'array', array = name }
        else
            d = { k = 'aderef', base = b }
        end
        if warnSlice then sliceWarn(name, adj, d.idx or d.keys) end
        local f = placeFn(d)
        if d.k == 'array' then voidUse[f] = isLexical(name, '@') and 'private array' or 'a variable' end
        return f
    end
    -- the hash operand of keys, values, each (%name, %$name, %{...}, and an
    -- array for keys/values); returns its descriptor
    local function hashOperand(name)
        if tok == 'hash' or tok == 'hderef' or tok == 'array' or tok == 'aderef' then
            local e = unary()
            local d = lvalues[e]
            if d and (d.k == 'hash' or d.k == 'hderef' or d.k == 'array' or d.k == 'aderef') then return d end
        end
        unsupported(name .. ' on an expression')
    end
    -- keys HASH, values HASH, each HASH (current token: the word): in list
    -- context the keys, the values (aliases of the hash's) or the next key
    -- and value; in scalar context their number, or the next key.  (For an
    -- array: its indexes and elements.)
    local function parseKeys(name)
        nextTok()
        local paren = tok == '('
        if paren then nextTok() end
        local d = hashOperand(name)
        if paren then
            if tok ~= ')' then evalDie(code, pos) end
            nextTok()
        end
        local isArray = d.k == 'array' or d.k == 'aderef'
        if isArray and name == 'each' then unsupported('each on an array') end
        local function list()
            if isArray then
                local arr = arrayOf(d, true)
                local out = newList({}, 0)
                for i = 1, alen(arr) do flatInto(out, name == 'keys' and i - 1 or arr[i]) end
                if name == 'values' then srcOf[out] = arr end
                return out
            end
            local h = hashOf(d, true)
            if name == 'each' then
                -- (the iterator of the hash, which keys and values reset)
                local it = EV.iters[h]
                if not it then
                    local keys, orig = hashKeys(h)
                    it = { keys = keys, orig = orig, i = 0 }
                    EV.iters[h] = it
                end
                it.i = it.i + 1
                local key = it.keys[it.i]
                if key == nil then
                    EV.iters[h] = nil
                    return newList({}, 0)
                end
                return newList({ key, h[it.orig[key]] }, 2)
            end
            EV.iters[h] = nil
            local keys, orig = hashKeys(h)
            local out = newList({}, 0)
            local src = { hash = h, keys = {} }
            for i, k in ipairs(keys) do
                if name == 'keys' then
                    flatInto(out, k)
                else
                    flatInto(out, h[orig[k]])
                    src.keys[i] = orig[k]
                end
            end
            if name == 'values' then srcOf[out] = src end
            return out
        end
        local f
        if name == 'each' then
            f = function() return list()[1] end
        else
            f = function() return list().n end
        end
        listForm[f] = list
        return f
    end
    -- exists ELEMENT, delete ELEMENT (current token: the word): whether the
    -- hash has the key (the array the element), and removing it -- the
    -- containers on the way are created, as in Perl
    local function parseExists(name)
        nextTok()
        local paren = tok == '('
        if paren then nextTok() end
        local e = paren and expr(0) or expr(9)
        if paren then
            if tok ~= ')' then evalDie(code, pos) end
            nextTok()
        end
        local d = lvalues[e]
        if d and d.paren then d = d.single end
        if d and (d.k == 'aslice' or d.k == 'hslice') then unsupported(name .. ' of a slice') end
        if not d or not (d.k == 'h' or d.k == 'a' or d.k == 'elem') then
            unsupported(name .. ' on this kind of argument')
        end
        local isHash = d.k == 'h' or d.kind == 'HASH'
        if name == 'exists' then
            return function()
                local c, key = locate(d, true)
                if isHash then return boolVal(hget(c, key) ~= nil) end
                return boolVal(key ~= nil and key <= alen(c) and c[key] ~= nil)
            end
        end
        return function()
            local c, key = locate(d, true)
            if isHash then
                local v = hget(c, key)
                if c[key] == nil and v ~= nil then key = mtointeger(tonumber(key)) end
                c[key] = nil
                return v
            end
            if key == nil or key > alen(c) then return nil end
            local v = c[key]
            c[key] = nil
            if getmetatable(c) == PerlList and key == c.n then
                -- (deleting the last element shortens the array)
                local len = key - 1
                while len > 0 and c[len] == nil do len = len - 1 end
                c.n = len
            end
            return v
        end
    end
    -- chomp/chop [PLACE] (current token: the word; $_ by default): in place;
    -- the number of characters removed, or the last character removed
    local function parseChomp(name)
        nextTok()
        local paren = tok == '('
        if paren then nextTok() end
        local d
        if (paren and tok ~= ')') or (not paren and startsTerm()) then
            local e = paren and expr(0) or expr(9)
            d = lvalues[e]
            if d and d.paren then d = d.single end
            if not d then unsupported(name .. ' on an expression') end
            if d.k == 'list' or d.k == 'aslice' or d.k == 'hslice' or d.k == 'hash' or d.k == 'hderef' then
                unsupported(name .. ' on a list')
            end
            local body = e
            -- (`chomp(my $x = ...)`: the assignment runs first)
            d = { run = body, place = d }
        else
            d = { place = { '_' } }
        end
        if paren then
            if tok ~= ')' then evalDie(code, pos) end
            nextTok()
        end
        local place = d.place
        local function one(c, key, r)
            local v = cget(c, key)
            if v == nil then return r end
            local s = perlStr(v)
            if name == 'chomp' then
                local new, cnt = perl.chomp(s)
                if cnt > 0 then cset(c, key, new) end
                return (r or 0) + cnt
            end
            if s == '' then return r or '' end
            cset(c, key, ssub(s, 1, -2))
            return ssub(s, -1)
        end
        local f = function()
            if d.run then d.run() end
            if place.k == 'array' or place.k == 'aderef' then
                local arr = arrayOf(place, true)
                local r
                for i = 1, alen(arr) do r = one(arr, i, r) end
                return r or (name == 'chomp' and 0 or '')
            end
            local c, key = locate(place, true)
            if not c then perl.die('Modification of a read-only value attempted at (eval 1) line 1.\n') end
            return one(c, key) or (name == 'chomp' and 0 or '')
        end
        return f
    end
    -- the localtime/gmtime of the closure t (now without one): in list
    -- context the fields, in scalar context the date as ctime(3) writes it
    local DAY_NAMES = { 'Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat' }
    local MON_NAMES = { 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec' }
    local function timeFn(name, t)
        local get = name == 'localtime' and perl.localtime or perl.gmtime
        local function fields()
            if not t then return get() end
            local v = sc(t())
            if v == nil then
                warnUninit(name, varName[t], true)
                v = 0
            end
            return get(perl.num(v, name))
        end
        local f = function()
            local tm = fields()
            if #tm == 0 then return nil end
            return sformat('%s %s %2d %02d:%02d:%02d %s', DAY_NAMES[tm[7] + 1], MON_NAMES[tm[5] + 1], tm[4],
                           tm[3], tm[2], tm[1], perlStr(tm[6] + 1900))
        end
        listForm[f] = function()
            local tm = fields()
            return newList({ tunpack(tm, 1, #tm) }, #tm)
        end
        voidUse[f] = name
        return f
    end
    -- the arguments of a list operator: in parentheses, or without them
    -- everything up to the next low-precedence operator
    local function listOpArgs()
        if tok == '(' then return callArgs() end
        local args = {}
        if startsTerm(true) then
            args[1] = expr(3.5)
            while tok == ',' or tok == '=>' do
                nextTok()
                args[#args + 1] = expr(3.5)
            end
        end
        return args
    end
    -- sort LIST, sort BLOCK LIST (current token: the word sort): Perl's
    -- string order, or the order of the block comparing $a and $b
    local function parseSort()
        nextTok()
        local paren = tok == '('
        if paren then nextTok() end
        local cmpBlock
        if tok == '{' then cmpBlock = block() end
        local args = {}
        if paren then
            while tok ~= ')' do
                args[#args + 1] = expr(3.5)
                if tok == ',' or tok == '=>' then
                    nextTok()
                elseif tok ~= ')' then
                    evalDie(code, pos)
                end
            end
            nextTok()
        elseif startsTerm() then
            args = listOpArgs()
        end
        return function()
            local list = flatArgs(args)
            local items = {}
            for i = 1, list.n do items[i] = { list[i] } end
            local sorted
            if cmpBlock then
                -- ($a and $b are package variables, localized by sort)
                local sa, sb = store('a'), store('b')
                local oldA, oldB = sa.a, sb.b
                sorted = perl.sort(items, function(x, y)
                    sa.a, sb.b = x[1], y[1]
                    return perl.num(sc(cmpBlock()))
                end)
                sa.a, sb.b = oldA, oldB
            else
                sorted = perl.sort(items, function(x, y) return perl.cmp(x[1], y[1]) end)
            end
            local out = newList({}, 0)
            for i = 1, #sorted do flatInto(out, sorted[i][1]) end
            return out
        end
    end
    -- reverse LIST (current token: the word reverse): in list context the
    -- elements in reverse order, in scalar context their concatenation (or
    -- $_) reversed
    local function parseReverse()
        nextTok()
        local args = listOpArgs()
        local f = function()
            local str
            if #args == 0 then
                str = perlStr(sc(getVar({ '_' })))
            else
                local a, t = flatArgs(args), {}
                for i = 1, a.n do t[i] = perlStr(a[i]) end
                str = tconcat(t)
            end
            return str:reverse()
        end
        listForm[f] = function()
            local a = flatArgs(args)
            local out = newList({}, 0)
            for i = a.n, 1, -1 do flatInto(out, a[i]) end
            return out
        end
        return f
    end
    -- map BLOCK LIST, map EXPR, LIST, grep BLOCK LIST, grep EXPR, LIST
    -- (current token: the word): $_ is each element in turn (an alias: a
    -- change to it changes the element where it comes from), map gives the
    -- values of the block in list context, grep the elements for which it
    -- is true; in scalar context their number
    local function parseMapGrep(name)
        nextTok()
        local paren = tok == '('
        if paren then nextTok() end
        local body
        if tok == '{' then
            body = block()
        else
            body = expr(3.5)
            if tok ~= ',' and tok ~= '=>' then evalDie(code, pos) end
            nextTok()
        end
        local args = {}
        if paren then
            while tok ~= ')' do
                args[#args + 1] = expr(3.5)
                if tok == ',' or tok == '=>' then
                    nextTok()
                elseif tok ~= ')' then
                    evalDie(code, pos)
                end
            end
            nextTok()
        elseif startsTerm() then
            args = listOpArgs()
        end
        return function()
            local items, cnt, cs, ks, ro = aliasItems(args)
            local st = store('_')
            local old = st._
            local out = newList({}, 0)
            -- ($_ is restored however the block ends)
            local ok, err = pcall(function()
                for i = 1, cnt do
                    st._ = items[i]
                    if name == 'map' then
                        flatInto(out, listOf(body))
                    elseif perl.truthy(sc(body())) then
                        flatInto(out, cget(st, '_'))
                    end
                    writeBack(st, '_', items[i], cs[i], ks[i], ro[i])
                end
            end)
            st._ = old
            if not ok then error(err, 0) end
            return out
        end
    end
    -- is every operand closure but the k-th a defined literal?
    local function othersConstant(list, k)
        for i = 1, #list do
            if i ~= k and not constant[list[i]] then return false end
        end
        return true
    end
    -- a hash term (%name, %$name, %{...}): in list context its keys and
    -- values, in scalar context the number of keys
    local function hashTerm(d)
        local function get()
            local h = hashOf(d, false)
            if type(h) ~= 'table' then return nil end
            return h
        end
        local f = function() return #hashKeys(get()) end
        listForm[f] = function() return hashList(get()) end
        lvalues[f] = d
        pureRead[f] = true
        voidUse[f] = d.k == 'hash' and isLexical(d[1], '%') and 'private hash' or 'a variable'
        return f
    end
    -- Pkg->Name(ARGS) (current token '->' after the package name; with meth
    -- the token after the package name): the function Pkg::Name, called with
    -- the package name first, as Perl calls a class method
    local function classMethod(pkg, meth)
        if not meth then
            nextTok()   -- (past the arrow)
            if tok ~= 'word' then evalDie(code, pos) end
            meth = tokVal
            nextTok()
        end
        local args = {}
        if tok == '(' then args = callArgs() end
        local function call()
            local fn = funcs[pkg .. '::' .. meth]
            if not fn then
                perl.die('Can\'t locate object method "' .. meth .. '" via package "' .. pkg ..
                         '" at (eval 1) line 1.\n')
            end
            local a = flatArgs(args)
            for i = 1, a.n do a[i] = EV.export(a[i]) end
            return fn(pkg, tunpack(a, 1, a.n))
        end
        local f = function() return (call()) end
        listForm[f] = function()
            local r = tpack(call())
            return newList(r, r.n)
        end
        return f
    end
    -- (the range operator in list context: Perl's RANGE_IS_NUMERIC decides
    --  between the integers from a to b and the magic string increment from
    --  a until b, or until the string is longer than b)
    local function range(a, b)
        if isCarray(a) then a = a:tostring() end
        if isCarray(b) then b = b:tostring() end
        local out = newList({}, 0)
        local strA, strB = type(a) == 'string', type(b) == 'string'
        local numeric = (a ~= nil and not strA) or (b ~= nil and not strB) or
                        (((a == nil and b ~= nil) or (strA and looksLikeNumber(a) and ssub(a, 1, 1) ~= '0')) and
                         (b == nil or looksLikeNumber(b)))
        if numeric then
            local i, j = intVal(a, 'range (or flop)'), intVal(b, 'range (or flop)')
            for v = i, j do
                out.n = out.n + 1
                out[out.n] = v
            end
            return out
        end
        local s, e = a == nil and '' or a, b == nil and '' or b
        local len = #e
        while #s <= len do
            flatInto(out, s)
            if s == e then break end
            local nx = (s ~= '' and smatch(s, '^[a-zA-Z]*[0-9]*$')) and perl.increment(s)
            if type(nx) ~= 'string' then break end  -- (not a magic string: it became a number)
            s = nx
        end
        return out
    end
    local function primary()
        local t, v = tok, tokVal
        if t == 'word' and smatch(code, '^[ \t\n\r\f\v]*=>', pos) then
            -- (a bareword before => is a string)
            nextTok()
            local f = function() return v end
            constant[f] = true
            folded[f] = { v }
            return f
        end
        if t == 'num' or t == 'str' then
            nextTok()
            local f = function() return v end
            constant[f] = true
            folded[f] = { v }
            return f
        elseif t == 'istr' then
            nextTok()
            local build, static, nVars = compileInterp(v, 'str')
            local f = function() return build('concatenation (.) or string') end
            if static then constant[f] = true end
            -- (in void context: the function a leading case modifier
            --  stands for, join for "@array" alone, else "string")
            local mod = smatch(v, '^\\([ULQFul])')
            voidUse[f] = mod and EVAL_CASE_FUNC[mod] or
                         smatch(v, '^@[A-Za-z_][A-Za-z0-9_]*$') and 'join or string' or 'string'
            if nVars == 0 then fold(f, {}) end
            return f
        elseif t == 'qw' then
            -- qw(...): a list of the words (each a constant in void context)
            nextTok()
            local words, kids = v, {}
            for i, w in ipairs(words) do
                kids[i] = function() return w end
                folded[kids[i]] = { w }
            end
            local f = function() return newList({ tunpack(words) }, #words, true) end
            voidKids[f] = kids
            parenList[f] = true
            return f
        elseif t == 'var' then
            -- $name, and what follows it right away: [INDEX] (an element of
            -- @name) or {KEY} (of %name); $$name (with [..]/{..}: an element
            -- of what $name refers to)
            local adj = ssub(code, pos, pos)
            nextTok()
            local d
            if v.k then
                d = v       -- ($1, $&)
            elseif adj == '[' and tok == '[' then
                if v[1] == '_' and not v.deref then unsupported('@_') end
                nextTok()
                local idx = scalarCtx(expr(0))
                if tok ~= ']' then evalDie(code, pos) end
                closeTerm()
                if v.deref then
                    d = { k = 'elem', kind = 'ARRAY', base = { place = { v[1] } }, idx = idx }
                else
                    d = { k = 'a', v[1], idx = idx }
                end
            elseif adj == '{' and tok == '{' then
                local key, keyFn = hashSubscript()
                if v.deref then
                    d = { k = 'elem', kind = 'HASH', base = { place = { v[1] } }, key = key, keyFn = keyFn }
                else
                    d = { k = 'h', v[1], key, keyFn = keyFn,
                          hkey = declared['%' .. v[1]] and '%' .. v[1] or nil }
                end
            elseif v.deref then
                d = { k = 'sderef', base = { place = { v[1] } } }
            else
                d = v
            end
            return placeFn(d)
        elseif t == 'array' then
            local adj = ssub(code, pos, pos)
            nextTok()
            return arrayTerm(v, nil, adj)
        elseif t == 'aderef' then
            local b, adj
            if v then
                adj = ssub(code, pos, pos)
                nextTok()
                b = { place = { v } }
            else
                nextTok()   -- (the '{')
                b, adj = derefBlock()
            end
            return arrayTerm(nil, b, adj)
        elseif t == 'hash' then
            nextTok()
            if v.deref then return hashTerm({ k = 'hderef', base = { place = { v[1] } } }) end
            return hashTerm({ k = 'hash', v[1], hkey = declared['%' .. v[1]] and '%' .. v[1] or nil })
        elseif t == 'hderef' then
            nextTok()   -- (the '{')
            return hashTerm({ k = 'hderef', base = derefBlock() })
        elseif t == 'sderef' then
            -- ${ EXPR }, ${ EXPR }[INDEX], ${ EXPR }{KEY}
            nextTok()   -- (the '{')
            local b, adj = derefBlock()
            local d
            if (adj == '[' and tok == '[') or (adj == '{' and tok == '{') then
                d = subscript(b)
            else
                d = { k = 'sderef', base = b }
            end
            return placeFn(d)
        elseif t == 'lastidx' then
            nextTok()
            local d
            if not v then
                d = { k = 'lastidx', base = derefBlock() }   -- ($#{ EXPR })
            elseif v.deref then
                d = { k = 'lastidx', base = { place = { v[1] } } }
            else
                d = { k = 'lastidx', array = v[1] }
            end
            return placeFn(d)
        elseif t == 'subst' or t == 'trans' then
            nextTok()
            local f = editFn(t, v, { '_' })
            if sfind(v[3], 'r', 1, true) then voidUse[f] = NONDESTRUCTIVE[t] end
            return f
        elseif t == 'word' and v == 'undef' then
            -- undef, and undef EXPR (the variable, array or hash becomes
            -- undefined or empty)
            nextTok()
            local d
            if tok == '(' then
                nextTok()
                if tok ~= ')' then
                    d = lvalues[expr(0)]
                    if not d then unsupported('undef(EXPR)') end
                end
                if tok ~= ')' then evalDie(code, pos) end
                nextTok()
            elseif tok == 'var' or tok == 'array' or tok == 'hash' or tok == 'aderef' or
                   tok == 'hderef' or tok == 'sderef' then
                d = lvalues[unary()]
                if not d then unsupported('undef EXPR') end
            end
            if d and d.paren then d = d.single end
            if not d then
                local f = function() return nil end
                lvalues[f] = { k = 'skip' }     -- (undef in a list assignment)
                return f
            end
            if d.k == 'list' or d.k == 'aslice' or d.k == 'hslice' or d.k == 'skip' then
                unsupported('undef on a list')
            end
            return function()
                if d.k == 'array' or d.k == 'aderef' then
                    fillArray(arrayOf(d, true), newList({}, 0))
                elseif d.k == 'hash' or d.k == 'hderef' then
                    local h = hashOf(d, true)
                    for key in pairs(h) do h[key] = nil end
                else
                    setVar(d, nil)
                end
                return nil
            end
        elseif t == 'word' and v == 'my' then
            return parseMy()
        elseif t == 'word' and v == 'split' then
            local f = parseSplit()
            voidUse[f] = 'split'
            return f
        elseif t == 'word' and (v == 'push' or v == 'unshift') then
            return parsePush(v)
        elseif t == 'word' and (v == 'shift' or v == 'pop') then
            return parseShift(v)
        elseif t == 'word' and v == 'splice' then
            return parseSplice()
        elseif t == 'word' and v == 'sort' then
            local f = parseSort()
            voidUse[f] = 'sort'
            return f
        elseif t == 'word' and v == 'reverse' then
            local f = parseReverse()
            voidUse[f] = 'reverse'
            return f
        elseif t == 'word' and (v == 'map' or v == 'grep') then
            return parseMapGrep(v)
        elseif t == 'word' and (v == 'keys' or v == 'values' or v == 'each') then
            return parseKeys(v)
        elseif t == 'word' and (v == 'exists' or v == 'delete') then
            return parseExists(v)
        elseif t == 'word' and (v == 'chomp' or v == 'chop') then
            return parseChomp(v)
        elseif t == 'word' and (v == 'localtime' or v == 'gmtime') then
            nextTok()
            local arg
            if tok == '(' then
                local args = callArgs()
                arg = args[1]
            elseif startsTerm() then
                arg = expr(9)
            end
            return timeFn(v, arg)
        elseif t == 'word' and v == 'return' then
            -- return EXPR: the value of the eval (in its scalar context)
            nextTok()
            local e
            if startsTerm(true) then e = expr(3.2) end
            return function()
                local val
                if e then val = sc(e()) end
                error(setmetatable({ ctl = 'return', value = val }, Ctl), 0)
            end
        elseif t == 'word' and (v == 'next' or v == 'last') then
            -- next/last [LABEL]: leave the iteration or the loop
            nextTok()
            local label
            if tok == 'word' and not EVAL_BIN[tokVal] and not STMT_WORDS[tokVal] then
                label = tokVal
                nextTok()
            end
            loopCtl = loopCtl + 1
            local signal = setmetatable({ ctl = v, label = label }, Ctl)
            return function() error(signal, 0) end
        elseif t == 'word' and v == 'do' then
            -- do BLOCK: the value of the block's last statement
            nextTok()
            if tok ~= '{' then unsupported('do FILE') end
            local body = block()
            local f = function() return body() end
            listForm[f] = function() return listOf(body) end
            voidKids[f] = voidKids[body]
            doBlock[f] = body
            return f
        elseif t == 'word' and v == 'require' then
            -- require Module::Name, require 'file.pl': through the caller's
            -- CORE::GLOBAL::require (as Perl calls an override of require),
            -- with the file name Perl gives it
            nextTok()
            local file, nameFn
            if tok == 'word' then
                file = sgsub(tokVal, '::', '/') .. '.pm'
                nextTok()
            elseif tok == 'num' then
                unsupported('require VERSION')
            else
                nameFn = scalarCtx(expr(9))
            end
            local hook = funcs['CORE::GLOBAL::require']
            funcNames['CORE::GLOBAL::require'] = hook ~= nil
            if not hook then unsupported('require') end
            return function()
                local name = file or perlStr(sc(nameFn()))
                return funcs['CORE::GLOBAL::require'](name)
            end
        elseif t == 'word' and (v == 'die' or v == 'warn') then
            -- die LIST, warn LIST: the message, " at (eval 1) line 1." added
            -- unless it ends in a newline
            nextTok()
            local args = listOpArgs()
            return function()
                local a, parts = flatArgs(args), {}
                for i = 1, a.n do parts[i] = perlStr(a[i]) end
                local msg = tconcat(parts)
                if v == 'warn' then return perl.warn(msg) end
                if msg == '' then msg = 'Died' end
                if ssub(msg, -1) ~= '\n' then msg = msg .. ' at (eval 1) line 1.\n' end
                perl.die(msg)
            end
        elseif t == 'word' and v == 'new' and smatch(code, '^[ \t\n\r\f\v]*[A-Za-z_]', pos) then
            -- new CLASS(ARGS): Perl's indirect object syntax for CLASS->new
            nextTok()
            local pkg = tokVal
            nextTok()
            return classMethod(pkg, 'new')
        elseif t == '(' then
            nextTok()
            local e
            if tok == ')' then
                nextTok()
                e = function() return newList({}, 0, true) end
                lvalues[e] = { k = 'list', list = {} }
            else
                e = expr(0)
                if tok ~= ')' then evalDie(code, pos) end
                nextTok()
            end
            parenList[e] = true
            if tok == '[' then
                -- a list slice (LIST)[INDEXES]: the elements at the indexes (a
                -- negative one counts from the end; one past the end is undef),
                -- in scalar context the last of them; nothing of an empty list
                nextTok()
                local idx = expr(0)
                if tok ~= ']' then evalDie(code, pos) end
                closeTerm()
                local f = function()
                    local list = flatInto(newList({}, 0), listOf(e))
                    local ix = flatInto(newList({}, 0), listOf(idx))
                    local out = newList({}, 0, true)
                    if list.n == 0 then return out end
                    for k = 1, ix.n do
                        local i = intVal(ix[k])
                        if i < 0 then i = i + list.n end
                        out.n = out.n + 1
                        if i >= 0 then out[out.n] = list[i + 1] end
                    end
                    return out
                end
                voidUse[f] = 'list slice'
                return f
            end
            local d = lvalues[e]
            if d and d.k ~= 'list' then
                -- ((PLACE): a list of one place in an assignment, the place
                --  itself for the rest)
                local f = function() return e() end
                lvalues[f] = { k = 'list', list = { d }, paren = true, single = d }
                listForm[f], varName[f], voidUse[f] = listForm[e], varName[e], voidUse[e]
                voidKids[f], folded[f], constant[f] = voidKids[e], folded[e], constant[e]
                if not voidKids[f] and not voidUse[f] and not folded[f] then voidKids[f] = { e } end
                pureRead[f] = pureRead[e]
                parenList[f] = true
                return f
            end
            return e
        elseif t == '[' then
            -- [LIST]: a reference to a new array of the values
            nextTok()
            local e
            if tok ~= ']' then e = expr(0) end
            if tok ~= ']' then evalDie(code, pos) end
            closeTerm()
            local f = function()
                local list = newList({}, 0)
                if e then flatInto(list, listOf(e)) end
                return EV.aref(list)
            end
            voidUse[f] = 'anonymous array ([])'
            return f
        elseif t == '{' then
            -- {LIST}: a reference to a new hash of the keys and values
            nextTok()
            local e
            if tok ~= '}' then e = expr(0) end
            if tok ~= '}' then evalDie(code, pos) end
            closeTerm()
            local f = function()
                local h = setmetatable({}, PerlHash)
                if e then fillHash(h, flatInto(newList({}, 0), listOf(e)), 'anonymous hash') end
                return h
            end
            voidUse[f] = 'anonymous hash ({})'
            return f
        elseif t == 'regex' then
            -- a bare /re/ matches $_
            nextTok()
            local m, ml = regexFn(v[1], v[2])
            local f = function() return boolVal(m(getVar({ '_' }), NAME_)) end
            listForm[f] = function() return ml(getVar({ '_' }), NAME_) end
            return f
        elseif t == 'word' then
            -- (a Perl builtin, else a function of the caller's funcs)
            local fn = EVAL_FUNCS[v]
            local userFn = not fn
            if userFn then
                if EVAL_UNSUPPORTED[v] then unsupported(EVAL_UNSUPPORTED[v]) end
                if STMT_WORDS[v] then evalDie(code, pos) end
                -- (looked up again at run time, among the functions of the run)
                fn = funcs[v]
                funcNames[v] = fn ~= nil
            end
            local qualified = sfind(v, '::', 1, true)
            if qualified and smatch(code, '^[ \t\n\r\f\v]*%->', pos) then
                nextTok()
                return classMethod(v)
            end
            if not fn and not qualified then unsupported('function ' .. v .. '()') end
            nextTok()
            local isList = EVAL_LIST_OPS[v] or userFn
            local args = {}
            if tok == '(' then
                args = callArgs()
            elseif EVAL_NAMED_UNARY[v] and startsTerm() then
                args[1] = expr(9)
            elseif isList then
                args = listOpArgs()
            end
            local unaryDefault = EVAL_NAMED_UNARY[v] and not EVAL_NO_DEFAULT[v] and #args == 0
            -- (a builtin warns about an undef argument, see EVAL_UNINIT)
            local uninitDesc = not userFn and EVAL_UNINIT[v] or nil
            local f = function()
                local func = fn
                if userFn then func = funcs[v] end
                if not func then
                    -- (a package's function that is not there, as Perl's
                    --  run time says)
                    perl.die('Undefined subroutine &' .. v .. ' called at (eval 1) line 1.\n')
                end
                if unaryDefault then    -- ($_ by default)
                    local x = sc(getVar({ '_' }))
                    if x == nil and uninitDesc then warnUninit(uninitDesc, NAME_, true) end
                    return func(x)
                end
                if userFn then
                    -- (@_ aliases the arguments: perl.setArg assigns to the
                    --  variable passed, as `$_[0] = $val` does; the values
                    --  leave the code, EV.export)
                    local a, alias = newList({}, 0), {}
                    for i = 1, #args do
                        local val, d = listOf(args[i]), lvalues[args[i]]
                        if d and not LIST_PLACE[d.k] and getmetatable(val) ~= PerlList then
                            alias[a.n] = d
                        end
                        flatInto(a, val)
                    end
                    for i = 1, a.n do a[i] = EV.export(a[i]) end
                    local oldAlias = argAlias
                    argAlias = function(k, val)
                        if not alias[k] then
                            perl.die('Modification of a read-only value attempted at (eval 1) line 1.\n')
                        end
                        setVar(alias[k], val)
                    end
                    local r = tpack(pcall(func, tunpack(a, 1, a.n)))
                    argAlias = oldAlias
                    if not r[1] then error(r[2], 0) end
                    return tunpack(r, 2, r.n)
                end
                if isList then
                    local a = flatArgs(args, uninitDesc)
                    return func(tunpack(a, 1, a.n))
                end
                local a = {}
                for i = 1, #args do a[i] = sc(args[i]()) end
                if uninitDesc then
                    for i = 1, #args do
                        if a[i] == nil then warnUninit(uninitDesc, varName[args[i]], othersConstant(args, i)) end
                    end
                end
                return func(tunpack(a, 1, #args))
            end
            if userFn or v == 'unpack' then
                -- (in list context all the values the function returns)
                listForm[f] = function()
                    local r = tpack(f())
                    return newList(r, r.n)
                end
            end
            if not userFn then
                if not isList then
                    for i = 1, #args do scalarCtx(args[i]) end
                end
                voidUse[f] = EVAL_VOID[v]
                if EVAL_FOLD[v] and not unaryDefault then fold(f, args) end
            end
            return f
        end
        evalDie(code, pos)
    end
    -- ++/-- on the variable behind closure e (prefix: the new value,
    -- postfix: the old one; ++ on a non-numeric string is Perl's magic
    -- increment)
    local function incDec(op, e, prefix)
        local v = lvalues[e]
        if v and v.paren then v = v.single end
        if not v or LIST_PLACE[v.k] or v.k == 'skip' or v.k == 'lastidx' then
            unsupported(op .. ' on an expression')
        end
        local pre = not pureRead[e] and e
        return function()
            if pre then pre() end
            local c, key = locate(v, true)
            if not c then perl.die('Modification of a read-only value attempted at (eval 1) line 1.\n') end
            if key == nil then
                perl.die('Modification of non-creatable array value attempted at (eval 1) line 1.\n')
            end
            local old = sc(cget(c, key))
            local new
            if op == '++' then
                new = type(old) == 'string' and old ~= '' and not smatch(old, '^[ \t\n\r\f\v]*[-+]?[%d.]') and
                      perl.increment(old) or perl.num(old) + 1
            else
                new = perl.num(old) - 1
            end
            cset(c, key, new)
            if prefix then return new end
            return old == nil and (op == '++' and 0 or nil) or old
        end
    end
    unary = function()
        if tok == '!' then
            nextTok()
            local e = unary()
            local f = function() return boolVal(not perl.truthy(sc(e()))) end
            voidUse[f] = 'not'
            return fold(f, { scalarCtx(e) }, true)
        elseif tok == '-' then
            nextTok()
            local e = scalarCtx(unary())
            local f = function()
                local v = sc(e())
                -- (Perl negates a string that is not a number as a string:
                --  -"foo" is "-foo", -"-foo" is "+foo", -"+5" is "-5")
                if type(v) == 'string' then
                    local c = ssub(v, 1, 1)
                    if smatch(c, '^[A-Za-z_]') then return '-' .. v end
                    if c == '+' or (c == '-' and not looksLikeNumber(v)) then
                        return (c == '-' and '+' or '-') .. ssub(v, 2)
                    end
                end
                return -numArg(v, e, 'neg', true)
            end
            voidUse[f] = NUM_OPS.neg
            return fold(f, { e })
        elseif tok == '+' then
            nextTok()
            return unary()
        elseif tok == '\\' then
            -- a reference: to an array, a hash, a scalar variable (which
            -- the box it gives out holds from now on, see Alias), else to a
            -- copy of the value (perl.str shows it as Perl does, "SCALAR(0x...)")
            local at = tokPos
            nextTok()
            local e = unary()
            local d = lvalues[e]
            local paren = d and d.paren
            if paren then d = d.single end
            local k = d and d.k
            -- (\(@a): a reference to each element)
            if paren and LIST_PLACE[k] then unsupported('reference \\ to a list', at) end
            local pre = not pureRead[e] and e
            local f
            if d and (k == 'array' or k == 'aderef') then
                f = function()
                    if pre then pre() end
                    return EV.aref(arrayOf(d, true))
                end
            elseif d and (k == 'hash' or k == 'hderef') then
                f = function()
                    if pre then pre() end
                    return hashOf(d, true)
                end
            elseif d and k == nil then
                hasAlias = true
                local name = d[1]
                f = function()
                    if pre then pre() end
                    local st = store(name)
                    local old = st[name]
                    if type(old) == 'table' and getmetatable(old) == Alias then return old.cell end
                    local cell = { ref = 'SCALAR', value = old }
                    st[name] = setmetatable({ cell = cell }, Alias)
                    if st == vars then aliasedVars = true end
                    return cell
                end
            elseif d and (k == 'h' or k == 'a' or k == 'elem') then
                -- (an element: a box that reads and writes it)
                f = function()
                    if pre then pre() end
                    local c, key = locate(d, true)
                    if key == nil then
                        perl.die('Modification of non-creatable array value attempted at (eval 1) line 1.\n')
                    end
                    return setmetatable({ ref = 'SCALAR', c = c, k = key }, ElemRef)
                end
            elseif d and k == 'sderef' then
                f = function()
                    if pre then pre() end
                    return container(d.base, 'SCALAR', true)
                end
            elseif d and k ~= 'cap' and k ~= 'amp' and k ~= 'skip' then
                unsupported('reference \\ to a list', at)
            else
                f = function() return { ref = 'SCALAR', value = sc(e()) } end
            end
            voidUse[f] = 'single ref constructor'
            return f
        elseif tok == '++' or tok == '--' then
            local op = tok
            nextTok()
            return incDec(op, unary(), true)
        elseif tok == 'word' and tokVal == 'not' then
            nextTok()
            local e = scalarCtx(expr(3))
            local f = function() return boolVal(not perl.truthy(sc(e()))) end
            voidUse[f] = 'not'
            return fold(f, { e }, true)
        end
        local p = primary()
        p = postfix(lvalues[p], p)
        if tok == '++' or tok == '--' then
            local op = tok
            nextTok()
            return incDec(op, p, false)
        end
        return p
    end
    -- (the descriptions Perl's warnings give the string operators)
    local STR_OPS = { ['.'] = 'concatenation (.) or string', eq = 'string eq', ne = 'string ne',
                      lt = 'string lt', gt = 'string gt', le = 'string le', ge = 'string ge',
                      cmp = 'string comparison (cmp)' }
    -- a binary operator on the closures l0 and r0; quietLeft: an undef left
    -- operand does not warn (the compound assignments .= += -=)
    local function binaryOp(op, l0, r0, quietLeft)
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
        -- (an operand is the only non-constant one when the other is a literal)
        local lSingle, rSingle = constant[r0] or false, constant[l0] or false
        -- numeric operands: Perl numifies the right one first
        local function nums()
            local a, b = l(), r()
            b = numArg(b, r0, op, rSingle)
            if a == nil and quietLeft then return 0, b end
            return numArg(a, l0, op, lSingle), b
        end
        local function strs()
            local a, b = l(), r()
            local desc = STR_OPS[op]
            if a == nil and quietLeft then a = '' else a = strArg(a, l0, desc, lSingle) end
            return a, strArg(b, r0, desc, rSingle)
        end
        local function ints()
            local a, b = nums()
            return mtointeger(trunc(a)) or 0, mtointeger(trunc(b)) or 0
        end
        if op == 'or' or op == '||' then
            return function() local v = l() if perl.truthy(v) then return v end return r() end
        elseif op == 'and' or op == '&&' then
            return function() local v = l() if not perl.truthy(v) then return v end return r() end
        elseif op == '//' then
            return function() local v = l() if v ~= nil then return v end return r() end
        elseif op == 'xor' then
            return function() return boolVal(perl.truthy(l()) ~= perl.truthy(r())) end
        elseif op == '==' then return function() return boolVal(cmpNum(nums()) == 0) end
        elseif op == '!=' then return function() return boolVal(cmpNum(nums()) ~= 0) end
        elseif op == '<=>' then return function() return cmpNum(nums()) end
        elseif op == '<' then return function() return boolVal(cmpNum(nums()) < 0) end
        elseif op == '>' then return function() return boolVal(cmpNum(nums()) > 0) end
        elseif op == '<=' then return function() return boolVal(cmpNum(nums()) <= 0) end
        elseif op == '>=' then return function() return boolVal(cmpNum(nums()) >= 0) end
        elseif op == 'eq' then return function() return boolVal(cmpStr(strs()) == 0) end
        elseif op == 'ne' then return function() return boolVal(cmpStr(strs()) ~= 0) end
        elseif op == 'cmp' then return function() return cmpStr(strs()) end
        elseif op == 'lt' then return function() return boolVal(cmpStr(strs()) < 0) end
        elseif op == 'gt' then return function() return boolVal(cmpStr(strs()) > 0) end
        elseif op == 'le' then return function() return boolVal(cmpStr(strs()) <= 0) end
        elseif op == 'ge' then return function() return boolVal(cmpStr(strs()) >= 0) end
        elseif op == '+' then return function() local a, b = nums() return a + b end
        elseif op == '-' then return function() local a, b = nums() return a - b end
        elseif op == '*' then return function() local a, b = nums() return a * b end
        elseif op == '/' then
            return function()
                local a, d = nums()
                if d == 0 then perl.die('Illegal division by zero at (eval 1) line 1.\n') end
                return a / d
            end
        elseif op == '%' then
            return function()
                local a, d = ints()
                if d == 0 then perl.die('Illegal modulus zero at (eval 1) line 1.\n') end
                return a % d
            end
        elseif op == '**' then return function() local a, b = nums() return a ^ b end
        elseif op == '.' then return function() local a, b = strs() return a .. b end
        elseif op == '&' then return function() local a, b = ints() return a & b end
        elseif op == '|' then return function() local a, b = ints() return a | b end
        elseif op == '^' then return function() local a, b = ints() return a ~ b end
        elseif op == '<<' then return function() local a, b = ints() return a << b end
        elseif op == '>>' then return function() local a, b = ints() return a >> b end
        end
        -- (op == 'x': the count first)
        return function()
            local a, b = l(), r()
            local count = mtointeger(trunc(numArg(b, r0, 'x', rSingle))) or 0
            -- (Perl names the string operand only when the count is a literal)
            return srep(strArg(a, lSingle and l0 or nil, 'repeat (x)', lSingle), count)
        end
    end
    -- (the comparisons: their folded value, true or false, does not warn in
    --  void context)
    local BOOL_OPS = { ['=='] = 1, ['!='] = 1, ['<'] = 1, ['>'] = 1, ['<='] = 1, ['>='] = 1,
                       eq = 1, ne = 1, lt = 1, gt = 1, le = 1, ge = 1, xor = 1 }
    local function binary(op, l0, r0, quietLeft)
        local f = binaryOp(op, l0, r0, quietLeft)
        if op == ',' or op == '=>' then
            voidKids[f] = { l0, r0 }
            commaOf[f] = voidKids[f]
            -- (a list of places: the target of a list assignment)
            local dl, dr = lvalues[l0], lvalues[r0]
            if dl and dr then
                local list = {}
                for _, d in ipairs({ dl, dr }) do
                    if d.k == 'list' then
                        for _, x in ipairs(d.list) do list[#list + 1] = x end
                    else
                        list[#list + 1] = d
                    end
                end
                lvalues[f] = { k = 'list', list = list }
            end
        elseif op == 'or' or op == '||' or op == 'and' or op == '&&' or op == '//' then
            scalarCtx(condCheck(l0))
            -- (a literal left operand decides at compile time: it is the
            --  value, or the right operand stands in the operator's place)
            local c = folded[l0]
            local decides
            if c then
                if op == '//' then
                    decides = true
                elseif op == 'or' or op == '||' then
                    decides = perl.truthy(c[1])
                else
                    decides = not perl.truthy(c[1])
                end
            end
            if decides then
                folded[f] = { c[1], quiet = true }
            elseif c and folded[r0] then
                folded[f] = { folded[r0][1], quiet = true }
            else
                voidKids[f] = { r0 }
            end
        else
            scalarCtx(l0)
            scalarCtx(r0)
            voidUse[f] = op == 'xor' and 'logical xor' or NUM_OPS[op] or STR_OPS[op]
            fold(f, { l0, r0 }, BOOL_OPS[op])
            if op == 'x' and parenList[l0] then
                -- ((LIST) x N in list context: the list repeated)
                listForm[f] = function()
                    local src = flatInto(newList({}, 0), listOf(l0))
                    local cnt = mtointeger(trunc(numArg(sc(r0()), r0, 'x', constant[l0] or false))) or 0
                    local out = newList({}, 0)
                    for _ = 1, cnt do flatInto(out, src) end
                    return out
                end
            end
        end
        return f
    end
    expr = function(minPrec)
        local left = unary()
        while true do
            local op = tok
            if op == 'word' then op = tokVal end
            local info = EVAL_BIN[op]
            if not info or info[1] < minPrec then break end
            local prec, assoc = info[1], info[2]
            local opPos = tokPos
            nextTok()
            local l = left
            if (op == ',' or op == '=>') and (tok == ')' or tok == ';' or tok == 'eof' or tok == ']' or tok == '}') then
                -- (a trailing comma)
                local empty = function() return newList({}, 0, true) end
                lvalues[empty] = { k = 'list', list = {} }
                left = binary(',', l, empty)
            elseif op == '?' then
                local a = expr(3.5)     -- (the middle operand may be an assignment)
                if tok ~= ':' then evalDie(code, pos) end
                nextTok()
                local b = expr(4)
                condCheck(l)
                left = function() if perl.truthy(sc(l())) then return a() end return b() end
                -- (in list context the branch's list)
                listForm[left] = function() if perl.truthy(sc(l())) then return listOf(a) end return listOf(b) end
                -- (a literal condition chooses the branch at compile time)
                scalarCtx(l)
                local c = folded[l]
                if c then
                    local chosen = perl.truthy(c[1]) and a or b
                    voidKids[left] = { chosen }
                    folded[left] = folded[chosen]
                else
                    voidKids[left] = { a, b }
                end
            elseif op == '..' then
                -- the range operator: in list context the list from the left
                -- to the right value (in scalar context Perl's flip-flop)
                local r = expr(prec + 0.001)
                local text = code
                left = function()
                    evalUnsupported(text, opPos, 'range operator .. in scalar context (flip-flop)')
                end
                listForm[left] = function() return range(sc(l()), sc(r())) end
                voidUse[left] = 'range (or flop)'
            elseif op == '=' then
                local v = lvalues[l]
                if not v then unsupported('assignment to an expression') end
                local r = expr(prec)
                -- (`my` runs after the value: a fresh variable each time)
                local pre = not pureRead[l] and l
                if LIST_PLACE[v.k] then
                    left = function()
                        local val = listOf(r)
                        if pre then pre() end
                        return setVar(v, val)
                    end
                else
                    scalarCtx(r)
                    left = function()
                        local val = r()
                        if pre then pre() end
                        return setVar(v, val)
                    end
                    if folded[r] then constAssign[left] = true end
                    -- (the assignment is the variable: `($x = $y) =~ s/...//`)
                    lvalues[left] = v
                end
            elseif EVAL_ASSIGN_OP[op] then
                local v = lvalues[l]
                if v and v.paren then v = v.single end
                if not v or LIST_PLACE[v.k] or v.k == 'skip' or v.k == 'lastidx' then
                    unsupported(op .. ' on this kind of target')
                end
                local pre = not pureRead[l] and l
                -- (the place, located once per evaluation)
                local cur = {}
                local target = function()
                    if pre then pre() end
                    local c, key = locate(v, true)
                    if not c then perl.die('Modification of a read-only value attempted at (eval 1) line 1.\n') end
                    if key == nil then
                        perl.die('Modification of non-creatable array value attempted at (eval 1) line 1.\n')
                    end
                    cur[1], cur[2] = c, key
                    return cget(c, key)
                end
                varName[target] = nameOf(v)
                -- (an undef target is quietly 0 or '' for .= += -= -- and
                --  ||= &&= //=, which do not use its value)
                local apply = binary(EVAL_ASSIGN_OP[op], target, expr(prec),
                                     op == '.=' or op == '+=' or op == '-=')
                left = function()
                    local c0, k0 = cur[1], cur[2]
                    local val = sc(apply())
                    cset(cur[1], cur[2], val)
                    cur[1], cur[2] = c0, k0
                    return val
                end
                lvalues[left] = v
            elseif (op == '=~' or op == '!~') and (tok == 'subst' or tok == 'trans') then
                local v = lvalues[l]
                if v and v.paren then v = v.single end
                if not v or LIST_PLACE[v.k] or v.k == 'skip' then
                    unsupported(op .. ' s/// or tr/// on an expression')
                end
                if op == '!~' then evalDie(code, pos) end
                local kind, parts = tok, tokVal
                nextTok()
                left = editFn(kind, parts, v, not pureRead[l] and l)
                -- (tr///r warns in void context only on a `my` scalar)
                if sfind(parts[3], 'r', 1, true) and (kind == 'subst' or
                   (v.k == nil and isLexical(v[1], '$'))) then
                    voidUse[left] = NONDESTRUCTIVE[kind]
                end
            elseif op == '=~' or op == '!~' then
                if tok ~= 'regex' then unsupported(op .. ' with a pattern expression') end
                local m, ml = regexFn(tokVal[1], tokVal[2])
                nextTok()
                local neg = op == '!~'
                local lName = varName[l]
                left = function()
                    local r = m(l(), lName)
                    if neg then r = not r end
                    return boolVal(r)
                end
                if neg then voidUse[left] = 'negative pattern binding (!~)' end
                if not neg then listForm[left] = function() return ml(l(), lName) end end
            else
                -- (a left-associative operator: its right operand has only
                --  the operators that bind tighter)
                left = binary(op, l, expr(assoc == 'R' and prec or prec + 0.001))
            end
            if assoc == 'N' then
                local o2 = tok == 'word' and tokVal or tok
                if EVAL_BIN[o2] and EVAL_BIN[o2][1] == prec then evalDie(code, pos) end
            end
        end
        return left
    end
    -- statements: EXPR [if COND | unless COND | for LIST | while COND |
    -- until COND], the block forms of if/unless, the loops, bare blocks,
    -- separated by ';'
    local statements
    -- a block {...} (current token '{'); void: a loop body, whose statements
    -- are all in void context (else the last one gives the block's value)
    block = function(void)
        if tok ~= '{' then evalDie(code, pos) end
        nextTok()
        local stmts = statements('}')
        nextTok()
        if void then
            for k = 1, #stmts do inVoid(stmts[k]) end
        else
            voidStatements(stmts)
        end
        local f = function()
            local r
            for k = 1, #stmts do r = stmts[k]() end
            return r
        end
        if not void then voidKids[f] = { stmts[#stmts] } end
        -- (in list context the last statement gives its list)
        listForm[f] = function()
            for k = 1, #stmts - 1 do stmts[k]() end
            if #stmts == 0 then return newList({}, 0) end
            return listOf(stmts[#stmts])
        end
        return f
    end
    local function condition()
        if tok ~= '(' then evalDie(code, pos) end
        nextTok()
        local c = scalarCtx(condCheck(expr(0)))
        if tok ~= ')' then evalDie(code, pos) end
        nextTok()
        return c
    end
    -- loops ...............................................................
    -- A loop body that contains next or last (`guarded`) runs under pcall:
    -- they raise their Ctl object, which the loop with the label (or the
    -- innermost one) catches.
    -- the body of a loop (current token '{'), and whether it can be left
    -- through next/last
    local function loopBody()
        local before = loopCtl
        local body = block(true)
        return body, loopCtl ~= before
    end
    -- run a loop body once: nil to go on, 'next' or 'last' when it said so
    local function runBody(body, guarded, label)
        if not guarded then
            body()
            return nil
        end
        local ok, err = pcall(body)
        if ok then return nil end
        if getmetatable(err) == Ctl and err.ctl ~= 'return' and (err.label == nil or err.label == label) then
            return err.ctl
        end
        error(err, 0)
    end
    -- foreach over the list closure listE with the loop variable name
    -- (aliasing each element, restored after the loop); its value is '',
    -- undef when last left it
    local function foreachFn(name, listE, body, guarded, label)
        return function()
            local items, cnt, cs, ks, ro = aliasItems(listE and { listE } or {})
            local st = store(name)
            local old = st[name]
            local ok, r = pcall(function()
                for i = 1, cnt do
                    st[name] = items[i]
                    local how = runBody(body, guarded, label)
                    writeBack(st, name, items[i], cs[i], ks[i], ro[i])
                    if how == 'last' then return nil end
                end
                return ''
            end)
            st[name] = old
            if not ok then error(r, 0) end
            return r
        end
    end
    -- for/foreach (current token: what follows the keyword): foreach with
    -- `my $x`, `$x` or $_, or the C-style for (INIT; COND; STEP)
    local function parseFor(label)
        local name, isMy
        if tok == 'word' and tokVal == 'my' then
            nextTok()
            isMy = true
        end
        if tok == 'var' then
            if tokVal.k or tokVal.deref then unsupported('this kind of loop variable') end
            name = tokVal[1]
            nextTok()
        elseif isMy then
            unsupported('this kind of loop variable')
        end
        if tok ~= '(' then evalDie(code, pos) end
        nextTok()
        local listE
        if tok ~= ')' then
            if not name and tok == ';' then
                listE = nil
            else
                listE = expr(0)
            end
        end
        if not name and tok == ';' then
            -- for (INIT; COND; STEP) BLOCK: the value is the last condition's
            local init = listE
            nextTok()
            local cond, step
            if tok ~= ';' then cond = scalarCtx(expr(0)) end
            if tok ~= ';' then evalDie(code, pos) end
            nextTok()
            if tok ~= ')' then step = expr(0) end
            if tok ~= ')' then evalDie(code, pos) end
            nextTok()
            if init then inVoid(init) end
            if step then inVoid(step) end
            local body, guarded = loopBody()
            return function()
                if init then init() end
                local c
                while true do
                    if cond then
                        c = sc(cond())
                        if not perl.truthy(c) then break end
                    end
                    if runBody(body, guarded, label) == 'last' then return nil end
                    if step then step() end
                end
                return c
            end
        end
        if tok ~= ')' then evalDie(code, pos) end
        nextTok()
        if isMy then declared[name] = true end
        local body, guarded = loopBody()
        return foreachFn(name or '_', listE, body, guarded, label)
    end
    -- while/until (COND) BLOCK (current token '('): the value is the last
    -- condition's
    local function parseWhile(neg, label)
        if tok ~= '(' then evalDie(code, pos) end
        nextTok()
        local cond
        if tok ~= ')' then cond = scalarCtx(expr(0)) end
        if tok ~= ')' then evalDie(code, pos) end
        nextTok()
        local body, guarded = loopBody()
        if tok == 'word' and tokVal == 'continue' then unsupported('continue block') end
        return function()
            local c
            while true do
                if cond then
                    c = sc(cond())
                    if perl.truthy(c) == neg then break end
                end
                if runBody(body, guarded, label) == 'last' then return nil end
            end
            return c
        end
    end
    -- (after a '{' that starts a statement: a word or a quoted string and
    --  then `,` or `=>`, the start of an anonymous hash)
    local HASH_START = { '^[ \t\n\r\f\v]*[A-Za-z_][A-Za-z0-9_]*[ \t\n\r\f\v]*()',
                         "^[ \t\n\r\f\v]*'[^']*'[ \t\n\r\f\v]*()", '^[ \t\n\r\f\v]*"[^"]*"[ \t\n\r\f\v]*()' }
    local function anonHashAhead()
        for _, pat in ipairs(HASH_START) do
            local after = smatch(code, pat, pos)
            if after and (ssub(code, after, after) == ',' or ssub(code, after, after + 1) == '=>') then
                return true
            end
        end
        return false
    end
    local function statement()
        local ctlBefore = loopCtl
        -- LABEL: (of a loop, for next/last)
        local label
        if tok == 'word' and not EVAL_BIN[tokVal] and not STMT_WORDS[tokVal] and
           smatch(code, '^[ \t\n\r\f\v]*:', pos) and not smatch(code, '^[ \t\n\r\f\v]*::', pos) then
            label = tokVal
            nextTok()
            nextTok()
        end
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
            local f = function()
                local r
                for k = 1, #conds do
                    r = sc(conds[k]())
                    if perl.truthy(r) ~= (k == 1 and neg) then return bodies[k]() end
                end
                if elseBody then return elseBody() end
                return r
            end
            -- (in void context the bodies that can run: a literal condition
            --  decides at compile time)
            local kids = {}
            voidKids[f] = kids
            for k = 1, #conds do
                local c = folded[conds[k]]
                if not c then
                    kids[#kids + 1] = bodies[k]
                elseif perl.truthy(c[1]) ~= (k == 1 and neg) then
                    kids[#kids + 1] = bodies[k]
                    return f, true
                end
            end
            kids[#kids + 1] = elseBody
            return f, true
        elseif tok == 'word' and (tokVal == 'for' or tokVal == 'foreach') then
            nextTok()
            return parseFor(label), true
        elseif tok == 'word' and (tokVal == 'while' or tokVal == 'until') then
            local neg = tokVal == 'until'
            nextTok()
            return parseWhile(neg, label), true
        elseif tok == '{' and not anonHashAhead() then
            -- (a bare block; `{ WORD =>` or `{ 'string',` is an anonymous
            --  hash instead, as Perl guesses)
            local body = block()
            if loopCtl == ctlBefore then return body, true end
            -- (a bare block is a loop that runs once: next and last leave it)
            local f = function()
                local ok, r = pcall(body)
                if ok then return r end
                if getmetatable(r) == Ctl and r.ctl ~= 'return' and (r.label == nil or r.label == label) then
                    return nil
                end
                error(r, 0)
            end
            voidKids[f] = voidKids[body]
            return f, true
        end
        local e = expr(0)
        if tok == 'word' and (tokVal == 'if' or tokVal == 'unless') then
            local neg = tokVal == 'unless'
            nextTok()
            local c, body = scalarCtx(condCheck(expr(0))), e
            e = function()
                local r = sc(c())
                if perl.truthy(r) ~= neg then return body() end
                return r
            end
            -- (`EXPR if COND` is `COND && EXPR`: a literal condition decides
            --  at compile time, see binary)
            local lit = folded[c]
            if not lit then
                voidKids[e] = { body }
            elseif perl.truthy(lit[1]) == neg then
                voidKids[e] = {}
            elseif folded[body] then
                folded[e] = { folded[body][1], quiet = true }
            else
                voidKids[e] = { body }
            end
        elseif tok == 'word' and (tokVal == 'for' or tokVal == 'foreach') then
            -- EXPR for LIST: EXPR for each element in $_
            nextTok()
            local listE = expr(0)
            inVoid(e)
            e = foreachFn('_', listE, e, loopCtl ~= ctlBefore)
        elseif tok == 'word' and (tokVal == 'while' or tokVal == 'until') then
            -- EXPR while COND (do BLOCK while COND: the block first)
            local neg = tokVal == 'until'
            nextTok()
            local cond = scalarCtx(expr(0))
            local body, guarded = e, loopCtl ~= ctlBefore
            local first = doBlock[e]
            inVoid(e)
            e = function()
                if first then body() end
                local c
                while true do
                    c = sc(cond())
                    if perl.truthy(c) == neg then break end
                    if first then
                        body()
                    elseif runBody(body, guarded) == 'last' then
                        return nil
                    end
                end
                return c
            end
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
    -- the code text of a s///e replacement, parsed with this eval's
    -- variables: returns the closure that runs it (its last statement's)
    subCode = function(text)
        local saved = { code, pos, n, tok, tokVal, tokPos, lastKind }
        code, pos, n, tok = text, 1, #text, nil
        nextTok()
        local stmts = statements('eof')
        code, pos, n, tok, tokVal, tokPos, lastKind = tunpack(saved, 1, 7)
        voidStatements(stmts)
        if #stmts == 1 then return stmts[1] end
        local f = function()
            local r
            for k = 1, #stmts do r = stmts[k]() end
            return r
        end
        return f
    end
    -- the text of a variable expression in an interpolated string (see
    -- interpExtent), parsed as an expression of this eval
    subExpr = function(text)
        local saved = { code, pos, n, tok, tokVal, tokPos, lastKind }
        code, pos, n, tok = text, 1, #text, nil
        nextTok()
        local e = expr(0)
        if tok ~= 'eof' then evalDie(code, pos) end
        code, pos, n, tok, tokVal, tokPos, lastKind = tunpack(saved, 1, 7)
        return e
    end
    nextTok()
    local stmts = statements('eof')
    voidStatements(stmts)
    -- (the value of the last statement: in scalar context, or thrown away
    --  in a void-context eval)
    if not (opts and opts.void) and #stmts > 0 then scalarCtx(stmts[#stmts]) end
    local function main()
        local r
        for k = 1, #stmts do r = stmts[k]() end
        return sc(r)
    end
    return function(vars1, funcs1, outer)
        -- (the state of the run this one interrupts, if any)
        local oldVars, oldFuncs, oldLex, oldCaps, oldMatch, oldAliased = vars, funcs, lex, caps, lastMatch, aliasedVars
        vars, funcs, lex, aliasedVars = vars1, funcs1, {}, false
        if outer then caps, lastMatch = { tunpack(outer) }, outer.amp else caps, lastMatch = {}, nil end
        local oldWarnAt = warnAt
        warnAt = ' at (eval 1) line 1.\n'
        local ok, rtn = pcall(main)
        warnAt = oldWarnAt
        if aliasedVars then
            -- (the caller's variables that `\` aliased get their values back)
            for name, v in pairs(vars) do
                if type(v) == 'table' and getmetatable(v) == Alias then vars[name] = v.cell.value end
            end
        end
        vars, funcs, lex, caps, lastMatch, aliasedVars = oldVars, oldFuncs, oldLex, oldCaps, oldMatch, oldAliased
        if not ok then
            if getmetatable(rtn) ~= Ctl then error(rtn, 0) end
            if rtn.ctl == 'return' then
                rtn = rtn.value
            else
                -- (next/last outside a loop)
                perl.warn('Exiting eval via ' .. rtn.ctl .. ' at (eval 1) line 1.\n')
                if rtn.label then
                    perl.die('Label not found for "' .. rtn.ctl .. ' ' .. rtn.label .. '" at (eval 1) line 1.\n')
                end
                perl.die('Can\'t "' .. rtn.ctl .. '" outside a loop block at (eval 1) line 1.\n')
            end
        end
        return EV.export(rtn)
    end
end

-- (compiled codes by code text and options; emptied when full)
local evalCache = { progs = {}, size = 0, max = 512, noFuncs = {} }
function perl.eval(code, vars, funcs, outer, opts)
    code = perlStr(code)
    funcs = funcs or evalCache.noFuncs
    local key = code
    if opts then
        -- (the options that change the compilation: void, globals)
        local sig = opts.void and 'v' or ''
        if opts.globals then
            local g = {}
            for name in pairs(opts.globals) do g[#g + 1] = name end
            tsort(g)
            sig = sig .. ':' .. tconcat(g, ',')
        end
        key = sig .. '\0' .. code
    end
    local prog = evalCache.progs[key]
    if prog then
        -- (compiled with other functions: a name that is there now and was
        --  not then, or the other way round)
        for name, had in pairs(prog.funcNames) do
            if (funcs[name] ~= nil) ~= had then
                prog = nil
                break
            end
        end
    end
    if not prog then
        prog = { warns = {}, funcNames = {} }
        local ok, res = pcall(compileEval, code, funcs, opts, prog.warns, prog.funcNames)
        if ok then
            prog.run = res
        elseif getmetatable(res) == PerlDie then
            prog.err = res      -- (a syntax error, or code outside the subset)
        else
            error(res, 0)
        end
        if evalCache.size >= evalCache.max then evalCache.progs, evalCache.size = {}, 0 end
        evalCache.progs[key] = prog
        evalCache.size = evalCache.size + 1
    end
    local warns = prog.warns
    for i = 1, #warns do perl.warn(warns[i]) end
    if prog.err then error(prog.err, 0) end
    return prog.run(vars or {}, funcs, outer)
end

return perl
