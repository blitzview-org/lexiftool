--------------------------------------------------------------------------------
-- File:         lexiftool/PostScript.lua
-- Ported from:  lib/Image/ExifTool/PostScript.pm
--
-- Description:  Read PostScript meta information
--
-- Revisions:    07/08/2005 - P. Harvey Created
--
-- References:   1) http://partners.adobe.com/public/developer/en/ps/5002.EPSF_Spec.pdf
--               2) http://partners.adobe.com/public/developer/en/ps/5001.DSC_Spec.pdf
--               3) http://partners.adobe.com/public/developer/en/illustrator/sdk/AI7FileFormat.pdf
--
-- Port notes:   Complete port of PostScript.pm: every table and sub, in
--               upstream order (DOS binary EPS header with TIFF preview,
--               PFA/PFB font info, %AI12_CompressedData inflate, embedded
--               documents with ExtractEmbedded).  Perl's dynamically scoped
--               `$/` is the module field PostScript.RS, saved and restored
--               by ProcessPS (and WritePS) like `local $/`.  A Lua string is
--               a value, so CheckPSEnd returns the shortened data and
--               DecodeComment returns the extra data as second result.
--               GetNextLine has no Windows long-line patch (it applies to
--               Windows Perl only).  The write-include
--               WritePostScript.pl is lexiftool/WritePostScript.lua; its
--               subs are bound here as AUTOLOAD closures (at the
--               predeclaration of WritePS).
--------------------------------------------------------------------------------

local PostScript = {}
local ExifTool = require('lexiftool')
local perl = require('lexiftool.perl')
local substr = perl.substr
local matches = perl.matches
local isMatch = perl.isMatch
local subst = perl.subst
local tr = perl.tr
local pack = perl.pack
local length = perl.length
local truthy = perl.truthy
local Get32u = ExifTool.Get32u
local SetByteOrder = ExifTool.SetByteOrder
local GetTagTable = ExifTool.GetTagTable

-- (Perl's input record separator `$/`, which ProcessPS and WritePS set with
--  `local` and GetNextLine reads; "\n" is Perl's default.  A module field, so
--  that WritePostScript.lua sets the same one)
PostScript.RS = "\n"

-- (upstream's predeclaration `sub WritePS($$);`: WritePS is a sub of
--  WritePostScript.pl, which upstream AUTOLOADs -- DoAutoLoad loads it on the
--  first call.  Here every sub of WritePostScript.pl is bound to a closure
--  that loads WritePostScript.lua on first use)
for _, name in ipairs({ 'WriteXMPDir', 'WritePSDirectory', 'EncodeTag', 'WriteNewTags', 'WritePS' }) do
    PostScript[name] = function(...) return require('lexiftool.WritePostScript')[name](...) end
end

-- PostScript tag table (upstream %Image::ExifTool::PostScript::Main)
PostScript.Main = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    WRITE_PROC = PostScript.WritePS,
    PREFERRED = 1, -- always add these tags when writing
    GROUPS = { [2] = 'Image' },
    -- Note: Make all of these tags priority 0 since the first one found at
    -- the start of the file should take priority (in case multiples exist)
    Author = { Priority = 0, Groups = { [2] = 'Author' }, Writable = 'string' },
    BoundingBox = { Priority = 0 },
    Copyright = { Priority = 0, Writable = 'string' }, --2
    CreationDate = {
        Name = 'CreateDate',
        Priority = 0,
        Groups = { [2] = 'Time' },
        Writable = 'string',
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
        PrintConvInv = function(self, val) return self:InverseDateTime(val) end,
    },
    Creator     = { Priority = 0, Writable = 'string' },
    ImageData   = { Priority = 0 },
    For         = { Priority = 0, Writable = 'string', Notes = 'for whom the document was prepared'},
    Keywords    = { Priority = 0, Writable = 'string' },
    ModDate = {
        Name = 'ModifyDate',
        Priority = 0,
        Groups = { [2] = 'Time' },
        Writable = 'string',
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
        PrintConvInv = function(self, val) return self:InverseDateTime(val) end,
    },
    Pages = { Priority = 0 },
    Routing = { Priority = 0, Writable = 'string' }, --2
    Subject = { Priority = 0, Writable = 'string' },
    Title = { Priority = 0, Writable = 'string' },
    Version = { Priority = 0, Writable = 'string' }, --2
    -- these subdirectories for documentation only
    BeginPhotoshop = {
        Name = 'PhotoshopData',
        SubDirectory = { TagTable = 'lexiftool.Photoshop.Main' },
    },
    BeginICCProfile = {
        Name = 'ICC_Profile',
        SubDirectory = { TagTable = 'lexiftool.ICC_Profile.Main' },
    },
    begin_xml_packet = {
        Name = 'XMP',
        SubDirectory = { TagTable = 'lexiftool.XMP.Main' },
    },
    TIFFPreview = {
        Groups = { [2] = 'Preview' },
        Binary = 1,
        Notes = [[
            not a real tag ID, but used to represent the TIFF preview extracted from DOS
            EPS images
        ]],
    },
    BeginDocument = {
        Name = 'EmbeddedFile',
        SubDirectory = {
            TagTable = 'lexiftool.PostScript.Main',
        },
        Notes = 'extracted with L<ExtractEmbedded|../ExifTool.html#ExtractEmbedded> option',
    },
    EmbeddedFileName = {
        Notes = [[
            not a real tag ID, but the file name from a BeginDocument statement.
            Extracted with document metadata when L<ExtractEmbedded|../ExifTool.html#ExtractEmbedded> option is used
        ]],
    },
    -- AI metadata (most with a single leading '%')
    AI9_ColorModel = {
        Name = 'AIColorModel',
        PrintConv = { [1] = 'RGB', [2] = 'CMYK' },
    },
    AI3_ColorUsage = { Name = 'AIColorUsage' },
    AI5_RulerUnits = {
        Name = 'AIRulerUnits',
        PrintConv = {
            [0] = 'Inches',
            [1] = 'Millimeters',
            [2] = 'Points',
            [3] = 'Picas',
            [4] = 'Centimeters',
            [6] = 'Pixels',
        },
    },
    AI5_TargetResolution = { Name = 'AITargetResolution' },
    AI5_NumLayers = { Name = 'AINumLayers' },
    AI5_FileFormat = { Name = 'AIFileFormat' },
    AI8_CreatorVersion = { Name = 'AICreatorVersion' }, -- (double leading '%')
    AI12_BuildNumber = { Name = 'AIBuildNumber' },
}

--------------------------------------------------------------------------------
-- AutoLoad our writer routines when necessary
--
-- (upstream AUTOLOAD/DoAutoLoad loads WritePostScript.pl -- its subs are bound
--  to loader closures at their predeclaration position at the top of this file)

--------------------------------------------------------------------------------
-- Get image width or height
-- Inputs: 0) value list ref (ImageData, BoundingBox), 1) true to get height
local function ImageSize(vals, getHeight)
    local w, h
    local isA, a1, a2 = false, nil, nil
    if truthy(vals[0]) then isA, a1, a2 = isMatch(vals[0], [[^(\d+) (\d+)]]) end
    if isA then
        w, h = perl.num(a1), perl.num(a2)
    else
        local isB, b1, b2, b3, b4 = false, nil, nil, nil, nil
        if truthy(vals[1]) then isB, b1, b2, b3, b4 = isMatch(vals[1], [[^(\d+) (\d+) (\d+) (\d+)]]) end
        if isB then w, h = b3 - b1, b4 - b2 end
    end
    if getHeight then return h end
    return w
end
PostScript.ImageSize = ImageSize

-- composite tags (upstream %Image::ExifTool::PostScript::Composite)
PostScript.Composite = {
    GROUPS = { [0] = 'Composite', [1] = 'Composite', [2] = 'Image' },
    -- BoundingBox is in points, not pixels,
    -- but use it anyway if ImageData is not available
    ImageWidth = {
        TagID = 'PostScript-ImageWidth', -- (disambiguates from Exif::Composite::ImageWidth)
        Desire = { [0] = 'Main:PostScript:ImageData', [1] = 'PostScript:BoundingBox' },
        ValueConv = function(_self, val) return ImageSize(val, false) end,
    },
    ImageHeight = {
        TagID = 'PostScript-ImageHeight', -- (disambiguates from Exif::Composite::ImageHeight)
        Desire = { [0] = 'Main:PostScript:ImageData', [1] = 'PostScript:BoundingBox' },
        ValueConv = function(_self, val) return ImageSize(val, true) end,
    },
}

-- add our composite tags
ExifTool.AddCompositeTags('lexiftool.PostScript', nil, PostScript)

--------------------------------------------------------------------------------
-- Set PostScript format error warning
-- Inputs: 0) ExifTool object reference, 1) error string
-- Returns: 1
local function PSErr(et, str)
    -- set file type if not done already
    local ext = et.FILE_EXT
    et:SetFileType((ext and ext == 'AI') and 'AI' or 'PS')
    et:Warn("PostScript format error (" .. str .. ")")
    return 1
end
PostScript.PSErr = PSErr

--------------------------------------------------------------------------------
-- Return input record separator to use for the specified file
-- Inputs: 0) RAF reference
-- Returns: Input record separator or undef on error
function PostScript.GetInputRecordSeparator(raf)
    local pos = raf:Tell()  -- save current position
    local n, data, sep
    n, data = raf:Read(256)
    if not truthy(n) then return nil end
    local a, d = 999, 999
    -- (pos($data) after the /g match: the 0-based end offset of the match)
    local _, en = matches(data, [[\x0a]])
    if en then a = en end
    _, en = matches(data, [[\x0d]])
    if en then d = en end
    local diff = a - d
    if diff == 1 then
        sep = "\x0d\x0a"
    elseif diff == -1 then
        sep = "\x0a\x0d"
    elseif diff > 0 then
        sep = "\x0d"
    elseif diff < 0 then
        sep = "\x0a"
    end -- else error
    raf:Seek(pos, 0)    -- restore original position
    return sep
end

--------------------------------------------------------------------------------
-- Split into lines ending in any CR, LF or CR+LF combination
-- (this is annoying, and could be avoided if EPS files didn't mix linefeeds!)
-- Inputs: 0) data pointer, 1) reference to lines array
-- Notes: Fills @$lines with lines from splitting $$dataPt
function PostScript.SplitLine(data, lines)
    while true do
        local endl
        -- find the position of the first LF (\x0a)
        local _, e = matches(data, [[\x0a]])
        if e then endl = e end
        local _, e2 = matches(data, [[\x0d]])
        if e2 then -- find the first CR (\x0d)
            if endl ~= nil then
                -- (remember, CR+LF is a DOS newline...)
                if e2 < endl - 1 then endl = e2 end
            else
                endl = e2
            end
        elseif endl == nil then
            lines[#lines + 1] = data
            break
        end
        if length(data) == endl then
            lines[#lines + 1] = data
            break
        else
            -- continue to split into separate lines
            lines[#lines + 1] = substr(data, 0, endl)
            data = substr(data, endl)
        end
    end
end

--------------------------------------------------------------------------------
-- check to be sure we haven't read past end of PS data in DOS-style file
-- Inputs: 0) RAF ref (with PSEnd member), 1) data ref
-- - modifies data and sets RAF to EOF if end of PS is reached
-- (Lua: returns the data)
function PostScript.CheckPSEnd(raf, data)
    local pos = raf:Tell()
    if pos >= raf.PSEnd then
        raf:Seek(0, 2)  -- seek to end of file so we can't read any more
        if pos > raf.PSEnd then data = substr(data, 0, length(data) - pos + raf.PSEnd) end
    end
    return data
end

--------------------------------------------------------------------------------
-- Read next line from EPS file
-- Inputs: 0) RAF ref (with PSEnd member if Postscript ends before end of file)
--         1) array of lines from file
-- Returns: true on success
-- (the patch for the Windows memory problem with very long lines applies only
--  to Windows Perl, IsPC() -- not a concern of this port)
function PostScript.GetNextLine(raf, lines)
    local data, n
    local altnl = (PostScript.RS == "\x0d") and "\x0a" or "\x0d"
    while true do -- luacheck: ignore 512
        n, data = raf:ReadLine(PostScript.RS)
        if not truthy(n) then break end
        if truthy(raf.PSEnd) then data = PostScript.CheckPSEnd(raf, data) end
        -- split line if it contains other newline sequences
        if perl.isMatchDyn(data, altnl) then
                -- split into separate lines
            --    push @$lines, split /$altnl/, $data, -1;
            --    if (@$lines == 2 and $$lines[1] eq $/) {
            --        # handle case of DOS newline data inside file using Unix newlines
            --        $$lines[0] .= pop @$lines;
            --    }
            -- split into separate lines if necessary
           PostScript.SplitLine(data, lines)
        else
            lines[#lines + 1] = data
        end
        return 1
    end
    return 0
end

--------------------------------------------------------------------------------
-- Decode comment from PostScript file
-- Inputs: 0) comment string, 1) RAF ref, 2) reference to lines array
--         3) optional data reference for extra lines read from file
-- Returns: Decoded comment string (may be an array reference)
-- - handles multi-line comments and escape sequences
-- (Lua: the extra data is returned as second result when dataPt is given)
function PostScript.DecodeComment(val, raf, lines, dataPt)
    val = subst(val, [[\x0d*\x0a*$]], '')   -- remove trailing CR, LF or CR/LF
    -- check for continuation comments
    while true do
        if #lines == 0 and not truthy(PostScript.GetNextLine(raf, lines)) then break end
        if not isMatch(lines[1], '^%%\\+') then break end -- is the next line a continuation?
        if dataPt then dataPt = dataPt .. lines[1] end  -- add to data if necessary
        lines[1] = subst(lines[1], [[\x0d*\x0a*$]], '')     -- remove trailing CR, LF or CR/LF
        val = val .. substr(table.remove(lines, 1), 3)  -- add to value (without leading "%%+")
    end
    local vals = {}
    -- handle bracketed string values
    if isMatch(val, [[^\((.*)\)$]]) then -- remove brackets if necessary
        val = subst(val, [[^\((.*)\)$]], '$1')
        -- split into an array of strings if necessary
        local nesting = 1
        local gpos = 0
        while true do
            local bra, e = matches(val, [[(\(|\))]], gpos)
            if bra == nil then break end
            gpos = e
            local pos = gpos - 2
            local backslashes = 0
            while pos ~= 0 and substr(val, pos, 1) == '\\' do
                pos = pos - 1
                backslashes = backslashes + 1
            end
            if backslashes & 0x01 == 0 then -- escaped if odd number
                if bra == '(' then
                    nesting = nesting + 1
                else
                    nesting = nesting - 1
                    if nesting == 0 then
                        vals[#vals + 1] = substr(val, 0, gpos - 1)
                        val = substr(val, gpos)
                        gpos = 0
                        if isMatch(val, [[^\s*\(]]) then
                            val = subst(val, [[\s*\(]], '')
                            nesting = nesting + 1
                        end
                    end
                end
            end
        end
        vals[#vals + 1] = val
        for i, v in ipairs(vals) do
            -- decode escape sequences in bracketed strings
            -- (similar to code in PDF.pm, but without line continuation)
            local gp = 0
            while true do
                local c, e = matches(v, [[(?s)\\(.)]], gp)
                if c == nil then break end
                local n = e - 2
                local r
                if isMatch(c, '[0-7]') then
                    -- get up to 2 more octal digits
                    local more = matches(v, [[\G([0-7]{1,2})]], e)
                    if more ~= nil then c = c .. more end
                    -- convert octal escape code
                    r = perl.chr(perl.oct(c) & 0xff)
                else
                    -- convert escaped characters
                    r = tr(c, 'nrtbf', '\n\r\t\b\f')
                end
                v = substr(v, 0, n) .. r .. substr(v, n + length(c) + 1)
                -- continue search after this character
                gp = n + length(r)
            end
            vals[i] = v
        end
        if #vals > 1 then val = vals else val = vals[1] end
    end
    return val, dataPt
end

--------------------------------------------------------------------------------
-- Unescape PostScript string
-- Inputs: 0) string
-- Returns: unescaped string
function PostScript.UnescapePostScript(str)
    -- decode escape sequences in literal strings
    local gp = 0
    while true do
        local c, e = matches(str, [[(?s)\\(.)]], gp)
        if c == nil then break end
        local n = e - 2
        local r
        if isMatch(c, '[0-7]') then
            -- get up to 2 more octal digits
            local more = matches(str, [[\G([0-7]{1,2})]], e)
            if more ~= nil then c = c .. more end
            -- convert octal escape code
            r = perl.chr(perl.oct(c) & 0xff)
        elseif c == "\x0d" then
            -- the string is continued if the line ends with '\'
            -- (also remove "\x0d\x0a")
            local more = matches(str, [[\G(\x0a)]], e)
            if more ~= nil then c = c .. more end
            r = ''
        elseif c == "\x0a" then
            r = ''
        else
            -- convert escaped characters
            r = tr(c, 'nrtbf', '\n\r\t\b\f')
        end
        str = substr(str, 0, n) .. r .. substr(str, n + length(c) + 1)
        -- continue search after this character
        gp = n + length(r)
    end
    return str
end

--------------------------------------------------------------------------------
-- Extract information from EPS, PS or AI file
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference, 2) optional tag table ref
-- Returns: 1 if this was a valid PostScript file
function PostScript.ProcessPS(et, dirInfo, tagTablePtr)
    local raf = dirInfo.RAF
    local embedded = et:Options('ExtractEmbedded')
    local data, dos, endDoc, fontTable, comment, n

    -- allow read from data
    if not raf then
        raf = require('lexiftool.RandomAccess').new(dirInfo.DataPt)
        et:VerboseDir('PostScript')
    end
--
-- determine if this is a postscript file
--
    n, data = raf:Read(4)
    if n ~= 4 then return 0 end
    -- accept either ASCII or DOS binary postscript file format
    if not isMatch(data, [[^(%!PS|%!Ad|%!Fo|\xc5\xd0\xd3\xc6)]]) then return 0 end
    if isMatch(data, '^%!Ad') then
        -- I've seen PS files start with "%!Adobe-PS"...
        n, data = raf:Read(6)
        if not (n == 6 and data == "obe-PS") then return 0 end
    elseif isMatch(data, [[^\xc5\xd0\xd3\xc6]]) then
        -- process DOS binary file header
        -- - save DOS header then seek ahead and check PS header
        n, dos = raf:Read(26)
        if n ~= 26 then return 0 end
        SetByteOrder('II')
        local psStart = Get32u(dos, 0)
        local ok = false
        if raf:Seek(psStart, 0) then
            n, data = raf:Read(4)
            ok = n == 4 and data == '%!PS'
        end
        if not ok then
            return PSErr(et, 'invalid header')
        end
        raf.PSEnd = psStart + Get32u(dos, 4)    -- set end of PostScript data in RAF
    else
        -- check for PostScript font file (PFA or PFB)
        local n2, d2 = raf:Read(12)
        if truthy(n2) then data = data .. d2 end
        if isMatch(data, '^%!(PS-(AdobeFont-|Bitstream )|FontType1-)') then
            et:SetFileType('PFA')   -- PostScript ASCII font file
            fontTable = GetTagTable(nil, 'lexiftool.Font.PSInfo')
            -- PostScript font files may contain an unformatted comments which may
            -- contain useful information, so accumulate these for the Comment tag
            comment = 1
        end
        raf:Seek(-length(data), 1)
    end
--
-- set the newline type based on the first newline found in the file
--
    local oldRS = PostScript.RS        -- (local $/)
    PostScript.RS = PostScript.GetInputRecordSeparator(raf)
    if not truthy(PostScript.RS) then PostScript.RS = oldRS return PSErr(et, 'invalid PS data') end

    -- set file type (PostScript or EPS)
    n, data = raf:ReadLine(PostScript.RS)
    if not truthy(n) then data = '' end
    local type_
    if isMatch(data, 'EPSF') then
        type_ = 'EPS'
    else
        -- read next line to see if this is an Illustrator file
        local line2
        local pos = raf:Tell()
        n, line2 = raf:ReadLine(PostScript.RS)
        if truthy(n) and isMatch(line2, '^%%Creator: Adobe Illustrator') then
            type_ = 'AI'
        else
            type_ = 'PS'
        end
        raf:Seek(pos, 0)
    end
    et:SetFileType(type_)
    if perl.truthy(et.OPTIONS.FastScan) and perl.num(et.OPTIONS.FastScan) == 3 then PostScript.RS = oldRS return 1 end
--
-- extract TIFF information from DOS header
--
    if not tagTablePtr then tagTablePtr = GetTagTable(nil, 'lexiftool.PostScript.Main') end
    if dos then
        local base = Get32u(dos, 16)
        if base ~= 0 then
            local pos = raf:Tell()
            -- extract the TIFF preview
            local len = Get32u(dos, 20)
            local val = et:ExtractBinary(base, len, 'TIFFPreview')
            if val ~= nil and isMatch(val, [[^(MM\0\x2a|II\x2a\0|Binary)]]) then
                et:HandleTag(tagTablePtr, 'TIFFPreview', val)
            else
                et:Warn('Bad TIFF preview image')
            end
            -- extract information from TIFF in DOS header
            -- (set Parent to '' to avoid setting FileType tag again)
            local dirInfo2 = {
                Parent = '',
                RAF = raf,
                Base = base,
            }
            if not truthy(et:ProcessTIFF(dirInfo2)) then et:Warn('Bad embedded TIFF') end
            -- position file pointer to extract PS information
            raf:Seek(pos, 0)
        end
    end
--
-- parse the postscript
--
    local buff, mode, beginToken, endToken, docNum, subDocNum
    local lines, altnl = {}
    if PostScript.RS == "\x0d" then
        altnl = "\x0a"
    else
        PostScript.RS = "\x0a"     -- end on any LF (even if DOS CR+LF)
        altnl = "\x0d"
    end
    while true do
        if #lines > 0 then
            data = table.remove(lines, 1)
        else
            n, data = raf:ReadLine(PostScript.RS)
            if not truthy(n) then break end
            -- check for alternate newlines as efficiently as possible
            if perl.isMatchDyn(data, altnl) then
                -- (the Windows long-line patch applies only on IsPC())
                -- split into separate lines
                lines = perl.splitDyn(altnl, data, -1)
                data = table.remove(lines, 1)
                if #lines == 1 and lines[1] == PostScript.RS then
                    -- handle case of DOS newline data inside file using Unix newlines
                    data = data .. lines[1]
                    lines = {}
                end
            end
        end
        if mode then
            if not endToken then
                buff = buff .. data
                if not isMatch(data, [[<\?xpacket end=.(w|r).\?>(\n|\r|$)]]) then goto next_ end
            elseif not perl.isMatchDyn(data, '(?i)^' .. endToken) then
                if mode == 'XMP' then
                    buff = buff .. data
                elseif mode == 'Document' then
                    -- ignore embedded documents, but keep track of nesting level
                    if perl.isMatchDyn(data, '^' .. beginToken) then docNum = docNum .. '-1' end
                else
                    -- data is ASCII-hex encoded
                    data = tr(data, '0-9A-Fa-f', '', 'dc')  -- remove all but hex characters
                    buff = buff .. pack('H*', data) -- translate from hex
                end
                goto next_
            elseif mode == 'Document' then
                docNum = subst(perl.str(docNum), [[-?\d+$]], '')   -- decrement document nesting level
                -- done with Document mode if we are back at the top level
                if not truthy(docNum) then mode = nil end
                goto next_
            end
        elseif endDoc and perl.isMatchDyn(data, '(?i)^' .. endDoc) then
            local isD, d1 = isMatch(perl.str(docNum), [[-?(\d+)$]])
            docNum = subst(perl.str(docNum), [[-?(\d+)$]], '')     -- decrement nesting level
            if isD then subDocNum = perl.num(d1) end    -- remember our last sub-document number
            et.DOC_NUM = docNum
            if not truthy(docNum) then endDoc = nil end -- done with document if top level
            goto next_
        else
            local isBegin, b1, b2, b3 = isMatch(data, [[(?i)^(%{1,2})(Begin)(_xml_packet|Photoshop|ICCProfile|Document|Binary)]])
            if isBegin then
                -- the beginning of a data block
                local modeLookup = {
                    _xml_packet = 'XMP',
                    photoshop   = 'Photoshop',
                    iccprofile  = 'ICC_Profile',
                    document    = 'Document',
                    binary      = nil, -- (we will try to skip this)
                }
                mode = modeLookup[perl.lc(b3)]
                if not mode then
                    local isBin, len
                    if #lines == 0 then isBin, len = isMatch(data, [[(?i)^%{1,2}BeginBinary:\s*(\d+)]]) end
                    if isBin then
                        if not raf:Seek(perl.num(len), 1) then break end -- skip binary data
                    end
                    goto next_
                end
                buff = ''
                beginToken = b1 .. b2 .. b3
                endToken = b1 .. (b2 == 'begin' and 'end' or 'End') .. b3
                if mode == 'Document' then
                    -- this is either the 1st sub-document or Nth document
                    if truthy(docNum) then
                        -- increase nesting level
                        subDocNum = (subDocNum or 0) + 1
                        docNum = docNum .. '-' .. subDocNum
                    else
                        -- this is the Nth document
                        docNum = (et.DOC_COUNT or 0) + 1
                    end
                    subDocNum = 0   -- new level, so reset subDocNum
                    if not truthy(embedded) then goto next_ end -- skip over this document
                    -- set document number for family 4-7 group names
                    et.DOC_NUM = docNum
                    et.LIST_TAGS = { }  -- don't build lists across different documents
                    et.PROCESSED = { }  -- re-initialize processed directory lookup too
                    endDoc = endToken           -- parse to EndDocument token
                    -- reset mode to allow parsing into sub-directories
                    endToken = nil
                    mode = nil
                    -- save document name if available
                    local isN, docName = perl.isMatchDyn(data, '(?i)^' .. beginToken .. [[:\s+([^\n\r]+)]])
                    if isN then
                        -- remove brackets if necessary
                        local isBr, inner = isMatch(docName, [[^\((.*)\)$]])
                        if isBr then docName = inner end
                        et:HandleTag(tagTablePtr, 'EmbeddedFileName', docName)
                    end
                end
                goto next_
            elseif isMatch(data, [[^<\?xpacket begin=.{7,13}W5M0MpCehiHzreSzNTczkc9d]]) then
                -- pick up any stray XMP data
                mode = 'XMP'
                buff = data
                endToken = nil  -- no end token (just look for xpacket end)
                -- XMP could be contained in a single line (if newlines are different)
                if not isMatch(data, [[<\?xpacket end=.(w|r).\?>(\n|\r|$)]]) then goto next_ end
            else
                local isTag, tag, val = isMatch(data, [[(?s)^%%?(\w+): ?(.*)]])
                if isTag and tagTablePtr[tag] then
                    -- only allow 'ImageData' and AI tags to have single leading '%'
                    if not (isMatch(data, [[^%(%|AI\d+_)]]) or tag == 'ImageData') then goto next_ end
                    -- decode comment string (reading continuation lines if necessary)
                    val = PostScript.DecodeComment(val, raf, lines)
                    et:HandleTag(tagTablePtr, tag, val)
                    goto next_
                elseif truthy(embedded) and isMatch(data, '^%AI12_CompressedData') then
                    -- the rest of the file is compressed
                    if not ExifTool.hasZlib() then   -- (`eval { require Compress::Zlib }`)
                        et:Warn('Install Compress::Zlib to extract compressed embedded data')
                        break
                    end
                    -- seek back to find the start of the compressed data in the file
                    local tlen = length(data) + #lines
                    for _, l in ipairs(lines) do tlen = tlen + length(l) end
                    local backTo = raf:Tell() - tlen - 64
                    if backTo < 0 then backTo = 0 end
                    if not raf:Seek(backTo, 0) then break end
                    n, data = raf:Read(2048)
                    if not truthy(n) then break end
                    if not isMatch(data, '.*?%AI12_CompressedData') then break end
                    data = subst(data, '.*?%AI12_CompressedData', '')
                    local inflate = ExifTool.inflateInit()
                    if not inflate then et:Warn('Error initializing inflate') break end
                    -- generate a PS-like file in memory from the compressed data
                    local verbose = et:Options('Verbose')
                    if perl.num(verbose) > 1 then
                        et:VerboseDir('AI12_CompressedData (first 4kB)')
                        et:VerboseDump(data)
                    end
                    -- remove header if it exists (Windows AI files only)
                    data = subst(data, [[(?s)^.{0,256}EndData[\x0d\x0a]+]], '')
                    local val2
                    while true do
                        local v2, stat = inflate:inflate(data)
                        if stat == ExifTool.Z_STREAM_END then val2 = (val2 or '') .. v2 break end
                        if stat ~= ExifTool.Z_OK then val2 = nil break end
                        if val2 ~= nil then
                            val2 = val2 .. v2
                        elseif isMatch(v2, '^%!PS') then
                            val2 = v2
                        else
                            -- add postscript header (for file recognition) if it doesn't exist
                            val2 = "%!PS-Adobe-3.0" .. PostScript.RS .. v2
                        end
                        n, data = raf:Read(65536)
                        if not truthy(n) then break end
                    end
                    if val2 == nil then et:Warn('Error inflating AI compressed data') break end
                    if perl.num(verbose) > 1 then
                        et:VerboseDir('Uncompressed AI12 Data')
                        et:VerboseDump(val2)
                    end
                    -- extract information from embedded images in the uncompressed data
                    PostScript.ProcessPS(et, { DataPt = val2 })
                    break
                elseif fontTable then
                    if comment ~= nil then
                        -- extract initial comments from PostScript Font files
                        local isC, c1 = isMatch(data, [=[^%\s+(.*?)[\x0d\x0a]]=])
                        if isC then
                            if truthy(comment) then comment = perl.str(comment) .. "\n" end
                            comment = perl.str(comment) .. c1
                            goto next_
                        elseif not isMatch(data, '^%') then
                            -- stop extracting comments at the first non-comment line
                            if truthy(length(comment)) then et:FoundTag('Comment', comment) end
                            comment = nil
                        end
                    end
                    local isF, ftag, fval = isMatch(data, [[^\s*/(\w+)\s*(.*)]])
                    if isF and fontTable[ftag] then
                        local isP, p1 = isMatch(fval, [[^\((.*)\)]])
                        if isP then
                            fval = PostScript.UnescapePostScript(p1)
                        else
                            local isS, s1 = isMatch(fval, [[/?(\S+)]])
                            if isS then fval = s1 end
                        end
                        et:HandleTag(fontTable, ftag, fval)
                    elseif isMatch(data, '^currentdict end') then
                        -- only extract tags from initial FontInfo dict
                        fontTable = nil
                    end
                    goto next_
                else
                    goto next_
                end
            end
        end
        do
            -- extract information from buffered data
            local dirInfo2 = {
                DataPt = buff,
                DataLen = length(buff),
                DirStart = 0,
                DirLen = length(buff),
                Parent = 'PostScript',
            }
            local subTablePtr = GetTagTable(nil, "lexiftool." .. mode .. ".Main")
            if not truthy(et:ProcessDirectory(dirInfo2, subTablePtr)) then
                et:Warn("Error processing " .. mode .. " information in PostScript file")
            end
            buff = nil
            mode = nil
        end
        ::next_::
    end
    if endDoc and not mode then mode = 'Document' end
    if mode then PSErr(et, "unterminated " .. mode .. " data") end
    PostScript.RS = oldRS
    return 1
end

--------------------------------------------------------------------------------
-- Extract information from EPS file
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference
-- Returns: 1 if this was a valid PostScript file
function PostScript.ProcessEPS(et, dirInfo)
    return PostScript.ProcessPS(et, dirInfo)
end

-- (PROCESS_PROC is set here so the table can reference the function above;
--  upstream has it inline in the table)
PostScript.Main.PROCESS_PROC = PostScript.ProcessPS

return PostScript -- end
