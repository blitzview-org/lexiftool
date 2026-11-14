--------------------------------------------------------------------------------
-- File:         lexiftool/JVC.lua
-- Ported from:  lib/Image/ExifTool/JVC.pm
--
-- Description:  JVC EXIF maker notes tags
--
-- Revisions:    12/21/2005  - P. Harvey Created
--
-- Port notes:   JVC.pm in full: the Main and Text tables and ProcessJVCText.
--               Main's WRITE_PROC/CHECK_PROC (Exif::WriteExif/CheckExif)
--               are reached through wrappers instead of a top-level require
--               of WriteExif, which would pull in most vendor modules.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local perl = require('lexiftool.perl')
local perlTruthy = perl.truthy
local isMatch, eachMatch, subst = perl.isMatch, perl.eachMatch, perl.subst
local substr = perl.substr
local AddTagToTable = ExifTool.AddTagToTable

local JVC = {}

-- JVC EXIF-based maker notes
JVC.Main = {
    WRITE_PROC = function(...) return require('lexiftool.WriteExif').WriteExif(...) end,
    CHECK_PROC = function(...) return require('lexiftool.WriteExif').CheckExif(...) end,
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    NOTES = 'JVC EXIF maker note tags.',
    --0x0001 - almost always '2', but '3' for GR-DV700 samples
    [0x0002] = { -- #PH
        Name = 'CPUVersions',
        -- remove trailing nulls/spaces and split at remaining nulls/spaces
        ValueConv = function(_self, val)
            local _ = val; _ = subst(_, [[(\s*\0)+$]], ''); _ = subst(_, [[(\s*\0)+]], ', ', 'g'); return _
        end,
    },
    [0x0003] = { -- #PH
        Name = 'Quality',
        PrintConv = {
            [0] = 'Low',
            [1] = 'Normal',
            [2] = 'Fine',
        },
    },
}

-- JVC text-based maker notes
JVC.Text = {
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    NOTES = 'JVC/Victor text-based maker note tags.',
    VER = { Name = 'MakerNoteVersion' }, -- PH
    QTY = { -- PH
        Name = 'Quality',
        PrintConv = {
            STND = 'Normal',
            STD  = 'Normal',
            FINE = 'Fine',
        },
    },
}

--------------------------------------------------------------------------------
-- Process JVC text-based maker notes
-- Inputs: 0) ExifTool object reference
--         1) Reference to directory information hash
--         2) Pointer to tag table for this directory
-- Returns: 1 on success, otherwise returns 0 and sets a Warning
function JVC.ProcessJVCText(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    local dirStart = perlTruthy(dirInfo.DirStart) and dirInfo.DirStart or 0
    local dataLen = dirInfo.DataLen
    local dirLen = perlTruthy(dirInfo.DirLen) and dirInfo.DirLen or dataLen - dirStart
    local verbose = et:Options('Verbose')

    local data = substr(dataPt, dirStart, dirLen)
    -- validate text maker notes
    if not isMatch(data, [[^VER:]]) then
        et:Warn('Bad JVC text maker notes')
        return 0
    end
    for tag, val in eachMatch(data, [[(?s)([A-Z]+):(.{3,4})]]) do
        local tagInfo = et:GetTagInfo(tagTablePtr, tag)
        if perlTruthy(verbose) then
            et:VerboseInfo(tag, tagInfo, {
                Table  = tagTablePtr,
                Value  = val,
            })
        end
        if not tagInfo then
            if not perlTruthy(et.OPTIONS.Unknown) then goto next end
            tagInfo = {
                Name = 'JVC_Text_' .. tag,
                Unknown = 1,
                PrintConv = function(self, v) return ExifTool.LimitLongValues(v, self) end,
            }
            -- add tag information to table
            AddTagToTable(nil, tagTablePtr, tag, tagInfo)
        end
        et:FoundTag(tagInfo, val)
        ::next::
    end
    return 1
end

JVC.Text.PROCESS_PROC = JVC.ProcessJVCText

return JVC -- end
