--------------------------------------------------------------------------------
-- File:         lexiftool/HTML.lua
-- Ported from:  lib/Image/ExifTool/HTML.pm
--
-- Description:  Read HTML meta information
--
-- Revisions:    01/30/2007 - P. Harvey Created
--
-- References:   1) http://www.w3.org/TR/html4/
--               2) http://www.daisy.org/publications/specifications/daisy_202.html
--               3) http://vancouver-webpages.com/META/metatags.detail.html
--               4) http://www.html-reference.com/META.htm
--
-- Port notes:   Complete port of HTML.pm: every table, lookup and sub, in
--               upstream order.  Deviations forced by Lua:
--               - `local $/` (from PostScript::GetInputRecordSeparator) is
--                 the RS argument of ReadLine and is spliced into the
--                 linefeed-replacing regex as upstream interpolates it.
--               - EscapeXML/UnescapeXML are XMP's (upstream imports them);
--                 XMP is required where they are used, not at the top.
--               - EscapeChar takes the first code point with utf8.codepoint
--                 (upstream: unpack('C0U')); a malformed sequence gives 0.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local perl = require('lexiftool.perl')
local matches = perl.matches
local matchesDyn = perl.matchesDyn
local isMatch = perl.isMatch
local subst = perl.subst
local substDyn = perl.substDyn
local tr = perl.tr
local lc = perl.lc
local uc = perl.uc
local ucfirst = perl.ucfirst
local chr = perl.chr
local hex = perl.hex
local length = perl.length
local substr = perl.substr
local sprintf = perl.sprintf
local truthy = perl.truthy
local GetTagTable = ExifTool.GetTagTable
local AddTagToTable = ExifTool.AddTagToTable
-- upstream's `use Image::ExifTool::PostScript;` -- loading HTML.pm loads
-- PostScript.pm, whose Composite tags (PostScript-ImageWidth/-ImageHeight)
-- thereby join the merged %Composite table and defer every Composite that
-- bare-Require's ImageWidth/ImageHeight (Exif-ImageSize and friends) by one
-- build pass. That deferral is visible in the output order, so the require
-- has to happen here, not just where PostScript data is actually read.
local PostScript = require('lexiftool.PostScript')

local HTML = {}

-- (upstream's predeclaration; the sub below assigns to it)
local SetHTMLCharset

-- convert HTML charset (lower case) to ExifTool Charset name
local htmlCharset = {
    macintosh     = 'MacRoman',
   ['iso-8859-1']   = 'Latin',
   ['utf-8']        = 'UTF8',
   ['windows-1252'] = 'Latin',
}

-- HTML 4 character entity references
local entityNum = {
    quot        = 34,
    eth         = 240,
    lsquo       = 8216,
    amp         = 38,
    ntilde      = 241,
    rsquo       = 8217,
    apos        = 39,
    ograve      = 242,
    sbquo       = 8218,
    lt          = 60,
    oacute      = 243,
    ldquo       = 8220,
    gt          = 62,
    ocirc       = 244,
    rdquo       = 8221,
    nbsp        = 160,
    otilde      = 245,
    bdquo       = 8222,
    iexcl       = 161,
    ouml        = 246,
    dagger      = 8224,
    cent        = 162,
    divide      = 247,
    Dagger      = 8225,
    pound       = 163,
    oslash      = 248,
    bull        = 8226,
    curren      = 164,
    ugrave      = 249,
    hellip      = 8230,
    yen         = 165,
    uacute      = 250,
    permil      = 8240,
    brvbar      = 166,
    ucirc       = 251,
    prime       = 8242,
    sect        = 167,
    uuml        = 252,
    Prime       = 8243,
    uml         = 168,
    yacute      = 253,
    lsaquo      = 8249,
    copy        = 169,
    thorn       = 254,
    rsaquo      = 8250,
    ordf        = 170,
    yuml        = 255,
    oline       = 8254,
    laquo       = 171,
    OElig       = 338,
    frasl       = 8260,
    ['not'] = 172,
    oelig       = 339,
    euro        = 8364,
    shy         = 173,
    Scaron      = 352,
    image       = 8465,
    reg         = 174,
    scaron      = 353,
    weierp      = 8472,
    macr        = 175,
    Yuml        = 376,
    real        = 8476,
    deg         = 176,
    fnof        = 402,
    trade       = 8482,
    plusmn      = 177,
    circ        = 710,
    alefsym     = 8501,
    sup2        = 178,
    tilde       = 732,
    larr        = 8592,
    sup3        = 179,
    Alpha       = 913,
    uarr        = 8593,
    acute       = 180,
    Beta        = 914,
    rarr        = 8594,
    micro       = 181,
    Gamma       = 915,
    darr        = 8595,
    para        = 182,
    Delta       = 916,
    harr        = 8596,
    middot      = 183,
    Epsilon     = 917,
    crarr       = 8629,
    cedil       = 184,
    Zeta        = 918,
    lArr        = 8656,
    sup1        = 185,
    Eta         = 919,
    uArr        = 8657,
    ordm        = 186,
    Theta       = 920,
    rArr        = 8658,
    raquo       = 187,
    Iota        = 921,
    dArr        = 8659,
    frac14      = 188,
    Kappa       = 922,
    hArr        = 8660,
    frac12      = 189,
    Lambda      = 923,
    forall      = 8704,
    frac34      = 190,
    Mu          = 924,
    part        = 8706,
    iquest      = 191,
    Nu          = 925,
    exist       = 8707,
    Agrave      = 192,
    Xi          = 926,
    empty       = 8709,
    Aacute      = 193,
    Omicron     = 927,
    nabla       = 8711,
    Acirc       = 194,
    Pi          = 928,
    isin        = 8712,
    Atilde      = 195,
    Rho         = 929,
    notin       = 8713,
    Auml        = 196,
    Sigma       = 931,
    ni          = 8715,
    Aring       = 197,
    Tau         = 932,
    prod        = 8719,
    AElig       = 198,
    Upsilon     = 933,
    sum         = 8721,
    Ccedil      = 199,
    Phi         = 934,
    minus       = 8722,
    Egrave      = 200,
    Chi         = 935,
    lowast      = 8727,
    Eacute      = 201,
    Psi         = 936,
    radic       = 8730,
    Ecirc       = 202,
    Omega       = 937,
    prop        = 8733,
    Euml        = 203,
    alpha       = 945,
    infin       = 8734,
    Igrave      = 204,
    beta        = 946,
    ang         = 8736,
    Iacute      = 205,
    gamma       = 947,
    ['and'] = 8743,
    Icirc       = 206,
    delta       = 948,
    ['or'] = 8744,
    Iuml        = 207,
    epsilon     = 949,
    cap         = 8745,
    ETH         = 208,
    zeta        = 950,
    cup         = 8746,
    Ntilde      = 209,
    eta         = 951,
    int         = 8747,
    Ograve      = 210,
    theta       = 952,
    there4      = 8756,
    Oacute      = 211,
    iota        = 953,
    sim         = 8764,
    Ocirc       = 212,
    kappa       = 954,
    cong        = 8773,
    Otilde      = 213,
    lambda      = 955,
    asymp       = 8776,
    Ouml        = 214,
    mu          = 956,
    ne          = 8800,
    times       = 215,
    nu          = 957,
    equiv       = 8801,
    Oslash      = 216,
    xi          = 958,
    le          = 8804,
    Ugrave      = 217,
    omicron     = 959,
    ge          = 8805,
    Uacute      = 218,
    pi          = 960,
    sub         = 8834,
    Ucirc       = 219,
    rho         = 961,
    sup         = 8835,
    Uuml        = 220,
    sigmaf      = 962,
    nsub        = 8836,
    Yacute      = 221,
    sigma       = 963,
    sube        = 8838,
    THORN       = 222,
    tau         = 964,
    supe        = 8839,
    szlig       = 223,
    upsilon     = 965,
    oplus       = 8853,
    agrave      = 224,
    phi         = 966,
    otimes      = 8855,
    aacute      = 225,
    chi         = 967,
    perp        = 8869,
    acirc       = 226,
    psi         = 968,
    sdot        = 8901,
    atilde      = 227,
    omega       = 969,
    lceil       = 8968,
    auml        = 228,
    thetasym    = 977,
    rceil       = 8969,
    aring       = 229,
    upsih       = 978,
    lfloor      = 8970,
    aelig       = 230,
    piv         = 982,
    rfloor      = 8971,
    ccedil      = 231,
    ensp        = 8194,
    lang        = 9001,
    egrave      = 232,
    emsp        = 8195,
    rang        = 9002,
    eacute      = 233,
    thinsp      = 8201,
    loz         = 9674,
    ecirc       = 234,
    zwnj        = 8204,
    spades      = 9824,
    euml        = 235,
    zwj         = 8205,
    clubs       = 9827,
    igrave      = 236,
    lrm         = 8206,
    hearts      = 9829,
    iacute      = 237,
    rlm         = 8207,
    diams       = 9830,
    icirc       = 238,
    ndash       = 8211,
    iuml        = 239,
    mdash       = 8212,
}
local entityName = {} -- look up entity names by number (built as necessary)

-- HTML info
-- (tag ID's are case insensitive and must be all lower case in tables)
HTML.Main = {
    GROUPS = { [2] = 'Document' },
    NOTES = [[
        Meta information extracted from the header of HTML and XHTML files.  This is
        a mix of information found in the C<META> elements, C<XML> element, and the
        C<TITLE> element.
    ]],
    dc = {
        Name = 'DC',
        SubDirectory = { TagTable = 'lexiftool.HTML.dc' },
    },
    ncc = {
        Name = 'NCC',
        SubDirectory = { TagTable = 'lexiftool.HTML.ncc' },
    },
    prod = {
        Name = 'Prod',
        SubDirectory = { TagTable = 'lexiftool.HTML.prod' },
    },
    vw96 = {
        Name = 'VW96',
        SubDirectory = { TagTable = 'lexiftool.HTML.vw96' },
    },
   ['http-equiv'] = {
        Name = 'HTTP-equiv',
        SubDirectory = { TagTable = 'lexiftool.HTML.equiv' },
    },
    o = {
        Name = 'Office',
        SubDirectory = { TagTable = 'lexiftool.HTML.Office' },
    },
    abstract        = { },
    author          = { },
    classification  = { },
   ['content-language']={ Name = 'ContentLanguage' },
    copyright       = { },
    description     = { },
    distribution    = { },
   ['doc-class']      = { Name = 'DocClass' },
   ['doc-rights']     = { Name = 'DocRights' },
   ['doc-type']       = { Name = 'DocType' },
    formatter       = { },
    generator       = { },
    generatorversion= { Name = 'GeneratorVersion' },
    googlebot       = { Name = 'GoogleBot' },
    keywords        = { List = 1 },
    mssmarttagspreventparsing = { Name = 'NoMSSmartTags' },
    originator      = { },
    owner           = { },
    progid          = { Name = 'ProgID' },
    rating          = { },
    refresh         = { },
   ['resource-type']  = { Name = 'ResourceType' },
   ['revisit-after']  = { Name = 'RevisitAfter' },
    robots          = { List = 1 },
    title           = { Notes = "the only extracted tag which isn't from an HTML META element" },
}

-- ref 2
HTML.dc = {
    GROUPS = { [1] = 'HTML-dc', [2] = 'Document' },
    NOTES = 'Dublin Core schema tags (also used in XMP).',
    contributor = { Groups = { [2] = 'Author' }, List = 'Bag' },
    coverage    = { },
    creator     = { Groups = { [2] = 'Author' }, List = 'Seq' },
    date        = {
        Groups = { [2] = 'Time'   },
        List = 'Seq',
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    description = { },
   ['format']     = { },
    identifier  = { },
    language    = { List = 'Bag' },
    publisher   = { Groups = { [2] = 'Author' }, List = 'Bag' },
    relation    = { List = 'Bag' },
    rights      = { Groups = { [2] = 'Author' } },
    source      = { Groups = { [2] = 'Author' } },
    subject     = { List = 'Bag' },
    title       = { },
    type        = { List = 'Bag' },
}

-- ref 2
HTML.ncc = {
    GROUPS = { [1] = 'HTML-ncc', [2] = 'Document' },
    charset         = { Name = 'CharacterSet' }, -- name changed to avoid conflict with -charset option
    depth           = { },
    files           = { },
    footnotes       = { },
    generator       = { },
    kbytesize       = { Name = 'KByteSize' },
    maxpagenormal   = { Name = 'MaxPageNormal' },
    multimediatype  = { Name = 'MultimediaType' },
    narrator        = { },
    pagefront       = { Name = 'PageFront' },
    pagenormal      = { Name = 'PageNormal' },
    pagespecial     = { Name = 'PageSpecial' },
    prodnotes       = { Name = 'ProdNotes' },
    producer        = { },
    produceddate    = { Name = 'ProducedDate', Groups = { [2] = 'Time' } }, -- YYYY-mm-dd
    revision        = { },
    revisiondate    = { Name = 'RevisionDate', Groups = { [2] = 'Time' } },
    setinfo         = { Name = 'SetInfo' },
    sidebars        = { },
    sourcedate      = { Name = 'SourceDate', Groups = { [2] = 'Time' } },
    sourceedition   = { Name = 'SourceEdition' },
    sourcepublisher = { Name = 'SourcePublisher' },
    sourcerights    = { Name = 'SourceRights' },
    sourcetitle     = { Name = 'SourceTitle' },
    tocitems        = { Name = 'TOCItems' },
    totaltime       = { Name = 'Duration' }, -- HH:MM:SS
}

-- ref 3
HTML.vw96 = {
    GROUPS = { [1] = 'HTML-vw96', [2] = 'Document' },
    objecttype      = { Name = 'ObjectType' },
}

-- ref 2
HTML.prod = {
    GROUPS = { [1] = 'HTML-prod', [2] = 'Document' },
    reclocation     = { Name = 'RecLocation' },
    recengineer     = { Name = 'RecEngineer' },
}

-- ref 3/4
HTML.equiv = {
    GROUPS = { [1] = 'HTTP-equiv', [2] = 'Document' },
    NOTES = 'These tags have a family 1 group name of "HTTP-equiv".',
   ['cache-control']       = { Name = 'CacheControl' },
   ['content-disposition'] = { Name = 'ContentDisposition' },
   ['content-language']    = { Name = 'ContentLanguage' },
   ['content-script-type'] = { Name = 'ContentScriptType' },
   ['content-style-type']  = { Name = 'ContentStyleType' },
    -- note: setting the HTMLCharset like this will miss any tags which come earlier
   ['content-type']        = { Name = 'ContentType', RawConv = function(et, val) return SetHTMLCharset(val, et) end },
   ['default-style']       = { Name = 'DefaultStyle' },
    expires              = { },
   ['ext-cache']           = { Name = 'ExtCache' },
    imagetoolbar         = { Name = 'ImageToolbar' },
    lotus                = { },
   ['page-enter']          = { Name = 'PageEnter' },
   ['page-exit']           = { Name = 'PageExit' },
   ['pics-label']          = { Name = 'PicsLabel' },
    pragma               = { },
    refresh              = { },
   ['reply-to']            = { Name = 'ReplyTo' },
   ['set-cookie']          = { Name = 'SetCookie' },
   ['site-enter']          = { Name = 'SiteEnter' },
   ['site-exit']           = { Name = 'SiteExit' },
    vary                 = { },
   ['window-target']       = { Name = 'WindowTarget' },
}

-- MS Office namespace (ref PH)
HTML.Office = {
    GROUPS = { [1] = 'HTML-office', [2] = 'Document' },
    NOTES = 'Tags written by Microsoft Office applications.',
    Subject     = { },
    Author      = { Groups = { [2] = 'Author' } },
    Keywords    = { },
    Description = { },
    Template    = { },
    LastAuthor  = { Groups = { [2] = 'Author' } },
    Revision    = { Name = 'RevisionNumber' },
    TotalTime   = { Name = 'TotalEditTime',   PrintConv = function(_self, val) return ExifTool.ConvertTimeSpan(val, 60) end },
    Created     = {
        Name = 'CreateDate',
        Groups = { [2] = 'Time' },
        ValueConv = function(_self, val) return require('lexiftool.XMP').ConvertXMPDate(val) end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    -- luacheck: push ignore 314
    LastSaved   = {
        Name = 'ModifyDate',
        Groups = { [2] = 'Time' },
        ValueConv = function(_self, val) return require('lexiftool.XMP').ConvertXMPDate(val) end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    LastSaved   = {
        Name = 'ModifyDate',
        Groups = { [2] = 'Time' },
        ValueConv = function(_self, val) return require('lexiftool.XMP').ConvertXMPDate(val) end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    -- luacheck: pop
    LastPrinted = {
        Name = 'LastPrinted',
        Groups = { [2] = 'Time' },
        ValueConv = function(_self, val) return require('lexiftool.XMP').ConvertXMPDate(val) end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    Pages       = { },
    Words       = { },
    Characters  = { },
    Category    = { },
    Manager     = { },
    Company     = { },
    Lines       = { },
    Paragraphs  = { },
    CharactersWithSpaces = { },
    -- luacheck: push ignore 314
    Version     = { Name = 'RevisionNumber' },
    -- luacheck: pop
}

--------------------------------------------------------------------------------
-- Set HTMLCharset member based on content type
-- Inputs: 0) content type string, 1) ExifTool ref
-- Returns: original string
function SetHTMLCharset(val, et)
    local isCS, cs = isMatch(val, [[charset=['"]?([-\w]+)]])
    if isCS then et.HTMLCharset = htmlCharset[lc(cs)] end
    return val
end
HTML.SetHTMLCharset = SetHTMLCharset

--------------------------------------------------------------------------------
-- Convert single UTF-8 character to HTML character reference
-- Inputs: 0) UTF-8 character sequence
-- Returns: HTML character reference (eg. "&quot;");
-- Note: Must be called via EscapeHTML to load name lookup
function HTML.EscapeChar(ch)
    local val
    -- (upstream: unpack('C0U', $ch) -- the first code point of the sequence)
    local ok, cp = pcall(utf8.codepoint, ch, 1, 1, true)
    if ok then val = cp end
    if val == nil then return '?' end
    if entityName[val] then return "&" .. entityName[val] .. ";" end
    return sprintf('&#x%x;', val)
end

--------------------------------------------------------------------------------
-- Escape any special characters for HTML
-- Inputs: 0) string to be escaped, 1) optional string encoding (default 'UTF8')
-- Returns: escaped string
function HTML.EscapeHTML(str, enc)
    -- escape XML characters
    str = require('lexiftool.XMP').EscapeXML(str)
    -- escape other special characters if they exist
    if isMatch(str, [=[[\x80-\xff]]=]) then
        -- generate entity name lookup if necessary
        if next(entityName) == nil then
            for k, v in pairs(entityNum) do
                entityName[v] = k
            end
            entityName[39] = nil  -- 'apos' is not valid HTML
        end
        if enc and enc ~= 'UTF8' then
            str = ExifTool.Decode(nil, str, enc, nil, 'UTF8')
            str = subst(str, [[(?s)([\xc2-\xf7][\x80-\xbf]+)]], HTML.EscapeChar, 'g')
            str = ExifTool.Decode(nil, str, 'UTF8', nil, enc)
        else
            -- escape any non-ascii characters for HTML
            str = subst(str, [[(?s)([\xc2-\xf7][\x80-\xbf]+)]], HTML.EscapeChar, 'g')
        end
    end
    return str
end

--------------------------------------------------------------------------------
-- Unescape all HTML character references
-- Inputs: 0) string to be unescaped, 1) optional string encoding (default 'UTF8')
-- Returns: unescaped string
function HTML.UnescapeHTML(str, enc)
    return require('lexiftool.XMP').UnescapeXML(str, entityNum, enc)
end

--------------------------------------------------------------------------------
-- Extract information from a HTML file
-- Inputs: 0) ExifTool object reference, 1) DirInfo reference
-- Returns: 1 on success, 0 if this wasn't a valid HTML file
function HTML.ProcessHTML(et, dirInfo)
    local raf = dirInfo.RAF
    local buff, n

    -- validate HTML or XHTML file
    n, buff = raf:Read(256)
    if not truthy(n) then return 0 end
    local isHTML, _, h2 = isMatch(buff, [[(?i)^(\xef\xbb\xbf)?\s*<(!DOCTYPE\s+HTML|HTML|\?xml)]])
    if not isHTML then return 0 end
    if h2 == '?xml' and not isMatch(buff, [[(?i)<(!DOCTYPE\s+)?HTML]]) then return 0 end
    et:SetFileType()

    if not raf:Seek(0, 0) then
        et:Warn('Seek error')
        return 1
    end

    local RS = PostScript.GetInputRecordSeparator(raf)    -- (local $/)
    if not truthy(RS) then
        et:Warn('Invalid HTML data')
        return 1
    end

    -- extract header information
    local doc
    while true do
        n, buff = raf:ReadLine(RS)
        if not truthy(n) then break end
        if doc == nil then
            -- look for 'head' element
            local m, e = matches(buff, [[(?i)<head\b]])
            if m then
                doc = substr(buff, e)
            end
        else
            doc = doc .. buff
            if isMatch(buff, '(?i)</head>') then break end
        end
    end
    if doc == nil then return 1 end

    -- process all elements in header
    local tagTablePtr = GetTagTable(nil, 'lexiftool.HTML.Main')
    local docPos = 0    -- (pos($doc))
    while true do
        local tagName, attrs, e = matches(doc, [[(?s)<([\w:.-]+)(.*?)>]], docPos)
        if not tagName then break end
        docPos = e
        local tag = lc(tagName)
        local val, grp
        if isMatch(attrs, '/$') then    -- self-contained XHTML tags end in '/>'
            val = ''
        else
            -- look for element close
            local pos = docPos
            local close = "</" .. tagName .. ">"
            -- the following doesn't work on Solaris Perl 5.6.1 due to Perl bug:
            -- if ($doc =~ m{(.*?)</$tagName>}sg) {
            --     $val = $1;
            local m, ce = matchesDyn(doc, '(?s)' .. close, docPos)
            if m then
                docPos = ce
                val = substr(doc, pos, docPos - pos - length(close))
            else
                docPos = pos
                if tag ~= 'meta' then goto next_ end  -- META tags don't need to be closed
                val = ''
            end
        end
        do
            local table_ = tagTablePtr
            if tag == 'meta' then
                -- parse HTML META element
                tag = nil -- luacheck: ignore 311
                -- tag name is in NAME or HTTP-EQUIV attribute
                local isName, nm = isMatch(attrs, [[(?si)\bname\s*=\s*['"]?([\w:.-]+)]])
                if isName then
                    tagName = nm
                else
                    local isEquiv, he = isMatch(attrs, [[(?si)\bhttp-equiv\s*=\s*['"]?([\w:.-]+)]])
                    if isEquiv then
                        tagName = "HTTP-equiv." .. he
                    else
                        goto next_  -- no name
                    end
                end
                tag = lc(tagName)
                if not truthy(tag) then goto next_ end
                -- tag value is in CONTENT attribute
                local isC, _, c2 = isMatch(attrs, [[(?si)\bcontent\s*=\s*(['"])(.*?)\1]])
                if not isC then
                    isC, _, c2 = isMatch(attrs, [[(?si)\bcontent\s*=\s*(['"]?)([\w:.-]+)]])
                end
                if isC then
                    val = c2
                else
                    if not truthy(length(val)) then goto next_ end
                end
                -- isolate group name (separator is '.' in HTML, but ':' in ref 2)
                local isGrp, g1, g2 = isMatch(tag, [[^([\w-]+)[:.]([\w-]+)]])
                if isGrp then
                    grp, tag = g1, g2
                    local tagInfo = et:GetTagInfo(tagTablePtr, grp)
                    if tagInfo and tagInfo.SubDirectory then
                        table_ = GetTagTable(nil, tagInfo.SubDirectory.TagTable)
                    else
                        tag = grp .. "." .. tag
                    end
                end
            elseif tag == 'xml' then
                et:VPrint(0, "Parsing XML\n")
                -- parse XML tags (quick-and-dirty)
                local xml = val
                local xmlPos = 0    -- (pos($xml))
                while true do
                    local x1, x2, _, x4, xe = matches(xml, [[<([\w-]+):([\w-]+)(\s.*?)?>([^<]*?)<\/\1:\2>]], xmlPos)
                    if x1 == nil then break end
                    xmlPos = xe
                    grp, tag, val = x1, x2, x4
                    local tagInfo = et:GetTagInfo(tagTablePtr, grp)
                    if not (tagInfo and tagInfo.SubDirectory) then goto nextXML end
                    table_ = GetTagTable(nil, tagInfo.SubDirectory.TagTable)
                    if not table_[tag] then
                        local name = ucfirst(tag)
                        name = subst(name, '(?i)_x([0-9a-f]{4})_', function(h) return chr(hex(h)) end, 'g') -- convert hex codes
                        name = subst(name, [[\s(.)]], function(c) return uc(c) end, 'g')     -- capitalize all words in tag name
                        name = tr(name, '-_a-zA-Z0-9', '', 'dc') -- remove illegal characters (also hex code wide chars)
                        AddTagToTable(nil, table_, tag, { Name = name })
                        et:VPrint(0, "  [adding " .. tag .. " '" .. name .. "']\n")
                    end
                    if truthy(et.HTMLCharset) then val = et:Decode(val, et.HTMLCharset) end
                    et:HandleTag(table_, tag, require('lexiftool.XMP').UnescapeXML(val))
                    ::nextXML::
                end
                goto next_
            else
                -- the only other element we process is TITLE
                if tag ~= 'title' then goto next_ end
            end
            if not table_[tag] then
                local name = tagName
                name = subst(name, [[(?s)\W+(\w)]], function(c) return ucfirst(c) end, 'g')
                local info = { Name = name, Groups = { [0] = 'HTML' } }
                if truthy(grp) then info.Groups[1] = (grp == 'http-equiv' and 'HTTP-equiv' or "HTML-" .. grp) end
                AddTagToTable(nil, table_, tag, info)
                et:VPrint(0, "  [adding " .. tag .. " '" .. tagName .. "']\n")
            end
            -- recode if necessary
            if truthy(et.HTMLCharset) then val = et:Decode(val, et.HTMLCharset) end
            val = substDyn(val, [[(?s)\s*]] .. RS .. [[\s*]], ' ', 'g')    -- replace linefeeds and indenting spaces
            val = HTML.UnescapeHTML(val)    -- unescape HTML character references
            et:HandleTag(table_, tag, val)
        end
        ::next_::
    end
    return 1
end

return HTML
