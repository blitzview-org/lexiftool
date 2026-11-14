--------------------------------------------------------------------------------
-- File:         lexiftool/VCard.lua
-- Ported from:  lib/Image/ExifTool/VCard.pm
--
-- Description:  Read vCard and iCalendar meta information
--
-- Revisions:    2015/04/05 - P. Harvey Created
--               2015/05/02 - PH Added iCalendar support
--
-- References:   1) http://en.m.wikipedia.org/wiki/VCard
--               2) http://tools.ietf.org/html/rfc6350
--               3) http://tools.ietf.org/html/rfc5545
--
-- Port notes:   Complete port of VCard.pm: every table, lookup and sub, in
--               upstream order.  Deviations forced by Lua:
--               - The hash spread `%timeInfo` is a helper call in front of
--                 the entry (`timeInfo { ... }`), as in MacOS.lua.
--               - `local $/ = "\r\n"` is the RS argument of ReadLine/chomp.
--               - A list value (`\@vals`) is a Lua array, a binary value
--                 (base64) is { ref = 'SCALAR', value = ... }.
--               - Image::ExifTool::GetLangInfo is Writer.GetLangInfo.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local perl = require('lexiftool.perl')
local matches = perl.matches
local isMatch = perl.isMatch
local subst = perl.subst
local split = perl.split
local lc = perl.lc
local uc = perl.uc
local ucfirst = perl.ucfirst
local chr = perl.chr
local hex = perl.hex
local chomp = perl.chomp
local truthy = perl.truthy
local GetTagTable = ExifTool.GetTagTable
local AddTagToTable = ExifTool.AddTagToTable

local VCard = {}

local unescapeVCard = { ['\\'] = '\\', [','] = ',', ['n'] = "\n", ['N'] = "\n" }

-- lookup for iCalendar components (used to generate family 1 group names if top level)
local isComponent = { Event = 1, Todo = 1, Journal = 1, Freebusy = 1, Timezone = 1, Alarm = 1 }

-- (port helper: Perl's `{ ..., %hash }` -- the entries of hash are added to
--  the tagInfo; explicit fields win as in Perl, see MacOS.lua)
local function spread(hash)
    return function(t)
        for k, v in pairs(hash) do
            if t[k] == nil then t[k] = v end
        end
        return t
    end
end

local timeInfo = spread {
    -- convert common date/time formats to EXIF style
    ValueConv = function(_self, val)
        val = subst(val, [[(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})(Z?)]], '$1:$2:$3 $4:$5:$6$7', 'g')
        val = subst(val, [[(\d{4})(\d{2})(\d{2})]], '$1:$2:$3', 'g')
        val = subst(val, [[(\d{4})-(\d{2})-(\d{2})]], '$1:$2:$3', 'g')
        return val
    end,
    PrintConv = function(self, val) return self:ConvertDateTime(val) end,
}

-- vCard tags (ref 1/2/PH)
-- Note: The case of all tag ID's is normalized to lowercase with uppercase first letter
VCard.Main = {
    GROUPS = { [2] = 'Document' },
    VARS = { NO_LOOKUP = 1 }, -- omit tags from lookup
    NOTES = [[
        This table lists common vCard tags, but ExifTool will also extract any other
        vCard tags found.  Tag names may have "Pref" added to indicate the preferred
        instance of a vCard property, and other "TYPE" parameters may also added to
        the tag name.  VCF files may contain multiple vCard entries which are
        distinguished by the ExifTool family 3 group name (document  number). See
        L<http://tools.ietf.org/html/rfc6350> for the vCard 4.0 specification.
    ]],
    Version     = { Name = 'VCardVersion',   Description = 'VCard Version' },
    Fn          = { Name = 'FormattedName',  Groups = { [2] = 'Author' } },
    N           = { Name = 'Name',           Groups = { [2] = 'Author' } },
    Bday        = timeInfo { Name = 'Birthday',       Groups = { [2] = 'Time' } },
    Tz          = { Name = 'TimeZone',       Groups = { [2] = 'Time' } },
    Adr         = { Name = 'Address',        Groups = { [2] = 'Location' } },
    Geo = {
        Name = 'Geolocation',
        Groups = { [2] = 'Location' },
        -- when used as a parameter, VCard 4.0 adds a "geo:" prefix that we need to remove
        ValueConv = function(_self, val) val = subst(val, '^geo:', '') return val end,
    },
    Anniversary = { },
    Email       = { },
    Gender      = { },
    Impp        = 'IMPP',
    Lang        = 'Language',
    Logo        = { },
    Nickname    = { },
    Note        = { },
    Org         = 'Organization',
    Photo       = { Groups = { [2] = 'Preview' } },
    Prodid      = 'Software',
    Rev         = 'Revision',
    Sound       = { },
    Tel         = 'Telephone',
    Title       = 'JobTitle',
    Uid         = 'UID',
    Url         = 'URL',
    ['X-ablabel'] = { Name = 'ABLabel', PrintConv = function(_self, val) val = subst(val, [[^_\$!<(.*)>!\$_$]], '$1') return val end },
    ['X-abdate']  = timeInfo { Name = 'ABDate',  Groups = { [2] = 'Time' } },
    ['X-aim']     = 'AIM',
    ['X-icq']     = 'ICQ',
    ['X-abuid']   = 'AB_UID',
    ['X-abrelatednames'] = 'ABRelatedNames',
    ['X-socialprofile']  = 'SocialProfile',
}

VCard.VCalendar = {
    GROUPS = { [1] = 'VCalendar', [2] = 'Document' },
    VARS = {
        NO_LOOKUP = 1, -- omit tags from lookup
        LONG_TAGS = 6, -- some X-microsoft tags have unavoidably long ID's
    },
    NOTES = [[
        The VCard module is also used to process iCalendar ICS files since they use
        a format similar to vCard.  The following table lists standard iCalendar
        tags, but any existing tags will be extracted.  Top-level iCalendar
        components (eg. Event, Todo, Timezone, etc.) are used for the family 1 group
        names, and embedded components (eg. Alarm) are added as a prefix to the tag
        name.  See L<http://tools.ietf.org/html/rfc5545> for the official iCalendar
        2.0 specification.
    ]],
    Version     = { Name = 'VCalendarVersion',   Description = 'VCalendar Version' },
    Calscale    = 'CalendarScale',
    Method      = { },
    Prodid      = 'Software',
    Attach      = 'Attachment',
    Categories  = { },
    Class       = 'Classification',
    Comment     = { },
    Description = { },
    Geo = {
        Name = 'Geolocation',
        Groups = { [2] = 'Location' },
        ValueConv = function(_self, val) val = subst(val, '^geo:', '') return val end,
    },
    Location    = { Name = 'Location',            Groups = { [2] = 'Location' } },
    ['Percent-complete'] = 'PercentComplete',
    Priority    = { },
    Resources   = { },
    Status      = { },
    Summary     = { },
    Completed   = timeInfo { Name = 'DateTimeCompleted',   Groups = { [2] = 'Time' } },
    Dtend       = timeInfo { Name = 'DateTimeEnd',         Groups = { [2] = 'Time' } },
    Due         = timeInfo { Name = 'DateTimeDue',         Groups = { [2] = 'Time' } },
    Dtstart     = timeInfo { Name = 'DateTimeStart',       Groups = { [2] = 'Time' } },
    Duration    = { },
    Freebusy    = 'FreeBusyTime',
    Transp      = 'TimeTransparency',
    Tzid        = { Name = 'TimezoneID',          Groups = { [2] = 'Time' } },
    Tzname      = { Name = 'TimezoneName',        Groups = { [2] = 'Time' } },
    Tzoffsetfrom= { Name = 'TimezoneOffsetFrom',  Groups = { [2] = 'Time' } },
    Tzoffsetto  = { Name = 'TimezoneOffsetTo',    Groups = { [2] = 'Time' } },
    Tzurl       = { Name = 'TimeZoneURL',         Groups = { [2] = 'Time' } },
    Attendee    = { },
    Contact     = { },
    Organizer   = { },
    ['Recurrence-id'] = 'RecurrenceID',
    ['Related-to']    = 'RelatedTo',
    Url         = 'URL',
    Uid         = 'UID',
    Exdate      = timeInfo { Name = 'ExceptionDateTimes',  Groups = { [2] = 'Time' } },
    Rdate       = timeInfo { Name = 'RecurrenceDateTimes', Groups = { [2] = 'Time' } },
    Rrule       = { Name = 'RecurrenceRule',      Groups = { [2] = 'Time' } },
    Action      = { },
    Repeat      = { },
    Trigger     = { },
    Created     = timeInfo { Name = 'DateCreated',         Groups = { [2] = 'Time' } },
    Dtstamp     = timeInfo { Name = 'DateTimeStamp',       Groups = { [2] = 'Time' } },
    ['Last-modified'] = timeInfo { Name = 'ModifyDate',      Groups = { [2] = 'Time' } },
    Sequence    = 'SequenceNumber',
    ['Request-status'] = 'RequestStatus',
    Acknowledged= timeInfo { Name = 'Acknowledged',        Groups = { [2] = 'Time' } },
--
-- Observed X-tags (not a comprehensive list):
--
    ['X-apple-calendar-color']= 'CalendarColor',
    ['X-apple-default-alarm'] = 'DefaultAlarm',
    ['X-apple-local-default-alarm'] = 'LocalDefaultAlarm',
    ['X-microsoft-cdo-appt-sequence']     = 'AppointmentSequence',
    ['X-microsoft-cdo-ownerapptid']       = 'OwnerAppointmentID',
    ['X-microsoft-cdo-busystatus']        = 'BusyStatus',
    ['X-microsoft-cdo-intendedstatus']    = 'IntendedBusyStatus',
    ['X-microsoft-cdo-alldayevent']       = 'AllDayEvent',
    ['X-microsoft-cdo-importance'] = {
        Name = 'Importance',
        PrintConv = {
            [0] = 'Low',
            [1] = 'Normal',
            [2] = 'High',
        },
    },
    ['X-microsoft-cdo-insttype'] = {
        Name = 'InstanceType',
        PrintConv = {
            [0] = 'Non-recurring Appointment',
            [1] = 'Recurring Appointment',
            [2] = 'Single Instance of Recurring Appointment',
            [3] = 'Exception to Recurring Appointment',
        },
    },
    ['X-microsoft-donotforwardmeeting']   = 'DoNotForwardMeeting',
    ['X-microsoft-disallow-counter']      = 'DisallowCounterProposal',
    ['X-microsoft-locations'] = { Name = 'MeetingLocations', Groups = { [2] = 'Location' } },
    ['X-wr-caldesc']          = 'CalendarDescription',
    ['X-wr-calname']          = 'CalendarName',
    ['X-wr-relcalid']         = 'CalendarID',
    ['X-wr-timezone']         = { Name = 'TimeZone2', Groups = { [2] = 'Time' } },
    ['X-wr-alarmuid']         = 'AlarmUID',
}

VCard.VNote = {
    GROUPS = { [1] = 'VNote', [2] = 'Document' },
    NOTES = 'Tags extracted from V-Note VNT files.',
    Version = { },
    Body    = { },
    Dcreated        = timeInfo { Name = 'CreateDate', Groups = { [2] = 'Time' } },
    ['Last-modified'] = timeInfo { Name = 'ModifyDate', Groups = { [2] = 'Time' } },
}

--------------------------------------------------------------------------------
-- Get vCard tag, creating if necessary
-- Inputs: 0) ExifTool ref, 1) tag table ref, 2) tag ID, 3) tag Name,
--         4) source tagInfo ref, 5) lang code
-- Returns: tagInfo ref
local function GetVCardTag(et, tagTablePtr, tag, name, srcInfo, langCode)
    local tagInfo = tagTablePtr[tag]
    if not tagInfo then
        if srcInfo then
            tagInfo = { }
            for k, v in pairs(srcInfo) do tagInfo[k] = v end
        else
            tagInfo = { }
            et:VPrint(0, et.INDENT, "[adding " .. tag .. "]\n")
        end
        tagInfo.Name = name
        tagInfo.Description = nil   -- create new description
        AddTagToTable(nil, tagTablePtr, tag, tagInfo)
    end
    -- handle alternate languages (the "language" parameter)
    if truthy(langCode) then tagInfo = require('lexiftool.Writer').GetLangInfo(tagInfo, langCode) end
    return tagInfo
end
VCard.GetVCardTag = GetVCardTag

--------------------------------------------------------------------------------
-- Decode vCard text
-- Inputs: 0) ExifTool ref, 1) vCard text, 2) encoding
-- Returns: decoded text (or array ref for a list of values)
function VCard.DecodeVCardText(et, val, enc)
    enc = enc ~= nil and lc(enc) or ''
    if enc == 'b' or enc == 'base64' then
        local XMP = require('lexiftool.XMP')
        -- (upstream DecodeBase64 returns a scalar ref)
        val = { ref = 'SCALAR', value = XMP.DecodeBase64(val) }
    else
        if enc == 'quoted-printable' then
            -- convert "=HH" hex codes to characters
            val = subst(val, '(?i)=([0-9a-f]{2})', function(h) return chr(hex(h)) end, 'g')
        end
        val = et:Decode(val, 'UTF8')    -- convert from UTF-8
        -- convert unescaped commas to nulls to separate list items
        -- (upstream `s/(\\.)|(,)/$1 || "\0"/sge`; one group here, since a
        --  group that took no part reaches a replacement function as false)
        val = subst(val, [[(?s)(\\.|,)]], function(c1) return c1 == ',' and "\0" or c1 end, 'g')
        -- unescape necessary characters in value
        val = subst(val, [[(?s)\\(.)]], function(c1) return truthy(unescapeVCard[c1]) and unescapeVCard[c1] or c1 end, 'g')
        -- split into list if necessary
        local vals = split([[\0]], val)
        if #vals > 1 then val = vals end
    end
    return val
end

--------------------------------------------------------------------------------
-- Read information in a vCard file
-- Inputs: 0) ExifTool ref, 1) dirInfo ref
-- Returns: 1 on success, 0 if this wasn't a valid vCard file
function VCard.ProcessVCard(et, dirInfo)
    local raf = dirInfo.RAF
    local buff, val, ok, component, n
    local compNum, count = {}, {}

    n, buff = raf:Read(24)
    if not (truthy(n) and raf:Seek(0, 0)) then return 0 end
    local isVCard, c1 = isMatch(buff, '(?i)^BEGIN:(VCARD|VCALENDAR|VNOTE)\r\n')
    if not isVCard then return 0 end
    local info = {
        VCARD     = { 'VCard', 'vCard', 'Main', 'VCF' },
        VCALENDAR = { 'ICS', 'iCalendar', 'VCalendar', 'ICS' },
        VNOTE     = { 'VNote', 'vNote', 'VNote', 'VNT', 'text/v-note' },
    }
    local type_, lbl, tbl, ext, mime = table.unpack(info[uc(c1)], 1, 5)
    et:SetFileType(type_, mime, ext)
    if truthy(et.OPTIONS.FastScan) and perl.num(et.OPTIONS.FastScan) == 3 then return 1 end
    local RS = "\r\n"   -- (local $/ = "\r\n")
    local tagTablePtr = GetTagTable(nil, "lexiftool.VCard." .. tbl)
    local more
    more, buff = raf:ReadLine(RS)   -- read first line
    if truthy(more) then buff = chomp(buff, RS) end
    while truthy(more) do
        -- retrieve previous line from $buff
        if buff ~= nil then val = buff end
        -- read ahead to next line to see if is a continuation
        more, buff = raf:ReadLine(RS)
        if truthy(more) then
            buff = chomp(buff, RS)
            -- add continuation line if necessary
            if isMatch(buff, '^[ \t]') then
                buff = subst(buff, '^[ \t]', '')
                val = val .. buff
                buff = nil
                goto next_
            end
        end
        do
            local isBE, be1, be2, be3 = isMatch(val, [[(?i)^(BEGIN|END):(V?)(\w+)$]])
            if isBE then
                local begin, v, what = (lc(be1) == 'begin' and 1 or 0), be2, ucfirst(lc(be3))
                if what == 'Card' or what == 'Calendar' or what == 'Note' then
                    if begin ~= 0 then
                        count = { { } }     -- reset group counters
                    else
                        ok = 1      -- ok if we read at least on full VCARD or VCALENDAR
                    end
                    goto next_
                end
                -- absorb top-level component into family 1 group name
                if isComponent[what] then
                    if begin ~= 0 then
                        if not component then
                            -- begin a new top-level component
                            count = { { } }
                            component = what
                            compNum[component] = (compNum[component] or 0) + 1
                            goto next_
                        end
                    elseif component and component == what then
                        -- this top-level component has ended
                        component = nil
                        goto next_
                    end
                end
                -- keep count of each component at this level
                if begin ~= 0 then
                    if truthy(v) then count[#count][what] = (count[#count][what] or 0) + 1 end
                    count[#count + 1] = { obj = what }
                elseif #count > 1 then
                    count[#count] = nil
                end
                goto next_
            elseif truthy(ok) then
                ok = 0
                et.DOC_COUNT = (et.DOC_COUNT or 0) + 1
                et.DOC_NUM = et.DOC_COUNT   -- read next card as a new document
            end
        end
        do
            local tag = matches(val, '^([-A-Za-z0-9.]+)')
            if tag == nil then
                et:Warn("Unrecognized line in " .. lbl .. " file")
                goto next_
            end
            val = subst(val, '^([-A-Za-z0-9.]+)', '')
            -- set group if it exists
            local grp = matches(tag, [[^([-A-Za-z0-9]+)\.]])
            if grp ~= nil then
                tag = subst(tag, [[^([-A-Za-z0-9]+)\.]], '')
                et.SET_GROUP1 = ucfirst(lc(grp))
            elseif component then
                et.SET_GROUP1 = component .. compNum[component]
            else
                et.SET_GROUP1 = nil
            end
            local name, p
            local param = {}
            -- vCard tag ID's are case-insensitive, so normalize to lowercase with
            -- an uppercase first letter for use as a tag name
            if isMatch(tag, '[a-z]') then name = ucfirst(tag) end  -- preserve mixed case in name if it exists
            tag = ucfirst(lc(tag))
            -- get source tagInfo reference
            local srcInfo = et:GetTagInfo(tagTablePtr, tag)
            if srcInfo then
                name = srcInfo.Name     -- use our name
            else
                if not truthy(name) then name = tag end
                -- remove leading "X-" from name if it exists
                if isMatch(name, '^X-') then
                    name = subst(name, '^X-', '')
                    name = ucfirst(name)
                end
            end
            -- add object name(s) to tag if necessary
            if #count > 1 then
                -- (Lua: count is 1-based; $count[$i] is count[i + 1], and
                --  $count[-1] -- reached as $count[$i-1] at $i=0 -- is the last)
                for i = #count - 2, 0, -1 do
                    local pre = count[i == 0 and #count or i].obj or ''    -- use containing object name as tag prefix
                    local c = count[i + 1][pre]                    -- add index for object number
                    if c == nil then c = '' end
                    tag = pre .. c .. tag
                    name = pre .. c .. name
                end
            end
            -- parse parameters
            while true do
                local p1, p2 = matches(val, '^;([-A-Za-z0-9]*)(=?)')
                if p1 == nil then break end
                val = subst(val, '^;([-A-Za-z0-9]*)(=?)', '')
                p = ucfirst(lc(p1))
                -- convert old vCard 2.x parameters to the new "TYPE=" format
                if not truthy(p2) then
                    val = p1 .. val
                    p = 'Type'
                end
                -- read parameter value
                while true do
                    local v1 = matches(val, '^"([^"]*)",?')
                    if v1 ~= nil then
                        val = subst(val, '^"([^"]*)",?', '')
                    else
                        v1 = matches(val, '^([^";:,]+,?)')
                        if v1 == nil then break end
                        val = subst(val, '^([^";:,]+,?)', '')
                    end
                    local v = p == 'Type' and ucfirst(lc(v1)) or v1
                    param[p] = param[p] ~= nil and param[p] .. v or v
                end
                if param[p] ~= nil then
                    param[p] = subst(param[p], [[(?s)\\(.)]], function(e1) return truthy(unescapeVCard[e1]) and unescapeVCard[e1] or e1 end, 'g')
                else
                    param[p] = ''
                end
            end
            if not isMatch(val, '^:') then
                et:Warn("Invalid line in " .. lbl .. " file")
                goto next_
            end
            val = subst(val, '^:', '')
            -- add 'Type' parameter to id and name if it exists
            if truthy(param.Type) then
                tag = tag .. param.Type
                name = name .. param.Type
            end
            -- convert base64-encoded data
            local d1, d2 = matches(val, [[^data:(\w+)/(\w+);base64,]])
            if d1 ~= nil then
                val = subst(val, [[^data:(\w+)/(\w+);base64,]], '')
                local xtra = ucfirst(lc(d1)) .. ucfirst(lc(d2))
                tag = tag .. xtra
                name = name .. xtra
                param.Encoding = 'base64'
            end
            val = VCard.DecodeVCardText(et, val, param.Encoding)
            local tagInfo = GetVCardTag(et, tagTablePtr, tag, name, srcInfo, param.Language)
            et:HandleTag(tagTablePtr, tag, val, { TagInfo = tagInfo })
            -- handle some other parameters that we care about (ignore the rest for now)
            for _, p_ in ipairs({ 'Geo', 'Label', 'Tzid' }) do
                p = p_
                if param[p] ~= nil then
                    -- use tag attributes from our table if it exists
                    local srcTag2 = et:GetTagInfo(tagTablePtr, p)
                    local pn = srcTag2 and srcTag2.Name or p
                    val = VCard.DecodeVCardText(et, param[p])
                    -- add parameter to tag ID and name
                    local tg, nm = tag .. p, name .. pn
                    tagInfo = GetVCardTag(et, tagTablePtr, tg, nm, srcTag2, param.Language)
                    et:HandleTag(tagTablePtr, tg, val, { TagInfo = tagInfo })
                end
            end
        end
        ::next_::
    end
    et.SET_GROUP1 = nil
    et.DOC_NUM = nil
    if not truthy(ok) then et:Warn("Missing " .. lbl .. " end") end
    return 1
end

return VCard
