--------------------------------------------------------------------------------
-- File:         lexiftool/DjVu.lua
-- Ported from:  lib/Image/ExifTool/DjVu.pm
--
-- Description:  Read DjVu archive meta information
--
-- Revisions:    09/25/2008 - P. Harvey Created
--
-- References:   1) http://djvu.sourceforge.net/ (DjVu v3 specification, Nov 2005)
--               2) http://www.djvu.org/
--
-- Notes:        DjVu files are recognized and the IFF structure is processed
--               by Image::ExifTool::AIFF
--
-- Port notes:   read port: the Main/Info/Form/Ant/Meta tables plus ParseAnt,
--               ProcessAnt, ProcessMeta and ProcessBZZ (the BZZ decoder itself
--               lives in BZZ.lua, as upstream). Upstream DjVu.pm is read-only.
--               ParseAnt's `$$dataPt` with its pos() is the box
--               `{ data = ..., pos = ... }`; matchG stands for the scalar
--               `$$dataPt =~ /.../g`.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
-- (XMP is required at the point of use, not at the top: a top-level require
--  would load it for every file that loads this module, and
--  BuildCompositeTags derives its worklist from `package.loaded`)
local perl = require('lexiftool.perl')
local str = perl.str
local ucfirst = perl.ucfirst
local matches, isMatch, subst = perl.matches, perl.isMatch, perl.subst
local substr, length = perl.substr, perl.length
local tr = perl.tr

local DjVu = {}

-- DjVu chunks that we parse (ref 4)
DjVu.Main = {
    GROUPS = { [2] = 'Image' },
    NOTES = [[
        Information is extracted from the following chunks in DjVu images. See
        L<http://www.djvu.org/> for the DjVu specification.
    ]],
    INFO = {
        SubDirectory = { TagTable = 'lexiftool.DjVu.Info' },
    },
    FORM = {
        TypeOnly = 1, -- extract chunk type only, then descend into chunk
        SubDirectory = { TagTable = 'lexiftool.DjVu.Form' },
    },
    ANTa = {
        SubDirectory = { TagTable = 'lexiftool.DjVu.Ant' },
    },
    ANTz = {
        Name = 'CompressedAnnotation',
        SubDirectory = {
            TagTable = 'lexiftool.DjVu.Ant',
            -- ProcessProc wired below (forward reference to DjVu.ProcessBZZ)
        },
    },
    INCL = 'IncludedFileID',
}

-- information in the DjVu INFO chunk
DjVu.Info = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Image' },
    FORMAT = 'int8u',
    PRIORITY = 0, -- first INFO block takes priority
    [0] = {
        Name = 'ImageWidth',
        Format = 'int16u',
    },
    [2] = {
        Name = 'ImageHeight',
        Format = 'int16u',
    },
    [4] = {
        Name = 'DjVuVersion',
        Description = 'DjVu Version',
        Format = 'int8u[2]',
        -- (this may be just one byte as with version 0.16)
        ValueConv = function(_self, val)
            local a, b = str(val):match('(%d+) (%d+)')
            if a then return b .. '.' .. a end
            return '0.' .. str(val)
        end,
    },
    [6] = {
        Name = 'SpatialResolution',
        Format = 'int16u',
        ValueConv = function(_self, val) return ((val & 0xff) << 8) + (val >> 8) end, -- (little-endian!)
    },
    [8] = {
        Name = 'Gamma',
        ValueConv = function(_self, val) return val / 10 end,
    },
    [9] = {
        Name = 'Orientation',
        Mask = 0x07, -- (upper 5 bits reserved)
        PrintConv = {
            [1] = 'Horizontal (normal)',
            [2] = 'Rotate 180',
            [5] = 'Rotate 90 CW',
            [6] = 'Rotate 270 CW',
        },
    },
}

-- information in the DjVu FORM chunk
DjVu.Form = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Image' },
    [0] = {
        Name = 'SubfileType',
        Format = 'undef[4]',
        Priority = 0,
        PrintConv = {
            DJVU = 'Single-page image',
            DJVM = 'Multi-page document',
            PM44 = 'Color IW44',
            BM44 = 'Grayscale IW44',
            DJVI = 'Shared component',
            THUM = 'Thumbnail image',
        },
    },
}

-- tags found in the DjVu annotation chunk (ANTz or ANTa)
DjVu.Ant = {
    -- PROCESS_PROC wired below (forward reference to DjVu.ProcessAnt)
    GROUPS = { [2] = 'Image' },
    NOTES = 'Information extracted from annotation chunks.',
    metadata = {
        SubDirectory = { TagTable = 'lexiftool.DjVu.Meta' },
    },
    xmp = {
        Name = 'XMP',
        SubDirectory = { TagTable = 'lexiftool.XMP.Main' },
    },
}

-- tags found in the DjVu annotation metadata
DjVu.Meta = {
    -- PROCESS_PROC wired below (forward reference to DjVu.ProcessMeta)
    GROUPS = { [1] = 'DjVu-Meta', [2] = 'Image' },
    NOTES = [[
        This table lists the standard DjVu metadata tags, but ExifTool will extract
        any tags that exist even if they don't appear here.  The DjVu v3
        documentation endorses tags borrowed from two standards: 1) BibTeX
        bibliography system tags (all lowercase Tag ID's in the table below), and 2)
        PDF DocInfo tags (capitalized Tag ID's).
    ]],
    -- BibTeX tags (ref http://en.wikipedia.org/wiki/BibTeX)
    address = { Groups = { [2] = 'Location' } },
    annote = { Name = 'Annotation' },
    author = { Groups = { [2] = 'Author' } },
    booktitle = { Name = 'BookTitle' },
    chapter = {},
    crossref = { Name = 'CrossRef' },
    edition = {},
    eprint = { Name = 'EPrint' },
    howpublished = { Name = 'HowPublished' },
    institution = {},
    journal = {},
    key = {},
    month = { Groups = { [2] = 'Time' } },
    note = {},
    number = {},
    organization = {},
    pages = {},
    publisher = {},
    school = {},
    series = {},
    title = {},
    type = {},
    url = { Name = 'URL' },
    volume = {},
    year = { Groups = { [2] = 'Time' } },
    -- PDF tags (same as Image::ExifTool::PDF::Info)
    Title = {},
    Author = { Groups = { [2] = 'Author' } },
    Subject = {},
    Keywords = {},
    Creator = {},
    Producer = {},
    CreationDate = {
        Name = 'CreateDate',
        Groups = { [2] = 'Time' },
        -- RFC 3339 date/time format
        ValueConv = function(_self, val) return require('lexiftool.XMP').ConvertXMPDate(val) end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    ModDate = {
        Name = 'ModifyDate',
        Groups = { [2] = 'Time' },
        ValueConv = function(_self, val) return require('lexiftool.XMP').ConvertXMPDate(val) end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    Trapped = {
        -- remove leading '/' from '/True' or '/False'
        ValueConv = function(_self, val) return str(val):gsub('^/', '') end,
    },
}

-- (port helper: Perl's `$$dataPt =~ /pat/g` in scalar context on a
--  `{ data = <string>, pos = <0-based pos() or nil> }` box -- match from
--  pos(), set pos() past the match and return the first capture, or reset
--  pos() to undef on failure)
local function matchG(dataPt, pat)
    local c, e = matches(dataPt.data, pat, dataPt.pos)
    if e == nil then
        dataPt.pos = nil
        return nil
    end
    dataPt.pos = e
    return c
end

--------------------------------------------------------------------------------
-- Parse DjVu annotation "s-expression" syntax (recursively)
-- Inputs: 0) data ref (with pos($$dataPt) set to start of annotation)
-- Returns: reference to list of tokens/references, or undef if no tokens,
--          and the position in $$dataPt is set to end of last token
-- Notes: The DjVu annotation syntax is not well documented, so I make
--        a number of assumptions here!
-- (Lua: dataPt is the matchG box above)
local function ParseAnt(dataPt)
    local toks, tok, more = {}
    -- (the DjVu annotation syntax really sucks, and requires that every
    -- single token be parsed in order to properly scan through the items)
    while true do   -- (Tok:)
        -- find the next token
        local c1 = matchG(dataPt, [[(?s)(\S)]])   -- get next non-space character
        if c1 == nil then break end
        if c1 == '(' then       -- start of list
            tok = ParseAnt(dataPt)
        elseif c1 == ')' then  -- end of list
            more = 1
            break
        elseif c1 == '"' then  -- quoted string
            tok = ''
            while true do
                -- get string up to the next quotation mark
                -- this doesn't work in perl 5.6.2! grrrr
                -- last Tok unless $$dataPt =~ /(.*?)"/sg;
                -- $tok .= $1;
                local pos = dataPt.pos
                if matchG(dataPt, [[(?s)"]]) == nil then goto Tok end    -- (last Tok)
                tok = tok .. substr(dataPt.data, pos, dataPt.pos-1-pos)
                -- we're good unless quote was escaped by odd number of backslashes
                local ok, bs = isMatch(tok, [[(\\+)$]])
                if not (ok and (length(bs) & 0x01) ~= 0) then break end
                tok = tok .. '"'    -- quote is part of the string
            end
            -- convert C escape sequences, allowed in quoted text
            -- (note: this only converts a few of them!)
            local esc = { a = "\a", b = "\b", f = "\f", n = "\n",
                          r = "\r", t = "\t", ['"'] = '"', ['\\'] = '\\' }
            tok = subst(tok, [[(?s)\\(.)]], function(c) return esc[c] or '\\' .. c end, 'g')
        else                -- key name
            dataPt.pos = dataPt.pos - 1
            -- allow anything in key but whitespace, braces and double quotes
            -- (this is one of those assumptions I mentioned)
            tok = matchG(dataPt, [[(?s)([^\s()"]+)]])
        end
        if tok ~= nil then toks[#toks+1] = tok end
    end
    ::Tok::
    -- prevent further parsing unless more after this
    if not more then dataPt.pos = length(dataPt.data) end
    if #toks > 0 then return toks end
    return nil
end

--------------------------------------------------------------------------------
-- Process DjVu annotation chunk (ANTa or decoded ANTz)
-- Inputs: 0) ExifTool object reference, 1) DirInfo reference, 2) tag table ref
-- Returns: 1 on success
--------------------------------------------------------------------------------
function DjVu.ProcessAnt(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    -- quick pre-scan to check for metadata or XMP
    -- upstream: `$$dataPt =~ /\(\s*(metadata|xmp)[\s("]/s` (PCRE2 via the
    -- facade -- Lua patterns have no alternation)
    if not perl.matches(dataPt, '\\(\\s*(metadata|xmp)[\\s("]') then
        return 1
    end
    -- parse annotations into a tree structure
    local toks = ParseAnt({ data = dataPt, pos = 0 })   -- (pos($$dataPt) = 0)
    if not toks then return 0 end
    -- process annotations individually
    for _, ant in ipairs(toks) do
        if type(ant) == 'table' and #ant >= 2 then
            local tag = ant[1]
            if type(tag) ~= 'table' and tagTablePtr[tag] ~= nil then
                if tag == 'metadata' then
                    local rest = {}
                    for i = 2, #ant do rest[#rest + 1] = ant[i] end
                    -- ProcessMeta() takes the parsed entry list directly
                    -- (upstream: `$et->HandleTag($tagTablePtr, $tag, $ant)`
                    -- with no DataPt parm -- HandleTag's own SubDirectory
                    -- fallback derives the subdirectory's data from the
                    -- value itself when no DataPt is given)
                    et:HandleTag(tagTablePtr, tag, rest)
                elseif type(ant[2]) ~= 'table' then -- only process simple values
                    et:HandleTag(tagTablePtr, tag, ant[2])
                end
            end
        end
    end
    return 1
end

--------------------------------------------------------------------------------
-- Process DjVu metadata
-- Inputs: 0) ExifTool object reference, 1) DirInfo reference, 2) tag table ref
-- Returns: 1 on success
-- Notes: input dirInfo DataPt is a reference to a list of pre-parsed metadata entries
-- (Lua: DataPt is the list itself)
--------------------------------------------------------------------------------
function DjVu.ProcessMeta(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    if perl.ref(dataPt) ~= 'ARRAY' then return 0 end
    et:VerboseDir('Metadata', #dataPt)
    local err
    for _, item in ipairs(dataPt) do
        -- make sure item is a simple tag/value pair
        if not (perl.ref(item) == 'ARRAY' and #item >= 2 and
                perl.ref(item[1]) == '' and perl.ref(item[2]) == '') then err = 1 goto next end
        -- add any new tags to the table
        if not tagTablePtr[item[1]] then
            local name = item[1]
            name = tr(name, '-_a-zA-Z0-9', '', 'dc') -- remove illegal characters
            if length(name) == 0 then err = 1 goto next end
            et:AddTagToTable(tagTablePtr, item[1], { Name = ucfirst(name) })
        end
        et:HandleTag(tagTablePtr, item[1], item[2])
        ::next::
    end
    if err then et:Warn('Ignored invalid metadata entry(s)') end
    return 1
end

--------------------------------------------------------------------------------
-- Process BZZ-compressed data (in DjVu images)
-- Inputs: 0) ExifTool object reference, 1) DirInfo reference, 2) tag table ref
-- Returns: 1 on success
--------------------------------------------------------------------------------
function DjVu.ProcessBZZ(et, dirInfo, tagTablePtr)
    local BZZ = require('lexiftool.BZZ')
    local buff = BZZ.Decode(dirInfo.DataPt)
    if buff == nil then
        et:Warn('Error decoding ' .. str(dirInfo.DirName))
        return 0
    end
    local verbose = et:Options('Verbose')
    if perl.num(verbose) >= 3 then
        -- dump the decoded data in very verbose mode
        et:VerboseDir('Decoded ' .. str(dirInfo.DirName), 0, #buff)
        et:VerboseDump(buff)
    end
    dirInfo.DataPt = buff
    dirInfo.DataLen = #buff
    dirInfo.DirLen = #buff
    -- process the data using the default process proc for this table
    local processProc = tagTablePtr.PROCESS_PROC
    if not processProc then return 0 end
    return processProc(et, dirInfo, tagTablePtr)
end

DjVu.Ant.PROCESS_PROC = DjVu.ProcessAnt
DjVu.Meta.PROCESS_PROC = DjVu.ProcessMeta
DjVu.Main.ANTz.SubDirectory.ProcessProc = DjVu.ProcessBZZ

return DjVu
