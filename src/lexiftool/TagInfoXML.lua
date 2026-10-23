--------------------------------------------------------------------------------
-- File:         lexiftool/TagInfoXML.lua
-- Ported from:  lib/Image/ExifTool/TagInfoXML.pm
--
-- Description:  Read/write tag information XML database
--
-- Revisions:    2009/01/28 - P. Harvey Created
--
-- Port notes:   the read path is complete: Write (which is what -listx runs),
--               EscapePerl, LoadLangModules and NumbersFirst, in upstream
--               order, plus %credits, %translateLang, $numbersFirst,
--               $caseInsensitive and %fakeWriteGroup.
--
--               BuildLangModules and WriteLangModule are ported as the
--               developer tools they are upstream: BuildLangModules reads a
--               tag info XML database and WriteLangModule writes Perl source
--               to lib/Image/ExifTool/Lang/$lang.pm below the current
--               directory (dying unless lib/Image/ExifTool exists there), the
--               same text upstream writes.  The Lang modules of this port
--               are mechanical copies of the vendored ones (tools/gen_lang.pl)
--               and carry no $VERSION, so a module's version starts at 1.00.
--               The table names read from the XML database keep the upstream
--               spelling as keys of %langInfo and are converted to the port's
--               spelling only to look the table up.
--
--               LoadLangModules loads `lexiftool.Lang.<code>` for each of
--               ExifTool.langs, which is upstream's list of the Lang modules
--               *upstream* has.  All of them are ported, so none of them
--               takes upstream's "Can't load Lang::xx" branch any more.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local Writer = require('lexiftool.Writer')
local XMP = require('lexiftool.XMP')
local perl = require('lexiftool.perl')
local matches, isMatch, isMatchDyn = perl.matches, perl.isMatch, perl.isMatchDyn
local subst = perl.subst
local split = perl.split
local join = perl.join
local length = perl.length
local sprintf = perl.sprintf
local perlTruthy = ExifTool.perlTruthy
local tsort = perl.tsort

local GetTagTable = ExifTool.GetTagTable
local TagTableKeys = ExifTool.TagTableKeys
local GetTagInfoList = ExifTool.GetTagInfoList

local TagInfoXML = {}

local warn = perl.warn
local print = perl.print
local perlStr = perl.str
local perlLc = perl.lc

-- set this to a language code to generate Lang module with 'MISSING' entries
TagInfoXML.makeMissing = ''

-- names for acknowledgements in the POD documentation
local credits = {
    cs   = 'Jens Duttke and Petr MichE<aacute>lek',
    de   = 'Jens Duttke, Herbert Kauer and Jobi',
    es   = 'Jens Duttke, Santiago del BrE<iacute>o GonzE<aacute>lez and Emilio Sancha',
    fi   = 'Jens Duttke and Jarkko ME<auml>kineva',
    fr   = 'Jens Duttke, Bernard Guillotin, Jean Glasser, Jean Piquemal, Harry Nizard, Alphonse Philippe and Philippe Bonnaure (GraphicConverter)',
    it   = 'Jens Duttke, Ferdinando Agovino, Emilio Dati and Michele Locati',
    ja   = 'Jens Duttke and Kazunari Nishina',
    ko   = 'Jens Duttke and Jeong Beom Kim',
    nl   = 'Jens Duttke, Peter Moonen, Herman Beld and Peter van der Laan',
    pl   = 'Jens Duttke, Przemyslaw Sulek and Kacper Perschke',
    ru   = 'Jens Duttke, Sergey Shemetov, Dmitry Yerokhin, Anton Sukhinov and Alexander',
    sk   = 'Peter Bagin',
    sv   = 'Jens Duttke and BjE<ouml>rn SE<ouml>derstrE<ouml>m',
   ['tr'] = 'Jens Duttke, Hasan Yildirim and Cihan Ulusoy',
    zh_cn = 'Jens Duttke and Haibing Zhong',
    zh_tw = 'Jens Duttke and MikeF',
}

-- translate country codes to language codes
local translateLang = {
    ch_s  = 'zh_cn',
    ch_cn = 'zh_cn',
    ch_tw = 'zh_tw',
    cz    = 'cs',
    jp    = 'ja',
    kr    = 'ko',
    se    = 'sv',
}

local numbersFirst = 1  -- set to -1 to sort numbers last, or 2 to put negative numbers last
local caseInsensitive   -- used internally by sort routine

-- write groups that don't represent real family 1 group names
local fakeWriteGroup = {
    Comment = 1,    -- (JPEG Comment)
    colr = 1,       -- (Jpeg2000 'colr' box)
}

-- (port artifact, see the Port notes: spell a table name the way upstream
--  spells it, since the XML database and the Lang modules carry that spelling)
local function upstreamShortName(shortName)
    return (shortName:gsub('%.', '::'))
end

local function upstreamName(tableName)
    -- (the tables ExifTool.pm itself defines are 'lexiftool.ExifTool.X' here,
    --  and the QuickTimeStream.pl ones are in package QuickTime upstream --
    --  the same respelling SetupTagTable applies to SHORT_NAME)
    local name = tableName:gsub('^lexiftool%.ExifTool%.', ''):gsub('^lexiftool%.QuickTimeStream%.', 'QuickTime.')
    return 'Image::ExifTool::' .. upstreamShortName(name:gsub('^lexiftool%.', ''))
end

-- (port artifact, see the Port notes: Perl hash keys are strings)
local function keyStr(key)
    return type(key) == 'number' and ExifTool.NumStr(key) or perlStr(key)
end

-- (port artifact: upstream tells an indexed PrintConv (an ARRAY of
--  conversions) from a plain lookup (a HASH) with ref(); a Lua table is both
--  at once, so the test is the one GetValue uses (lexiftool.lua, "split into
--  list if conversion is an array"): the first element is a table, a
--  function (an upstream expression string or code ref) or `false`
--  (upstream undef) -- a plain lookup's values are strings or numbers only,
--  including the one under key 1)
local function isArrayConv(conv)
    if type(conv) ~= 'table' then return false end
    local first = conv[1]
    return first == false or type(first) == 'table' or type(first) == 'function'
end

-- (the subs upstream predeclares at the top of the file: LoadLangModules,
--  WriteLangModule and NumbersFirst.  They are package subs, so they live on
--  the module table; the file-scope locals are the forward reference Write
--  needs, bound right after each definition below)
local LoadLangModules, NumbersFirst

--------------------------------------------------------------------------------
-- Utility to print tag information database as an XML list
-- Inputs: 0) output file name (undef to send to console),
--         1) group name (may be undef), 2) options hash ('Flags','NoDesc','Lang')
-- Returns: true on success
function TagInfoXML.Write(file, group, opts)
    opts = opts or {}
    local et = ExifTool.new()
    local fp, tableName, defaultLang
    local langInfo, langs, groups = {}, {}, {}
    if group then groups = split(':', group) end

    Writer.LoadAllTables()  -- first load all our tables
    if not opts.NoDesc then
        defaultLang = ExifTool.defaultLang
        LoadLangModules(langInfo, opts.Lang) -- load necessary Lang modules
        if opts.Lang then
            for lang in pairs(langInfo) do
                if isMatchDyn(lang, '(?i)^' .. opts.Lang .. '$') then langs[#langs + 1] = lang end
            end
        else
            for lang in pairs(langInfo) do langs[#langs + 1] = lang end
            tsort(langs)
        end
    end
    if file ~= nil then
        local err
        fp, err = io.open(file, 'w')
        if not fp then return 0, err end
    else
        fp = io.stdout
    end
    print(fp, "<?xml version='1.0' encoding='UTF-8'?>\n")
    print(fp, '<!-- Generated by Image::ExifTool ' .. ExifTool.VERSION .. ' -->\n')
    print(fp, '<taginfo>\n\n')

    -- loop through all tables and save tag names to %allTags hash
    local tableNames = {}
    for name in pairs(ExifTool.GetAllTables()) do tableNames[#tableNames + 1] = name end
    -- (upstream sorts `keys %allTables`, whose names are 'Image::ExifTool::X::Y';
    --  sorting this port's 'lexiftool.X.Y' names by their upstream spelling is
    --  what keeps upstream's table order)
    tsort(tableNames, function(a, b) return perl.lt(upstreamName(a), upstreamName(b)) end)
    for _, luaTableName in ipairs(tableNames) do
        tableName = upstreamName(luaTableName)
        local table_ = GetTagTable(nil, luaTableName)
        local grps = table_.GROUPS
        local didTag
        -- sort in same order as tag name documentation
        caseInsensitive = (matches(tableName, [[::XMP::]]) ~= nil)
        -- get list of languages defining elements in this table
        local isBinary = (table_.PROCESS_PROC and
                          table_.PROCESS_PROC == ExifTool.ProcessBinaryData)
        -- generate flattened tag names for structure fields if this is an XMP table
        if table_.GROUPS and table_.GROUPS[0] == 'XMP' then
            XMP.AddFlattenedTags(table_)
        end
        numbersFirst = 2
        if table_.VARS and table_.VARS.ALPHA_FIRST then numbersFirst = -1 end
        local keys = TagTableKeys(table_)
        tsort(keys, function(a, b) return NumbersFirst(keyStr(a), keyStr(b)) < 0 end)
        numbersFirst = 1
        -- loop through all tag ID's in this table
        for _, tagID in ipairs(keys) do
            local infoArray = GetTagInfoList(table_, tagID)
            local xmlID = XMP.FullEscapeXML(keyStr(tagID))
            -- get a list of languages defining elements for this ID
            local index, fam
            for i = 1, #infoArray do
                index = i - 1
                repeat -- PTILoop:
                local tagInfo = infoArray[i]
                -- don't list subdirectories unless they are writable
                if not (perlTruthy(tagInfo.Writable) or not tagInfo.SubDirectory) then break end
                if perlTruthy(tagInfo.Hidden) then break end
                if #groups > 0 then
                    local tg = et:GetGroup(tagInfo)
                    local skip
                    for _, grp in ipairs(groups) do
                        local found
                        for f = 0, 3 do
                            if tg[f] and isMatchDyn(tg[f], '(?i)^' .. grp .. '$') then found = true break end
                        end
                        if not found then skip = true break end
                    end
                    if skip then break end  -- next PTILoop
                end
                if not didTag then
                    local tname = upstreamShortName(table_.SHORT_NAME)
                    print(fp, "<table name='" .. tname .. "' g0='" .. grps[0] .. "' g1='" ..
                             grps[1] .. "' g2='" .. grps[2] .. "'>\n")
                    if not opts.NoDesc then
                        -- print table description
                        local desc = table_.TABLE_DESC
                        if not desc then
                            desc = subst(tname, [[::Main$]], '')
                            desc = subst(desc, [[::]], ' ', 'g')
                        end
                        -- print alternate language descriptions
                        print(fp, " <desc lang='en'>" .. desc .. '</desc>\n')
                        for _, lang in ipairs(langs) do
                            desc = langInfo[lang][tableName]
                            if desc then
                                desc = XMP.EscapeXML(desc)
                                print(fp, " <desc lang='" .. lang .. "'>" .. desc .. '</desc>\n')
                            end
                        end
                    end
                    didTag = 1
                end
                local name = tagInfo.Name
                local ind = #infoArray > 1 and (" index='" .. index .. "'") or ''
                local format = perlTruthy(tagInfo.Writable) and tagInfo.Writable or table_.WRITABLE
                local writable = perlTruthy(format) and 'true' or 'false'
                -- check our conversions to make sure we can really write this tag
                if writable == 'true' then
                    if tagInfo.Writable ~= nil and not perlTruthy(tagInfo.Writable) then writable = 'false' end
                    for _, conv in ipairs({ 'PrintConv', 'ValueConv' }) do
                        if tagInfo[conv] and
                           not tagInfo[conv .. 'Inv'] and
                           type(tagInfo[conv]) ~= 'table' and
                           not tagInfo.WriteAlso then
                            writable = 'false'
                            break
                        end
                    end
                end
                if not perlTruthy(format) or keyStr(format) == '1' then
                    format = tagInfo.Format or table_.FORMAT
                end
                if tagInfo.Struct then format = 'struct' end
                if format ~= nil then
                    format = keyStr(format)
                    format = subst(format, [==[\[.*\$.*\]]==], '')  -- remove expressions from format
                    if format == '2' then format = 'undef' end  -- (special case)
                elseif isBinary then
                    format = 'int8u'
                else
                    format = '?'
                end
                local count = ''
                local cnt = matches(format, [[\[.*?(\d*)\]$]])
                if cnt ~= nil then
                    format = subst(format, [[\[.*?(\d*)\]$]], '')
                    if length(cnt) > 0 then count = " count='" .. cnt .. "'" end
                elseif perlTruthy(tagInfo.Count) and perl.num(tagInfo.Count) > 1 then
                    count = " count='" .. keyStr(tagInfo.Count) .. "'"
                end
                local groups = et:GetGroup(tagInfo) -- luacheck: ignore 421
                local writeGroup = tagInfo.WriteGroup or table_.WRITE_GROUP
                -- use common write group for group 1 (unless fake)
                if writeGroup and not fakeWriteGroup[writeGroup] then groups[1] = writeGroup end
                -- add group names if different from table defaults
                local grp = ''
                for f = 0, 2 do
                    fam = f
                    if groups[fam] ~= grps[fam] then grp = grp .. ' g' .. fam .. "='" .. groups[fam] .. "'" end
                end
                -- add flags if necessary
                if opts.Flags then
                    local flags = {}
                    for _, f in ipairs({ 'Avoid', 'Binary', 'List', 'Mandatory', 'Unknown' }) do
                        if perlTruthy(tagInfo[f]) then flags[#flags + 1] = f end
                    end
                    if perlTruthy(tagInfo.List) and matches(keyStr(tagInfo.List), [[^(Alt|Bag|Seq)$]]) then
                        flags[#flags + 1] = tagInfo.List
                    end
                    if tagInfo.Flat ~= nil then flags[#flags + 1] = 'Flattened' end
                    if perlTruthy(tagInfo.Protected) and (perl.num(tagInfo.Protected) & 0x01) ~= 0 then
                        flags[#flags + 1] = 'Unsafe'
                    end
                    if perlTruthy(tagInfo.Protected) and (perl.num(tagInfo.Protected) & 0x02) ~= 0 then
                        flags[#flags + 1] = 'Protected'
                    end
                    if perlTruthy(tagInfo.Permanent) or
                       (groups[0] == 'MakerNotes' and tagInfo.Permanent == nil) then
                        flags[#flags + 1] = 'Permanent'
                    end
                    if #flags > 0 then
                        tsort(flags)
                        grp = " flags='" .. join(',', flags) .. "'" .. grp
                    end
                    -- add parent structure tag ID
                    if tagInfo.ParentTagInfo then
                        grp = grp .. " struct='" .. keyStr(tagInfo.ParentTagInfo.TagID) .. "'"
                    end
                end
                print(fp, " <tag id='" .. xmlID .. "' name='" .. name .. "'" .. ind ..
                         " type='" .. format .. "'" .. count .. " writable='" .. writable .. "'" .. grp)
                if opts.NoDesc then
                    -- short output format
                    print(fp, '/>\n')    -- empty tag element
                    break               -- no descriptions or values
                else
                    print(fp, '>')
                end
                local desc = tagInfo.Description
                if desc == nil then desc = ExifTool.MakeDescription(name) end
                -- add alternate language descriptions and get references
                -- to alternate language PrintConv hashes
                local altDescr = ''
                local langConv = {}
                for _, lang in ipairs(langs) do
                    local ld = langInfo[lang][name]
                    if ld then
                        if type(ld) == 'table' then
                            langConv[lang] = ld.PrintConv
                            ld = ld.Description
                        end
                        -- ignore descriptions that are the same as the default language
                        if ld and ld ~= desc then
                            ld = XMP.EscapeXML(ld)
                            altDescr = altDescr .. "\n  <desc lang='" .. lang .. "'>" .. ld .. '</desc>'
                        end
                    end
                end
                -- print tag descriptions
                desc = XMP.EscapeXML(desc)
                if not (opts.Lang and altDescr ~= '') then
                    print(fp, "\n  <desc lang='" .. defaultLang .. "'>" .. desc .. '</desc>')
                end
                print(fp, altDescr .. '\n')
                local vi = 0
                while true do
                    local conv = tagInfo.PrintConv
                    -- (hidden = '' disables PrintConv in -listx output)
                    if tagInfo.Hidden == '' then break end
                    local idx = ''
                    if isArrayConv(conv) then
                        if vi >= #conv then break end
                        conv = conv[vi + 1]
                        idx = " index='" .. vi .. "'"
                    else
                        if vi > 0 then break end
                    end
                    if type(conv) == 'table' then
                        -- make a list of available alternate languages
                        local langConvList = {}
                        for lang in pairs(langConv) do langConvList[#langConvList + 1] = lang end
                        tsort(langConvList)
                        print(fp, '  <values' .. idx .. '>\n')
                        caseInsensitive = false
                        -- add bitmask values to main lookup
                        if conv.BITMASK then
                            for bit, v in pairs(conv.BITMASK) do
                                local mask = 'Bit' .. keyStr(bit)
                                if not conv[mask] then conv[mask] = v end
                            end
                        end
                        local convKeys = {}
                        for k in pairs(conv) do convKeys[#convKeys + 1] = k end
                        tsort(convKeys, function(a, b) return NumbersFirst(keyStr(a), keyStr(b)) < 0 end)
                        for _, key in ipairs(convKeys) do
                            local ks = keyStr(key)
                            if ks ~= 'BITMASK' and ks ~= 'OTHER' and ks ~= 'Notes' then
                                local val = conv[key]
                                do
                                    val = keyStr(val)
                                    local xmlVal = XMP.EscapeXML(val)
                                    local xmlKey = XMP.FullEscapeXML(ks)
                                    print(fp, "   <key id='" .. xmlKey .. "'>\n")
                                    -- add alternate language values
                                    local altConv = ''
                                    for _, lang in ipairs(langConvList) do
                                        local lv = langConv[lang]
                                        if isArrayConv(lv) then lv = lv[vi + 1] end
                                        if lv then
                                            lv = lv[val]
                                            -- ignore values that are missing or same as default
                                            if lv ~= nil and lv ~= val then
                                                lv = XMP.EscapeXML(lv)
                                                altConv = altConv .. "    <val lang='" .. lang .. "'>" ..
                                                          lv .. '</val>\n'
                                            end
                                        end
                                    end
                                    if not (opts.Lang and altConv ~= '') then
                                        print(fp, "    <val lang='" .. defaultLang .. "'>" .. xmlVal .. '</val>\n')
                                    end
                                    print(fp, altConv .. '   </key>\n')
                                end
                            end
                        end
                        print(fp, '  </values>\n')
                    end
                    vi = vi + 1
                end
                print(fp, ' </tag>\n')
                until true
            end
        end
        if didTag then print(fp, '</table>\n\n') end
    end
    local success = 1
    print(fp, '</taginfo>\n')
    if file ~= nil then fp:close() end
    return success
end

--------------------------------------------------------------------------------
-- Escape backslash and quote in string
-- Inputs: string
-- Returns: escaped string
function TagInfoXML.EscapePerl(str)
    str = subst(str, [[\\]], [[\\\\]], 'g')
    str = subst(str, [[']], [[\']], 'g')
    return str
end

--------------------------------------------------------------------------------
-- Generate Lang modules from input tag info XML database
-- Inputs: 0) XML filename, 1) update flags:
--       0x01 = preserve version numbers
--       0x02 = update all modules, even if they didn't change
--       0x04 = update from scratch, ignoring existing definitions
--       0x08 = override existing different descriptions and values
-- Returns: Count of updated Lang modules, or -1 on error
-- Notes: Must be run from the directory containing 'lib'
function TagInfoXML.BuildLangModules(file, updateFlag)
    local table_, tableName, id, index, valIndex, name, key, lang, defDesc
    local langInfo, different, changed, overrideDifferent = {}, {}, {}, nil
    local makeMissing = TagInfoXML.makeMissing

    Writer.LoadAllTables()  -- first load all our tables
    -- generate our flattened tags
    local tableNames = {}
    for tn in pairs(ExifTool.GetAllTables()) do tableNames[#tableNames + 1] = tn end
    tsort(tableNames, function(x, y) return perl.lt(upstreamName(x), upstreamName(y)) end)
    for _, tn in ipairs(tableNames) do
        local tbl = GetTagTable(nil, tn)
        if tbl.GROUPS and tbl.GROUPS[0] == 'XMP' then
            XMP.AddFlattenedTags(tbl)
        end
    end
    LoadLangModules(langInfo)       -- load all existing Lang modules
    if not updateFlag then updateFlag = 0 end
    if updateFlag & 0x04 ~= 0 then langInfo = {} end
    if updateFlag & 0x08 ~= 0 then overrideDifferent = 1 end

    if file ~= nil then
        local xfile = io.open(file, 'rb')
        if not xfile then return -1 end
        for line in xfile:lines('L') do
            local isTok, t1, tok = isMatch(line, [[^\s*<(\/?)(\w+)]])
            if not isTok then goto next_ end
            if perlTruthy(t1) then
                -- close appropriate entities
                if tok == 'tag' then
                    id, index, name, defDesc = nil, nil, nil, nil
                elseif tok == 'values' then
                    key, valIndex = nil, nil
                elseif tok == 'table' then
                    table_, id = nil, nil
                end
                goto next_
            end
            if tok == 'table' then
                local isT, tn = isMatch(line, [=[^\s*<table name='([^']+)'[ >]]=])
                if not isT then warn('Bad table') goto next_ end
                tableName = "Image::ExifTool::" .. tn
                -- ignore userdefined tables
                if isMatch(tableName, '^Image::ExifTool::UserDefined') then goto next_ end
                table_ = GetTagTable(nil, 'lexiftool.' .. tn:gsub('::', '.'))
                if not table_ then warn("Unknown tag table " .. tableName .. "\n") end
                goto next_
            end
            if table_ == nil then goto next_ end
            if tok == 'tag' then
                local isTag, i1, i2, _, i4 = isMatch(line, [=[^\s*<tag id='([^']*)' name='([^']+)'( index='(\d+)')?[ >]]=])
                if not isTag then warn('Bad tag') goto next_ end
                id = XMP.FullUnescapeXML(i1)
                name = i2
                index = i4
                -- convert hex ID's unless ID_FMT is something other than 'hex'
                -- (for string ID's that look like hex)
                if isMatch(id, [[^0x[\da-fA-F]+$]]) and (table_.VARS == nil or
                    table_.VARS.ID_FMT == nil or table_.VARS.ID_FMT == 'hex')
                then
                    id = perl.hex(id)
                end
                goto next_
            end
            if tok == 'values' then
                local isV, v1 = isMatch(line, [[^\s*<values index='([^']*)'>]])
                if not isV then goto next_ end
                valIndex = perl.num(v1)
            elseif tok == 'key' then
                if id == nil then warn('No ID') goto next_ end
                local isK, k1 = isMatch(line, [[^\s*<key id='([^']*)'>]])
                if not isK then warn('Bad key') goto next_ end
                key = XMP.FullUnescapeXML(k1)
                if isMatch(key, [[^0x[\da-fA-F]+$]]) then key = perl.hex(key) end -- convert hex keys
            elseif tok == 'val' or tok == 'desc' then
                local isVal, _, l2, l3 = perl.isMatchDyn(line, [[^\s*<]] .. tok .. [[( lang='([-\w]+?)')?>(.*)<\/]] .. tok .. '>')
                if not isVal then warn("Bad " .. tok) goto next_ end
                if tok == 'desc' and key ~= nil then warn('Out of order "desc"') goto next_ end
                lang = l2
                if not perlTruthy(lang) then goto next_ end -- looking only for alternate languages
                lang = perl.tr(lang, '-A-Z', '_a-z')
                -- use standard ISO 639-1 language codes
                if translateLang[lang] then lang = translateLang[lang] end
                local tval = XMP.UnescapeXML(l3)
                local val = perl.ucfirst(tval)
                if isMatch(tval, '^(cRAW|iTun)') then val = tval end -- special-case non-capitalized values
                local cap = (tval ~= val)
                if perlTruthy(makeMissing) then
                    if lang == 'en' then
                        lang = makeMissing
                        val = 'MISSING'
                        cap = nil
                    end
                elseif val == 'MISSING' then
                    goto next_  -- ignore "MISSING" entries
                end
                local isDefault = (lang == ExifTool.defaultLang)
                if not (langInfo[lang] or isDefault) then
                    print(io.stdout, "Creating new language " .. lang .. "\n")
                    langInfo[lang] = { }
                end
                if name == nil then name = '<unknown>' end
                if id == nil then
                    if isDefault then goto next_ end
                    -- this is a table description
                    if langInfo[lang][tableName] and
                            langInfo[lang][tableName] == val then goto next_ end
                    langInfo[lang][tableName] = val
                    changed[lang] = 1
                    if cap then warn("Capitalized '" .. lang .. "' val for " .. name .. ": " .. val .. "\n") end
                    goto next_
                end
                local infoArray = GetTagInfoList(table_, id)

                -- this will fail for UserDefined tags and tags without ID's
                if #infoArray == 0 then warn("Error loading tag for " .. tableName .. " ID='" .. keyStr(id) .. "'\n") goto next_ end
                local tagInfo, lInfo
                if index ~= nil then
                    tagInfo = infoArray[perl.num(index) + 1]
                    if not tagInfo then warn('Invalid index') goto next_ end
                else
                    if #infoArray > 1 then warn('Missing index') goto next_ end
                    tagInfo = infoArray[1]
                end
                local tagName = tagInfo.Name
                if isDefault then
                    if not perlTruthy(tagInfo.Description) then
                        tagInfo.Description = ExifTool.MakeDescription(tagName)
                    end
                    defDesc = tagInfo.Description
                    lInfo = tagInfo
                else
                    lInfo = langInfo[lang][tagName]
                    if lInfo == nil then
                        lInfo = { }
                        langInfo[lang][tagName] = lInfo
                    elseif type(lInfo) ~= 'table' then
                        lInfo = { Description = lInfo }
                        langInfo[lang][tagName] = lInfo
                    end
                end
                -- save new value in langInfo record
                if tok == 'desc' then
                    local oldVal = lInfo.Description
                    if oldVal ~= nil and oldVal == val then goto next_ end
                    if perlTruthy(makeMissing) then
                        if oldVal ~= nil and val == 'MISSING' then goto next_ end
                    elseif oldVal ~= nil then
                        local t = lang .. " " .. tagName
                        if not (different[t] ~= nil and different[t] == val) then
                            local a = different[t] ~= nil and 'ANOTHER ' or ''
                            warn(a .. "Different '" .. lang .. "' desc for " .. tagName .. ": " .. val .. " (was " .. lInfo.Description .. ")\n")
                            if different[t] ~= nil then goto next_ end -- don't change back again
                            different[t] = val
                        end
                        if not overrideDifferent then goto next_ end
                    end
                    if isDefault then goto next_ end
                    if defDesc ~= nil and defDesc == val then
                        lInfo.Description = nil -- delete if same as default language
                    else
                        lInfo.Description = val
                    end
                else
                    if key == nil then warn("No key for " .. tagInfo.Name) goto next_ end
                    local printConv = tagInfo.PrintConv
                    if isArrayConv(printConv) then
                        if valIndex == nil then warn('No value index') goto next_ end
                        printConv = printConv[valIndex + 1]
                    end
                    if type(printConv) ~= 'table' then warn('No PrintConv') goto next_ end
                    local convVal = printConv[key]
                    if convVal == nil and type(key) == 'string' then convVal = printConv[tonumber(key)] end
                    if convVal == nil then
                        if printConv.BITMASK and isMatch(keyStr(key), [[^\d+$]]) then
                            for i = 0, 63 do
                                local mask = (0x01 << i)
                                if mask == 0 then break end
                                if perl.num(key) == mask then
                                    convVal = printConv.BITMASK[i]
                                end
                            end
                        end
                        if convVal == nil then
                            if warn("Missing PrintConv entry for " .. tableName .. " " .. tagInfo.Name .. " " .. keyStr(key) .. "\n") then goto next_ end
                        end
                    end
                    if cap and isMatch(convVal, '^[a-z]') then
                        val = perl.lcfirst(val)    -- change back to lower case
                        cap = nil
                    end
                    local lc = lInfo.PrintConv
                    if not lc then
                        lc = { }
                        lInfo.PrintConv = lc
                    end
                    if isArrayConv(lc) then lc = printConv end -- (default lang only)
                    local oldVal = lc[convVal]
                    if oldVal ~= nil and oldVal == val then goto next_ end
                    if perlTruthy(makeMissing) then
                        if oldVal ~= nil and val == 'MISSING' then goto next_ end
                    elseif oldVal ~= nil and (not isDefault or not isMatch(val, [[^\d+$]])) then
                        local t = lang .. " " .. tagName .. " " .. convVal
                        if not (different[t] ~= nil and different[t] == val) then
                            local a = different[t] ~= nil and 'ANOTHER ' or ''
                            warn(a .. "Different '" .. lang .. "' val for " .. tagName .. " '" .. convVal .. "': " .. val .. " (was " .. oldVal .. ")\n")
                            if different[t] ~= nil then goto next_ end -- don't change back again
                            different[t] = val
                        end
                        if not overrideDifferent then goto next_ end
                    end
                    if isDefault then goto next_ end
                    if cap then warn("Capitalized '" .. lang .. "' val for " .. tagName .. ": " .. tval .. "\n") end
                    lc[convVal] = val
                end
                changed[lang] = 1
            end
            ::next_::
        end
        xfile:close()
    end
    -- rewrite all changed Lang modules
    local rtnVal = 0
    local langList
    if updateFlag & 0x02 ~= 0 then
        langList = ExifTool.langs
    else
        langList = {}
        for l in pairs(changed) do langList[#langList + 1] = l end
        tsort(langList)
    end
    for _, l in ipairs(langList) do
        lang = l
        if lang ~= ExifTool.defaultLang then
            rtnVal = rtnVal + 1
            -- write this module (only increment version number if not forced)
            if not perlTruthy(TagInfoXML.WriteLangModule(lang, langInfo[lang], updateFlag & 0x01 == 0)) then
                rtnVal = -1
                break
            end
        end
    end
    return rtnVal
end

--------------------------------------------------------------------------------
-- Write Lang module
-- Inputs: 0) language string, 1) langInfo lookup reference, 2) flag to increment version
-- Returns: true on success
function TagInfoXML.WriteLangModule(lang, langTags, newVersion)
    local err
    if not perl.stat("lib/Image/ExifTool") then perl.die("Must run from directory containing 'lib'\n") end
    local out = "lib/Image/ExifTool/Lang/" .. lang .. ".pm"
    local tmp = out .. ".tmp"
    local xout = io.open(tmp, 'wb')
    if not xout then perl.die("Error creating " .. tmp .. "\n") end
    -- (upstream reads $Image::ExifTool::Lang::${lang}::VERSION; the Lang
    --  modules of this port carry no version, see the Port notes)
    local ver = package.loaded['lexiftool.Lang.' .. lang] and package.loaded['lexiftool.Lang.' .. lang].VERSION
    if perlTruthy(ver) then
        if newVersion then ver = perl.int(ver * 100 + 1.5) / 100 end
    else
        ver = 1.0
    end
    ver = sprintf('%.2f', ver)
    local langName = ExifTool.langName[lang] or lang
    langName = subst(langName, [[\s*\(.*]], '')
    print(xout, (([[
#------------------------------------------------------------------------------
# File:         $lang.pm
#
# Description:  ExifTool $langName language translations
#
# Notes:        This file generated automatically by Image::ExifTool::TagInfoXML
#------------------------------------------------------------------------------

package Image::ExifTool::Lang::$lang;

use strict;
use vars qw(\$VERSION);

\$VERSION = '${ver}';

]]):gsub('%$langName', langName):gsub('%$lang', lang):gsub('%${ver}', ver):gsub('\\%$', '$')))
    print(xout, "%Image::ExifTool::Lang::" .. lang .. "::Translate = (\n")
    -- loop through all tag and table names
    local tags = {}
    for t in pairs(langTags) do tags[#tags + 1] = t end
    tsort(tags)
    for _, tag in ipairs(tags) do
        local desc = langTags[tag]
        local conv
        if type(desc) == 'table' then
            conv = desc.PrintConv
            desc = desc.Description
            -- remove description if not necessary
            -- (not strictly correct -- should test against tag description, not name)
            if perlTruthy(desc) and desc == tag then desc = nil end
            -- remove unnecessary value translations
            if conv then
                local keys = {}
                for k in pairs(conv) do keys[#keys + 1] = k end
                for _, k in ipairs(keys) do
                    if keyStr(k) == conv[k] then conv[k] = nil end
                end
                if next(conv) == nil then conv = nil end
            end
        end
        if desc ~= nil then
            desc = TagInfoXML.EscapePerl(desc)
        elseif not conv then
            goto next_
        end
        print(xout, "   '" .. tag .. "' => ")
        if not conv then
            print(xout, "'" .. desc .. "',\n")
            goto next_
        end
        print(xout, "{\n")
        if desc ~= nil then print(xout, "      Description => '" .. desc .. "',\n") end
        if conv then
            print(xout, "      PrintConv => {\n")
            local ckeys = {}
            for k in pairs(conv) do ckeys[#ckeys + 1] = keyStr(k) end
            tsort(ckeys)
            for _, k in ipairs(ckeys) do
                local str = TagInfoXML.EscapePerl(k)
                local v = conv[k]
                if v == nil then v = conv[tonumber(k)] end
                local val = TagInfoXML.EscapePerl(v)
                print(xout, "        '" .. str .. "' => '" .. val .. "',\n")
            end
            print(xout, "      },\n")
        end
        print(xout, "    },\n")
        ::next_::
    end
    -- generate acknowledgements for this language
    local ack
    if credits[lang] then
        ack = "Thanks to " .. credits[lang] .. " for providing this translation."
        ack = subst(ack, [[(?s)(.{1,76})( +|$)]], "$1\n", 'g') -- wrap text to 76 columns
        ack = "~head1 ACKNOWLEDGEMENTS\n\n" .. ack .. "\n"
    else
        ack = ''
    end
    local footer = ([[
);

1;  # end

__END__

~head1 NAME

Image::ExifTool::Lang::$lang.pm - ExifTool $langName language translations

~head1 DESCRIPTION

This file is used by Image::ExifTool to generate localized tag descriptions
and values.

~head1 AUTHOR

Copyright 2003-2026, Phil Harvey (philharvey66 at gmail.com)

This library is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

$ack~head1 SEE ALSO

L<Image::ExifTool(3pm)|Image::ExifTool>,
L<Image::ExifTool::TagInfoXML(3pm)|Image::ExifTool::TagInfoXML>

~cut
]]):gsub('%$langName', langName):gsub('%$lang', lang):gsub('%$ack', function() return ack end)
    footer = subst(footer, '(?m)^~', '=', 'g') -- un-do pod obfuscation
    if not perlTruthy(print(xout, footer)) then err = 1 end
    if not xout:close() then err = 1 end
    if err or not os.rename(tmp, out) then
        warn("Error writing " .. out .. "\n")
        os.remove(tmp)
        err = 1
    end
    return err and 0 or 1
end

--------------------------------------------------------------------------------
-- load all lang modules into hash
-- Inputs: 0) Hash reference, 1) specific language to load (undef for all)
function TagInfoXML.LoadLangModules(langHash, lang)
    local langs = lang and { lang } or ExifTool.langs
    for _, l in ipairs(langs) do
        lang = l
        repeat
        if lang == ExifTool.defaultLang then break end
        local ok, xlat = pcall(require, 'lexiftool.Lang.' .. lang)
        if not ok or type(xlat) ~= 'table' then
            warn("Can't load Lang::" .. lang .. '\n')
            break
        end
        if next(xlat) == nil then
            warn('Missing Info for ' .. lang .. '\n')
            break
        end
        langHash[lang] = xlat
        until true
    end
end

LoadLangModules = TagInfoXML.LoadLangModules

--------------------------------------------------------------------------------
-- sort numbers first numerically, then strings alphabetically (case insensitive)
function TagInfoXML.NumbersFirst(a, b)
    local rtnVal
    local bNum, _, bDec = matches(b, [[^(-?[0-9]+)(\.(\d*))?$]])
    local aNum, _, aFrac = matches(a, [[^(-?[0-9]+)(\.(\d*))?$]])
    if aNum ~= nil then
        if bNum ~= nil then
            bNum = tonumber(bNum)
            if numbersFirst == 2 and bNum < 0 then bNum = bNum + 1e9 end
            local aInt = tonumber(aNum)
            if numbersFirst == 2 and aInt < 0 then aInt = aInt + 1e9 end
            -- compare integer part as a number
            rtnVal = (aInt < bNum and -1) or (aInt > bNum and 1) or 0
            if rtnVal == 0 then
                local aDec = tonumber(aFrac or '') or 0
                bDec = tonumber(bDec or '') or 0
                -- compare decimal part as an integer too
                -- (so that "1.10" comes after "1.9")
                rtnVal = (aDec < bDec and -1) or (aDec > bDec and 1) or 0
            end
        else
            rtnVal = -numbersFirst
        end
    elseif bNum ~= nil then
        rtnVal = numbersFirst
    else
        local a2, b2 = a, b
        -- expand numbers to 3 digits (with restrictions to avoid messing up ascii-hex tags)
        if isMatch(a2, [[^(APP|DMC-\w+ )?[.0-9 ]*$]]) and length(a2) < 16 then
            a2 = subst(a2, [[(\d+)]], function(d) return sprintf('%.3d', tonumber(d)) end, 'g')
        end
        if isMatch(b2, [[^(APP|DMC-\w+ )?[.0-9 ]*$]]) and length(b2) < 16 then
            b2 = subst(b2, [[(\d+)]], function(d) return sprintf('%.3d', tonumber(d)) end, 'g')
        end
        if caseInsensitive then
            local la, lb = perlLc(a2), perlLc(b2)
            rtnVal = perl.cmp(la, lb)
        end
        if not rtnVal or rtnVal == 0 then
            rtnVal = perl.cmp(a2, b2)
        end
    end
    return rtnVal
end

NumbersFirst = TagInfoXML.NumbersFirst

return TagInfoXML
