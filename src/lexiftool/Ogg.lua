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
-- Port notes:   complete: ProcessPacket (the codec-header dispatcher) and
--               ProcessOGG (leading/trailing ID3 check, the page/packet
--               walker with its -v2 page dumps, and the Ogg-FLAC header
--               packets, read through FLAC.ProcessFLAC).
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local RandomAccess = require('lexiftool.RandomAccess')
local perl = require('lexiftool.perl')
local substr = perl.substr
local matches = perl.matches
local isMatch = perl.isMatch
local perlTruthy = perl.truthy
local ord = perl.ord
local ucfirst = perl.ucfirst
local unpack = perl.unpack
local printf = perl.printf
local sort = perl.sort
local keys = perl.keys
local Get8u = ExifTool.Get8u
local Get32u = ExifTool.Get32u
local GetTagTable = ExifTool.GetTagTable

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
-- Process Ogg packet
-- Inputs: 0) ExifTool object ref, 1) data ref
-- Returns: 1 on success
--------------------------------------------------------------------------------
local function ProcessPacket(et, dataPt)
    local rtnVal = 0
    local m1, m2 = matches(dataPt, [[(?s)^(.)(vorbis|theora)]])
    if not m1 then m1 = matches(dataPt, [[^(OpusHead|OpusTags)]]) end
    if m1 then
        local tag, type, pos
        if perlTruthy(m2) then tag, type, pos = ord(m1), ucfirst(m2), 7 else tag, type, pos = m1, 'Opus', 8 end
        -- this is an OGV file if it contains Theora video
        if type == 'Theora' and et.FILE_TYPE == 'OGG' then et:OverrideFileType('OGV') end
        if type == 'Opus' and et.FILE_TYPE == 'OGG' then et:OverrideFileType('OPUS') end
        local tagTablePtr = GetTagTable(nil, 'lexiftool.' .. type .. '.Main')
        local tagInfo = et:GetTagInfo(tagTablePtr, tag)
        if not (tagInfo and tagInfo.SubDirectory) then return 0 end
        local subdir = tagInfo.SubDirectory
        local dirInfo = {
            DataPt   = dataPt,
            DirName  = tagInfo.Name,
            DirStart = pos,
        }
        local table_ = GetTagTable(nil, subdir.TagTable)
        -- set group1 so Theoris comments can be distinguised from Vorbis comments
        if type == 'Theora' then et.SET_GROUP1 = type end
        if subdir.ByteOrder then ExifTool.SetByteOrder(subdir.ByteOrder) end
        rtnVal = et:ProcessDirectory(dirInfo, table_)
        ExifTool.SetByteOrder('II')
        et.SET_GROUP1 = nil
    end
    return rtnVal
end

--------------------------------------------------------------------------------
-- Extract information from an Ogg file
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference
-- Returns: 1 on success, 0 if this wasn't a valid Ogg file
--------------------------------------------------------------------------------
function Ogg.ProcessOGG(et, dirInfo)

    -- must first check for leading/trailing ID3 information
    if not perlTruthy(et.DoneID3) then
        local ID3 = require('lexiftool.ID3')
        if perlTruthy(ID3.ProcessID3(et, dirInfo)) then return 1 end
    end
    local raf = dirInfo.RAF
    local verbose = et:Options('Verbose')
    local out = et:Options('TextOut') or io.stdout
    local success, page, packets, streams, stream = 0, 0, 0, 0, ''
    local buff, flag, numFlac, n
    local val, streamPage = {}, {}

    while true do
        -- must read ahead to next page to see if it is a continuation
        -- (this code would be a lot simpler if the continuation flag
        --  was on the leading instead of the trailing page!)
        local n28
        if raf then n28, buff = raf:Read(28) end
        if raf and n28 == 28 then
            -- validate magic number
            if not isMatch(buff, '^OggS') then
                if success ~= 0 then et:Warn('Lost synchronization') end
                break
            end
            if success == 0 then
                -- set file type and initialize on first page
                success = 1
                et:SetFileType()
                ExifTool.SetByteOrder('II')
            end
            flag = Get8u(buff, 5)           -- page flag
            stream = Get32u(buff, 14)       -- stream serial number
            if flag & 0x02 ~= 0 then
                streams = streams + 1       -- count start-of-stream pages
                page = 0
                streamPage[stream] = page
            else
                page = streamPage[stream]
            end
            if flag & 0x01 == 0 then packets = packets + 1 end -- keep track of packet count
        else
            -- all done unless we have to process our last packet
            if not next(val) then break end
            stream = sort(keys(val))[1]     -- take a stream
            flag = 0                        -- no continuation
            raf = nil                       -- flag for done reading
        end

        if numFlac ~= nil then
            -- stop to process FLAC headers if we hit the end of file
            if not raf then break end
            numFlac = numFlac - 1 -- one less header packet to read
        else
            -- can finally process previous packet from this stream
            -- unless this is a continuation page
            if val[stream] ~= nil and flag & 0x01 == 0 then
                ProcessPacket(et, val[stream])
                val[stream] = nil
                -- only read the first $MAX_PACKETS packets from each stream
                if packets > MAX_PACKETS * streams or raf == nil then
                    if not next(val) then break end   -- all done (success!)
                end
            end
            -- stop processing Ogg if we have scanned enough packets
            if packets > MAX_PACKETS * streams and not next(val) then break end
        end

        -- continue processing the current page
        local pageNum = Get32u(buff, 18)    -- page sequence number
        local nseg = Get8u(buff, 26)        -- number of segments
        -- calculate total data length
        local dataLen = Get8u(buff, 27)
        if nseg ~= 0 then
            if not raf then break end
            n, buff = raf:Read(nseg - 1)
            if n ~= nseg - 1 then break end
            local segs = { unpack('C*', buff) }
            -- could check that all these (but the last) are 255...
            for _, v in ipairs(segs) do dataLen = dataLen + v end
        end
        if page ~= nil then
            if page == pageNum then
                page = page + 1
                streamPage[stream] = page
            else
                et:Warn('Missing page(s) in Ogg file')
                page = nil
                streamPage[stream] = nil
            end
        end
        -- read page data
        if raf then n, buff = raf:Read(dataLen) end
        if not (raf and n == dataLen) then break end
        if perl.num(verbose) > 1 then
            printf(out, "Page %d, stream 0x%x, flag 0x%x (%d bytes)\n",
                   pageNum, stream, flag, dataLen)
            et:VerboseDump(buff, { DataPos = raf:Tell() - dataLen })
        end
        if val[stream] ~= nil then
            val[stream] = val[stream] .. buff   -- add this continuation page
        elseif flag & 0x01 == 0 then    -- ignore remaining pages of a continued packet
            -- ignore the first page of any packet we aren't parsing
            local fl
            if isMatch(buff, [[(?s)^(.(vorbis|theora)|Opus(Head|Tags))]]) then
                val[stream] = buff          -- save this page
            else
                fl = matches(buff, [[(?s)^\x7fFLAC..(..)]])
                if fl then
                    numFlac = unpack('n', fl)
                    val[stream] = substr(buff, 9)
                end
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
    end
    if numFlac ~= nil and val[stream] ~= nil then
        -- process FLAC headers as if it was a complete FLAC file
        local FLAC = require('lexiftool.FLAC')
        local dirInfo2 = { RAF = RandomAccess.new(val[stream]) }
        FLAC.ProcessFLAC(et, dirInfo2)
    end
    return success
end

return Ogg
