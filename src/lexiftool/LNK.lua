--------------------------------------------------------------------------------
-- File:         lexiftool/LNK.lua
-- Ported from:  lib/Image/ExifTool/LNK.pm
--
-- Description:  Read meta information from MS Shell Link files
--
-- Revisions:    2009/09/19 - P. Harvey Created
--               2025/10/20 - PH Added .URL file support
--
-- References:   1) http://msdn.microsoft.com/en-us/library/dd871305(PROT.10).aspx ([MS-SHLLINK].pdf)
--               2) http://www.i2s-lab.com/Papers/The_Windows_Shortcut_File_Format.pdf
--               3) https://harfanglab.io/insidethelab/sadfuture-xdspy-latest-evolution/#tid_specifications_ignored
--               4) https://github.com/libyal/libfwsi/blob/main/documentation/Windows%20Shell%20Item%20format.asciidoc
--               5) https://github.com/EricZimmerman/Lnk/blob/master/Lnk/ShellItems/ShellBag0x00.cs
--
-- Port notes:   LNK.pm in full: every tag table, DOSTime, GetString,
--               ProcessItemID, ProcessURI, ProcessLinkInfo, ProcessINI and
--               ProcessLNK.  Upstream LNK.pm has no write path.  Lua forms:
--               the hash spreads %fileTime and %mtpGUID are helper calls in
--               front of the entry (`fileTime { ... }`); the `%opts, Start
--               => ...` argument lists are `merge(opts, { ... })`; the
--               predeclared ProcessItemID/ProcessLinkInfo/ProcessURI are
--               `false` PROCESS_PROC entries assigned at the end; a binary
--               value (`\$val`) is { ref = 'SCALAR', value = ... }.
--               Upstream oddities carried verbatim: the URI table's
--               FTPHost, FTPUserName, FTPPassword and second URI RawConv
--               miss a closing parenthesis (Perl's eval fails to compile
--               them, and so does the stand-in here); FTPUserName's Hook
--               reads the never-set URIUserNameLen; HotKey's
--               `chr $ch =~ /^[A-Z0-9]$/` takes chr() of the match result,
--               so its first branch is always taken; the INI-header test
--               `/^\[[InternetShortcut\][\x0d\x0a]/` is one character class.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')   -- (upstream `use Image::ExifTool qw(:DataAccess :Utils)`)
local Microsoft = require('lexiftool.Microsoft')
local ASF = require('lexiftool.ASF')    -- (for GetGUID)
local perl = require('lexiftool.perl')
local uv = perl.uv
local perlTruthy = perl.truthy
local length, substr = perl.length, perl.substr
local sprintf, num, chr = perl.sprintf, perl.num, perl.chr
local matches, isMatch, findAll = perl.matches, perl.isMatch, perl.findAll
local subst, tr, join = perl.subst, perl.tr, perl.join
local pack, unpack = perl.pack, perl.unpack
local Get8u, Get16u, Get32u = ExifTool.Get8u, ExifTool.Get16u, ExifTool.Get32u
local SetByteOrder = ExifTool.SetByteOrder
local GetTagTable = ExifTool.GetTagTable
local AddTagToTable = ExifTool.AddTagToTable
local ConvertUnixTime = ExifTool.ConvertUnixTime

local LNK = {}

-- (upstream predeclarations `sub ProcessItemID($$$); sub ProcessLinkInfo($$$);
--  sub ProcessURI($$$);`: the PROCESS_PROC entries below are `false` until
--  the subs are defined)

-- (port helper: Perl's `{ ..., %fileTime }` -- the entries of the spread
--  hash are added to the tagInfo)
local function spread(hash)
    return function(t)
        for k, v in pairs(hash) do
            if t[k] == nil then t[k] = v end
        end
        return t
    end
end

-- (port helper: Perl's argument list `%opts, Start => $pos, ...` -- a copy
--  of opts with the extra entries)
local function merge(opts, more)
    local t = {}
    for k, v in pairs(opts) do t[k] = v end
    for k, v in pairs(more) do t[k] = v end
    return t
end

-- (upstream's URI RawConv strings that miss a closing parenthesis: Perl's
--  eval of them fails to compile, which this stand-in reproduces)
local function evalSyntaxError()
    perl.die('syntax error at (eval) line 1, at EOF\n')
end

local fileAttributes = {
    BITMASK = {
        [0] = 'Read-only',
        [1] = 'Hidden',
        [2] = 'System',
        [3] = 'Volume', --(not used)
        [4] = 'Directory',
        [5] = 'Archive',
        [6] = 'Encrypted?', --(ref 2, not used in XP)
        [7] = 'Normal',
        [8] = 'Temporary',
        [9] = 'Sparse',
        [10] = 'Reparse point',
        [11] = 'Compressed',
        [12] = 'Offline',
        [13] = 'Not indexed',
        [14] = 'Encrypted',
    },
}

local fileTime = spread {
    Format = 'int64u',
    -- convert time from 100-ns intervals since Jan 1, 1601
    RawConv = function(_self, val) if perlTruthy(val) then return val end return nil end,
    ValueConv = function(_self, val) val=val/1e7-11644473600; return ConvertUnixTime(val,1) end,
    PrintConv = function(self, val) return self:ConvertDateTime(val) end,
}

-- (one key, 'B4BFCC3A-...', is a genuine duplicate upstream; Perl's hash
--  assignment keeps the later value just like this Lua table does)
-- luacheck: ignore 314
local guidLookup = {
    -- ref https://learn.microsoft.com/en-us/windows/win32/shell/knownfolderid
    ['008CA0B1-55B4-4C56-B8A8-4DE4B299D3BE'] = 'Account Pictures (per-user)',
    ['DE61D971-5EBC-4F02-A3A9-6C82895E5C04'] = 'Get Programs (virtual)',
    ['724EF170-A42D-4FEF-9F26-B60E846FBA4F'] = 'Administrative Tools (per-user)',
    ['B2C5E279-7ADD-439F-B28C-C41FE1BBF672'] = 'AppDataDesktop (per-user)',
    ['7BE16610-1F7F-44AC-BFF0-83E15F2FFCA1'] = 'AppDataDocuments (per-user)',
    ['7CFBEFBC-DE1F-45AA-B843-A542AC536CC9'] = 'AppDataFavorites (per-user)',
    ['559D40A3-A036-40FA-AF61-84CB430A4D34'] = 'AppDataProgramData (per-user)',
    ['A3918781-E5F2-4890-B3D9-A7E54332328C'] = 'Application Shortcuts (per-user)',
    ['1E87508D-89C2-42F0-8A7E-645A0F50CA58'] = 'Applications (virtual)',
    ['A305CE99-F527-492B-8B1A-7E76FA98D6E4'] = 'Installed Updates (virtual)',
    ['AB5FB87B-7CE2-4F83-915D-550846C9537B'] = 'Camera Roll (per-user)',
    ['9E52AB10-F80D-49DF-ACB8-4330F5687855'] = 'Temporary Burn Folder (per-user)',
    ['DF7266AC-9274-4867-8D55-3BD661DE872D'] = 'Programs and Features (virtual)',
    ['D0384E7D-BAC3-4797-8F14-CBA229B392B5'] = 'Administrative Tools (common)',
    ['C1BAE2D0-10DF-4334-BEDD-7AA20B227A9D'] = 'OEM Links (common)',
    ['0139D44E-6AFE-49F2-8690-3DAFCAE6FFB8'] = 'Programs (common)',
    ['A4115719-D62E-491D-AA7C-E74B8BE3B067'] = 'Start Menu (common)',
    ['82A5EA35-D9CD-47C5-9629-E15D2F714E6E'] = 'Startup (common)',
    ['B94237E7-57AC-4347-9151-B08C6C32D1F7'] = 'Templates (common)',
    ['0AC0837C-BBF8-452A-850D-79D08E667CA7'] = 'Computer (virtual)',
    ['4BFEFB45-347D-4006-A5BE-AC0CB0567192'] = 'Conflicts (virtual)',
    ['6F0CD92B-2E97-45D1-88FF-B0D186B8DEDD'] = 'Network Connections (virtual)',
    ['56784854-C6CB-462B-8169-88E350ACB882'] = 'Contacts (per-user)',
    ['82A74AEB-AEB4-465C-A014-D097EE346D63'] = 'Control Panel (virtual)',
    ['2B0F765D-C0E9-4171-908E-08A611B84FF6'] = 'Cookies (per-user)',
    ['B4BFCC3A-DB2C-424C-B029-7FE99A87C641'] = 'Desktop (per-user)',
    ['5CE4A5E9-E4EB-479D-B89F-130C02886155'] = 'DeviceMetadataStore (common)',
    ['FDD39AD0-238F-46AF-ADB4-6C85480369C7'] = 'Documents (per-user)',
    ['7B0DB17D-9CD2-4A93-9733-46CC89022E7C'] = 'Documents (per-user)',
    ['374DE290-123F-4565-9164-39C4925E467B'] = 'Downloads (per-user)',
    ['1777F761-68AD-4D8A-87BD-30B759FA33DD'] = 'Favorites (per-user)',
    ['FD228CB7-AE11-4AE3-864C-16F3910AB8FE'] = 'Fonts (fixed)',
    ['CAC52C1A-B53D-4EDC-92D7-6B2E8AC19434'] = 'Games (virtual)',
    ['054FAE61-4DD8-4787-80B6-090220C4B700'] = 'GameExplorer (per-user)',
    ['D9DC8A3B-B784-432E-A781-5A1130A75963'] = 'History (per-user)',
    ['52528A6B-B9E3-4ADD-B60D-588C2DBA842D'] = 'Homegroup (virtual)',
    ['9B74B6A3-0DFD-4F11-9E78-5F7800F2E772'] = 'User name (%USERNAME%) (virtual)',
    ['BCB5256F-79F6-4CEE-B725-DC34E402FD46'] = 'ImplicitAppShortcuts (per-user)',
    ['352481E8-33BE-4251-BA85-6007CAEDCF9D'] = 'Temporary Internet Files (per-user)',
    ['4D9F7874-4E0C-4904-967B-40B0D20C3E4B'] = 'The Internet (virtual)',
    ['1B3EA5DC-B587-4786-B4EF-BD1DC332AEAE'] = 'Libraries (per-user)',
    ['BFB9D5E0-C6A9-404C-B2B2-AE6DB6AF4968'] = 'Links (per-user)',
    ['F1B32785-6FBA-4FCF-9D55-7B8E7F157091'] = 'Local (per-user)',
    ['A520A1A4-1780-4FF6-BD18-167343C5AF16'] = 'LocalLow (per-user)',
    ['2A00375E-224C-49DE-B8D1-440DF7EF3DDC'] = 'None (fixed)',
    ['4BD8D571-6D19-48D3-BE97-422220080E43'] = 'Music (per-user)',
    ['2112AB0A-C86A-4FFE-A368-0DE96E47012E'] = 'Music (per-user)',
    ['C5ABBF53-E17F-4121-8900-86626FC2C973'] = 'Network Shortcuts (per-user)',
    ['D20BEEC4-5CA8-4905-AE3B-BF251EA09B53'] = 'Network (virtual)',
    ['31C0DD25-9439-4F12-BF41-7FF4EDA38722'] = '3D Objects (per-user)',
    ['2C36C0AA-5812-4B87-BFD0-4CD0DFB19B39'] = 'Original Images (per-user)',
    ['69D2CF90-FC33-4FB7-9A0C-EBB0F0FCB43C'] = 'Slide Shows (per-user)',
    ['A990AE9F-A03B-4E80-94BC-9912D7504104'] = 'Pictures (per-user)',
    ['33E28130-4E1E-4676-835A-98395C3BC3BB'] = 'Pictures (per-user)',
    ['DE92C1C7-837F-4F69-A3BB-86E631204A23'] = 'Playlists (per-user)',
    ['76FC4E2D-D6AD-4519-A663-37BD56068185'] = 'Printers (virtual)',
    ['9274BD8D-CFD1-41C3-B35E-B13F55A758F4'] = 'Printer Shortcuts (per-user)',
    ['5E6C858F-0E22-4760-9AFE-EA3317B67173'] = 'User Name (%USERNAME%) (fixed)',
    ['62AB5D82-FDC1-4DC3-A9DD-070D1D495D97'] = 'ProgramData (fixed)',
    ['905E63B6-C1BF-494E-B29C-65B732D3D21A'] = 'Program Files (fixed)',
    ['6D809377-6AF0-444B-8957-A3773F02200E'] = 'Program Files (fixed)',
    ['7C5A40EF-A0FB-4BFC-874A-C0F2E0B9FA8E'] = 'Program Files (fixed)',
    ['F7F1ED05-9F6D-47A2-AAAE-29D317C6F066'] = 'Common Files (fixed)',
    ['6365D5A7-0F0D-45E5-87F6-0DA56B6A4F7D'] = 'Common Files (fixed)',
    ['DE974D24-D9C6-4D3E-BF91-F4455120B917'] = 'Common Files (fixed)',
    ['A77F5D77-2E2B-44C3-A6A2-ABA601054A51'] = 'Programs (per-user)',
    ['DFDF76A2-C82A-4D63-906A-5644AC457385'] = 'Public (fixed)',
    ['C4AA340D-F20F-4863-AFEF-F87EF2E6BA25'] = 'Public Desktop (common)',
    ['ED4824AF-DCE4-45A8-81E2-FC7965083634'] = 'Public Documents (common)',
    ['3D644C9B-1FB8-4F30-9B45-F670235F79C0'] = 'Public Downloads (common)',
    ['DEBF2536-E1A8-4C59-B6A2-414586476AEA'] = 'GameExplorer (common)',
    ['48DAF80B-E6CF-4F4E-B800-0E69D84EE384'] = 'Libraries (common)',
    ['3214FAB5-9757-4298-BB61-92A9DEAA44FF'] = 'Public Music (common)',
    ['B6EBFB86-6907-413C-9AF7-4FC2ABF07CC5'] = 'Public Pictures (common)',
    ['E555AB60-153B-4D17-9F04-A5FE99FC15EC'] = 'Ringtones (common)',
    ['0482AF6C-08F1-4C34-8C90-E17EC98B1E17'] = 'Public Account Pictures (common)',
    ['2400183A-6185-49FB-A2D8-4A392A602BA3'] = 'Public Videos (common)',
    ['52A4F021-7B75-48A9-9F6B-4B87A210BC8F'] = 'Quick Launch (per-user)',
    ['AE50C081-EBD2-438A-8655-8A092E34987A'] = 'Recent Items (per-user)',
    ['1A6FDBA2-F42D-4358-A798-B74D745926C5'] = 'Recorded TV (common)',
    ['B7534046-3ECB-4C18-BE4E-64CD4CB7D6AC'] = 'Recycle Bin (virtual)',
    ['8AD10C31-2ADB-4296-A8F7-E4701232C972'] = 'Resources (fixed)',
    ['C870044B-F49E-4126-A9C3-B52A1FF411E8'] = 'Ringtones (per-user)',
    ['3EB685DB-65F9-4CF6-A03A-E3EF65729F3D'] = 'Roaming (per-user)',
    ['AAA8D5A5-F1D6-4259-BAA8-78E7EF60835E'] = 'RoamedTileImages (per-user)',
    ['00BCFC5A-ED94-4E48-96A1-3F6217F21990'] = 'RoamingTiles (per-user)',
    ['B250C668-F57D-4EE1-A63C-290EE7D1AA1F'] = 'Sample Music (common)',
    ['C4900540-2379-4C75-844B-64E6FAF8716B'] = 'Sample Pictures (common)',
    ['15CA69B3-30EE-49C1-ACE1-6B5EC372AFB5'] = 'Sample Playlists (common)',
    ['859EAD94-2E85-48AD-A71A-0969CB56A6CD'] = 'Sample Videos (common)',
    ['4C5C32FF-BB9D-43B0-B5B4-2D72E54EAAA4'] = 'Saved Games (per-user)',
    ['3B193882-D3AD-4EAB-965A-69829D1FB59F'] = 'Saved Pictures (per-user)',
    ['E25B5812-BE88-4BD9-94B0-29233477B6C3'] = 'Saved Pictures Library (per-user)',
    ['7D1D3A04-DEBB-4115-95CF-2F29DA2920DA'] = 'Searches (per-user)',
    ['B7BEDE81-DF94-4682-A7D8-57A52620B86F'] = 'Screenshots (per-user)',
    ['EE32E446-31CA-4ABA-814F-A5EBD2FD6D5E'] = 'Offline Files (virtual)',
    ['0D4C3DB6-03A3-462F-A0E6-08924C41B5D4'] = 'History (per-user)',
    ['190337D1-B8CA-4121-A639-6D472D16972A'] = 'Search Results (virtual)',
    ['98EC0E18-2098-4D44-8644-66979315A281'] = 'Microsoft Office Outlook (virtual)',
    ['7E636BFE-DFA9-4D5E-B456-D7B39851D8A9'] = 'Templates (per-user)',
    ['8983036C-27C0-404B-8F08-102D10DCFD74'] = 'SendTo (per-user)',
    ['7B396E54-9EC5-4300-BE0A-2482EBAE1A26'] = 'Gadgets (common)',
    ['A75D362E-50FC-4FB7-AC2C-A8BEAA314493'] = 'Gadgets (per-user)',
    ['A52BBA46-E9E1-435F-B3D9-28DAA648C0F6'] = 'OneDrive (per-user)',
    ['767E6811-49CB-4273-87C2-20F355E1085B'] = 'Camera Roll (per-user)',
    ['24D89E24-2F19-4534-9DDE-6A6671FBB8FE'] = 'Documents (per-user)',
    ['339719B5-8C47-4894-94C2-D8F77ADD44A6'] = 'Pictures (per-user)',
    ['625B53C3-AB48-4EC1-BA1F-A1EF4146FC19'] = 'Start Menu (per-user)',
    ['B97D20BB-F46A-4C97-BA10-5E3608430854'] = 'Startup (per-user)',
    ['43668BF8-C14E-49B2-97C9-747784D784B7'] = 'Sync Center (virtual)',
    ['289A9A43-BE44-4057-A41B-587A76D7E7F9'] = 'Sync Results (virtual)',
    ['0F214138-B1D3-4A90-BBA9-27CBC0C5389A'] = 'Sync Setup (virtual)',
    ['1AC14E77-02E7-4E5D-B744-2EB1AE5198B7'] = 'System32 (fixed)',
    ['D65231B0-B2F1-4857-A4CE-A8E7C6EA7D27'] = 'System32 (fixed)',
    ['A63293E8-664E-48DB-A079-DF759E0509F7'] = 'Templates (per-user)',
    ['9E3995AB-1F9C-4F13-B827-48B24B6C7174'] = 'User Pinned (per-user)',
    ['0762D272-C50A-4BB0-A382-697DCD729B80'] = 'Users (fixed)',
    ['5CD7AEE2-2219-4A67-B85D-6C9CE15660CB'] = 'Programs (per-user)',
    ['BCBD3057-CA5C-4622-B42D-BC56DB0AE516'] = 'Programs (per-user)',
    ['F3CE0F7C-4901-4ACC-8648-D5D44B04EF8F'] = 'Users Full Name (virtual)',
    ['A302545D-DEFF-464B-ABE8-61C8648D939B'] = 'Libraries (virtual)',
    ['18989B1D-99B5-455B-841C-AB7C74E4DDFC'] = 'MyVideos (per-user)',
    ['491E922F-5643-4AF4-A7EB-4E7A138D8174'] = 'Videos (per-user)',
    -- ref Google AI and from my samples
    ['00021401-0000-0000-C000-000000000046'] = 'Shell Link Class Identifier',
    ['20D04FE0-3AEA-1069-A2D8-08002B30309D'] = 'My Computer',
    ['450D8FBA-AD25-11D0-A2A8-0800361B3003'] = 'My Documents',
    ['B4BFCC3A-DB2C-424C-B029-7FE99A87C641'] = 'Desktop',
    ['F3364BA0-65B9-11CE-A9BA-00AA004AE661'] = 'Search Results Folder',
    ['04731B67-D933-450A-90E6-4ACD2E9408FE'] = 'CLSID_SearchFolder (Windows Search)',
    ['53F5630D-B6BF-11D0-94F2-00A0C91EFB8B'] = 'Device Class GUID for a volume',
    ['F42EE2D3-909F-4907-8871-4C22FC0BF756'] = 'Documents',
    ['17789161-0268-45B3-8557-013009765873'] = 'Local AppData',
    ['9E395ED8-512D-4315-9960-9110B74616C8'] = 'Recent Items',
    ['21EC2020-3AEA-1069-A2DD-08002B30309D'] = 'Control Panel Items',
    ['7007ACC7-3202-11D1-AAD2-00805FC1270E'] = 'Network Connections',
    ['26EE0668-A00A-44D7-9371-BEB064C98683'] = 'Control Panel',
    ['2559A1F1-21D7-11D4-BDAF-00C04F60B9F0'] = 'Windows Help and Support',
    ['031E4825-7B94-4DC3-B131-E946B44C8DD5'] = 'Libraries',
    ['22877A6D-37A1-461A-91B0-DBDA5AAEBC99'] = 'Recent Items',
    ['2559A1F3-21D7-11D4-BDAF-00C04F60B9F0'] = 'Run Dialog Box',
    ['3080F90D-D7AD-11D9-BD98-0000947B0257'] = 'Desktop',
    ['3080F90E-D7AD-11D9-BD98-0000947B0257'] = 'Task View',
    ['4336A54D-038B-4685-AB02-99BB52D3FB8B'] = 'Public User Root Folder',
    ['5399E694-6CE5-4D6C-8FCE-1D8870FDCBA0'] = 'Control Panel',
    ['59031A47-3F72-44A7-89C5-5595FE6B30EE'] = 'User Profile',
    ['871C5380-42A0-1069-A2EA-08002B30309D'] = 'Internet',
    ['ED228FDF-9EA8-4870-83B1-96B02CFE0D52'] = 'Game Explorer',
    ['A8CDFF1C-4878-43BE-B5FD-F8091C1C60D0'] = 'Documents',
    ['3ADD1653-EB32-4CB0-BBD7-DFA0ABB5ACCA'] = 'My Pictures',
    ['52205FD8-5DFB-447D-801A-D0B52F2E83E1'] = "User Files",
    ['D3162B92-9365-467A-956B-92703ACA08AF'] = 'User Documents',
    ['4234D49B-0245-4DF3-B780-3893943456E1'] = 'User Music',
    -- ref https://github.com/EricZimmerman/GuidMapping/blob/master/Resources/GuidToName.txt
    ['0C39A5CF-1A7A-40C8-BA74-8900E6DF5FCD'] = 'Recent Items',
    -- ref https://github.com/libyal/libfwsi/blob/main/documentation/Windows%20Shell%20Item%20format.asciidoc
    ['5E591A74-DF96-48D3-8D67-1733BCEE28BA'] = 'Delegate GUID',
    ['04731b67-d933-450a-90e6-4acd2e9408fe'] = 'Search Folder',
    ['DFFACDC5-679F-4156-8947-C5C76BC0B67F'] = 'Users Files',
    ['289af617-1cc3-42a6-926c-e6a863f0e3ba'] = 'My Computer',
    ['3134ef9c-6b18-4996-ad04-ed5912e00eb5'] = 'Recent Files',
    ['35786d3c-b075-49b9-88dd-029876e11c01'] = 'Portable Devices',
    ['3936e9e4-d92c-4eee-a85a-bc16d5ea0819'] = 'Frequent Places',
    ['59031a47-3f72-44a7-89c5-5595fe6b30ee'] = 'Shared Documents',
    ['640167b4-59b0-47a6-b335-a6b3c0695aea'] = 'Portable Media Devices',
    ['896664f7-12e1-490f-8782-c0835afd98fc'] = 'Libraries',
    ['9113a02d-00a3-46b9-bc5f-9c04daddd5d7'] = 'Enhanced Storage Data Source',
    ['9db7a13c-f208-4981-8353-73cc61ae2783'] = 'Previous Versions',
    ['b155bdf8-02f0-451e-9a26-ae317cfd7779'] = 'NetHood',
    ['c2b136e2-d50e-405c-8784-363c582bf43e'] = 'Wireless Devices',
    ['d34a6ca6-62c2-4c34-8a7c-14709c1ad938'] = 'Common Places',
    ['dffacdc5-679f-4156-8947-c5c76bc0b67f'] = 'Profile',
    ['ed50fc29-b964-48a9-afb3-15ebb9b97f36'] = 'PrintHood',
    ['f5fb2c77-0e2f-4a16-a381-3e560c68bc83'] = 'Removable Drives',
    -- ref https://learn.microsoft.com/en-us/windows/win32/wpd_sdk/supporting-autoplay
    ['80E170D2-1055-4A3E-B952-82CC4F8A8689'] = 'Content Type All',
    ['0FED060E-8793-4B1E-90C9-48AC389AC631'] = 'Content Type Appointment',
    ['4AD2C85E-5E2D-45E5-8864-4F229E3C6CF0'] = 'Content Type Audio',
    ['AA18737E-5009-48FA-AE21-85F24383B4E6'] = 'Content Type Audio Album',
    ['A1FD5967-6023-49A0-9DF1-F8060BE751B0'] = 'Content Type Calendar',
    ['DC3876E8-A948-4060-9050-CBD77E8A3D87'] = 'Content Type Certificate',
    ['EABA8313-4525-4707-9F0E-87C6808E9435'] = 'Content Type Contact',
    ['346B8932-4C36-40D8-9415-1828291F9DE9'] = 'Content Type Contact Group',
    ['680ADF52-950A-4041-9B41-65E393648155'] = 'Content Type Document',
    ['8038044A-7E51-4F8F-883D-1D0623D14533'] = 'Content Type Email',
    ['27E2E392-A111-48E0-AB0C-E17705A05F85'] = 'Content Type Folder',
    ['99ED0160-17FF-4C44-9D98-1D7A6F941921'] = 'Content Type Functional Object',
    ['0085E0A6-8D34-45D7-BC5C-447E59C73D48'] = 'Content Type Generic File',
    ['E80EAAF8-B2DB-4133-B67E-1BEF4B4A6E5F'] = 'Content Type Generic Message',
    ['EF2107D5-A52A-4243-A26B-62D4176D7603'] = 'Content Type Image',
    ['75793148-15F5-4A30-A813-54ED8A37E226'] = 'Content Type Image Album',
    ['5E88B3CC-3E65-4E62-BFFF-229495253AB0'] = 'Content Type Media Cast',
    ['9CD20ECF-3B50-414F-A641-E473FFE45751'] = 'Content Type Memo',
    ['00F0C3AC-A593-49AC-9219-24ABCA5A2563'] = 'Content Type Mixed Content Album',
    ['031DA7EE-18C8-4205-847E-89A11261D0F3'] = 'Content Type Network Association',
    ['1A33F7E4-AF13-48F5-994E-77369DFE04A3'] = 'Content Type Playlist',
    ['D269F96A-247C-4BFF-98FB-97F3C49220E6'] = 'Content Type Program',
    ['821089F5-1D91-4DC9-BE3C-BBB1B35B18CE'] = 'Content Type Section',
    ['63252F2C-887F-4CB6-B1AC-D29855DCEF6C'] = 'Content Type Task',
    ['60A169CF-F2AE-4E21-9375-9677F11C1C6E'] = 'Content Type Television',
    ['28D8D31E-249C-454E-AABC-34883168E634'] = 'Content Type Unspecified',
    ['9261B03C-3D78-4519-85E3-02C5E1F50BB9'] = 'Content Type Video',
    ['012B0DB7-D4C1-45D6-B081-94B87779614F'] = 'Content Type Video Album',
    ['0BAC070A-9F5F-4DA4-A8F6-3DE44D68FD6C'] = 'Content Type Wireless Profile',
}

-- common tag information for MTP GUID tags
local mtpGUID = spread {
    Format = 'undef[72]',
    ValueConv = function(self, val) return self:Decode(val, 'UTF16') end,
    SeparateTable = 'GUID',
    PrintConv = guidLookup,
}

-- Information extracted from LNK (Windows Shortcut) files
LNK.Main = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Other' },
    VARS = { ID_FMT = 'hex' },    -- print hex ID's in documentation
    NOTES = 'Information extracted from MS Shell Link (Windows shortcut) files.',
    -- maybe the Flags aren't very useful to the user (since they are
    -- mainly structural), but extract them anyway for completeness
    [0x14] = {
        Name = 'Flags',
        Format = 'int32u',
        PrintConv = { BITMASK = {
            [0] = 'IDList',
            [1] = 'LinkInfo',
            [2] = 'Description',
            [3] = 'RelativePath',
            [4] = 'WorkingDir',
            [5] = 'CommandArgs',
            [6] = 'IconFile',
            [7] = 'Unicode',
            [8] = 'NoLinkInfo',
            [9] = 'ExpString',
            [10] = 'SeparateProc',
            [12] = 'DarwinID',
            [13] = 'RunAsUser',
            [14] = 'ExpIcon',
            [15] = 'NoPidAlias',
            [17] = 'RunWithShim',
            [18] = 'NoLinkTrack',
            [19] = 'TargetMetadata',
            [20] = 'NoLinkPathTracking',
            [21] = 'NoKnownFolderTracking',
            [22] = 'NoKnownFolderAlias',
            [23] = 'LinkToLink',
            [24] = 'UnaliasOnSave',
            [25] = 'PreferEnvPath',
            [26] = 'KeepLocalIDList',
        }},
    },
    [0x18] = {
        Name = 'FileAttributes',
        Format = 'int32u',
        SeparateTable = 'FileAttributes',
        PrintConv = fileAttributes,
    },
    [0x1c] = fileTime {
        Name = 'CreateDate',
        Groups = { [2] = 'Time' },
        -- %fileTime,
    },
    [0x24] = fileTime {
        Name = 'AccessDate',
        Groups = { [2] = 'Time' },
        -- %fileTime,
    },
    [0x2c] = fileTime {
        Name = 'ModifyDate',
        Groups = { [2] = 'Time' },
        -- %fileTime,
    },
    [0x34] = {
        Name = 'TargetFileSize',
        Format = 'int32u',
    },
    [0x38] = {
        Name = 'IconIndex',
        Format = 'int32u',
        PrintConv = function(_self, val) if perlTruthy(val) then return val end return '(none)' end,
        -- (seen 0xffffffff)
    },
    [0x3c] = {
        Name = 'RunWindow',
        Format = 'int32u',
        PrintConv = {
            [0] = 'Hide',
            [1] = 'Normal',
            [2] = 'Show Minimized',
            [3] = 'Show Maximized',
            [4] = 'Show No Activate',
            [5] = 'Show',
            [6] = 'Minimized',
            [7] = 'Show Minimized No Activate',
            [8] = 'Show NA',
            [9] = 'Restore',
            [10] = 'Show Default',
        },
    },
    [0x40] = {
        Name = 'HotKey',
        Format = 'int32u',
        PrintHex = 1,
        PrintConv = {
            OTHER = function(val)
                local ch = val & 0xff
                -- (Perl parses `chr $ch =~ /^[A-Z0-9]$/` as chr() of the match
                --  result, "\x01" or "\0" -- always true)
                if perlTruthy(chr(isMatch(ch, [[^[A-Z0-9]$]]) and 1 or 0)) then
                    ch = chr(ch)
                elseif ch >= 0x70 and ch <= 0x87 then
                    ch = 'F' .. (ch - 0x6f)
                elseif ch == 0x90 then
                    ch = 'Num Lock'
                elseif ch == 0x91 then
                    ch = 'Scroll Lock'
                else
                    ch = sprintf('Unknown (0x%x)', ch)
                end
                if val & 0x400 ~= 0 then ch = 'Alt-' .. ch end
                if val & 0x200 ~= 0 then ch = 'Control-' .. ch end
                if val & 0x100 ~= 0 then ch = 'Shift-' .. ch end
                return ch
            end,
            [0x00] = '(none)',
            -- these entries really only for documentation
            [0x90] = 'Num Lock',
            [0x91] = 'Scroll Lock',
           ["0x30'-'0x39"] = "0-9",
           ["0x41'-'0x5a"] = "A-Z",
           ["0x70'-'0x87"] = "F1-F24",
           [0x100] = 'Shift',
           [0x200] = 'Control',
           [0x400] = 'Alt',
        },
    },
    -- note: tags 0x100xx-0x300xx are synthesized tag ID's
    [0x10000] = {
        Name = 'ItemID',
        SubDirectory = { TagTable = 'lexiftool.LNK.ItemID' },
    },
    [0x20000] = {
        Name = 'LinkInfo',
        SubDirectory = { TagTable = 'lexiftool.LNK.LinkInfo' },
    },
    [0x30004] = 'Description',
    [0x30008] = 'RelativePath',
    [0x30010] = 'WorkingDirectory',
    [0x30020] = 'CommandLineArguments',
    [0x30040] = 'IconFileName',
    -- note: tags 0xa000000x are actually ID's (not indices)
    [0xa0000000] = {
        Name = 'UnknownData',
        SubDirectory = { TagTable = 'lexiftool.LNK.UnknownData' },
    },
    [0xa0000001] = {
        Name = 'EnvVarData',
        SubDirectory = { TagTable = 'lexiftool.LNK.EnvVarData' },
    },
    [0xa0000002] = {
        Name = 'ConsoleData',
        SubDirectory = { TagTable = 'lexiftool.LNK.ConsoleData' },
    },
    [0xa0000003] = {
        Name = 'TrackerData',
        SubDirectory = { TagTable = 'lexiftool.LNK.TrackerData' },
    },
    [0xa0000004] = {
        Name = 'ConsoleFEData',
        SubDirectory = { TagTable = 'lexiftool.LNK.ConsoleFEData' },
    },
    [0xa0000005] = {
        Name = 'SpecialFolderData',
        SubDirectory = { TagTable = 'lexiftool.LNK.UnknownData' },
    },
    [0xa0000006] = {
        Name = 'DarwinData',
        SubDirectory = { TagTable = 'lexiftool.LNK.UnknownData' },
    },
    [0xa0000007] = {
        Name = 'IconEnvData',
        SubDirectory = { TagTable = 'lexiftool.LNK.UnknownData' },
    },
    [0xa0000008] = {
        Name = 'ShimData',
        SubDirectory = { TagTable = 'lexiftool.LNK.UnknownData' },
    },
    [0xa0000009] = {
        Name = 'PropertyStoreData',
        SubDirectory = { TagTable = 'lexiftool.LNK.UnknownData' },
    },
    [0xa000000b] = {
        Name = 'KnownFolderData',
        SubDirectory = { TagTable = 'lexiftool.LNK.UnknownData' },
    },
    [0xa000000c] = {
        Name = 'VistaIDListData',
        SubDirectory = { TagTable = 'lexiftool.LNK.UnknownData' },
    },
}

-- ref: https://helgeklein.com/blog/dissecting-a-shortcut/
-- ref: https://github.com/Matmaus/LnkParse3/blob/master/LnkParse3/target_factory.py
-- Note: The ItemID raw data includes the leading 2-byte size word
LNK.ItemID = {
    GROUPS = { [2] = 'Other' },
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    [0x00] = {{
        Name = 'ControlPanelCPL',  -- special ID 0xffffffxx
        Condition = function(_self, valPt) return isMatch(valPt, [[(?s)^.{5}\xff{3}]]) end,
        SubDirectory = { TagTable = 'lexiftool.LNK.ControlPanelCPL' },
    },{
        Name = 'GameFolderInfo',   -- special ID 0x49534647
        Condition = function(_self, valPt) return isMatch(valPt, [[(?s)^.{4}GFSI]]) end,
        SubDirectory = { TagTable = 'lexiftool.LNK.GameFolderInfo' },
    },{
        Name = 'PropertyStore',    -- ID 0x23febbee
        Condition = function(_self, valPt) return isMatch(valPt, [[^.{6}\xee\xbb\xfe\x23]]) end,
        SubDirectory = { TagTable = 'lexiftool.LNK.PropertyStore' },
    },{
        Name = 'MTPType2',         -- ID 0x10312005
        Condition = function(_self, valPt) return isMatch(valPt, [[^.{6}\x05\x20\x31\x10]]) end,
        SubDirectory = { TagTable = 'lexiftool.LNK.MTPType2' },
    },{
        Name = 'Item00Info',
        SubDirectory = { TagTable = 'lexiftool.LNK.Item00Info' },
    }},
    [0x01] = {
        Name = 'ControlPanelInfo',
        SubDirectory = { TagTable = 'lexiftool.LNK.ControlPanelInfo' },
    },
    [0x1e] = { -- (seems to be decoding the same as 0x1f)
        Name = 'RootFolder',
        SubDirectory = { TagTable = 'lexiftool.LNK.RootFolder' },
    },
    [0x1f] = {
        Name = 'RootFolder',
        SubDirectory = { TagTable = 'lexiftool.LNK.RootFolder' },
    },
    -- 0x20-0x2f MyComputer (even ID's have GUID, odd have name)
    [0x2e] = { -- (have only seen 0x2e so far)
        Name = 'VolumeGUID',
        RawConv = function(_self, val) if length(val) >= 20 then return val end return nil end,
        -- seen 0x14 and 0x32 bytes long, but GUID was last 16 bytes in both cases
        ValueConv = function(_self, val) return ASF.GetGUID(substr(val,-16)) end,
        SeparateTable = 'GUID',
        PrintConv = guidLookup,
    },
    [0x2f] = {
        Name = 'VolumeName',
        ValueConv = function(_self, val) local s = substr(val, 3); s = subst(s, [[\0+$]], ''); return s end,
    },
    -- 0x30-0x3f ShellFSFolder
    [0x31] = {
        Name = 'TargetInfo',
        SubDirectory = { TagTable = 'lexiftool.LNK.TargetInfo' },
    },
    -- 0x40-0x4f NetworkLocation
    [0x40] = {
        Name = 'NetworkLocation',
        -- extract ASCII strings (Location + optional Description and Comments)
        ValueConv = function(_self, val)
            val = substr(val, 6)
            local strs = findAll(val, [[([\x20-\x7f]+)]])
            if #strs == 0 then return { ref = 'SCALAR', value = val } end
            if #strs == 1 then return strs[1] end
            return strs
        end,
    },
    [0x52] = {
        Name = 'CompressedFolder',
        Binary = 1, -- (not implemented)
    },
    [0x61] = {
        Name = 'URI',
        SubDirectory = { TagTable = 'lexiftool.LNK.URI' },
    },
    [0x70] = {
        Name = 'ControlPanelShellItem',
        ValueConv = function(_self, val) return ASF.GetGUID(substr(val,14)) end,
        SeparateTable = 'GUID',
        PrintConv = guidLookup,
    },
    [0x71] = {
        Name = 'ControlPanelShellItem',
        ValueConv = function(_self, val) return ASF.GetGUID(substr(val,14)) end,
        SeparateTable = 'GUID',
        PrintConv = guidLookup,
    },
    [0x72] = { Name = 'Printers', Binary = 1 },
    [0x73] = { Name = 'CommonPlacesFolder', Binary = 1 },
    [0x74] = {
        Name = 'UsersFilesFolder',
        SubDirectory = { TagTable = 'lexiftool.LNK.UsersFilesFolder' },
    },
    [0xff] = { --PH
        Name = 'VendorData',
        -- extract Unicode and ASCII strings from vendor data (min length 3 chars, null terminated)
        -- or return binary data if no strings
        ValueConv = function(_self, val)
            local strs = findAll(val, [[([\x21-\x7f]\0[\x20-\x7f]\0(?:[\x20-\x7f]\0)+\0|[\x21-\x7f][\x20-\x7f][\x20-\x7f]+)\0]])
            for i = 1, #strs do strs[i] = tr(strs[i], [[\0]], '', 'd') end -- convert all to ASCII
            if #strs == 0 then return { ref = 'SCALAR', value = val } end
            if #strs == 1 then return strs[1] end
            return strs
        end,
    },
--
-- extension blocks
--
    [0xbeef0003] = {
        Name = 'Beef0003',
        SubDirectory = { TagTable = 'lexiftool.LNK.Beef0003' },
    },
    [0xbeef0004] = {
        Name = 'Beef0004',
        SubDirectory = { TagTable = 'lexiftool.LNK.Beef0004' },
    },
    [0xbeef0014] = {
        Name = 'Beef0014',
        SubDirectory = { TagTable = 'lexiftool.LNK.Beef0014' },
    },
    [0xbeef0025] = {
        Name = 'Beef0025',
        SubDirectory = { TagTable = 'lexiftool.LNK.Beef0025' },
    },
    [0xbeef0026] = {{
        Name = 'Beef0026a',
        Condition = function(_self, valPt) return isMatch(valPt, [=[^.{8}[\x11\x10\x12\x34\x31]]=]) end,
        SubDirectory = { TagTable = 'lexiftool.LNK.Beef0026a' },
    },{
        Name = 'Unknown_beef0026',
        Binary = 1,
    }},
}

LNK.RootFolder = {
    GROUPS = { [2] = 'Other' },
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    -- (is this useful?) 0x03 => 'FolderID',
    [0x03] = {
        Name = 'SortIndex',
        PrintHex = 1,
        PrintConv = { --https://github.com/Matmaus/LnkParse3/blob/master/LnkParse3/target/root_folder.py
            [0x00] = 'Internet Explorer',
            [0x42] = 'Libraries',
            [0x44] = 'Users',
            [0x48] = 'My Documents',
            [0x4c] = 'Public Folder',
            [0x50] = 'My Computer',
            [0x54] = 'Users Libraries',
            [0x58] = 'My Network Places/Network',
            -- 0x5b - ChatGPT thinks this is for the user home folder
            [0x60] = 'Recycle Bin',
            [0x68] = 'Internet Explorer',
            [0x70] = 'Control Panel',
            [0x78] = 'Recycle Bin',
            [0x80] = 'My Games',
        },
    },
    [0x04] = {
        Name = 'RootFolderGUID',
        Format = 'undef[16]',
        ValueConv = function(_self, val) return ASF.GetGUID(val) end,
        SeparateTable = 'GUID',
        PrintConv = guidLookup,
    },
}

-- ref https://helgeklein.com/blog/dissecting-a-shortcut/
LNK.TargetInfo = {
    GROUPS = { [2] = 'Other' },
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    -- (always 0?) 3 => 'TargetFileFlags',
    -- (duplicate tag name) 4 => { Name => 'TargetFileSize', Format => 'int32u' },
    [8] = {
        Name = 'TargetFileModifyDate',
        Groups = { [2] = 'Time' },
        Format = 'int32u',
        RawConv = function(_self, val) if perlTruthy(val) then return val end return nil end, -- (ignore zero dates)
        ValueConv = function(_self, val) return LNK.DOSTime(val) end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    [12] = {
        Name = 'TargetFileAttributes',
        SeparateTable = 'FileAttributes',
        PrintConv = fileAttributes,
    },
    [14] = {
        Name = 'TargetFileDOSName',
        Format = 'undef[$size-14]',
        -- (the RawConv's value is that of the branch's last statement)
        RawConv = function(self, val)
            -- allow for the possibility of Unicode here
            if isMatch(val, [=[^[\x20-\x7f]\0[\x20-\x7f]]=]) then
                local ok, c1 = isMatch(val, [[(?s)^((.{2})*?)\0\0]])
                if ok then val = c1 end
                val = self:Decode(val, 'UTF16', 'II')
                return val
            else
                local ok, c1 = isMatch(val, [[(?s)^(.*?)\0]])
                if ok then val = c1; return val end
                return ''   -- (the value of the failed match)
            end
        end,
    },
}

-- https://github.com/Matmaus/LnkParse3/blob/master/LnkParse3/target/control_panel_cpl.py
LNK.ControlPanelCPL = {
    GROUPS = { [2] = 'Other' },
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    [4] = {
        Name = 'Item00SpecialType',
        Format = 'int32u',
        PrintConv = function(_self, val) return sprintf("0x%.8x (ControlPanelCPL)", val) end,
        -- seen 0xffffff37
    },
    [12] = {
        Name = 'CPLFilePath',
        Condition = function(_self, valPt) return not isMatch(valPt, [[^\0]]) end,
        Format = 'undef[$size-12]',
        -- pull out all valid ASCII strings
        RawConv = function(self, val)
            self.CPLIsASCII = 1
            local strs = findAll(val, [[[^\0]+]])
            if #strs <= 1 then return strs[1] end
            return strs
        end,
    },
    [24] = {
        Name = 'CPLFilePath',
        Condition = function(self) return not perlTruthy(self.CPLIsASCII) end,
        Format = 'undef[$size-24]',
        -- pull out all valid Unicode strings
        RawConv = function(self, val)
            local strs = {}
            val = val .. "\0\0" -- allow for missing terminator
            while true do
                local ok, uni = isMatch(val, [[(?s)^((?:..)*?)\0\0]])
                if not ok then break end
                val = substr(val, length(uni) + 2)
                if isMatch(uni, [[^[\x20-\x7f]+$]]) then
                    -- also extract random ASCII data
                    strs[#strs + 1] = uni
                else
                    local str = self:Decode(uni, 'UTF16')
                    if perlTruthy(length(str)) then strs[#strs + 1] = str end
                end
            end
            if #strs <= 1 then return strs[1] end
            return strs
        end,
    },
}

-- ref 5
LNK.GameFolderInfo = {
    GROUPS = { [2] = 'Other' },
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    [4] = {
        Name = 'Item00SpecialType',
        Format = 'int32u',
        PrintConv = function(_self, val) return sprintf("0x%.8x (GameFolder)", val) end,
        -- val = 0x49534647
    },
    -- (nothing else known)
}

-- ref 5
LNK.PropertyStore = {
    GROUPS = { [2] = 'Other' },
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    [12] = {
        Name = 'PropertyStoreGUID',
        Format = 'undef[18]',
        ValueConv = function(_self, val) return ASF.GetGUID(substr(val,2)) end,
        SeparateTable = 'GUID',
        PrintConv = guidLookup,
    },
}

-- ref 5
LNK.MTPType2 = {
    GROUPS = { [2] = 'Other' },
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    [38] = {
        Name = 'StorageNameLen',
        Format = 'int32u',
        RawConv = function(self, val) self.StorageNameLen = val; return nil end,
        Hidden = 1,
    },
    [42] = {
        Name = 'StorageIDLen',
        Format = 'int32u',
        RawConv = function(self, val) self.StorageIDLen = val; return nil end,
        Hidden = 1,
    },
    [46] = {
        Name = 'FileSystemNameLen',
        Format = 'int32u',
        RawConv = function(self, val) self.FileSystemNameLen = val; return nil end,
        Hidden = 1,
    },
    [50] = {
        Name = 'NumGUIDs',
        Format = 'int32u',
        RawConv = function(self, val) self.NumGUIDs = val; return nil end,
        Hidden = 1,
    },
    [54] = {
        Name = 'MTPStorageName',
        Format = 'undef[$$self{StorageNameLen} * 2]',
        ValueConv = function(self, val) return self:Decode(val, "UTF16") end,
        Hook = function(self) return num(self.StorageNameLen) * 2 end,
    },
    [54.1] = {
        Name = 'MTPStorageID',
        Format = 'undef[$$self{StorageIDLen} * 2]',
        ValueConv = function(self, val) return self:Decode(val, "UTF16") end,
        Hook = function(self) return num(self.StorageIDLen) * 2 end,
    },
    [54.2] = {
        Name = 'MTPFileSystem',
        Format = 'undef[$$self{FileSystemNameLen} * 2]',
        ValueConv = function(self, val) return self:Decode(val, "UTF16") end,
        Hook = function(self) return num(self.FileSystemNameLen) * 2 end,
    },
    [56] = mtpGUID {
        Name = 'MTP_GUID1',
        Condition = function(self) return num(self.NumGUIDs) >= 1 end,
        -- %mtpGUID,
    },
    [134] = mtpGUID {
        Name = 'MTP_GUID2',
        Condition = function(self) return num(self.NumGUIDs) >= 2 end,
        -- %mtpGUID,
    },
    [212] = mtpGUID {
        Name = 'MTP_GUID3',
        Condition = function(self) return num(self.NumGUIDs) >= 3 end,
        -- %mtpGUID,
    },
    [290] = mtpGUID {
        Name = 'MTP_GUID4',
        Condition = function(self) return num(self.NumGUIDs) >= 4 end,
        -- %mtpGUID,
    },
    [368] = mtpGUID {
        Name = 'MTP_GUID5',
        Condition = function(self) return num(self.NumGUIDs) >= 5 end,
        -- %mtpGUID,
    },
    [446] = mtpGUID {
        Name = 'MTP_GUID6',
        Condition = function(self) return num(self.NumGUIDs) >= 6 end,
        -- %mtpGUID,
    },
    [524] = mtpGUID {
        Name = 'MTP_GUID7',
        Condition = function(self) return num(self.NumGUIDs) >= 7 end,
        -- %mtpGUID,
    },
    [602] = mtpGUID {
        Name = 'MTP_GUID8',
        Condition = function(self) return num(self.NumGUIDs) >= 8 end,
        -- %mtpGUID,
    },
    -- (arbitrarily decode only the first 8 MTP GUID's)
}

-- ref PH
LNK.Item00Info = {
    GROUPS = { [2] = 'Other' },
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    -- 4 - int16u data size
    [6] = {
        Name = 'Item00Type',
        Format = 'int32u',
        PrintHex = 1,
        PrintConv = {
            -- (never used because these are handled separately,
            --  but included here for documentation)
            [0x23febbee] = 'PropertyStoreGUID',
            [0x10312005] = 'MTPType2',
            -- 0x00000000 ?
            -- 0x07192006 ?
        },
    },
    -- extract property strings (seen with Item00Type == 0x0)
    [20] = {
        Name = 'Prop1Len',
        Format = 'int16u',
        RawConv = function(self, val) self.Prop1Len = val; return nil end,
        Hidden = 1,
    },
    [22] = {
        Name = 'Prop2Len',
        Format = 'int16u',
        RawConv = function(self, val) self.Prop2Len = val; return nil end,
        Hidden = 1,
    },
    [23] = {
        Name = 'Dummy',
        RawConv = function() return nil end,
        Hidden = 1,
        -- decide whether or not this looks like property strings
        Hook = function(self, _format, _varSize, size)
            if 24 + 2 * (num(self.Prop1Len) + num(self.Prop2Len)) ~= size then
                -- doesn't look like property strings
                self.Prop1Len = nil
                self.Prop2Len = nil
            end
        end,
    },
    [24] = {
        Name = 'PropertyString1',
        Condition = function(self) return perlTruthy(self.Prop1Len) end,
        Format = 'undef[$$self{Prop1Len} * 2]',
        RawConv = function(self, val) return self:Decode(val, "UTF16") end,
        Hook = function(self) return num(self.Prop1Len) * 2 end,
    },
    [24.1] = {
        Name = 'PropertyString2',
        Condition = function(self) return perlTruthy(self.Prop2Len) end,
        Format = 'undef[$$self{Prop2Len} * 2]',
        RawConv = function(self, val) return self:Decode(val, "UTF16") end,
    },
}

-- ref https://github.com/Matmaus/LnkParse3/blob/master/LnkParse3/target/control_panel_category.py
LNK.ControlPanelInfo = {
    GROUPS = { [2] = 'Other' },
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    [8] = {
        Name = 'ControlPanelCategory',
        Format = 'int32u',
        PrintConv = {
            [0] = 'All Control Panel Items',
            [1] = 'Appearance and Personalization',
            [2] = 'Hardware and Sound',
            [3] = 'Network and Internet',
            [4] = 'Sounds, Speech, and Audio Devices',
            [5] = 'System and Security',
            [6] = 'Clock, Language, and Region',
            [7] = 'Ease of Access',
            [8] = 'Programs',
            [9] = 'User Accounts',
            [10] = 'Security Center',
            [11] = 'Mobile PC',
        },
    },
}

LNK.URI = {
    GROUPS = { [2] = 'Other' },
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    -- 3 - flags: 0x80 set if URI is in Unicode
    [3] = {
        Name = 'URIFlags',
        Hidden = 1,
        RawConv = function(self, val) self.URIFlags = val; return nil end,
    },
    [4] = {
        Name = 'URIDataSize',
        Format = 'int16u',
        Hidden = 1,
        RawConv = function(self, val) self.URIDataSize = val; return nil end,
    },
    [8] = {
        Name = 'URI',
        Condition = function(self) return num(self.URIDataSize, '==') == 0 end,
        Format = 'undef[$size-8]',
        RawConv = function(self, val) return self:Decode(val, (num(self.URIFlags, '&') & 0x80) ~= 0 and "UTF16" or "Latin") end,
    },
-- all of the following tags are NC because a sample wasn't available
    [14] = fileTime {
        Name = 'TimeStamp',
        Condition = function(self) return num(self.URIDataSize) > 0 end,
        Groups = { [2] = 'Time' },
        -- %fileTime,
    },
    [42] = {
        Name = 'FTPHostLen',
        Condition = function(self) return num(self.URIDataSize) > 0 end,
        Hidden = 1,
        Format = 'int32u',
        RawConv = function(self, val) self.FTPHostLen = val; return nil end,
    },
    [46] = {
        Name = 'FTPHost',
        Condition = function(self) return num(self.URIDataSize) > 0 end,
        Format = 'undef[$$self{FTPHostLen}]',
        RawConv = evalSyntaxError, -- ('$self->Decode($val, ($$self{URIFlags} & 0x80) ? "UTF16" : "Latin"')
        Hook = function(self) return num(self.FTPHostLen) - 1 end, -- (subtract 1 so offset 47 becomes 46)
    },
    [47] = {
        Name = 'FTPUserNameLen',
        Condition = function(self) return num(self.URIDataSize) > 0 end,
        Hidden = 1,
        Format = 'int32u',
        RawConv = function(self, val) self.FTPUserNameLen = val; return nil end,
    },
    [51] = {
        Name = 'FTPUserName',
        Condition = function(self) return num(self.URIDataSize) > 0 end,
        Format = 'undef[$$self{FTPUserNameLen}]',
        RawConv = evalSyntaxError, -- ('$self->Decode($val, ($$self{URIFlags} & 0x80) ? "UTF16" : "Latin"')
        Hook = function(self) return num(self.URIUserNameLen) - 1 end,
    },
    [52] = {
        Name = 'FTPPasswordLen',
        Condition = function(self) return num(self.URIDataSize) > 0 end,
        Hidden = 1,
        Format = 'int32u',
        RawConv = function(self, val) self.FTPPasswordLen = val; return nil end,
    },
    [56] = {
        Name = 'FTPPassword',
        Condition = function(self) return num(self.URIDataSize) > 0 end,
        Format = 'undef[$$self{FTPPasswordLen}]',
        RawConv = evalSyntaxError, -- ('$self->Decode($val, ($$self{URIFlags} & 0x80) ? "UTF16" : "Latin"')
        Hook = function(self) return num(self.FTPPasswordLen) - 1 end,
    },
    [57] = {
        Name = 'URI',
        Condition = function(self) return num(self.URIDataSize) > 0 end,
        Format = 'undef[$size-57-$varSize]',
        RawConv = evalSyntaxError, -- ('$self->Decode($val, ($$self{URIFlags} & 0x80) ? "UTF16" : "Latin"')
    },
}

-- ref https://github.com/EricZimmerman/ExtensionBlocks/blob/master/ExtensionBlocks/Beef0003.cs
LNK.Beef0003 = {
    GROUPS = { [2] = 'Other' },
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    [8] = {
        Name = 'UnknownGUID',
        Format = 'undef[16]',
        ValueConv = function(_self, val) return ASF.GetGUID(val) end,
        SeparateTable = 'GUID',
        PrintConv = guidLookup,
    },
}

-- ref https://github.com/EricZimmerman/ExtensionBlocks/blob/master/ExtensionBlocks/Beef0004.cs
LNK.Beef0004 = {
    GROUPS = { [2] = 'Other' },
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    NOTES = 'TargetInfo extensions.',
    -- 0 - int16u ExtensionSize
    [2] = {
        Name = 'Beef0004Ver',
        Format = 'int16u',
        Hidden = 1,
        RawConv = function(self, val) self.Beef0004Ver = val; return nil end,
    },
    -- 2 - int16u ExtensionVersion
    -- 4 - int16u ExtensionType = 0x0004
    -- 6 - int16u ExtensionMagic = 0xbeef
    [8] = {
        Name = 'TargetFileCreateDate',
        Groups = { [2] = 'Time' },
        Format = 'int32u',
        ValueConv = function(_self, val) return LNK.DOSTime(val) end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    [12] = {
        Name = 'TargetFileAccessDate',
        Groups = { [2] = 'Time' },
        Format = 'int32u',
        ValueConv = function(_self, val) return LNK.DOSTime(val) end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    [16] = {
        Name = 'OperatingSystem',
        Format = 'int16u',
        PrintHex = 1,
        PrintConv = {
            [0x14] = 'Windows XP, 2003',
            [0x26] = 'Windows Vista',
            [0x2a] = 'Windows 2008, 7, 8',
            [0x2e] = 'Windows 8.1, 10',
        },
        Hook = function(self)
            local varSize = 0   -- (the Lua Hook returns the $varSize delta)
            if num(self.Beef0004Ver) >= 7 then varSize = varSize + 18 end
            if num(self.Beef0004Ver) >= 3 then varSize = varSize + 2 end
            if num(self.Beef0004Ver) >= 9 then varSize = varSize + 4 end
            if num(self.Beef0004Ver) >= 8 then varSize = varSize + 4 end
            return varSize
        end,
    },
    [18] = {
        Name = 'TargetFileName',
        Format = 'undef[$size - 20 - $varSize]',    -- (drop offset word after name)
        -- extract two strings if they exist
        RawConv = function(self, val)
            local a = findAll(val, [[(?s)((?:..)*?)\0\0]])
            for i = 1, #a do a[i] = self:Decode(a[i], "UTF16") end
            if #a > 1 then return a end
            return a[1]
        end,
    },
}

-- ref 4
LNK.Beef0014 = {
    GROUPS = { [2] = 'Other' },
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    NOTES = 'URI extensions.',
    [0] = 'AbsoluteURI',
    [1] = 'URIAuthority',
    [2] = 'DisplayURI',
    [3] = 'URIDomain',
    [4] = 'URIExtension',
    [5] = 'URIFragment',
    [6] = 'URIHost',
    [7] = 'URIPassword',
    [8] = 'URIPath',
    [9] = 'URIPathAndQuery',
    [10] = 'URIQuery',
    [11] = 'RawURI',
    [12] = 'URISchemeName',
    [13] = 'URIUserInfo',
    [14] = 'URIUserName',
    [15] = 'URIHostType',
    [16] = 'URIPort',
    [17] = 'URIScheme',
    [18] = 'URIZone',
}

-- ref https://github.com/EricZimmerman/ExtensionBlocks/blob/master/ExtensionBlocks/Beef0025.cs
LNK.Beef0025 = {
    GROUPS = { [2] = 'Other' },
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    [0x0c] = fileTime {
        Name = 'FileTime1',
        Groups = { [2] = 'Time' },
        -- %fileTime,
    },
    [0x14] = fileTime {
        Name = 'FileTime2',
        Groups = { [2] = 'Time' },
        -- %fileTime,
    },
}

-- ref https://github.com/EricZimmerman/ExtensionBlocks/blob/master/ExtensionBlocks/Beef0026.cs
LNK.Beef0026a = {
    GROUPS = { [2] = 'Other' },
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    [0x0c] = fileTime {
        Name = 'CreateDate',
        Groups = { [2] = 'Time' },
        -- %fileTime,
    },
    [0x14] = fileTime {
        Name = 'ModifyDate',
        Groups = { [2] = 'Time' },
        -- %fileTime,
    },
    [0x1c] = fileTime {
        Name = 'LastAccessDate',
        Groups = { [2] = 'Time' },
        -- %fileTime,
    },
}

-- ref https://github.com/Matmaus/LnkParse3/blob/master/LnkParse3/target/users_files_folder.py
LNK.UsersFilesFolder = {
    GROUPS = { [2] = 'Other' },
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    [0x04] = {
        Name = 'IgnoreThis',
        Hidden = 1,
        Format = 'int16u',
        RawConv = function() return nil end,
        Hook = function(_self, _format, _varSize, _size, dataPt, pos) return Get16u(dataPt, pos) end, -- skip inner data
    },
    [0x06] = {
        Name = 'DelegateClassGUID',
        Format = 'undef[16]',
        ValueConv = function(_self, val) return ASF.GetGUID(val) end,
        SeparateTable = 'GUID',
        PrintConv = guidLookup,
    },
    [0x16] = {
        Name = 'DelegateFolderGUID',
        Format = 'undef[16]',
        ValueConv = function(_self, val) return ASF.GetGUID(val) end,
        SeparateTable = 'GUID',
        PrintConv = guidLookup,
    },
}

LNK.LinkInfo = {
    GROUPS = { [2] = 'Other' },
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    FORMAT = 'int32u',
    VARS = { ID_FMT = 'none' },
    VolumeID = { },
    DriveType = {
        PrintConv = {
            [0] = 'Unknown',
            [1] = 'Invalid Root Path',
            [2] = 'Removable Media',
            [3] = 'Fixed Disk',
            [4] = 'Remote Drive',
            [5] = 'CD-ROM',
            [6] = 'Ram Disk',
        },
    },
    DriveSerialNumber = {
        PrintConv = function(_self, val) return join("-", { unpack("A4 A4", sprintf("%08X", val)) }) end,
    },
    VolumeLabel = { },
    LocalBasePath = { },
    CommonNetworkRelLink = { },
    CommonPathSuffix = { },
    CommonPathSuffixUnicode = { },
    NetName = { },
    DeviceName = { },
    NetProviderType = {
        PrintHex = 1,
        PrintConv = {
            -- https://github.com/tpn/winsdk-10/blob/master/Include/10.0.14393.0/shared/wnnc.h
            [0x010000] = 'MSNET',
            [0x020000] = 'SMB',
            [0x030000] = 'NETWARE',
            [0x040000] = 'VINES',
            [0x050000] = '10NET',
            [0x060000] = 'LOCUS',
            [0x070000] = 'SUN_PC_NFS',
            [0x080000] = 'LANSTEP',
            [0x090000] = '9TILES',
            [0x0A0000] = 'LANTASTIC',
            [0x0B0000] = 'AS400',
            [0x0C0000] = 'FTP_NFS',
            [0x0D0000] = 'PATHWORKS',
            [0x0E0000] = 'LIFENET',
            [0x0F0000] = 'POWERLAN',
            [0x100000] = 'BWNFS',
            [0x110000] = 'COGENT',
            [0x120000] = 'FARALLON',
            [0x130000] = 'APPLETALK',
            [0x140000] = 'INTERGRAPH',
            [0x150000] = 'SYMFONET',
            [0x160000] = 'CLEARCASE',
            [0x170000] = 'FRONTIER',
            [0x180000] = 'BMC',
            [0x190000] = 'DCE',
            [0x1a0000] = 'AVID',
            [0x1b0000] = 'DOCUSPACE',
            [0x1c0000] = 'MANGOSOFT',
            [0x1d0000] = 'SERNET',
            [0x1e0000] = 'RIVERFRONT1',
            [0x1f0000] = 'RIVERFRONT2',
            [0x200000] = 'DECORB',
            [0x210000] = 'PROTSTOR',
            [0x220000] = 'FJ_REDIR',
            [0x230000] = 'DISTINCT',
            [0x240000] = 'TWINS',
            [0x250000] = 'RDR2SAMPLE',
            [0x260000] = 'CSC',
            [0x270000] = '3IN1',
            [0x290000] = 'EXTENDNET',
            [0x2a0000] = 'STAC',
            [0x2b0000] = 'FOXBAT',
            [0x2c0000] = 'YAHOO',
            [0x2d0000] = 'EXIFS',
            [0x2e0000] = 'DAV',
            [0x2f0000] = 'KNOWARE',
            [0x300000] = 'OBJECT_DIRE',
            [0x310000] = 'MASFAX',
            [0x320000] = 'HOB_NFS',
            [0x330000] = 'SHIVA',
            [0x340000] = 'IBMAL',
            [0x350000] = 'LOCK',
            [0x360000] = 'TERMSRV',
            [0x370000] = 'SRT',
            [0x380000] = 'QUINCY',
            [0x390000] = 'OPENAFS',
            [0x3a0000] = 'AVID1',
            [0x3b0000] = 'DFS',
            [0x3c0000] = 'KWNP',
            [0x3d0000] = 'ZENWORKS',
            [0x3e0000] = 'DRIVEONWEB',
            [0x3f0000] = 'VMWARE',
            [0x400000] = 'RSFX',
            [0x410000] = 'MFILES',
            [0x420000] = 'MS_NFS',
            [0x430000] = 'GOOGLE',
            [0x440000] = 'NDFS',
            [0x450000] = 'DOCUSHARE',
        },
    },
}

LNK.UnknownData = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Other' },
}

LNK.ConsoleData = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Other' },
    [0x08] = {
        Name = 'FillAttributes',
        Format = 'int16u',
        PrintConv = function(_self, val) return sprintf("0x%.2x", val) end,
    },
    [0x0a] = {
        Name = 'PopupFillAttributes',
        Format = 'int16u',
        PrintConv = function(_self, val) return sprintf("0x%.2x", val) end,
    },
    [0x0c] = {
        Name = 'ScreenBufferSize',
        Format = 'int16u[2]',
        PrintConv = function(_self, val) val = subst(val, ' ', ' x '); return val end,
    },
    [0x10] = {
        Name = 'WindowSize',
        Format = 'int16u[2]',
        PrintConv = function(_self, val) val = subst(val, ' ', ' x '); return val end,
    },
    [0x14] = {
        Name = 'WindowOrigin',
        Format = 'int16u[2]',
        PrintConv = function(_self, val) val = subst(val, ' ', ' x '); return val end,
    },
    [0x20] = {
        Name = 'FontSize',
        Format = 'int16u[2]',
        PrintConv = function(_self, val) val = subst(val, ' ', ' x '); return val end,
    },
    [0x24] = {
        Name = 'FontFamily',
        Format = 'int32u',
        PrintHex = 1,
        Mask = 0xf0,
        PrintConv = {
            [0] = "Don't Care",
            [0x1] = 'Roman',
            [0x2] = 'Swiss',
            [0x3] = 'Modern',
            [0x4] = 'Script',
            [0x5] = 'Decorative',
        },
    },
    [0x28] = {
        Name = 'FontWeight',
        Format = 'int32u',
    },
    [0x2c] = {
        Name = 'FontName',
        Format = 'undef[64]',
        RawConv = function(self, val)
            val = self:Decode(val, 'UTF16')
            val = subst(val, [[(?s)\0.*]], '')
            if perlTruthy(length(val)) then return val end return nil
        end,
    },
    [0x6c] = {
        Name = 'CursorSize',
        Format = 'int32u',
    },
    [0x70] = {
        Name = 'FullScreen',
        Format = 'int32u',
        PrintConv = function(_self, val) return perlTruthy(val) and "Yes" or "No" end,
    },
    [0x74] = { --PH (MISSING FROM MS DOCUMENTATION! -- screws up subsequent offsets)
        Name = 'QuickEdit',
        Format = 'int32u',
        PrintConv = function(_self, val) return perlTruthy(val) and "Yes" or "No" end,
    },
    [0x78] = {
        Name = 'InsertMode',
        Format = 'int32u',
        PrintConv = function(_self, val) return perlTruthy(val) and "Yes" or "No" end,
    },
    [0x7c] = {
        Name = 'WindowOriginAuto',
        Format = 'int32u',
        PrintConv = function(_self, val) return perlTruthy(val) and "Yes" or "No" end,
    },
    [0x80] = {
        Name = 'HistoryBufferSize',
        Format = 'int32u',
    },
    [0x84] = {
        Name = 'NumHistoryBuffers',
        Format = 'int32u',
    },
    [0x88] = {
        Name = 'RemoveHistoryDuplicates',
        Format = 'int32u',
        PrintConv = function(_self, val) return perlTruthy(val) and "Yes" or "No" end,
    },
}

LNK.TrackerData = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Other' },
    [0x10] = {
        Name = 'MachineID',
        Format = 'var_string',
    },
}

LNK.ConsoleFEData = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Other' },
    [0x08] = {
        Name = 'CodePage',
        Format = 'int32u',
        SeparateTable = 'Microsoft CodePage',
        PrintConv = Microsoft.codePage,
    },
}

LNK.EnvVarData = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [2] = 'Other' },
    [8] = {
        Name = 'EnvironmentTarget',
        Format = 'string[260]',
    },
    [268] = {
        Name = 'EnvironmentTargetUnicode',
        Format = 'unicode[260]',
        ValueConv = function(self, val) return self:Decode(val, "UTF16", "II") end,
    },
}

LNK.INI = {
    GROUPS = { [2] = 'Document' },
    VARS = { ID_FMT = 'none' },
    NOTES = 'Tags found in INI-format Windows .URL files.',
    URL         = { },
    IconFile    = { },
    IconIndex   = { },
    WorkingDirectory = { },
    HotKey      = { },
    ShowCommand = { PrintConv = { [1] = 'Normal', [2] = 'Minimized', [3] = 'Maximized' } },
    Modified    = {
        Groups = { [2] = 'Time' },
        Format = 'int64u',
        -- convert time from hex 100-ns intervals since Jan 1, 1601 (NC)
        RawConv = function(_self, val)
            local dat = pack('H*', val)
            if length(dat) < 8 then return nil end
            local lo, hi = unpack('V2', dat)
            if not (perlTruthy(lo) or perlTruthy(hi)) then return nil end
            return uv(hi * 4294967296 + lo)
        end,
        ValueConv = function(_self, val) val=val/1e7-11644473600; return ConvertUnixTime(val,1) end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    Author      = { Groups = { [2] = 'Author' } },
    WhatsNew    = { },
    Comment     = { },
    Desc        = { },
    Roamed      = { Notes = '1 if synced across multiple devices' },
    IDList      = { },
}

--------------------------------------------------------------------------------
-- Get DOS date/time
-- Inputs: 0) date/time integer value (date in low word)
-- Returns: EXIF-format date/time string
function LNK.DOSTime(val)
    return sprintf('%.4d:%.2d:%.2d %.2d:%.2d:%.2d',
       ((val >> 9)  & 0x7f) + 1980, -- year
        (val >> 5)  & 0x0f, -- month
        (val >> 0)  & 0x1f, -- day
        (val >> 27) & 0x1f, -- hour
        (val >> 21) & 0x3f, -- minute
        (val >> 15) & 0x3e  -- second (2 sec resolution)
    )
end

--------------------------------------------------------------------------------
-- Extract null-terminated ASCII or Unicode string from buffer
-- Inputs: 0) buffer ref, 1) start position, 2) flag for unicode string
-- Return: string or undef if start position is outside bounds
function LNK.GetString(dataPt, pos, unicode)
    if pos >= length(dataPt) then return nil end
    -- (pos($$dataPt) = $pos: the \G match starts at that offset)
    local ok, c1
    if unicode then
        ok, c1 = isMatch(dataPt, [[(?s)\G((?:..)*?)\0\0]], pos)
    else
        ok, c1 = isMatch(dataPt, [[(?s)\G(.*?)\0]], pos)
    end
    if ok then return c1 end
    return substr(dataPt, pos)
end

--------------------------------------------------------------------------------
-- Process item ID data (ref 4)
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference, 2) tag table ref
-- Returns: 1 on success
function LNK.ProcessItemID(et, dirInfo, tagTablePtr)
    local verbose = et:Options('Verbose')
    local dataPt = dirInfo.DataPt
    local dataLen = length(dataPt)
    local pos = 0
    local opts = {
        DataPt  = dataPt,
        DataPos = dirInfo.DataPos,
    }
    et:VerboseDir('ItemID', nil, dataLen)
    while true do
        if pos + 2 > dataLen then et:Warn('Missing item ID list terminator'); break end
        local size = Get16u(dataPt, pos)
        if size == 0 then
            local more = dataLen - pos - 2
            if more ~= 0 then et:Warn("Unknown " .. more .. " bytes after item ID list") end
            break
        elseif size < 4 then
            et:Warn('Invalid item ID entry size')
            break
        end
        local tag = Get8u(dataPt, pos+2) -- get item ID
        if pos + size > dataLen then
            et:Warn(sprintf('Truncated item with ID 0x%.2x', tag))
            size = dataLen - pos
        end
        -- 0x20-0x2f, 0x30-0x3f and 0x40-0x4f are ID ranges for the same tags
        if not tagTablePtr[tag] then
            local lkup = { [0x20]=0x2e, [0x21]=0x2f, [0x30]=0x31, [0x40]=0x40 }
            local srcTag = lkup[tag & 0x71] or lkup[tag & 0x70]  -- (keep bit 0 of MyComputer ID)
            -- make a clone of the existing tag definition
            if perl.ref(tagTablePtr[srcTag]) == 'HASH' then
                local clone = {}
                for k, v in pairs(tagTablePtr[srcTag]) do clone[k] = v end
                clone.TagID = tag
                tagTablePtr[tag] = clone
            end
        end
        if not tagTablePtr[tag] then
            AddTagToTable(nil, tagTablePtr, tag, {
                Name = sprintf('Item_%.2x', tag),
                SubDirectory = { TagTable = 'lexiftool.LNK.UnknownData' },
            })
        end
        -- isolate this itemID data
        local dat = substr(dataPt, pos, size)
        -- look for 0xbeef extension blocks
        -- (don't know what the first 2 bytes are, but I've seen 0x0003, 0x0007, 0x0008
        --  and 0x0009 for 0xbeef0004, and 0x0000 for 0xbeef0014 and 0xbeef0025)
        -- List of observed 0xbeef blocks (0xbeef ID - ItemID):
        --  0xbeef0003 - 0xb1
        --  0xbeef0004 - 0x31,0x32
        --  0xbeef0014 - 0x61
        --  0xbeef0025 - 0x2e
        --  0xbeef0026 - 0x1f,0x2e
        local beefStart
        local found, datPos = matches(dat, [[(?s).{5}\0\xef\xbe]])   -- (datPos: pos($dat))
        if found then
            local off = datPos - 8
            local off2 = Get16u(dat, length(dat) - 2)
            if off == off2 then
                beefStart = pos + off
            else
                et:Warn('Unexpected 0xbeef extension offset')
            end
        end
        et:HandleTag(tagTablePtr, tag, nil, merge(opts, {
            Start = pos,
            Size  = perlTruthy(beefStart) and beefStart - pos or size,
        }))
        if verbose > 1 and perlTruthy(beefStart) then
            local len = size - beefStart + pos
            et:VPrint(1, sprintf(et.INDENT .. "- Tag 0x%.4x Extension (%d bytes)\n",tag,len))
            et:VerboseDump(dataPt, merge(opts, { Start = beefStart, Len = len }))
        end
        -- process 0xbeef extension blocks
        while perlTruthy(beefStart) do
            local endPos = pos + size -- end if itemID entry
            if beefStart + 8 > endPos then
                if beefStart ~= endPos then et:Warn('Garbage data in 0xbeef extension') end
                break
            end
            local len = Get16u(dataPt, beefStart)
            local beefID = Get32u(dataPt, beefStart + 4)
            if (beefID & 0xffff0000) ~= 0xbeef0000 then et:Warn('Invalid 0xbeef extension'); break end
            if beefStart + len > endPos then et:Warn('Truncated 0xbeef extension'); break end
            if not tagTablePtr[beefID] then
                AddTagToTable(nil, tagTablePtr, beefID, {
                    Name = sprintf('Unknown_beef%.4x', beefID & 0xffff),
                    Binary = 1,
                })
            end
            et:HandleTag(tagTablePtr, beefID, nil, merge(opts, {
                Start = beefStart,
                Size  = len,
            }))
            if len & 0x01 ~= 0 then len = len + 1 end  -- assume they start on 2-byte boundaries (NC)
            beefStart = beefStart + len     -- step to next extension block
        end
        pos = pos + size
    end
end

--------------------------------------------------------------------------------
-- Process URI 0xbeef0014 extension (ref 4)
-- Inputs: 0) ExifTool ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
function LNK.ProcessURI(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    local pos = dirInfo.DirStart or 0
    local dirLen = dirInfo.DirLen
    local endPos = pos + dirLen
    if dirLen < 56 then return 0 end
    et:VerboseDir('URI', nil, dirLen)
    -- offset 8 - GUID df2fce13-25ec-45bb-9d4c-cecd47c2430c
    local num_ = Get32u(dataPt, pos + 52)
    pos = pos + 56
    for _ = 0, num_ - 1 do
        if pos + 8 > endPos then et:Warn('Truncated URI extension'); break end
        local tag = Get32u(dataPt, pos)
        local size = Get32u(dataPt, pos + 4)
        pos = pos + 8
        if size == 0 then goto continue end
        if pos + size > endPos then et:Warn('Truncated URI string'); break end
        do
            -- (many tags are untested -- some may not be Unicode strings?)
            local val = et:Decode(substr(dataPt, pos, size), 'UTF16')
            et:HandleTag(tagTablePtr, tag, val, {
                DataPt  = dataPt,
                DataPos = dirInfo.DataPos,
                Start   = pos,
                Size    = size,
            })
        end
        pos = pos + size
        ::continue::
    end
    return 1
end

--------------------------------------------------------------------------------
-- Process link information data
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference, 2) tag table ref
-- Returns: 1 on success
function LNK.ProcessLinkInfo(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    local dataLen = length(dataPt)
    if dataLen < 0x24 then return 0 end
    local hdrLen = Get32u(dataPt, 4)
    local lif = Get32u(dataPt, 8)   -- link info flags
    local opts = {
        DataPt  = dataPt,
        DataPos = dirInfo.DataPos,
        Size    = 4, -- (typical value size)
    }
    local off, unicode, pos, val, size
    et:VerboseDir('LinkInfo', nil, dataLen)
    if lif & 0x01 ~= 0 then
        -- read Volume ID
        off = Get32u(dataPt, 0x0c)
        if off ~= 0 and off + 0x20 <= dataLen then
            -- my $len = Get32u($dataPt, $off);
            et:HandleTag(tagTablePtr, 'DriveType', nil, merge(opts, { Start=off+4 }))
            et:HandleTag(tagTablePtr, 'DriveSerialNumber', nil, merge(opts, { Start=off+8 }))
            pos = Get32u(dataPt, off + 0x0c)
            if pos == 0x14 then
                -- use VolumeLabelOffsetUnicode instead
                pos = Get32u(dataPt, off + 0x10)
                unicode = 1
            end
            pos = pos + off
            val = LNK.GetString(dataPt, pos, unicode)
            if val ~= nil then
                size = length(val)
                if unicode then val = et:Decode(val, 'UTF16') end
                et:HandleTag(tagTablePtr, 'VolumeLabel', val, merge(opts, { Start=pos, Size=size }))
            end
        end
        -- read local base path
        if hdrLen >= 0x24 then
            pos = Get32u(dataPt, 0x1c)
            unicode = 1
        else
            pos = Get32u(dataPt, 0x10)
            unicode = nil
        end
        val = LNK.GetString(dataPt, pos, unicode)
        if val ~= nil then
            size = length(val)
            if unicode then val = et:Decode(val, 'UTF16') end
            et:HandleTag(tagTablePtr, 'LocalBasePath', val, merge(opts, { Start=pos, Size=size }))
        end
    end
    if lif & 0x02 ~= 0 then
        -- read common network relative link
        off = Get32u(dataPt, 0x14)
        if off ~= 0 and off + 0x14 <= dataLen then
            local siz = Get32u(dataPt, off)
            if off + siz > dataLen then return 0 end
            pos = Get32u(dataPt, off + 0x08)
            if pos > 0x14 and siz >= 0x18 then
                pos = Get32u(dataPt, off + 0x14)
                unicode = 1
            else
                unicode = nil
            end
            val = LNK.GetString(dataPt, off + pos, unicode)
            if val ~= nil then
                size = length(val)
                if unicode then val = et:Decode(val, 'UTF16') end
                et:HandleTag(tagTablePtr, 'NetName', val, merge(opts, { Start=pos, Size=size }))
            end
            local flg = Get32u(dataPt, off + 0x04)
            if flg & 0x01 ~= 0 then
                pos = Get32u(dataPt, off + 0x0c)
                if pos > 0x14 and siz >= 0x1c then
                    pos = Get32u(dataPt, off + 0x18)
                    unicode = 1
                else
                    unicode = nil
                end
                val = LNK.GetString(dataPt, off + pos, unicode)
                if val ~= nil then
                    size = length(val)
                    if unicode then val = et:Decode(val, 'UTF16') end
                    et:HandleTag(tagTablePtr, 'DeviceName', val, merge(opts, { Start=pos, Size=size }))
                end
            end
            if flg & 0x02 ~= 0 then
                val = Get32u(dataPt, off + 0x10)
                et:HandleTag(tagTablePtr, 'NetProviderType', val, merge(opts, { Start=off + 0x10 }))
            end
        end
    end
    off = Get32u(dataPt, 0x18)
    if off ~= 0 and off < dataLen then
        val = LNK.GetString(dataPt, off)
        et:HandleTag(tagTablePtr, 'CommonPathSuffix', val, merge(opts, { Start=off, Size=length(val)+1 }))
    end
    if hdrLen >= 0x24 then
        off = Get32u(dataPt, 0x20)
        if off ~= 0 and off < dataLen then
            val = LNK.GetString(dataPt, off, 1)
            et:HandleTag(tagTablePtr, 'CommonPathSuffixUnicode', val, merge(opts, { Start=off, Size=length(val)+1 }))
        end
    end
    return 1
end

--------------------------------------------------------------------------------
-- Extract information from a INI-format file
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference
-- Returns: 1 on success, 0 if this wasn't a valid INI file
function LNK.ProcessINI(et, dirInfo)
    local raf = dirInfo.RAF
    local buff, n
    local rs = "\x0d\x0a"   -- (local $/)
    local tagTablePtr = GetTagTable(nil, 'lexiftool.LNK.INI')
    while true do
        n, buff = raf:ReadLine(rs)
        if n == 0 then break end
        local ok, c1 = isMatch(buff, [=[^\[(.*?)\]]=])
        if ok then
            et:VPrint(0, c1 .. " section:\n")
        else
            local c2; ok, c1, c2 = isMatch(buff, [[^\s*(\w+)=(.*)\x0d\x0a$]])
            if ok then
                et:HandleTag(tagTablePtr, c1, c2, { MakeTagInfo = 1 })
            end
        end
    end
    return 1
end

--------------------------------------------------------------------------------
-- Extract information from a MS Shell Link (Windows shortcut) file
-- Inputs: 0) ExifTool object reference, 1) dirInfo reference
-- Returns: 1 on success, 0 if this wasn't a valid LNK file
function LNK.ProcessLNK(et, dirInfo)
    local raf = dirInfo.RAF
    local buff, buf2, len, i, bad, isUnicode
    local n

    -- read LNK file header
    n, buff = raf:Read(0x4c); if n ~= 0x4c then return 0 end
    if not isMatch(buff, [[(?s)^.{4}\x01\x14\x02\0{5}\xc0\0{6}\x46]]) then
        -- check for INI-format LNK file (eg. .URL file)
        if not isMatch(buff, [=[^\[[InternetShortcut\][\x0d\x0a]]=]) then return 0 end
        if not raf:Seek(0,0) then return 0 end
        et:SetFileType('URL', 'application/x-mswinurl')
        return LNK.ProcessINI(et, dirInfo)
    end
    len = unpack('V', buff)
    if len < 0x4c then return 0 end
    if len > 0x4c then
        n, buf2 = raf:Read(len - 0x4c); if n ~= len - 0x4c then return 0 end
        buff = buff .. buf2
    end
    et:SetFileType()
    SetByteOrder('II')

    local tagTablePtr = GetTagTable(nil, 'lexiftool.LNK.Main')
    local dirInfo_ = {
        DataPt = buff,
        DataPos = 0,
        DataLen = length(buff),
        DirLen = length(buff),
    }
    et:ProcessDirectory(dirInfo_, tagTablePtr)

    local flags = Get32u(buff, 0x14)

    -- save Unicode flag for strings
    if flags & 0x80 ~= 0 then isUnicode = 1 end

    -- read link target ID list
    if flags & 0x01 ~= 0 then
        n, buff = raf:Read(2); if n ~= 2 then et:Warn('Missing target ID list'); return 1 end
        len = unpack('v', buff)
        n, buff = raf:Read(len); if n ~= len then et:Warn('Truncated target ID list'); len = length(buff) end
        et:HandleTag(tagTablePtr, 0x10000, nil, {
            DataPt  = buff,
            DataPos = raf:Tell() - len,
            Size    = len,
        })
    end

    -- read link information
    if flags & 0x02 ~= 0 then
        n, buff = raf:Read(4); if n ~= 4 then et:Warn('Missing link information'); return 1 end
        len = unpack('V', buff)
        if len < 4 then et:Warn('Invalid link information'); return 1 end
        n, buf2 = raf:Read(len-4); if n ~= len-4 then et:Warn('Truncated link information'); len = length(buf2) end
        buff = buff .. buf2
        et:HandleTag(tagTablePtr, 0x20000, nil, {
            DataPt  = buff,
            DataPos = raf:Tell() - len,
            Size    = len,
        })
    end

    -- read string data
    local strings = { 'Description', 'RelativePath', 'WorkingDirectory',
                      'CommandLineArguments', 'IconFileName' }
    i = 0
    while i < #strings do
        local val, limit
        local mask = 0x04 << i
        if flags & mask == 0 then goto continue end
        n, buff = raf:Read(2); if n ~= 2 then et:Warn("Invalid " .. strings[i+1] .. " string"); return 1 end
        do
            local pos = raf:Tell()
            len = unpack('v', buff); if not perlTruthy(len) then goto continue end
            -- Windows doesn't follow their own specification and limits the length
            -- for most of these strings (ref 3)
            if i ~= 3 and len >= 260 then
                limit = 1
                if len > 260 then
                    len = 260
                    et:Warn('LNK string data overrun! Possible security issue')
                end
            end
            -- characters are 2 bytes if Unicode flag is set
            if isUnicode then len = len * 2 end
            n, buff = raf:Read(len); if n == 0 then et:Warn("Truncated " .. strings[i+1] .. " string"); return 1 end
            -- remove last character if string is at length limit (Windows treats this as a null)
            if limit then
                len = len - (isUnicode and 2 or 1)
                buff = substr(buff, 0, len)
            end
            if isUnicode then val = et:Decode(buff, 'UTF16') end
            et:HandleTag(tagTablePtr, 0x30000 | mask, val, {
                DataPt  = buff,
                DataPos = pos,
                Size    = len,
            })
        end
        ::continue::
        i = i + 1
    end

    -- read extra data
    while true do
        n, buff = raf:Read(4); if n ~= 4 then break end
        len = unpack('V', buff)
        if len < 4 then break end
        len = len - 4
        n, buf2 = raf:Read(len); if n ~= len then et:Warn('Truncated extra data'); break end
        if len <= 4 then goto continue end
        buff = buff .. buf2
        do
            local tag = Get32u(buff, 4)
            local tagInfo = tagTablePtr[tag]
            if not (perl.ref(tagInfo) == 'HASH' and tagInfo.SubDirectory) then
                tagInfo = tagTablePtr[0xa0000000]
            end
            et:HandleTag(tagTablePtr, tag, nil, {
                DataPt  = buff,
                DataPos = raf:Tell() - len - 4,
                TagInfo = tagInfo,
            })
        end
        ::continue::
    end
    -- check for an overlay
    local pos = raf:Tell()
    len = 0
    while true do
        i, buff = raf:Read(65536)
        if not perlTruthy(i) then break end
        len = len + i
        if not bad and isMatch(buff, [=[[^\0]]=]) then bad = 1 end
    end
    if bad then
        et:Warn(sprintf('Unknown %d-byte overlay at offset 0x%x', len, pos))
    elseif len ~= 0 then
        et:Warn(len .. " bytes of null padding at end of file")
    end
    return 1
end

LNK.ItemID.PROCESS_PROC = LNK.ProcessItemID
LNK.Beef0014.PROCESS_PROC = LNK.ProcessURI
LNK.LinkInfo.PROCESS_PROC = LNK.ProcessLinkInfo

return LNK -- end
