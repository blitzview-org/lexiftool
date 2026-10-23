--------------------------------------------------------------------------------
-- File:         lexiftool/PhotoMechanic.lua
-- Ported from:  lib/Image/ExifTool/PhotoMechanic.pm
--
-- Description:  Read/write Camera Bits Photo Mechanic information
--
-- Revisions:    10/28/2006 - P. Harvey Created
--
-- Port notes:   complete: the colorClasses map, the Main, SoftEdit and
--               XMP tables (with their WRITE_PROC/CHECK_PROC and Inv
--               conversions), and ProcessPhotoMechanic (trailer read,
--               DumpTrailer and trailer rewrite).
--------------------------------------------------------------------------------

local perl = require('lexiftool.perl')
local subst = perl.subst
local sprintf = perl.sprintf
local length = perl.length
local str = perl.str
local carray = require('carray')
local IPTC = require('lexiftool.IPTC')

local PhotoMechanic = {}

-- color class names
local colorClasses = {
    [0] = '0 (None)',
    [1] = '1 (Winner)',
    [2] = '2 (Winner alt)',
    [3] = '3 (Superior)',
    [4] = '4 (Superior alt)',
    [5] = '5 (Typical)',
    [6] = '6 (Typical alt)',
    [7] = '7 (Extras)',
    [8] = '8 (Trash)',
}

-- raw/preview crop coordinate conversions
local rawCropConv = {
    ValueConv    = function(_, val) return val / 655.36 end,
    ValueConvInv = function(_, val) return math.floor(tonumber(val) * 655.36 + 0.5) end,
    PrintConv    = function(_, val) return sprintf('%.3f%%', val) end,
    PrintConvInv = function(_, val) return (str(val):gsub('[ %%]', '')) end,
}

-- Perl's `%rawCropConv` spread into a tag entry
local function withRawCropConv(name)
    local t = { Name = name }
    for k, v in pairs(rawCropConv) do t[k] = v end
    return t
end

-- main tag table IPTC-format records in PhotoMechanic trailer
PhotoMechanic.Main = {
    GROUPS = { [2] = 'Image' },
    PROCESS_PROC = IPTC.ProcessIPTC,
    WRITE_PROC = IPTC.WriteIPTC,
    NOTES = [[
        The Photo Mechanic trailer contains data in an IPTC-format structure, with
        soft edit information stored under record number 2.
    ]],
    [2] = {
        Name = 'SoftEdit',
        SubDirectory = {
            TagTable = 'lexiftool.PhotoMechanic.SoftEdit',
        },
    },
}

-- Record 2 -- PhotoMechanic soft edit information
-- (FORMAT is carried for parity but deliberately not used in the read path;
--  see the upstream comment about backward compatibility with improperly
--  written PhotoMechanic tags)
PhotoMechanic.SoftEdit = {
    GROUPS = { [2] = 'Image' },
    WRITE_PROC = IPTC.WriteIPTC,
    CHECK_PROC = function(...) return require('lexiftool.IPTC').CheckIPTC(...) end,
    WRITABLE = 1,
    FORMAT = 'int32s',
    [209] = withRawCropConv('RawCropLeft'),
    [210] = withRawCropConv('RawCropTop'),
    [211] = withRawCropConv('RawCropRight'),
    [212] = withRawCropConv('RawCropBottom'),
    [213] = 'ConstrainedCropWidth',
    [214] = 'ConstrainedCropHeight',
    [215] = 'FrameNum',
    [216] = {
        Name = 'Rotation',
        PrintConv = {
            [0] = '0',
            [1] = '90',
            [2] = '180',
            [3] = '270',
        },
    },
    [217] = 'CropLeft',
    [218] = 'CropTop',
    [219] = 'CropRight',
    [220] = 'CropBottom',
    [221] = {
        Name = 'Tagged',
        PrintConv = { [0] = 'No', [1] = 'Yes' },
    },
    [222] = {
        Name = 'ColorClass',
        PrintConv = colorClasses,
    },
    [223] = 'Rating',
    [236] = withRawCropConv('PreviewCropLeft'),
    [237] = withRawCropConv('PreviewCropTop'),
    [238] = withRawCropConv('PreviewCropRight'),
    [239] = withRawCropConv('PreviewCropBottom'),
}

-- PhotoMechanic XMP properties
PhotoMechanic.XMP = {
    GROUPS = { [0] = 'XMP', [1] = 'XMP-photomech', [2] = 'Image' },
    NAMESPACE = { photomechanic = 'http://ns.camerabits.com/photomechanic/1.0/' },
    WRITE_PROC = require('lexiftool.XMP').WriteXMP,
    WRITABLE = 'string',
    NOTES = [[
        Below is a list of the observed PhotoMechanic XMP tags.  The actual
        namespace prefix is "photomechanic" but ExifTool shortens this in
        the family 1 group name.
    ]],
    ColorClass = {
        Writable = 'integer',
        PrintConv = colorClasses,
    },
    CountryCode = { Avoid = 1, Groups = { [2] = 'Location' } },
    EditStatus = {},
    PMVersion = {},
    Prefs = {
        Notes = 'format is "Tagged:0, ColorClass:1, Rating:2, FrameNum:3"',
        PrintConv = function(_self, val)
            return subst(str(val),
                [[\s*(\d+):\s*(\d+):\s*(\d+):\s*(\S*)]],
                'Tagged:$1, ColorClass:$2, Rating:$3, FrameNum:$4')
        end,
        PrintConvInv = function(_self, val)
            return subst(str(val),
                [[(?is)Tagged:\s*(\d+).*ColorClass:\s*(\d+).*Rating:\s*(\d+).*FrameNum:\s*(\S*)]],
                '$1:$2:$3:$4')
        end,
    },
    Tagged = { Writable = 'boolean', PrintConv = { False = 'No', True = 'Yes' } },
    TimeCreated = {
        Avoid = 1,
        Groups = { [2] = 'Time' },
        Shift = 'Time',
        ValueConv = function(_self, val) return require('lexiftool.Exif').ExifTime(val) end,
        ValueConvInv = function(_self, val) return IPTC.IptcTime(val) end,
    },
    CreatorIdentity = { List = 'Seq' },
}

--------------------------------------------------------------------------------
-- Read/write PhotoMechanic information in a file (read subset)
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference
-- Returns: 1 on success, 0 if this file didn't contain PhotoMechanic info
-- - updates DataPos to point to start of PhotoMechanic information
-- - updates DirLen to trailer length
--------------------------------------------------------------------------------
function PhotoMechanic.ProcessPhotoMechanic(et, dirInfo)
    local raf = dirInfo.RAF
    local offset = dirInfo.Offset or 0
    local outfile = dirInfo.OutFile
    local verbose = et:Options('Verbose')
    local out = et:Options('TextOut')
    local rtnVal = 0
    local buff, footer, n

    -- (every branch exits; the loop form mirrors the Perl original)
    -- luacheck: ignore 512
    while true do
        -- read and validate trailer footer (last 12 bytes)
        if raf:Seek(-12-offset, 2) then n, footer = raf:Read(12) end
        if n ~= 12 then break end
        if not perl.isMatch(footer, [[cbipcbbl$]]) then break end
        local size = perl.unpack('N', footer)

        if size & 0x80000000 ~= 0 or not raf:Seek(-size-12, 1) then
            et:Warn('Bad PhotoMechanic trailer')
            break
        end
        n, buff = raf:Read(size)
        if n ~= size then
            et:Warn('Error reading PhotoMechanic trailer')
            break
        end
        rtnVal = 1    -- we read the trailer successfully

        -- set variables returned in dirInfo hash
        dirInfo.DataPos = raf:Tell() - size
        dirInfo.DirLen = size + 12

        local dirInfo2 = {  -- (upstream's lexical %dirInfo)
            DataPt = buff,
            DataPos = dirInfo.DataPos,
            DirStart = 0,
            DirLen = size,
            Parent = 'PhotoMechanic',
        }
        local tagTablePtr = et:GetTagTable('lexiftool.PhotoMechanic.Main')
        if not outfile then
            -- extract trailer information
            if perl.truthy(verbose) or et.HTML_DUMP then et:DumpTrailer(dirInfo) end
            et:ProcessDirectory(dirInfo2, tagTablePtr)
        elseif et.DEL_GROUP.PhotoMechanic then
            -- delete the trailer
            if perl.truthy(verbose) then out:write("  Deleting PhotoMechanic trailer\n") end
            et.CHANGED = (et.CHANGED or 0) + 1
        else
            -- rewrite the trailer
            local Writer = require('lexiftool.Writer')   -- (Writer.pl, loaded on demand)
            local newPt
            local newBuff = Writer.WriteDirectory(et, dirInfo2, tagTablePtr)
            if newBuff ~= nil then
                newBuff = carray.new('char'):append(newBuff)
                newPt = newBuff -- write out the modified trailer
                local pad = 0x800 - length(newBuff)
                if pad > 0 and not perl.truthy(et.OPTIONS.Compact.NoPadding) then
                    -- pad out to 2kB like PhotoMechanic does
                    newBuff:append(("\0"):rep(pad))
                end
                -- generate new footer
                footer = perl.pack('N', length(newPt)) .. 'cbipcbbl'
            else
                newPt = buff    -- just copy existing trailer
            end
            -- write out the trailer
            if not Writer.Write(outfile, newPt, footer) then rtnVal = -1 end
        end
        break
    end
    return rtnVal
end

return PhotoMechanic
