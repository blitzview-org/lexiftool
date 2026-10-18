--------------------------------------------------------------------------------
-- File:         lexiftool/PrintIM.lua
-- Ported from:  lib/Image/ExifTool/PrintIM.pm
--
-- Description:  Read PrintIM meta information
--
-- Revisions:    04/07/2004  - P. Harvey Created
--
-- Port notes:   read subset: PrintIM table and processor, used as a
--               sub-directory of the EPPIM/Exif tags.
--------------------------------------------------------------------------------

local PrintIM = {}

local sprintf = require('lexiftool.perl').sprintf
local perlTruthy = require('lexiftool.perl').truthy

-- ExifTool PrintIM version (mirror of $Image::ExifTool::PrintIM::VERSION)
PrintIM.VERSION = '1.07'

-- PrintIM table (proprietary specification by Epson)
PrintIM.Main = {
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    GROUPS = { [0] = 'PrintIM', [1] = 'PrintIM', [2] = 'Printing' },
    PRINT_CONV = function(_self, val) return sprintf('0x%.8x', val) end,
    TAG_PREFIX = 'PrintIM',
    PrintIMVersion = { -- values: 0100, 0250, 0260, 0300
        Description = 'PrintIM Version',
        -- (PrintConv = false suppresses the table PRINT_CONV default,
        --  mirroring the upstream `PrintConv => undef`)
        PrintConv = false,
    },
}

-- Process PrintIM IFD
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
function PrintIM.ProcessPrintIM(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    local offset = dirInfo.DirStart
    local size = dirInfo.DirLen

    if not size then
        et:Warn('Empty PrintIM data')
        return 0
    end
    if size <= 15 then
        et:Warn('Bad PrintIM data')
        return 0
    end
    if dataPt:sub(offset + 1, offset + 7) ~= 'PrintIM' then
        et:Warn('Invalid PrintIM header')
        return 0
    end
    -- check size of PrintIM block
    local num = et.Get16u(dataPt, offset + 14)
    if size < 16 + num * 6 then
        -- size is too big, maybe byte ordering is wrong
        if et.GetByteOrder() == 'II' then
            et.SetByteOrder('MM')
        else
            et.SetByteOrder('II')
        end
        num = et.Get16u(dataPt, offset + 14)
        if size < 16 + num * 6 then
            et:Warn('Bad PrintIM size')
            return 0
        end
    end
    if perlTruthy(et:Options('Verbose')) then et:VerboseDir('PrintIM', num) end
    et:HandleTag(tagTablePtr, 'PrintIMVersion', dataPt:sub(offset + 9, offset + 12), {
        DataPt = dataPt,
        Start  = offset + 8,
        Size   = 4,
    })
    for n = 0, num - 1 do
        local pos = offset + 16 + n * 6
        local tag = et.Get16u(dataPt, pos)
        local val = et.Get32u(dataPt, pos + 2)
        et:HandleTag(tagTablePtr, tag, val, {
            Index  = n,
            DataPt = dataPt,
            Start  = pos + 2,
            Size   = 4,
        })
    end
    return 1
end

-- (PROCESS_PROC is set here so the table can reference the function below)
PrintIM.Main.PROCESS_PROC = PrintIM.ProcessPrintIM

return PrintIM
