--------------------------------------------------------------------------------
-- File:         lexiftool/WriteXMP.lua
-- Ported from:  lib/Image/ExifTool/WriteXMP.pl
--
-- Description:  Write XMP meta information
--
-- Revisions:    12/19/2004 - P. Harvey Created
--
-- Port notes:   All subs of WriteXMP.pl, in upstream order.  Upstream
--               compiles the file into the Image::ExifTool::XMP package and
--               AUTOLOADs it on the first call of one of its subs; this port
--               makes it a module of its own, and XMP.lua binds every sub at
--               its predeclaration position to a closure that loads this
--               file on first use (XMP.WriteXMP, XMP.CheckXMP, ... keep
--               working for all callers, the tables' WRITE_PROC/CHECK_PROC
--               included).
--
--               Scalar references: CheckXMP is a CHECK_PROC and follows the
--               port's convention for those (value in; error and the
--               possibly changed value out), with the body working on a
--               { value = ... } box so it reads like upstream's `$$valPtr`
--               (a value box: it holds the value, a carray only while
--               InflateStruct or ValidateXMP edits it).  The boxes of
--               ValidateXMP and LimitXMPSize hold a carray (doc/api.md
--               §4).  DeleteStruct's path and change counter are value
--               boxes as in XMPStruct.lua.  Perl's pos() of $path is the
--               local pathPos (nil = undef).  The 4-argument substr edits a
--               carray; where the edited string is a hash key ($path in
--               %capture), it is a string again right after the edit.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')   -- (upstream `use Image::ExifTool qw(:DataAccess :Utils)`)
local Writer = require('lexiftool.Writer')
local perl = require('lexiftool.perl')
local substr = perl.substr
local carray = require('carray')
local length = perl.length
local matches, matchesDyn = perl.matches, perl.matchesDyn
local isMatch, isMatchDyn = perl.isMatch, perl.isMatchDyn
local subst, substDyn = perl.subst, perl.substDyn
local findAll = perl.findAll
local split, join = perl.split, perl.join
local tr = perl.tr
local lc, uc, ucfirst = perl.lc, perl.uc, perl.ucfirst
local quotemeta = perl.quotemeta
local truthy = perl.truthy

local XMP = require('lexiftool.XMP')    -- (upstream `package Image::ExifTool::XMP`)
local WriteXMP = {}

-- (upstream `use vars qw(%specialStruct %dateTimeInfo %stdXlatNS)`: package
--  variables of XMP.pm, read here under their short names, like %nsURI)
local specialStruct = XMP.specialStruct
local stdXlatNS = XMP.stdXlatNS
local nsURI = XMP.nsURI
local EscapeXML, UnescapeXML = XMP.EscapeXML, XMP.UnescapeXML
local FixUTF8, GetXMPTagID = XMP.FixUTF8, XMP.GetXMPTagID
local RegisterNamespace, ProcessXMP, FoundXMP = XMP.RegisterNamespace, XMP.ProcessXMP, XMP.FoundXMP
local ConvertRational, ConvertXMPDate = XMP.ConvertRational, XMP.ConvertXMPDate
-- (the XMPStruct.pl subs, through XMP.lua's AUTOLOAD closures)
local InflateStruct, CheckStruct = XMP.InflateStruct, XMP.CheckStruct
local DeleteStruct, AddNewStruct = XMP.DeleteStruct, XMP.AddNewStruct
-- (Writer.pl subs upstream calls as plain functions)
local Write, Rationalize = Writer.Write, Writer.Rationalize
local function AddTagToTable(...) return ExifTool.AddTagToTable(nil, ...) end
-- (port helpers: Perl's `ref $x eq 'HASH'` / `ref $x eq 'ARRAY'` for a
--  structure value, as XMPStruct.lua decides them, and for a tag table entry)
local isHashRef = function(x) return require('lexiftool.XMPStruct').isHashRef(x) end
local isArrayRef = function(x) return require('lexiftool.XMPStruct').isArrayRef(x) end
local function isHash(x) return type(x) == 'table' and x[1] == nil end
-- (Perl's `cmp`, for the sort routines below)
local cmp = perl.cmp
-- (Perl `warn`)
local function warn(msg) perl.print(io.stderr, msg) end

-- (upstream's predeclarations `sub CheckXMP($$$;$);` ... -- the other subs
--  are defined before their first use)
local CheckXMP, CaptureXMP, SetPropertyPath

local debug = 0
local numPadLines = 24       -- number of blank padding lines

-- when writing extended XMP, resources bigger than this get placed in their own
-- rdf:Description so they can be moved to the extended segments if necessary
local newDescThresh = 10240  -- 10 kB

-- individual resources and namespaces to place last in separate rdf:Description's
-- so they can be moved to extended XMP segments if required (see Oct. 2008 XMP spec)
local extendedRes = {
    ['photoshop:History'] = 1,
    ['xap:Thumbnails'] = 1,
    ['xmp:Thumbnails'] = 1,
    ['crs'] = 1,
    ['crss'] = 1,
}

-- namespaces to validate more completely when Validate option is used
local validateNS = { tiff = 1, exif = 1, exifEX = 1 }

local rdfDesc = 'rdf:Description'
--
-- packet/xmp/rdf headers and trailers
--
local pktOpen = "<?xpacket begin='\xef\xbb\xbf' id='W5M0MpCehiHzreSzNTczkc9d'?>\n"
local xmlOpen = "<?xml version='1.0' encoding='UTF-8'?>\n"
local xmpOpenPrefix = "<x:xmpmeta xmlns:x='" .. nsURI.x .. "'"
local rdfOpen = "<rdf:RDF xmlns:rdf='" .. nsURI.rdf .. "'>\n"
local rdfClose = "</rdf:RDF>\n"
local xmpClose = "</x:xmpmeta>\n"
local pktCloseW =  "<?xpacket end='w'?>" -- writable by default
local pktCloseR =  "<?xpacket end='r'?>"
local sp, nl

--------------------------------------------------------------------------------
-- Get XMP opening tag (and set x:xmptk appropriately)
-- Inputs: 0) ExifTool object ref
-- Returns: x:xmpmeta opening tag
local function XMPOpen(et)
    local nv = et.NEW_VALUE and et.NEW_VALUE[XMP.x.xmptk]
    local tk
    if nv ~= nil then
        tk = et:GetNewValue(nv)
        et:VerboseValue((truthy(tk) and '+' or '-') .. ' XMP-x:XMPToolkit', tk)
        et.CHANGED = (et.CHANGED or 0) + 1
    else
        tk = 'Image::ExifTool ' .. ExifTool.VERSION
    end
    local str = truthy(tk) and (" x:xmptk='" .. EscapeXML(tk) .. "'") or ''
    return xmpOpenPrefix .. str .. ">\n"
end

--------------------------------------------------------------------------------
-- Validate XMP packet and set read or read/write mode
-- Inputs: 0) XMP data reference, 1) 'r' = read only, 'w' or undef = read/write
-- Returns: true if XMP is good (and adds packet header/trailer if necessary)
-- (Lua: the data reference is the box { value = <carray> }, doc/api.md §4)
local function ValidateXMP(xmpPt, mode)
    xmpPt.value = subst(xmpPt.value, [[(?s)^\s*<!--.*?-->\s*]], '') -- remove leading comment if it exists
    if not isMatch(xmpPt.value, [[^\0*<\0*\?\0*x\0*p\0*a\0*c\0*k\0*e\0*t]]) then
        if not isMatch(xmpPt.value, [[^<x(mp)?:x[ma]pmeta]]) then return '' end
        -- add required xpacket header/trailer
        xmpPt.value = carray.new('char'):append(pktOpen, xmpPt.value, pktCloseW)
    end
    if not truthy(mode) then mode = 'w' end
    local end_ = substr(xmpPt.value, -32, 32)
    -- check for proper xpacket trailer and set r/w mode if necessary
    local ok, _, m2 = isMatch(end_, [[(e\0*n\0*d\0*=\0*['"]\0*)([rw])(\0*['"]\0*\?\0*>)]])
    if not ok then return '' end
    end_ = substDyn(end_, [[(e\0*n\0*d\0*=\0*['"]\0*)([rw])(\0*['"]\0*\?\0*>)]], '$1' .. mode .. '$3')
    if m2 ~= mode then substr(xmpPt.value, -32, 32, end_) end
    return 1
end

--------------------------------------------------------------------------------
-- Validate XMP property
-- Inputs: 0) ExifTool ref, 1) validate hash ref, 2) attribute hash ref
-- - issues warnings if problems detected
local function ValidateProperty(et, propList, attr)

    if et.XmpValidate and #propList > 2 then
        if matches(propList[1], [[^x:x[ma]pmeta$]]) and
            propList[2] == 'rdf:RDF' and
            isMatch(propList[3], [[rdf:Description( |$)]])
        then
            if #propList > 3 then
                if matches(propList[#propList], [[^rdf:(Bag|Seq|Alt)$]]) then
                    et:Warn('Ignored empty ' .. propList[#propList] .. ' list for ' .. propList[#propList - 1], 1)
                else
                    if propList[#propList - 1] == 'rdf:Alt' and attr then
                        local lang = attr['xml:lang']
                        if truthy(lang) and #propList >= 5 then
                            local langPath = join('/', { table.unpack(propList, 4, #propList - 2) })
                            local valLang = et.XmpValidateLangAlt
                            if not valLang then valLang = {} et.XmpValidateLangAlt = valLang end
                            if not valLang[langPath] then valLang[langPath] = { } end
                            if valLang[langPath][lang] then
                                et:Warn('Duplicate language (' .. lang .. ') in lang-alt list: ' .. langPath)
                            else
                                valLang[langPath][lang] = 1
                            end
                        end
                    end
                    -- (Perl's `and` binds tighter than `or`: the second
                    --  alternative is the rdf:li case, whose $1/$2 come from
                    --  the grandparent property)
                    local ns, name = matches(propList[#propList], [[^(\w+):(\w+)]])
                    if not (ns and validateNS[ns]) then
                        ns, name = nil, nil
                        if propList[#propList] == 'rdf:li' then
                            ns, name = matches(propList[#propList - 2], [[^(\w+):(\w+)]])
                            if not (ns and validateNS[ns]) then ns, name = nil, nil end
                        end
                    end
                    if ns then
                        local tbl = ExifTool.GetTagTable(nil, 'lexiftool.XMP.' .. ns)
                        if tbl and not tbl[name] then et:Warn('Non-standard XMP property: ' .. ns .. ':' .. name) end
                    end
                    local xmpValidate = et.XmpValidate
                    local path = join('/', { table.unpack(propList, 4, #propList) })
                    if xmpValidate[path] ~= nil then
                        et:Warn('Duplicate XMP property: ' .. path)
                    else
                        xmpValidate[path] = 1
                    end
                end
            end
        elseif propList[1] ~= 'rdf:RDF' or
               not isMatch(propList[2], [[rdf:Description( |$)]])
        then
            et:Warn('Improperly enclosed XMP property: ' .. join('/', propList))
        end
    end
end

--------------------------------------------------------------------------------
-- Check XMP date values for validity and format accordingly
-- Inputs: 1) EXIF-format date string (XMP-format also accepted)
-- Returns: XMP date/time string (or undef on error)
local function FormatXMPDate(val)
    local y, m, d, t, tz
    local y1, m1, d1, t1, tz1 = matches(val, [[(\d{4}):(\d{2}):(\d{2}) (\d{2}:\d{2}(?::\d{2}(?:\.\d*)?)?)(.*)]])
    if not y1 then
        y1, m1, d1, t1, tz1 = matches(val, [[(\d{4})-(\d{2})-(\d{2})T(\d{2}:\d{2}(?::\d{2}(?:\.\d*)?)?)(.*)]])
    end
    if y1 then
        y, m, d, t, tz = y1, m1, d1, t1, tz1
        val = y .. '-' .. m .. '-' .. d .. 'T' .. t
    elseif isMatch(val, [[^\s*\d{4}(:\d{2}){0,2}\s*$]]) then
        -- this is just a date (YYYY, YYYY-mm or YYYY-mm-dd)
        val = tr(val, ':', '-')
    else
        local t2, tz2 = matches(val, [[^\s*(\d{2}:\d{2}(?::\d{2}(?:\.\d*)?)?)(.*)\s*$]])
        if t2 then
            -- this is just a time
            t, tz = t2, tz2
            val = t
        else
            return nil
        end
    end
    if truthy(tz) then
        if not isMatch(tz, [[^(Z|[+-]\d{2}:\d{2})$]]) then return nil end
        val = val .. tz
    end
    return val
end

--------------------------------------------------------------------------------
-- Check XMP values for validity and format accordingly
-- Inputs: 0) ExifTool object ref, 1) tagInfo hash ref, 2) raw value ref, 3) conversion type
-- Returns: error string or undef (and may change value) on success
-- Note: copies structured information to avoid conflicts with calling code
-- (Lua: the CHECK_PROC convention -- the value itself in; the error and the
--  possibly changed value out.  The body works on the box valPtr, standing
--  in for upstream's `$valPtr`)
function CheckXMP(et, tagInfo, val, convType)
    local valPtr = { value = val }

    if tagInfo.Struct then
        -- (upstream: require 'Image/ExifTool/XMPStruct.pl')
        local item, err, w, warn_
        if type(valPtr.value) ~= 'table' then
            valPtr.value = carray.new('char'):append(perl.str(valPtr.value))  -- (InflateStruct eats it)
            valPtr.value, warn_ = InflateStruct(et, valPtr)
            -- expect a structure HASH ref or ARRAY of structures
            if type(valPtr.value) ~= 'table' then
                -- allow empty structures
                if valPtr.value == '' then
                    valPtr.value = { [require('lexiftool.XMPStruct').STRUCT_MARK] = true }
                    return nil, valPtr.value
                end
                return 'Improperly formed structure', valPtr.value
            end
        end
        if isArrayRef(valPtr.value) then
            if not tagInfo.List then return 'Not a list tag', valPtr.value end
            local copy = { table.unpack(valPtr.value) } -- copy the list for ExifTool to use
            valPtr.value = copy                         -- return the copy
            for i = 1, #copy do
                item = copy[i]
                if not isHashRef(item) then
                    item, w = InflateStruct(et, { value = carray.new('char'):append(perl.str(item)) }) -- deserialize structure
                    copy[i] = item
                    if w then warn_ = w end
                    if isHashRef(item) then goto nextItem end
                    err = 'Improperly formed structure'
                    break
                end
                copy[i], err = CheckStruct(et, item, tagInfo.Struct)
                if err then break end
                ::nextItem::
            end
        else
            valPtr.value, err = CheckStruct(et, valPtr.value, tagInfo.Struct)
        end
        if warn_ then et.CHECK_WARN = warn_ end
        return err, valPtr.value
    end
    local format = tagInfo.Writable
    -- (if no format specified, value is a simple string)
    if not truthy(format) or format == 'string' or format == 'lang-alt' then
        -- convert value to UTF8 if necessary
        if et.OPTIONS.Charset ~= 'UTF8' then
            if isMatch(valPtr.value, [=[[\x80-\xff]]=]) then
                -- convert from Charset to UTF-8
                valPtr.value = et:Encode(valPtr.value, 'UTF8')
            end
        else
            -- translate invalid XML characters to "."
            valPtr.value = tr(valPtr.value, [[\0-\x08\x0b\x0c\x0e-\x1f]], '.')
            -- fix any malformed UTF-8 characters
            local fixed
            fixed, valPtr.value = FixUTF8(valPtr.value)
            if fixed and not et.WarnBadUTF8 then
                et:Warn('Malformed UTF-8 character(s)')
                et.WarnBadUTF8 = 1
            end
        end
        return nil, valPtr.value   -- success
    end
    if format == 'rational' or format == 'real' then
        -- make sure the value is a valid floating point number
        if not (ExifTool.IsFloat(valPtr.value) or
            -- allow 'inf' and 'undef' rational values
            (format == 'rational' and (valPtr.value == 'inf' or
             valPtr.value == 'undef' or ExifTool.IsRational(valPtr.value))))
        then
            return 'Not a floating point number', valPtr.value
        end
        if format == 'rational' then
            valPtr.value = join('/', { Rationalize(valPtr.value, 0xffffffff) })
        end
    elseif format == 'integer' then
        -- make sure the value is integer
        if ExifTool.IsInt(valPtr.value) then -- luacheck: ignore 542
            -- no conversion required (converting to 'int' would remove leading '+')
        elseif ExifTool.IsHex(valPtr.value) then
            valPtr.value = perl.hex(valPtr.value)
        else
            return 'Not an integer', valPtr.value
        end
    elseif format == 'date' then
        local newDate = FormatXMPDate(valPtr.value)
        if not truthy(newDate) then return 'Invalid date/time (use YYYY:mm:dd HH:MM:SS[.ss][+/-HH:MM|Z])', valPtr.value end
        valPtr.value = newDate
    elseif format == 'boolean' then
        -- (allow lower-case 'true' and 'false' if not setting PrintConv value)
        if not truthy(valPtr.value) or isMatch(valPtr.value, [[(?i)false]]) or isMatch(valPtr.value, [[(?i)^no$]]) then
            if not truthy(valPtr.value) or valPtr.value ~= 'false' or not truthy(convType) or convType == 'PrintConv' then
                valPtr.value = 'False'
            end
        elseif valPtr.value ~= 'true' or not truthy(convType) or convType == 'PrintConv' then
            valPtr.value = 'True'
        end
    elseif format == '1' or format == 1 then
        -- this is the entire XMP data block
        -- (ValidateXMP edits the scalar in place, so it gets a carray; the
        --  value handed back is a string again)
        valPtr.value = carray.new('char'):append(valPtr.value)
        local ok = truthy(ValidateXMP(valPtr))
        valPtr.value = valPtr.value:tostring()
        if not ok then return 'Invalid XMP data', valPtr.value end
    else
        return 'Unknown XMP format: ' .. perl.str(format), valPtr.value
    end
    return nil, valPtr.value   -- success!
end

--------------------------------------------------------------------------------
-- Get PropertyPath for specified tagInfo
-- Inputs: 0) tagInfo reference
-- Returns: PropertyPath string
local function GetPropertyPath(tagInfo)
    if not tagInfo.PropertyPath then SetPropertyPath(tagInfo.Table, tagInfo.TagID) end
    return tagInfo.PropertyPath
end

--------------------------------------------------------------------------------
-- Set PropertyPath for specified tag (also for associated flattened tags and structure elements)
-- Inputs: 0) tagTable reference, 1) tagID, 2) tagID of parent structure,
--         3) structure definition ref (or undef), 4) property list up to this point (or undef),
--         5) flag set if any containing structure has a TYPE
-- Notes: also generates flattened tags if they don't already exist
function SetPropertyPath(tagTablePtr, tagID, parentID, structPtr, propList, isType)
    local table_ = structPtr or tagTablePtr
    local tagInfo = table_ and table_[tagID]
    local flatInfo

    if not isHash(tagInfo) then return end -- (shouldn't happen)

    if structPtr then
        local flatID = parentID .. ucfirst(tagID)
        flatInfo = tagTablePtr[flatID]
        if flatInfo then
            if flatInfo.PropertyPath then return end
        elseif #propList > 50 then
            return -- avoid deep recursion
        else
            -- flattened tag doesn't exist, so create it now
            -- (could happen if we were just writing a structure)
            flatInfo = { Name = ucfirst(flatID), Flat = 1 }
            AddTagToTable(tagTablePtr, flatID, flatInfo)
        end
        if structPtr.TYPE then isType = 1 end
    else
        -- don't override existing main table entry if already set by a Struct
        if tagInfo.PropertyPath then return end
        -- use property path from original tagInfo if this is an alternate-language tag
        local srcInfo = tagInfo.SrcTagInfo
        if srcInfo then tagInfo.PropertyPath = GetPropertyPath(srcInfo) end
        if tagInfo.PropertyPath then return end
        -- set property path for all flattened tags in structure if necessary
        if tagInfo.RootTagInfo then
            SetPropertyPath(tagTablePtr, tagInfo.RootTagInfo.TagID)
            if tagInfo.PropertyPath then return end
            warn("Internal Error: Didn't set path from root for " .. tagID .. "\n")
            warn("(Is the Struct NAMESPACE defined?)\n")
        end
    end
    local ns = tagInfo.Namespace or table_.NAMESPACE
    if not ns then warn('No namespace for ' .. tagID .. "\n") return end
    local propList_, listType = { }
    if propList then propList_ = { table.unpack(propList) } end
    propList_[#propList_ + 1] = ns .. ':' .. tagID
    -- lang-alt lists are handled specially, signified by Writable='lang-alt'
    if tagInfo.Writable and tagInfo.Writable == 'lang-alt' then
        listType = 'Alt'
        -- remove language code from property path if it exists
        if tagInfo.LangCode then
            propList_[#propList_] = substDyn(propList_[#propList_], '-' .. tagInfo.LangCode .. '$', '')
        end
        -- handle lists of lang-alt lists (eg. XMP-plus:Custom tags)
        if tagInfo.List and perl.str(tagInfo.List) ~= '1' then
            propList_[#propList_ + 1] = 'rdf:' .. tagInfo.List
            propList_[#propList_ + 1] = 'rdf:li 10'
        end
    else
        listType = tagInfo.List
    end
    -- add required properties if this is a list
    if truthy(listType) and perl.str(listType) ~= '1' then
        propList_[#propList_ + 1] = 'rdf:' .. listType
        propList_[#propList_ + 1] = 'rdf:li 10'
    end
    -- set PropertyPath for all flattened tags of this structure if necessary
    local strTable = tagInfo.Struct
    if strTable and not (parentID and
        -- must test NoSubStruct flag to avoid infinite recursion
        ((tagTablePtr[parentID] and tagTablePtr[parentID].NoSubStruct) or
        length(parentID) > 500)) -- avoid deep recursion
    then
        -- make sure the structure namespace has been registered
        -- (user-defined namespaces may not have been)
        if type(strTable.NAMESPACE) == 'table' then RegisterNamespace(strTable) end
        for tag in pairs(strTable) do
            -- ignore special fields and any lang-alt fields we may have added
            if specialStruct[tag] or not isHash(strTable[tag]) or strTable[tag].LangCode then goto nextTag end
            do
                local fullID = parentID and (parentID .. ucfirst(tagID)) or tagID
                SetPropertyPath(tagTablePtr, tag, fullID, strTable, propList_, isType)
            end
            ::nextTag::
        end
    end
    -- if this was a structure field and not a normal tag,
    -- we set PropertyPath in the corresponding flattened tag
    if structPtr then
        tagInfo = flatInfo
        -- set StructType flag if any containing structure has a TYPE
        if isType then tagInfo.StructType = 1 end
    end
    -- set property path for tagInfo in main table
    tagInfo.PropertyPath = join('/', propList_)
end

--------------------------------------------------------------------------------
-- Save XMP property name/value for rewriting
-- Inputs: 0) ExifTool object reference
--         1) reference to array of XMP property path (last is current property)
--         2) property value, 3) optional reference to hash of property attributes
function CaptureXMP(et, propList, val, attrs)
    if not (val ~= nil and #propList > 2) then return end
    if matches(propList[1], [[^x:x[ma]pmeta$]]) and
        propList[2] == 'rdf:RDF' and
        isMatchDyn(propList[3], rdfDesc .. '( |$)')
    then
        -- no properties to save yet if this is just the description
        if #propList <= 3 then return end
        -- ignore empty list properties
        if matches(propList[#propList], [[^rdf:(Bag|Seq|Alt)$]]) then
            et:Warn('Ignored empty ' .. propList[#propList] .. ' list for ' .. propList[#propList - 1], 1)
            return
        end
        -- save information about this property
        local capture = et.XMP_CAPTURE
        local path = join('/', { table.unpack(propList, 4, #propList) })
        if capture[path] ~= nil then
            et.XMP_ERROR = 'Duplicate XMP property: ' .. path
        else
            capture[path] = { val, attrs or { } }
        end
    elseif propList[1] == 'rdf:RDF' and
           isMatchDyn(propList[2], rdfDesc .. '( |$)')
    then
        -- set flag so we don't write x:xmpmeta element
        et.XMP_NO_XMPMETA = 1
        -- add missing x:xmpmeta element and try again
        table.insert(propList, 1, 'x:xmpmeta')
        CaptureXMP(et, propList, val, attrs)
    else
        et.XMP_ERROR = 'Improperly enclosed XMP property: ' .. join('/', propList)
    end
end

--------------------------------------------------------------------------------
-- Save information about resource containing blank node with nodeID
-- Inputs: 0) reference to blank node information hash
--         1) reference to property list
--         2) property value
--         3) [optional] reference to attribute hash
-- Notes: This routine and ProcessBlankInfo() are also used for reading information, but
--        are uncommon so are put in this file to reduce compile time for the common case
local function SaveBlankInfo(blankInfo, propListPt, val, attrs)

    local propPath = join('/', propListPt)
    local ids = findAll(propPath, [[ #([^ /]*)]])
    -- split the property path at each nodeID
    for _, id in ipairs(ids) do
        local pre, prop, post = matchesDyn(propPath, '^(.*?)/([^/]*) #' .. id .. '((/.*)?)$')
        if pre == nil then warn("internal error parsing nodeID's") goto nextId end
        -- the element with the nodeID should be in the path prefix for subject
        -- nodes and the path suffix for object nodes
        if prop ~= rdfDesc then
            if truthy(post) then
                post = '/' .. prop .. post
            else
                pre = pre .. '/' .. prop
            end
        end
        do
            local Prop = blankInfo.Prop
            if not Prop[id] then Prop[id] = { Pre = { }, Post = { } } end
            Prop[id].Pre[pre] = 1
            if (post ~= nil and length(post) > 0) or (val ~= nil and length(val) > 0) then
                -- save the property value and attributes for each unique path suffix
                Prop[id].Post[post] = { val, attrs, propPath }
            end
        end
        ::nextId::
    end
end

--------------------------------------------------------------------------------
-- Process blank-node information
-- Inputs: 0) ExifTool object ref, 1) tag table ref,
--         2) blank node information hash ref, 3) flag set for writing
local function ProcessBlankInfo(et, tagTablePtr, blankInfo, isWriting)
    if not isWriting then et:VPrint(1, "  [Elements with nodeID set:]\n") end
    -- handle each nodeID separately
    for _, id in ipairs(perl.sort(perl.keys(blankInfo.Prop))) do
        local path = blankInfo.Prop[id]
        -- flag all resource names so we can warn later if some are unused
        local unused = { }
        for post in pairs(path.Post) do
            unused[post] = 1
        end
        -- combine property paths for all possible paths through this node
        for _, pre in ipairs(perl.sort(perl.keys(path.Pre))) do
            -- there will be no description for the object of a blank node
            if not isMatchDyn(pre, '/' .. rdfDesc .. '/') then goto nextPre end
            for _, post in ipairs(perl.sort(perl.keys(path.Post))) do
                local propList = split('/', pre .. post)
                local val, attrs = path.Post[post][1], path.Post[post][2]
                if isWriting then
                    CaptureXMP(et, propList, val, attrs)
                else
                    FoundXMP(et, tagTablePtr, propList, val)
                end
                unused[post] = nil
            end
            ::nextPre::
        end
        -- save information from unused properties (if RDF is malformed like f-spot output)
        if next(unused) then
            if truthy(et:Options('Verbose')) then et:Warn('An XMP resource is about nothing') end
            for _, post in ipairs(perl.sort(perl.keys(unused))) do
                local val, attrs, propPath = table.unpack(path.Post[post], 1, 3)
                local propList = split('/', propPath)
                if isWriting then
                    CaptureXMP(et, propList, val, attrs)
                else
                    FoundXMP(et, tagTablePtr, propList, val)
                end
            end
        end
    end
end

--------------------------------------------------------------------------------
-- Convert path to namespace used in file (this is a pain, but the XMP
-- spec only suggests 'preferred' namespace prefixes...)
-- Inputs: 0) ExifTool object reference, 1) property path
-- Returns: conforming property path
local function ConformPathToNamespace(et, path)
    local propList = split('/', path)
    -- (AddNewStruct may run without an ExifTool object, where upstream's
    --  `$$et{XMP_NS}` is undef: then no prefix is in use and nothing changes)
    local nsUsed = et and et.XMP_NS or { }
    for i, prop in ipairs(propList) do
        local ns, tag = matches(prop, [[(.+?):(.*)]])
        if ns == nil or nsUsed[ns] then goto nextProp end
        do
            local uri = nsURI[ns]
            if not uri then
                warn('No URI for namespace prefix ' .. ns .. "!\n")
                goto nextProp
            end
            for ns2, uri2 in pairs(nsUsed) do
                if uri2 ~= uri then goto nextNS end
                -- use the existing namespace prefix instead of ours
                propList[i] = ns2 .. ':' .. tag
                do break end
                ::nextNS::
            end
        end
        ::nextProp::
    end
    return join('/', propList)
end

--------------------------------------------------------------------------------
-- Add necessary rdf:type element when writing structure
-- Inputs: 0) ExifTool ref, 1) tag table ref, 2) capture hash ref, 3) path string
--         4) optional base path (already conformed to namespace) for elements in
--            variable-namespace structures
local function AddStructType(et, tagTablePtr, capture, path, basePath)
    local props = split('/', path)
    local doneID = { }
    while true do
        table.remove(props)
        if #props == 0 then break end
        local tagID = GetXMPTagID(props)
        if doneID[tagID] then goto continue end
        doneID[tagID] = 1
        do
            local tagInfo = tagTablePtr[tagID]
            if not isHash(tagInfo) then break end
            if tagInfo.Struct then
                local type_ = tagInfo.Struct.TYPE
                if type_ then
                    local pat = tagInfo.PropertyPath
                    if not pat then warn("Missing PropertyPath in AddStructType\n") break end
                    pat = ConformPathToNamespace(et, pat)
                    pat = subst(pat, [[ \d+]], [[ \\d\+]], 'g')
                    local m = matchesDyn(path, '^(' .. pat .. ')')
                    if not m then warn("Wrong path in AddStructType\n") break end
                    local p = m .. '/rdf:type'
                    if basePath then p = basePath .. '/' .. p end
                    if not capture[p] then capture[p] = { '', { ['rdf:resource'] = type_ } } end
                end
            end
            if not tagInfo.StructType then break end
        end
        ::continue::
    end
end

--------------------------------------------------------------------------------
-- Process SphericalVideoXML (see XMP-GSpherical tags documentation)
-- Inputs: 0) ExifTool ref, 1) dirInfo ref, 2) tag table ref
-- Returns: SphericalVideoXML data
local function ProcessGSpherical(et, dirInfo, tagTablePtr)
    -- extract SphericalVideoXML as a block if requested
    if et.REQ_TAG_LOOKUP and et.REQ_TAG_LOOKUP.sphericalvideoxml then
        et:FoundTag('SphericalVideoXML', substr(dirInfo.DataPt, 16))
    end
    return XMP.ProcessXMP(et, dirInfo, tagTablePtr)
end

--------------------------------------------------------------------------------
-- Hack to use XMP writer for SphericalVideoXML (see XMP-GSpherical tags documentation)
-- Inputs: 0) ExifTool ref, 1) dirInfo ref, 2) tag table ref
-- Returns: SphericalVideoXML data
local function WriteGSpherical(et, dirInfo, tagTablePtr)
    dirInfo.Compact = 1
    local dataPt = dirInfo.DataPt
    if dataPt and truthy(dataPt) then
        -- make it look like XMP for writing
        local buff = dataPt
        buff = subst(buff, [[<rdf:SphericalVideo]], "<?xpacket begin='.*?' id='W5M0MpCehiHzreSzNTczkc9d'?>\n<x:xmpmeta xmlns:x='adobe:ns:meta/'><rdf:RDF")
        buff = subst(buff, [[(?s)\s*xmlns:GSpherical]], ">\n<rdf:Description xmlns:GSpherical")
        buff = subst(buff, [[<\/rdf:SphericalVideo>]], '</rdf:Description>')
        buff = buff .. "</rdf:RDF></x:xmpmeta><?xpacket end='w'?>"
        dirInfo.DataPt = buff
        dirInfo.DirLen = length(buff) - (dirInfo.DirStart or 0)
    end
    local xmp = XMP.WriteXMP(et, dirInfo, tagTablePtr)
    if truthy(xmp) then
        -- change back to rdf:SphericalVideo structure
        xmp = subst(xmp, [[(?s)^<\?xpacket begin.*?<rdf:RDF]], "<rdf:SphericalVideo\n")
        xmp = subst(xmp, [[>\s*<rdf:Description rdf:about=''\s*]], "\n ")
        xmp = subst(xmp, [[(?s)\s*<\/rdf:Description>\s*(<\/rdf:RDF>)]], "\n</rdf:SphericalVideo>$1")
        xmp = subst(xmp, [[(?s)\s*<\/rdf:RDF>\s*<\/x:xmpmeta>.*]], '')
    end
    return xmp
end

--------------------------------------------------------------------------------
-- Utility routine to encode data in base64
-- Inputs: 0) binary data string, 1) flag to avoid inserting newlines
-- Returns:   base64-encoded string
local function EncodeBase64(data, noNewlines)
    -- encode the data in 45-byte chunks
    local chunkSize = 45
    local len = length(data)
    local str = carray.new('char')
    local i = 0
    while i < len do
        local n = len - i
        if n > chunkSize then n = chunkSize end
        -- add uuencoded data to output (minus size byte, but including trailing newline)
        str:append(substr(perl.pack('u', substr(data, i, n)), 1))
        i = i + chunkSize
    end
    -- convert to base64 (remember that "\0" may be encoded as ' ' or '`')
    tr(str, '` -_', 'AA-Za-z0-9+/')
    -- convert pad characters at the end (remember to account for trailing newline)
    local pad = 3 - (len % 3)
    if pad < 3 then substr(str, -pad - 1, pad, string.rep('=', pad)) end
    if truthy(noNewlines) then tr(str, [[\n]], '', 'd') end  -- remove newlines if specified
    return str:tostring()
end

--------------------------------------------------------------------------------
-- sort tagInfo hash references by tag name
-- (Lua: the sort block as a function of ($a, $b))
local function ByTagName(a, b)
    return cmp(a.Name, b.Name)
end

--------------------------------------------------------------------------------
-- sort alphabetically, but with rdf:type first in the structure
-- (Lua: the sort block as a function of ($a, $b))
local function TypeFirst(a, b)
    if isMatch(a, [[rdf:type$]]) then
        if not isMatch(b, [[rdf:type$]]) then return cmp(substr(a, 0, -8), b) end
    elseif isMatch(b, [[rdf:type$]]) then
        return cmp(a, substr(b, 0, -8))
    end
    return cmp(a, b)
end

--------------------------------------------------------------------------------
-- Limit size of XMP
-- Inputs: 0) ExifTool object ref, 1) XMP data ref (written up to start of $rdfClose),
--         2) max XMP len, 3) rdf:about string, 4) list ref for description start offsets
--         5) start offset of first description recommended for extended XMP
-- Returns: 0) extended XMP ref, 1) GUID and updates $$dataPt (or undef if no extended XMP)
-- (Lua: the data reference is the box { value = <carray> }, doc/api.md §4;
--  the extended XMP is returned as a string)
local function LimitXMPSize(et, dataPt, maxLen, about, startPt, extStart)

    -- return straight away if it isn't too big
    if length(dataPt.value) < maxLen then return nil end

    startPt[#startPt + 1] = length(dataPt.value)  -- add end offset to list
    local newData = carray.new('char'):append(substr(dataPt.value, 0, startPt[1]))
    local guid = string.rep('0', 32)
    -- write the required xmpNote:HasExtendedXMP property
    newData:append(nl .. sp .. '<' .. rdfDesc .. " rdf:about='" .. about .. "'\n" .. sp .. sp ..
              "xmlns:xmpNote='" .. nsURI.xmpNote .. "'")
    if truthy(et.OPTIONS.Compact.Shorthand) then
        newData:append("\n" .. sp .. sp .. "xmpNote:HasExtendedXMP='" .. guid .. "'/>\n")
    else
        newData:append('>' .. nl .. sp .. sp .. '<xmpNote:HasExtendedXMP>' .. guid ..
                  '</xmpNote:HasExtendedXMP>' .. nl .. sp .. '</' .. rdfDesc .. ">\n")
    end

    local descSize = { }
    -- calculate all description block sizes
    for i = 2, #startPt do
        descSize[startPt[i - 1]] = startPt[i] - startPt[i - 1]
    end
    table.remove(startPt)    -- remove end offset
    -- write the descriptions from smallest to largest, as many in main XMP as possible
    local descStart = perl.sort(startPt, function(a, b) return descSize[a] - descSize[b] end)
    local extData = carray.new('char'):append(XMPOpen(et) .. rdfOpen)
    for i = 0, 1 do
        for _, start in ipairs(descStart) do
            -- write main XMP first (in order of size), then extended XMP afterwards (in order)
            if (i ~= 0) ~= (start >= extStart) then goto nextStart end
            if length(newData) + descSize[start] > maxLen then
                extData:append(substr(dataPt.value, start, descSize[start]))
            else
                newData:append(substr(dataPt.value, start, descSize[start]))
            end
            ::nextStart::
        end
    end
    extData:append(rdfClose .. xmpClose)  -- close rdf:RDF and x:xmpmeta
    extData = extData:tostring()
    -- calculate GUID from MD5 of extended XMP data
    if et:hasMD5() then
        guid = uc(perl.unpack('H*', et:md5(extData)))
        newData = subst(newData, [[0{32}]], guid)     -- update GUID in main XMP segment
    end
    et:VerboseValue('+ XMP-xmpNote:HasExtendedXMP', guid)
    dataPt.value = newData                 -- return main XMP block
    return extData, guid        -- return extended XMP and its GUID
end

--------------------------------------------------------------------------------
-- Close out bottom-level property
-- Inputs: 0) current property path list ref, 1) longhand properties at each resource
--         level, 2) shorthand properties at each resource level, 3) resource flag for
--         each property path level (set only if Shorthand is enabled)
-- (Lua: $$long[-1]/$$long[-2] are long[#long]/long[#long - 1]; resFlag is
--  indexed like the Perl array plus one, and may have holes like it)
local function CloseProperty(curPropList, long, short, resFlag)

    local prop = table.remove(curPropList)
    prop = subst(prop, [[ .*]], '')       -- remove list index if it exists
    local pad = string.rep(sp, #curPropList + 1)
    if truthy(resFlag[#curPropList + 1]) then
        -- close this XMP structure with possible shorthand properties
        if length(short[#short]) > 0 then
            if length(long[#long]) > 0 then
                -- require a new Description if both longhand and shorthand properties
                long[#long - 1] = long[#long - 1] .. '>' .. nl .. pad .. '<' .. rdfDesc
                short[#short] = short[#short] .. '>' .. nl
                long[#long] = long[#long] .. pad .. '</' .. rdfDesc .. '>' .. nl
            else
                -- simply close empty property if all shorthand
                short[#short] = short[#short] .. '/>' .. nl
            end
        else
            -- use "parseType" instead of opening a new Description
            long[#long - 1] = long[#long - 1] .. ' rdf:parseType="Resource"'
            short[#short] = length(long[#long]) > 0 and ('>' .. nl) or ('/>' .. nl)
        end
        if length(long[#long]) > 0 then long[#long] = long[#long] .. pad .. '</' .. prop .. '>' .. nl end
        long[#long - 1] = long[#long - 1] .. short[#short] .. long[#long]
        table.remove(short)
        table.remove(long)
    elseif resFlag[#curPropList + 1] ~= nil then
        -- close this top level Description with possible shorthand values
        if length(long[#long]) > 0 then
            long[#long - 1] = long[#long - 1] .. short[#short] .. '>' .. nl .. long[#long] .. pad .. '</' .. prop .. '>' .. nl
        else
            long[#long - 1] = long[#long - 1] .. short[#short] .. '/>' .. nl -- empty element (ie. all shorthand)
        end
        short[#short] = ''
        long[#long] = ''
    else
        -- close this property (no chance of shorthand)
        long[#long] = long[#long] .. pad .. '</' .. prop .. '>' .. nl
        if #curPropList == 0 then
            -- add properties now that this top-level Description is complete
            long[#long - 1] = long[#long - 1] .. '>' .. nl .. long[#long]
            long[#long] = ''
        end
    end
    -- remove expired resource flags
    for k in pairs(resFlag) do
        if k > #curPropList then resFlag[k] = nil end
    end
end

--------------------------------------------------------------------------------
-- Write XMP information
-- Inputs: 0) ExifTool ref, 1) source dirInfo ref (with optional WriteGroup),
--         2) [optional] tag table ref
-- Returns: with tag table: new XMP data (may be empty if no XMP data) or undef on error
--          without tag table: 1 on success, 0 if not valid XMP file, -1 on write error
-- Notes: May set dirInfo InPlace flag to rewrite with specified DirLen (=2 to allow larger)
--        May set dirInfo ReadOnly flag to write as read-only XMP ('r' mode and no padding)
--        May set dirInfo Compact flag to force compact (drops 2kB of padding)
--        May set dirInfo MaxDataLen to limit output data length -- this causes ExtendedXMP
--          and ExtendedGUID to be returned in dirInfo if extended XMP was required
-- (luacheck 311: pathPos follows Perl's pos($path), which every assignment to
--  $path resets whether or not it is read again)
-- luacheck: push ignore 311
function WriteXMP.WriteXMP(et, dirInfo, tagTablePtr)
    if not et then return 1 end    -- allow dummy access to autoload this package
    local dataPt = dirInfo.DataPt
    local capture, nsUsed, xmpErr, about = { }, { }, nil, nil
    local changed = 0
    local xmpFile = (not tagTablePtr)   -- this is an XMP data file if no $tagTablePtr
    -- prefer XMP over other metadata formats in some types of files
    local preferred = xmpFile or (et.PreferredGroup and et.PreferredGroup == 'XMP')
    local verbose = et.OPTIONS.Verbose or 0     -- (undef counts as 0)
    local compact = { }    -- (make a copy so we can change settings)
    for k, v in pairs(et.OPTIONS.Compact or { }) do compact[k] = v end
    local dirLen = dirInfo.DirLen
    if dirLen == nil and dataPt then dirLen = length(dataPt) end
--
-- extract existing XMP information into %capture hash
--
    -- define hash in ExifTool object to capture XMP information (also causes
    -- CaptureXMP() instead of FoundXMP() to be called from ParseXMPElement())
    --
    -- The %capture hash is keyed on the complete property path beginning after
    -- rdf:RDF/rdf:Description/.  The values are array references with the
    -- following entries: 0) value, 1) attribute hash reference.
    et.XMP_CAPTURE = capture
    et.XMP_NS = nsUsed
    et.XMP_NO_XMPMETA = nil
    et.XMP_NO_XPACKET = nil
    et.XMP_IS_XML = nil
    et.XMP_IS_SVG = nil

    -- set current padding characters
    sp, nl = (truthy(compact.NoIndent) and '' or ' '), (truthy(compact.NoNewline) and '' or "\n")

    -- get value for new rdf:about
    local tagInfo = XMP.rdf.about
    if et.NEW_VALUE and et.NEW_VALUE[tagInfo] ~= nil then
        about = et:GetNewValue(et.NEW_VALUE[tagInfo])
        if not truthy(about) then about = '' end
    end

    if xmpFile or truthy(dirLen) then
        et.XMP_ERROR = nil
        -- extract all existing XMP information (to the XMP_CAPTURE hash)
        local success = ProcessXMP(et, dirInfo, tagTablePtr)
        -- don't continue if there is nothing to parse or if we had a parsing error
        if not (truthy(success) and not et.XMP_ERROR) then
            local err = et.XMP_ERROR or 'Error parsing XMP'
            -- may ignore this error only if we were successful
            if xmpFile then
                local raf = dirInfo.RAF
                -- allow empty XMP data so we can create something from nothing
                if truthy(success) or not raf:Seek(0, 2) or truthy(raf:Tell()) then
                    -- no error message if not an XMP file
                    if not et.XMP_ERROR then return 0 end
                    if truthy(et:Error(err, success)) then
                        et.XMP_CAPTURE = nil
                        return 0
                    end
                end
            else
                if truthy(success) and perl.str(success) == '1' then success = 2 end
                if truthy(et:Warn(err, success)) then
                    et.XMP_CAPTURE = nil
                    return nil
                end
            end
        end
        if about ~= nil then
            if verbose > 1 then
                local wasAbout = et.XmpAbout
                if wasAbout ~= nil then et:VerboseValue('- XMP-rdf:About', UnescapeXML(wasAbout)) end
                et:VerboseValue('+ XMP-rdf:About', about)
            end
            about = EscapeXML(about) -- must escape for XML
            changed = changed + 1
        else
            about = et.XmpAbout
            if not truthy(about) then about = '' end
        end
        et.XMP_ERROR = nil

        -- call InitWriteDirs to initialize FORCE_WRITE flags if necessary
        if xmpFile and truthy(et:GetNewValue('ForceWrite')) then Writer.InitWriteDirs(et, { }, 'XMP') end
        -- set changed if we are ForceWrite tag was set to "XMP"
        if et.FORCE_WRITE and et.FORCE_WRITE.XMP then changed = changed + 1 end

    elseif about ~= nil then
        et:VerboseValue('+ XMP-rdf:About', about)
        about = EscapeXML(about) -- must escape for XML
        -- (don't increment $changed here because we need another tag to be written)
    else
        about = ''
    end
--
-- handle writing XMP as a block to XMP file
--
    if xmpFile then
        tagInfo = ExifTool.Extra.XMP
        if tagInfo and et.NEW_VALUE and et.NEW_VALUE[tagInfo] then
            local rtnVal = 1
            local newVal = et:GetNewValue(et.NEW_VALUE[tagInfo])
            if newVal ~= nil and length(newVal) > 0 then
                et:VPrint(0, "  Writing XMP as a block\n")
                et.CHANGED = (et.CHANGED or 0) + 1
                if not Write(dirInfo.OutFile, newVal) then rtnVal = -1 end
            end
            et.XMP_CAPTURE = nil
            return rtnVal
        end
    end
--
-- delete groups in family 1 if requested
--
    local delGroupXMP
    if next(et.DEL_GROUP) then
        for grp in pairs(et.DEL_GROUP) do
            if isMatch(grp, [[^XMP-.+$]]) then delGroupXMP = true break end
        end
        if not delGroupXMP then
            -- (logic is a bit more complex for group names in exiftool XML files)
            for _, uri in pairs(nsUsed) do
                if isMatch(uri, [[^http://ns.exiftool.(?:ca|org)/]]) then delGroupXMP = true break end
            end
        end
    end
    if delGroupXMP then
        local del = et.DEL_GROUP
        for _, path in ipairs(perl.keys(capture)) do
            local propList = split('/', path) -- get property list
            local tag, ns = GetXMPTagID(propList)
            -- translate namespace if necessary
            if stdXlatNS[ns] then ns = stdXlatNS[ns] end
            local grp
            local g = nsUsed[ns] and { matches(nsUsed[ns], [[^http://ns.exiftool.(?:ca|org)/(.*?)/(.*?)/]]) }
            -- no "XMP-" added to most groups in exiftool RDF/XML output file
            if g and g[1] ~= nil then
                if isMatch(g[2], [[^\d]]) then
                    grp = 'XML-' .. g[1]
                    --(all XML-* groups stored as uppercase DEL_GROUP key)
                    local ucg = uc(grp)
                    if not (del[ucg] or (del['XML-*'] and not del['-' .. ucg])) then goto nextPath end
                else
                    grp = g[2]
                    if not (del[grp] or (del[g[1]] and not del['-' .. grp])) then goto nextPath end
                end
            else
                grp = 'XMP-' .. ns
                local ucg = uc(grp)
                if not (del[ucg] or (del['XMP-*'] and not del['-' .. ucg])) then goto nextPath end
            end
            et:VerboseValue('- ' .. grp .. ':' .. tag, capture[path][1])
            capture[path] = nil
            changed = changed + 1
            ::nextPath::
        end
    end
    -- delete HasExtendedXMP tag (we create it as needed)
    local hasExtTag = 'xmpNote:HasExtendedXMP'
    if capture[hasExtTag] then
        et:VerboseValue('- XMP-' .. hasExtTag, capture[hasExtTag][1])
        capture[hasExtTag] = nil
    end
    -- set $xmpOpen now to to handle xmptk tag first
    local xmpOpen = et.XMP_NO_XMPMETA and '' or XMPOpen(et)
--
-- add, delete or change information as specified
--
    -- get hash of all information we want to change
    -- (sorted by tag name so alternate languages come last, but with structures
    -- first so flattened tags may be used to override individual structure elements)
    local tagInfoList, structList, delLangPath, delLangPaths, delAllLang, firstNewPath, langTags =
        { }, { }, nil, { }, { }, nil, { }
    local writeGroup = dirInfo.WriteGroup
    for _, ti in ipairs(perl.sort(Writer.GetNewTagInfoList(et), ByTagName)) do
        tagInfo = ti
        if et:GetGroup(tagInfo, 0) ~= 'XMP' then goto nextInfo end
        if tagInfo.Name == 'XMP' then goto nextInfo end -- (ignore full XMP block if we didn't write it already)
        if truthy(writeGroup) and writeGroup ~= et.NEW_VALUE[tagInfo].WriteGroup then goto nextInfo end
        if tagInfo.LangCode then
            langTags[#langTags + 1] = tagInfo
        elseif tagInfo.Struct then
            structList[#structList + 1] = tagInfo
        else
            tagInfoList[#tagInfoList + 1] = tagInfo
        end
        ::nextInfo::
    end
    if #langTags > 0 then
        -- keep original order in which lang-alt entries were added
        for _, ti in ipairs(perl.sort(langTags, function(a, b) return et.NEW_VALUE[a].Order - et.NEW_VALUE[b].Order end)) do
            if ti.Struct then
                structList[#structList + 1] = ti
            else
                tagInfoList[#tagInfoList + 1] = ti
            end
        end
    end
    local allInfo = { table.unpack(structList) }
    for _, ti in ipairs(tagInfoList) do allInfo[#allInfo + 1] = ti end
    for _, ti in ipairs(allInfo) do
        tagInfo = ti
        local delPaths = { }   -- list of deleted paths
        local tag = tagInfo.TagID
        local path = GetPropertyPath(tagInfo)
        local pathPos           -- (Perl's pos($path): set by m//g, undef after an assignment)
        if not path then
            et:Warn("Can't write XMP:" .. tag .. ' (namespace unknown)')
            goto nextTag
        end
        -- skip tags that were handled specially
        if path == 'rdf:about' or path == 'x:xmptk' then
            changed = changed + 1
            goto nextTag
        end
        do
        local isStruct = tagInfo.Struct
        -- change our property path namespace prefixes to conform
        -- to the ones used in this file
        path = ConformPathToNamespace(et, path)
        -- find existing property
        local cap = capture[path]
        -- MicrosoftPhoto screws up the case of some tags, and some other software,
        -- including Adobe software, has been known to write the wrong list type or
        -- not properly enclose properties in a list, so we check for this
        while not cap do -- luacheck: ignore 512 (upstream's `until ($cap) { ... last; }`)
            -- find and fix all incorrect property names if this is a structure or a flattened tag
            local fixInfo = { }
            if isStruct or tagInfo.Flat ~= nil then
                -- get tagInfo for all containing (possibly nested) structures
                local props = split('/', path)
                local tbl = tagInfo.Table
                while #props > 0 do
                    local info = tbl[GetXMPTagID(props)]
                    if isHash(info) and info.Struct and
                        (#fixInfo == 0 or fixInfo[1] ~= info)
                    then
                        table.insert(fixInfo, 1, info)
                    end
                    table.remove(props)
                end
                if #fixInfo == 0 then et:Warn('Error finding parent structure for ' .. tagInfo.Name) end
            end
            -- fix property path for this tag (last in the @fixInfo list)
            if not (#fixInfo > 0 and isStruct) then fixInfo[#fixInfo + 1] = tagInfo end
            -- start from outermost containing structure, fixing incorrect list types, etc,
            -- finally fixing the actual tag properties after all containing structures
            local err
            while #fixInfo > 0 do
                local fixInfo1 = table.remove(fixInfo, 1)
                local fixPath = ConformPathToNamespace(et, GetPropertyPath(fixInfo1))
                local regex = quotemeta(fixPath)
                regex = subst(regex, [[ \d+]], [[ \\d\+]], 'g')  -- match any list index
                local ok = regex
                local ok2, fixed
                local fixedList, fixedSet = { }, { }
                -- check for incorrect list types
                local regex0 = regex
                regex = subst(regex, [[\\/rdf\\:(Bag|Seq|Alt)\\/]], '/rdf:(Bag|Seq|Alt)/', 'g')
                if regex ~= regex0 then
                    -- also look for missing bottom-level list
                    regex0 = regex
                    regex = subst(regex, [[/rdf:\(Bag\|Seq\|Alt\)/rdf\\:li\\ \\d\+$]], '')
                    if regex ~= regex0 then
                        if #fixInfo == 0 then regex = regex .. '(/.*)?' end
                    end
                elseif #fixInfo == 0 then
                    ok2 = regex
                    -- check for properties in lists that shouldn't be (ref forum4325)
                    regex = regex .. [[(/rdf:(Bag|Seq|Alt)/rdf:li \d+)?]]
                end
                if #fixInfo > 0 then
                    regex = regex .. '(/.*)?'
                    ok = ok .. '(/.*)?'
                end
                local matchList = { }
                for p in pairs(capture) do
                    if isMatchDyn(p, '(?i)^' .. regex .. '$') then matchList[#matchList + 1] = p end
                end
                matchList = perl.sort(matchList)
                if #matchList == 0 then break end
                if isMatchDyn(matchList[1], '^' .. ok .. '$') then
                    if #fixInfo == 0 then
                        path = matchList[1]
                        pathPos = nil
                        cap = capture[path]
                    end
                    goto nextFix
                end
                do
                -- needs fixing...
                local fixProps = split('/', fixPath)
                for _, match in ipairs(matchList) do
                    local matchProps = split('/', match)
                    -- remove superfluous list properties if necessary
                    if ok2 and #matchProps > #fixProps then
                        for k = #fixProps + 1, #matchProps do matchProps[k] = nil end
                    end
                    for i = 1, #fixProps do
                        if matchProps[i] == nil then
                            matchProps[i] = fixProps[i]
                        elseif not (isMatch(matchProps[i], [[ \d+$]]) or matchProps[i] == fixProps[i]) then
                            matchProps[i] = fixProps[i]
                        end
                    end
                    fixed = join('/', matchProps)
                    if fixedSet[fixed] or (capture[fixed] and match ~= fixed) then err = 1 end
                    fixedList[#fixedList + 1] = fixed
                    fixedSet[fixed] = 1
                end
                local tg = et:GetGroup(fixInfo1, 1) .. ':' .. fixInfo1.Name
                local wrn = lc(fixedList[1]) == lc(matchList[1]) and 'tag ID case' or 'list type'
                if err then
                    et:Warn('Incorrect ' .. wrn .. ' for existing ' .. tg .. ' (not changed)')
                else
                    -- fix the incorrect property paths for all values of this tag
                    local didFix
                    for _, fixed1 in ipairs(fixedList) do
                        local match = table.remove(matchList, 1)
                        if fixed1 == match then goto nextFixed end
                        capture[fixed1] = capture[match]
                        capture[match] = nil
                        -- remove xml:lang attribute from incorrect lang-alt list if necessary
                        if ok2 and not isMatchDyn(match, '^' .. ok2 .. '$') then capture[fixed1][2]['xml:lang'] = nil end
                        didFix = 1
                        ::nextFixed::
                    end
                    if #fixInfo == 0 then cap = capture[path] or capture[fixedList[1]] end
                    if didFix then
                        et:Warn('Fixed incorrect ' .. wrn .. ' for ' .. tg, 1)
                        changed = changed + 1
                    end
                end
                end
                ::nextFix::
            end
            break
        end
        local nvHash = Writer.GetNewValueHash(et, tagInfo)
        local overwrite = Writer.IsOverwriting(et, nvHash)
        local writable = tagInfo.Writable or ''
        local attrs, deleted, added, existed, newLang = { }
        -- set up variables to save/restore paths of deleted lang-alt tags
        if writable == 'lang-alt' then
            newLang = lc(tagInfo.LangCode or 'x-default')
            if delLangPath and delLangPath == path then
                -- restore paths of deleted entries for this language
                if delLangPaths[newLang] then delPaths = { table.unpack(delLangPaths[newLang]) } end
            else
                delLangPaths = { }
                delLangPath = path   -- base path for deleted lang-alt tags
                delAllLang = { }
                firstNewPath = nil   -- reset first path for new lang-alt tag
            end
            if next(delAllLang) then
                -- add missing paths to delete list for entries where all languages were deleted
                local reSort
                for prefix in pairs(delAllLang) do
                    local found
                    for _, p in ipairs(delPaths) do
                        if isMatchDyn(p, '^' .. prefix) then found = true break end
                    end
                    if not found then
                        delPaths[#delPaths + 1] = prefix .. '10'
                        reSort = 1
                    end
                end
                if reSort then delPaths = perl.sort(delPaths) end
            end
        end
        -- delete existing entry if necessary
        if isStruct then
            -- delete all structure (or pseudo-structure) elements
            -- (upstream: require 'Image/ExifTool/XMPStruct.pl')
            local pathPt, changedPt = { value = path }, { value = changed }
            deleted, added, existed = DeleteStruct(et, capture, pathPt, nvHash, changedPt)
            path, changed = pathPt.value, changedPt.value
            pathPos = nil
            -- don't add if it didn't exist and not IsCreating and Avoid
            if not existed and not truthy(nvHash.IsCreating) and tagInfo.Avoid then added = nil end
            if not (deleted or added or truthy(Writer.IsOverwriting(et, nvHash))) then goto nextTag end
            if existed and nvHash.CreateOnly then goto nextTag end
        elseif cap then
            if nvHash.CreateOnly then goto nextTag end   -- (necessary for List-type tags)
            -- take attributes from old values if they exist
            for k, v in pairs(cap[2]) do attrs[k] = v end
            if truthy(overwrite) then
                local oldLang, delLang, addLang, langPathPat
                local matchingPaths, langsHere = { }, { }
                -- check to see if this is an indexed list item
                if isMatch(path, ' ') then
                    local pp = subst(path, [[ \d+]], [[ \\d\+]], 'g')
                    for p in pairs(capture) do
                        if isMatchDyn(p, '^' .. pp .. '$') then matchingPaths[#matchingPaths + 1] = p end
                    end
                    matchingPaths = perl.sort(matchingPaths)
                else
                    matchingPaths[#matchingPaths + 1] = path
                end
                local oldOverwrite = overwrite
                for _, path1 in ipairs(matchingPaths) do
                    local val, attrs1 = capture[path1][1], capture[path1][2]
                    if writable == 'lang-alt' then
                        -- get original language code (lc for comparisons)
                        oldLang = lc(attrs1['xml:lang'] or 'x-default')
                        -- revert to original overwrite flag if this is in a different structure
                        if not langPathPat or not isMatchDyn(path1, '^' .. langPathPat .. '$') then
                            overwrite = oldOverwrite
                            langPathPat = subst(path1, [[\d+$]], [[\\d+]])
                        end
                        -- remember languages in this lang-alt list
                        if not langsHere[langPathPat] then langsHere[langPathPat] = { } end
                        langsHere[langPathPat][oldLang] = 1
                        if addLang == nil then
                            -- add to lang-alt list by default if creating this tag from scratch
                            addLang = truthy(nvHash.IsCreating) and 1 or 0
                        end
                        if overwrite < 0 then
                            if oldLang ~= newLang then goto nextMatch end
                            -- only add new tag if we are overwriting this one
                            -- (note: this won't match if original XML contains CDATA!)
                            addLang = Writer.IsOverwriting(et, nvHash, UnescapeXML(val))
                            if not truthy(addLang) then goto nextMatch end
                        end
                        -- delete all if deleting "x-default" and writing with no LangCode
                        -- (XMP spec requires x-default language exist and be first in list)
                        if oldLang == 'x-default' and not tagInfo.LangCode then
                            delLang = 1     -- delete all languages
                            overwrite = 1   -- force overwrite
                        elseif tagInfo.LangCode and not delLang then
                            -- only overwrite specified language
                            if lc(tagInfo.LangCode) ~= oldLang then goto nextMatch end
                        end
                    elseif overwrite < 0 then
                        -- only overwrite specific values
                        if nvHash.Shift then
                            -- values to be shifted are checked (hence re-formatted) late,
                            -- so we must un-format the to-be-shifted value for IsOverwriting()
                            local fmt = tagInfo.Writable or ''
                            if fmt == 'rational' then
                                val = ConvertRational(val) or val
                            elseif fmt == 'date' then
                                val = ConvertXMPDate(val)
                            end
                        end
                        -- (note: this won't match if original XML contains CDATA!)
                        if not truthy(Writer.IsOverwriting(et, nvHash, UnescapeXML(val))) then goto nextMatch end
                    end
                    if verbose > 1 then
                        local grp = et:GetGroup(tagInfo, 1)
                        local tagName = tagInfo.Name
                        if tagInfo.LangCode then tagName = substDyn(tagName, '-' .. tagInfo.LangCode .. '$', '') end
                        if truthy(attrs1['xml:lang']) then tagName = tagName .. '-' .. attrs1['xml:lang'] end
                        et:VerboseValue('- ' .. grp .. ':' .. tagName, val)
                    end
                    -- save attributes and path from first deleted property
                    -- so we can replace it exactly
                    if #delPaths == 0 then
                        attrs = { }
                        for k, v in pairs(attrs1) do attrs[k] = v end
                    end
                    if writable == 'lang-alt' then
                        langsHere[langPathPat][oldLang] = 0 -- (lang was deleted)
                    end
                    -- save deleted paths so we can replace the same elements
                    -- (separately for each language of a lang-alt list)
                    if writable ~= 'lang-alt' or oldLang == newLang then
                        delPaths[#delPaths + 1] = path1
                    else
                        if not delLangPaths[oldLang] then delLangPaths[oldLang] = { } end
                        table.insert(delLangPaths[oldLang], path1)
                    end
                    -- keep track of paths where we deleted all languages of a lang-alt tag
                    if delLang then
                        local p = subst(path1, [[\d+$]], '')
                        delAllLang[p] = 1
                    end
                    -- delete this tag
                    capture[path1] = nil
                    changed = changed + 1
                    -- delete rdf:type tag if it is the only thing left in this structure
                    do
                        local pp = matches(path1, [[^(.*)\/]])
                        if pp and capture[pp .. '/rdf:type'] then
                            local a = 0
                            for p in pairs(capture) do
                                if isMatchDyn(p, '^' .. quotemeta(pp) .. [[\/[^\/]+]]) then a = a + 1 end
                            end
                            if a == 1 then capture[pp .. '/rdf:type'] = nil end
                        end
                    end
                    ::nextMatch::
                end
                if not (#delPaths > 0 or tagInfo.List or truthy(addLang)) then goto nextTag end
                if #delPaths > 0 then
                    path = table.remove(delPaths, 1)
                    pathPos = nil
                    -- make sure new path is unique
                    while capture[path] do
                        if not isMatch(path, [[ \d(\d+)$]]) then break end
                        path = subst(path, [[ \d(\d+)$]], function(d)
                            local n = d + 1
                            return ' ' .. length(n) .. n
                        end)
                    end
                    deleted = 1
                else
                    -- don't change tag if we couldn't delete old copy
                    -- unless this is a list or an lang-alt tag
                    if not (tagInfo.List or truthy(oldLang)) then goto nextTag end
                    -- avoid adding duplicate entry to lang-alt in a list
                    if writable == 'lang-alt' and next(langsHere) then
                        for _, lp in ipairs(perl.sort(perl.keys(langsHere))) do
                            if not isMatchDyn(path, '^' .. lp .. '$') then goto nextLang end
                            if not truthy(langsHere[lp][newLang]) then break end
                            do
                                local m1, m2, m3 = matches(path, [[(.* )\d(\d+)(.*? \d+)$]])
                                if not m1 then et:Error('Internal error writing lang-alt list') break end
                                local nxt = m2 + 1
                                path = m1 .. length(nxt) .. nxt .. m3 -- step to next index
                                pathPos = nil
                            end
                            ::nextLang::
                        end
                    end
                    -- (match last index to put in same lang-alt list for Bag of lang-alt items)
                    local m, en = matches(path, [[.* (\d+)]])
                    if not m then warn("Internal error: no list index!\n") goto nextTag end
                    added, pathPos = m, en
                end
            else
                -- we are never overwriting, so we must be adding to a list
                -- match the last index unless this is a list of lang-alt lists
                local pat = [[.* (\d+)]]
                if writable == 'lang-alt' then
                    if firstNewPath then
                        path = firstNewPath
                        pathPos = nil
                        overwrite = 1 -- necessary to put x-default entry first below
                    else
                        pat = [[.* (\d+)(.*? \d+)]]
                    end
                end
                -- (the captures, then the end offset: Perl's pos($path) after m//g)
                local m = { matchesDyn(path, pat) }
                if #m > 0 then
                    added = m[1]
                    pathPos = m[#m]
                    -- set position to end of matching index number
                    local m2 = #m == 3 and m[2] or nil
                    if truthy(m2) then pathPos = pathPos - length(m2) end
                end
            end
            if added ~= nil then
                local len = length(added)
                local pos = (pathPos or 0) - len
                local nxt = substr(added, 1) + 1
                -- always insert x-default lang-alt entry first (as per XMP spec)
                -- (need to test $overwrite because this will be a new lang-alt entry otherwise)
                if truthy(overwrite) and writable == 'lang-alt' and (not tagInfo.LangCode or
                    tagInfo.LangCode == 'x-default')
                then
                    local saveCap = capture[path]
                    while saveCap do
                        local p = carray.new('char'):append(path)
                        substr(p, pos, len, length(nxt) .. nxt)
                        p = p:tostring()    -- (a hash key)
                        -- increment index in the path of the existing item
                        local nextCap = capture[p]
                        capture[p] = saveCap
                        if not nextCap then break end
                        saveCap = nextCap
                        nxt = nxt + 1
                    end
                else
                    -- add to end of list
                    while capture[path] do
                        local try = length(nxt) .. nxt
                        path = carray.new('char'):append(path)
                        substr(path, pos, len, try)
                        path = path:tostring()  -- (a hash key)
                        len = length(try)
                        nxt = nxt + 1
                    end
                end
            end
        end
        -- check to see if we want to create this tag
        -- (create non-avoided tags in XMP data files by default)
        local isCreating = (truthy(nvHash.IsCreating) or ((isStruct or
                            (preferred and nvHash.Shift == nil)) and
                            not tagInfo.Avoid and not nvHash.EditOnly))

        -- don't add new values unless...
            -- ...tag existed before and was deleted, or we added it to a list
        if not (deleted or added ~= nil or
            -- ...tag didn't exist before and we are creating it
            (not cap and isCreating)) then goto nextTag end

        -- get list of new values (all done if no new values specified)
        local newValues = et:GetNewValue(nvHash, true)
        if #newValues == 0 then goto nextTag end

        -- set language attribute for lang-alt lists
        if writable == 'lang-alt' then
            attrs['xml:lang'] = tagInfo.LangCode or 'x-default'
            if added ~= nil then firstNewPath = path end  -- save path of first lang-alt tag added
        end
        -- add new value(s) to %capture hash
        local subIdx
        while true do
            local newValue = table.remove(newValues, 1)
            if isStruct then
                if AddNewStruct(et, tagInfo, capture,
                                path, newValue, tagInfo.Struct) ~= 0 then changed = changed + 1 end
            else
                newValue = EscapeXML(newValue)
                repeat -- (a cheap 'goto')
                    if tagInfo.Resource then
                        -- only store as a resource if it doesn't contain any illegal characters
                        if not isMatch(newValue, [=[(?i)[^a-z0-9\:\/\?\#\[\]\@\!\$\&\'\(\)\*\+\,\;\=\.\-\_\~]]=]) then
                            local a = { }
                            for k, v in pairs(attrs) do a[k] = v end
                            a['rdf:resource'] = newValue
                            capture[path] = { '', a }
                            break
                        end
                        local grp = et:GetGroup(tagInfo, 1)
                        et:Warn(grp .. ':' .. tagInfo.Name .. ' written as a literal because value is not a valid URI', 1)
                        -- fall through to write as a string literal
                    end
                    -- remove existing value and/or resource attribute if they exist
                    attrs['rdf:value'] = nil
                    attrs['rdf:resource'] = nil
                    capture[path] = { newValue, attrs }
                until true
                if verbose > 1 then
                    local grp = et:GetGroup(tagInfo, 1)
                    et:VerboseValue('+ ' .. grp .. ':' .. tagInfo.Name, newValue)
                end
                changed = changed + 1
                -- add rdf:type if necessary
                if tagInfo.StructType then
                    AddStructType(et, tagInfo.Table, capture, path)
                end
            end
            if #newValues == 0 then break end
            -- match last index except for lang-alt items where we want to put each
            -- item in a different lang-alt list (so match the 2nd-last for these)
            do
                local pat = writable == 'lang-alt' and [[.* (\d+)(.*? \d+)]] or [[.* (\d+)]]
                pathPos = 0
                -- (the captures, then the end offset: Perl's pos($path) after m//g)
                local m = { matchesDyn(path, pat) }
                if #m == 0 then
                    warn('Internal error: no list index for ' .. tag .. ' (' .. path .. ') (' .. pat .. ")!\n")
                    goto nextValue
                end
                pathPos = m[#m]
                local m2 = #m == 3 and m[2] or nil
                local idx = m[1]
                local len = length(m[1])
                local pos = pathPos - len - (truthy(m2) and length(m2) or 0)
                -- use sub-indices if necessary to store additional values in sequence
                if subIdx then
                    idx = substr(idx, 0, -length(subIdx))   -- remove old sub-index
                    subIdx = substr(subIdx, 1) + 1
                    subIdx = length(subIdx) .. subIdx
                elseif #delPaths > 0 then
                    path = table.remove(delPaths, 1)
                    pathPos = nil
                    -- make sure new path is unique
                    while capture[path] do
                        if not isMatch(path, [[ \d(\d+)$]]) then break end
                        path = subst(path, [[ \d(\d+)$]], function(d)
                            local n = d + 1
                            return ' ' .. length(n) .. n
                        end)
                    end
                    goto nextValue
                else
                    subIdx = '10'
                end
                path = carray.new('char'):append(path)
                substr(path, pos, len, idx .. subIdx)
                path = path:tostring()  -- (a hash key)
                pathPos = nil
            end
            ::nextValue::
        end
        -- make sure any empty structures are deleted
        -- (ExifTool shouldn't write these, but other software may)
        if tagInfo.Flat ~= nil then
            local p = path
            while isMatch(p, [[\/[^\/]+$]]) do
                p = subst(p, [[\/[^\/]+$]], '')
                if not capture[p] then goto nextP end
                -- it is an error if this property has a value
                if isMatch(capture[p][1], [[\S]]) then et:Error('Improperly structured XMP (' .. p .. ')', 1) end
                capture[p] = nil    -- delete the (hopefully) empty structure
                ::nextP::
            end
        end
        end
        ::nextTag::
    end
    -- remove the ExifTool members we created
    et.XMP_CAPTURE = nil
    et.XMP_NS = nil

    local maxDataLen = dirInfo.MaxDataLen
    -- get DataPt again because it may have been set by ProcessXMP
    dataPt = dirInfo.DataPt

    -- return now if we didn't change anything
    if not (changed ~= 0 or (truthy(maxDataLen) and dataPt and
        length(dataPt) > maxDataLen))
    then
        if not xmpFile then return nil end  -- just rewrite original XMP
        if dataPt then
            if not Write(dirInfo.OutFile, dataPt) then return -1 end
        end
        return 1
    end
--
-- write out the new XMP information (serialize it)
--
    -- start writing the XMP data
    local long, short, resFlag = { '', '' }, { '' }, { }
    if et.XMP_NO_XPACKET then
        -- write BOM if flag is set
        if et.XMP_NO_XPACKET == 2 then long[#long - 1] = long[#long - 1] .. "\xef\xbb\xbf" end
    else
        long[#long - 1] = long[#long - 1] .. pktOpen
    end
    if et.XMP_IS_XML then long[#long - 1] = long[#long - 1] .. xmlOpen end
    long[#long - 1] = long[#long - 1] .. xmpOpen .. rdfOpen

    -- initialize current property path list
    local curPropList, writeLast, descStart, extStart = { }, { }, { }, nil
    local nsCur, prop, path = { }
    local pathList = perl.sort(perl.keys(capture), TypeFirst)
    -- order properties to write large values last if we have a MaxDataLen limit
    if truthy(maxDataLen) and #pathList > 0 then
        local pathTmp = { }
        local lastProp, lastNS, propSize = '', '', 0
        local pathLoop = { table.unpack(pathList) }
        pathLoop[#pathLoop + 1] = '' -- add empty path to end of list for loop
        pathList = { }
        for _, path1 in ipairs(pathLoop) do
            local m1, m2 = matches(path1, [[^((\w*)[^\/]*)]])  -- get path element ($1) and ns ($2)
            if m1 == lastProp then
                pathTmp[#pathTmp + 1] = path1   -- accumulate all paths with same root
            else
                -- put in list to write last if recommended or values are too large
                if extendedRes[lastProp] or extendedRes[lastNS] or
                    propSize > newDescThresh
                then
                    for _, p in ipairs(pathTmp) do writeLast[#writeLast + 1] = p end
                else
                    for _, p in ipairs(pathTmp) do pathList[#pathList + 1] = p end
                end
                if not truthy(path1) then break end      -- all done if we hit empty path
                pathTmp = { path1 }
                lastProp, lastNS, propSize = m1, m2, 0
            end
            propSize = propSize + length(capture[path1][1])
        end
    end

    -- write out all properties
    while true do
        local nsNew, newDesc = { }, nil
        if #pathList == 0 then
            if #writeLast == 0 then break end
            pathList = writeLast
            writeLast = { }
            newDesc = 2   -- start with a new description for the extended data
        end
        path = table.remove(pathList, 1)
        local propList = split('/', path) -- get property list
        -- must open/close rdf:Description too
        table.insert(propList, 1, rdfDesc)
        -- make sure we have defined all necessary namespaces
        for _, prop1 in ipairs(propList) do
            local ns = matches(prop1, [[(.*):]])
            if ns == nil then goto nextProp end
            if ns == 'rdf' then goto nextProp end       -- rdf namespace already defined
            do
                local uri = nsUsed[ns]
                if not uri then
                    uri = nsURI[ns]       -- we must have added a namespace
                    if not uri then
                        -- (namespace prefix may be empty if trying to write empty XMP structure, forum12384)
                         if length(ns) > 0 then
                            local err = 'Undefined XMP namespace: ' .. ns
                            if not xmpErr or err ~= xmpErr then
                                if xmpFile then et:Error(err) else et:Warn(err) end
                                xmpErr = err
                            end
                         end
                         goto nextProp
                    end
                end
                nsNew[ns] = uri
                -- need a new description if any new namespaces
                if not nsCur[ns] then newDesc = 1 end
            end
            ::nextProp::
        end
        local closeTo = 0
        if newDesc then
            -- look forward to see if we will want to also open other namespaces
            -- at this level (this is necessary to keep lists and structures from
            -- being broken if a property introduces a new namespace; plus it
            -- improves formatting)
            for _, path2 in ipairs(pathList) do
                local ns2s = findAll(path2, [[(?:^|/)([^/]+?):]])
                local opening = truthy(compact.OneDesc) and 1 or 0
                for _, ns2 in ipairs(ns2s) do
                    if ns2 == 'rdf' then goto nextNS2 end
                    if nsNew[ns2] then
                        opening = opening + 1
                        goto nextNS2
                    end
                    if opening == 0 then break end
                    do
                        -- get URI for this existing or new namespace
                        local uri = nsUsed[ns2] or nsURI[ns2]
                        if not truthy(uri) then break end
                        nsNew[ns2] = uri -- also open this namespace
                    end
                    ::nextNS2::
                end
                if opening == 0 then break end
            end
        else
            -- find first property where the current path differs from the new path
            while closeTo < #curPropList do
                if closeTo >= #propList then break end
                if propList[closeTo + 1] ~= curPropList[closeTo + 1] then break end
                closeTo = closeTo + 1
            end
        end
        -- close out properties down to the common base path
        while #curPropList > closeTo do CloseProperty(curPropList, long, short, resFlag) end

        -- open new description if necessary
        if newDesc then
            if newDesc == 2 then extStart = length(long[#long - 1]) end -- extended data starts after this
            -- save rdf:Description start positions so we can reorder them if necessary
            if truthy(maxDataLen) then descStart[#descStart + 1] = length(long[#long - 1]) end
            -- open the new description
            prop = rdfDesc
            nsCur = { }                 -- save current namespaces
            for k, v in pairs(nsNew) do nsCur[k] = v end
            local ns = perl.sort(perl.keys(nsCur))
            long[#long - 1] = long[#long - 1] .. nl .. sp .. '<' .. prop .. " rdf:about='" .. about .. "'"
            -- generate et:toolkit attribute if this is an exiftool RDF/XML output file
            if et.XMP_NO_XMPMETA and #ns > 0 and isMatch(nsCur[ns[1]], [[^http://ns.exiftool.(?:ca|org)/]]) then
                long[#long - 1] = long[#long - 1] .. "\n" .. sp .. sp .. "xmlns:et='http://ns.exiftool.org/1.0/'" ..
                            " et:toolkit='Image::ExifTool " .. ExifTool.VERSION .. "'"
            end
            for _, n in ipairs(ns) do
                long[#long - 1] = long[#long - 1] .. "\n" .. sp .. sp .. 'xmlns:' .. n .. "='" .. nsCur[n] .. "'"
            end
            curPropList[#curPropList + 1] = prop
            -- set resFlag to 0 to indicate base description when Shorthand enabled
            if truthy(compact.Shorthand) then resFlag[1] = 0 end
        end
        local val, attrs = capture[path][1], capture[path][2]
        if debug ~= 0 then perl.print(io.stdout, path .. ' = ' .. val .. "\n") end
        -- open new properties if necessary
        local dummy
        for n = #curPropList, #propList - 2 do
            prop = propList[n + 1]
            curPropList[#curPropList + 1] = prop
            prop = subst(prop, [[ .*]], '')       -- remove list index if it exists
            -- (we may add parseType and shorthand properties later,
            --  so leave off the trailing ">" for now)
            long[#long] = long[#long] .. (truthy(compact.NoIndent) and '' or string.rep(' ', #curPropList)) .. '<' .. prop
            if prop ~= rdfDesc and (not isMatch(propList[n + 2], [[^rdf:]]) or
                (propList[n + 2] == 'rdf:type' and n + 1 == #propList - 1))
            then
                -- check for empty structure
                if isMatch(propList[n + 2], [[:~dummy~$]]) then
                    long[#long] = long[#long] .. " rdf:parseType='Resource'/>" .. nl
                    table.remove(curPropList)
                    dummy = 1
                    break
                end
                if truthy(compact.Shorthand) then
                    resFlag[#curPropList] = 1
                    long[#long + 1] = ''
                    short[#short + 1] = ''
                else
                    -- use rdf:parseType='Resource' to avoid new 'rdf:Description'
                    long[#long] = long[#long] .. " rdf:parseType='Resource'>" .. nl
                end
            else
                long[#long] = long[#long] .. '>' .. nl -- (will be no shorthand properties)
            end
        end
        local prop2 = table.remove(propList)  -- get new property name
        -- add element unless it was a dummy structure field
        if not (dummy or (val == '' and isMatch(prop2, [[:~dummy~$]]))) then
            prop2 = subst(prop2, [[ .*]], '')      -- remove list index if it exists
            local pad = truthy(compact.NoIndent) and '' or string.rep(' ', #curPropList + 1)
            -- (can't write as shortcut if it has attributes or CDATA)
            if resFlag[#curPropList] ~= nil and next(attrs) == nil and not isMatch(val, [[<!\[CDATA\[]]) then
                short[#short] = short[#short] .. "\n" .. pad .. prop2 .. "='" .. val .. "'"
            else
                long[#long] = long[#long] .. pad .. '<' .. prop2
                -- write out attributes
                for _, attr in ipairs(perl.sort(perl.keys(attrs))) do
                    local attrVal = attrs[attr]
                    local quot = isMatch(attrVal, "'") and '"' or "'"
                    long[#long] = long[#long] .. ' ' .. attr .. '=' .. quot .. attrVal .. quot
                end
                long[#long] = long[#long] .. (length(val) > 0 and ('>' .. val .. '</' .. prop2 .. '>' .. nl) or ('/>' .. nl))
            end
        end
    end
    -- close out all open properties
    while #curPropList > 0 do CloseProperty(curPropList, long, short, resFlag) end

    -- limit XMP length and re-arrange if necessary to fit inside specified size
    if truthy(maxDataLen) then
        -- adjust maxDataLen to allow room for closing elements
        maxDataLen = maxDataLen - (length(rdfClose) + length(xmpClose) + length(pktCloseW))
        if not truthy(extStart) then extStart = length(long[#long - 1]) end
        local longPt = { value = carray.new('char'):append(long[#long - 1]) }
        local extXMP, guid = LimitXMPSize(et, longPt, maxDataLen, about, descStart, extStart)
        long[#long - 1] = longPt.value:tostring()
        -- return extended XMP information in $dirInfo
        dirInfo.ExtendedXMP = extXMP
        dirInfo.ExtendedGUID = guid
        -- compact if necessary to fit
        if length(long[#long - 1]) + 101 * numPadLines > maxDataLen then compact.NoPadding = 1 end
    end
    if truthy(dirInfo.Compact) then compact.NoPadding = 1 end
--
-- close out the XMP, clean up, and return our data
--
    long[#long - 1] = long[#long - 1] .. rdfClose
    if not et.XMP_NO_XMPMETA then long[#long - 1] = long[#long - 1] .. xmpClose end

    -- remove the ExifTool members we created
    et.XMP_CAPTURE = nil
    et.XMP_NS = nil
    et.XMP_NO_XMPMETA = nil

    -- (the XMP standard recommends writing 2k-4k of white space before the
    -- packet trailer, with a newline every 100 characters)
    if not et.XMP_NO_XPACKET then
        local pad = string.rep(' ', 100) .. "\n"
        -- get current XMP length without padding
        local len = length(long[#long - 1]) + length(pktCloseW)
        if truthy(dirInfo.InPlace) and not (dirInfo.InPlace == 2 and len > dirLen) then
            -- pad to specified DirLen
            if len > dirLen then
                local str = 'Not enough room to edit XMP in place'
                if not truthy(compact.Shorthand) then str = str .. '. Try Shorthand feature' end
                et:Warn(str)
                return nil
            end
            local num = (dirLen - len) // length(pad)
            if num ~= 0 then
                long[#long - 1] = long[#long - 1] .. string.rep(pad, num)
                len = len + length(pad) * num
            end
            if len < dirLen then long[#long - 1] = long[#long - 1] .. string.rep(' ', dirLen - len - 1) .. "\n" end
        elseif not truthy(compact.NoPadding) and not xmpFile and not truthy(dirInfo.ReadOnly) then
            long[#long - 1] = long[#long - 1] .. string.rep(pad, numPadLines)
        end
        long[#long - 1] = long[#long - 1] .. (truthy(dirInfo.ReadOnly) and pktCloseR or pktCloseW)
    end
    -- return empty data if no properties exist and this is allowed
    if not (next(capture) or xmpFile or truthy(dirInfo.InPlace) or truthy(dirInfo.NoDelete)) then
        long[#long - 1] = ''
    end
    if xmpErr then
        if xmpFile then return -1 end
        return nil
    end
    et.CHANGED = (et.CHANGED or 0) + changed
    if debug > 1 and truthy(long[#long - 1]) then perl.print(io.stdout, long[#long - 1]) end
    if not xmpFile then return long[#long - 1] end
    if not Write(dirInfo.OutFile, long[#long - 1]) then return -1 end
    return 1
end
-- luacheck: pop

-- (the subs above, for XMP.lua's AUTOLOAD closures)
WriteXMP.XMPOpen = XMPOpen
WriteXMP.ValidateXMP = ValidateXMP
WriteXMP.ValidateProperty = ValidateProperty
WriteXMP.FormatXMPDate = FormatXMPDate
WriteXMP.CheckXMP = CheckXMP
WriteXMP.GetPropertyPath = GetPropertyPath
WriteXMP.SetPropertyPath = SetPropertyPath
WriteXMP.CaptureXMP = CaptureXMP
WriteXMP.SaveBlankInfo = SaveBlankInfo
WriteXMP.ProcessBlankInfo = ProcessBlankInfo
WriteXMP.ConformPathToNamespace = ConformPathToNamespace
WriteXMP.AddStructType = AddStructType
WriteXMP.ProcessGSpherical = ProcessGSpherical
WriteXMP.WriteGSpherical = WriteGSpherical
WriteXMP.EncodeBase64 = EncodeBase64
WriteXMP.ByTagName = ByTagName
WriteXMP.TypeFirst = TypeFirst
WriteXMP.LimitXMPSize = LimitXMPSize
WriteXMP.CloseProperty = CloseProperty

return WriteXMP -- end
