--------------------------------------------------------------------------------
-- File:         lexiftool/Ogg.lua
-- Ported from:  lib/Image/ExifTool/Ogg.pm
--
-- Description:  Read Ogg meta information
--
-- Revisions:    2011/07/13 - P. Harvey Created (split from Vorbis.pm)
--               2016/07/14 - PH Added Ogg Opus support
--
-- References:   1) http://www.xiph.org/vorbis/doc/
--               2) http://flac.sourceforge.net/ogg_mapping.html
--               3) http://www.theora.org/doc/Theora.pdf
--
-- Port notes:   read subset. Ported: ProcessOGG (the page/packet walker)
--               and ProcessPacket (the codec-header dispatcher). Deferred
--               (not exercised by the vendored images): the Ogg-FLAC
--               (0x7f FLAC) continuation handling -- FLAC.ogg is detected
--               and read as a plain FLAC
--               stream via the same code path, and Vorbis.ogg's comment
--               block is reached directly.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local perl = require('lexiftool.perl')
local substr = perl.substr

local Ogg = {}

local MAX_PACKETS = 2 -- maximum packets to scan from each stream at start of file

-- Information types recognized in Ogg files (upstream %Ogg::Main, for
-- documentation purposes only -- the code below dispatches by content)
Ogg.Main = {
    vorbis = { SubDirectory = { TagTable = 'lexiftool.Vorbis.Main' } },
    theora = { SubDirectory = { TagTable = 'lexiftool.Theora.Main' } },
    Opus = { SubDirectory = { TagTable = 'lexiftool.Opus.Main' } },
    FLAC = { SubDirectory = { TagTable = 'lexiftool.FLAC.Main' } },
    ID3 = { SubDirectory = { TagTable = 'lexiftool.ID3.Main' } },
}

--------------------------------------------------------------------------------
-- Process Ogg packet (upstream ProcessPacket)
-- Inputs: 0) ExifTool object ref, 1) data ref
-- Returns: 1 on success
--------------------------------------------------------------------------------
local function ProcessPacket(et, dataPt)
    local rtnVal
    local p1 = dataPt:sub(1, 1)
    local p2_7 = dataPt:sub(2, 7)
    local tag, type, pos
    if p2_7 == 'vorbis' or p2_7 == 'theora' then
        tag = p1:byte()
        type = (p2_7 == 'vorbis') and 'Vorbis' or 'Theora'
        pos = 7
    elseif dataPt:sub(1, 8) == 'OpusHead' or dataPt:sub(1, 8) == 'OpusTags' then
        tag = dataPt:sub(1, 8)
        type = 'Opus'
        pos = 8
    else
        return 0
    end
    -- this is an OGV file if it contains Theora video
    if type == 'Theora' and et.FILE_TYPE == 'OGG' then
        et:OverrideFileType('OGV')
    end
    if type == 'Opus' and et.FILE_TYPE == 'OGG' then
        et:OverrideFileType('OPUS')
    end
    local tagTablePtr = et:GetTagTable('lexiftool.' .. type .. '.Main')
    local tagInfo = et:GetTagInfo(tagTablePtr, tag)
    if not (tagInfo and tagInfo.SubDirectory) then return 0 end
    local subdir = tagInfo.SubDirectory
    local dirInfo = {
        DataPt = dataPt,
        DirName = tagInfo.Name,
        DirStart = pos,
    }
    local table_ = et:GetTagTable(subdir.TagTable)
    -- set group1 so Theoris comments can be distinguised from Vorbis comments
    if type == 'Theora' then et.SET_GROUP1 = type end
    if subdir.ByteOrder then ExifTool.SetByteOrder(subdir.ByteOrder) end
    rtnVal = et:ProcessDirectory(dirInfo, table_, subdir.ProcessProc)
    ExifTool.SetByteOrder('II')
    et.SET_GROUP1 = nil
    return rtnVal
end

--------------------------------------------------------------------------------
-- Extract information from an Ogg file (upstream ProcessOGG, read subset:
-- no Theora/FLAC continuation special-casing beyond what the vendored
-- images exercise, no verbose page dumps)
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference
-- Returns: 1 on success, 0 if this wasn't a valid Ogg file
--------------------------------------------------------------------------------
function Ogg.ProcessOGG(et, dirInfo)
    -- must first check for leading/trailing ID3 information
    if not et.DoneID3 then
        local ID3 = require('lexiftool.ID3')
        local id3rtn = ID3.ProcessID3(et, dirInfo)
        -- (Perl truthiness: ProcessID3 returns 0 for "no ID3 header",
        --  which is falsy in Perl but truthy in Lua)
        if id3rtn and id3rtn ~= 0 then return 1 end
    end
    local raf = dirInfo.RAF
    local success = 0
    local packets = 0
    local streams = 0
    local stream = ''
    local val = {}
    local streamPage = {}
    local numFlac

    for _ = 1, 100000 do
        local n, buff = raf:Read(28)
        if n == 28 then
            -- validate magic number
            if buff:sub(1, 4) ~= 'OggS' then
                if success ~= 0 then et:Warn('Lost synchronization') end
                break
            end
            if success == 0 then
                -- set file type and initialize on first page
                success = 1
                et:SetFileType()
                ExifTool.SetByteOrder('II')
            end
            local flag = buff:byte(6) -- page flag
            stream = perl.unpack('V', buff:sub(15, 18)) -- stream serial number
            if flag & 0x02 ~= 0 then
                streams = streams + 1 -- count start-of-stream pages
                streamPage[stream] = 0
            end
            if flag & 0x01 == 0 then packets = packets + 1 end -- keep track of packet count
            if numFlac ~= nil then
                -- stop to process FLAC headers if we hit the end of file
                numFlac = numFlac - 1 -- one less header packet to read
            else
                -- can finally process previous packet from this stream
                -- unless this is a continuation page
                if val[stream] ~= nil and flag & 0x01 == 0 then
                    ProcessPacket(et, val[stream])
                    val[stream] = nil
                    -- only read the first MAX_PACKETS packets from each stream
                    if packets > MAX_PACKETS * streams or raf == nil then
                        break
                    end
                end
                -- stop processing Ogg if we have scanned enough packets
                if packets > MAX_PACKETS * streams and not next(val) then break end
            end
            -- continue processing the current page
            local pageNum = perl.unpack('V', buff:sub(19, 22)) -- page sequence number
            local nseg = buff:byte(27) -- number of segments
            -- calculate total data length
            local dataLen = buff:byte(28)
            if nseg ~= 0 then
                local sn, segBuff = raf:Read(nseg - 1)
                if sn ~= nseg - 1 then break end
                for i = 1, nseg - 1 do dataLen = dataLen + segBuff:byte(i) end
            end
            local expected = streamPage[stream]
            if expected ~= nil then
                if expected == pageNum then
                    streamPage[stream] = expected + 1
                else
                    et:Warn('Missing page(s) in Ogg file')
                    streamPage[stream] = nil
                end
            end
            -- read page data
            local dn, dBuff = raf:Read(dataLen)
            if dn ~= dataLen then break end
            if val[stream] ~= nil then
                val[stream] = val[stream] .. dBuff -- add this continuation page
                elseif flag & 0x01 == 0 then -- ignore remaining pages of a continued packet
                -- ignore the first page of any packet we aren't parsing
                if dBuff:sub(1, 1) ~= nil and
                    (dBuff:sub(2, 7) == 'vorbis' or dBuff:sub(2, 7) == 'theora' or
                    dBuff:sub(1, 8) == 'OpusHead' or dBuff:sub(1, 8) == 'OpusTags') then
                    val[stream] = dBuff -- save this page
                elseif dBuff:sub(1, 5) == '\127FLAC' then
                    -- (Ogg FLAC: \x7fFLAC + version(1) + header count(2))
                    local fl = dBuff:sub(8, 9)
                    numFlac = fl:byte(1) * 256 + fl:byte(2)
                    val[stream] = substr(dBuff, 9)
                end
            end
            if numFlac ~= nil then
                -- stop to process FLAC headers if we have them all
                if numFlac <= 0 then break end
            elseif val[stream] ~= nil and flag & 0x04 ~= 0 then
                -- process Ogg packet now if end-of-stream bit is set
                ProcessPacket(et, val[stream])
                val[stream] = nil
            end
        else
            -- all done unless we have to process our last packet
            if not next(val) then break end
            for k in pairs(val) do stream = k end -- take a stream
            if numFlac ~= nil then
                -- stop to process FLAC headers at end of file
                break
            end
            ProcessPacket(et, val[stream])
            val[stream] = nil
            break
        end
    end
    if numFlac ~= nil and val[stream] ~= nil then
        -- process FLAC headers as if it was a complete FLAC file
        local FLAC = require('lexiftool.FLAC')
        local RandomAccess = require('lexiftool.RandomAccess')
        local dirInfo2 = { RAF = RandomAccess.new(val[stream]) }
        FLAC.ProcessFLAC(et, dirInfo2)
    end
    return success
end

return Ogg