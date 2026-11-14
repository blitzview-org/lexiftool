--------------------------------------------------------------------------------
-- File:         lexiftool/Rawzor.lua
-- Ported from:  lib/Image/ExifTool/Rawzor.pm
--
-- Description:  Read meta information from Rawzor compressed images
--
-- Revisions:    09/09/2008 - P. Harvey Created
--
-- References:   1) http://www.rawzor.com/
--
-- Port notes:   Full port.  IO::Uncompress::Bunzip2 is the perl facade's
--               counterpart over compress.bzip2 (perl.evalRequire), with
--               the one-shot defaults of the Perl module; its output scalar
--               \$buf2 is a box { value = <carray> }.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local perl = require('lexiftool.perl')
local sprintf = perl.sprintf
local substr = perl.substr
local length = perl.length
local isMatch = perl.isMatch

local Rawzor = {}

-- currently support this version Rawzor images
local implementedRawzorVersion = 199 -- (up to version 1.99)

-- Rawzor-specific tags
Rawzor.Main = {
    GROUPS = { [2] = 'Other' },
    VARS = { ID_FMT = 'none' },
    NOTES = [[
        Rawzor files store compressed images of other formats. As well as the
        information listed below, exiftool uncompresses and extracts the meta
        information from the original image.
    ]],
    OriginalFileType = { },
    OriginalFileSize = {
        PrintConv = ExifTool.Extra.FileSize.PrintConv,
    },
    RawzorRequiredVersion = {
        ValueConv = function(_self, val) return val / 100 end,
        PrintConv = function(_self, val) return sprintf('%.2f', val) end,
    },
    RawzorCreatorVersion = {
        ValueConv = function(_self, val) return val / 100 end,
        PrintConv = function(_self, val) return sprintf('%.2f', val) end,
    },
    -- compression factor is originalSize/compressedSize (and compression
    -- ratio is the inverse - ref "Data Compression" by David Salomon)
    CompressionFactor = { PrintConv = function(_self, val) return sprintf('%.2f', val) end },
}

--------------------------------------------------------------------------------
-- Extract information from a Rawzor file
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference
-- Returns: 1 on success, 0 if this wasn't a valid Rawzor file
function Rawzor.ProcessRWZ(et, dirInfo)
    local raf = dirInfo.RAF
    local buff, buf2

    -- read the Rawzor file header:
    --  0 string - "rawzor" signature
    --  6 int16u - Required SDK version
    --  8 int16u - Creator SDK version
    -- 10 int64u - RWZ file size
    -- 18 int64u - original raw file size
    -- 26 undef[12] - reserved
    -- 38 int64u - metadata offset
    local n
    n, buff = raf:Read(46)
    if not (n == 46 and isMatch(buff, '^rawzor')) then return 0 end

    ExifTool.SetByteOrder('II')
    local reqVers = ExifTool.Get16u(buff, 6)
    local creatorVers = ExifTool.Get16u(buff, 8)
    local rwzSize = ExifTool.Get64u(buff, 10)
    local origSize = ExifTool.Get64u(buff, 18)
    local tagTablePtr = et:GetTagTable('lexiftool.Rawzor.Main')
    et:HandleTag(tagTablePtr, 'RawzorRequiredVersion', reqVers)
    et:HandleTag(tagTablePtr, 'RawzorCreatorVersion', creatorVers)
    et:HandleTag(tagTablePtr, 'OriginalFileSize', origSize)
    if ExifTool.perlTruthy(rwzSize) then
        et:HandleTag(tagTablePtr, 'CompressionFactor', origSize / rwzSize)
    end
    -- check version numbers
    if reqVers > implementedRawzorVersion then
        et:Warn('Version ' .. ExifTool.NumStr(reqVers) .. ' Rawzor images not yet supported')
        return 1
    end
    local metaOffset = ExifTool.Get64u(buff, 38)
    if metaOffset > 0x7fffffff then
        et:Warn('Bad metadata offset')
        return 1
    end
    -- check for the ability to uncompress the information
    local haveBzip2, IO_Uncompress_Bunzip2 = perl.evalRequire('IO::Uncompress::Bunzip2')
    if not haveBzip2 then
        et:Warn('Install IO::Compress::Bzip2 to decode Rawzor bzip2 compression')
        return 1
    end
    -- read the metadata header:
    --  0 int64u - metadata section 0 end (offset in original file)
    --  8 int64u - metadata section 1 start
    -- 16 int64u - metadata section 1 end
    -- 24 int64u - metadata section 2 start
    -- 32 undef[4] - reserved
    -- 36 int32u - original metadata size
    -- 40 int32u - compressed metadata size
    local n2
    if raf:Seek(metaOffset, 0) then n2, buff = raf:Read(44) end
    if n2 ~= 44 then
        et:Warn('Error reading metadata header')
        return 1
    end
    local metaSize = ExifTool.Get32u(buff, 36)
    if ExifTool.perlTruthy(metaSize) then
        et.DontValidateImageData = 1
        -- validate the metadata header and read the compressed metadata
        local end0 = ExifTool.Get64u(buff, 0)
        local pos1 = ExifTool.Get64u(buff, 8)
        local end1 = ExifTool.Get64u(buff, 16)
        local pos2 = ExifTool.Get64u(buff, 24)
        local len = ExifTool.Get32u(buff, 40)
        local n3
        n3, buff = raf:Read(len)
        if not (n3 == len and
            end0 + (end1 - pos1) + (origSize - pos2) == metaSize and
            end0 <= pos1 and pos1 <= end1 and end1 <= pos2)
        then
            et:Warn('Error reading image metadata')
            return 1
        end
        -- uncompress the metadata
        buf2 = {}   -- (\$buf2: a box, which bunzip2 sets to a carray)
        if not (IO_Uncompress_Bunzip2.bunzip2({ value = buff }, buf2) and
            length(buf2.value) == metaSize)
        then
            et:Warn('Error uncompressing image metadata')
            return 1
        end
        -- re-assemble the original file (sans image data)
        buff = nil -- luacheck: ignore 311 (can't hurt to free memory as soon as possible)
        buf2 = buf2.value   -- (the carray in the box)
        buff = substr(buf2, 0, end0) .. ("\0"):rep(pos1 - end0) ..
                substr(buf2, end0, end1 - pos1) .. ("\0"):rep(pos2 - end1) ..
                substr(buf2, end0 + end1 - pos1, origSize - pos2)
        buf2 = nil -- luacheck: ignore 311

        -- extract original information by calling ExtractInfo recursively
        et:ExtractInfo({ ref = 'SCALAR', value = buff }, { ReEntry = 1 })
        buff = nil -- luacheck: ignore 311
    end
    -- set OriginalFileType from FileType of original file
    -- then change FileType and MIMEType to indicate a Rawzor image
    local origFileType = et.FileType
    if ExifTool.perlTruthy(origFileType) then
        et:HandleTag(tagTablePtr, 'OriginalFileType', origFileType)
        et:OverrideFileType('RWZ')
    else
        et:HandleTag(tagTablePtr, 'OriginalFileType', 'Unknown')
        et:SetFileType()
    end
    return 1
end

return Rawzor
