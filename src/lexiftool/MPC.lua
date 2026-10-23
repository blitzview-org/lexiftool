--------------------------------------------------------------------------------
-- File:         lexiftool/MPC.lua
-- Ported from:  lib/Image/ExifTool/MPC.pm
--
-- Description:  Read Musepack audio meta information
--
-- Revisions:    11/14/2006 - P. Harvey Created
--
-- References:   1) http://www.musepack.net/
--
-- Port notes:   complete: Main (the bit-packed MPC header table, processed
--               by FLAC.ProcessBitStream) and ProcessMPC (the whole-file
--               reader: ID3 leading check, `MP+` signature, version-7
--               header bit-table with its verbose dump, the non-version-7
--               warning, then the APE trailer via APE.ProcessAPE).
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local perlTruthy = require('lexiftool.perl').truthy
local str = require('lexiftool.perl').str
local matches = require('lexiftool.perl').matches
local ord = require('lexiftool.perl').ord
local GetTagTable = ExifTool.GetTagTable
local FLAC = require('lexiftool.FLAC')

local MPC = {}

-- MPC metadata blocks (upstream %Image::ExifTool::MPC::Main)
MPC.Main = {
    PROCESS_PROC = FLAC.ProcessBitStream,
    GROUPS = { [2] = 'Audio' },
    NOTES = [[
        Tags used in Musepack (MPC) audio files.  ExifTool also extracts ID3 and APE
        information from these files.
    ]],
    ['Bit032-063'] = 'TotalFrames',
    ['Bit080-081'] = {
        Name = 'SampleRate',
        PrintConv = {
            [0] = 44100,
            [1] = 48000,
            [2] = 37800,
            [3] = 32000,
        },
    },
    ['Bit084-087'] = {
        Name = 'Quality',
        PrintConv = {
            [1] = 'Unstable/Experimental',
            [5] = '0',
            [6] = '1',
            [7] = '2 (Telephone)',
            [8] = '3 (Thumb)',
            [9] = '4 (Radio)',
            [10] = '5 (Standard)',
            [11] = '6 (Xtreme)',
            [12] = '7 (Insane)',
            [13] = '8 (BrainDead)',
            [14] = '9',
            [15] = '10',
        },
    },
    ['Bit088-093'] = 'MaxBand',
    ['Bit096-111'] = 'ReplayGainTrackPeak',
    ['Bit112-127'] = 'ReplayGainTrackGain',
    ['Bit128-143'] = 'ReplayGainAlbumPeak',
    ['Bit144-159'] = 'ReplayGainAlbumGain',
    ['Bit179'] = {
        Name = 'FastSeek',
        PrintConv = { [0] = 'No', [1] = 'Yes' },
    },
    ['Bit191'] = {
        Name = 'Gapless',
        PrintConv = { [0] = 'No', [1] = 'Yes' },
    },
    ['Bit216-223'] = {
        Name = 'EncoderVersion',
        PrintConv = function(_self, val)
            local s = str(val)
            s = s:gsub('(%d)(%d)(%d)$', '%1.%2.%3')
            return s
        end,
    },
}

--------------------------------------------------------------------------------
-- Extract information from an MPC file
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference
-- - Just looks for MPC trailer if FileType is already set
-- Returns: 1 on success, 0 if this wasn't a valid MPC file
--------------------------------------------------------------------------------
function MPC.ProcessMPC(et, dirInfo)

    -- must first check for leading ID3 information
    if not perlTruthy(et.DoneID3) then
        local ID3 = require('lexiftool.ID3')
        if perlTruthy(ID3.ProcessID3(et, dirInfo)) then return 1 end
    end
    local raf = dirInfo.RAF
    local n, buff, m1

    -- check MPC signature
    n, buff = raf:Read(32)
    if n == 32 then m1 = matches(buff, [[(?s)^MP\+(.)]]) end
    if not m1 then return 0 end
    local vers = ord(m1) & 0x0f
    et:SetFileType()

    -- extract audio information (currently only from version 7 MPC files)
    if vers == 0x07 then
        ExifTool.SetByteOrder('II')
        local pos = raf:Tell() - 32
        if perlTruthy(et:Options('Verbose')) then
            et:VPrint(0, "MPC Header (32 bytes):\n")
            et:VerboseDump(buff, { DataPos = pos })
        end
        local tagTablePtr = GetTagTable(nil, 'lexiftool.MPC.Main')
        local dirInfo_ = { DataPt = buff, DataPos = pos }
        et:ProcessDirectory(dirInfo_, tagTablePtr)
    else
        et:Warn('Audio info currently not extracted from this version MPC file')
    end

    -- process APE trailer if it exists
    local APE = require('lexiftool.APE')
    APE.ProcessAPE(et, dirInfo)

    return 1
end

return MPC