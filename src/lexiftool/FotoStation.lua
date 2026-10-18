--------------------------------------------------------------------------------
-- File:         lexiftool/FotoStation.lua
-- Ported from:  lib/Image/ExifTool/FotoStation.pm
--
-- Description:  Read/write FotoWare FotoStation trailer
--
-- Revisions:    10/28/2006 - P. Harvey Created
--
-- Port notes:   ProcessFotoStation (read and write) and the Main/SoftEdit
--               tables, SoftEdit with upstream's WRITE_PROC/CHECK_PROC.
--------------------------------------------------------------------------------

local perl = require('lexiftool.perl')
local length = perl.length
local ExifTool = require('lexiftool')
local Writer = require('lexiftool.Writer')

local FotoStation = {}

FotoStation.Main = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    GROUPS = { [2] = 'Image' },
    NOTES = [[
        The following tables define information found in the FotoWare FotoStation
        trailer.
    ]],
    [0x01] = {
        Name = 'IPTC',
        SubDirectory = {
            TagTable = 'lexiftool.IPTC.Main',
        },
    },
    [0x02] = {
        Name = 'SoftEdit',
        SubDirectory = {
            TagTable = 'lexiftool.FotoStation.SoftEdit',
        },
    },
    [0x03] = {
        Name = 'ThumbnailImage',
        Groups = { [2] = 'Preview' },
        Writable = 1,
        RawConv = function(self, val, tag)
            -- (upstream ValidateImage returns the image reference; the port's returns the data)
            local pt = self:ValidateImage(val, tag)
            if pt == nil then return nil end
            return { ref = 'SCALAR', value = pt }
        end,
    },
    [0x04] = {
        Name = 'PreviewImage',
        Groups = { [2] = 'Preview' },
        Writable = 1,
        RawConv = function(self, val, tag)
            -- (upstream ValidateImage returns the image reference; the port's returns the data)
            local pt = self:ValidateImage(val, tag)
            if pt == nil then return nil end
            return { ref = 'SCALAR', value = pt }
        end,
    },
}

-- crop coordinate conversions (upstream %cropConv shared hash; Lua has no
-- hash-slice merge, so the conversions are expanded into each entry below)
local function cropConvValue(_self, val)
    return val / 1000
end

local function cropConvValueInv(_self, val)
    return val * 1000
end

local function cropConvPrint(self, val)
    return self.NumStr(val) .. '%'
end

local function cropConvPrintInv(_self, val)
    return (perl.tr(val, ' %', '', 'd'))
end

-- soft crop record
FotoStation.SoftEdit = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    WRITE_PROC = function(...) return require('lexiftool.Writer').WriteBinaryData(...) end,
    CHECK_PROC = Writer.CheckBinaryData,
    WRITABLE = 1,
    FORMAT = 'int32s',
    FIRST_ENTRY = 0,
    GROUPS = { [2] = 'Image' },
    [0] = {
        Name = 'OriginalImageWidth',
    },
    [1] = 'OriginalImageHeight',
    [2] = 'ColorPlanes',
    [3] = {
        Name = 'XYResolution',
        ValueConv = function(_self, val) return val / 1000 end,
        ValueConvInv = function(_self, val) return val * 1000 end,
    },
    [4] = {
        Name = 'Rotation',
        Notes = [[
            rotations are stored as degrees CCW * 100, but converted to degrees CW by
            ExifTool
        ]],
        -- raw value is 0, 9000, 18000 or 27000
        ValueConv = function(_self, val)
            if val == 0 then return 0 end -- (Perl: 0 is falsy)
            return 360 - val / 100
        end,
        ValueConvInv = function(_self, val)
            if not perl.truthy(val) then return 0 end
            return (360 - val) * 100
        end,
    },
    -- 5 Validity Check (0x11222211)
    [6] = { Name = 'CropLeft',   ValueConv = cropConvValue, ValueConvInv = cropConvValueInv,
                                 PrintConv = cropConvPrint, PrintConvInv = cropConvPrintInv },
    [7] = { Name = 'CropTop',    ValueConv = cropConvValue, ValueConvInv = cropConvValueInv,
                                 PrintConv = cropConvPrint, PrintConvInv = cropConvPrintInv },
    [8] = { Name = 'CropRight',  ValueConv = cropConvValue, ValueConvInv = cropConvValueInv,
                                 PrintConv = cropConvPrint, PrintConvInv = cropConvPrintInv },
    [9] = { Name = 'CropBottom', ValueConv = cropConvValue, ValueConvInv = cropConvValueInv,
                                 PrintConv = cropConvPrint, PrintConvInv = cropConvPrintInv },
    [11] = {
        Name = 'CropRotation',
        -- raw value in the range -4500 to 4500
        ValueConv = function(_self, val) return -val / 100 end,
        ValueConvInv = function(_self, val) return -val * 100 end,
    },
}

--------------------------------------------------------------------------------
-- Read/write FotoStation information in a file
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference
-- Returns: 1 on success, 0 if this file didn't contain FotoStation information
-- - updates DataPos to point to start of FotoStation information
-- - updates DirLen to trailer length
--------------------------------------------------------------------------------
function FotoStation.ProcessFotoStation(et, dirInfo)
    if not et then return 1 end    -- allow dummy access to autoload this package
    local raf = dirInfo.RAF
    local outfile = dirInfo.OutFile
    local offset = dirInfo.Offset or 0
    local tagTablePtr, dirBuff
    local verbose = et:Options('Verbose')
    local out = et:Options('TextOut')
    local rtnVal = 0

    dirInfo.DirLen = 0          -- initialize returned trailer length
    raf:Seek(-offset, 2)        -- seek to specified offset from end of file

    -- loop through FotoStation records
    while true do
        -- look for trailer signature
        if not raf:Seek(-10, 1) then break end
        local n, footer = raf:Read(10)
        if n ~= 10 then break end
        local tag, size, sig = perl.unpack('nNN', footer)
        if not (sig == 0xa1b2c3d4 and size >= 10 and raf:Seek(-size, 1)) then break end
        size = size - 10        -- size of data only
        local n2, buff = raf:Read(size)
        if n2 ~= size then break end
        raf:Seek(-size, 1)
        -- set variables returned in dirInfo hash
        dirInfo.DataPos = raf:Tell()
        dirInfo.DirLen = dirInfo.DirLen + size + 10

        if not tagTablePtr then
            tagTablePtr = et:GetTagTable('lexiftool.FotoStation.Main')
            et.SetByteOrder('MM')   -- necessary for the binary data
            rtnVal = 1              -- we found a valid FotoStation trailer
        end
        if not outfile then
            -- print verbose trailer information
            if perl.truthy(verbose) or et.HTML_DUMP then
                et:DumpTrailer({
                    RAF = raf,
                    DataPos = dirInfo.DataPos,
                    DirLen = size + 10,
                    DirName = 'FotoStation_' .. tag,
                })
            end
            -- extract information for this tag
            et:HandleTag(tagTablePtr, tag, buff, {
                DataPt  = buff,
                Start   = 0,
                Size    = size,
                DataPos = dirInfo.DataPos,
            })
            goto continue
        end
        if Writer.IsGroupDeleted(et, 'FotoStation') then
            if perl.truthy(verbose) then out:write("  Deleting FotoStation trailer\n") end
            verbose = 0     -- no more verbose messages after this
            et.CHANGED = (et.CHANGED or 0) + 1
            goto continue
        end
        -- rewrite this information
        do
            local tagInfo = et:GetTagInfo(tagTablePtr, tag)
            if tagInfo then
                local newVal
                local tagName = tagInfo.Name
                if tagInfo.SubDirectory then
                    local subdirInfo = {
                        DataPt   = buff,
                        DirStart = 0,
                        DirLen   = size,
                        DataPos  = dirInfo.DataPos,
                        DirName  = tagName,
                        Parent   = 'FotoStation',
                    }
                    local subTable = et:GetTagTable(tagInfo.SubDirectory.TagTable)
                    newVal = Writer.WriteDirectory(et, subdirInfo, subTable)
                else
                    local nvHash = Writer.GetNewValueHash(et, tagInfo)
                    if Writer.IsOverwriting(et, nvHash) > 0 then
                        newVal = Writer.GetNewValue(et, nvHash)
                        if newVal == nil then newVal = '' end
                        if verbose > 1 then
                            local len = length(newVal)
                            if perl.truthy(size) then out:write('    - FotoStation:' .. tagName .. ' (' .. size .. " bytes)\n") end
                            if perl.truthy(len) then out:write('    + FotoStation:' .. tagName .. ' (' .. len .. " bytes)\n") end
                        end
                        et.CHANGED = (et.CHANGED or 0) + 1
                    end
                end
                if newVal ~= nil then
                    buff = newVal
                    size = length(newVal) + 10
                    footer = perl.pack('nNN', tag, size, sig)
                end
            end
            -- maintain original record order
            dirBuff = buff .. footer .. (dirBuff or '')
        end
        ::continue::
    end
    -- write the modified FotoStation trailer
    if dirBuff and not require('lexiftool.Writer').Write(outfile, dirBuff) then rtnVal = -1 end
    return rtnVal
end

-- (PROCESS_PROC/WRITE_PROC are set here so the table can reference the
--  function above -- upstream has both inline, pointing at the same routine)
FotoStation.Main.PROCESS_PROC = FotoStation.ProcessFotoStation
FotoStation.Main.WRITE_PROC = FotoStation.ProcessFotoStation

return FotoStation
