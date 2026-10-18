--------------------------------------------------------------------------------
-- File:         lexiftool/PCAP.lua
-- Ported from:  lib/Image/ExifTool/PCAP.pm
--
-- Description:  Read CAP, PCAP and PCAPNG Packet Capture files
--
-- Revisions:    2025-03-03 - P. Harvey Created
--
-- References:   1) https://www.ietf.org/archive/id/draft-gharris-opsawg-pcap-01.html
--               2) https://www.ietf.org/archive/id/draft-ietf-opsawg-pcapng-02.html
--               3) https://formats.kaitai.io/microsoft_network_monitor_v2/
--
-- Port notes:   read port: the Main table plus ProcessPCAP. Upstream PCAP.pm is
--               read-only.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local matches = require('lexiftool.perl').matches
local substr = require('lexiftool.perl').substr
local sprintf = require('lexiftool.perl').sprintf
local uv = require('lexiftool.perl').uv
local str = require('lexiftool.perl').str

local PCAP = {}

PCAP.Main = {
    GROUPS = { [0] = 'File', [1] = 'File', [2] = 'Other' },
    VARS = { NO_LOOKUP = 1 }, -- omit tags from lookup
    NOTES = 'Tags extracted from  CAP, PCAP and PCAPNG Packet Capture files.',
    -- (Note: All string values are UTF-8 but I'm going to be lazy and not bother decoding them)
    ByteOrder = {
        PrintConv = {
            II = 'Little-endian (Intel, II)',
            MM = 'Big-endian (Motorola, MM)',
        },
    },
    PCAPVersion = {},
    LinkType = {
        PrintConvColumns = 2,
        PrintConv = {
            [0] = 'BSD Loopback',
            [1] = 'IEEE 802.3 Ethernet',
            [2] = 'Experimental 4Mb Ethernet',
            [3] = 'AX.25',
            [4] = 'PRONET',
            [5] = 'MIT CHAOSNET',
            [6] = 'IEEE 802.5',
            [7] = 'ARCNET BSD',
            [8] = 'SLIP',
            [9] = 'PPP',
            [10] = 'fddI',
            [50] = 'PPP HDLC',
            [51] = 'PPP Ethernet',
            [99] = 'Symantec Firewall',
            [100] = 'ATM RFC 1483',
            [101] = 'Raw',
            [102] = 'SLIP BSD/OS',
            [103] = 'PPP BSD/OS',
            [104] = 'Cisco PPP with HDLC',
            [105] = 'IEEE 802.11',
            [106] = 'ATM Classical IP',
            [107] = 'Frame Relay',
            [108] = 'OpenBSD Loopback',
            [109] = 'OpenBSD IPSEC',
            [110] = 'ATM LANE 802.3',
            [111] = 'NetBSD HIPPI',
            [112] = 'NetBSD HDLC',
            [113] = 'Linux SLL',
            [114] = 'Apple LocalTalk',
            [115] = 'Acorn Econet',
            [116] = 'OpenBSD ipfilter',
            [117] = 'OpenBSD pflog',
            [118] = 'Cisco IOS',
            [119] = 'IEEE 802.11 Prism',
            [120] = 'IEEE 802.11 Aironet',
            [121] = 'Siemens HiPath HDLC',
            [122] = 'IP-over-Fibre',
            [123] = 'SunATM',
            [124] = 'RapidIO',
            [125] = 'PCI Express',
            [126] = 'Xilinx Aurora',
            [127] = 'IEEE 802.11 Radiotap',
            [128] = 'Tazmen Sniffer',
            [129] = 'ARCNET Linux',
            [130] = 'Juniper MLPPP',
            [131] = 'Juniper MLFR',
            [132] = 'Juniper ES',
            [133] = 'Juniper GGSN',
            [134] = 'Juniper MFR',
            [135] = 'Juniper ATM2',
            [136] = 'Juniper Services',
            [137] = 'Juniper ATM1',
            [138] = 'Apple IP-over-IEEE 1394',
            [139] = 'MTP2 with PHDR',
            [140] = 'MTP2',
            [141] = 'MTP3',
            [142] = 'SCCP',
            [143] = 'DOCSIS',
            [144] = 'Linux IrDA',
            [145] = 'IBM SP',
            [146] = 'IBM SN',
            [163] = 'IEEE 802.11 AVS',
            [164] = 'Juniper Monitor',
            [165] = 'BACnet MS/TP',
            [166] = 'PPP PPPD',
            [167] = 'Juniper PPPOE',
            [168] = 'Juniper PPPOE ATM',
            [169] = 'GPRS LLC',
            [170] = 'GPF-T',
            [171] = 'GPF-F',
            [172] = 'Gcom T1/E1',
            [173] = 'Gcom Serial',
            [174] = 'Juniper PIC Peer',
            [175] = 'ERF ETH',
            [176] = 'ERF POS',
            [177] = 'Linux LAPD',
            [178] = 'Juniper Ether',
            [179] = 'Juniper PPP',
            [180] = 'Juniper Frame Relay',
            [181] = 'Juniper CHDLC',
            [182] = 'Juniper VP',
            [185] = 'A653 ICM',
            [186] = 'USB FreeBSD',
            [187] = 'Bluetooth HCI H4',
            [188] = 'IEEE 802.16 MAC CPS',
            [189] = 'USB Linux',
            [190] = 'CAN 2.0B',
            [191] = 'IEEE 802.15.4 Linux',
            [192] = 'PPI',
            [193] = 'IEEE 802.16 MAC CPS Radio',
            [194] = 'Juniper ISM',
            [195] = 'IEEE 802.15.4 with FCS',
            [196] = 'SITA',
            [197] = 'ERF',
            [198] = 'RAIF1',
            [199] = 'IPMB Kontron',
            [200] = 'Juniper ST',
            [201] = 'Bluetooth HCI H4 with PHDR',
            [202] = 'AX.25 KISS',
            [203] = 'LAPD',
            [204] = 'PPP with DIR',
            [205] = 'Cisco HDLC with DIR',
            [206] = 'Frame Relay with DIR',
            [207] = 'LAPB with DIR',
            [209] = 'IPMB Linux',
            [210] = 'FlexRay',
            [211] = 'MOST',
            [212] = 'LIN',
            [213] = 'X2E Serial',
            [214] = 'X2E Xoraya',
            [215] = 'IEEE 802.15.4 Nonask PHY',
            [216] = 'Linux evdev',
            [217] = 'GSMtap Um',
            [218] = 'GSMtap Abis',
            [219] = 'MPLS',
            [220] = 'USB Linux MMapped',
            [221] = 'DECT',
            [222] = 'AOS',
            [223] = 'Wireless HART',
            [224] = 'FC-2',
            [225] = 'FC-2 with Frame Delims',
            [226] = 'IPNET',
            [227] = 'CAN Socketcan',
            [228] = 'IPv4',
            [229] = 'IPv6',
            [230] = 'IEEE 802.15.4 No FCS',
            [231] = 'D-Bus',
            [232] = 'Juniper VS',
            [233] = 'Juniper SRX E2E',
            [234] = 'Juniper Fibre Channel',
            [235] = 'DVB-CI',
            [236] = 'Mux 27.010',
            [237] = 'STANAG 5066 D_PDU',
            [238] = 'Juniper ATM Cemic',
            [239] = 'NFLOG',
            [240] = 'Netanalyzer',
            [241] = 'Netanalyzer Transparent',
            [242] = 'IP-over-InfiniBand',
            [243] = 'MPEG-2 TS',
            [244] = 'NG40',
            [245] = 'NFC LLCP',
            [246] = 'Pfsync',
            [247] = 'InfiniBand',
            [248] = 'SCTP',
            [249] = 'USBPcap',
            [250] = 'RTAC Serial',
            [251] = 'Bluetooth LE LL',
            [252] = 'Wireshark Upper PDU',
            [253] = 'Netlink',
            [254] = 'Bluetooth Linux Monitor',
            [255] = 'Bluetooth BREDR BB',
            [256] = 'Bluetooth LE LL with PHDR',
            [257] = 'PROFIBUS Data Link',
            [258] = 'Apple PKTAP',
            [259] = 'EPON',
            [260] = 'IPMI HPM.2',
            [261] = 'Z-Wave R1/R2',
            [262] = 'Z-Wave R3',
            [263] = 'WattStopper DLM',
            [264] = 'ISO 14443',
            [265] = 'RDS',
            [266] = 'USB Darwin',
            [267] = 'Openflow',
            [268] = 'SDLC',
            [269] = 'TI LLN Sniffer',
            [270] = 'LoRaTap',
            [271] = 'Vsock',
            [272] = 'Nordic BLE',
            [273] = 'DOCSIS 31 XRA31',
            [274] = 'Ethernet MPacket',
            [275] = 'DisplayPort AUX',
            [276] = 'Linux SLL2',
            [277] = 'Sercos Monitor',
            [278] = 'Openvizsla',
            [279] = 'Elektrobit EBHSR',
            [280] = 'VPP Dispatch',
            [281] = 'DSA Tag BRCM',
            [282] = 'DSA Tag BRCM Prepend',
            [283] = 'IEEE 802.15.4 Tap',
            [284] = 'DSA Tag DSA',
            [285] = 'DSA Tag EDSA',
            [286] = 'ELEE',
            [287] = 'Z-Wave Serial',
            [288] = 'USB 2.0',
            [289] = 'ATSC ALP',
        },
    },
    TimeStamp = {
        Groups = { [2] = 'Time' },
        ValueConv = function(self, val)
            if self.WindowsTS then return val end
            local digits = (self.TSResol and self.TSResol < 1e-7) and 9 or 6
            return ExifTool.ConvertUnixTime(val, 1, digits)
        end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    --
    -- "options" tags common to all blocks
    --
    [1] = 'Comment',
    [2988] = {
        Name = 'CustomOption1',
        ValueConv = function(_self, val)
            if #val <= 4 then return nil end
            local len = ExifTool.Get16u(val, 2)
            if not (len > 4 and len <= #val - 4) then return nil end
            return 'Type=' .. ExifTool.Get16u(val, 0) .. ' PEN=' .. ExifTool.Get32u(val, 4) ..
                ' Val=' .. substr(val, 8, len - 4)
        end,
    },
    [2989] = {
        Name = 'CustomOption2',
        Binary = 1,
    },
    [19372] = {
        Name = 'CustomOption3',
        ValueConv = function(_self, val)
            if #val <= 4 then return nil end
            local len = ExifTool.Get16u(val, 2)
            if not (len > 4 and len <= #val - 4) then return nil end
            return 'Type=' .. ExifTool.Get16u(val, 0) .. ' PEN=' .. ExifTool.Get32u(val, 4) ..
                ' Val=' .. substr(val, 8, len - 4)
        end,
    },
    [19373] = {
        Name = 'CustomOption4',
        Binary = 1,
    },
    --
    -- "options" tags in Section Header Block
    --
    ['SHB-2'] = 'Hardware',
    ['SHB-3'] = 'OperatingSystem',
    ['SHB-4'] = 'UserApplication',
    --
    -- "options" tags in Interface Description Block
    --
    ['IDB-2'] = 'DeviceName',
    ['IDB-3'] = 'Description',
    ['IDB-4'] = {
        Name = 'IPv4Addr',
        Description = 'IPv4 Addr',
        -- IP address and net mask
        ValueConv = function(_self, val)
            local parts = {}
            for i = 1, #val do parts[i] = str(val:byte(i)) end
            return table.concat(parts, '.')
        end,
    },
    ['IDB-5'] = {
        Name = 'IPv6Addr',
        Description = 'IPv6 Addr',
        ValueConv = function(_self, val)
            local groups = {}
            for i = 1, 16, 2 do groups[#groups + 1] = string.format('%02x%02x', val:byte(i), val:byte(i + 1)) end
            return table.concat(groups, ':') .. '/' .. val:byte(17)
        end,
    },
    ['IDB-6'] = {
        Name = 'MACAddr',
        ValueConv = function(_self, val)
            local groups = {}
            for i = 1, 6 do groups[i] = string.format('%02x', val:byte(i)) end
            return table.concat(groups, '-')
        end,
    },
    ['IDB-7'] = {
        Name = 'EUIAddr',
        ValueConv = function(_self, val)
            local groups = {}
            for i = 1, 8, 2 do groups[#groups + 1] = string.format('%02x%02x', val:byte(i), val:byte(i + 1)) end
            return table.concat(groups, ':')
        end,
    },
    ['IDB-8'] = { Name = 'Speed', Format = 'int64u' },
    ['IDB-9'] = {
        Name = 'TimeStampResolution',
        Format = 'int8u',
        -- upstream: '$$self{TSResol} = (...)' -- a Perl assignment expression,
        -- which evaluates to (and thus returns) the assigned value, not $val
        RawConv = function(self, val)
            if val & 0x80 ~= 0 then
                self.TSResol = 2 ^ -(val & 0x7f)
            else
                self.TSResol = 10 ^ -val
            end
            return self.TSResol
        end,
    },
    ['IDB-10'] = 'TimeZone',
    ['IDB-11'] = {
        Name = 'Filter',
        ValueConv = function(_self, val) return ExifTool.Get8u(val, 0) .. ': ' .. substr(val, 1) end,
    },
    ['IDB-12'] = 'OperatingSystem',
    ['IDB-13'] = { Name = 'FrameCheckSequenceLength', Format = 'int8u' },
    ['IDB-14'] = {
        Name = 'TimeStampOffset',
        Format = 'int64u',
        RawConv = function(self, val) self.TSOff = val; return val end,
    },
    ['IDB-15'] = 'Hardware',
    ['IDB-16'] = { Name = 'TXSpeed', Format = 'int64u' },
    ['IDB-17'] = { Name = 'RXSpeed', Format = 'int64u' },
    ['IDB-18'] = 'TimezoneName',
}

--------------------------------------------------------------------------------
-- Extract metadata from a PCAP file
-- Inputs: 0) ExifTool ref, 1) dirInfo ref
-- Returns: 1 on success, 0 if this wasn't a valid PCAP file
--------------------------------------------------------------------------------
function PCAP.ProcessPCAP(et, dirInfo)
    local raf = dirInfo.RAF
    local n, buff = raf:Read(24)
    if n ~= 24 then return 0 end

    local fileType, byteOrder, verPos
    local g1, g2 = matches(buff, [[(?s)^\xa1\xb2(\xc3\xd4|\x3c\x4d)\0.\0.|(\xd4\xc3|\x4d\x3c)\xb2\xa1.\0.\0]])
    if g1 or g2 then
        fileType = 'PCAP'
        local t = g1 or g2
        et.TSResol = (t == '\195\212' or t == '\212\195') and 1e-6 or 1e-9
        byteOrder = buff:sub(1, 1) == '\161' and 'MM' or 'II'
        verPos = 4
    elseif buff:sub(1, 4) == '\10\13\13\10' and
        (buff:sub(9, 12) == '\26\43\60\77' or buff:sub(9, 12) == '\77\60\43\26') then
        fileType = 'PCAPNG'
        byteOrder = buff:sub(9, 12) == '\26\43\60\77' and 'MM' or 'II'
        verPos = 12
    elseif buff:sub(1, 6) == 'GMBU\0\2' then
        -- handle Windows Network Monitor 2.0 CAP files
        et:SetFileType('CAP', 'application/octet-stream', 'cap')
        local tagTablePtr = et:GetTagTable('lexiftool.PCAP.Main')
        et.WindowsTS = 1
        local a = {}
        for i = 1, 9 do a[i] = ExifTool.Get16u(buff, 6 + (i - 1) * 2) end
        local val = sprintf('%.4d:%.2d:%.2d %.2d:%.2d:%.2d.%.3d', a[2], a[3], a[5], a[6], a[7], a[8])
        et:HandleTag(tagTablePtr, 'LinkType', a[1])
        et:HandleTag(tagTablePtr, 'TimeStamp', val)
        if raf:Seek(40, 0) then
            local n2, b2 = raf:Read(8)
            if n2 == 8 then
                local off = ExifTool.Get32u(b2, 0)
                local len = ExifTool.Get32u(b2, 4)
                -- extract comment
                if len < 1024 and raf:Seek(off, 0) then
                    local n3, b3 = raf:Read(len)
                    if n3 == len then
                        et:HandleTag(tagTablePtr, 1, b3) -- (NC) null terminated? Unicode?
                    end
                end
            end
        end
        return 1
    else
        return 0
    end

    et:SetFileType(fileType)
    ExifTool.SetByteOrder(byteOrder)
    local tagTablePtr = et:GetTagTable('lexiftool.PCAP.Main')
    local ver = ExifTool.Get16u(buff, verPos) .. '.' .. ExifTool.Get16u(buff, verPos + 2)
    et:HandleTag(tagTablePtr, 'PCAPVersion', fileType .. ' ' .. ver)
    et:HandleTag(tagTablePtr, 'ByteOrder', byteOrder)

    if fileType == 'PCAP' then
        et:HandleTag(tagTablePtr, 'LinkType', (ExifTool.Get16u(buff, 22)))
        local n2, b2 = raf:Read(8)
        if n2 ~= 8 then
            et:Warn('Truncated PCAP file')
            return 1
        end
        local ts = ExifTool.Get32u(b2, 0) + ExifTool.Get32u(b2, 4) * et.TSResol
        et:HandleTag(tagTablePtr, 'TimeStamp', ts)
        return 1
    end

    -- read through PCAPNG options for the SHB, IDB and get the timestamp from the first EPD
    local dir = 'SHB' -- Section Header Block
    while true do
        local n2, b2 = raf:Read(4)
        if n2 ~= 4 then break end
        local opt = ExifTool.Get16u(b2, 0)
        local len = ExifTool.Get16u(b2, 2)
        if opt == 0 then -- (end of options?)
            local n3, b3 = raf:Read(20)
            if n3 ~= 20 then break end
            local dirNum = ExifTool.Get32u(b3, 4)
            if dirNum == 1 then
                et:HandleTag(tagTablePtr, 'LinkType', (ExifTool.Get16u(b3, 12)))
                dir = 'IDB' -- Interface Description Block
                goto continueOptLoop -- continue with IDB options
            elseif dirNum == 6 then -- EPD (Enhanced Packet Data)
                local ts = uv(4294967296 * ExifTool.Get32u(b3, 16))
                -- upstream: `$raf->Read(\$buff, 4)` -- passing \$buff (a
                -- reference) instead of $buff to a sub with prototype ($$$)
                -- means the read's result is never actually written back to
                -- $buff (Perl only aliases @_ to a plain lvalue argument,
                -- not to a fresh reference expression), so the following
                -- Get32u(\$buff,0) silently re-reads offset 0 of the STALE
                -- 20-byte buffer from the *previous* read, not fresh bytes.
                -- This is a real upstream bug, verified against the actual
                -- Perl module and its golden .out; still consume 4 bytes
                -- from the stream to match upstream's byte-position
                -- advancement, but keep using b3 (not the just-read bytes).
                local n4 = raf:Read(4)
                if n4 ~= 4 then break end
                if et.TSResol then
                    ts = (ts + ExifTool.Get32u(b3, 0)) * et.TSResol + (et.TSOff or 0)
                    et:HandleTag(tagTablePtr, 'TimeStamp', ts)
                end
            end
            break
        end
        local pad = (len + 3) & 0xfffc -- round to an even 4 bytes
        local n5, b5 = raf:Read(pad)
        if n5 ~= pad then
            et:Warn('Error reading ' .. dir .. ' options')
            break
        end
        local id = tagTablePtr[opt] and opt or (dir .. '-' .. opt)
        et:HandleTag(tagTablePtr, id, nil, {
            DataPt = b5,
            DataPos = raf:Tell() - pad,
            Size = len,
            MakeTagInfo = 1,
        })
        ::continueOptLoop::
    end
    return 1
end

return PCAP
