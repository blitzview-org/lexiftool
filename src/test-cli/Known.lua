--------------------------------------------------------------------------------
-- File:         test-cli/Known.lua
--
-- Description:  Known deviations: cases whose difference comes from internals
--               of the Perl interpreter the port cannot reproduce
--               (doc/cli-tests.md, "Known deviations"). Shared by the CLI
--               golden test (Known.GOLDEN, read by Report.lua) and the corpus
--               run (CorpusReport.KNOWN).
--
--               The form 'upstream-bug' covers the other kind: an obvious bug
--               in exiftool that the port does not reproduce (doc/
--               differences.md, "Upstream bugs the port does not reproduce"),
--               the form 'upstream-fix' an obvious bug that makes exiftool
--               print a wrong result where the port prints the right one,
--               and the form 'perl-bug' a bug of the Perl interpreter itself,
--               in the releases and on the platform recorded for it: it
--               applies only to a reference built by such a Perl (the "perl"
--               line of the reference's run.txt).
--
--               An entry is never a suppression: a case counts as "known" only
--               while its difference has exactly the recorded form -- only the
--               named file differs, and in it only the recorded lines (missing
--               from the test side, reordered, without the variable name, or
--               the other of two recorded hash-order variants), or, for an
--               upstream bug, the reference shows exactly exiftool's abort and
--               the test side exactly the recorded correct result, or, for a
--               wrong result of exiftool, exactly the recorded edits turn the
--               reference into the test side, or, for a Perl bug, every
--               differing line has exactly the wrong value of that bug in the
--               reference and the right one on the test side. Any other
--               difference in the same case makes it an ordinary difference
--               again; a known case that has become identical is reported so
--               its entry can go.
--------------------------------------------------------------------------------

local Util = require('test-cli.Util')

local Known = {}

-- An entry, keyed by case directory:
--   file  the only file that may differ;
--   lines Lua pattern for the only lines that may differ;
--   form  'missing' -- the lines are in the reference only (Perl prints a
--         warning the port cannot), 'order' -- the same lines in another
--         order (Perl hash order), 'unnamed' -- the same lines, but the
--         test side has the warning without Perl's variable name
--         ("Use of uninitialized value $x in" -> "Use of uninitialized
--         value in"), 'hash-order' -- Perl's hash order decides: exiftool
--         walks a hash (`keys %h`) whose order Perl fixes per process (the
--         harness pins PERL_HASH_SEED, which still leaves reference keys to
--         their addresses), lexiftool walks it in its own fixed order
--         (perl.keys), and the two give different ones of the possible
--         results. `hunks` records both variants verbatim: a list of
--         { ref = { lines }, test = { lines } } (ref not empty); the test
--         side must be the reference with every hunk's ref lines (found in
--         this order) replaced by its test lines, and nothing else (`lines`
--         unused), 'upstream-bug' -- exiftool dies on a bug of its own that
--         the port does not reproduce (`file` and `lines` unused): the
--         reference must show exactly that abort -- a non-zero exit status,
--         stderr.txt exactly the lines of `die`, stdout.txt a prefix of the
--         expected output (what exiftool wrote before dying) -- and the test
--         side exactly the expected result, which is the reference of the
--         same case for the image `twin` (an archive that differs from this
--         one only where the bug is not triggered) with every plain string
--         `from` of the pairs in `subst` replaced by its `to`; only
--         stdout.txt, stderr.txt and exit.txt may differ, 'upstream-fix' --
--         exiftool gives a wrong result on a bug of its own that the port
--         does not reproduce (`file` and `lines` unused): `edits` maps each
--         file that may differ to its edits, and every file of the case that
--         differs must be one of them. An edit is either a list of hunks as
--         for 'hash-order' (the reference's lines with every hunk's ref
--         lines, found in this order, replaced by its test lines, must give
--         exactly the test side) or `{ bytes = { ref = S, image = NAME,
--         offset = N, length = L } }`: the reference is exactly the string
--         S and the test side exactly the L bytes at offset N of the fixture
--         NAME (src/test/images), for binary output such as -b, 'perl-bug'
--         -- a bug of the Perl interpreter (`bug`, a key of Known.PERL_BUGS)
--         that the port does not reproduce; the entry applies only where
--         the reference's Perl runs on the bug's platform, and matches only
--         where it is one of the bug's releases; the bug's `check` decides
--         about the differing lines (`lines` unused);
--   why   the reason, one sentence.

-- Perl's `use warnings` on an undef $lensModel in Canon.pm PrintLensID
-- (`$lensModel =~ / \+ ((EXTENDER )?RF)?.../`), shown by -v as a Conv warning.
Known.WHY_LENSMODEL = 'Perl reads the variable name in "Use of uninitialized value $lensModel" from ' ..
    'its op tree; the facade warns as Perl does but sees only the value, not the variable name'
Known.PAT_LENSMODEL = '^  Warning = PrintConv LensID: Use of uninitialized value %$lensModel in pattern match'

-- The golden cases (Cases.lua): Sigma.x3f has no LensModel, so every -v level
-- that prints the conversions carries the warning.
Known.GOLDEN = {}
for _, label in ipairs({ 'dump-v', 'dump-v2', 'dump-v3', 'dump-v5' }) do
    Known.GOLDEN['read/' .. label .. '/Sigma.x3f'] = { file = 'stdout.txt', lines = Known.PAT_LENSMODEL,
                                                       form = 'unnamed', why = Known.WHY_LENSMODEL }
end

-- ReadFilesInfo in 7Z.pm reads the "external" byte of the attributes from the
-- outer stream and then calls the undefined ReadUINT64, so exiftool dies on
-- lex_7Z_ExternalAttr.7z (lex_7Z_PlainHeader.7z with an empty kDummy property
-- after the attributes); read correctly, the archive gives the same tags as
-- lex_7Z_PlainHeader.7z, apart from the file name and size and, in -v3, the
-- header size.
Known.WHY_7Z_ATTR = '7Z.pm ReadFilesInfo reads the attributes\' "external" byte from the wrong stream ' ..
    'and calls the undefined ReadUINT64, so exiftool dies; the port reads the archive as the 7z format defines it'
for _, label in ipairs({ 'default', 'a-u-ee-G1', 'imageDataHash', 'archive-v3', 'archive-j' }) do
    Known.GOLDEN['read/' .. label .. '/lex_7Z_ExternalAttr.7z'] = {
        form = 'upstream-bug', twin = 'lex_7Z_PlainHeader.7z',
        subst = { { 'lex_7Z_PlainHeader.7z', 'lex_7Z_ExternalAttr.7z' },
                  { 'File Size                       : 124 bytes',
                    'File Size                       : 126 bytes' },
                  { '"FileSize": "124 bytes"', '"FileSize": "126 bytes"' },
                  { '  FileSize = 124\n', '  FileSize = 126\n' },
                  { 'NextHeaderSize: 82\n', 'NextHeaderSize: 84\n' } },
        die = { 'Undefined subroutine &Image::ExifTool::7Z::ReadUINT64 called at <FILE> line <N>.' },
        why = Known.WHY_7Z_ATTR }
end

-- Pentax.pm lists the ImageTone values of the GR IV Monochrome as 33024 to
-- 33029 and then Custom 1 to 3 with the key 33024 again; in a Perl hash the
-- last one wins, so exiftool prints 33024 as "Custom 3" (doc/differences.md).
-- lex_Pentax_ImageToneGRIV.jpg has that value; -listx carries the value list.
Known.WHY_PENTAX_TONE = 'Pentax.pm gives ImageTone 33024 four times and the last ("Custom 3") wins; ' ..
    'the port prints "Standard"'
local function toneLine(prefix)
    return { { ref = { prefix .. 'Custom 3' }, test = { prefix .. 'Standard' } } }
end
Known.GOLDEN['read/default/lex_Pentax_ImageToneGRIV.jpg'] = {
    form = 'upstream-fix', why = Known.WHY_PENTAX_TONE,
    edits = { ['stdout.txt'] = toneLine('Image Tone                      : ') } }
Known.GOLDEN['read/a-u-ee-G1/lex_Pentax_ImageToneGRIV.jpg'] = {
    form = 'upstream-fix', why = Known.WHY_PENTAX_TONE,
    edits = { ['stdout.txt'] = toneLine('[Pentax]        Image Tone                      : ') } }
Known.GOLDEN['read/pentax-imagetone/lex_Pentax_ImageToneGRIV.jpg'] = {
    form = 'upstream-fix', why = Known.WHY_PENTAX_TONE,
    edits = { ['stdout.txt'] = toneLine('[Pentax]        Image Tone                      : ') } }

-- QuickTime.pm lists the PreviewImage of a `skip` atom (DuDuBell M1) after
-- the unconditional Skip entry, so exiftool never extracts it (doc/
-- differences.md); lex_QuickTime_SkipPreview.mov has that layout, and the
-- third `skip` atom of lex_QuickTime_VideoExt.mp4 (12 bytes and a JPEG start)
-- matches the preview's condition too. In -listx the two entries swap their
-- index. (The outputs of the `dir` and `stay` groups are sorted.)
Known.WHY_QT_SKIP = 'QuickTime.pm puts the skip atom\'s PreviewImage after the unconditional Skip ' ..
    'entry, so exiftool never extracts it; the port checks the preview first'
local function qtFix(case, hunks)
    Known.GOLDEN[case] = { form = 'upstream-fix', why = Known.WHY_QT_SKIP, edits = { ['stdout.txt'] = hunks } }
end
local function swap(ref, test) return { { ref = { ref }, test = { test } } } end
local function insert(after, line) return { { ref = { after }, test = { after, line } } } end
qtFix('read/default/lex_QuickTime_SkipPreview.mov',
      insert('Compatible Brands               : qt',
             'Preview Image                   : (Binary data 332 bytes, use -b option to extract)'))
qtFix('read/a-u-ee-G1/lex_QuickTime_SkipPreview.mov',
      swap('[QuickTime]     Skip                            : (Binary data 344 bytes, use -b option to extract)',
           '[QuickTime]     Preview Image                   : (Binary data 332 bytes, use -b option to extract)'))
Known.GOLDEN['read/qt-skip-preview/lex_QuickTime_SkipPreview.mov'] = {
    form = 'upstream-fix', why = Known.WHY_QT_SKIP,
    edits = { ['stdout.txt'] = { bytes = { ref = '', image = 'lex_QuickTime_SkipPreview.mov',
                                           offset = 40, length = 332 } } } }
qtFix('read/default/lex_QuickTime_VideoExt.mp4',
      insert('Version                         : 2.1',
             'Preview Image                   : (Binary data 8 bytes, use -b option to extract)'))
local QT_VIDEOEXT_G1 = swap(
    '[QuickTime]     Skip                            : (Binary data 20 bytes, use -b option to extract)',
    '[QuickTime]     Preview Image                   : (Binary data 8 bytes, use -b option to extract)')
qtFix('read/a-u-ee-G1/lex_QuickTime_VideoExt.mp4', QT_VIDEOEXT_G1)
qtFix('read/qt-new/lex_QuickTime_VideoExt.mp4', QT_VIDEOEXT_G1)
qtFix('stay/s-stdin-qt-fast/all', QT_VIDEOEXT_G1)
qtFix('read/qt-new-j/lex_QuickTime_VideoExt.mp4',
      insert('  "QuickTime:Version": "2.1",',
             '  "QuickTime:PreviewImage": "(Binary data 8 bytes, use -b option to extract)",'))
qtFix('read/qt-new-v3/lex_QuickTime_VideoExt.mp4', swap('  Skip = ........', '  PreviewImage = ........'))

-- -listx (sorted): one "Custom 3" fewer, one "Standard" more, and the index
-- of the two `skip` entries swapped -- both bugs at once
for _, label in ipairs({ 'd-listx-all', 'd-listx-lang0' }) do
    Known.GOLDEN['dir/' .. label .. '/all'] = {
        form = 'upstream-fix', why = Known.WHY_PENTAX_TONE .. '; ' .. Known.WHY_QT_SKIP,
        edits = { ['stdout.txt'] = {
            { ref = { "    <val lang='en'>Custom 3</val>", "    <val lang='en'>Custom 4</val>" },
              test = { "    <val lang='en'>Custom 4</val>" } },
            { ref = { "    <val lang='en'>Standard</val>", "    <val lang='en'>Stanford MIPS-X</val>" },
              test = { "    <val lang='en'>Standard</val>", "    <val lang='en'>Standard</val>",
                       "    <val lang='en'>Stanford MIPS-X</val>" } },
            { ref = { " <tag id='skip' name='PreviewImage' index='5' type='?' writable='false' g2='Preview'>",
                      " <tag id='skip' name='Skip' index='4' type='?' writable='false'>" },
              test = { " <tag id='skip' name='PreviewImage' index='4' type='?' writable='false' g2='Preview'>",
                       " <tag id='skip' name='Skip' index='5' type='?' writable='false'>" } } } } }
end

-- Geolocation.pm ReadDatabase never clears @countryList/@regionList/
-- @subregionList/@timezoneList (or %featureTypes) before reading them, so a
-- GeoDir database that ends inside one of those lists leaves it half
-- filled; when ReadDatabase then falls back to the bundled database, the
-- fallback's entries are appended onto the leftover ones and every index
-- into that list is off by the leftover count (doc/differences.md).
-- lex_Geolocation_GeoDirTruncList/Geolocation.dat ends after five country
-- records, so GPS.jpg's country index lands on the sixth bundled entry
-- ("FK"/"Falkland Islands") instead of the right one ("GB"/"United
-- Kingdom").
Known.WHY_GEODIR_TRUNCLIST = 'Geolocation.pm ReadDatabase never clears the country/region/subregion/' ..
    'timezone lists before a GeoDir database is read, so a database truncated inside one of them leaves ' ..
    'leftover entries that shift every index once the bundled database is appended; the port clears them'
Known.GOLDEN['read/api-geodir-trunc-list/GPS.jpg'] = {
    form = 'upstream-fix', why = Known.WHY_GEODIR_TRUNCLIST,
    edits = { ['stdout.txt'] = {
        { ref = { '[ExifTool]      Geolocation Country Code        : FK' },
          test = { '[ExifTool]      Geolocation Country Code        : GB' } },
        { ref = { '[ExifTool]      Geolocation Country             : Falkland Islands' },
          test = { '[ExifTool]      Geolocation Country             : United Kingdom' } } } } }

-- An over-long varint as the size of a FLIF chunk: FLIF.pm's GetVarInt
-- returns undef, which Perl's `use warnings` reports wherever it is used
-- (RandomAccess Read, the comparisons); the port numifies the undef as Perl
-- does, but cannot name the variable or the Perl source line.
Known.WHY_FLIF_UNDEF = 'Perl warns "Use of uninitialized value" for the undefined FLIF chunk size; ' ..
    'the port uses the value as Perl does without that interpreter warning'
for _, c in ipairs({ 'read/default', 'read/a-u-ee-G1', 'read/imageDataHash', 'read/bounds-v3', 'write/w-Subject' }) do
    Known.GOLDEN[c .. '/lex_FLIF_LongChunkSize.flif'] = { file = 'stderr.txt', form = 'missing',
        lines = '^Use of uninitialized value %$[_A-Za-z][_A-Za-z0-9]* in .* at <FILE> line <N>%.\r?$',
        why = Known.WHY_FLIF_UNDEF }
end

-- Bugs of the Perl interpreter the port does not reproduce (form
-- 'perl-bug'). Per bug: `os`, the platform it shows on (Perl's $^O), `perls`,
-- the releases that have it ($^V), and `check(k, ref, test)`, which decides
-- whether one differing line pair has exactly the bug's form for entry `k`.
Known.PERL_BUGS = {}

-- The day of the week (0 = Sunday) of a date of the Gregorian calendar
local function weekday(y, m, d)
    local t = { 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 }
    if m < 3 then y = y - 1 end
    return (y + y // 4 - y // 100 + y // 400 + t[m] + d) % 7
end

-- The day of the month of the n-th (5: last) Sunday of a month
local function sunday(y, m, n)
    local first = 1 + (7 - weekday(y, m, 1)) % 7
    local d = first + (n - 1) * 7
    local len = ({ 31, (y % 4 == 0 and y % 100 ~= 0 or y % 400 == 0) and 29 or 28,
                   31, 30, 31, 30, 31, 31, 30, 31, 30, 31 })[m]
    while d > len do d = d - 7 end
    return d
end

-- Is the date a whole day of DST under the US rules the Windows C runtime
-- applies to every TZ value with a DST name (from 2007: second Sunday of
-- March to first Sunday of November, before: first Sunday of April to last
-- Sunday of October)? The days of the changes themselves are left out.
local function usDstDay(y, m, d)
    local sm, sn, em, en = 4, 1, 10, 5
    if y >= 2007 then sm, sn, em, en = 3, 2, 11, 1 end
    local v, s, e = m * 100 + d, sm * 100 + sunday(y, sm, sn), em * 100 + sunday(y, em, en)
    return v > s and v < e
end

-- POSIX::strftime of Perl 5.42.0 defaults its isdst argument to 0 (Perl
-- GH #22351, fixed in 5.42.1), so on Windows, where Perl has no tm_gmtoff/
-- tm_zone, it calls no mktime: the C runtime's %Z is the standard name for
-- every date. With the fix (isdst -1) mktime decides: the DST name for a
-- date in DST, and for one before 1970, where mktime fails and the C
-- runtime takes the remaining tm_isdst -1 as true. The -d format of the
-- tz-d-*/tz-past-* cases ends in "%z %Z"; %z is exiftool's own
-- (TimeZoneString), so only the name may differ: the reference line ends in
-- the standard name `k.std`, the test line is the same line with the DST
-- name `k.dst` instead (without the space when that is empty, as exiftool
-- trims the value), and its date is before 1969 or a whole day of DST.
Known.PERL_BUGS['strftime-isdst0'] = {
    os = 'MSWin32',
    perls = { ['5.42.0'] = true },
    check = function(k, ref, test)
        local head, y, m, d, name = ref:match('^(.-: (%d%d%d%d):(%d%d):(%d%d) %d%d:%d%d:%d%d [-+]%d%d%d%d) (.*)$')
        if head == nil or name ~= k.std then return false end
        if test ~= ((head .. ' ' .. k.dst):gsub(' +$', '')) then return false end
        y, m, d = tonumber(y), tonumber(m), tonumber(d)
        return y < 1969 or (k.dst ~= '' and usDstDay(y, m, d))
    end,
}

-- The tz-d-*/tz-past-* cases (Cases.TIME_ZONES) in a reference by Perl
-- 5.42.0 on Windows: the standard and DST names the C runtime reads from
-- each TZ value (its first three characters, and the three after the offset
-- if anything follows it), and the images whose dates show the bug -- a
-- summer date in a zone with DST, or any date before 1970 (tz-past-*).
Known.WHY_STRFTIME_ISDST0 = 'POSIX::strftime of Perl 5.42.0 defaults isdst to 0 (Perl GH #22351), so on ' ..
    'Windows %Z is the standard name all year; the port behaves as Perl with the fix'
local CRT_NAMES = {
    est5edt = { 'EST', 'EDT' }, ny = { 'Ame', 'ric' }, berlin = { 'Eur', 'ope' }, p05 = { '<+0', '>-5' },
    plus5 = { '+05', '' }, minus5 = { '-05', '' }, utc = { 'UTC', '' },
}
local function perlBugCases(label, zones, images)
    for _, z in ipairs(zones) do
        for _, img in ipairs(images) do
            Known.GOLDEN['read/' .. label .. z .. '/' .. img] = {
                form = 'perl-bug', bug = 'strftime-isdst0', file = 'stdout.txt',
                std = CRT_NAMES[z][1], dst = CRT_NAMES[z][2], why = Known.WHY_STRFTIME_ISDST0 }
        end
    end
end
perlBugCases('tz-d-', { 'est5edt', 'ny', 'berlin', 'p05' },
             { 'CanonRaw.cr2', 'ExifTool.jpg', 'GPS.jpg', 'Nikon.jpg', 'PDF.pdf', 'Photoshop.psd',
               'QuickTime.mov', 'XMP.xmp' })
perlBugCases('tz-past-', { 'est5edt', 'ny', 'berlin', 'p05', 'plus5', 'minus5', 'utc' },
             { 'Canon.jpg', 'ExifTool.jpg', 'Nikon.jpg', 'QuickTime.mov' })

-- The Perl of a tree (the "perl" line of its run.txt: release and $^O), or
-- nil for a tree that has none
local perlOfTree = {}
local function treePerl(tree)
    if perlOfTree[tree] == nil then
        local text = Util.readFile(tree .. '/run.txt') or ''
        local v, plat = text:match('\nperl: (%S+) (%S+)')
        perlOfTree[tree] = v and { version = v, os = plat } or false
    end
    return perlOfTree[tree] or nil
end

-- Does entry `k` apply to the trees at all? A 'perl-bug' entry only where
-- the reference's Perl runs on the bug's platform; every other form always.
-- (An entry that applies and whose case is identical is reported, so it can
-- go -- for a Perl bug, once the reference's Perl no longer has it.)
function Known.applies(k, o)
    if k.form ~= 'perl-bug' then return true end
    local p = treePerl(o.refTree)
    return p ~= nil and p.os == Known.PERL_BUGS[k.bug].os
end

local function splitLines(text)
    local t = {}
    for line in (text or ''):gmatch('([^\n]*)\n') do t[#t + 1] = line end
    return t
end

-- Every occurrence of the plain string `from` in `text` replaced by `to`.
local function replacePlain(text, from, to)
    local out, pos = {}, 1
    while true do
        local a, b = text:find(from, pos, true)
        if not a then break end
        out[#out + 1] = text:sub(pos, a - 1)
        out[#out + 1] = to
        pos = b + 1
    end
    out[#out + 1] = text:sub(pos)
    return table.concat(out)
end

-- The reference's lines `ref` with every hunk's ref lines (found in this
-- order) replaced by its test lines: equal to `test`, with every hunk found?
local function replayHunks(hunks, ref, test)
    local out, i, h = {}, 1, 1
    while i <= #ref do
        local hunk = hunks[h]
        local at = hunk ~= nil and #hunk.ref > 0
        if at then
            for j = 1, #hunk.ref do
                if ref[i + j - 1] ~= hunk.ref[j] then at = false break end
            end
        end
        if at then
            for _, l in ipairs(hunk.test) do out[#out + 1] = l end
            i, h = i + #hunk.ref, h + 1
        else
            out[#out + 1] = ref[i]
            i = i + 1
        end
    end
    if h <= #hunks or #out ~= #test then return false end
    for j = 1, #out do
        if out[j] ~= test[j] then return false end
    end
    return true
end

-- Form 'upstream-fix' (see the entry fields above): every differing file is
-- one of `edits`, and each of those turns the reference into the test side.
function Known.matchesUpstreamFix(r, k, o)
    if #r.diffs == 0 then return false end
    for _, f in ipairs(r.diffs) do
        if k.edits[f] == nil then return false end
    end
    for f, e in pairs(k.edits) do
        local refText = Util.readFile(o.refTree .. '/' .. r.dir .. '/' .. f)
        local testText = Util.readFile(o.testTree .. '/' .. r.dir .. '/' .. f)
        if refText == nil or testText == nil then return false end
        if e.bytes then
            if refText ~= e.bytes.ref or o.imagesDir == nil then return false end
            local img = Util.readFile(o.imagesDir .. '/' .. e.bytes.image)
            if img == nil or testText ~= img:sub(e.bytes.offset + 1, e.bytes.offset + e.bytes.length) then
                return false
            end
        -- (the hunks are recorded without the "\r" that ends every line of
        --  Perl's text-mode output on Windows; both sides lose it alike)
        elseif not replayHunks(e, splitLines((refText:gsub('\r\n', '\n'))),
                               splitLines((testText:gsub('\r\n', '\n')))) then
            return false
        end
    end
    return true
end

-- Form 'upstream-bug' (see the entry fields above).
function Known.matchesUpstreamBug(r, k, o)
    local allowed = { ['stdout.txt'] = true, ['stderr.txt'] = true, ['exit.txt'] = true }
    for _, f in ipairs(r.diffs) do
        if not allowed[f] then return false end
    end
    local refDir = o.refTree .. '/' .. r.dir
    local testDir = o.testTree .. '/' .. r.dir
    local twinDir = o.refTree .. '/' .. r.dir:gsub('[^/]+$', '') .. k.twin
    local function read(dir, f) return Util.readFile(dir .. '/' .. f) end
    -- (the recorded strings end their lines in "\n"; a file whose lines end
    -- in "\r\n" -- Perl's text-mode STDOUT/STDERR on Windows -- gets them
    -- with that line end)
    local function eol(text, s)
        if text:find('\r\n', 1, true) then return (s:gsub('\n', '\r\n')) end
        return s
    end
    -- the expected result: the twin's reference with the recorded replacements
    local expect = {}
    for f in pairs(allowed) do
        local text = read(twinDir, f)
        if text == nil then return false end
        for _, p in ipairs(k.subst) do text = replacePlain(text, eol(text, p[1]), eol(text, p[2])) end
        expect[f] = text
        if read(testDir, f) ~= text then return false end
    end
    -- the reference: exactly exiftool's abort
    local exit = (read(refDir, 'exit.txt') or ''):match('^%s*(%-?%d+)%s*$')
    if exit == nil or exit == '0' then return false end
    local err = read(refDir, 'stderr.txt') or ''
    if err ~= eol(err, table.concat(k.die, '\n') .. '\n') then return false end
    local out = read(refDir, 'stdout.txt')
    if out == nil or expect['stdout.txt']:sub(1, #out) ~= out then return false end
    return true
end

-- Form 'perl-bug' (see the entry fields above): only `file` differs, the
-- line count is the same, and every differing line pair -- at least one --
-- passes the bug's check (with the same line end on both sides).
function Known.matchesPerlBug(r, k, o)
    local bug = Known.PERL_BUGS[k.bug]
    local p = treePerl(o.refTree)
    if bug == nil or p == nil or p.os ~= bug.os or not bug.perls[p.version] then return false end
    if #r.diffs ~= 1 or r.diffs[1] ~= k.file then return false end
    local ref = splitLines(Util.readFile(o.refTree .. '/' .. r.dir .. '/' .. k.file))
    local test = splitLines(Util.readFile(o.testTree .. '/' .. r.dir .. '/' .. k.file))
    if #ref ~= #test then return false end
    local any = false
    for i = 1, #ref do
        if ref[i] ~= test[i] then
            local a, b = (ref[i]:gsub('\r$', '')), (test[i]:gsub('\r$', ''))
            if (#a == #ref[i]) ~= (#b == #test[i]) or not bug.check(k, a, b) then return false end
            any = true
        end
    end
    return any
end

-- Does the difference of result `r` (Compare) have exactly the recorded form
-- `k`? `o.refTree`/`o.testTree` are the two trees.
function Known.matches(r, k, o)
    if k.form == 'upstream-bug' then return Known.matchesUpstreamBug(r, k, o) end
    if k.form == 'upstream-fix' then return Known.matchesUpstreamFix(r, k, o) end
    if k.form == 'perl-bug' then return Known.matchesPerlBug(r, k, o) end
    if #r.diffs ~= 1 or r.diffs[1] ~= k.file then return false end
    local ref = splitLines(Util.readFile(o.refTree .. '/' .. r.dir .. '/' .. k.file))
    local test = splitLines(Util.readFile(o.testTree .. '/' .. r.dir .. '/' .. k.file))
    if k.form == 'missing' then
        local kept = {}
        for _, l in ipairs(ref) do
            if not l:find(k.lines) then kept[#kept + 1] = l end
        end
        if #kept ~= #test then return false end
        for i = 1, #kept do
            if kept[i] ~= test[i] then return false end
        end
        return true
    end
    if k.form == 'hash-order' then return replayHunks(k.hunks, ref, test) end
    if k.form == 'unnamed' then
        if #ref ~= #test then return false end
        local any = false
        for i = 1, #ref do
            if ref[i] ~= test[i] then
                if not ref[i]:find(k.lines) then return false end
                local unnamed = ref[i]:gsub('Use of uninitialized value %$[_A-Za-z][_A-Za-z0-9]* in ',
                                            'Use of uninitialized value in ', 1)
                if unnamed ~= test[i] then return false end
                any = true
            end
        end
        return any
    end
    -- 'order': same lines, and every line at a changed position is a recorded one
    if #ref ~= #test then return false end
    for i = 1, #ref do
        if ref[i] ~= test[i] and not (ref[i]:find(k.lines) and test[i]:find(k.lines)) then
            return false
        end
    end
    table.sort(ref)
    table.sort(test)
    for i = 1, #ref do
        if ref[i] ~= test[i] then return false end
    end
    return true
end

return Known
