--------------------------------------------------------------------------------
-- File:         lexiftool/MacOS.lua
-- Ported from:  lib/Image/ExifTool/MacOS.pm
--
-- Description:  Read/write MacOS system tags
--
-- Revisions:    2017/03/01 - P. Harvey Created
--               2020/10/13 - PH Added ability to read MacOS "._" files
--
-- Port notes:   Complete port of MacOS.pm: every table, lookup and sub, in
--               upstream order.  Deviations forced by Lua:
--               - The predeclarations `sub MDItemLocalTime($);` and
--                 `sub ProcessATTR($$$);` are locals at the top; code refs to
--                 them in the tables are closures calling the local.
--               - The hash spread `%mdDateInfo` is a helper call in front of
--                 the entry (`mdDateInfo { ... }`), as in QuickTime.lua.
--               - Backticks and system() go through perl.qx/perl.system ($?
--                 is perl.CHILD_ERROR); System's reopening of STDOUT/STDERR
--                 on /dev/null is perl.redirectStdio, which applies to the
--                 child processes perl.system starts.
--               - Perl's `$_` loop variable is `line`; `$type` is `type_`.
--               - A binary value (`\$buff`) is { ref = 'SCALAR', value = ... }.
--               - SetMacOSTags reads the list of new values through
--                 Writer.GetNewValues (upstream: GetNewValue in list context).
--               ExtractMDItemTags, ExtractXAttrTags and GetFileCreateDate
--               are wired up at their call site (lexiftool.lua's
--               ExtractInfo, the `$^O eq 'darwin'` branch). Still
--               unreachable: SetMacOSTags's caller (Writer.pl
--               SetSystemTags, also darwin-only) is not ported, so writing
--               System:MacOS tags is not possible yet; only "._" sidecar
--               files (ProcessMacOS) are read.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local perl = require('lexiftool.perl')
local matches = perl.matches
local isMatch = perl.isMatch
local subst = perl.subst
local split = perl.split
local tr = perl.tr
local join = perl.join
local uc = perl.uc
local ucfirst = perl.ucfirst
local hex = perl.hex
local length = perl.length
local substr = perl.substr
local unpack = perl.unpack
local pack = perl.pack
local ord = perl.ord
local num = perl.num
local str = perl.str
local truthy = perl.truthy
local qx = perl.qx
local system = perl.system
local Get8u = ExifTool.Get8u
local Get16u = ExifTool.Get16u
local Get32u = ExifTool.Get32u
local SetByteOrder = ExifTool.SetByteOrder
local GetTagTable = ExifTool.GetTagTable
local AddTagToTable = ExifTool.AddTagToTable
local DecodeBits = ExifTool.DecodeBits
local ConvertUnixTime = ExifTool.ConvertUnixTime
local ConvertDuration = ExifTool.ConvertDuration

local MacOS = {}

-- (upstream's predeclarations; the subs below assign to them)
local MDItemLocalTime
local ProcessATTR

-- (port helper: Perl's `{ ..., %hash }` -- the entries of hash are added to
--  the tagInfo; explicit fields win as in Perl, see QuickTime.lua)
local function spread(hash)
    return function(t)
        for k, v in pairs(hash) do
            if t[k] == nil then t[k] = v end
        end
        return t
    end
end

local mdDateInfo = spread {
    ValueConv = function(_self, val) return MDItemLocalTime(val) end,
    PrintConv = function(self, val) return self:ConvertDateTime(val) end,
}

local delXAttr = {
    XAttrQuarantine = 'com.apple.quarantine',
    XAttrMDItemWhereFroms = 'com.apple.metadata:kMDItemWhereFroms',
}

-- Information decoded from Mac OS sidecar files
MacOS.Main = {
    GROUPS = { [0] = 'File', [1] = 'MacOS' },
    NOTES = [[
        Note that on some filesystems, MacOS creates sidecar files with names that
        begin with "._".  ExifTool will read these files if specified, and extract
        the information listed in the following table without the need for extra
        options, but these files are not writable directly.
    ]],
    [2] = {
        Name = 'RSRC',
        SubDirectory = { TagTable = 'lexiftool.RSRC.Main' },
    },
    [9] = {
        Name = 'ATTR',
        SubDirectory = {
            TagTable = 'lexiftool.MacOS.XAttr',
            ProcessProc = function(...) return ProcessATTR(...) end,
        },
    },
}

-- "mdls" tags (ref PH)
MacOS.MDItem = {
    WRITE_PROC = ExifTool.DummyWriteProc,
    VARS = { ID_FMT = 'none' },
    GROUPS = { [0] = 'File', [1] = 'MacOS', [2] = 'Other' },
    NOTES = [[
        MDItem tags are extracted using the "mdls" utility.  They are extracted if
        any "MDItem*" tag or the MacOS group is specifically requested, or by
        setting the API L<MDItemTags|../ExifTool.html#MDItemTags> option to 1 or the API L<RequestAll|../ExifTool.html#RequestAll> option to 2 or
        higher.  Note that these tags do not necessarily reflect the current
        metadata of a file -- it may take some time for the MacOS mdworker daemon to
        index the file after a metadata change.
    ]],
    MDItemFinderComment = {
        Writable = 1,
        WritePseudo = 1,
        Protected = 1, -- (all writable pseudo tags must be protected)
    },
    MDItemFSLabel = {
        Writable = 1,
        WritePseudo = 1,
        Protected = 1, -- (all writable pseudo tags must be protected)
        WriteCheck = function(_self, _tagInfo, val) if isMatch(val, [[^[0-7]$]]) then return nil end return "Not an integer in the range 0-7" end,
        PrintConv = {
            [0] = '0 (none)',
            [1] = '1 (Gray)',
            [2] = '2 (Green)',
            [3] = '3 (Purple)',
            [4] = '4 (Blue)',
            [5] = '5 (Yellow)',
            [6] = '6 (Red)',
            [7] = '7 (Orange)',
        },
    },
    MDItemFSCreationDate = {
        Writable = 1,
        WritePseudo = 1,
        DelCheck = function() return "Can't delete" end,
        Protected = 1, -- (all writable pseudo tags must be protected)
        Shift = 'Time', -- (but not supported yet)
        Notes = [[
            file creation date.  Requires "setfile" for writing.  Note that when
            reading, it may take a few seconds after writing a file before this value
            reflects the change.  However, L<FileCreateDate|Extra.html> is updated immediately
        ]],
        Groups = { [2] = 'Time' },
        ValueConv = function(_self, val) return MDItemLocalTime(val) end,
        ValueConvInv = function(_self, val) return val end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
        PrintConvInv = function(self, val) return require('lexiftool.Writer').InverseDateTime(self, val) end,
    },
    MDItemAcquisitionMake         = { Groups = { [2] = 'Camera' } },
    MDItemAcquisitionModel        = { Groups = { [2] = 'Camera' } },
    MDItemAltitude                = { Groups = { [2] = 'Location' } },
    MDItemAperture                = { Groups = { [2] = 'Camera' } },
    MDItemAudioBitRate            = { Groups = { [2] = 'Audio' } },
    MDItemAudioChannelCount       = { Groups = { [2] = 'Audio' } },
    MDItemAuthors                 = { Groups = { [2] = 'Author' } },
    MDItemBitsPerSample           = { Groups = { [2] = 'Image' } },
    MDItemCity                    = { Groups = { [2] = 'Location' } },
    MDItemCodecs                  = { },
    MDItemColorSpace              = { Groups = { [2] = 'Image' } },
    MDItemComment                 = { },
    MDItemContentCreationDate     = mdDateInfo { Groups = { [2] = 'Time' } },
    MDItemContentCreationDateRanking = mdDateInfo { Groups = { [2] = 'Time' } },
    MDItemContentModificationDate = mdDateInfo { Groups = { [2] = 'Time' } },
    MDItemContentType             = { },
    MDItemContentTypeTree         = { },
    MDItemContributors            = { },
    MDItemCopyright               = { Groups = { [2] = 'Author' } },
    MDItemCountry                 = { Groups = { [2] = 'Location' } },
    MDItemCreator                 = { Groups = { [2] = 'Document' } },
    MDItemDateAdded               = mdDateInfo { Groups = { [2] = 'Time' } },
    MDItemDescription             = { },
    MDItemDisplayName             = { },
    MDItemDownloadedDate          = mdDateInfo { Groups = { [2] = 'Time' } },
    MDItemDurationSeconds         = { PrintConv = function(_self, val) return ConvertDuration(val) end },
    MDItemEncodingApplications    = { },
    MDItemEXIFGPSVersion          = { Groups = { [2] = 'Location' }, Description = 'MD Item EXIF GPS Version' },
    MDItemEXIFVersion             = { },
    MDItemExposureMode            = { Groups = { [2] = 'Camera' } },
    MDItemExposureProgram         = { Groups = { [2] = 'Camera' } },
    MDItemExposureTimeSeconds     = { Groups = { [2] = 'Camera' } },
    MDItemFlashOnOff              = { Groups = { [2] = 'Camera' } },
    MDItemFNumber                 = { Groups = { [2] = 'Camera' } },
    MDItemFocalLength             = { Groups = { [2] = 'Camera' } },
    MDItemFSContentChangeDate     = mdDateInfo { Groups = { [2] = 'Time' } },
    MDItemFSCreatorCode           = { Groups = { [2] = 'Author' } },
    MDItemFSFinderFlags           = { },
    MDItemFSHasCustomIcon         = { },
    MDItemFSInvisible             = { },
    MDItemFSIsExtensionHidden     = { },
    MDItemFSIsStationery          = { },
    MDItemFSName                  = { },
    MDItemFSNodeCount             = { },
    MDItemFSOwnerGroupID          = { },
    MDItemFSOwnerUserID           = { },
    MDItemFSSize                  = { },
    MDItemFSTypeCode              = { },
    MDItemGPSDateStamp            = { Groups = { [2] = 'Time' } },
    MDItemGPSStatus               = { Groups = { [2] = 'Location' } },
    MDItemGPSTrack                = { Groups = { [2] = 'Location' } },
    MDItemHasAlphaChannel         = { Groups = { [2] = 'Image' } },
    MDItemImageDirection          = { Groups = { [2] = 'Location' } },
    MDItemInterestingDateRanking  = mdDateInfo { Groups = { [2] = 'Time' } },
    MDItemISOSpeed                = { Groups = { [2] = 'Camera' } },
    MDItemKeywords                = { },
    MDItemKind                    = { },
    MDItemLastUsedDate            = mdDateInfo { Groups = { [2] = 'Time' } },
    MDItemLastUsedDate_Ranking    = { },
    MDItemLatitude                = { Groups = { [2] = 'Location' } },
    MDItemLensModel               = { },
    MDItemLogicalSize             = { },
    MDItemLongitude               = { Groups = { [2] = 'Location' } },
    MDItemMediaTypes              = { },
    MDItemNumberOfPages           = { },
    MDItemOrientation             = { Groups = { [2] = 'Image' } },
    MDItemOriginApplicationIdentifier = { },
    MDItemOriginMessageID         = { },
    MDItemOriginSenderDisplayName = { },
    MDItemOriginSenderHandle      = { },
    MDItemOriginSubject           = { },
    MDItemPageHeight              = { Groups = { [2] = 'Image' } },
    MDItemPageWidth               = { Groups = { [2] = 'Image' } },
    MDItemPhysicalSize            = { Groups = { [2] = 'Image' } },
    MDItemPixelCount              = { Groups = { [2] = 'Image' } },
    MDItemPixelHeight             = { Groups = { [2] = 'Image' } },
    MDItemPixelWidth              = { Groups = { [2] = 'Image' } },
    MDItemProfileName             = { Groups = { [2] = 'Image' } },
    MDItemRedEyeOnOff             = { Groups = { [2] = 'Camera' } },
    MDItemResolutionHeightDPI     = { Groups = { [2] = 'Image' } },
    MDItemResolutionWidthDPI      = { Groups = { [2] = 'Image' } },
    MDItemSecurityMethod          = { },
    MDItemSpeed                   = { Groups = { [2] = 'Location' } },
    MDItemStateOrProvince         = { Groups = { [2] = 'Location' } },
    MDItemStreamable              = { },
    MDItemTimestamp               = { Groups = { [2] = 'Time' } }, -- (time only)
    MDItemTitle                   = { },
    MDItemTotalBitRate            = { },
    MDItemUseCount                = { },
    MDItemUsedDates               = mdDateInfo { Groups = { [2] = 'Time' } },
    MDItemUserDownloadedDate      = mdDateInfo { Groups = { [2] = 'Time' } },
    MDItemUserDownloadedUserHandle= { },
    MDItemUserSharedReceivedDate  = { },
    MDItemUserSharedReceivedRecipient = { },
    MDItemUserSharedReceivedRecipientHandle = { },
    MDItemUserSharedReceivedSender= { },
    MDItemUserSharedReceivedSenderHandle = { },
    MDItemUserSharedReceivedTransport = { },
    MDItemUserTags                = {
        List = 1,
        Writable = 1,
        WritePseudo = 1,
        Protected = 1, -- (all writable pseudo tags must be protected)
        Notes = [[
            requires "tag" utility for writing -- install with "brew install tag".  Note
            that user tags may not contain a comma, and that duplicate user tags will
            not be written
        ]],
    },
    MDItemVersion                 = { },
    MDItemVideoBitRate            = { Groups = { [2] = 'Video' } },
    MDItemWhereFroms              = { },
    MDItemWhiteBalance            = { Groups = { [2] = 'Image' } },
    -- tags used by Apple Mail on .emlx files
    com_apple_mail_dateReceived   = mdDateInfo { Name = 'AppleMailDateReceived', Groups = { [2] = 'Time' } },
    com_apple_mail_dateSent       = mdDateInfo { Name = 'AppleMailDateSent',     Groups = { [2] = 'Time' } },
    com_apple_mail_flagged        = { Name = 'AppleMailFlagged' },
    com_apple_mail_messageID      = { Name = 'AppleMailMessageID' },
    com_apple_mail_priority       = { Name = 'AppleMailPriority' },
    com_apple_mail_read           = { Name = 'AppleMailRead' },
    com_apple_mail_repliedTo      = { Name = 'AppleMailRepliedTo' },
    com_apple_mail_isRemoteAttachment = { Name = 'AppleMailIsRemoteAttachment' },
    MDItemAccountHandles          = { },
    MDItemAccountIdentifier       = { },
    MDItemAuthorEmailAddresses    = { },
    MDItemBundleIdentifier        = { },
    MDItemContentCreationDate_Ranking=mdDateInfo{Groups= { [2] = 'Time' } },
    MDItemDateAdded_Ranking       = mdDateInfo { Groups = { [2] = 'Time' } },
    MDItemEmailConversationID     = { },
    MDItemIdentifier              = { },
    MDItemInterestingDate_Ranking = mdDateInfo { Groups = { [2] = 'Time' } },
    MDItemIsApplicationManaged    = { },
    MDItemIsExistingThread        = { },
    MDItemIsLikelyJunk            = { },
    MDItemMailboxes               = { },
    MDItemMailDateReceived_Ranking= mdDateInfo { Groups = { [2] = 'Time' } },
    MDItemPrimaryRecipientEmailAddresses = { },
    MDItemRecipients              = { },
    MDItemSubject                 = { },
}

-- "xattr" tags
MacOS.XAttr = {
    WRITE_PROC = ExifTool.DummyWriteProc,
    GROUPS = { [0] = 'File', [1] = 'MacOS', [2] = 'Other' },
    VARS = { ID_FMT = 'none' }, -- (id's are too long)
    NOTES = [[
        XAttr tags are extracted using the "xattr" utility.  They are extracted if
        any "XAttr*" tag or the MacOS group is specifically requested, or by setting
        the API L<XAttrTags|../ExifTool.html#XAttrTags> option to 1 or the API L<RequestAll|../ExifTool.html#RequestAll> option to 2 or higher.
        And they are extracted by default from MacOS "._" files when reading
        these files directly.
    ]],
    ['com.apple.FinderInfo'] = {
        Name = 'XAttrFinderInfo',
        ConvertBinary = 1,
        -- ref https://opensource.apple.com/source/CarbonHeaders/CarbonHeaders-9A581/Finder.h
        ValueConv = function(_self, val)
            local a = { unpack('a4a4n3x10nx2N', val.value) }
            for i = 1, 2 do a[i] = tr(a[i], '\0', '', 'd') a[i] = "'" .. a[i] .. "'" end
            return join(' ', a)
        end,
        PrintConv = function(_self, val)
            local c1, c2, en = matches(val, [[(?s)^('.*?') ('.*?') ]])
            if c1 == nil then return val end
            val = substr(val, en)
            local type_, creator = c1, c2
            local flags, y, x, exFlags, putAway = table.unpack(split(' ', val))
            local label = (num(flags) >> 1) & 0x07
            flags = DecodeBits(((num(exFlags)<<16) | num(flags)) & 0xfff1, {
                [0] = 'OnDesk',
                [6] = 'Shared',
                [7] = 'HasNoInits',
                [8] = 'Inited',
                [10] = 'CustomIcon',
                [11] = 'Stationery',
                [12] = 'NameLocked',
                [13] = 'HasBundle',
                [14] = 'Invisible',
                [15] = 'Alias',
                -- extended flags
                [22] = 'HasRoutingInfo',
                [23] = 'ObjectBusy',
                [24] = 'CustomBadge',
                [31] = 'ExtendedFlagsValid',
            })
            local str_ = "Type=" .. type_ .. " Creator=" .. creator .. " Flags=" .. flags .. " Label=" .. label .. " Pos=(" .. x .. "," .. y .. ")"
            if truthy(putAway) then str_ = str_ .. " Putaway=" .. putAway end
            return str_
        end,
    },
    ['com.apple.quarantine'] = {
        Name = 'XAttrQuarantine',
        Writable = 1,
        WritePseudo = 1,
        WriteCheck = function() return "May only delete this tag" end,
        Protected = 1,
        Notes = [[
            quarantine information for files downloaded from the internet.  May only be
            deleted when writing
        ]],
        -- ($a[1] is the time when the quarantine tag was set)
        PrintConv = function(_self, val)
            local a = split(';', val)
            a[1] = 'Flags=' .. str(a[1])
            a[2] = 'set at ' .. ConvertUnixTime(hex(a[2]))
            a[3] = 'by ' .. str(a[3])
            return join(' ', a)
        end,
        PrintConvInv = function(_self, val) return val end,
    },
    ['com.apple.metadata:com_apple_mail_dateReceived'] = {
        Name = 'XAttrAppleMailDateReceived',
        Groups = { [2] = 'Time' },
    },
    ['com.apple.metadata:com_apple_mail_dateSent'] = {
        Name = 'XAttrAppleMailDateSent',
        Groups = { [2] = 'Time' },
    },
    ['com.apple.metadata:com_apple_mail_isRemoteAttachment'] = {
        Name = 'XAttrAppleMailIsRemoteAttachment',
    },
    ['com.apple.metadata:kMDItemDownloadedDate'] = {
        Name = 'XAttrMDItemDownloadedDate',
        Groups = { [2] = 'Time' },
    },
    ['com.apple.metadata:kMDItemFinderComment']  = { Name = 'XAttrMDItemFinderComment' },
    ['com.apple.metadata:kMDItemWhereFroms'] = {
        Name = 'XAttrMDItemWhereFroms',
        Writable = 1,
        WritePseudo = 1,
        WriteCheck = function() return "May only delete this tag" end,
        Protected = 1,
        Notes = [[
            information about where the file came from.  May only be deleted when
            writing
        ]],
    },
    ['com.apple.metadata:kMDLabel']              = { Name = 'XAttrMDLabel', Binary = 1 },
    ['com.apple.ResourceFork']                   = { Name = 'XAttrResourceFork', Binary = 1 },
    ['com.apple.lastuseddate#PS']                = {
        Name = 'XAttrLastUsedDate',
        Groups = { [2] = 'Time' },
        -- (first 4 bytes are date/time.  Not sure what remaining 12 bytes are for)
        RawConv = function(_self, val) return ConvertUnixTime(unpack("V",val.value)) end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
}

--------------------------------------------------------------------------------
-- Convert OS MDItem time string to standard EXIF-formatted local time
-- Inputs: 0) time string (eg. "2017-02-21 17:21:43 +0000")
-- Returns: EXIF-formatted local time string with timezone
function MDItemLocalTime(val)
    val = tr(val, '-', ':')
    val = subst(val, [[ ?([-+]\d{2}):?(\d{2})]], '$1:$2')
    -- convert from UTC to local time
    if isMatch(val, [[\+00:00$]]) then
        local time = ExifTool.GetUnixTime(val)
        if truthy(time) then val = ConvertUnixTime(time, 1) end
    end
    return val
end
MacOS.MDItemLocalTime = MDItemLocalTime

--------------------------------------------------------------------------------
-- Call system command, redirecting all I/O to /dev/null
-- Inputs: system arguments
-- Returns: system return code
local function System(...)
    local oldout, olderr = perl.redirectStdio('/dev/null', '/dev/null')
    local result = system(...)
    perl.redirectStdio(oldout, olderr)
    return result
end
MacOS.System = System

--------------------------------------------------------------------------------
-- Set MacOS MDItem and XAttr tags from new tag values
-- Inputs: 0) ExifTool ref, 1) file name, 2) list of tags to set
-- Returns: 1=something was set OK, 0=didn't try, -1=error (and warning set)
-- Notes: There may be errors even if 1 is returned
function MacOS.SetMacOSTags(et, file, setTags)
    local Writer = require('lexiftool.Writer')
    local result = 0

    for _, tag in ipairs(setTags) do
        local attr, err, silentErr
        local cmd = {}
        local val, nvHash = et:GetNewValue(tag)
        if not nvHash then goto continue end
        do
            local overwrite = Writer.IsOverwriting(et, nvHash)
            if not truthy(nvHash.TagInfo.List) then
                if not truthy(overwrite) then goto continue end
                if overwrite < 0 then
                    local operation = truthy(nvHash.Shift) and 'Shifting' or 'Conditional replacement'
                    et:Warn(operation .. " of MacOS " .. tag .. " not yet supported")
                    goto continue
                end
            end
            if tag == 'MDItemFSCreationDate' or tag == 'FileCreateDate' then
                -- convert to local time if value has a time zone
                if isMatch(val, '[-+Z]') then
                    local time = ExifTool.GetUnixTime(val, 1)
                    if truthy(time) then val = ConvertUnixTime(time, 1) end
                    val = subst(val, '[-+].*', '') -- remove time zone
                end
                val = subst(val, [[(\d{4}):(\d{2}):(\d{2})]], '$2/$3/$1')   -- reformat for setfile
                cmd[#cmd + 1] = '/usr/bin/setfile'
                cmd[#cmd + 1] = '-d'
                cmd[#cmd + 1] = val
                cmd[#cmd + 1] = file
            elseif tag == 'MDItemUserTags' then
                -- (tested with "tag" version 0.9.0)
                local vals = et:GetNewValue(nvHash, true)
                if overwrite < 0 and #(nvHash.DelValue or {}) > 0 then
                    -- delete specified tags
                    local dels = nvHash.DelValue
                    local del = join(',', dels)
                    err = System('/usr/local/bin/tag', '-r', del, file)
                    if not truthy(err) then
                        et:VerboseValue("- " .. tag, del)
                        result = 1
                        if #vals > 0 then err = nil end    -- more to do if there are tags to add
                    end
                end
                if err == nil then
                    -- add new tags, or overwrite or delete existing tags
                    local opt = overwrite > 0 and '-s' or '-a'
                    val = #vals > 0 and join(',', vals) or ''
                    cmd[#cmd + 1] = '/usr/local/bin/tag'
                    cmd[#cmd + 1] = opt
                    cmd[#cmd + 1] = val
                    cmd[#cmd + 1] = file
                    if overwrite > 0 then et:VPrint(1,"    - " .. tag .. " = (all)\n") end
                    if val == '' then val = nil end
                end
            elseif delXAttr[tag] then
                cmd[#cmd + 1] = '/usr/bin/xattr'
                cmd[#cmd + 1] = '-d'
                cmd[#cmd + 1] = delXAttr[tag]
                cmd[#cmd + 1] = file
                silentErr = 256   -- (will get this error if attribute doesn't exist)
            else
                local f, v
                f = subst(file, [[([\\"])]], [[\\$1]], 'g')   -- escape backslashes and quotes for AppleScript
                if tag == 'MDItemFinderComment' then
                    -- (write finder comment using osascript instead of xattr
                    -- because it is more work to construct the necessary bplist)
                    if val == nil then val = '' end  -- set to empty string instead of deleting
                    v = et:Encode(val, 'UTF8')
                    v = subst(v, [[([\\"])]], [[\\$1]], 'g')
                    attr = 'comment'
                else -- $tag eq 'MDItemFSLabel'
                    v = truthy(val) and 8 - num(val) or 0       -- convert from label to label index (0 for no label)
                    attr = 'label index'
                end
                cmd[#cmd + 1] = '/usr/bin/osascript'
                cmd[#cmd + 1] = '-e'
                cmd[#cmd + 1] = 'set fp to POSIX file "' .. f .. '" as alias'
                cmd[#cmd + 1] = '-e'
                cmd[#cmd + 1] = 'tell application "Finder" to set ' .. attr .. ' of file fp to "' .. str(v) .. '"'
            end
            if #cmd > 0 then err = System(table.unpack(cmd)) end
            if not truthy(err) then
                if val ~= nil then et:VerboseValue("+ " .. tag, val) end
                result = 1
            elseif not truthy(silentErr) or err ~= silentErr then
                local cmd_ = cmd[1] or 'tag'
                cmd_ = subst(cmd_, '.*/', '')
                et:Warn('Error ' .. str(err) .. ' running "' .. cmd_ .. '" to set ' .. tag)
                if not truthy(result) then result = -1 end
            end
        end
        ::continue::
    end
    return result
end

--------------------------------------------------------------------------------
-- Extract MacOS metadata item tags
-- Inputs: 0) ExifTool object ref, 1) file name
function MacOS.ExtractMDItemTags(et, file)
    local fn, tag, val, tmp

    fn = subst(file, [[([`"\$\\])]], [[\\$1]], 'g')   -- escape necessary characters
    et:VPrint(0, '(running mdls)')
    local mdls = qx('/usr/bin/mdls "' .. fn .. '" 2> /dev/null', true)   -- get MacOS metadata
    if truthy(perl.CHILD_ERROR) or #mdls == 0 then
        et:Warn('Error running "mdls" to extract MDItem tags')
        return
    end
    local tagTablePtr = GetTagTable(nil, 'lexiftool.MacOS.MDItem')
    et.INDENT = et.INDENT .. '| '
    et:VerboseDir('MDItem')
    for _, line in ipairs(mdls) do
        line = subst(line, [[\n$]], '')     -- (chomp)
        if type(val) ~= 'table' then
            local ok, c1 = isMatch(line, [[^k?(\w+)\s*= ]])
            if not ok then goto continue end
            line = subst(line, [[^k?(\w+)\s*= ]], '')
            tag = c1
            if line == '(' then val = { } goto continue end -- (start of a list)
            if line == '(null)' then line = '' end
            if isMatch(line, '^"') then line = subst(line, '^"', '') line = subst(line, '"$', '') end  -- remove quotes if they exist
            val = line
        elseif line == ')' then   -- (end of a list)
            line = val[1]
            if line == nil then goto continue end
        else
            -- add item to list
            line = subst(line, '^    ', '')          -- remove leading spaces
            line = subst(line, ',$', '')             -- remove trailing comma
            if line == '(null)' then line = '' end
            if isMatch(line, '^"') then line = subst(line, '^"', '') line = subst(line, '"$', '') end  -- remove quotes if they exist
            line = subst(line, [[\\"]], '"', 'g')          -- un-escape quotes
            line = subst(line, [[\\\\]], [[\\]], 'g')        -- un-escape backslashes
            line = et:Decode(line, 'UTF8')
            val[#val + 1] = line
            goto continue
        end
        -- add to Extra tags if not done already
        if not tagTablePtr[tag] then
            -- check for a date/time format
            local tagInfo = {}
            if isMatch(line, [[^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}]]) then
                tagInfo = {
                    Groups = { [2] = 'Time' },
                    ValueConv = function(_self, v) return MDItemLocalTime(v) end,
                    PrintConv = function(self, v) return self:ConvertDateTime(v) end,
                }
            end
            -- change tags like "com_apple_mail_xxx" to "AppleMailXxx"
            tmp = subst(tag, '^com_', '') -- remove leading "com_"
            tmp = subst(tmp, '_([a-z])', function(c) return uc(c) end, 'g')  -- use CamelCase
            tagInfo.Name = ExifTool.MakeTagName(tmp)
            if type(val) == 'table' then tagInfo.List = 1 end
            if isMatch(tag, 'Audio') then tagInfo.Groups = tagInfo.Groups or {} tagInfo.Groups[2] = 'Audio' end
            if isMatch(tag, '(Copyright|Author)') then tagInfo.Groups = tagInfo.Groups or {} tagInfo.Groups[2] = 'Author' end
            et:VPrint(0, "  [adding " .. tag .. "]\n")
            AddTagToTable(nil, tagTablePtr, tag, tagInfo)
        end
        if type(val) ~= 'table' then val = et:Decode(val, 'UTF8') end
        et:HandleTag(tagTablePtr, tag, val)
        val = nil
        ::continue::
    end
    et.INDENT = subst(et.INDENT, [[\| $]], '')
end

--------------------------------------------------------------------------------
-- Read MacOS XAttr value
-- Inputs: 0) ExifTool object ref, 1) file name
local function ReadXAttrValue(et, tagTablePtr, tag, val)
    -- add to our table if necessary
    if not tagTablePtr[tag] then
        local name
        -- generate tag name from attribute name
        local ok, c1 = isMatch(tag, [[^com\.apple\.(.*)$]])
        if ok then
            name = subst(c1, '^metadata:_?k', '')
            name = subst(name, '^metadata:(com_)?', '')
        else
            name = tag
        end
        name = subst(name, '[.:_]([a-z])', function(c) return uc(c) end, 'g')
        name = 'XAttr' .. ucfirst(name)
        local tagInfo = { Name = name }
        if isMatch(tag, 'Date$') then tagInfo.Groups = { [2] = 'Time' } end
        et:VPrint(0, "  [adding " .. tag .. "]\n")
        AddTagToTable(nil, tagTablePtr, tag, tagInfo)
    end
    if isMatch(val, '^bplist0') then
        local dirInfo = { DataPt = val }
        local PLIST = require('lexiftool.PLIST')
        if truthy(PLIST.ProcessBinaryPLIST(et, dirInfo, tagTablePtr)) then
            if PLIST.isDict(dirInfo.Value) then return nil end
            val = dirInfo.Value
        else
            et:Warn("Error decoding " .. tagTablePtr[tag].Name)
            return nil
        end
    end
    if type(val) ~= 'table' and (isMatch(val, [[\0]]) or length(val) > 200) or tag == 'XAttrMDLabel' then
        local buff = val
        val = { ref = 'SCALAR', value = buff }
    end
    return val
end
MacOS.ReadXAttrValue = ReadXAttrValue

--------------------------------------------------------------------------------
-- Read MacOS extended attribute tags using 'xattr' utility
-- Inputs: 0) ExifTool object ref, 1) file name
function MacOS.ExtractXAttrTags(et, file)
    local fn, tag, val, warn

    fn = subst(file, [[([`"\$\\])]], [[\\$1]], 'g')       -- escape necessary characters
    et:VPrint(0, '(running xattr)')
    local xattr = qx('/usr/bin/xattr -lx "' .. fn .. '" 2> /dev/null', true) -- get MacOS extended attributes
    if truthy(perl.CHILD_ERROR) or #xattr == 0 then
        if truthy(perl.CHILD_ERROR) then et:Warn('Error running "xattr" to extract XAttr tags') end
        return
    end
    local tagTablePtr = GetTagTable(nil, 'lexiftool.MacOS.XAttr')
    et.INDENT = et.INDENT .. '| '
    et:VerboseDir('XAttr')
    xattr[#xattr + 1] = ''    -- (for a list terminator)
    for _, line in ipairs(xattr) do
        line = subst(line, [[\n$]], '')     -- (chomp)
        if isMatch(line, '^[\\dA-Fa-f]{8}') then
            line = subst(line, '^[\\dA-Fa-f]{8}', '')
            if not truthy(tag) then warn = 1 goto continue end
            line = subst(line, [[\|.*]], '')
            line = tr(line, ' ', '', 'd')
            if isMatch(line, '[^\\dA-Fa-f]') or (length(line) & 1) ~= 0 then warn = 2 goto continue end
            if val == nil then val = '' end
            val = val .. pack('H*', line)
            goto continue
        elseif truthy(tag) and val ~= nil then
            val = ReadXAttrValue(et, tagTablePtr, tag, val)
            if val ~= nil then et:HandleTag(tagTablePtr, tag, val) end
            tag = nil
            val = nil
        end
        if length(line) == 0 then goto continue end
        if not isMatch(line, ':$') then warn = 3 goto continue end  -- attribute name must have trailing ":"
        line = subst(line, ':$', '')
        if val ~= nil then warn = 4 val = nil end
        -- remove random ID after kMDLabel in tag ID
        tag = subst(line, '(?s)^com.apple.metadata:kMDLabel_.*', 'com.apple.metadata:kMDLabel')
        ::continue::
    end
    if truthy(warn) then et:Warn('Error ' .. warn .. ' parsing "xattr" output') end
    et.INDENT = subst(et.INDENT, [[\| $]], '')
end

--------------------------------------------------------------------------------
-- Extract MacOS file creation date/time
-- Inputs: 0) ExifTool object ref, 1) file name
function MacOS.GetFileCreateDate(et, file)
    local fn

    fn = subst(file, [[([`"\$\\])]], [[\\$1]], 'g')   -- escape necessary characters
    et:VPrint(0, '(running stat)')
    local time = qx("/usr/bin/stat -f '%SB' -t '%Y:%m:%d %H:%M:%S%z' \"" .. fn .. "\" 2> /dev/null")
    if truthy(perl.CHILD_ERROR) or not truthy(time) or not isMatch(time, [[([-+]\d{2})(\d{2})\s*$]]) then
        et:Warn('Error running "stat" to extract FileCreateDate')
        return
    end
    time = subst(time, [[([-+]\d{2})(\d{2})\s*$]], '$1:$2')
    et.SET_GROUP1 = 'MacOS'
    et:FoundTag('FileCreateDate', time)
    et.SET_GROUP1 = nil
end

--------------------------------------------------------------------------------
-- Read ATTR metadata from "._" file
-- Inputs: 0) ExifTool ref, 1) dirInfo ref, 2) tag table ref
-- Return: 1 on success
-- (ref https://www.swiftforensics.com/2018/11/the-dot-underscore-file-format.html)
function ProcessATTR(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    local dataPos = dirInfo.DataPos
    local dataLen = length(dataPt)

    if not (dataLen >= 58 and isMatch(dataPt, [[(?s)^.{34}ATTR]])) then et:Warn('Invalid ATTR header') return 0 end
    local entries = Get32u(dataPt, 66)
    et:VerboseDir('ATTR', entries)
    -- (Note: The RAF is not in $dirInfo because it would break RSRC reading --
    -- the RSCR block uses relative offsets, while the ATTR block uses absolute! grrr!)
    local raf = et.RAF -- luacheck: ignore 211
    local pos = 70       -- first entry is after ATTR header
    for _ = 0, entries - 1 do
        if pos + 12 > dataLen then et:Warn('Truncated ATTR entry') break end
        local off = Get32u(dataPt, pos)
        local len = Get32u(dataPt, pos + 4)
        local n = Get8u(dataPt, pos + 10)  -- number of characters in tag name
        if pos + 11 + n > dataLen then et:Warn('Truncated ATTR name') break end
        off = off - dataPos       -- convert to relative offset (grrr!)
        if off < 0 or off > dataLen then et:Warn('Invalid ATTR offset') break end
        local tag = substr(dataPt, pos + 11, n)
        tag = subst(tag, [[\0+$]], '')       -- remove null terminator
        -- remove random ID after kMDLabel in tag ID
        tag = subst(tag, '(?s)^com.apple.metadata:kMDLabel_.*', 'com.apple.metadata:kMDLabel')
        if off + len > dataLen then et:Warn('Truncated ATTR value') break end
        local val = ReadXAttrValue(et, tagTablePtr, tag, substr(dataPt, off, len))
        if val ~= nil then
            et:HandleTag(tagTablePtr, tag, val, {
                DataPt  = dataPt,
                DataPos = dataPos,
                Start   = off,
                Size    = len,
            })
        end
        pos = pos + ((11 + n + 3) & -4) -- step to next entry (on even 4-byte boundary)
    end
    return 1
end
MacOS.ProcessATTR = ProcessATTR

--------------------------------------------------------------------------------
-- Read information from a MacOS "._" sidecar file
-- Inputs: 0) ExifTool ref, 1) dirInfo ref
-- Returns: 1 on success, 0 if this wasn't a valid "._" file
-- (ref https://www.swiftforensics.com/2018/11/the-dot-underscore-file-format.html)
function MacOS.ProcessMacOS(et, dirInfo)
    local raf = dirInfo.RAF
    local n, hdr, buff

    n, hdr = raf:Read(26)
    if n ~= 26 then return 0 end
    local ok, c1 = isMatch(hdr, [[(?s)^\0\x05\x16\x07\0(.)\0\0Mac OS X        ]])
    if not ok then return 0 end
    local ver = ord(c1)
    -- (extension may be anything, so just echo back the incoming file extension if it exists)
    et:SetFileType(nil, nil, et.FILE_EXT)
    if ver ~= 2 then et:Warn("Unsupported file version " .. ver) return 1 end
    SetByteOrder('MM')
    local tagTablePtr = GetTagTable(nil, 'lexiftool.MacOS.Main')
    local entries = Get16u(hdr, 0x18)
    et:VerboseDir('MacOS', entries)
    n, hdr = raf:Read(entries * 12)
    if n ~= entries * 12 then et:Warn('Truncated header') return 1 end
    for i = 0, entries - 1 do
        local pos = i * 12
        local tag = Get32u(hdr, pos)
        local off = Get32u(hdr, pos + 4)
        local len = Get32u(hdr, pos + 8)
        if len > 100000000 then et:Warn('Record size too large') break end
        local seekOK = raf:Seek(off,0)
        if seekOK then n, buff = raf:Read(len) end
        if not (seekOK and n == len) then et:Warn('Truncated record') break end
        et:HandleTag(tagTablePtr, tag, nil, { DataPt = buff, DataPos = off, Index = i })
    end
    return 1
end

return MacOS
