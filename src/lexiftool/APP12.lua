--------------------------------------------------------------------------------
-- File:         lexiftool/APP12.lua
-- Ported from:  lib/Image/ExifTool/APP12.pm
--
-- Description:  Read APP12 meta information
--
-- Revisions:    10/18/2005 - P. Harvey Created
--
-- References:   1) Heinrich Giesen private communication
--
-- Port notes:   read-path subset: Ducky and PictureInfo tables plus their
--               processors.
--------------------------------------------------------------------------------

-- Frequently used library functions as local aliases.
local tconcat = table.concat

local perl = require('lexiftool.perl')
local substr = perl.substr
local sprintf = perl.sprintf
local tsort = perl.tsort
local str = perl.str
local ucfirst = perl.ucfirst

local APP12 = {}

-- ExifTool APP12 version (mirror of $Image::ExifTool::APP12::VERSION)
APP12.VERSION = '1.15'

-- Perl IsFloat check (upstream IsFloat)
local function isFloat(v)
    return type(v) == 'number' or (type(v) == 'string' and tonumber(v) ~= nil)
end

-- Format an exposure time (upstream Exif.pm PrintExposureTime)
local function printExposureTime(secs)
    if not isFloat(secs) then return secs end
    if secs < 0.25001 and secs > 0 then
        return sprintf('1/%d', math.floor(0.5 + 1 / secs))
    end
    local s = sprintf('%.1f', secs)
    s = s:gsub('%.0$', '')
    return s
end

-- Decode a UTF-16 (big-endian) string to UTF-8 (subset: used for the ASCII
-- Ducky Comment/Copyright values; surrogate pairs are not handled)
local function decodeUTF16BE(s)
    local units = { perl.unpack('n*', s) }
    local out = {}
    for i = 1, #units do
        local u = units[i]
        if u < 0x80 then
            out[#out + 1] = string.char(u)
        elseif u < 0x800 then
            out[#out + 1] = string.char(0xC0 + u // 0x40, 0x80 + u % 0x40)
        else
            out[#out + 1] = string.char(0xE0 + u // 0x1000, 0x80 + (u // 0x40) % 0x40, 0x80 + u % 0x40)
        end
    end
    return tconcat(out)
end

-- Encode a UTF-8 string to big-endian UTF-16 (the inverse of decodeUTF16BE
-- above, for the Ducky Comment/Copyright write path).  Codepoints above
-- U+FFFF become a surrogate pair.
local function encodeUTF16BE(s)
    local out = {}
    local i = 1
    while i <= #s do
        local b = s:byte(i)
        local cp, len
        if b < 0x80 then
            cp, len = b, 1
        elseif b < 0xE0 then
            cp, len = (b & 0x1F) * 0x40 + (s:byte(i + 1) & 0x3F), 2
        elseif b < 0xF0 then
            cp, len = (b & 0x0F) * 0x1000 + (s:byte(i + 1) & 0x3F) * 0x40 + (s:byte(i + 2) & 0x3F), 3
        else
            cp, len = (b & 0x07) * 0x40000 + (s:byte(i + 1) & 0x3F) * 0x1000 + (s:byte(i + 2) & 0x3F) * 0x40 + (s:byte(i + 3) & 0x3F), 4
        end
        if cp < 0x10000 then
            out[#out + 1] = string.char(cp // 0x100, cp % 0x100)
        else
            cp = cp - 0x10000
            local hi = 0xD800 + cp // 0x400
            local lo = 0xDC00 + cp % 0x400
            out[#out + 1] = string.char(hi // 0x100, hi % 0x100, lo // 0x100, lo % 0x100)
        end
        i = i + len
    end
    return tconcat(out)
end

-- APP12 segment written in Photoshop "Save For Web" images
-- (from tests with Photoshop 7 files - PH/1)
APP12.Ducky = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    GROUPS = { [0] = 'Ducky', [1] = 'Ducky', [2] = 'Image' },
    WRITABLE = 'string',
    NOTES = [[
        Photoshop uses the JPEG APP12 "Ducky" segment to store some information in
        "Save for Web" images.
    ]],
    [1] = { --PH
        Name = 'Quality',
        Priority = 0,
        Avoid = 1,
        Writable = 'int32u',
        ValueConv = function(_self, val) return perl.unpack('N', val) end, -- 4-byte integer
        ValueConvInv = function(_self, val) return string.pack('>I4', tonumber(val)) end,
        PrintConv = function(_self, val) return perl.str(val) .. '%' end,
        -- (upstream PrintConvInv: `$val=~/(\d+)/ ? $1 : undef` -- strip the
        -- trailing '%' the PrintConv appends)
        PrintConvInv = function(_self, val) return str(val):match('(%d+)') end,
    },
    [2] = { --#1
        Name = 'Comment',
        Priority = 0,
        Avoid = 1,
        -- (ignore 4-byte character count at start of value)
        ValueConv = function(_self, val) return decodeUTF16BE(substr(val, 4)) end,
        ValueConvInv = function(_self, val)
            -- (same count rule as Copyright below)
            val = str(val)
            return string.pack('>I4', #val) .. encodeUTF16BE(val)
        end,
    },
    [3] = { --PH
        Name = 'Copyright',
        Priority = 0,
        Avoid = 1,
        Groups = { [2] = 'Author' },
        -- (ignore 4-byte character count at start of value)
        ValueConv = function(_self, val) return decodeUTF16BE(substr(val, 4)) end,
        ValueConvInv = function(_self, val)
            -- (upstream: `pack("N",length $val) . Encode($val,"UTF16","MM")`
            --  -- the count is the length of the INCOMING string, which is
            --  UTF-8 here, not the number of UTF-16 units: "(c) 2006 Phil
            --  Harvey" counts 19, not 18)
            val = str(val)
            return string.pack('>I4', #val) .. encodeUTF16BE(val)
        end,
    },
}

-- Process Ducky APP12 segment
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
function APP12.ProcessDucky(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    local pos = dirInfo.DirStart or 0
    local dirEnd = pos + dirInfo.DirLen
    et.SetByteOrder('MM')
    -- process all data blocks in Ducky segment
    while true do
        if pos + 4 > dirEnd then break end
        local tag = et.Get16u(dataPt, pos)
        local len = et.Get16u(dataPt, pos + 2)
        pos = pos + 4
        if pos + len > dirEnd then
            et:Warn('Invalid Ducky block length')
            break
        end
        local val = substr(dataPt, pos, len)
        et:HandleTag(tagTablePtr, tag, val, {
            DataPt = dataPt,
            DataPos = dirInfo.DataPos,
            Start = pos,
            Size = len,
        })
        pos = pos + len
    end
    return 1
end

-- APP12 tags (ref PH)
APP12.PictureInfo = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    GROUPS = { [0] = 'APP12', [1] = 'PictureInfo', [2] = 'Image' },
    PRIORITY = 0,
    NOTES = [[
        The JPEG APP12 "Picture Info" segment was used by some older cameras, and
        contains ASCII-based meta information.  Below are some tags which have been
        observed Agfa and Polaroid images, however ExifTool will extract information
        from any tags found in this segment.
    ]],
    FNumber = {
        ValueConv = function(_self, val) return (val:gsub('^[A-Za-z ]*', '')) end, -- Agfa leads with an 'F'
        PrintConv = function(_self, val) return sprintf('%.1f', tonumber(val)) end,
    },
    Aperture = {
        PrintConv = function(_self, val) return sprintf('%.1f', tonumber(val)) end,
    },
    TimeDate = {
        Name = 'DateTimeOriginal',
        Description = 'Date/Time Original',
        Groups = { [2] = 'Time' },
        ValueConv = function(self, val)
            return val:match('^%d+$') and self.ConvertUnixTime(val) or val
        end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    Shutter = {
        Name = 'ExposureTime',
        ValueConv = function(_self, val) return tonumber(val) * 1e-6 end,
        PrintConv = function(_self, val) return printExposureTime(val) end,
    },
    shtr = {
        Name = 'ExposureTime',
        ValueConv = function(_self, val) return tonumber(val) * 1e-6 end,
        PrintConv = function(_self, val) return printExposureTime(val) end,
    },
   ['Serial#'] = {
        Name = 'SerialNumber',
        Groups = { [2] = 'Camera' },
    },
    Flash       = { PrintConv = { [0] = 'Off', [1] = 'On' } },
    Macro       = { PrintConv = { [0] = 'Off', [1] = 'On' } },
    StrobeTime  = { },
    Ytarget     = { Name = 'YTarget' },
    ylevel      = { Name = 'YLevel' },
    FocusPos    = { },
    FocusMode   = { },
    Quality     = { },
    ExpBias     = 'ExposureCompensation',
    FWare       = 'FirmwareVersion',
    Resolution  = { },
    Protect     = { },
    ContTake    = { },
    ImageSize   = { PrintConv = function(_self, val) return val:gsub('-', 'x') end },
    ColorMode   = { },
    Zoom        = { },
    ZoomPos     = { },
    LightS      = { },
    Type        = {
        Name = 'CameraType',
        Groups = { [2] = 'Camera' },
        DataMember = 'CameraType',
        RawConv = function(self, val)
            self.CameraType = val
            return val
        end,
    },
    Version     = { Groups = { [2] = 'Camera' } },
    ID          = { Groups = { [2] = 'Camera' } },
}

-- Process APP12 Picture Info segment
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
function APP12.ProcessAPP12(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    local dirStart = dirInfo.DirStart or 0
    local dirLen = dirInfo.DirLen or (#dataPt - dirStart)
    local buff = substr(dataPt, dirStart, dirLen)
    local verbose = et.OPTIONS.Verbose
    local success = 0
    local section = ''
    -- this regular expression is a bit complex, but basically we are looking for
    -- section headers (eg. "[Camera Info]") and tag/value pairs (eg. "tag=value",
    -- where "value" may contain white space), separated by spaces or CR/LF.
    -- (APP12 uses CR/LF, but Olympus TextualInfo is similar and uses spaces)
    for token in perl.eachMatch(buff, [[(\[.*?\]|[\w#-]+=[\x20-\x7e]+?(?=\s*([\n\r\0]|[\w#-]+=|\[|$)))]]) do
        -- was this a section name?
        local bracketContent = token:match('^%[(.*)%]$')
        if bracketContent then
            if perl.truthy(verbose) then et:VerboseDir(bracketContent) end
            section = perl.matches(bracketContent, [[(?i)^(\S+) ?Info$]]) or ''
            success = 1
        else
            if perl.truthy(verbose) and success == 0 then et:VerboseDir(dirInfo.DirName) end
            success = 1
            local tag, val = perl.matches(token, [[(\S+)=(.+)]])
            local tagInfo = et:GetTagInfo(tagTablePtr, tag)
            if perl.truthy(verbose) then et:VerboseInfo(tag, tagInfo, { Value = val }) end
            if not tagInfo then
                -- add new tag to table
                tagInfo = { Name = ucfirst(tag) }
                -- put in Camera group if information in "Camera" section
                if perl.matches(section, [[(?i)camera]]) then tagInfo.Groups = { [2] = 'Camera' } end
                et:VPrint(0, et.INDENT, '[adding APP12:' .. tagInfo.Name .. ']\n')
                et:AddTagToTable(tagTablePtr, tag, tagInfo)
            end
            et:FoundTag(tagInfo, val)
        end
    end
    return success
end

--------------------------------------------------------------------------------
-- Write path (M6, Writer.t tests 11/12 slice). Port of the essential shape
-- of upstream's WriteDucky (a plain block-stream rewrite, like WriteIPTC's):
-- only the Quality tag (int32u, the only Ducky tag any vendored test
-- writes) is resolved; Comment/Copyright's UTF-16BE decode has no inverse
-- ported since nothing writes them. A tag not already present in the
-- stream is appended at the end (upstream pops candidate new tags off a
-- sorted-ascending list and processes them last-to-first, i.e. highest tag
-- number first when there's more than one -- not observable with a single
-- Quality tag, so not replicated here). Terminated with two zero bytes
-- (upstream: `$newData .= "\0\0" if length $newData`) matching the 'Ducky'
-- segments Photoshop itself writes.
-- Inputs: 0) ExifTool ref, 1) source dirInfo ref (DataPt = the raw
--            tag/len/val stream after the 'Ducky' header), 2) tag table ref
-- Returns: 1) new data block (string) if any edit actually applied ('' if no
--             entries are left), 2) nil if no pending edit touched this directory
-- Notes: this is APP12.Ducky's WRITE_PROC, so containers reach it through
--        Writer.WriteDirectory (upstream APP12.pm's `WRITE_PROC => \&WriteDucky`)
--------------------------------------------------------------------------------
function APP12.WriteDucky(et, dirInfo, _tagTablePtr)
    if not et then return 1 end    -- allow dummy access to autoload this package
    dirInfo = dirInfo or {}
    local origData = dirInfo.DataPt or ''
    if dirInfo.DirLen then
        origData = origData:sub((dirInfo.DirStart or 0) + 1,
                                (dirInfo.DirStart or 0) + dirInfo.DirLen)
    end
    local entries = {}
    local pos = 0
    local len_data = #origData
    et.SetByteOrder('MM')
    while pos + 4 <= len_data do
        local tag = et.Get16u(origData, pos)
        local len = et.Get16u(origData, pos + 2)
        pos = pos + 4
        if pos + len > len_data then break end
        local val = origData:sub(pos + 1, pos + len)
        pos = pos + len
        entries[#entries + 1] = { tag = tag, val = val }
    end

    -- collect the pending Ducky edits from the tagInfo-keyed NEW_VALUE store
    local editList = {}
    if et.NEW_VALUE then
        for tagInfo, nvHash in pairs(et.NEW_VALUE) do
            if tagInfo.Table == APP12.Ducky then
                local h = nvHash
                while h do
                    editList[#editList + 1] = h
                    h = h.Next
                end
            end
        end
    end
    -- upstream pops candidate new tags off a sorted-ascending list and
    -- processes them last-to-first (highest tag number first), so new Ducky
    -- entries are emitted in descending tag-number order; same-tag list
    -- entries keep their SetNewValue order
    tsort(editList, function(a, b)
        local ta = a.TagInfo and a.TagInfo.TagID or 0
        local tb = b.TagInfo and b.TagInfo.TagID or 0
        if ta ~= tb then return ta > tb end
        return (a.Order or 0) < (b.Order or 0)
    end)

    local changed = false
    for _, nvHash in ipairs(editList) do
        local tagInfo = nvHash.TagInfo
        local tid = tagInfo.TagID
        -- Quality (1) and Copyright (3) are writable; Ducky:Comment (2,
        -- Avoid=1) is deferred (its bare name collides with the COM-segment
        -- Comment, resolved by upstream's priority mechanism, not ported yet)
        if tid ~= 1 and tid ~= 3 then
            goto continueDucky
        end
        -- (the value arrives converted to the raw stored bytes: SetNewValue
        --  has run ConvInv on it -- Quality: '84%' -> 4-byte big-endian int,
        --  Copyright: -> UTF-16BE with a 4-byte character count)
        local value = et:GetNewValue(nvHash)
        local delValue = nvHash.DelValue and #nvHash.DelValue > 0
        local found = false
        for i = 1, #entries do
            if entries[i].tag == tid then
                found = true
                if value == nil or delValue then
                    table.remove(entries, i)
                else
                    entries[i].val = value
                end
                changed = true
                break
            end
        end
        -- only CREATE a new Ducky segment entry when this tag is preferred
        -- (IsCreating): a bare "Quality"/"Copyright" also matches tags in
        -- other tables, and the Ducky copy is Avoid=1/lower priority so must
        -- not be created
        if not found and value ~= nil and not delValue and nvHash.IsCreating and nvHash.IsCreating ~= 0 then
            entries[#entries + 1] = { tag = tid, val = value }
            changed = true
        end
        ::continueDucky::
    end

    if not changed then return nil end
    et.CHANGED = (et.CHANGED or 0) + 1
    if #entries == 0 then return '' end   -- (no entries left: empty directory)

    local parts = {}
    for _, ent in ipairs(entries) do
        parts[#parts + 1] = et.Put16u(ent.tag) .. et.Put16u(#ent.val) .. ent.val
    end
    return table.concat(parts) .. '\0\0'
end

-- (PROCESS_PROC is set here so the Ducky/PictureInfo tables can reference
--  their processors, which are defined after the tables in this file)
APP12.Ducky.PROCESS_PROC = APP12.ProcessDucky
APP12.PictureInfo.PROCESS_PROC = APP12.ProcessAPP12

-- (WRITE_PROC is set here so the Ducky table can reference WriteDucky, which
-- is defined further down; upstream has it inline in the table)
APP12.Ducky.WRITE_PROC = APP12.WriteDucky

return APP12
