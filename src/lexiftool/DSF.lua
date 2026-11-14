--------------------------------------------------------------------------------
-- File:         lexiftool/DSF.lua
-- Ported from:  lib/Image/ExifTool/DSF.pm
--
-- Description:  Read DSF meta information
--
-- Revisions:    2025-09-24 - P. Harvey Created
--
-- References:   1) https://dsd-guide.com/sites/default/files/white-papers/DSFFileFormatSpec_E.pdf
--
-- Port notes:   ported in full: the `Main` header table and `ProcessDSF`
--               (including the ID3v2 metadata block at the end of the file).
--               Upstream DSF.pm is read-only.
--               No vendored test image is a DSF file.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local perl = require('lexiftool.perl')
local matches = perl.matches
local substr = perl.substr
local perlTruthy = ExifTool.perlTruthy

local DSF = {}

-- DSF header format
DSF.Main = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [0] = 'File', [1] = 'File', [2] = 'Audio' },
    FORMAT = 'int32u',
    NOTES = [[
        Tags read from the 'fmt ' header of a DSF (DSD Stream File) audio files. As
        well, ID3 metadata may also exist in these files. See
        L<https://dsd-guide.com/sites/default/files/white-papers/DSFFileFormatSpec_E.pdf>
        for the specification.
    ]],
    [3] = 'FormatVersion',
    [4] = { Name = 'FormatID', PrintConv = { [0] = 'DSD Raw' } },
    [5] = {
        Name = 'ChannelType',
        PrintConv = {
            [1] = 'Mono',
            [2] = 'Stereo (Left, Right)',
            [3] = '3 Channels (Left, Right, Center)',
            [4] = 'Quad (Left, Right, Back L, Back R)',
            [5] = '4 Channels (Left, Right, Center, Bass)',
            [6] = '5 Channels (Left, Right, Center, Back L, Back R)',
            [7] = '5.1 Channels (Left, Right, Center, Bass, Back L, Back R)',
        },
    },
    [6] = 'ChannelCount',
    [7] = 'SampleRate',
    [8] = 'BitsPerSample',
    [9] = { Name = 'SampleCount', Format = 'int64u' },
    [11] = 'BlockSize',
}

--------------------------------------------------------------------------------
-- Extract metadata from a DSF file
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference
-- Returns: 1 on success, 0 if this wasn't a valid DSF file
function DSF.ProcessDSF(et, dirInfo)
    local raf = dirInfo.RAF
    local buff, buf2

    -- verify this is a valid DSF file
    local n
    n, buff = raf:Read(40)
    if n ~= 40 then return 0 end
    if matches(buff, [[(?s)^DSD \x1c\0{7}.{16}fmt ]]) == nil then return 0 end
    et:SetFileType()   -- set the FileType tag
    local tagTbl = et:GetTagTable('lexiftool.DSF.Main')
    ExifTool.SetByteOrder('II')
    local fmtLen = ExifTool.Get64u(buff, 32)
    local n2
    if fmtLen > 12 and fmtLen < 1000 then n2, buf2 = raf:Read(fmtLen - 12) end
    if not (fmtLen > 12 and fmtLen < 1000 and n2 == fmtLen - 12) then
        et:Warn('Error reading DSF fmt chunk')
        return 1
    end
    local fileSize = ExifTool.Get64u(buff, 12)
    local metaPos = ExifTool.Get64u(buff, 20)
    buff = substr(buff, 28) .. buf2
--
-- process the DSF 'fmt ' chunk
--
    local dirInfo2 = {
        DataPt = buff,
        DirStart = 0,
        DirLen = #buff,
    }
    et:ProcessBinaryData(dirInfo2, tagTbl)
--
-- process ID3v2 if it exists
--
    local metaLen = fileSize - metaPos
    if perlTruthy(metaPos) and metaLen > 0 and metaLen < 20000000 and raf:Seek(metaPos, 0) then
        local n3
        n3, buff = raf:Read(metaLen)
        if n3 == metaLen then
            dirInfo2.DataPt   = buff
            dirInfo2.DataPos  = metaPos
            dirInfo2.DirLen   = metaLen
            local id3Tbl = et:GetTagTable('lexiftool.ID3.Main')
            et:ProcessDirectory(dirInfo2, id3Tbl)
        end
    end
    return 1
end

return DSF
