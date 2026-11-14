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
-- Port notes:   Complete port of APP12.pm: the PictureInfo and Ducky tables
--               and WriteDucky, ProcessDucky and ProcessAPP12, line for
--               line.  Perl's `for (;;)` loops are `while true` loops, `next`
--               a goto to the label at the end of the loop body.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local perl = require('lexiftool.perl')
local perlTruthy = ExifTool.perlTruthy
local SetByteOrder = ExifTool.SetByteOrder
local Get16u = ExifTool.Get16u
local AddTagToTable = ExifTool.AddTagToTable
local isMatch, matches, eachMatch, subst = perl.isMatch, perl.matches, perl.eachMatch, perl.subst
local substr = perl.substr
local length = perl.length
local sprintf = perl.sprintf
local perlStr = perl.str
local unpack, pack = perl.unpack, perl.pack
local tr = perl.tr
local ucfirst = perl.ucfirst
local keys, sort = perl.keys, perl.sort
-- (Writer.pl's routines, loaded on first use like upstream's AUTOLOAD)
local function Writer() return require('lexiftool.Writer') end

local APP12 = {}

-- ExifTool APP12 version (mirror of $Image::ExifTool::APP12::VERSION)
APP12.VERSION = '1.15'

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
        ValueConv = function(_self, val) val = subst(val, [[^[A-Za-z ]*]], '') return val end, -- Agfa leads with an 'F'
        PrintConv = function(_self, val) return sprintf('%.1f', val) end,
    },
    Aperture = {
        PrintConv = function(_self, val) return sprintf('%.1f', val) end,
    },
    TimeDate = {
        Name = 'DateTimeOriginal',
        Description = 'Date/Time Original',
        Groups = { [2] = 'Time' },
        ValueConv = function(_self, val)
            if isMatch(val, [[^\d+$]]) then return ExifTool.ConvertUnixTime(val) else return val end
        end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    Shutter = {
        Name = 'ExposureTime',
        ValueConv = function(_self, val) return perl.num(val, '*') * 1e-6 end,
        PrintConv = function(_self, val) return require('lexiftool.Exif').PrintExposureTime(val) end,
    },
    shtr = {
        Name = 'ExposureTime',
        ValueConv = function(_self, val) return perl.num(val, '*') * 1e-6 end,
        PrintConv = function(_self, val) return require('lexiftool.Exif').PrintExposureTime(val) end,
    },
   ['Serial#']    = {
        Name = 'SerialNumber',
        Groups = { [2] = 'Camera' },
    },
    Flash       = { PrintConv = { [0] = 'Off', [1] = 'On' } },
    Macro       = { PrintConv = { [0] = 'Off', [1] = 'On' } },
    -- luacheck: push ignore 314 (upstream repeats the StrobeTime key)
    StrobeTime  = { },
    Ytarget     = { Name = 'YTarget' },
    ylevel      = { Name = 'YLevel' },
    FocusPos    = { },
    FocusMode   = { },
    Quality     = { },
    ExpBias     = 'ExposureCompensation',
    FWare       = 'FirmwareVersion',
    StrobeTime  = { },
    -- luacheck: pop
    Resolution  = { },
    Protect     = { },
    ContTake    = { },
    ImageSize   = { PrintConv = function(_self, val) val = tr(val, '-', 'x') return val end },
    ColorMode   = { },
    Zoom        = { },
    ZoomPos     = { },
    LightS      = { },
    Type        = {
        Name = 'CameraType',
        Groups = { [2] = 'Camera' },
        DataMember = 'CameraType',
        RawConv = function(self, val) self.CameraType = val return val end,
    },
    Version     = { Groups = { [2] = 'Camera' } },
    ID          = { Groups = { [2] = 'Camera' } },
}

-- APP12 segment written in Photoshop "Save For Web" images
-- (from tests with Photoshop 7 files - PH/1)
APP12.Ducky = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    WRITE_PROC = false, -- predeclaration, see below for implementation
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
        ValueConv = function(_self, val) return unpack('N', val) end,    -- 4-byte integer
        ValueConvInv = function(_self, val) return pack('N', val) end,
        PrintConv = function(_self, val) return perlStr(val) .. '%' end,
        PrintConvInv = function(_self, val)
            local ok, c1 = isMatch(val, [[(\d+)]])
            if ok then return c1 else return nil end
        end,
    },
    [2] = { --#1
        Name = 'Comment',
        Priority = 0,
        Avoid = 1,
        -- (ignore 4-byte character count at start of value)
        ValueConv = function(self, val) return self:Decode(substr(val, 4), 'UTF16', 'MM') end,
        ValueConvInv = function(self, val) return pack('N', length(val)) .. self:Encode(val, 'UTF16', 'MM') end,
    },
    [3] = { --PH
        Name = 'Copyright',
        Priority = 0,
        Avoid = 1,
        Groups = { [2] = 'Author' },
        -- (ignore 4-byte character count at start of value)
        ValueConv = function(self, val) return self:Decode(substr(val, 4), 'UTF16', 'MM') end,
        ValueConvInv = function(self, val) return pack('N', length(val)) .. self:Encode(val, 'UTF16', 'MM') end,
    },
}

--------------------------------------------------------------------------------
-- Write APP12 Ducky segment
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref, 2) tag table ref
-- Returns: New directory data or undefined on error
function APP12.WriteDucky(et, dirInfo, tagTablePtr)
    if not et then return 1 end    -- allow dummy access to autoload this package
    local dataPt = dirInfo.DataPt
    local pos = dirInfo.DirStart
    local newTags = Writer().GetNewTagInfoHash(et, tagTablePtr)
    local addTags = sort(keys(newTags), function(a, b) return a - b end) -- ($a <=> $b)
    local dirEnd
    local doneTags = { }
    if dataPt then
        dirEnd = pos + dirInfo.DirLen
    else
        local tmp = ''
        dataPt = tmp
        pos, dirEnd = 0, 0
    end
    local newData = ''
    SetByteOrder('MM')
    -- process all data blocks in Ducky segment
    while true do
        local tag, len, val
        if pos + 4 <= dirEnd then
            tag = Get16u(dataPt, pos)
            len = Get16u(dataPt, pos + 2)
            pos = pos + 4
            if pos + len > dirEnd then
                et:Warn('Invalid Ducky block length')
                return nil
            end
            val = substr(dataPt, pos, len)
            pos = pos + len
        else
            if #addTags == 0 then break end
            tag = table.remove(addTags)     -- (pop @addTags)
            if doneTags[tag] then goto nextBlock end
        end
        doneTags[tag] = 1
        do
            local tagInfo = newTags[tag]
            if tagInfo then
                local nvHash = Writer().GetNewValueHash(et, tagInfo)
                local isNew
                if val ~= nil then
                    if perlTruthy(Writer().IsOverwriting(et, nvHash, val)) then
                        et:VerboseValue('- Ducky:' .. tagInfo.Name, val)
                        isNew = 1
                    end
                else
                    if not perlTruthy(nvHash.IsCreating) then goto nextBlock end
                    isNew = 1
                end
                if isNew then
                    val = et:GetNewValue(nvHash)
                    et.CHANGED = (et.CHANGED or 0) + 1
                    if val == nil then goto nextBlock end   -- next if tag is being deleted
                    et:VerboseValue('+ Ducky:' .. tagInfo.Name, val)
                end
            end
        end
        newData = newData .. pack('nn', tag, length(val)) .. val
        ::nextBlock::
    end
    if length(newData) > 0 then newData = newData .. '\0\0' end
    return newData
end

--------------------------------------------------------------------------------
-- Process APP12 Ducky segment (ref PH)
-- Inputs: 0) ExifTool object reference, 1) Directory information ref, 2) tag table ref
-- Returns: 1 on success, 0 if this wasn't a recognized Ducky segment
-- Notes: This segment has the following format:
--   1) 5 bytes: "Ducky"
--   2) multiple data blocks (all integers are big endian):
--      a) 2 bytes: block type (0=end, 1=Quality, 2=Comment, 3=Copyright)
--      b) 2 bytes: block length (N)
--      c) N bytes: block data
function APP12.ProcessDucky(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    local pos = dirInfo.DirStart
    local dirEnd = pos + dirInfo.DirLen
    SetByteOrder('MM')
    -- process all data blocks in Ducky segment
    while true do
        if pos + 4 > dirEnd then break end
        local tag = Get16u(dataPt, pos)
        local len = Get16u(dataPt, pos + 2)
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

--------------------------------------------------------------------------------
-- Process APP12 Picture Info segment (ref PH)
-- Inputs: 0) ExifTool object reference, 1) Directory information ref, 2) tag table ref
-- Returns: 1 on success, 0 if this wasn't a recognized APP12
function APP12.ProcessAPP12(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    local dirStart = perlTruthy(dirInfo.DirStart) and dirInfo.DirStart or 0
    local dirLen = perlTruthy(dirInfo.DirLen) and dirInfo.DirLen or (length(dataPt) - dirStart)
    if dirLen ~= dirStart + length(dataPt) then
        local buff = substr(dataPt, dirStart, dirLen)
        dataPt = buff
    -- (else: `pos($$dataPt) = $$dirInfo{DirStart}`, reset to 0 below)
    end
    local verbose = et:Options('Verbose')
    local success = 0
    local section = ''
    -- (pos($$dataPt) = 0: the match loop below starts at the beginning)

    -- this regular expression is a bit complex, but basically we are looking for
    -- section headers (eg. "[Camera Info]") and tag/value pairs (eg. "tag=value",
    -- where "value" may contain white space), separated by spaces or CR/LF.
    -- (APP12 uses CR/LF, but Olympus TextualInfo is similar and uses spaces)
    for token in eachMatch(dataPt, [[(\[.*?\]|[\w#-]+=[\x20-\x7e]+?(?=\s*([\n\r\0]|[\w#-]+=|\[|$)))]]) do
        -- was this a section name?
        local ok, c1 = isMatch(token, [=[^\[(.*)\]]=])
        if ok then
            if perlTruthy(verbose) then et:VerboseDir(c1) end
            local isInfo, s1 = isMatch(token, [=[(?i)\[(\S+) ?Info\]]=])
            if isInfo then section = s1 else section = '' end
            success = 1
            goto nextToken
        end
        if perlTruthy(verbose) and success == 0 then et:VerboseDir(dirInfo.DirName) end
        success = 1
        do
            local tag, val = matches(token, [[(\S+)=(.+)]])
            local tagInfo = et:GetTagInfo(tagTablePtr, tag)
            if perlTruthy(verbose) then et:VerboseInfo(tag, tagInfo, { Value = val }) end
            if not tagInfo then
                -- add new tag to table
                tagInfo = { Name = ucfirst(tag) }
                -- put in Camera group if information in "Camera" section
                if isMatch(section, [[(?i)camera]]) then tagInfo.Groups = { [2] = 'Camera' } end
                et:VPrint(0, et.INDENT, '[adding APP12:' .. tagInfo.Name .. "]\n")
                AddTagToTable(nil, tagTablePtr, tag, tagInfo)
            end
            et:FoundTag(tagInfo, val)
        end
        ::nextToken::
    end
    return success
end

APP12.PictureInfo.PROCESS_PROC = APP12.ProcessAPP12
APP12.Ducky.PROCESS_PROC = APP12.ProcessDucky
APP12.Ducky.WRITE_PROC = APP12.WriteDucky

return APP12
