--------------------------------------------------------------------------------
-- File:         lexiftool/MakerNotes.lua
-- Ported from:  lib/Image/ExifTool/MakerNotes.pm
--
-- Description:  Read and write EXIF maker notes
--
-- Revisions:    11/11/2004 - P. Harvey Created
--
-- Port notes:   read-path subset.  The conditional `%Main` list carries
--               every upstream entry, in upstream order (verify_port checks
--               the Name sequence).  Entries whose target table is not
--               ported yet -- `Kodak::Type2`-`Type11`/`Unknown`,
--               `Nikon::Type2`, `Sony::PIC`/`Ericsson` -- reach ProcessExif's
--               "Unknown tag table" warning instead of being decoded; the
--               `FixOffsets` patches of `MakerNoteGE2`/`MakerNoteSanyoPatch`
--               are functions (upstream: eval strings) that ProcessExif
--               calls as `valuePtr, valEnd = FixOffsets(...)`.
--               `ProcessCanon` includes the HtmlDump footer-
--               identification block (MakerNotes.pm:1697-1720);
--               `ProcessGE2` and `ProcessKodakPatch` are ported.
--               The three catch-all entries at the end of the upstream list
--               are ported: `MakerNoteUnknownText`/`MakerNoteUnknownBinary`
--               and `MakerNoteUnknown` (dispatching into the new
--               `lexiftool.Unknown.Main` table via
--               `ProcessUnknownOrPreview`/`ProcessUnknown`, incl. the
--               "[minor] Unrecognized MakerNotes" warning when no IFD is
--               found -- first exercised by GoPro.jpg).  Its write side,
--               `WriteUnknownOrPreview` (PreviewImage maker notes or a
--               rewritten IFD via WriteExif), is wired as the entry's
--               WriteProc, with WriteExif's matching `$loc = 0` branch.
--               LocateIFD and GetMakerNoteOffset in full; LocateIFD tells a
--               `$start`-relative Base by the name of the ported Base
--               function's third parameter (`start` vs `_start`).
--------------------------------------------------------------------------------

local matches = require('lexiftool.perl').matches
local isMatch = require('lexiftool.perl').isMatch
local substr = require('lexiftool.perl').substr
local subst = require('lexiftool.perl').subst
local truthy = require('lexiftool.perl').truthy
local length = require('lexiftool.perl').length
local ExifTool = require('lexiftool')
local sprintf = require('lexiftool.perl').sprintf
local tsort = require('lexiftool.perl').tsort
local perlStr = require('lexiftool.perl').str
local uc = require('lexiftool.perl').uc
local perlNum = require('lexiftool.perl').num

local MakerNotes = {}

-- Process Canon maker notes
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
function MakerNotes.ProcessCanon(et, dirInfo, tagTablePtr)
    -- identify Canon MakerNote footer in HtmlDump
    -- (this code moved from FixBase so it also works for Adobe MakN in DNG images)
    if et.HTML_DUMP and (dirInfo.DirLen or 0) > 8 then
        local dataPos = dirInfo.DataPos or 0
        local dirStart = dirInfo.DirStart or 0
        local footerPos = dirStart + dirInfo.DirLen - 8
        local footer = substr(dirInfo.DataPt, footerPos, 8)
        if matches(footer, [[^(II\x2a\x00|MM\x00\x2a)]]) and substr(footer, 0, 2) == ExifTool.GetByteOrder() then
            local oldOffset = ExifTool.Get32u(footer, 4)
            local newOffset = dirStart + dataPos
            local str = sprintf('Original maker note offset: 0x%.4x', oldOffset)
            if oldOffset ~= newOffset then
                str = str .. sprintf('\nCurrent maker note offset: 0x%.4x', newOffset)
            end
            local filePos = (dirInfo.Base or 0) + dataPos + footerPos
            et:HDump(filePos, 8, '[Canon MakerNotes footer]', str)
        end
    end
    -- process as normal
    return require('lexiftool.Exif').ProcessExif(et, dirInfo, tagTablePtr)
end

--------------------------------------------------------------------------------
-- Process GE type 2 maker notes
-- Inputs: 0) ExifTool object ref, 1) DirInfo ref, 2) tag table ref
-- Returns: 1 on success
function MakerNotes.ProcessGE2(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    if not dataPt then return 0 end
    local dirStart = dirInfo.DirStart or 0

    -- these maker notes are missing the IFD entry count, but they
    -- always have 25 entries, so write the entry count manually
    -- (upstream writes into the caller's scalar through the reference; the
    --  changed buffer is a carray, handed on in dirInfo -- api.md §4)
    if type(dataPt) == 'string' then
        dataPt = require('carray').new('char'):append(dataPt)
        dirInfo.DataPt = dataPt
    end
    ExifTool.Set16u(dataPt, dirStart, 25)
    return require('lexiftool.Exif').ProcessExif(et, dirInfo, tagTablePtr)
end

-- conditional list of maker notes
-- Notes:
-- - This is NOT a normal tag table!
-- - Put these in alphabetical order to make TagNames documentation nicer.
MakerNotes.Main = {
    -- decide which MakerNotes to use (based on makernote header and camera make/model)
    {
        -- this maker notes starts with a standard TIFF header at offset 0x0a
        -- (must check Nikon signature first because Nikon Capture NX can generate
        --  NEF images containing Nikon maker notes from JPEG images of any camera model)
        Name = 'MakerNoteApple',
        Condition = function(_self, val) return matches(perlStr(val), [[^Apple iOS\x00]]) ~= nil end,
        SubDirectory = {
            TagTable = 'lexiftool.Apple.Main',
            Start = function(_et, _val, valuePtr) return valuePtr + 14 end,
            Base = function(_et, _val, start) return start - 14 end,
            ByteOrder = 'Unknown',
        },
    },
    {
        -- this maker notes starts with a standard TIFF header at offset 0x0a
        -- (must check Nikon signature first because Nikon Capture NX can generate
        --  NEF images containing Nikon maker notes from JPEG images of any camera model)
        Name = 'MakerNoteNikon',
        Condition = function(_self, val) return matches(perlStr(val), [[^Nikon\x00\x02]]) ~= nil end,
        SubDirectory = {
            TagTable = 'lexiftool.Nikon.Main',
            Start = function(_et, _val, valuePtr) return valuePtr + 18 end,
            Base = function(_et, _val, start) return start - 8 end,
            ByteOrder = 'Unknown',
        },
    },
    {
        Name = 'MakerNoteCanon',
        -- (starts with an IFD)
        Condition = function(self) return matches(self.Make, [[^Canon]]) ~= nil end,
        Groups = { [1] = 'MakerNotes' },
        SubDirectory = {
            TagTable = 'lexiftool.Canon.Main',
            ProcessProc = MakerNotes.ProcessCanon,
            ByteOrder = 'Unknown',
        },
    },
    {
        Name = 'MakerNoteCasio',
        -- do negative lookahead assertion just to get tags
        -- in a nice order for documentation
        -- (starts with an IFD)
        Condition = function(self, val)
            return matches(self.Make, [[^CASIO]]) ~= nil and matches(perlStr(val), [[^(QVC|DCI)\x00]]) == nil
        end,
        SubDirectory = {
            TagTable = 'lexiftool.Casio.Main',
            ByteOrder = 'Unknown',
        },
    },
    {
        Name = 'MakerNoteCasio2',
        -- (starts with "QVC\0" [Casio] or "DCI\0" [Concord])
        -- (also found in AVI and MOV videos)
        Condition = function(_self, val) return matches(perlStr(val), [[^(QVC|DCI)\x00]]) ~= nil end,
        SubDirectory = {
            TagTable = 'lexiftool.Casio.Type2',
            Start = function(_et, _val, valuePtr) return valuePtr + 6 end,
            ByteOrder = 'Unknown',
            FixBase = 1, -- necessary for AVI and MOV videos
        },
    },
    {
        Name = 'MakerNoteDJIInfo',
        Condition = function(_self, val) return matches(perlStr(val), [[^\[ae_dbg_info:]]) ~= nil end,
        NotIFD = 1,
        SubDirectory = { TagTable = 'lexiftool.DJI.Info' },
    },
    {
        Name = 'MakerNoteDJI',
        Condition = function(self, val)
            return self.Make == 'DJI' and matches(perlStr(val), [[(?s)^(...@AMBA|DJI)]]) == nil
        end,
        SubDirectory = {
            TagTable = 'lexiftool.DJI.Main',
            Start = function(_et, _val, valuePtr) return valuePtr end,
            ByteOrder = 'Unknown',
        },
    },
    {
        Name = 'MakerNoteFLIR',
        -- (starts with IFD, Make is 'FLIR Systems AB' or 'FLIR Systems')
        Condition = function(self)
            -- upstream: `$$self{Make} =~ /^(FLIR Systems|Teledyne FLIR)/`
            -- (PCRE2 via the facade -- Lua patterns have no alternation)
            local make = self.Make
            if not make then return false end
            return matches(perlStr(make), '^(FLIR Systems|Teledyne FLIR)') ~= nil
        end,
        SubDirectory = {
            TagTable = 'lexiftool.FLIR.Main',
            Start = function(_et, _val, valuePtr) return valuePtr end,
            ByteOrder = 'Unknown',
        },
    },
    {
        -- The Fuji maker notes use a structure similar to a self-contained
        -- TIFF file, but with "FUJIFILM" instead of the standard TIFF header
        Name = 'MakerNoteFujiFilm',
        -- (starts with "FUJIFILM" -- also used by some Leica, Minolta and Sharp models)
        -- (GE FujiFilm models start with "GENERALE")
        Condition = function(_self, val) return matches(perlStr(val), [[^(FUJIFILM|GENERALE)]]) ~= nil end,
        SubDirectory = {
            TagTable = 'lexiftool.FujiFilm.Main',
            -- there is an 8-byte maker tag (FUJIFILM) we must skip over
            OffsetPt = function(_et, _val, valuePtr) return valuePtr + 8 end,
            -- the pointers are relative to the subdirectory start
            -- (before adding the offsetPt) - PH
            Base = function(_et, _val, start) return start end,
            ByteOrder = 'LittleEndian',
        },
    },
    {
        Name = 'MakerNoteGE',
        -- (starts with "GE\0\0" or "GENIC\0")
        Condition = function(_self, val) return matches(perlStr(val), [[^GE(\x00\x00|NIC\x00)]]) ~= nil end,
        SubDirectory = {
            TagTable = 'lexiftool.GE.Main',
            Start = function(_et, _val, valuePtr) return valuePtr + 18 end,
            FixBase = 1,
            AutoFix = 1,
            ByteOrder = 'Unknown',
        },
    },
    {
        Name = 'MakerNoteGE2',
        Condition = function(_self, val) return matches(perlStr(val), [[^GE\x0c\0\0\0\x16\0\0\0]]) ~= nil end,
        -- Note: we will get a "Maker notes could not be parsed" warning when writing
        --       these maker notes because they aren't currently supported for writing
        SubDirectory = {
            TagTable = 'lexiftool.FujiFilm.Main',
            ProcessProc = MakerNotes.ProcessGE2,
            Start = function(_et, _val, valuePtr) return valuePtr + 12 end,
            Base = function(_et, _val, start) return start - 6 end,
            ByteOrder = 'LittleEndian',
            -- hard patch for crazy offsets
            FixOffsets = function(valuePtr, valEnd, _size, tagID)
                if tagID >= 0x1303 then valuePtr = valuePtr - 210 end
                return valuePtr, valEnd
            end,
       },
    },
    {
        Name = 'MakerNoteGoogle',
        Condition = function(_self, val) return matches(perlStr(val), [=[^HDRP[\x02\x03]]=]) ~= nil end,
        NotIFD = 1,
        SubDirectory = {
            TagTable = 'lexiftool.Google.HDRPlusMakerNote',
        },
    },
    {
        Name = 'MakerNoteHasselblad',
        Condition = function(self) return self.Make == 'Hasselblad' end,
        SubDirectory = {
            TagTable = 'lexiftool.Unknown.Main',
            ByteOrder = 'Unknown',
            Start = function(_et, _val, valuePtr) return valuePtr end,
            Base = function(_self, _val, _start) return 0 end, -- (avoids warnings since maker notes are not self-contained)
        },
        -- 0x0011 - sensor code (ref IB)
        -- 0x0012 - camera model id?
        -- 0x0015 - camera model name
        -- 0x0016 - coating code (ref IB)
    },
    -- (the GE X5 has really messed up EXIF-like maker notes starting with
    --  "GENIC\x0c\0" --> currently not decoded)
    {
        Name = 'MakerNoteHP',  -- PhotoSmart 720 (also Vivitar 3705, 3705B and 3715)
        Condition = function(_self, val) return matches(perlStr(val), [[^(Hewlett-Packard|Vivitar)]]) ~= nil end,
        SubDirectory = {
            TagTable = 'lexiftool.HP.Main',
            ProcessProc = false, -- predeclaration, patched below (ProcessUnknown)
            ByteOrder = 'Unknown',
        },
    },
    {
        Name = 'MakerNoteHP2', -- PhotoSmart E427
        -- (this type of maker note also used by BenQ, Mustek, Sanyo, Traveler and Vivitar)
        Condition = function(_self, val) return matches(perlStr(val), [==[^610[\x00-\x04]]==]) ~= nil end,
        NotIFD = 1,
        SubDirectory = {
            TagTable = 'lexiftool.HP.Type2',
            Start = function(_et, _val, valuePtr) return valuePtr end,
            ByteOrder = 'LittleEndian',
        },
    },
    {
        Name = 'MakerNoteHP4', -- PhotoSmart M627
        Condition = function(_self, val) return matches(perlStr(val), [==[^IIII[\x04|\x05]\x00]==]) ~= nil end,
        NotIFD = 1,
        SubDirectory = {
            TagTable = 'lexiftool.HP.Type4',
            Start = function(_et, _val, valuePtr) return valuePtr end,
            ByteOrder = 'LittleEndian',
        },
    },
    {
        Name = 'MakerNoteHP6', -- PhotoSmart M425, M525 and M527
        Condition = function(_self, val) return matches(perlStr(val), [[^IIII\x06\x00]]) ~= nil end,
        NotIFD = 1,
        SubDirectory = {
            TagTable = 'lexiftool.HP.Type6',
            Start = function(_et, _val, valuePtr) return valuePtr end,
            ByteOrder = 'LittleEndian',
        },
    },
    {
        Name = 'MakerNoteISL', -- (used in Samsung GX20 samples)
        Condition = function(_self, val) return matches(perlStr(val), [[^ISLMAKERNOTE000\0]]) ~= nil end,
        -- this maker notes starts with a TIFF-like header at offset 0x10
        SubDirectory = {
            TagTable = 'lexiftool.Unknown.Main',
            Start = function(_et, _val, valuePtr) return valuePtr + 24 end,
            Base = function(_et, _val, start) return start - 8 end,
            ByteOrder = 'Unknown',
        },
    },
    {
        Name = 'MakerNoteJVC',
        Condition = function(_self, val) return matches(perlStr(val), [[^JVC ]]) ~= nil end,
        SubDirectory = {
            TagTable = 'lexiftool.JVC.Main',
            Start = function(_et, _val, valuePtr) return valuePtr + 4 end,
            ByteOrder = 'Unknown',
        },
    },
    {
        Name = 'MakerNoteJVCText',
        Condition = function(self, val)
            return matches(self.Make, [[^(JVC|Victor)]]) ~= nil and matches(perlStr(val), [[^VER:]]) ~= nil
        end,
        NotIFD = 1,
        SubDirectory = {
            TagTable = 'lexiftool.JVC.Text',
        },
    },
    {
        Name = 'MakerNoteKodak1a',
        Condition = function(self, val)
            return matches(self.Make, [[^EASTMAN KODAK]]) ~= nil and matches(perlStr(val), [[^KDK INFO]]) ~= nil
        end,
        NotIFD = 1,
        SubDirectory = {
            TagTable = 'lexiftool.Kodak.Main',
            Start = function(_et, _val, valuePtr) return valuePtr + 8 end,
            ByteOrder = 'BigEndian',
        },
    },
    {
        Name = 'MakerNoteKodak1b',
        Condition = function(self, val)
            return matches(self.Make, [[^EASTMAN KODAK]]) ~= nil and matches(perlStr(val), [[^KDK]]) ~= nil
        end,
        NotIFD = 1,
        SubDirectory = {
            TagTable = 'lexiftool.Kodak.Main',
            Start = function(_et, _val, valuePtr) return valuePtr + 8 end,
            ByteOrder = 'LittleEndian',
        },
    },
    {
        -- used by various Kodak, HP, Pentax and Minolta models
        Name = 'MakerNoteKodak2',
        Condition = function(_self, val)
            return matches(perlStr(val), [[(?s)^.{8}Eastman Kodak]]) ~= nil or
            matches(perlStr(val), [[^\x01\0[\0\x01]\0\0\0\x04\0[a-zA-Z]{4}]]) ~= nil
        end,
        NotIFD = 1,
        SubDirectory = {
            TagTable = 'lexiftool.Kodak.Type2',
            ByteOrder = 'BigEndian',
        },
    },
    {
        -- not much to key on here, but we know the
        -- upper byte of the year should be 0x07:
        Name = 'MakerNoteKodak3',
        Condition = function(self, val)
            return matches(self.Make, [[^EASTMAN KODAK]]) ~= nil and
            matches(perlStr(val), [[(?s)^(?!MM|II).{12}\x07]]) ~= nil and
            matches(perlStr(val), [[^(MM|II|AOC)]]) == nil
        end,
        NotIFD = 1,
        SubDirectory = {
            TagTable = 'lexiftool.Kodak.Type3',
            ByteOrder = 'BigEndian',
        },
    },
    {
        Name = 'MakerNoteKodak4',
        Condition = function(self, val)
            return matches(self.Make, [[^Eastman Kodak]]) ~= nil and
            matches(perlStr(val), [[(?s)^.{41}JPG]]) ~= nil and
            matches(perlStr(val), [[^(MM|II|AOC)]]) == nil
        end,
        NotIFD = 1,
        SubDirectory = {
            TagTable = 'lexiftool.Kodak.Type4',
            ByteOrder = 'BigEndian',
        },
    },
    {
        Name = 'MakerNoteKodak5',
        Condition = function(self, val)
            return matches(self.Make, [[^EASTMAN KODAK]]) ~= nil and
            (matches(self.Model, [[CX(4200|4230|4300|4310|6200|6230)]]) ~= nil or
            -- try to pick up similar models we haven't tested yet
            matches(perlStr(val), [[^\0(\x1a\x18|\x3a\x08|\x59\xf8|\x14\x80)\0]]) ~= nil)
        end,
        NotIFD = 1,
        SubDirectory = {
            TagTable = 'lexiftool.Kodak.Type5',
            ByteOrder = 'BigEndian',
        },
    },
    {
        Name = 'MakerNoteKodak6a',
        Condition = function(self)
            return matches(self.Make, [[^EASTMAN KODAK]]) ~= nil and
            matches(self.Model, [[DX3215]]) ~= nil
        end,
        NotIFD = 1,
        SubDirectory = {
            TagTable = 'lexiftool.Kodak.Type6',
            ByteOrder = 'BigEndian',
        },
    },
    {
        Name = 'MakerNoteKodak6b',
        Condition = function(self)
            return matches(self.Make, [[^EASTMAN KODAK]]) ~= nil and
            matches(self.Model, [[DX3700]]) ~= nil
        end,
        NotIFD = 1,
        SubDirectory = {
            TagTable = 'lexiftool.Kodak.Type6',
            ByteOrder = 'LittleEndian',
        },
    },
    {
        Name = 'MakerNoteKodak7',
        -- look for something that looks like a serial number
        -- (confirmed serial numbers have the format KXXXX########, but we also
        --  accept other strings from sample images that may be serial numbers)
        Condition = function(self, val)
            return matches(self.Make, [[(?i)Kodak]]) ~= nil and
            matches(perlStr(val), [=[^[CK][A-Z\d]{3} ?[A-Z\d]{1,2}\d{2}[A-Z\d]\d{4}[ \0]]=]) ~= nil
        end,
        NotIFD = 1,
        SubDirectory = {
            TagTable = 'lexiftool.Kodak.Type7',
            ByteOrder = 'LittleEndian',
        },
    },
    {
        Name = 'MakerNoteKodak8a',
        -- IFD-format maker notes: look for reasonable number of
        -- entries and check format and count of first IFD entry
        Condition = function(self, val)
            return matches(self.Make, [[(?i)Kodak]]) ~= nil and
            (matches(perlStr(val), [[(?s)^\0[\x02-\x7f]..\0[\x01-\x0c]\0\0]]) ~= nil or
             matches(perlStr(val), [[(?s)^[\x02-\x7f]\0..[\x01-\x0c]\0..\0\0]]) ~= nil)
        end,
        SubDirectory = {
            TagTable = 'lexiftool.Kodak.Type8',
            ProcessProc = false, -- predeclaration, patched below (ProcessUnknown)
            ByteOrder = 'Unknown',
        },
    },
    {
        Name = 'MakerNoteKodak8b',
        -- these maker notes have an extra 2 bytes after the entry count
        -- (this is handled by the patch).  Also, the IFD uses a Format 13,
        -- which is some 2-byte format (not Float, as decoded by ExifTool)
        -- - written by the PixPro AZ251, AZ361, AZ262, AZ521
        Condition = function(self, val)
            return matches(self.Make, [[(?i)Kodak]]) ~= nil and
            matches(perlStr(val), [[^MM\0\x2a\0\0\0\x08\0.\0\0]]) ~= nil
        end,
        SubDirectory = {
            TagTable = 'lexiftool.Kodak.Type8',
            ProcessProc = false, -- predeclaration, patched below (ProcessKodakPatch)
            ByteOrder = 'BigEndian',
            Start = function(_et, _val, valuePtr) return valuePtr + 8 end,
            Base = function(_et, _val, start) return start - 8 end,
        },
    },
    {
        Name = 'MakerNoteKodak8c',
        -- TIFF-format maker notes
        Condition = function(self, val)
            return matches(self.Make, [[(?i)Kodak]]) ~= nil and
            matches(perlStr(val), [[^(MM\0\x2a\0\0\0\x08|II\x2a\0\x08\0\0\0)]]) ~= nil
        end,
        SubDirectory = {
            TagTable = 'lexiftool.Kodak.Type8',
            ProcessProc = false, -- predeclaration, patched below (ProcessUnknown)
            ByteOrder = 'Unknown',
            Start = function(_et, _val, valuePtr) return valuePtr + 8 end,
            Base = function(_et, _val, start) return start - 8 end,
        },
    },
    {
        Name = 'MakerNoteKodak9',
        -- test header and Kodak:DateTimeOriginal
        Condition = function(_self, val) return matches(perlStr(val), [[(?s)^IIII[\x02\x03]\0.{14}\d{4}/\d{2}/\d{2} ]]) ~= nil end,
        NotIFD = 1,
        SubDirectory = {
            TagTable = 'lexiftool.Kodak.Type9',
            ByteOrder = 'LittleEndian',
        },
    },
    {
        Name = 'MakerNoteKodak10',
        -- yet another type of Kodak IFD-format maker notes:
        -- this type begins with a byte order indicator,
        -- followed immediately by the IFD
        Condition = function(self, val)
            return matches(self.Make, [[(?i)Kodak]]) ~= nil and
            matches(perlStr(val), [[^(MM\0[\x02-\x7f]|II[\x02-\x7f]\0)]]) ~= nil
        end,
        SubDirectory = {
            TagTable = 'lexiftool.Kodak.Type10',
            ProcessProc = false, -- predeclaration, patched below (ProcessUnknown)
            ByteOrder = 'Unknown',
            Start = function(_et, _val, valuePtr) return valuePtr + 2 end,
        },
    },
    {
        Name = 'MakerNoteKodak11',
        -- these maker notes have a 4-byte entry count
        -- - written by the PixPro S-1 (Note: Make is "JK Imaging, Ltd.", so check Model for "Kodak")
        Condition = function(self, val)
            return matches(self.Model, [[(?i)(Kodak|PixPro)]]) ~= nil and
            matches(perlStr(val), [[(?s)^II\x2a\0\x08\0\0\0.\0\0\0]]) ~= nil
        end,
        SubDirectory = {
            TagTable = 'lexiftool.Kodak.Type11',
            ProcessProc = false, -- predeclaration, patched below (ProcessKodakPatch)
            ByteOrder = 'LittleEndian',
            Start = function(_et, _val, valuePtr) return valuePtr + 8 end,
            Base = function(_et, _val, start) return start - 8 end,
        },
    },
    {
        Name = 'MakerNoteKodak12',
        -- these maker notes have a 4-byte entry count
        -- - written by the PixPro AZ901 (Note: Make is "JK Imaging, Ltd.", so check Model for "Kodak")
        Condition = function(self, val)
            return matches(self.Model, [[(?i)(Kodak|PixPro)]]) ~= nil and
            matches(perlStr(val), [[(?s)^MM\0\x2a\0\0\0\x08\0\0\0.]]) ~= nil
        end,
        SubDirectory = {
            TagTable = 'lexiftool.Kodak.Type11',
            ProcessProc = false, -- predeclaration, patched below (ProcessKodakPatch)
            ByteOrder = 'BigEndian',
            Start = function(_et, _val, valuePtr) return valuePtr + 8 end,
            Base = function(_et, _val, start) return start - 8 end,
        },
    },
    {
        Name = 'MakerNoteKodakUnknown',
        Condition = function(self, val)
            return matches(self.Make, [[(?i)Kodak]]) ~= nil and matches(perlStr(val), [[^AOC\0]]) == nil
        end,
        NotIFD = 1,
        SubDirectory = {
            TagTable = 'lexiftool.Kodak.Unknown',
            ByteOrder = 'BigEndian',
        },
    },
    {
        Name = 'MakerNoteKyocera',
        -- (starts with "KYOCERA")
        Condition = function(_self, val) return matches(perlStr(val), [[^KYOCERA]]) ~= nil end,
        SubDirectory = {
            TagTable = 'lexiftool.Unknown.Main',
            Start = function(_et, _val, valuePtr) return valuePtr + 22 end,
            Base = function(_et, _val, start) return start + 2 end,
            EntryBased = 1,
            ByteOrder = 'Unknown',
        },
    },
    {
        Name = 'MakerNoteMinolta',
        Condition = function(self, val)
            return matches(self.Make, [[(?i)^(Konica Minolta|Minolta)]]) ~= nil
                and matches(perlStr(val), [[^(MINOL|CAMER|MLY0|KC|\+M\+M|\xd7)]]) == nil
        end,
        SubDirectory = {
            TagTable = 'lexiftool.Minolta.Main',
            ByteOrder = 'Unknown',
        },
    },
    {
        -- the DiMAGE E323 (MINOL) and E500 (CAMER), and some models
        -- of Mustek, Pentax, Ricoh and Vivitar (CAMER).
        Name = 'MakerNoteMinolta2',
        Condition = function(self, val)
            if matches(perlStr(val), [[^(MINOL|CAMER)\0]]) == nil then return false end
            self.OlympusCAMER = 1
            return true
        end,
        SubDirectory = {
            -- these models use Olympus tags in the range 0x200-0x221 plus 0xf00
            TagTable = 'lexiftool.Olympus.Main',
            Start = function(_et, _val, valuePtr) return valuePtr + 8 end,
            ByteOrder = 'Unknown',
        },
    },
    {
        -- /^MLY0/ - DiMAGE G400, G500, G530, G600
        -- /^KC/   - Revio KD-420Z, DiMAGE E203
        -- /^+M+M/ - DiMAGE E201
        -- /^\xd7/ - DiMAGE RD3000
        Name = 'MakerNoteMinolta3',
        Condition = function(self) return matches(self.Make, [[(?i)^(Konica Minolta|Minolta)]]) ~= nil end,
        Binary = 1,
        Notes = 'not EXIF-based',
    },
    {
        Name = 'MakerNoteMotorola',
        Condition = function(_self, val) return matches(perlStr(val), [[^MOT\x00]]) ~= nil end,
        SubDirectory = {
            TagTable = 'lexiftool.Motorola.Main',
            Start = function(_et, _val, valuePtr) return valuePtr + 8 end,
            Base = function(_et, _val, start) return start - 8 end,
            ByteOrder = 'Unknown',
        },
    },
    {
        -- older Nikon maker notes
        Name = 'MakerNoteNikon2',
        Condition = function(_self, val) return matches(perlStr(val), [[^Nikon\x00\x01]]) ~= nil end,
        SubDirectory = {
            TagTable = 'lexiftool.Nikon.Type2',
            Start = function(_et, _val, valuePtr) return valuePtr + 8 end,
            ByteOrder = 'LittleEndian',
        },
    },
    {
        -- headerless Nikon maker notes
        Name = 'MakerNoteNikon3',
        Condition = function(self) return matches(self.Make, [[(?i)^NIKON]]) ~= nil end,
        SubDirectory = {
            TagTable = 'lexiftool.Nikon.Main',
            ByteOrder = 'Unknown', -- most are little-endian, but D1 is big
        },
    },
    {
        Name = 'MakerNoteNintendo',
        -- (starts with an IFD)
        Condition = function(self) return self.Make == 'Nintendo' end,
        SubDirectory = {
            TagTable = 'lexiftool.Nintendo.Main',
            ByteOrder = 'Unknown',
        },
    },
    {
        Name = 'MakerNoteOlympus',
        -- (if Make is 'SEIKO EPSON CORP.', starts with "EPSON\0")
        -- (if Make is 'OLYMPUS OPTICAL CO.,LTD' or 'OLYMPUS CORPORATION',
        --  starts with "OLYMP\0")
        Condition = function(_self, val) return matches(perlStr(val), [[^(OLYMP|EPSON)\x00]]) ~= nil end,
        SubDirectory = {
            TagTable = 'lexiftool.Olympus.Main',
            Start = function(_et, _val, valuePtr) return valuePtr + 8 end,
            ByteOrder = 'Unknown',
        },
    },
    {
        Name = 'MakerNoteOlympus2',
        -- new Olympus maker notes start with "OLYMPUS\0"
        Condition = function(_self, val) return matches(perlStr(val), [[^OLYMPUS\x00]]) ~= nil end,
        SubDirectory = {
            TagTable = 'lexiftool.Olympus.Main',
            Start = function(_et, _val, valuePtr) return valuePtr + 12 end,
            Base = function(_et, _val, start) return start - 12 end,
            ByteOrder = 'Unknown',
        },
    },
    {
        Name = 'MakerNoteOlympus3',
        -- new Olympus maker notes start with "OLYMPUS\0"
        Condition = function(_self, val) return matches(perlStr(val), [[^OM SYSTEM\0]]) ~= nil end,
        SubDirectory = {
            TagTable = 'lexiftool.Olympus.Main',
            Start = function(_et, _val, valuePtr) return valuePtr + 16 end,
            Base = function(_et, _val, start) return start - 16 end,
            ByteOrder = 'Unknown',
        },
    },
    {
        Name = 'MakerNoteLeica',
        -- (starts with "LEICA\0\0\0")
        Condition = function(self) return self.Make == 'LEICA' end,
        SubDirectory = {
            -- many Leica models use the same format as Panasonic
            TagTable = 'lexiftool.Panasonic.Main',
            Start = function(_et, _val, valuePtr) return valuePtr + 8 end,
            ByteOrder = 'Unknown',
        },
    },
    {
        Name = 'MakerNoteLeica2', -- used by the M8
        -- (starts with "LEICA\0\0\0")
        Condition = function(self, valPt)
            return matches(perlStr(self.Make or ''), '^Leica Camera AG') ~= nil
                and matches(valPt or '', [[^LEICA\0\0\0]]) ~= nil
        end,
        SubDirectory = {
            TagTable = 'lexiftool.Panasonic.Leica2',
            -- (the offset base is different in JPEG and DNG images, but we
            -- can copy makernotes from one to the other, so we need special
            -- logic to decide which base to apply)
            ProcessProc = false, -- predeclaration, patched below (FixLeicaBase)
            Start = function(_et, _val, valuePtr) return valuePtr + 8 end,
            Base = function(_et, _val, start) return start end, -- (- 8 for DNG images!)
            ByteOrder = 'Unknown',
        },
    },
    {
        Name = 'MakerNoteLeica3', -- used by the R8 and R9
        -- (starts with IFD)
        Condition = function(self, valPt)
            return matches(perlStr(self.Make or ''), '^Leica Camera AG') ~= nil
                and matches(valPt or '', '^LEICA') == nil
                and self.Model ~= 'S2' and self.Model ~= 'LEICA M (Typ 240)'
        end,
        SubDirectory = {
            TagTable = 'lexiftool.Panasonic.Leica3',
            Start = function(_et, _val, valuePtr) return valuePtr end,
            ByteOrder = 'Unknown',
        },
    },
    {
        Name = 'MakerNoteLeica4', -- used by the M9/M-Monochrom
        -- (M9 and M Monochrom start with "LEICA0\x03\0")
        Condition = function(self, valPt)
            return matches(perlStr(self.Make or ''), '^Leica Camera AG') ~= nil
                and matches(valPt or '', '^LEICA0') ~= nil
        end,
        SubDirectory = {
            TagTable = 'lexiftool.Panasonic.Leica4',
            Start = function(_et, _val, valuePtr) return valuePtr + 8 end,
            Base = function(_et, _val, start) return start - 8 end, -- (yay! Leica fixed the M8 problem)
            ByteOrder = 'Unknown',
        },
    },
    {
        Name = 'MakerNoteLeica5', -- used by the X1/X2/X VARIO/T/X-U
        -- (X1 starts with "LEICA\0\x01\0", Make is "LEICA CAMERA AG")
        -- (X2 starts with "LEICA\0\x05\0", Make is "LEICA CAMERA AG")
        -- (X VARIO starts with "LEICA\0\x04\0", Make is "LEICA CAMERA AG")
        -- (T (Typ 701) starts with "LEICA\0\0x6", Make is "LEICA CAMERA AG")
        -- (X (Typ 113) starts with "LEICA\0\0x7", Make is "LEICA CAMERA AG")
        -- (X-U (Typ 113) starts with "LEICA\0\x10\0", Make is "LEICA CAMERA AG")
        Condition = function(_self, valPt)
            return matches(valPt or '', [[^LEICA\0[\x01\x04\x05\x06\x07\x10\x1a]\0]]) ~= nil
        end,
        SubDirectory = {
            TagTable = 'lexiftool.Panasonic.Leica5',
            Start = function(_et, _val, valuePtr) return valuePtr + 8 end,
            Base = function(_et, _val, start) return start - 8 end,
            ByteOrder = 'Unknown',
        },
    },
    {
        Name = 'MakerNoteLeica6', -- used by the S2, M (Typ 240) and S (Typ 006)
        -- (starts with "LEICA\0\x02\xff", Make is "Leica Camera AG", but test the
        -- model names separately because the maker notes data may not be loaded
        -- at the time this is tested if they are in a JPEG trailer.  Also, this
        -- header is used by the M Monochrom (Type 246), with different offsets.)
        Condition = function(self)
            return self.Make == 'Leica Camera AG' and (self.Model == 'S2' or
                self.Model == 'LEICA M (Typ 240)' or self.Model == 'LEICA S (Typ 006)')
        end,
        DataTag = 'LeicaTrailer',  -- (generates fixup name for this tag)
        LeicaTrailer = 1, -- flag to special-case this tag in the Exif code
        SubDirectory = {
            TagTable = 'lexiftool.Panasonic.Leica6',
            Start = function(_et, _val, valuePtr) return valuePtr + 8 end,
            ByteOrder = 'Unknown',
            -- NOTE: Leica uses absolute file offsets when this maker note is stored
            -- as a JPEG trailer -- this case is handled by ProcessLeicaTrailer in
            -- Panasonic.pm, and any "Base" defined here is ignored for this case.
            -- ExifTool may also create S2/M maker notes inside the APP1 segment when
            -- copying from other files, and for this the normal EXIF offsets are used,
            -- Base should not be defined!
        },
    },
    {
        Name = 'MakerNoteLeica7', -- used by the M Monochrom (Typ 246)
        -- (starts with "LEICA\0\x02\xff", Make is "Leica Camera AG")
        Condition = function(_self, valPt)
            return matches(valPt or '', [[^LEICA\0\x02\xff]]) ~= nil
        end,
        DataTag = 'LeicaTrailer',  -- (generates fixup name for this tag)
        LeicaTrailer = 1, -- flag to special-case this tag in the Exif code
        SubDirectory = {
            TagTable = 'lexiftool.Panasonic.Leica6',
            Start = function(_et, _val, valuePtr) return valuePtr + 8 end,
            ByteOrder = 'Unknown',
            -- uses absolute file offsets (not based on TIFF header offset)
            Base = function(_self, _val, _start, base) return -base end,
        },
    },
    {
        Name = 'MakerNoteLeica8', -- used by the Q (Type 116)
        -- (Q (Typ 116) starts with "LEICA\0\x08\0", Make is "LEICA CAMERA AG")
        -- (SL (Typ 601) and CL start with "LEICA\0\x09\0", Make is "LEICA CAMERA AG")
        Condition = function(_self, valPt)
            return matches(valPt or '', [[^LEICA\0[\x08\x09\x0a]\0]]) ~= nil
        end,
        SubDirectory = {
            TagTable = 'lexiftool.Panasonic.Leica5',
            Start = function(_et, _val, valuePtr) return valuePtr + 8 end,
            ByteOrder = 'Unknown',
        },
    },
    {
        Name = 'MakerNoteLeica9', -- used by the M10/S
        -- (M10 and S start with "LEICA0\x02\0")
        Condition = function(self, valPt)
            return matches(perlStr(self.Make or ''), '^Leica Camera AG') ~= nil
                and matches(valPt or '', [[^LEICA\0\x02\0]]) ~= nil
        end,
        SubDirectory = {
            TagTable = 'lexiftool.Panasonic.Leica9',
            Start = function(_et, _val, valuePtr) return valuePtr + 8 end,
            ByteOrder = 'Unknown',
        },
    },
    {
        Name = 'MakerNoteLeica10', -- used by the D-Lux7
        Condition = function(_self, valPt)
            return matches(valPt or '', [[^LEICA CAMERA AG\0]]) ~= nil
        end,
        SubDirectory = {
            TagTable = 'lexiftool.Panasonic.Main',
            Start = function(_et, _val, valuePtr) return valuePtr + 18 end,
            ByteOrder = 'Unknown',
        },
    },
    {
        Name = 'MakerNotePanasonic',
        -- (starts with "Panasonic\0")
        Condition = function(self, val)
            return matches(perlStr(val), [[^Panasonic]]) ~= nil and self.Model ~= 'DC-FT7'
        end,
        SubDirectory = {
            TagTable = 'lexiftool.Panasonic.Main',
            Start = function(_et, _val, valuePtr) return valuePtr + 12 end,
            ByteOrder = 'Unknown',
        },
    },
    {
        Name = 'MakerNotePanasonic2',
        -- (starts with "Panasonic\0")
        Condition = function(self, valPt)
            return matches(perlStr(self.Make or ''), '^Panasonic') ~= nil
                and matches(valPt or '', '^MKE') ~= nil
        end,
        SubDirectory = {
            TagTable = 'lexiftool.Panasonic.Type2',
            ByteOrder = 'LittleEndian',
        },
    },
    {
        Name = 'MakerNotePanasonic3', -- (DC-FT7)
        -- (starts with "Panasonic\0")
        Condition = function(_self, valPt) return matches(valPt or '', '^Panasonic') ~= nil end,
        SubDirectory = {
            TagTable = 'lexiftool.Panasonic.Main',
            Start = function(_et, _val, valuePtr) return valuePtr + 12 end,
            Base = function(_self, _val, _start) return 12 end, -- crazy!
            ByteOrder = 'Unknown',
        },
    },
    {
        Name = 'MakerNotePentax',
        -- (starts with "AOC\0", but so does MakerNotePentax3)
        -- (also used by some Samsung models)
        Condition = function(self, val)
            return matches(perlStr(val), [[^AOC\x00]]) ~= nil
                and matches(self.Model, [[^PENTAX Optio ?[34]30RS\s*$]]) == nil
        end,
        SubDirectory = {
            TagTable = 'lexiftool.Pentax.Main',
            -- process as Unknown maker notes because the start offset and
            -- byte ordering are so variable
            ProcessProc = false, -- predeclaration, see below for implementation
            -- offsets can be totally whacky for Pentax maker notes,
            -- so attempt to fix the offset base if possible
            FixBase = 1,
            ByteOrder = 'Unknown',
        },
    },
    {
        Name = 'MakerNotePentax2',
        -- (starts with an IFD)
        -- Casio-like maker notes used only by the Optio 330 and 430
        Condition = function(self, val)
            return matches(self.Make, [[^Asahi]]) ~= nil
                and matches(perlStr(val), [[^AOC\x00]]) == nil
        end,
        SubDirectory = {
            TagTable = 'lexiftool.Pentax.Type2',
            ProcessProc = false, -- predeclaration, patched below (ProcessUnknown)
            FixBase = 1,
            ByteOrder = 'Unknown',
        },
    },
    {
        Name = 'MakerNotePentax3',
        -- (starts with "AOC\0", like the more common Pentax maker notes)
        -- Casio maker notes used only by the Optio 330RS and 430RS
        Condition = function(self) return matches(self.Make, [[^Asahi]]) ~= nil end,
        SubDirectory = {
            TagTable = 'lexiftool.Casio.Type2',
            ProcessProc = false, -- predeclaration, patched below (ProcessUnknown)
            FixBase = 1,
            ByteOrder = 'Unknown',
        },
    },
    {
        Name = 'MakerNotePentax4',
        -- (starts with 3 or 4 digits)
        -- HP2-like text-based maker notes used by Optio E20
        Condition = function(self, val)
            return matches(self.Make, [[^PENTAX]]) ~= nil and matches(perlStr(val), [[^\d{3}]]) ~= nil
        end,
        NotIFD = 1,
        SubDirectory = {
            TagTable = 'lexiftool.Pentax.Type4',
            Start = function(_et, _val, valuePtr) return valuePtr end,
            ByteOrder = 'LittleEndian',
        },
    },
    {
        Name = 'MakerNotePentax5',
        -- (starts with "PENTAX \0")
        -- used by cameras such as the Q, Optio S1, RS1500 and WG-1
        Condition = function(_self, val) return matches(perlStr(val), [[^PENTAX \0]]) ~= nil end,
        SubDirectory = {
            TagTable = 'lexiftool.Pentax.Main',
            Start = function(_et, _val, valuePtr) return valuePtr + 10 end,
            Base = function(_et, _val, start) return start - 10 end,
            ByteOrder = 'Unknown',
        },
    },
    {
        Name = 'MakerNotePentax6',
        -- (starts with "S1\0\0\0\0\0\0\x0c\0\0\0")
        Condition = function(_self, val) return matches(perlStr(val), [[^S1\0{6}\x0c\0{3}]]) ~= nil end,
        SubDirectory = {
            TagTable = 'lexiftool.Pentax.S1',
            Start = function(_et, _val, valuePtr) return valuePtr + 12 end,
            Base = function(_et, _val, start) return start - 12 end,
            ByteOrder = 'Unknown',
        },
    },
    {
        Name = 'MakerNotePhaseOne',
        -- Starts with: 'IIIITwaR' or 'IIIICwaR' (have seen both written by P25)
        -- (have also seen code which expects 'MMMMRawT')
        Condition = function(self, val, _format, count)
            if not matches(perlStr(val), [[(?s)^(IIII.waR|MMMMRaw.)]]) then return false end
            if count and count > 1000000 then
                self.TIFF_TYPE = 'IIQ'
                self:OverrideFileType('IIQ')
            end
            return 1
        end,
        NotIFD = 1,
        IsPhaseOne = 1,    -- flag to rebuild these differently
        SubDirectory = { TagTable = 'lexiftool.PhaseOne.Main' },
        PutFirst = 1,      -- place immediately after TIFF header
    },
    {
        Name = 'MakerNoteReconyxHyperFire',
        Condition = function(self, val)
            local ok, c1 = isMatch(perlStr(val), [[^\x01\xf1([\x02\x03]\x00)?]])
            return ok and
                (truthy(c1) or self.Make == 'RECONYX')
        end,
        SubDirectory = {
            TagTable = 'lexiftool.Reconyx.HyperFire',
            ByteOrder = 'Little-endian',
        },
    },
    {
        Name = 'MakerNoteReconyxUltraFire',
        Condition = function(_self, val) return matches(perlStr(val), [[^RECONYXUF\0]]) ~= nil end,
        SubDirectory = {
            TagTable = 'lexiftool.Reconyx.UltraFire',
            ByteOrder = 'Little-endian',
        },
    },
    {
        Name = 'MakerNoteReconyxHyperFire2',
        Condition = function(_self, val) return matches(perlStr(val), [[^RECONYXH2\0]]) ~= nil end,
        SubDirectory = {
            TagTable = 'lexiftool.Reconyx.HyperFire2',
            ByteOrder = 'Little-endian',
        },
    },
    {
        Name = 'MakerNoteReconyxMicroFire',
        Condition = function(_self, val) return matches(perlStr(val), [[^RECONYXMF\0]]) ~= nil end,
        SubDirectory = {
            TagTable = 'lexiftool.Reconyx.MicroFire',
            ByteOrder = 'Little-endian',
        },
    },
    {
        Name = 'MakerNoteReconyxHyperFire4K',
        Condition = function(_self, val) return matches(perlStr(val), [[^RECONYXHF4K\0]]) ~= nil end,
        SubDirectory = {
            TagTable = 'lexiftool.Reconyx.HyperFire4K',
            ByteOrder = 'Little-endian',
        },
    },
    {
        Name = 'MakerNoteRicohPentax',
        -- used by cameras such as the Ricoh GR III
        Condition = function(_self, val) return matches(perlStr(val), [[^RICOH\0(II|MM)]]) ~= nil end,
        SubDirectory = {
            TagTable = 'lexiftool.Pentax.Main',
            Start = function(_et, _val, valuePtr) return valuePtr + 8 end,
            Base = function(_et, _val, start) return start - 8 end,
            ByteOrder = 'Unknown',
        },
    },
    {
        Name = 'MakerNoteRicoh',
        -- (my test R50 image starts with "      \x02\x01" - PH)
        Condition = function(self, val)
            local v = perlStr(val)
            return isMatch(self.Make, [[^(PENTAX )?RICOH]])
                and matches(v, [[(?i)^(Ricoh|      |MM\x00\x2a|II\x2a\x00)]]) ~= nil
                and matches(v, [[(?s)^(MM\x00\x2a\x00\x00\x00\x08\x00.\x00\x00|II\x2a\x00\x08\x00\x00\x00.\x00\x00\x00)]]) == nil
                and self.Model ~= 'RICOH WG-M1'
        end,
        SubDirectory = {
            TagTable = 'lexiftool.Ricoh.Main',
            Start = function(_et, _val, valuePtr) return valuePtr + 8 end,
            ByteOrder = 'Unknown',
        },
    },
    {
        Name = 'MakerNoteRicoh2',
        -- (the Ricoh HZ15 starts with "MM\0\x2a" and the Pentax XG-1 starts with "II\x2a\0",
        -- but an extra 2 bytes of padding after the IFD entry count prevents these from
        -- being processed as a standard IFD.  Note that the offsets for the HZ15 are all
        -- zeros, but they seem to be mostly OK for the XG-1)
        Condition = function(self, val)
            return isMatch(self.Make, [[^(PENTAX )?RICOH]]) and (self.Model == 'RICOH WG-M1' or
                matches(perlStr(val),
                    [[(?s)^(MM\x00\x2a\x00\x00\x00\x08\x00.\x00\x00|II\x2a\x00\x08\x00\x00\x00.\x00\x00\x00)]]) ~= nil)
        end,
        SubDirectory = {
            TagTable = 'lexiftool.Ricoh.Type2',
            Start = function(_et, _val, valuePtr) return valuePtr + 8 end,
            Base = function(_et, _val, start) return start - 8 end,
            ByteOrder = 'Unknown',
            ProcessProc = false, -- predeclaration, patched below (ProcessKodakPatch)
        },
    },
    {
        Name = 'MakerNoteRicohText',
        Condition = function(self) return matches(self.Make, [[^RICOH]]) ~= nil end,
        NotIFD = 1,
        SubDirectory = {
            TagTable = 'lexiftool.Ricoh.Text',
            ByteOrder = 'Unknown',
        },
    },
    {
        Name = 'MakerNoteSamsung1a',
        -- Samsung STMN maker notes WITHOUT PreviewImage
        Condition = function(_self, valPt)
            return matches(valPt or '', [[(?s)^STMN\d{3}.\0{4}]]) ~= nil
        end,
        Binary = 1,
        Notes = 'Samsung "STMN" maker notes without PreviewImage',
    },
    {
        Name = 'MakerNoteSamsung1b',
        -- Samsung STMN maker notes WITH PreviewImage
        Condition = function(_self, valPt) return matches(valPt or '', [[^STMN\d{3}]]) ~= nil end,
        SubDirectory = {
            TagTable = 'lexiftool.Samsung.Main',
        },
    },
    {
        Name = 'MakerNoteSamsung2',
        -- Samsung EXIF-format maker notes (
        Condition = function(self, valPt)
            return uc(self.Make or '') == 'SAMSUNG' and (self.TIFF_TYPE == 'SRW' or
                matches(valPt or '',
                    [[(?s)^(\0.\0\x01\0\x07\0{3}\x04|.\0\x01\0\x07\0\x04\0{3})0100]]) ~= nil)
        end,
        SubDirectory = {
            TagTable = 'lexiftool.Samsung.Type2',
            -- Samsung is very inconsistent here, and uses absolute offsets for some
            -- models and relative offsets for others, so process as Unknown
            ProcessProc = false, -- predeclaration, patched below (ProcessUnknown)
            FixBase = 1,
            ByteOrder = 'Unknown',
        },
    },
    {
        Name = 'MakerNoteSanyo',
        -- (starts with "SANYO\0")
        Condition = function(self)
            return matches(self.Make, [[^SANYO]]) ~= nil and matches(self.Model, [[^(C4|J\d|S\d)\b]]) == nil
        end,
        SubDirectory = {
            TagTable = 'lexiftool.Sanyo.Main',
            Validate = function(_et, val) return matches(perlStr(val), [[^SANYO]]) ~= nil end,
            Start = function(_et, _val, valuePtr) return valuePtr + 8 end,
            ByteOrder = 'Unknown',
        },
    },
    {
        Name = 'MakerNoteSanyoC4',
        -- The C4 offsets are wrong by 12, so they must be fixed
        Condition = function(self) return matches(self.Make, [[^SANYO]]) ~= nil and matches(self.Model, [[^C4\b]]) ~= nil end,
        SubDirectory = {
            TagTable = 'lexiftool.Sanyo.Main',
            Validate = function(_et, val) return matches(perlStr(val), [[^SANYO]]) ~= nil end,
            Start = function(_et, _val, valuePtr) return valuePtr + 8 end,
            FixBase = 1,
            ByteOrder = 'Unknown',
        },
    },
    {
        Name = 'MakerNoteSanyoPatch',
        -- The J1, J2, J4, S1, S3 and S4 offsets are completely screwy
        Condition = function(self) return matches(self.Make, [[^SANYO]]) ~= nil end,
        SubDirectory = {
            TagTable = 'lexiftool.Sanyo.Main',
            Validate = function(_et, val) return matches(perlStr(val), [[^SANYO]]) ~= nil end,
            Start = function(_et, _val, valuePtr) return valuePtr + 8 end,
            ByteOrder = 'Unknown',
            FixOffsets = function(valuePtr, valEnd, size, tagID, wFlag)
                return require('lexiftool.Sanyo').FixOffsets(valuePtr, valEnd, size, tagID, wFlag)
            end,
        },
    },
    {
        Name = 'MakerNoteSigma',
        Condition = function(self, val)
            if matches(self.Make, [[(?i)^(SIGMA|FOVEON)]]) == nil then return false end
            -- save version number in "MakerNoteSigmaVer" member variable
            -- (upstream side effect; not read by any tag this port's
            -- current Sigma.Main subset needs, kept for parity/future use)
            local ver = matches(perlStr(val), [[^SIGMA\x00\x00\x00.(.)]])
            self.MakerNoteSigmaVer = ver and ver:byte(1) or -1
            return true
        end,
        SubDirectory = {
            TagTable = 'lexiftool.Sigma.Main',
            Validate = function(_et, val) return matches(perlStr(val), [[^(SIGMA|FOVEON)]]) ~= nil end,
            Start = function(_et, _val, valuePtr) return valuePtr + 10 end,
            ByteOrder = 'Unknown',
        },
    },
    {
        Name = 'MakerNoteSony',
        -- (starts with "SONY DSC \0" or "SONY CAM \0")
        -- (TF1 starts with "\0\0SONY PIC\0")
        -- (Hasselblad models start with "VHAB     \0")
        Condition = function(_self, val)
            return matches(perlStr(val), [[^(SONY (DSC|CAM|MOBILE)|\x00\x00SONY PIC\x00|VHAB     \x00)]]) ~= nil
        end,
        SubDirectory = {
            TagTable = 'lexiftool.Sony.Main',
            Start = function(_et, _val, valuePtr) return valuePtr + 12 end,
            ByteOrder = 'Unknown',
        },
    },
    {
        Name = 'MakerNoteSony2',
        -- (starts with "SONY PI\0" -- DSC-S650/S700/S750)
        Condition = function(self, val)
            if matches(perlStr(val), [[^SONY PI\0]]) == nil then return false end
            self.OlympusCAMER = 1
            return true
        end,
        SubDirectory = {
            TagTable = 'lexiftool.Olympus.Main',
            Start = function(_et, _val, valuePtr) return valuePtr + 12 end,
            ByteOrder = 'Unknown',
        },
    },
    {
        Name = 'MakerNoteSony3',
        -- (starts with "PREMI\0" -- DSC-S45/S500)
        Condition = function(self, val)
            if matches(perlStr(val), [[^(PREMI)\0]]) == nil then return false end
            self.OlympusCAMER = 1
            return true
        end,
        SubDirectory = {
            TagTable = 'lexiftool.Olympus.Main',
            Start = function(_et, _val, valuePtr) return valuePtr + 8 end,
            ByteOrder = 'Unknown',
        },
    },
    {
        Name = 'MakerNoteSony4',
        -- (starts with "SONY PIC\0" -- DSC-H200/J20/W370/W510, MHS-TS20)
        Condition = function(_self, val) return matches(perlStr(val), [[^SONY PIC\0]]) ~= nil end,
        SubDirectory = { TagTable = 'lexiftool.Sony.PIC' },
    },
    {
        Name = 'MakerNoteSony5', -- used in SR2 and ARW images
        Condition = function(self, val) -- luacheck: ignore 314 (duplicate key, as upstream: the next one wins)
            return matches(self.Make, [[^SONY]]) ~= nil and matches(perlStr(val), [[^\x01\x00]]) == nil
        end,
        Condition = function(self, val)
            return (matches(self.Make, [[^SONY]]) ~= nil or (matches(self.Make, [[^HASSELBLAD]]) ~= nil and
            matches(self.Model, [[^(HV|Stellar|Lusso|Lunar)]]) ~= nil)) and matches(perlStr(val), [[^\x01\x00]]) == nil
        end,
        SubDirectory = {
            TagTable = 'lexiftool.Sony.Main',
            Start = function(_et, _val, valuePtr) return valuePtr end,
            ByteOrder = 'Unknown',
        },
    },
    {
        Name = 'MakerNoteSonyEricsson',
        Condition = function(_self, val) return matches(perlStr(val), [[^SEMC MS\0]]) ~= nil end,
        SubDirectory = {
            TagTable = 'lexiftool.Sony.Ericsson',
            Start = function(_et, _val, valuePtr) return valuePtr + 20 end,
            Base = function(_et, _val, start) return start - 8 end,
            ByteOrder = 'Unknown',
        },
    },
    {
        Name = 'MakerNoteSonySRF',
        Condition = function(self) return matches(self.Make, [[^SONY]]) ~= nil end,
        SubDirectory = {
            TagTable = 'lexiftool.Sony.SRF',
            Start = function(_et, _val, valuePtr) return valuePtr end,
            ByteOrder = 'Unknown',
        },
    },
    {
        Name = 'MakerNoteUnknownText',
        Condition = function(_self, val)
            return matches(perlStr(val), [[^[\x09\x0d\x0a\x20-\x7e]+\0*$]]) ~= nil
        end,
        Notes = 'unknown text-based maker notes',
        -- show as binary if it is too long
        ValueConv = function(_self, val)
            if length(val) > 64 then return { ref = 'SCALAR', value = val } end
            return val
        end,
        ValueConvInv = function(_self, val) return val end,
    },
    {
        Name = 'MakerNoteUnknownBinary',
        -- "LSI1\0" - SilverFast
        Condition = function(_self, val)
            return matches(perlStr(val), [[^LSI1\0]]) ~= nil
        end,
        Notes = 'unknown binary maker notes',
        Binary = 1,
    },
    {
        Name = 'MakerNoteUnknown',
        PossiblePreview = 1,
        SubDirectory = {
            TagTable = 'lexiftool.Unknown.Main',
            ProcessProc = false, -- predeclaration, patched below (ProcessUnknownOrPreview)
            WriteProc = false, -- predeclaration, patched below (WriteUnknownOrPreview)
            ByteOrder = 'Unknown',
            FixBase = 2,
        },
    },
}

-- insert writable properties so we can write our maker notes
for _, tagInfo in ipairs(MakerNotes.Main) do
    tagInfo.Writable = 'undef'
    tagInfo.Format = 'undef' -- (make sure we don't convert this when reading)
    tagInfo.WriteGroup = 'ExifIFD'
    tagInfo.Groups = { [1] = 'MakerNotes' }
    if tagInfo.SubDirectory then
        -- make all SubDirectory tags block-writable
        tagInfo.Binary = 1
        tagInfo.MakerNotes = 1
    end
end

-- byte sizes for the various EXIF format types (duplicated from
-- Exif.formatSize -- requiring lexiftool.Exif here would be circular,
-- since Exif.lua requires lexiftool.MakerNotes at load time)
local formatSize = { 1,1,2,4,8,1,1,2,4,8,4,8,4,2,8,8,8,8 }

--------------------------------------------------------------------------------
-- Get normal offset of value data from end of maker note IFD
-- Inputs: 0) ExifTool object reference
-- Returns: Array: 0) relative flag (undef for no change)
--                 1) normal offset from end of IFD to first value (empty if unknown)
--                 2-N) other possible offsets used by some models
-- Notes: Directory size should be validated before calling this routine
-- (port: the offsets come back as a list table in the second result)
function MakerNotes.GetMakerNoteOffset(et)
    -- figure out where we expect the value data based on camera type
    local make = et.Make
    local model = et.Model
    local relative
    local offsets = { }
    local function push(...) for _, v in ipairs({ ... }) do offsets[#offsets + 1] = v end end

    -- normally value data starts 4 bytes after end of directory, so this is the default.
    -- offsets of 0 and 4 are always allowed even if not specified,
    -- but the first offset specified is the one used when writing
    if isMatch(make, [[^Canon]]) then
        push(isMatch(model, [[\b(20D|350D|REBEL XT|Kiss Digital N)\b]]) and 6 or 4)
        -- some Canon models (FV-M30, Optura50, Optura60) leave 24 unused bytes
        -- at the end of the IFD (2 spare IFD entries?)
        if isMatch(model, [[\b(FV\b|OPTURA)]]) then push(28) end
        -- some Canon PowerShot models leave 12 unused bytes
        if isMatch(model, [[(PowerShot|IXUS|IXY)]]) then push(16) end
    elseif isMatch(make, [[^CASIO]]) then
        -- Casio AVI and MOV images use no padding, and their JPEG's use 4,
        -- except some models like the EX-S770,Z65,Z70,Z75 and Z700 which use 16,
        -- and the EX-Z35 which uses 2 (grrrr...)
        if isMatch(et.FILE_TYPE, [[^(RIFF|MOV)$]]) then push(0) else push(4, 16, 2) end
    elseif isMatch(make, [[(?i)^(General Imaging Co.|GEDSC IMAGING CORP.)]]) then
        push(0)
    elseif isMatch(make, [[^KYOCERA]]) then
        push(12)
    elseif isMatch(make, [[^Leica Camera AG]]) then
        if model == 'S2' then
            -- lots of empty space before first value in S2 images
            push(4, (et.FILE_TYPE == 'JPEG' and 286 or 274))
        elseif model == 'LEICA M MONOCHROM (Typ 246)' then
            push(4, 130)
        elseif model == 'LEICA M (Typ 240)' then
            push(4, 118)
        elseif isMatch(model, [[^(R8|R9|M8)\b]]) then
            push(6)
        else
            push(4)
        end
    elseif isMatch(make, [[^OLYMPUS]]) and isMatch(model, [[^E-(1|300|330)\b]]) then
        push(16)
    elseif isMatch(make, [[^OLYMPUS]]) and
        -- these Olympus models are just weird
        isMatch(model, [[^(C2500L|C-1Z?|C-5000Z|X-2|C720UZ|C725UZ|C150|C2Z|E-10|E-20|FerrariMODEL2003|u20D|u10D)\b]])
    then
        -- no expected offset --> determine offset empirically via FixBase()
        local _ = nil
    elseif isMatch(make, [[^(Panasonic|JVC)\b]]) then
        push(0)
    elseif isMatch(make, [[^SONY]]) then
        -- earlier DSLR and "PREMI" models use an offset of 4
        if isMatch(model, [[^(DSLR-.*|SLT-A(33|35|55V)|NEX-(3|5|C3|VG10E))$]]) or
            truthy(et.OlympusCAMER)
        then
            push(4)
        else
            push(0)
        end
    elseif et.TIFF_TYPE == 'SRW' and make == 'SAMSUNG' and model == 'EK-GN120' then
        push(40)  -- patch to read most of the maker notes, but breaks PreviewIFD
    elseif make == 'FUJIFILM' then
        -- some models have offset of 6, so allow that too (A345,A350,A360,A370)
        push(4, 6)
    elseif isMatch(make, [[^TOSHIBA]]) then
        -- similar to Canon, can also have 24 bytes of padding
        push(0, 24)
    elseif isMatch(make, [[^PENTAX]]) then
        push(4)
        -- the Pentax addressing mode is determined automatically, but
        -- sometimes the algorithm gets it wrong, but Pentax always uses
        -- absolute addressing, so force it to be absolute
        relative = 0
    elseif isMatch(make, [[(?i)^Konica Minolta]]) then
        -- patch for DiMAGE X50, Xg, Z2 and Z10
        push(4, -16)
    elseif isMatch(make, [[^Minolta]]) then
        -- patch for DiMAGE 7, X20 and Z1
        push(4, -8, -12)
    else
        push(4)   -- the normal offset
    end
    return relative, offsets
end

--------------------------------------------------------------------------------
-- Get hash of value offsets / block sizes
-- Inputs: 0) ExifTool object reference (for Get16u/Get32u), 1) Data pointer,
--         2) offset to start of directory, 3) hash ref to return value
--         pointers based on tag ID
-- Returns: 0) hash reference: keys are offsets, values are block sizes
--          1) same thing, but with keys adjusted for value-based offsets
-- Notes: Directory size should be validated before calling this routine
-- - calculates MIN and MAX offsets in entry-based hash
function MakerNotes.GetValueBlocks(et, dataPt, dirStart, tagPtr)
    local numEntries = et.Get16u(dataPt, dirStart) or 0
    local valBlock, valBlkAdj = {}, {}
    for index = 0, numEntries - 1 do
        local entry = dirStart + 2 + 12 * index
        local format = et.Get16u(dataPt, entry + 2)
        if not format or format < 1 or format > 13 then break end
        local count = et.Get32u(dataPt, entry + 4) or 0
        local size = count * (formatSize[format] or 1)
        if size > 4 then
            local valPtr = et.Get32u(dataPt, entry + 8) or 0
            if tagPtr then tagPtr[et.Get16u(dataPt, entry)] = valPtr end
            -- save location and size of longest block at this offset
            if not (valBlock[valPtr] and valBlock[valPtr] > size) then
                valBlock[valPtr] = size
            end
            -- adjust for case of value-based offsets
            valPtr = valPtr + 12 * index
            if not (valBlkAdj[valPtr] and valBlkAdj[valPtr] > size) then
                valBlkAdj[valPtr] = size
                local endPos = valPtr + size
                if valBlkAdj.MIN then
                    -- save minimum only if it has a value of 12 or greater
                    if valBlkAdj.MIN < 12 or valBlkAdj.MIN > valPtr then valBlkAdj.MIN = valPtr end
                    if valBlkAdj.MAX > endPos then valBlkAdj.MAX = endPos end
                else
                    valBlkAdj.MIN = valPtr
                    valBlkAdj.MAX = endPos
                end
            end
        end
    end
    return valBlock, valBlkAdj
end

--------------------------------------------------------------------------------
-- Fix base offset for value offsets in maker notes IFD (if necessary)
-- Inputs: 0) ExifTool object ref, 1) DirInfo hash ref
-- Return: amount of base shift (and dirInfo Base and DataPos are updated,
--         FixedBy is set if offsets fixed, and Relative or EntryBased may be set)
-- (port: upstream's $debug printouts -- a development aid switched on by
--  editing the source -- are left out)
function MakerNotes.FixBase(et, dirInfo)
    -- don't fix base if fixing offsets individually or if we don't want to fix them
    if dirInfo.FixOffsets or dirInfo.NoFixBase then return 0 end

    local dataPt = dirInfo.DataPt
    local dataPos = dirInfo.DataPos or 0
    local dirStart = dirInfo.DirStart or 0
    local entryBased = dirInfo.EntryBased
    local dirName = dirInfo.DirName
    local fixBase = et:Options('FixBase')
    local setBase = (fixBase ~= nil and perlStr(fixBase) ~= '') and 1 or 0
    local fix, fixedBy
    local tagPtr = {}

    -- get hash of value block positions
    local valBlock, valBlkAdj = MakerNotes.GetValueBlocks(et, dataPt, dirStart, tagPtr)
    local valPtrs = {}
    for k in pairs(valBlock) do valPtrs[#valPtrs + 1] = k end
    if #valPtrs == 0 then return 0 end
    tsort(valPtrs)
--
-- handle special case of Canon maker notes with TIFF footer containing original offset
--
    if matches(et.Make, [[^Canon]]) ~= nil and (dirInfo.DirLen or 0) > 8 then
        local footerPos = dirStart + dirInfo.DirLen - 8
        local footer = substr(dataPt, footerPos, 8)
        if matches(footer, [[^(II\x2a\0|MM\0\x2a)]]) ~= nil and -- check for TIFF footer
           substr(footer, 0, 2) == ExifTool.GetByteOrder() -- validate byte ordering
        then
            local oldOffset = et.Get32u(footer, 4) or 0
            local newOffset = dirStart + dataPos
            if setBase ~= 0 then
                fix = fixBase
            else
                fix = newOffset - oldOffset
                if fix == 0 then return 0 end
                -- Picasa and ACDSee have a bug where they update other offsets without
                -- updating the TIFF footer (PH - 2009/02/25), so test for this case:
                -- validate Canon maker note footer fix by checking offset of last value
                local maxPt = valPtrs[#valPtrs] + valBlock[valPtrs[#valPtrs]]
                -- compare to end of maker notes, taking 8-byte footer into account
                local endDiff = dirStart + dirInfo.DirLen - (maxPt - dataPos) - 8
                -- ignore footer offset only if end difference is exactly correct
                -- (allow for possible padding byte, although I have never seen this)
                if endDiff == 0 or endDiff == 1 then
                    et:Warn('Canon maker note footer may be invalid (ignored)', 1)
                    return 0
                end
            end
            et:Warn('Adjusted ' .. perlStr(dirName) .. ' base by ' .. perlStr(fix), 1)
            dirInfo.FixedBy = fix
            dirInfo.Base = (dirInfo.Base or 0) + perlNum(fix, '+')
            dirInfo.DataPos = (dirInfo.DataPos or 0) - perlNum(fix, '-')
            return fix
        end
    end
--
-- analyze value offsets to see if they need fixing.  The first task is to determine
-- the minimum valid offset used (this is tricky, because we have to weed out bad
-- offsets written by some cameras)
--
    local minPt = valPtrs[1] -- if life were simple, this would be it
    dirInfo.MinOffset = minPt
    local ifdLen = 2 + 12 * (et.Get16u(dataPt, dirStart) or 0)
    local ifdEnd = dirStart + ifdLen
    local relative, offsets = MakerNotes.GetMakerNoteOffset(et)
    local makeDiff = offsets[1]
    local diff, shift

    -- calculate expected minimum value offset
    local expected = dataPos + ifdEnd + (makeDiff ~= nil and makeDiff or 4)

    -- zero our counters
    local countNeg12, countZero, countOverlap = 0, 0, 0
    local last
    for _, valPtr in ipairs(valPtrs) do
        if last ~= nil then
            local gap = valPtr - last
            if gap == 0 or gap == 1 then
                countZero = countZero + 1
            elseif gap == -12 and not entryBased then
                -- you get this when value offsets are relative to the IFD entry
                countNeg12 = countNeg12 + 1
            elseif gap < 0 then
                -- any other negative difference indicates overlapping values
                if valPtr ~= 0 then countOverlap = countOverlap + 1 end -- (but ignore zero value pointers)
            elseif gap >= ifdLen then
                -- ignore previous minimum if we took a jump to near the expected value
                -- (some values can be stored before the IFD)
                if math.abs(valPtr - expected) <= 4 then minPt = valPtr end
            end
            -- an offset less than 12 is surely garbage, so ignore it
            if minPt < 12 then minPt = valPtr end
        end
        last = valPtr + valBlock[valPtr]
    end
    -- could this IFD be using entry-based offsets?
    if ((countNeg12 > countZero and (valBlkAdj.MIN or 0) >= ifdLen - 2) or
        (valBlkAdj.MIN == ifdLen - 2 or valBlkAdj.MIN == ifdLen + 2)) and
        (valBlkAdj.MAX or 0) <= (dirInfo.DirLen or 0) - 2
    then
        -- looks like these offsets are entry-based, so use the offsets
        -- which have been correcting for individual entry position
        entryBased = 1
        if truthy(et:Options('Verbose')) then
            et:Warn(perlStr(dirName) .. ' offsets are entry-based', 1)
        end
    else
        -- calculate offset difference from end of IFD to first value
        diff = (minPt - dataPos) - ifdEnd
        shift = 0
        if countOverlap > 0 then et:Warn('Overlapping ' .. perlStr(dirName) .. ' values', 1) end
        if entryBased then
            et:Warn(perlStr(dirName) .. ' offsets do NOT look entry-based', 1)
            entryBased = nil
            relative = nil
        end
        -- use PrintIM tag to do special check for correct absolute offsets
        if tagPtr[0xe00] then
            local ptr = tagPtr[0xe00] - dataPos
            if ptr > 0 and ptr <= #dataPt - 8 and substr(dataPt, ptr, 8) == 'PrintIM\0' then
                return 0
            end
        end
        -- allow a range of reasonable differences for Unknown maker notes
        if dirInfo.FixBase and dirInfo.FixBase == 2 then
            if diff >= 0 and diff <= 24 then return 0 end
        end
    end
--
-- handle entry-based offsets
--
    if entryBased then
        -- most of my entry-based samples have first value immediately
        -- after last IFD entry (ie. no padding or next IFD pointer)
        makeDiff = 0
        offsets[#offsets + 1] = 4 -- but some do have a next IFD pointer
        -- corrected entry-based offsets are relative to start of first entry
        local expectedEB = 12 * (et.Get16u(dataPt, dirStart) or 0)
        diff = (valBlkAdj.MIN or 0) - expectedEB
        -- set up directory to read values with entry-based offsets
        -- (ignore everything and set base to start of first entry)
        shift = dataPos + dirStart + 2
        dirInfo.Base = (dirInfo.Base or 0) + shift
        dirInfo.DataPos = (dirInfo.DataPos or 0) - shift
        dirInfo.EntryBased = 1
        dirInfo.Relative = 1 -- entry-based offsets are relative
        dirInfo.FixBase = nil -- no automatic base fix
        if setBase == 0 then fixBase = nil end
    end
--
-- return without doing shift if offsets look OK
--
    if setBase == 0 then
        -- don't try to fix offsets for whacky cameras
        if makeDiff == nil then return shift or 0 end
        -- normal value data starts 4 bytes after IFD, but allow 0 or 4...
        if diff == 0 or diff == 4 then return shift or 0 end
        -- also check for allowed make-specific differences
        for _, o in ipairs(offsets) do
            if diff == o then return shift or 0 end
        end
    end
--
-- apply the fix, or issue a warning
--
    -- use default padding of 4 bytes unless already specified
    if makeDiff == nil then makeDiff = 4 end
    fix = makeDiff - diff -- assume standard diff for this make

    if dirInfo.FixBase then
        -- set flag if offsets are relative (base is at or above directory start)
        if dataPos - fix + dirStart <= 0 then
            dirInfo.Relative = relative ~= nil and relative or 1
        end
        if setBase ~= 0 then
            fixedBy = fixBase
            fix = fix + perlNum(fixBase, '+')
        end
    elseif fixBase ~= nil then
        if perlStr(fixBase) ~= '' then fix = fixBase end
        fixedBy = fix
    else
        -- print warning unless difference looks reasonable
        if diff < 0 or diff > 16 or (diff & 0x01) ~= 0 then
            et:Warn('Possibly incorrect maker notes offsets (fix by ' .. perlStr(fix) .. '?)', 1)
        end
        -- don't do the fix (but we already adjusted base if entry-based)
        return shift or 0
    end
    if fixedBy ~= nil then
        et:Warn('Adjusted ' .. perlStr(dirName) .. ' base by ' .. perlStr(fixedBy), 1)
        dirInfo.FixedBy = fixedBy
    end
    dirInfo.Base = (dirInfo.Base or 0) + perlNum(fix, '+')
    dirInfo.DataPos = (dirInfo.DataPos or 0) - perlNum(fix, '-')
    return perlNum(fix, '+') + (shift or 0)
end

--------------------------------------------------------------------------------
-- Find start of IFD in unknown maker notes
-- Inputs: 0) ExifTool object ref, 1) reference to directory information
-- Returns: offset to IFD on success, undefined otherwise
-- - dirInfo may contain TagInfo reference for tag associated with directory
-- - on success, updates DirStart, DirLen, Base and DataPos in dirInfo
-- - also sets Relative flag in dirInfo if offsets are relative to IFD
-- Note: Changes byte ordering!
-- (port: upstream tests `$$subdir{Base} =~ /\$start\b/` on the eval string;
--  the ported Base is a function($self, $val, $start) that uses $start
--  exactly when its third parameter is named, ie. not '_'-prefixed)
local function baseUsesStart(baseProc)
    if type(baseProc) ~= 'function' then return false end
    local pname = debug.getlocal(baseProc, 3)
    return pname ~= nil and pname:sub(1, 1) ~= '_'
end
function MakerNotes.LocateIFD(et, dirInfo)
    local dataPt = dirInfo.DataPt
    local dirStart = dirInfo.DirStart or 0
    -- (ignore MakerNotes DirLen since sometimes this is incorrect)
    local size = dirInfo.DataLen - dirStart
    local dirLen = dirInfo.DirLen ~= nil and dirInfo.DirLen or size
    local tagInfo = dirInfo.TagInfo
    local ifdOffsetPos
    -- the IFD should be within the first 32 bytes
    -- (Kyocera sets the current record at 22 bytes)
    local firstTry, lastTry = 0, 32

    -- make sure Base and DataPos are defined
    if not truthy(dirInfo.Base) then dirInfo.Base = 0 end
    if not truthy(dirInfo.DataPos) then dirInfo.DataPos = 0 end
--
-- use tag information (if provided) to determine directory location
--
    if tagInfo and tagInfo.SubDirectory then
        local subdir = tagInfo.SubDirectory
        if not (subdir.ProcessProc and
               (subdir.ProcessProc == MakerNotes.ProcessUnknown or
                subdir.ProcessProc == MakerNotes.ProcessUnknownOrPreview))
        then
            -- look for the IFD at the "Start" specified in our SubDirectory information
            local valuePtr = dirStart
            local newStart = dirStart
            if subdir.Start ~= nil then
                --### eval Start ($valuePtr)
                newStart = subdir.Start(et, nil, valuePtr)
            end
            if subdir.Base then
                -- calculate subdirectory start relative to $base for eval
                local start = newStart + dirInfo.DataPos
                local base = dirInfo.Base or 0
                --### eval Base ($start,$base)
                local baseShift = subdir.Base(et, nil, start, base)
                -- shift directory base (note: we may do this again below
                -- if an OffsetPt is defined, but that doesn't matter since
                -- the base shift is relative to DataPos, which we set too)
                dirInfo.Base = dirInfo.Base + baseShift
                dirInfo.DataPos = dirInfo.DataPos - baseShift
                -- this is a relative directory if Base depends on $start
                if baseUsesStart(subdir.Base) then
                    dirInfo.Relative = 1
                    -- hack to fix Leica quirk
                    if subdir.ProcessProc and subdir.ProcessProc == MakerNotes.FixLeicaBase then
                        local oldStart = dirInfo.DirStart
                        dirInfo.DirStart = newStart
                        MakerNotes.FixLeicaBase(et, dirInfo)
                        dirInfo.DirStart = oldStart
                    end
                end
            end
            -- add offset to the start of the directory if necessary
            if subdir.OffsetPt then
                if isMatch(subdir.ByteOrder, '(?i)^Little') then
                    et.SetByteOrder('II')
                elseif isMatch(subdir.ByteOrder, '(?i)^Big') then
                    et.SetByteOrder('MM')
                else
                    require('lexiftool.perl').warn("Can't have variable byte ordering for SubDirectories using OffsetPt\n")
                    return nil
                end
                --### eval OffsetPt ($valuePtr)
                ifdOffsetPos = subdir.OffsetPt(et, nil, valuePtr) - dirStart
            end
            -- pinpoint position to look for this IFD
            firstTry = newStart - dirStart
            lastTry = firstTry
        end
    end
--
-- scan for something that looks like an IFD
--
    if dirLen >= 14 + firstTry then  -- minimum size for an IFD
        local offset = firstTry
        while offset <= lastTry do -- IFD_TRY:
            if offset + 14 > dirLen then break end    -- 14 bytes is minimum size for an IFD
            local pos = dirStart + offset
--
-- look for a standard TIFF header (Nikon uses it, others may as well),
--
            if et.SetByteOrder(substr(dataPt, pos, 2)) and
                et.Get16u(dataPt, pos + 2) == 0x2a
            then
                ifdOffsetPos = 4
            end
            if ifdOffsetPos ~= nil then
                -- get pointer to IFD
                local ptr = et.Get32u(dataPt, pos + ifdOffsetPos)
                if ptr >= ifdOffsetPos + 4 and ptr + offset + 14 <= dirLen then
                    -- shift directory start and shorten dirLen accordingly
                    dirInfo.DirStart = dirInfo.DirStart + ptr + offset
                    dirInfo.DirLen = dirInfo.DirLen - (ptr + offset)
                    -- shift pointer base to the start of the TIFF header
                    local shift = dirInfo.DataPos + dirStart + offset
                    dirInfo.Base = dirInfo.Base + shift
                    dirInfo.DataPos = dirInfo.DataPos - shift
                    dirInfo.Relative = 1   -- set "relative offsets" flag
                    return ptr + offset
                end
                ifdOffsetPos = nil
            end
--
-- look for a standard IFD (starts with 2-byte entry count)
--
            do
                local num = et.Get16u(dataPt, pos)
                if not truthy(num) then goto next_try end
                -- number of entries in an IFD should be between 1 and 255
                if (num & 0xff) == 0 then
                    -- lower byte is zero -- byte order could be wrong
                    et.ToggleByteOrder()
                    num = num >> 8
                elseif (num & 0xff00) ~= 0 then
                    -- upper byte isn't zero -- not an IFD
                    goto next_try
                end
                local bytesFromEnd = size - (offset + 2 + 12 * num)
                if bytesFromEnd < 4 then
                    if not (bytesFromEnd == 2 or bytesFromEnd == 0) then goto next_try end
                end
                -- do a quick validation of all format types
                local index = 0
                while index < num do
                    local entry = pos + 2 + 12 * index
                    local format = et.Get16u(dataPt, entry+2)
                    local count = et.Get32u(dataPt, entry+4)
                    if not truthy(format) then
                        -- patch for buggy Samsung NX200 JPEG MakerNotes entry count
                        if num == 23 and index == 21 and et.Make == 'SAMSUNG' then
                            -- (port: Lua strings are immutable -- the patched
                            --  count goes into the caller's DataPt)
                            dataPt = substr(dataPt, 0, pos) .. et.Put16u(21) .. substr(dataPt, pos + 2)
                            dirInfo.DataPt = dataPt  -- really 21 IFD entries!
                            et:Warn('Fixed incorrect Makernote entry count', 1)
                            break
                        end
                        -- allow everything to be zero if not first entry
                        -- because some manufacturers pad with null entries
                        if not (truthy(count) or index == 0) then goto next_entry end
                        -- patch for Canon EOS 40D firmware 1.0.4 bug: allow zero format for last entry
                        if index==num-1 and isMatch(et.Model, 'EOS 40D') then goto next_entry end
                    end
                    -- patch for Sony cameras like the DSC-P10 that have invalid MakerNote entries
                    if num == 12 and et.Make == 'SONY' and index >= 8 then goto next_entry end
                    -- patch for Apple ProRaw DNG which uses format 16 in the maker notes
                    if format == 16 and et.Make == 'Apple' then goto next_entry end
                    -- (would like to verify tag ID, but some manufactures don't
                    --  sort entries in order of tag ID so we don't have much of
                    --  a handle to verify this field)
                    -- verify format
                    if format < 1 or format > 13 then goto next_try end
                    -- count must be reasonable (can't test for zero count because
                    -- cameras like the 1DmkIII use this value)
                    if (count & 0xff000000) ~= 0 then goto next_try end
                    -- extra tests to avoid mis-identifying Samsung makernotes (GT-I9000, etc)
                    if num ~= 1 then goto next_entry end
                    do
                        local valueSize = count * require('lexiftool.Exif').formatSize[format]
                        if valueSize > 4 then
                            if valueSize > size then goto next_try end
                            local valuePtr = et.Get32u(dataPt, entry+8)
                            if valuePtr > 0x10000 then goto next_try end
                        end
                    end
                    ::next_entry::
                    index = index + 1
                end
                dirInfo.DirStart = dirInfo.DirStart + offset    -- update directory start
                dirInfo.DirLen = dirInfo.DirLen - offset
                return offset   -- success!!
            end
            ::next_try::
            offset = offset + 2
        end
    end
    return nil
end

--------------------------------------------------------------------------------
-- Fix base offset for Leica maker notes
-- Inputs: 0) ExifTool ref, 1) dirInfo ref, 2) optional tag table ref
-- Returns: 1 on success
function MakerNotes.FixLeicaBase(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    local dirStart = dirInfo.DirStart or 0
    -- get hash of value block positions
    local valBlock = MakerNotes.GetValueBlocks(ExifTool, dataPt, dirStart)
    if next(valBlock) then
        -- get sorted list of value offsets
        local valPtrs = {}
        for k in pairs(valBlock) do valPtrs[#valPtrs + 1] = k end
        tsort(valPtrs)
        local numEntries = ExifTool.Get16u(dataPt, dirStart)
        local diff = valPtrs[1] - (numEntries * 12 + 4)
        if diff > 8 then
            dirInfo.Base = (dirInfo.Base or 0) - 8
            dirInfo.DataPos = dirInfo.DataPos + 8
        end
    end
    local success = 1
    if tagTablePtr then
        success = require('lexiftool.Exif').ProcessExif(et, dirInfo, tagTablePtr)
    end
    return success
end

--------------------------------------------------------------------------------
-- Process Kodak-patched maker notes (Kodak Type11, Ricoh Type2, GE)
-- Inputs: 0) ExifTool ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
function MakerNotes.ProcessKodakPatch(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    if not dataPt then return 0 end
    local dirStart = dirInfo.DirStart or 0

    -- these maker notes have an 2 extra null bytes either before or after the entry count,
    -- so fix this by making a 2-byte entry count just before the first IFD entry
    if not (dirInfo.DirLen and dirInfo.DirLen >= 4) then return 0 end
    local t1 = et.Get16u(dataPt, dirStart)
    local t2 = et.Get16u(dataPt, dirStart + 2)
    -- (upstream Set16u patches the data in place; a Lua string is immutable,
    --  so the patched copy replaces dirInfo's DataPt)
    if type(dataPt) == 'string' then
        dirInfo.DataPt = substr(dataPt, 0, dirStart + 2) .. ExifTool.Put16u(truthy(t1) and t1 or t2) ..
            substr(dataPt, dirStart + 4)
    else
        ExifTool.Set16u(dataPt, dirStart + 2, truthy(t1) and t1 or t2)
    end
    dirInfo.DirStart = dirInfo.DirStart + 2
    return require('lexiftool.Exif').ProcessExif(et, dirInfo, tagTablePtr)
end

--------------------------------------------------------------------------------
-- Process unknown maker notes or PreviewImage
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success, and updates dirInfo if necessary for new directory
function MakerNotes.ProcessUnknownOrPreview(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    local dirStart = dirInfo.DirStart
    local dirLen = dirInfo.DirLen
    -- check to see if this is a preview image
    if dirLen and dirLen > 6 and dataPt and
        substr(dataPt, dirStart, 3) == '\xff\xd8\xff' then
        et:VerboseDir('PreviewImage')
        if et.HTML_DUMP then
            local pos = dirInfo.DataPos + dirInfo.Base + dirStart
            et:HDump(pos, dirLen, '(MakerNotes:PreviewImage data)', "Size: " .. dirLen .. " bytes")
        end
        et:FoundTag('PreviewImage', substr(dataPt, dirStart, dirLen))
        return 1
    end
    return MakerNotes.ProcessUnknown(et, dirInfo, tagTablePtr)
end

--------------------------------------------------------------------------------
-- Write unknown maker notes or PreviewImage
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref, 2) tag table ref
-- Returns: directory data, '' to delete, or undef on error
--------------------------------------------------------------------------------
function MakerNotes.WriteUnknownOrPreview(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    local dirStart = dirInfo.DirStart
    local dirLen = dirInfo.DirLen
    local newVal
    -- check to see if this is a preview image
    if dirLen > 6 and substr(dataPt, dirStart, 3) == '\xff\xd8\xff' then
        if et.NEW_VALUE and et.NEW_VALUE[ExifTool.Extra.PreviewImage] then
            -- write or delete new preview (if deleted, it can't currently be added back again)
            newVal = et:GetNewValue('PreviewImage')
            if not truthy(newVal) then newVal = '' end
            if perlNum(et:Options('Verbose')) > 1 then
                et:VerboseValue("- MakerNotes:PreviewImage", substr(dataPt, dirStart, dirLen))
                if truthy(newVal) then et:VerboseValue("+ MakerNotes:PreviewImage", newVal) end
            end
            et.CHANGED = (et.CHANGED or 0) + 1
        else
            newVal = substr(dataPt, dirStart, dirLen)
        end
    else
        -- rewrite MakerNote IFD
        newVal = require('lexiftool.WriteExif').WriteExif(et, dirInfo, tagTablePtr)
    end
    return newVal
end

--------------------------------------------------------------------------------
-- Process unknown maker notes assuming it is in EXIF IFD format
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success, and updates dirInfo if necessary for new directory
function MakerNotes.ProcessUnknown(et, dirInfo, tagTablePtr)
    local success = 0

    local loc = MakerNotes.LocateIFD(et, dirInfo)
    if loc ~= nil then
        et.UnknownByteOrder = ExifTool.GetByteOrder()
        if perlNum(et:Options('Verbose')) > 1 then
            local out = et:Options('TextOut') or io.stdout -- (port: TextOut has no STDOUT default)
            local indent = et.INDENT
            indent = subst(indent, [[\| $]], '  ')
            out:write(sprintf("%sFound IFD at offset 0x%.4x in maker notes:\n",
                    indent, dirInfo.DirStart + dirInfo.DataPos + dirInfo.Base))
        end
        success = require('lexiftool.Exif').ProcessExif(et, dirInfo, tagTablePtr)
    else
        et.UnknownByteOrder = '' -- indicates we tried but didn't set byte order
        et:Warn('Unrecognized ' .. perlStr(dirInfo.DirName), 1)
    end
    return success
end

-- patch the SubDirectories' forward-referenced ProcessProcs (predeclared
-- above, before ProcessUnknown/ProcessKodakPatch/FixLeicaBase existed at this
-- point in the file). The function itself, not a wrapper, goes into the
-- table: LocateIFD compares it by identity (`eq \&FixLeicaBase`,
-- `eq \&ProcessUnknown`) like Perl compares the code refs.
local processUnknownNames = {
    MakerNotePentax = 1, MakerNoteHP = 1, MakerNoteKodak8a = 1, MakerNoteKodak8c = 1,
    MakerNoteKodak10 = 1, MakerNotePentax2 = 1, MakerNotePentax3 = 1, MakerNoteSamsung2 = 1,
}
local processKodakPatchNames = {
    MakerNoteKodak8b = 1, MakerNoteKodak11 = 1, MakerNoteKodak12 = 1, MakerNoteRicoh2 = 1,
}
for _, tagInfo in ipairs(MakerNotes.Main) do
    if tagInfo.Name == 'MakerNoteLeica2' then
        tagInfo.SubDirectory.ProcessProc = MakerNotes.FixLeicaBase
    elseif processUnknownNames[tagInfo.Name] then
        tagInfo.SubDirectory.ProcessProc = MakerNotes.ProcessUnknown
    elseif processKodakPatchNames[tagInfo.Name] then
        tagInfo.SubDirectory.ProcessProc = MakerNotes.ProcessKodakPatch
    elseif tagInfo.Name == 'MakerNoteUnknown' then
        tagInfo.SubDirectory.ProcessProc = MakerNotes.ProcessUnknownOrPreview
        tagInfo.SubDirectory.WriteProc = MakerNotes.WriteUnknownOrPreview
    end
end

return MakerNotes
