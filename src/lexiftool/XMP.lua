--------------------------------------------------------------------------------
-- File:         lexiftool/XMP.lua
-- Ported from:  lib/Image/ExifTool/XMP.pm
--
-- Description:  Read XMP meta information
--
-- Revisions:    11/25/2003 - P. Harvey Created
--               10/28/2004 - P. Harvey Major overhaul to conform with XMP spec
--               02/27/2005 - P. Harvey Also read UTF-16 and UTF-32 XMP
--               08/30/2005 - P. Harvey Split tag tables into separate namespaces
--               10/24/2005 - P. Harvey Added ability to parse .XMP files
--               08/25/2006 - P. Harvey Added ability to handle blank nodes
--               08/22/2007 - P. Harvey Added ability to handle alternate language tags
--               09/26/2008 - P. Harvey Added Iptc4xmpExt tags (version 1.0 rev 2)
--
-- References:   1) http://www.adobe.com/products/xmp/pdfs/xmpspec.pdf
--               2) http://www.w3.org/TR/rdf-syntax-grammar/  (20040210)
--               3) http://www.portfoliofaq.com/pfaq/v7mappings.htm
--               4) http://www.iptc.org/IPTC4XMP/
--               5) http://creativecommons.org/technology/xmp
--                  --> changed to http://wiki.creativecommons.org/Companion_File_metadata_specification (2007/12/21)
--               6) http://www.optimasc.com/products/fileid/xmp-extensions.pdf
--               7) Lou Salkind private communication
--               8) http://partners.adobe.com/public/developer/en/xmp/sdk/XMPspecification.pdf
--               9) http://www.w3.org/TR/SVG11/
--               10) http://www.adobe.com/devnet/xmp/pdfs/XMPSpecificationPart2.pdf (Oct 2008)
--               11) http://www.extensis.com/en/support/kb_article.jsp?articleNumber=6102211
--               12) http://www.cipa.jp/std/documents/e/DC-010-2012_E.pdf
--               13) http://www.cipa.jp/std/documents/e/DC-010-2017_E.pdf (changed to
--                   http://www.cipa.jp/std/documents/e/DC-X010-2017.pdf)
--
-- Notes:      - Property qualifiers are handled as if they were separate
--               properties (with no associated namespace).
--
--             - Currently, there is no special treatment of the following
--               properties which could potentially affect the extracted
--               information: xml:base, rdf:parseType (note that parseType
--               Literal isn't allowed by the XMP spec).
--
--             - The family 2 group names will be set to 'Unknown' for any XMP
--               tags not found in the XMP or Exif tag tables.
--
-- Port notes:   All tables and subs of XMP.pm: every namespace table of the
--               file (dc, xmp, xmpRights, xmpNote, xmpMM, xmpBJ, xmpTPg, pdf,
--               pdfx, photoshop, crs, tiff, exif, exifEX, aux, iptcCore,
--               Lightroom, Album, ExifTool, rdf, x, XML, the fallback `other`)
--               complete key for key, %XMP::Main and %XMP::Composite (GPS*Ref,
--               LensID, Flash), and the parser ProcessXMP / ParseXMPElement /
--               FoundXMP with FullUnescapeXML, FixUTF8, ScanForXMP,
--               PrintLensID and ConvertRationalList.  The order of the tables
--               and subs inside this file is not yet upstream's.
--
--               The three include files upstream compiles into this package
--               have files of their own, as upstream:
--                 - XMP2.lua (XMP2.pl): the additional namespace tables.  They
--                   are assigned to this module table and keep their names
--                   (lexiftool.XMP.iptcExt); ExifTool.GetTagTable loads
--                   XMP2.lua when a lexiftool.XMP table is not found here,
--                   as ExifTool.pm:8966 requires XMP2.pl.
--                 - XMPStruct.lua (XMPStruct.pl): structure support.  Its subs
--                   are bound at the AUTOLOAD position below to closures that
--                   load the file on first use (XMP.ConvertStruct,
--                   XMP.RestoreStruct, XMP.SerializeStruct, ...).
--                 - WriteXMP.lua (WriteXMP.pl): the writer.  Its subs are
--                   bound to loader closures at the predeclaration position
--                   near the top of this file (XMP.WriteXMP and XMP.CheckXMP
--                   are the WRITE_PROC/CHECK_PROC of %xmpTableDefaults).
--               The package variables they read (`use vars`: %latConv,
--               %longConv, %dateTimeInfo, %xmpTableDefaults, %specialStruct,
--               %stdXlatNS, %sDimensions, %sArea, %sColorant) are published
--               on the module table under their names.
--
--               The XmpValidate machinery is ported where upstream has it:
--               ProcessXMP sets up $$et{XmpValidate} (and warns about
--               non-standard/duplicate XMP and a missing xpacket wrapper,
--               or, in MWG strict mode, ignores non-standard XMP),
--               ParseXMPElement calls ValidateProperty and warns about a
--               wrong xmpmeta namespace and differing rdf:about attributes,
--               FoundXMP checks boolean capitalization, and ValidateProperty
--               itself is WriteXMP.pl's.  One Validate-gated piece is NOT
--               carried over:
--               XMP.pm:4216-4231's "Undefined XMP namespace"/"used out of
--               scope" warnings, which need the per-scope %usedNS/%definedNS
--               bookkeeping ParseXMPElement does not do here and could only
--               be guessed at.
--
--               %xmpTableDefaults is the `tableDefaults(t)` helper of
--               doc/conventions.md §2 (see MIE.lua), placed at upstream's
--               position.  Upstream declares the hash with `use vars` and the
--               XMP namespace tables outside XMP.pm (DJI.pm, Google.pm,
--               MWG.pm, PLUS.pm, XMP2.pl) spread it under its full package
--               name, so the helper is published as XMP.xmpTableDefaults and
--               those modules apply it as `XMP.xmpTableDefaults { ... }` --
--               module name and all, the same reading as the Perl line.
--               %dateTimeInfo is published as XMP.dateTimeInfo for the same
--               reason (Google.pm, Microsoft.pm and XMP2.pl spread it).
--
--               crs (and therefore crd, which XMP2.pl's INIT_TABLE fills from
--               it) carries Gradient/Paint/CircularGradient/MaskGroup/
--               DepthBasedCorrections, RetouchAreas, RangeMaskMapInfo, Look,
--               LensBlur and DepthMapInfo plus the %sCorrection/
--               %sRetouchArea/%sMapInfo/%sRangeMask structures; xmpTPg
--               MaxPageSize and SwatchGroups (%sSwatchGroup); xmp PageInfo
--               (%sPageInfo) and Format; photoshop CameraProfiles; exifEX
--               CompositeImageExposureTimes; tiff YCbCrSubSampling.
--               `pdfx`'s SourceModified ValueConv calls PDF's ConvertPDFDate
--               across modules, which is therefore published as
--               PDF.ConvertPDFDate.  The remaining %XMP::Main entries point
--               into other modules and the tables live there: Microsoft.lua
--               (microsoft/MP/MP1), Nikon.lua (sdc/ast/nine), Panasonic.lua
--               (xmpDSA) and Google.lua (GAudio/GImage/GPano/GSpherical/
--               GDepth/GFocus/GCreations/Device).
--
--               FixUTF8 returns the fixed string as second result (upstream
--               fixes it through the reference).  PrintLensID numbers
--               ambiguous Nikon IDs in sorted key order (upstream: Perl hash
--               order).  ScanForXMP is unreachable: the ScanForXMP branch of
--               ExifTool.pm's ExtractInfo is not ported.  UnescapeXML/
--               UnescapeChar take upstream's conversion hash and encoding
--               arguments.  DecodeBase64 returns the decoded string
--               (upstream: a reference to it); where upstream keeps the
--               reference, the caller makes it (`{ ref = 'SCALAR', value =
--               ... }`), as FoundXMP does for an rdf:datatype base64 value.
--------------------------------------------------------------------------------

-- Frequently used library functions as local aliases.
local sbyte = string.byte
local sfind = string.find
local ssub = string.sub
local tconcat = table.concat

local perl = require('lexiftool.perl')
local substr = perl.substr
local subst = perl.subst
local matches = perl.matches
local isMatch, isMatchDyn = perl.isMatch, perl.isMatchDyn
local truthy = perl.truthy
local sprintf = perl.sprintf
local tsort = perl.tsort
local perlStr = perl.str
local length = perl.length
local matchesDyn = perl.matchesDyn
local tr = perl.tr
local join, split, grep = perl.join, perl.split, perl.grep
local quotemeta = perl.quotemeta
local pack, unpack = perl.pack, perl.unpack
local tunpack = table.unpack
local Exif = require('lexiftool.Exif')
local GPS = require('lexiftool.GPS')
local JPEG = require('lexiftool.JPEG')
local lc, uc, ucfirst = perl.lc, perl.uc, perl.ucfirst
local XMP = {}

-- ExifTool XMP version (mirror of $Image::ExifTool::XMP::VERSION)
XMP.VERSION = '3.79'

-- (upstream's predeclarations `sub ProcessXMP($$;$);` ... `sub
--  WriteGSpherical($$$);`: the subs of WriteXMP.pl among them are AUTOLOADed
--  -- DoAutoLoad loads WriteXMP.pl on the first call.  Here every sub of
--  WriteXMP.pl is bound to a closure that loads WriteXMP.lua on first use;
--  XMP.WriteXMP and XMP.CheckXMP are the WRITE_PROC/CHECK_PROC that
--  %xmpTableDefaults spreads, and the subs this file calls by their bare
--  names get locals)
for _, name in ipairs({ 'XMPOpen', 'ValidateXMP', 'ValidateProperty', 'FormatXMPDate', 'CheckXMP',
                        'GetPropertyPath', 'SetPropertyPath', 'CaptureXMP', 'SaveBlankInfo',
                        'ProcessBlankInfo', 'ConformPathToNamespace', 'AddStructType',
                        'ProcessGSpherical', 'WriteGSpherical', 'EncodeBase64', 'ByTagName',
                        'TypeFirst', 'LimitXMPSize', 'CloseProperty', 'WriteXMP' }) do
    XMP[name] = function(...) return require('lexiftool.WriteXMP')[name](...) end
end
local CaptureXMP, ValidateProperty = XMP.CaptureXMP, XMP.ValidateProperty
local SaveBlankInfo, ProcessBlankInfo = XMP.SaveBlankInfo, XMP.ProcessBlankInfo

-- standard path locations for XMP in major file types
local stdPath = {
    JPEG = 'JPEG-APP1-XMP',
    TIFF = 'TIFF-IFD0-XMP',
    PSD = 'PSD-XMP',
}

-- Lookup for translating to ExifTool namespaces (and family 1 group names)
local stdXlatNS = {
    -- shorten ugly namespace prefixes
    Iptc4xmpCore = 'iptcCore',
    Iptc4xmpExt = 'iptcExt',
    photomechanic = 'photomech',
    MicrosoftPhoto = 'microsoft',
    prismusagerights = 'pur',
    GettyImagesGIFT = 'getty',
    hdr_metadata = 'hdr',
}
XMP.stdXlatNS = stdXlatNS -- (package variable, `use vars`: XMPStruct.pl reads it)

-- translate ExifTool XMP family 1 group names back to standard XMP namespace prefixes
local xmpNS = {
    iptcCore = 'Iptc4xmpCore',
    iptcExt = 'Iptc4xmpExt',
    photomech = 'photomechanic',
    microsoft = 'MicrosoftPhoto',
    getty = 'GettyImagesGIFT',
}

-- Lookup to translate standard XMP namespace prefixes into URI's.  This list
-- need not be complete, but it must contain an entry for each namespace prefix
-- (NAMESPACE) for writable tags in the XMP tables or in structures that doesn't
-- define a URI.  Also, the namespace must be defined here for non-standard
-- namespace prefixes to be recognized.
local nsURI = {
    aux       = 'http://ns.adobe.com/exif/1.0/aux/',
    album     = 'http://ns.adobe.com/album/1.0/',
    cc        = 'http://creativecommons.org/ns#', -- changed 2007/12/21 - PH
    crd       = 'http://ns.adobe.com/camera-raw-defaults/1.0/',
    crs       = 'http://ns.adobe.com/camera-raw-settings/1.0/',
    crss      = 'http://ns.adobe.com/camera-raw-saved-settings/1.0/',
    dc        = 'http://purl.org/dc/elements/1.1/',
    exif      = 'http://ns.adobe.com/exif/1.0/',
    exifEX    = 'http://cipa.jp/exif/1.0/',
    iX        = 'http://ns.adobe.com/iX/1.0/',
    pdf       = 'http://ns.adobe.com/pdf/1.3/',
    pdfx      = 'http://ns.adobe.com/pdfx/1.3/',
    photoshop = 'http://ns.adobe.com/photoshop/1.0/',
    rdf       = 'http://www.w3.org/1999/02/22-rdf-syntax-ns#',
    rdfs      = 'http://www.w3.org/2000/01/rdf-schema#',
    stDim     = 'http://ns.adobe.com/xap/1.0/sType/Dimensions#',
    stEvt     = 'http://ns.adobe.com/xap/1.0/sType/ResourceEvent#',
    stFnt     = 'http://ns.adobe.com/xap/1.0/sType/Font#',
    stJob     = 'http://ns.adobe.com/xap/1.0/sType/Job#',
    stRef     = 'http://ns.adobe.com/xap/1.0/sType/ResourceRef#',
    stVer     = 'http://ns.adobe.com/xap/1.0/sType/Version#',
    stMfs     = 'http://ns.adobe.com/xap/1.0/sType/ManifestItem#',
    stCamera  = 'http://ns.adobe.com/photoshop/1.0/camera-profile',
    crlcp     = 'http://ns.adobe.com/camera-raw-embedded-lens-profile/1.0/',
    tiff      = 'http://ns.adobe.com/tiff/1.0/',
    ['x']       = 'adobe:ns:meta/',
    xmpG      = 'http://ns.adobe.com/xap/1.0/g/',
    xmpGImg   = 'http://ns.adobe.com/xap/1.0/g/img/',
    xmp       = 'http://ns.adobe.com/xap/1.0/',
    xmpBJ     = 'http://ns.adobe.com/xap/1.0/bj/',
    xmpDM     = 'http://ns.adobe.com/xmp/1.0/DynamicMedia/',
    xmpMM     = 'http://ns.adobe.com/xap/1.0/mm/',
    xmpRights = 'http://ns.adobe.com/xap/1.0/rights/',
    xmpNote   = 'http://ns.adobe.com/xmp/note/',
    xmpTPg    = 'http://ns.adobe.com/xap/1.0/t/pg/',
    xmpidq    = 'http://ns.adobe.com/xmp/Identifier/qual/1.0/',
    xmpPLUS   = 'http://ns.adobe.com/xap/1.0/PLUS/',
    panorama  = 'http://ns.adobe.com/photoshop/1.0/panorama-profile',
    dex       = 'http://ns.optimasc.com/dex/1.0/',
    mediapro  = 'http://ns.iview-multimedia.com/mediapro/1.0/',
    expressionmedia = 'http://ns.microsoft.com/expressionmedia/1.0/',
    Iptc4xmpCore = 'http://iptc.org/std/Iptc4xmpCore/1.0/xmlns/',
    Iptc4xmpExt = 'http://iptc.org/std/Iptc4xmpExt/2008-02-29/',
    MicrosoftPhoto = 'http://ns.microsoft.com/photo/1.0',
    MP1       = 'http://ns.microsoft.com/photo/1.1', --PH (MP1 is fabricated)
    MP        = 'http://ns.microsoft.com/photo/1.2/',
    MPRI      = 'http://ns.microsoft.com/photo/1.2/t/RegionInfo#',
    MPReg     = 'http://ns.microsoft.com/photo/1.2/t/Region#',
    lr        = 'http://ns.adobe.com/lightroom/1.0/',
    DICOM     = 'http://ns.adobe.com/DICOM/',
['drone-dji']    = 'http://www.dji.com/drone-dji/1.0/',
    svg       = 'http://www.w3.org/2000/svg',
    et        = 'http://ns.exiftool.org/1.0/',
    plus      = 'http://ns.useplus.org/ldf/xmp/1.0/',
    prism     = 'http://prismstandard.org/namespaces/basic/2.0/',
    prl       = 'http://prismstandard.org/namespaces/prl/2.1/',
    pur       = 'http://prismstandard.org/namespaces/prismusagerights/2.1/',
    pmi       = 'http://prismstandard.org/namespaces/pmi/2.2/',
    prm       = 'http://prismstandard.org/namespaces/prm/3.0/',
    acdsee    = 'http://ns.acdsee.com/iptc/1.0/',
['acdsee-rs']    = 'http://ns.acdsee.com/regions/',
    digiKam   = 'http://www.digikam.org/ns/1.0/',
    swf       = 'http://ns.adobe.com/swf/1.0/',
    cell      = 'http://developer.sonyericsson.com/cell/1.0/',
    aas       = 'http://ns.apple.com/adjustment-settings/1.0/',
['mwg-rs']   = 'http://www.metadataworkinggroup.com/schemas/regions/',
['mwg-kw']   = 'http://www.metadataworkinggroup.com/schemas/keywords/',
['mwg-coll']   = 'http://www.metadataworkinggroup.com/schemas/collections/',
    stArea    = 'http://ns.adobe.com/xmp/sType/Area#',
    extensis  = 'http://ns.extensis.com/extensis/1.0/',
    ics       = 'http://ns.idimager.com/ics/1.0/',
    fpv       = 'http://ns.fastpictureviewer.com/fpv/1.0/',
    creatorAtom= 'http://ns.adobe.com/creatorAtom/1.0/',
['apple-fi']      = 'http://ns.apple.com/faceinfo/1.0/',
    GAudio    = 'http://ns.google.com/photos/1.0/audio/',
    GImage    = 'http://ns.google.com/photos/1.0/image/',
    GPano     = 'http://ns.google.com/photos/1.0/panorama/',
    GSpherical= 'http://ns.google.com/videos/1.0/spherical/',
    GDepth    = 'http://ns.google.com/photos/1.0/depthmap/',
    GFocus    = 'http://ns.google.com/photos/1.0/focus/',
    GCamera   = 'http://ns.google.com/photos/1.0/camera/',
    GCreations= 'http://ns.google.com/photos/1.0/creations/',
    dwc       = 'http://rs.tdwg.org/dwc/index.htm',
    GettyImagesGIFT = 'http://xmp.gettyimages.com/gift/1.0/',
    LImage    = 'http://ns.leiainc.com/photos/1.0/image/',
    Profile   = 'http://ns.google.com/photos/dd/1.0/profile/',
    sdc       = 'http://ns.nikon.com/sdc/1.0/',
    ast       = 'http://ns.nikon.com/asteroid/1.0/',
    nine      = 'http://ns.nikon.com/nine/1.0/',
    hdr_metadata = 'http://ns.adobe.com/hdr-metadata/1.0/',
    hdrgm     = 'http://ns.adobe.com/hdr-gain-map/1.0/',
    xmpDSA    = 'http://leica-camera.com/digital-shift-assistant/1.0/',
    seal      = 'http://ns.seal/2024/1.0/',
    GContainer= 'http://ns.google.com/photos/1.0/container/',
    HDRGainMap= 'http://ns.apple.com/HDRGainMap/1.0/',
    apdi      = 'http://ns.apple.com/pixeldatainfo/1.0/',
}
XMP.nsURI = nsURI -- exposed for the write path (WriteXMP) below

-- build reverse namespace lookup
local uri2ns = { ['http://ns.exiftool.ca/1.0/'] = 'et' } -- (allow exiftool.ca as well as exiftool.org)
do
    for ns, uri in pairs(nsURI) do
        uri2ns[uri] = ns
    end
end
XMP.uri2ns = uri2ns -- (exposed so a caller can undo a RegisterNamespace)

-- XMP namespaces which we don't want to contribute to generated EXIF tag names
local ignoreNamespace = { ['x'] = 1, rdf = 1, xmlns = 1, xml = 1, svg = 1, office = 1 }

-- ExifTool properties that don't generate tag names (et:tagid is historic)
local ignoreEtProp = {
    ['et:desc'] = 1, ['et:prt'] = 1, ['et:val'] = 1, ['et:id'] = 1, ['et:tagid'] = 1,
    ['et:toolkit'] = 1, ['et:table'] = 1, ['et:index'] = 1,
}

-- XMP properties to ignore (set dynamically via dirInfo IgnoreProp)
local ignoreProp = {}

-- these are the attributes that we handle for properties that contain
-- sub-properties.  Attributes for simple properties are easy, and we
-- just copy them over.  These are harder since we don't store attributes
-- for properties without simple values.  (maybe this will change...)
-- (special attributes are indicated by a list reference of tag information)
local recognizedAttrs = {
    ['rdf:about'] = { 'lexiftool.XMP.rdf', 'about', 'About' },
    ['x:xmptk']   = { 'lexiftool.XMP.x',   'xmptk', 'XMPToolkit' },
    ['x:xaptk']   = { 'lexiftool.XMP.x',   'xmptk', 'XMPToolkit' },
    ['rdf:parseType'] = 1,
    ['rdf:nodeID'] = 1,
    ['et:toolkit'] = 1,
    ['rdf:xmlns']  = 1,
    ['lastUpdate'] = { 'lexiftool.XMP.XML', 'lastUpdate', 'LastUpdate' },
}

-- special tags in structures below
local specialStruct = {
    STRUCT_NAME = 1, -- [optional] name of structure
    NAMESPACE   = 1, -- [mandatory for XMP] namespace prefix used for fields of this structure
    NOTES       = 1, -- [optional] notes for documentation about this structure
    TYPE        = 1, -- [optional] rdf:type resource for struct
    GROUPS      = 1, -- [optional] specifies family group 2 name for the structure
    SORT_ORDER  = 1, -- [optional] order for sorting fields in documentation
}
XMP.specialStruct = specialStruct -- (package variable, `use vars`: XMPStruct.pl reads it)

-- conversions for GPS coordinates
-- (the port's GPS.ToDegrees/GPS.ToDMS are reached through a lazy require to
--  avoid a load-order cycle: GPS.lua itself requires the core module)
local latConv = {
    ValueConv    = function(_self, val) return GPS.ToDegrees(val, 1) end,
    ValueConvInv = function(self, val) return GPS.ToDMS(self, val, 2, 'N') end,
    PrintConv    = function(self, val) return GPS.ToDMS(self, val, 1, 'N') end,
    PrintConvInv = function(_self, val) return GPS.ToDegrees(val, 1, 'lat') end,
}
local longConv = {
    ValueConv    = function(_self, val) return GPS.ToDegrees(val, 1) end,
    ValueConvInv = function(self, val) return GPS.ToDMS(self, val, 2, 'E') end,
    PrintConv    = function(self, val) return GPS.ToDMS(self, val, 1, 'E') end,
    PrintConvInv = function(_self, val) return GPS.ToDegrees(val, 1, 'lon') end,
}
-- (%latConv and %longConv are package variables (`use vars`) that XMP2.pl
--  reads as well, so they are published like %dateTimeInfo below)
XMP.latConv = latConv
XMP.longConv = longConv
local dateTimeInfo = {
    -- NOTE: Do NOT put "Groups" here because Groups hash must not be common!
    Writable = 'date',
    Shift = 'Time',
    Validate = function(_self, val) return require('lexiftool.Validate').ValidateXMPDate(val) end,
    PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    PrintConvInv = function(self, val) return self:InverseDateTime(val, nil, 1) end,
}
-- (upstream declares %dateTimeInfo with `use vars` and the XMP namespace
--  tables outside XMP.pm spread it under its full package name,
--  %Image::ExifTool::XMP::dateTimeInfo -- so it is published here the same way
--  %xmpTableDefaults is, and those modules read it as XMP.dateTimeInfo)
XMP.dateTimeInfo = dateTimeInfo

-- this conversion allows alternate language support for designated boolean tags
local boolConv = {
    PrintConv = {
        OTHER = function(val) -- (inverse conversion is the same)
            if lc(val) == 'false' then return 'False' end
            if lc(val) == 'true' then return 'True' end
            return val
        end,
        True = 'True',
        False = 'False',
    },
}

-- XMP structures (each structure is similar to a tag table so we can recurse
-- through them in SetPropertyPath() as if they were tag tables)
local sResourceRef = {
    STRUCT_NAME = 'ResourceRef',
    NAMESPACE   = 'stRef',
    documentID      = { },
    instanceID      = { },
    manager         = { },
    managerVariant  = { },
    manageTo        = { },
    manageUI        = { },
    renditionClass  = { },
    renditionParams = { },
    versionID       = { },
    alternatePaths  = { List = 'Seq' },
    filePath        = { },
    fromPart        = { },
    lastModifyDate  = { Writable = 'date', Shift = 'Time', Validate = dateTimeInfo.Validate,
                        PrintConv = dateTimeInfo.PrintConv, PrintConvInv = dateTimeInfo.PrintConvInv, Groups = { [2] = 'Time' } },
    maskMarkers     = { PrintConv = { All = 'All', None = 'None' } },
    partMapping     = { },
    toPart          = { },
    originalDocumentID = { },
    lastURL         = { },
    linkForm        = { },
    linkCategory    = { },
    placedXResolution    = { },
    placedYResolution    = { },
    placedResolutionUnit = { },
}

local sResourceEvent = {
    STRUCT_NAME = 'ResourceEvent',
    NAMESPACE   = 'stEvt',
    action          = { },
    instanceID      = { },
    parameters      = { },
    softwareAgent   = { },
    when            = { Writable = 'date', Shift = 'Time', Validate = dateTimeInfo.Validate,
                        PrintConv = dateTimeInfo.PrintConv, PrintConvInv = dateTimeInfo.PrintConvInv, Groups = { [2] = 'Time' } },
    changed         = { },
}

local sJobRef = {
    STRUCT_NAME = 'JobRef',
    NAMESPACE   = 'stJob',
    id          = { },
    name        = { },
    url         = { },
}

local sVersion = {
    STRUCT_NAME = 'Version',
    NAMESPACE   = 'stVer',
    comments    = { },
    event       = { Struct = sResourceEvent },
    modifier    = { },
    modifyDate  = { Writable = 'date', Shift = 'Time', Validate = dateTimeInfo.Validate,
                        PrintConv = dateTimeInfo.PrintConv, PrintConvInv = dateTimeInfo.PrintConvInv, Groups = { [2] = 'Time' } },
    version     = { },
}

local sManifestItem = {
    STRUCT_NAME = 'ManifestItem',
    NAMESPACE   = 'stMfs',
    linkForm            = { },
    placedXResolution   = { Namespace = 'xmpMM', Writable = 'real' },
    placedYResolution   = { Namespace = 'xmpMM', Writable = 'real' },
    placedResolutionUnit= { Namespace = 'xmpMM' },
    reference           = { Struct = sResourceRef },
}

local sPantryItem = {
    STRUCT_NAME = 'PantryItem',
    NAMESPACE   = nil, -- stores any top-level XMP tags
    InstanceID  = { Namespace = 'xmpMM', List = 0 },
}

-- (upstream %sThumbnail; used by xmp Thumbnails, with FlatName 'Thumbnail')
local sThumbnail = {
    STRUCT_NAME = 'Thumbnail',
    NAMESPACE   = 'xmpGImg',
    height      = { Writable = 'integer' },
    width       = { Writable = 'integer' },
    ['format']  = { },
    image       = {
        Avoid = 1,
        Groups = { [2] = 'Preview' },
        ValueConv = function(_self, val) return XMP.DecodeBase64(val) end,
        ValueConvInv = function(_self, val) return XMP.EncodeBase64(val) end,
    },
}
local sPageInfo = {
    STRUCT_NAME = 'PageInfo',
    NAMESPACE   = 'xmpGImg',
    PageNumber  = { Writable = 'integer', Namespace = 'xmpTPg' }, -- override default namespace
    height      = { Writable = 'integer' },
    width       = { Writable = 'integer' },
    ['format']  = { },
    image       = {
        Groups = { [2] = 'Preview' },
        ValueConv = function(_self, val) return XMP.DecodeBase64(val) end,
        ValueConvInv = function(_self, val) return XMP.EncodeBase64(val) end,
    },
}

-- dimensions structure (upstream %sDimensions; referenced by MWG Regions)
XMP.sDimensions = {
    STRUCT_NAME = 'Dimensions',
    NAMESPACE   = 'stDim',
    w           = { Writable = 'real' },
    h           = { Writable = 'real' },
    unit        = { },
}

-- area structure (upstream %sArea; referenced by MWG Regions)
XMP.sArea = {
    STRUCT_NAME = 'Area',
    NAMESPACE   = 'stArea',
   ['x']        = { Writable = 'real' },
   ['y']        = { Writable = 'real' },
    w           = { Writable = 'real' },
    h           = { Writable = 'real' },
    d           = { Writable = 'real' },
    unit        = { },
}

local sColorant = {
    STRUCT_NAME = 'Colorant',
    NAMESPACE   = 'xmpG',
    swatchName  = { },
    mode        = { PrintConv = { CMYK = 'CMYK', RGB = 'RGB', LAB = 'Lab' } },
    -- note: do not implement closed choice for "type" because Adobe can't
    -- get the case right:  spec. says "PROCESS" but Indesign writes "Process"
    type        = { },
    cyan        = { Writable = 'real' },
    magenta     = { Writable = 'real' },
    yellow      = { Writable = 'real' },
    black       = { Writable = 'real' },
    red         = { Writable = 'integer' },
    green       = { Writable = 'integer' },
    blue        = { Writable = 'integer' },
    gray        = { Writable = 'integer' },
    L           = { Writable = 'real' },
    A           = { Writable = 'integer' },
    B           = { Writable = 'integer' },
    ['tint']    = { Writable = 'integer', Notes = 'not part of 2010 XMP specification' }, -- observed in INDD sample - PH
}
XMP.sColorant = sColorant -- (package variable, `use vars`: XMP2.pl's xmpDM uses it)
local sSwatchGroup = {
    STRUCT_NAME = 'SwatchGroup',
    NAMESPACE   = 'xmpG',
    groupName   = { },
    groupType   = { Writable = 'integer' },
    Colorants = {
        FlatName = 'SwatchColorant',
        Struct = sColorant,
        List = 'Seq',
    },
}

local sFont = {
    STRUCT_NAME = 'Font',
    NAMESPACE   = 'stFnt',
    fontName    = { },
    fontFamily  = { },
    fontFace    = { },
    fontType    = { },
    versionString = { },
    composite   = { Writable = 'boolean' },
    fontFileName= { },
    childFontFiles = { List = 'Seq' },
}

local sOECF = {
    STRUCT_NAME = 'OECF',
    NAMESPACE   = 'exif',
    Columns     = { Writable = 'integer' },
    Rows        = { Writable = 'integer' },
    Names       = { List = 'Seq' },
    Values      = { List = 'Seq', Writable = 'rational' },
}

local sAreaModels = {
    STRUCT_NAME = 'AreaModels',
    NAMESPACE   = 'crs',
    ColorRangeMaskAreaSampleInfo = { FlatName = 'ColorSampleInfo' },
    AreaComponents = { FlatName = 'Components', List = 'Seq' },
}

local sCorrRangeMask = {
    STRUCT_NAME = 'CorrRangeMask',
    NAMESPACE   = 'crs',
    NOTES = 'Called CorrectionRangeMask by the spec.',
    Version     = { },
    Type        = { },
    ColorAmount = { Writable = 'real' },
    LumMin      = { Writable = 'real' },
    LumMax      = { Writable = 'real' },
    LumFeather  = { Writable = 'real' },
    DepthMin    = { Writable = 'real' },
    DepthMax    = { Writable = 'real' },
    DepthFeather= { Writable = 'real' },
    -- new in LR 11.0
    Invert      = { Writable = 'boolean' },
    SampleType  = { Writable = 'integer' },
    AreaModels  = {
        List = 'Seq',
        Struct = sAreaModels,
    },
    LumRange    = { },
    LuminanceDepthSampleInfo = { },
}

-- new LR2 crs structures (PH)
local sCorrectionMask -- (must define this before assigning because it is self-referential)
sCorrectionMask = {
    STRUCT_NAME = 'CorrectionMask',
    NAMESPACE   = 'crs',
    -- disable List behaviour of flattened Gradient/PaintBasedCorrections
    -- because these are nested in lists and the flattened tags can't
    -- do justice to this complex structure
    What         = { List = 0 },
    MaskValue    = { Writable = 'real', List = 0, FlatName = 'Value' },
    Radius       = { Writable = 'real', List = 0 },
    Flow         = { Writable = 'real', List = 0 },
    CenterWeight = { Writable = 'real', List = 0 },
    Dabs         = { List = 'Seq' },
    ZeroX        = { Writable = 'real', List = 0 },
    ZeroY        = { Writable = 'real', List = 0 },
    FullX        = { Writable = 'real', List = 0 },
    FullY        = { Writable = 'real', List = 0 },
    -- new elements used in CircularGradientBasedCorrections CorrectionMasks
    -- and RetouchAreas Masks
    Top          = { Writable = 'real', List = 0 },
    Left         = { Writable = 'real', List = 0 },
    Bottom       = { Writable = 'real', List = 0 },
    Right        = { Writable = 'real', List = 0 },
    Angle        = { Writable = 'real', List = 0 },
    Midpoint     = { Writable = 'real', List = 0 },
    Roundness    = { Writable = 'real', List = 0 },
    Feather      = { Writable = 'real', List = 0 },
    Flipped      = { Writable = 'boolean', List = 0 },
    Version      = { Writable = 'integer', List = 0 },
    SizeX        = { Writable = 'real', List = 0 },
    SizeY        = { Writable = 'real', List = 0 },
    X            = { Writable = 'real', List = 0 },
    Y            = { Writable = 'real', List = 0 },
    Alpha        = { Writable = 'real', List = 0 },
    CenterValue  = { Writable = 'real', List = 0 },
    PerimeterValue= { Writable = 'real', List = 0 },
    -- new in LR 11.0 MaskGroupBasedCorrections
    MaskActive   = { Writable = 'boolean', List = 0 },
    MaskName     = { List = 0 },
    MaskBlendMode= { Writable = 'integer', List = 0 },
    MaskInverted = { Writable = 'boolean', List = 0 },
    MaskSyncID   = { List = 0 },
    MaskVersion  = { List = 0 },
    MaskSubType  = { List = 0 },
    ReferencePoint = { List = 0  },
    InputDigest  = { List = 0 },
    MaskDigest   = { List = 0 },
    WholeImageArea = { List = 0 },
    Origin       = { List = 0 },
    Masks        = { Struct = false, NoSubStruct = 1 }, -- (self-reference, assigned below)
    CorrectionRangeMask = {
        Name = 'CorrRangeMask',
        Notes = 'called CorrectionRangeMask by the spec',
        FlatName = 'Range',
        Struct = sCorrRangeMask,
    },
}
sCorrectionMask.Masks.Struct = sCorrectionMask
local sCorrection = {
    STRUCT_NAME = 'Correction',
    NAMESPACE   = 'crs',
    What = { List = 0 },
    CorrectionAmount = { FlatName = 'Amount',     Writable = 'real', List = 0 },
    CorrectionActive = { FlatName = 'Active',     Writable = 'boolean', List = 0 },
    LocalExposure    = { FlatName = 'Exposure',   Writable = 'real', List = 0 },
    LocalSaturation  = { FlatName = 'Saturation', Writable = 'real', List = 0 },
    LocalContrast    = { FlatName = 'Contrast',   Writable = 'real', List = 0 },
    LocalClarity     = { FlatName = 'Clarity',    Writable = 'real', List = 0 },
    LocalSharpness   = { FlatName = 'Sharpness',  Writable = 'real', List = 0 },
    LocalBrightness  = { FlatName = 'Brightness', Writable = 'real', List = 0 },
    LocalToningHue   = { FlatName = 'ToningHue',  Writable = 'real', List = 0 },
    LocalToningSaturation = { FlatName = 'ToningSaturation',  Writable = 'real', List = 0 },
    LocalExposure2012     = { FlatName = 'Exposure2012',      Writable = 'real', List = 0 },
    LocalContrast2012     = { FlatName = 'Contrast2012',      Writable = 'real', List = 0 },
    LocalHighlights2012   = { FlatName = 'Highlights2012',    Writable = 'real', List = 0 },
    LocalShadows2012      = { FlatName = 'Shadows2012',       Writable = 'real', List = 0 },
    LocalClarity2012      = { FlatName = 'Clarity2012',       Writable = 'real', List = 0 },
    LocalLuminanceNoise   = { FlatName = 'LuminanceNoise',    Writable = 'real', List = 0 },
    LocalMoire       = { FlatName = 'Moire',      Writable = 'real', List = 0 },
    LocalDefringe    = { FlatName = 'Defringe',   Writable = 'real', List = 0 },
    LocalTemperature = { FlatName = 'Temperature',Writable = 'real', List = 0 },
    LocalTint        = { FlatName = 'Tint',       Writable = 'real', List = 0 },
    LocalHue         = { FlatName = 'Hue',        Writable = 'real', List = 0 },
    LocalWhites2012  = { FlatName = 'Whites2012', Writable = 'real', List = 0 },
    LocalBlacks2012  = { FlatName = 'Blacks2012', Writable = 'real', List = 0 },
    LocalDehaze      = { FlatName = 'Dehaze', Writable = 'real', List = 0 },
    LocalTexture     = { FlatName = 'Texture', Writable = 'real', List = 0 },
    -- new in LR 11.0
    CorrectionRangeMask = {
        Name = 'CorrRangeMask',
        Notes = 'called CorrectionRangeMask by the spec',
        FlatName = 'RangeMask',
        Struct = sCorrRangeMask,
    },
    CorrectionMasks  = {
        FlatName = 'Mask',
        Struct = sCorrectionMask,
        List = 'Seq',
    },
    CorrectionName = { },
    CorrectionSyncID = { },
}
local sRetouchArea = {
    STRUCT_NAME = 'RetouchArea',
    NAMESPACE   = 'crs',
    SpotType        = { List = 0 },
    SourceState     = { List = 0 },
    Method          = { List = 0 },
    SourceX         = { Writable = 'real',    List = 0 },
    OffsetY         = { Writable = 'real',    List = 0 },
    Opacity         = { Writable = 'real',    List = 0 },
    Feather         = { Writable = 'real',    List = 0 },
    Seed            = { Writable = 'integer', List = 0 },
    Masks = {
        FlatName = 'Mask',
        Struct = sCorrectionMask,
        List = 'Seq',
    },
}
local sMapInfo = {
    STRUCT_NAME = 'MapInfo',
    NAMESPACE   = 'crs',
    NOTES = [[
        Called RangeMaskMapInfo by the specification, the same as the containing
        structure.
    ]],
    RGBMin = { },
    RGBMax = { },
    LabMin = { },
    LabMax = { },
    LumEq  = { List = 'Seq' },
}
local sRangeMask = {
    STRUCT_NAME = 'RangeMask',
    NAMESPACE   = 'crs',
    NOTES = [[
        This structure is actually called RangeMaskMapInfo, but it only contains one
        element which is a RangeMaskMapInfo structure (Yes, really!).  So these are
        renamed to RangeMask and MapInfo respectively to avoid confusion and
        redundancy in the tag names.
    ]],
    RangeMaskMapInfo = { FlatName = 'MapInfo', Struct = sMapInfo },
}

--------------------------------------------------------------------------------
-- Escape / unescape helpers
--------------------------------------------------------------------------------

-- Escape necessary XML characters in UTF-8 string
-- Inputs: 0) string to be escaped
-- Returns: escaped string
-- (the apostrophe maps to '#39', not 'apos', which isn't valid HTML)
local charName = { ['"'] = 'quot', ['&'] = 'amp', ["'"] = '#39', ['<'] = 'lt', ['>'] = 'gt' }
function XMP.EscapeXML(str)
    if type(str) ~= 'string' then str = perlStr(str) end -- (Perl stringifies a number)
    -- escape necessary XML characters
    return (str:gsub('[&><\'"]', function(c) return '&' .. charName[c] .. ';' end))
end

local charNum = { quot = 34, amp = 38, apos = 39, lt = 60, gt = 62 }

-- Convert XML character reference to UTF-8
-- Inputs: 0) XML character reference stripped of the '&' and ';' (eg. 'quot', '#34', '#x22')
--         1) hash reference for looking up character numbers by name
--         2) optional character encoding (default 'UTF8')
-- Returns: UTF-8 equivalent (or original character on conversion error)
function XMP.UnescapeChar(ch, conv, enc)
    local val = conv[ch]
    if val == nil then
        local isHex, h = isMatch(ch, '^#x([0-9a-fA-F]+)$')
        if isHex then
            val = perl.hex(h)
        else
            local isDec, d = isMatch(ch, [[^#(\d+)$]])
            if isDec then
                val = perl.num(d)
            else
                return '&' .. ch .. ';' -- should issue a warning here? [no]
            end
        end
    end
    if val < 0x80 then return perl.chr(val) end -- simple ASCII
    val = perl.pack('C0U', val)
    if enc and enc ~= 'UTF8' then val = require('lexiftool').Decode(nil, val, 'UTF8', nil, enc) end
    return val
end

-- Unescape XML character references (entities and numerical)
-- Inputs: 0) string to be unescaped
--         1) optional hash reference to convert entity names to numbers
--         2) optional character encoding (default 'UTF8')
-- Returns: unescaped string
function XMP.UnescapeXML(str, conv, enc)
    if not conv then conv = charNum end
    str = subst(str, [[(?s)&(#?\w+);]], function(ch) return XMP.UnescapeChar(ch, conv, enc) end, 'g')
    return str
end

-- Escape string for XML, ensuring valid XML and UTF-8
-- Inputs: 0) string
-- Returns: escaped string
function XMP.FullEscapeXML(str)
    str = XMP.EscapeXML(str)                    -- escape necessary XML characters
    str = str:gsub('\\', '&#92;')               -- escape backslashes too
    -- then use C-escape sequences for invalid characters
    if sfind(str, '[%z\1-\31]') or require('lexiftool').IsUTF8(str) < 0 then
        str = str:gsub('[%z\1-\31\127-\255]', function(c) return sprintf('\\x%.2x', sbyte(c)) end)
    end
    return str
end

-- Unescape XML/C escaped string
-- Inputs: 0) string
-- Returns: unescaped string
function XMP.FullUnescapeXML(str)
    -- unescape C escape sequences first
    str = subst(str, [[(?s)\\x([\da-f]{2})]], function(h) return perl.chr(perl.hex(h)) end, 'g')
    local conv = charNum
    str = subst(str, [[(?s)&(#?\w+);]], function(ch) return XMP.UnescapeChar(ch, conv) end, 'g')
    return str
end

-- Fix malformed UTF8 (by replacing bad bytes with specified character)
-- Inputs: 0) string reference, 1) string to replace each bad byte,
--         may be '' to delete bad bytes, or undef to use '?'
-- Returns: true if string was fixed, and updates string
-- (Lua: a string is a value, so the fixed string is the second result)
function XMP.FixUTF8(str, bad)
    local fixed
    local pos = 0 -- start at beginning of string
    while true do
        local c1, e = matches(str, [=[([\x80-\xff])]=], pos)
        if e == nil then break end
        pos = e
        local ch = perl.ord(c1)
        -- (see comments in Image::ExifTool::IsUTF8())
        if ch >= 0xc2 and ch < 0xf8 then
            local n = ch < 0xe0 and 1 or (ch < 0xf0 and 2 or 3)
            local m1, e2 = perl.matchesDyn(str, [=[\G([\x80-\xbf]{]=] .. n .. '})', pos)
            if e2 ~= nil then
                if n == 1 then pos = e2 goto next_ end
                if n == 2 then
                    if not ((ch == 0xe0 and (perl.ord(m1) & 0xe0) == 0x80) or
                            (ch == 0xed and (perl.ord(m1) & 0xe0) == 0xa0) or
                            (ch == 0xef and perl.ord(m1) == 0xbf and
                                (perl.ord(substr(m1, 1)) & 0xfe) == 0xbe)) then pos = e2 goto next_ end
                else
                    if not ((ch == 0xf0 and (perl.ord(m1) & 0xf0) == 0x80) or
                            (ch == 0xf4 and perl.ord(m1) > 0x8f) or ch > 0xf4) then pos = e2 goto next_ end
                end
            end
        end
        -- replace bad character
        if bad == nil then bad = '?' end
        str = substr(str, 0, e - 1) .. bad .. substr(str, e)
        pos = e - 1 + #bad
        fixed = 1
        ::next_::
    end
    return fixed, str
end

-- Decode a base64 string (upstream XMP::DecodeBase64)
-- Inputs: 0) base64 string
-- Returns: decoded binary string
local b64chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
function XMP.DecodeBase64(val)
    local bits = 0
    local acc = 0
    local out = {}
    for i = 1, #val do
        local c = val:sub(i, i)
        if c == '=' then break end
        if c ~= ' ' and c ~= '\t' and c ~= '\n' and c ~= '\r' and c ~= '\f' then
            local b = b64chars:find(c, 1, true)
            if not b then break end
            acc = acc * 64 + (b - 1)
            bits = bits + 6
            if bits >= 8 then
                bits = bits - 8
                out[#out + 1] = string.char(math.floor(acc / 2 ^ bits) % 256)
                acc = acc % 2 ^ bits
            end
        end
    end
    return table.concat(out)
end

--------------------------------------------------------------------------------
-- Value conversion helpers
--------------------------------------------------------------------------------
-- Scan for XMP in a file
-- Inputs: 0) ExifTool object ref, 1) RAF reference
-- Returns: 1 if xmp was found, 0 otherwise
-- Notes: Currently only recognizes UTF8-encoded XMP
function XMP.ScanForXMP(et, raf)
    local buff, xmp, n
    local lastBuff = ''

    et:VPrint(0, "Scanning for XMP\n")
    while true do
        if buff == nil then
            n, buff = raf:Read(65536)
            if not truthy(n) then return 0 end
        end
        if xmp == nil then
            lastBuff = lastBuff .. buff
            local x1, e = matches(lastBuff, [[(<\?xpacket begin=)]])
            if e == nil then
                -- must keep last 15 bytes to match 16-byte "xpacket begin" string
                lastBuff = #buff <= 15 and buff or substr(buff, -15)
                buff = nil
                goto next_
            end
            xmp = x1
            buff = substr(lastBuff, e)
        end
        do
            local pos = #xmp - 18   -- (18 = length("<?xpacket end...") - 1)
            xmp = xmp .. buff           -- add new data to our XMP
            local m, e = matches(xmp, [[<\?xpacket end=['"][wr]['"]\?>]], pos > 0 and pos or 0) -- set start for "xpacket end" scan
            if m then
                buff = substr(xmp, e)       -- save data after end of XMP
                xmp = substr(xmp, 0, e)     -- isolate XMP
                -- check XMP for validity (not valid if it contains null bytes)
                pos = perl.rindex(xmp, "\0") + 1
                if pos == 0 then break end
                lastBuff = substr(xmp, pos)    -- re-parse beginning after last null byte
                xmp = nil
            else
                buff = nil
            end
        end
        ::next_::
    end
    if not truthy(et.FileType) then
        et.FILE_TYPE = et.FILE_EXT
        et:SetFileType('<unknown file containing XMP>', nil, '')
    end
    local dirInfo = {
        DataPt  = xmp,
        DirLen  = #xmp,
        DataLen = #xmp,
    }
    XMP.ProcessXMP(et, dirInfo)
    return 1
end

--------------------------------------------------------------------------------
-- Print conversion for XMP-aux:LensID
-- Inputs: 0) ExifTool ref, 1) LensID, 2) Make, 3) LensInfo, 4) FocalLength,
--         5) LensModel, 6) MaxApertureValue
-- (yes, this is ugly -- blame Adobe)
function XMP.PrintLensID(et, id, make, info, focalLength, lensModel, maxAv)
    local alt = { Pentax = 'Ricoh' }   -- Pentax changed its name to Ricoh
    -- missing: Olympus (no XMP:LensID written by Adobe)
    for _, mk in ipairs({ 'Canon', 'Nikon', 'Pentax', 'Sony', 'Sigma', 'Samsung', 'Leica' }) do
        if not (isMatchDyn(make, '(?i)' .. mk) or (alt[mk] and isMatchDyn(make, '(?i)' .. alt[mk]))) then goto next_ end
        do
            -- get name of module containing the lens lookup (default "Make.pm")
            local mod = ({ Sigma = 'SigmaRaw', Leica = 'Panasonic' })[mk] or mk
            local modTable = require('lexiftool.' .. mod)
            -- get the name of the lens name lookup (default "makeLensTypes")
            -- (canonLensTypes, pentaxLensTypes, nikonLensIDs, etc)
            local convName = ({ Nikon = 'nikonLensIDs' })[mk] or lc(mk) .. 'LensTypes'
            local printConv = modTable[convName]
            if not (type(printConv) == 'table' and next(printConv) ~= nil) then break end
            -- sf = short focal
            -- lf = long focal
            -- sa = max aperture at short focal
            -- la = max aperture at long focal
            local sf, lf, sa, la
            if truthy(info) then
                local a = perl.split(' ', info)
                for i = 1, 4 do if a[i] == 'undef' then a[i] = nil end end
                sf, lf, sa, la = a[1], a[2], a[3], a[4]
                local num = perl.num
                -- for Sony and ambiguous LensID, $info data may be incorrect:
                -- use only if it agrees with $focalLength and $maxAv (ref JR)
                if mk == 'Sony' and
                    ((truthy(focalLength) and ((truthy(sf) and num(focalLength) < num(sf) - 0.5) or
                                        (truthy(lf) and num(focalLength) > num(lf) + 0.5))) or
                     (truthy(maxAv) and ((truthy(sa) and num(maxAv) < num(sa) - 0.15) or
                                  (truthy(la) and num(maxAv) > num(la) + 0.15))))
                then
                    sf, lf, sa, la = nil, nil, nil, nil -- luacheck: ignore 311
                elseif truthy(maxAv) then
                    -- (using the short-focal-length max aperture in place of MaxAperture
                    -- is a bad approximation, so don't do this if MaxApertureValue exists)
                    sa = nil
                end
            end
            if mk == 'Pentax' and isMatch(id, [[^\d+$]]) then
                -- for Pentax, CS4 stores an int16u, but we use 2 x int8u
                id = perl.join(' ', { perl.unpack('C*', perl.pack('n', id)) })
            end
            -- Nikon is a special case because Adobe doesn't store the full LensID
            -- (Apple Photos does, but we have to convert back to hex)
            if mk == 'Nikon' then
                id = sprintf('%X', id)
                if #id & 0x01 ~= 0 then id = "0" .. id end   -- pad with leading 0 if necessary
                if isMatch(id, '(..)') then                   -- put spaces between bytes
                    id = subst(id, '(..)', '$1 ', 'g')
                    id = subst(id, ' $', '')
                end
                local newConv, used = {}, {}
                local i = 0
                -- (upstream walks `keys %$printConv` in Perl's hash order;
                --  sorted here for a deterministic numbering)
                local keys = {}
                for k in pairs(printConv) do
                    if type(k) == 'string' and isMatchDyn(k, '^' .. perl.quotemeta(id)) then keys[#keys + 1] = k end
                end
                tsort(keys)
                for _, k in ipairs(keys) do
                    local lens = printConv[k]
                    if not used[lens] then -- avoid duplicates
                        used[lens] = 1
                        newConv[i ~= 0 and id .. "." .. i or id] = lens
                        i = i + 1
                    end
                end
                printConv = newConv
            end
            local str = printConv[id]
            if str == nil and type(id) == 'string' then str = printConv[tonumber(id)] end
            if not truthy(str) then str = "Unknown (" .. perlStr(id) .. ")" end
            return Exif.PrintLensID(et, str, printConv,
                        nil, id, focalLength, sa, maxAv, sf, lf, lensModel)
        end
        ::next_::
    end
    return "Unknown (" .. perlStr(id) .. ")"
end

--------------------------------------------------------------------------------

-- Convert XMP date/time value to EXIF time format
-- Inputs: 0) string value, 1) optional "unsure" flag (only convert partial
--          dates when not unsure, mirroring the upstream $unsure argument)
-- Returns: converted value (and 1 as a second return when a full date/time
--          was converted, mirroring the upstream list-context return)
function XMP.ConvertXMPDate(val, unsure)
    -- (Lua patterns have no "optional group" quantifier -- `(...)?` only
    -- applies to a single preceding item, not a parenthesized capture -- so
    -- the upstream regex's optional ":SS" seconds group is checked as two
    -- separate patterns: with seconds, then without)
    local y, mo, d, hm, s, tz =
        val:match('^(%d%d%d%d)%-?(%d%d)%-?(%d%d)[T ](%d%d:%d%d)(:%d%d)[ \t\n\r\f\v]*([^ \t\n\r\f\v]*)$')
    if not y then
        y, mo, d, hm, tz = val:match('^(%d%d%d%d)%-?(%d%d)%-?(%d%d)[T ](%d%d:%d%d)[ \t\n\r\f\v]*([^ \t\n\r\f\v]*)$')
    end
    if y and mo then
        local s2 = s or '' -- seconds may be missing
        val = ('%s:%s:%s %s%s%s'):format(y, mo, d, hm, s2, tz or '') -- convert back to EXIF time format
        return val, 1
    elseif not unsure and val:match('^(%d%d%d%d)') then
        val = val:gsub('-', ':')
    end
    return val
end

-- Convert rational string value
-- Inputs: 0) string (converted to number, 'inf' or 'undef' on return if rational)
-- Returns: true if value was converted
function XMP.ConvertRational(val)
    local num, den = val:match('^(%-?%d+)/(%-?%d+)$')
    if not num then return nil end
    if tonumber(den) ~= 0 then
        return tonumber(num) / tonumber(den)
    elseif tonumber(num) ~= 0 then
        return 'inf'
    else
        return 'undef'
    end
end

-- Convert a string of floating point values to rationals
-- Inputs: 0) string of floating point numbers separated by spaces
-- Returns: string of rational numbers separated by spaces
function XMP.ConvertRationalList(val)
    local vals = perl.split(' ', val)
    if #vals ~= 4 then return val end
    for i = 1, #vals do
        local r = XMP.ConvertRational(vals[i])
        if r == nil then return val end
        vals[i] = r
    end
    return perl.join(' ', vals)
end

--------------------------------------------------------------------------------
-- Tag ID generation
--------------------------------------------------------------------------------

-- Generate a tag ID for this XMP tag
-- Inputs: 0) tag property name list ref, 1) array ref for receiving structure property list
--         2) array for receiving namespace list
-- Returns: tagID and outtermost interesting namespace (or '' if no namespace)
function XMP.GetXMPTagID(props, structProps, nsList)
    local tag
    local namespace
    for i = 1, #props do
        local prop = props[i]
        -- split name into namespace and property name
        local ns, nm
        local colon = sfind(prop, ':', 1, true)
        if colon then
            ns = ssub(prop, 1, colon - 1)
            nm = ssub(prop, colon + 1)
        else
            ns = ''
            nm = prop
        end
        if ignoreNamespace[ns] or ignoreProp[prop] or ignoreEtProp[prop] then
            -- special case: don't ignore rdf numbered items
            -- (not technically allowed in XMP, but used in RDF/XML)
            local num = nm:match('^_(%d+)$')
            if not num then
                -- save list index if necessary for structures
                if structProps and #structProps > 0 then
                    local idx = nm:match('^li (%d+)$')
                    if idx then
                        structProps[#structProps][#structProps[#structProps] + 1] = idx
                    end
                end
            else
                if tag then tag = tag .. '_' .. num end
            end
        else
            nm = subst(nm, [[ .*]], '') -- remove nodeID if it exists (no /s upstream: stops at an embedded newline)
            -- all uppercase is ugly, so convert it
            if not nm:find('[a-z]') then
                local xlat = stdXlatNS[ns] or ns
                local info = XMP.Main[xlat]
                local table_
                if type(info) == 'table' and info.SubDirectory then
                    table_ = require('lexiftool').GetTagTable(nil, info.SubDirectory.TagTable)
                end
                if not (table_ and table_[nm]) then
                    nm = lc(nm)
                    nm = nm:gsub('_([A-Za-z])', ucfirst)
                end
            end
            if tag then
                tag = tag .. ucfirst(nm) -- add to tag name
            else
                tag = nm
            end
            -- save structure information if necessary
            if structProps then
                structProps[#structProps + 1] = { nm }
                if nsList then nsList[#nsList + 1] = ns end
            end
            -- save namespace of first property to contribute to tag name
            -- (Perl truthiness: an empty-string namespace is falsy in Perl
            --  but truthy in Lua, so a later non-empty namespace must
            --  replace it -- e.g. an XML `xsi:schemaLocation` attribute
            --  after an unprefixed element name)
            if namespace == nil or namespace == '' then namespace = ns end
        end
    end
    return tag, namespace or ''
end

--------------------------------------------------------------------------------
-- Language handling
--------------------------------------------------------------------------------

-- Get standard case for language code
-- Inputs: 0) Language code
-- Returns: Language code in standard case
function XMP.StandardLangCase(lang)
    -- make 2nd subtag uppercase only if it is 2 letters
    local a, b, c = matches(lang, [[(?i)^([a-z]{2,3}|[xi])(-[a-z]{2})\b(.*)]])
    if a then
        return lc(a) .. uc(b) .. lc(c or '')
    end
    return lc(lang)
end

-- Get localized version of tagInfo hash
-- Inputs: 0) tagInfo hash ref, 1) language code (eg. "x-default")
-- Returns: new tagInfo hash ref, or nil if invalid
-- Get localized version of tagInfo hash (upstream: Image::ExifTool::GetLangInfo
-- in Writer.pl, shared by MIE/XMP/PNG/QuickTime; the caller must have already
-- verified tagInfo.Writable == 'lang-alt')
-- Notes: the new per-language tagInfo is cached in the tag table (keyed by
-- "<TagID>-<langCode>") so repeated occurrences of the same language reuse
-- the same tagInfo object -- required for ExifTool:FoundTag's LIST_TAGS
-- accumulation to recognize them as the same list tag
local function getLangInfo(et, tagInfo, langCode)
    local table_ = tagInfo.Table
    local tagID = tagInfo.TagID .. '-' .. langCode
    local langInfo = table_[tagID]
    if not langInfo then
        langInfo = {}
        for k, v in pairs(tagInfo) do langInfo[k] = v end
        langInfo.Name = tagInfo.Name .. '-' .. langCode
        langInfo.Description = et.MakeDescription(tagInfo.Name) .. ' (' .. langCode .. ')'
        langInfo.LangCode = langCode
        langInfo.SrcTagInfo = tagInfo
        et:AddTagToTable(table_, tagID, langInfo)
    end
    return langInfo
end

function XMP.GetLangInfo(tagInfo, langCode, et)
    -- only allow alternate language tags in lang-alt lists
    if not (tagInfo.Writable and tagInfo.Writable == 'lang-alt') then return nil end
    langCode = langCode:gsub('_', '-') -- RFC 3066 specifies '-' as a separator
    return getLangInfo(et, tagInfo, langCode)
end

--------------------------------------------------------------------------------
-- Register namespace for specified user-defined table
-- Inputs: 0) tag/structure table ref
-- Returns: namespace prefix
-- (XMP.pm:3077; Perl tells a list [prefix, URI] from a hash {prefix => URI}
--  by the reference type -- here a table with a [1] entry is the list)
function XMP.RegisterNamespace(tbl)
    if type(tbl.NAMESPACE) ~= 'table' then return tbl.NAMESPACE end
    local nsRef = tbl.NAMESPACE
    -- recognize as either a list or hash
    local ns
    if nsRef[1] ~= nil then
        ns = nsRef[1]
        nsURI[ns] = nsRef[2]
        uri2ns[nsRef[2]] = ns
    else -- must be a hash
        local nsList = {}  -- allow multiple namespace definitions
        for k in pairs(nsRef) do nsList[#nsList + 1] = k end
        tsort(nsList)
        while #nsList > 0 do
            ns = table.remove(nsList)
            if nsURI[ns] and nsURI[ns] ~= nsRef[ns] then
                perl.print(io.stderr, "User-defined namespace prefix '" .. ns .. "' conflicts with existing namespace\n")
            end
            nsURI[ns] = nsRef[ns]
            uri2ns[nsRef[ns]] = ns
        end
    end
    tbl.NAMESPACE = ns
    return ns
end

--------------------------------------------------------------------------------
-- Flattened tags (structure flattening for read)
--------------------------------------------------------------------------------

-- Generate flattened tags and add to table
-- Inputs: 0) tag table ref, 1) tag ID for Struct tag (if not defined, whole table is done)
--         2) flag to not expand sub-structures (NoSubStruct), 3) flag to leave
--         generated tags hidden
-- Returns: number of tags added
-- Notes: Must have verified that tagTablePtr[tagID].Struct exists before calling this routine
function XMP.AddFlattenedTags(tagTablePtr, tagID, noSubStruct, hidden)
    local count = 0
    local tagIDs = {}
    if tagID then
        tagIDs[#tagIDs + 1] = tagID
    else
        for k, v in pairs(tagTablePtr) do
            if type(v) == 'table' and v.Struct then
                tagIDs[#tagIDs + 1] = k
            end
        end
    end
    for i = 1, #tagIDs do
        local tid = tagIDs[i]
        local tagInfo = tagTablePtr[tid]
        if tagInfo.Flattened then goto continue end -- only generate flattened tags once
        tagInfo.Flattened = 1
        local strTable = tagInfo.Struct
        if type(strTable) ~= 'table' then goto continue end
        -- get prefix for flattened tag names
        local flat = tagInfo.FlatName or tagInfo.Name
        -- get family 2 group name for this structure tag
        local tagG2 = tagInfo.Groups and tagInfo.Groups[2]
        if not tagG2 then tagG2 = tagTablePtr.GROUPS and tagTablePtr.GROUPS[2] end
        for field, fieldInfo in pairs(strTable) do
            if specialStruct[field] then goto nextfield end
            if fieldInfo.LangCode then goto nextfield end -- don't flatten lang-alt tags
            if fieldInfo.Struct and noSubStruct then goto nextfield end -- don't expand sub-structures if specified
            -- build a tag ID for the corresponding flattened tag
            local fieldName = ucfirst(field)
            local flatField = fieldInfo.FlatName or fieldName
            local flatID = tid .. fieldName
            local flatInfo = tagTablePtr[flatID]
            if flatInfo then
                if type(flatInfo) ~= 'table' then goto nextfield end
                -- pre-defined flattened tags should have Flat flag set
                if flatInfo.Flat == nil then
                    if flatInfo.NotFlat then goto nextfield end
                end
                flatInfo.Flat = 0
                -- copy all missing entries from field information
                for k2, v2 in pairs(fieldInfo) do
                    if k2 ~= 'PropertyPath' and flatInfo[k2] == nil then
                        flatInfo[k2] = v2
                    end
                end
                -- re-generate List flag unless it is set to 0
                if truthy(flatInfo.List) then flatInfo.List = nil end
            else
                -- generate new flattened tag information based on structure field
                local flatName = flat .. flatField
                flatInfo = {}
                for k2, v2 in pairs(fieldInfo) do
                    flatInfo[k2] = v2
                end
                flatInfo.Name = flatName
                flatInfo.Flat = 0
                if not hidden then flatInfo.Hidden = 0 end
                if fieldInfo.FlatName then flatInfo.FlatName = flatName end
                if fieldInfo.Groups then
                    local g2 = {}
                    for f, n in pairs(fieldInfo.Groups) do g2[f] = n end
                    flatInfo.Groups = g2
                end
                -- add new flattened tag to table
                require('lexiftool').AddTagToTable(nil, tagTablePtr, flatID, flatInfo)
                count = count + 1
            end
            -- propagate List flag (unless set to 0 in pre-defined flattened tag)
            if flatInfo.List == nil and (truthy(fieldInfo.List) or truthy(tagInfo.List)) then
                flatInfo.List = truthy(fieldInfo.List) and fieldInfo.List or 1
            end
            -- set group 2 name from the first existing family 2 group
            if not flatInfo.Groups then flatInfo.Groups = {} end
            if fieldInfo.Groups and fieldInfo.Groups[2] then
                flatInfo.Groups[2] = fieldInfo.Groups[2]
            elseif strTable.GROUPS and strTable.GROUPS[2] then
                flatInfo.Groups[2] = strTable.GROUPS[2]
            else
                flatInfo.Groups[2] = tagG2
            end
            flatInfo.RootTagInfo = tagInfo.RootTagInfo or tagInfo
            flatInfo.ParentTagInfo = tagInfo
            -- recursively generate flattened tags for sub-structures
            if flatInfo.Struct then
                if #flatID > 250 then
                    -- (upstream: Perl builtin warn + last)
                    perl.print(io.stderr, 'Possible deep recursion for tag ' .. flatID .. '\n')
                    goto nextfieldBreak
                end
                -- reset flattened tag just in case we flattened hierarchy in
                -- the wrong order (must start from the outtermost structure
                -- to get the List flags right)
                flatInfo.Flattened = nil
                count = count + XMP.AddFlattenedTags(tagTablePtr, flatID, flatInfo.NoSubStruct)
            end
            ::nextfield::
        end
        ::nextfieldBreak::
        ::continue::
    end
    return count
end

--------------------------------------------------------------------------------
-- XMP tag tables
--------------------------------------------------------------------------------

-- Main XMP table (subset: only the namespace tables ported so far)
XMP.Main = {
    GROUPS = { [2] = 'Unknown' },
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    WRITE_PROC = XMP.WriteXMP,
    dc = {
        Name = 'dc', -- (otherwise generated name would be 'Dc')
        SubDirectory = { TagTable = 'lexiftool.XMP.dc' },
    },
    xmpRights = {
        Name = 'xmpRights',
        SubDirectory = { TagTable = 'lexiftool.XMP.xmpRights' },
    },
    xmpMM = {
        Name = 'xmpMM',
        SubDirectory = { TagTable = 'lexiftool.XMP.xmpMM' },
    },
    xmpBJ = {
        Name = 'xmpBJ',
        SubDirectory = { TagTable = 'lexiftool.XMP.xmpBJ' },
    },
    xmpTPg = {
        Name = 'xmpTPg',
        SubDirectory = { TagTable = 'lexiftool.XMP.xmpTPg' },
    },
    xmpNote = {
        Name = 'xmpNote',
        SubDirectory = { TagTable = 'lexiftool.XMP.xmpNote' },
    },
    photoshop = {
        Name = 'photoshop',
        SubDirectory = { TagTable = 'lexiftool.XMP.photoshop' },
    },
    crd = {
        Name = 'crd',
        SubDirectory = { TagTable = 'lexiftool.XMP.crd' },
    },
    crs = {
        Name = 'crs',
        SubDirectory = { TagTable = 'lexiftool.XMP.crs' },
    },
    prism = {
        Name = 'prism',
        SubDirectory = { TagTable = 'lexiftool.XMP.prism' },
    },
    prl = {
        Name = 'prl',
        SubDirectory = { TagTable = 'lexiftool.XMP.prl' },
    },
    pur = {
        Name = 'pur',
        SubDirectory = { TagTable = 'lexiftool.XMP.pur' },
    },
    pmi = {
        Name = 'pmi',
        SubDirectory = { TagTable = 'lexiftool.XMP.pmi' },
    },
    prm = {
        Name = 'prm',
        SubDirectory = { TagTable = 'lexiftool.XMP.prm' },
    },
    rdf = {
        Name = 'rdf',
        SubDirectory = { TagTable = 'lexiftool.XMP.rdf' },
    },
   ['x'] = {
        Name = 'x',
        SubDirectory = { TagTable = 'lexiftool.XMP.x' },
    },
    acdsee = {
        Name = 'acdsee',
        SubDirectory = { TagTable = 'lexiftool.XMP.acdsee' },
    },
   ['acdsee-rs'] = {
        Name = 'acdsee-rs',
        SubDirectory = { TagTable = 'lexiftool.XMP.ACDSeeRegions' },
    },
    pdf = {
        Name = 'pdf',
        SubDirectory = { TagTable = 'lexiftool.XMP.pdf' },
    },
    pdfx = {
        Name = 'pdfx',
        SubDirectory = { TagTable = 'lexiftool.XMP.pdfx' },
    },
    xmp = {
        Name = 'xmp',
        SubDirectory = { TagTable = 'lexiftool.XMP.xmp' },
    },
    album = {
        Name = 'album',
        SubDirectory = { TagTable = 'lexiftool.XMP.Album' },
    },
    et = {
        Name = 'et',
        SubDirectory = { TagTable = 'lexiftool.XMP.ExifTool' },
    },
    iptcCore = {
        Name = 'iptcCore',
        SubDirectory = { TagTable = 'lexiftool.XMP.iptcCore' },
    },
    xmpDM = {
        Name = 'xmpDM',
        SubDirectory = { TagTable = 'lexiftool.XMP.xmpDM' },
    },
    tiff = {
        Name = 'tiff',
        SubDirectory = { TagTable = 'lexiftool.XMP.tiff' },
    },
    exif = {
        Name = 'exif',
        SubDirectory = { TagTable = 'lexiftool.XMP.exif' },
    },
    exifEX = {
        Name = 'exifEX',
        SubDirectory = { TagTable = 'lexiftool.XMP.exifEX' },
    },
    aux = {
        Name = 'aux',
        SubDirectory = { TagTable = 'lexiftool.XMP.aux' },
    },
    photomech = {
        Name = 'photomech',
        SubDirectory = { TagTable = 'lexiftool.PhotoMechanic.XMP' },
    },
    mediapro = {
        Name = 'mediapro',
        SubDirectory = { TagTable = 'lexiftool.XMP.MediaPro' },
    },
    expressionmedia = {
        Name = 'expressionmedia',
        SubDirectory = { TagTable = 'lexiftool.XMP.ExpressionMedia' },
    },
    microsoft = {
        Name = 'microsoft',
        SubDirectory = { TagTable = 'lexiftool.Microsoft.XMP' },
    },
    MP = {
        Name = 'MP',
        SubDirectory = { TagTable = 'lexiftool.Microsoft.MP' },
    },
    MP1 = {
        Name = 'MP1',
        SubDirectory = { TagTable = 'lexiftool.Microsoft.MP1' },
    },
    iptcExt = {
        Name = 'iptcExt',
        SubDirectory = { TagTable = 'lexiftool.XMP.iptcExt' },
    },
    PixelLive = {
        SubDirectory = { TagTable = 'lexiftool.XMP.PixelLive' },
    },
    xmpPLUS = {
        Name = 'xmpPLUS',
        SubDirectory = { TagTable = 'lexiftool.XMP.xmpPLUS' },
    },
    panorama = {
        Name = 'panorama',
        SubDirectory = { TagTable = 'lexiftool.XMP.panorama' },
    },
    digiKam = {
        Name = 'digiKam',
        SubDirectory = { TagTable = 'lexiftool.XMP.digiKam' },
    },
    swf = {
        Name = 'swf',
        SubDirectory = { TagTable = 'lexiftool.XMP.swf' },
    },
    cell = {
        Name = 'cell',
        SubDirectory = { TagTable = 'lexiftool.XMP.cell' },
    },
    aas = {
        Name = 'aas',
        SubDirectory = { TagTable = 'lexiftool.XMP.aas' },
    },
    ['mwg-rs'] = {
        Name = 'mwg-rs',
        SubDirectory = { TagTable = 'lexiftool.MWG.Regions' },
    },
    ['mwg-kw'] = {
        Name = 'mwg-kw',
        SubDirectory = { TagTable = 'lexiftool.MWG.Keywords' },
    },
    ['mwg-coll'] = {
        Name = 'mwg-coll',
        SubDirectory = { TagTable = 'lexiftool.MWG.Collections' },
    },
    extensis = {
        Name = 'extensis',
        SubDirectory = { TagTable = 'lexiftool.XMP.extensis' },
    },
    ics = {
        Name = 'ics',
        SubDirectory = { TagTable = 'lexiftool.XMP.ics' },
    },
    fpv = {
        Name = 'fpv',
        SubDirectory = { TagTable = 'lexiftool.XMP.fpv' },
    },
    creatorAtom = {
        Name = 'creatorAtom',
        SubDirectory = { TagTable = 'lexiftool.XMP.creatorAtom' },
    },
   ['apple-fi'] = {
        Name = 'apple-fi',
        SubDirectory = { TagTable = 'lexiftool.XMP.apple_fi' },
    },
    plus = {
        Name = 'plus',
        SubDirectory = { TagTable = 'lexiftool.PLUS.XMP' },
    },
    cc = {
        Name = 'cc',
        SubDirectory = { TagTable = 'lexiftool.XMP.cc' },
    },
    dex = {
        Name = 'dex',
        SubDirectory = { TagTable = 'lexiftool.XMP.dex' },
    },
    GAudio = {
        Name = 'GAudio',
        SubDirectory = { TagTable = 'lexiftool.Google.GAudio' },
    },
    GImage = {
        Name = 'GImage',
        SubDirectory = { TagTable = 'lexiftool.Google.GImage' },
    },
    GPano = {
        Name = 'GPano',
        SubDirectory = { TagTable = 'lexiftool.Google.GPano' },
    },
    GContainer = {
        Name = 'GContainer',
        SubDirectory = { TagTable = 'lexiftool.Google.GContainer' },
    },
    GSpherical = {
        Name = 'GSpherical',
        SubDirectory = { TagTable = 'lexiftool.Google.GSpherical' },
    },
    GDepth = {
        Name = 'GDepth',
        SubDirectory = { TagTable = 'lexiftool.Google.GDepth' },
    },
    GFocus = {
        Name = 'GFocus',
        SubDirectory = { TagTable = 'lexiftool.Google.GFocus' },
    },
    GCamera = {
        Name = 'GCamera',
        SubDirectory = { TagTable = 'lexiftool.Google.GCamera' },
    },
    GCreations = {
        Name = 'GCreations',
        SubDirectory = { TagTable = 'lexiftool.Google.GCreations' },
    },
    Device = {
        Name = 'Device',
        SubDirectory = { TagTable = 'lexiftool.Google.Device' },
    },
    hdr = {
        Name = 'hdr',
        SubDirectory = { TagTable = 'lexiftool.XMP.hdr' },
    },
    hdrgm = {
        Name = 'hdrgm',
        SubDirectory = { TagTable = 'lexiftool.XMP.hdrgm' },
    },
    xmpDSA = {
        Name = 'xmpDSA',
        SubDirectory = { TagTable = 'lexiftool.Panasonic.DSA' },
    },
    lr = {
        Name = 'lr',
        SubDirectory = { TagTable = 'lexiftool.XMP.Lightroom' },
    },
    DICOM = {
        Name = 'DICOM',
        SubDirectory = { TagTable = 'lexiftool.XMP.DICOM' },
    },
    dwc = {
        Name = 'dwc',
        SubDirectory = { TagTable = 'lexiftool.DarwinCore.Main' },
    },
    getty = {
        Name = 'getty',
        SubDirectory = { TagTable = 'lexiftool.XMP.GettyImages' },
    },
    LImage = {
        Name = 'LImage',
        SubDirectory = { TagTable = 'lexiftool.XMP.LImage' },
    },
    sdc = {
        Name = 'sdc',
        SubDirectory = { TagTable = 'lexiftool.Nikon.sdc' },
    },
    ast = {
        Name = 'ast',
        SubDirectory = { TagTable = 'lexiftool.Nikon.ast' },
    },
    nine = {
        Name = 'nine',
        SubDirectory = { TagTable = 'lexiftool.Nikon.nine' },
    },
    HDRGainMap = {
        Name = 'HDRGainMap',
        SubDirectory = { TagTable = 'lexiftool.XMP.HDRGainMap' },
    },
    apdi = {
        Name = 'apdi',
        SubDirectory = { TagTable = 'lexiftool.XMP.apdi' },
    },
    seal = {
        Name = 'seal',
        SubDirectory = { TagTable = 'lexiftool.XMP.seal' },
    },
    ['drone-dji'] = {
        Name = 'drone-dji',
        SubDirectory = { TagTable = 'lexiftool.DJI.XMP' },
    },
}

--
-- Tag tables for all XMP namespaces:
--
-- Writable - only need to define this for writable tags if not plain text
--            (boolean, integer, rational, real, date or lang-alt)
-- List - XMP list type (Bag, Seq or Alt, or set to 1 for elements in Struct lists --
--        this is necessary to obtain proper list behaviour when reading/writing)
--
-- (Note that family 1 group names are generated from the property namespace, not
--  the group1 names below which exist so the groups will appear in the list.)
--
-- (upstream's %xmpTableDefaults.  Published as XMP.xmpTableDefaults because
--  upstream exports the hash via `use vars` and the XMP namespace tables in
--  DJI.pm, Google.pm, MWG.pm and PLUS.pm spread it under its full name,
--  %Image::ExifTool::XMP::xmpTableDefaults -- so those modules apply it here
--  as XMP.xmpTableDefaults { ... }, module name and all.)
local xmpTableDefaults = function(t)
    for k, v in pairs {
        -- (WriteXMP and CheckXMP are WriteXMP.pl's, bound to their AUTOLOAD
        --  closures at the predeclarations above)
        WRITE_PROC = XMP.WriteXMP,
        CHECK_PROC = XMP.CheckXMP,
        WRITABLE   = 'string',
        LANG_INFO  = XMP.GetLangInfo,
    } do t[k] = v end
    return t
end
XMP.xmpTableDefaults = xmpTableDefaults

-- rdf attributes extracted
XMP.rdf = xmpTableDefaults {
    GROUPS = { [1] = 'XMP-rdf', [2] = 'Document' },
    NAMESPACE = 'rdf',
    NOTES = [[
        Most RDF attributes are handled internally, but the "about" attribute is
        treated specially to allow it to be set to a specific value if required.
    ]],
    about = { Protected = 1 },
}

-- x attributes extracted
XMP.x = xmpTableDefaults {
    GROUPS = { [1] = 'XMP-x', [2] = 'Document' },
    NAMESPACE = 'x',
    NOTES = [[
        The "x" namespace is used for the "xmpmeta" wrapper, and may contain an
        "xmptk" attribute that is extracted as the XMPToolkit tag.  When writing,
        the XMPToolkit tag is generated automatically by ExifTool unless
        specifically set to another value.
    ]],
    xmptk = { Name = 'XMPToolkit', Protected = 1 },
}

-- Dublin Core namespace properties (dc)
XMP.dc = xmpTableDefaults {
    GROUPS = { [1] = 'XMP-dc', [2] = 'Other' },
    NAMESPACE = 'dc',
    TABLE_DESC = 'XMP Dublin Core',
    NOTES = 'Dublin Core namespace tags.',
    contributor = { Groups = { [2] = 'Author' }, List = 'Bag' },
    coverage    = { },
    creator     = { Groups = { [2] = 'Author' }, List = 'Seq' },
    date        = { Groups = { [2] = 'Time' }, List = 'Seq', Writable = 'date', Shift = 'Time', Validate = dateTimeInfo.Validate,
                    PrintConv = dateTimeInfo.PrintConv, PrintConvInv = dateTimeInfo.PrintConvInv },
    description = { Groups = { [2] = 'Image' }, Writable = 'lang-alt' },
   ['format']     = { Groups = { [2] = 'Image' } },
    identifier  = { Groups = { [2] = 'Image' } },
    language    = { List = 'Bag' },
    publisher   = { Groups = { [2] = 'Author' }, List = 'Bag' },
    relation    = { List = 'Bag' },
    rights      = { Groups = { [2] = 'Author' }, Writable = 'lang-alt' },
    source      = { Groups = { [2] = 'Author' }, Avoid = 1 },
    subject     = { Groups = { [2] = 'Image' }, List = 'Bag' },
    title       = { Groups = { [2] = 'Image' }, Writable = 'lang-alt' },
    type        = { Groups = { [2] = 'Image' }, List = 'Bag' },
}

--------------------------------------------------------------------------------

-- XMP Rights Management namespace properties (xmpRights, xapRights)
XMP.xmpRights = xmpTableDefaults {
    GROUPS = { [1] = 'XMP-xmpRights', [2] = 'Author' },
    NAMESPACE = 'xmpRights',
    NOTES = 'XMP Rights Management namespace tags.',
    Certificate     = { },
    Marked          = { Writable = 'boolean' },
    Owner           = { List = 'Bag' },
    UsageTerms      = { Writable = 'lang-alt' },
    WebStatement    = { },
}

-- XMP Media Management namespace properties (xmpMM, xapMM)
XMP.xmpMM = xmpTableDefaults {
    GROUPS = { [1] = 'XMP-xmpMM', [2] = 'Other' },
    NAMESPACE = 'xmpMM',
    TABLE_DESC = 'XMP Media Management',
    NOTES = 'XMP Media Management namespace tags.',
    DerivedFrom     = { Struct = sResourceRef },
    DocumentID      = { },
    History         = { Struct = sResourceEvent, List = 'Seq' },
    -- we treat these like list items since History is a list
    Ingredients     = { Struct = sResourceRef, List = 'Bag' },
    InstanceID      = { }, --PH (CS3)
    ManagedFrom     = { Struct = sResourceRef },
    Manager         = { Groups = { [2] = 'Author' } },
    ManageTo        = { Groups = { [2] = 'Author' } },
    ManageUI        = { },
    ManagerVariant  = { },
    Manifest        = { Struct = sManifestItem, List = 'Bag' },
    OriginalDocumentID = { },
    Pantry          = { Struct = sPantryItem, List = 'Bag' },
    PreservedFileName = { }, -- undocumented
    RenditionClass  = { },
    RenditionParams = { },
    VersionID       = { },
    Versions        = { Struct = sVersion, List = 'Seq' },
    LastURL         = { }, -- (deprecated)
    RenditionOf     = { Struct = sResourceRef }, -- (deprecated)
    SaveID          = { Writable = 'integer' }, -- (deprecated)
    subject         = { List = 'Seq', Avoid = 1, Notes = 'undocumented' },
}

-- XMP Basic Job Ticket namespace properties (xmpBJ, xapBJ)
XMP.xmpBJ = xmpTableDefaults {
    GROUPS = { [1] = 'XMP-xmpBJ', [2] = 'Other' },
    NAMESPACE = 'xmpBJ',
    TABLE_DESC = 'XMP Basic Job Ticket',
    NOTES = 'XMP Basic Job Ticket namespace tags.',
    -- Note: JobRef is a List of structures.  To accomplish this, we set the XMP
    -- List=>'Bag', but since SubDirectory is defined, this tag isn't writable
    -- directly.  Then we need to set List=>1 for the members so the Writer logic
    -- will allow us to add list items.
    JobRef = { Struct = sJobRef, List = 'Bag' },
}

-- XMP Paged-Text namespace properties (xmpTPg)
XMP.xmpTPg = xmpTableDefaults {
    GROUPS = { [1] = 'XMP-xmpTPg', [2] = 'Image' },
    NAMESPACE = 'xmpTPg',
    TABLE_DESC = 'XMP Paged-Text',
    NOTES = 'XMP Paged-Text namespace tags.',
    MaxPageSize         = { Struct = XMP.sDimensions },
    NPages              = { Writable = 'integer' },
    Fonts               = {
        FlatName = '',
        Struct = sFont,
        List = 'Bag',
    },
    FontsVersionString  = { Name = 'FontVersion',     Flat = 1 },
    FontsComposite      = { Name = 'FontComposite',   Flat = 1 },
    Colorants           = {
        FlatName = 'Colorant',
        Struct = sColorant,
        List = 'Seq',
    },
    PlateNames          = { List = 'Seq' },
    -- the following found in an AI file:
    HasVisibleTransparency = { Writable = 'boolean' },
    HasVisibleOverprint    = { Writable = 'boolean' },
    SwatchGroups = {
        Struct = sSwatchGroup,
        List = 'Seq',
    },
    SwatchGroupsColorants = { Name = 'SwatchGroupsColorants', Flat = 1 },
    SwatchGroupsGroupName = { Name = 'SwatchGroupName',       Flat = 1 },
    SwatchGroupsGroupType = { Name = 'SwatchGroupType',       Flat = 1 },
}

-- XMP Note namespace properties (xmpNote)
XMP.xmpNote = xmpTableDefaults {
    GROUPS = { [1] = 'XMP-xmpNote' },
    NAMESPACE = 'xmpNote',
    NOTES = 'XMP Note namespace tags.',
    HasExtendedXMP = {
        Notes = [[
            this tag is protected so it is not writable directly.  Instead, it is set
            automatically to the GUID of the extended XMP when writing extended XMP to a
            JPEG image
        ]],
        Protected = 2,
    },
}

-- Adobe Photoshop namespace properties (photoshop)
XMP.photoshop = xmpTableDefaults {
    GROUPS = { [1] = 'XMP-photoshop', [2] = 'Image' },
    NAMESPACE = 'photoshop',
    TABLE_DESC = 'XMP Photoshop',
    NOTES = 'Adobe Photoshop namespace tags.',
    AuthorsPosition = { Groups = { [2] = 'Author' } },
    CaptionWriter   = { Groups = { [2] = 'Author' } },
    Category        = { },
    City            = { Groups = { [2] = 'Location' } },
    ColorMode       = {
        Writable = 'integer', -- (as of July 2010 spec, courtesy of yours truly)
        PrintConvColumns = 2,
        PrintConv = {
            [0] = 'Bitmap',
            [1] = 'Grayscale',
            [2] = 'Indexed',
            [3] = 'RGB',
            [4] = 'CMYK',
            [7] = 'Multichannel',
            [8] = 'Duotone',
            [9] = 'Lab',
        },
    },
    Country         = { Groups = { [2] = 'Location' } },
    Credit          = { Groups = { [2] = 'Author' } },
    DateCreated     = { Groups = { [2] = 'Time' }, Writable = 'date', Shift = 'Time', Validate = dateTimeInfo.Validate, PrintConv = dateTimeInfo.PrintConv,
                        PrintConvInv = dateTimeInfo.PrintConvInv },
    DocumentAncestors = {
        List = 'Bag',
    },
    Headline        = { },
    History         = { }, --PH (CS3)
    ICCProfile      = { Name = 'ICCProfileName' }, --PH
    Instructions    = { },
    LegacyIPTCDigest = { }, --PH
    SidecarForExtension = { }, --PH (CS3)
    Source          = { Groups = { [2] = 'Author' } },
    State           = { Groups = { [2] = 'Location' } },
    -- the XMP spec doesn't show SupplementalCategories as a 'Bag', but
    -- that's the way Photoshop writes it [fixed in the June 2005 XMP spec].
    -- Also, it is incorrectly listed as "SupplementalCategory" in the
    -- IPTC Standard Photo Metadata docs (2008rev2 and July 2009rev1) - PH
    SupplementalCategories  = { List = 'Bag' },
    TextLayers = {
        FlatName = 'Text',
        List = 'Seq',
        Struct = {
            STRUCT_NAME = 'Layer',
            NAMESPACE   = 'photoshop',
            LayerName   = { },
            LayerText   = { },
        },
    },
    TransmissionReference = { Notes = 'Now used as a job identifier' },
    Urgency         = {
        Writable = 'integer',
        Notes = 'should be in the range 1-8 to conform with the XMP spec',
        PrintConv = { -- (same values as IPTC:Urgency)
            [0] = '0 (reserved)',              -- (not standard XMP)
            [1] = '1 (most urgent)',
            [2] = 2,
            [3] = 3,
            [4] = 4,
            [5] = '5 (normal urgency)',
            [6] = 6,
            [7] = 7,
            [8] = '8 (least urgent)',
            [9] = '9 (user-defined priority)', -- (not standard XMP)
        },
    },
    EmbeddedXMPDigest = { },   --PH (LR5)
    CameraProfiles = { --PH (2022-10-11)
        List = 'Seq',
        Struct = {
            NAMESPACE   = 'stCamera',
            STRUCT_NAME = 'Camera',
            Author              = { },
            Make                = { },
            Model               = { },
            UniqueCameraModel   = { },
            CameraRawProfile    = { Writable = 'boolean' },
            AutoScale           = { Writable = 'boolean' },
            Lens                = { },
            CameraPrettyName    = { },
            LensPrettyName      = { },
            ProfileName         = { },
            SensorFormatFactor  = { Writable = 'real' },
            FocalLength         = { Writable = 'real' },
            FocusDistance       = { Writable = 'real' },
            ApertureValue       = { Writable = 'real' },
            PerspectiveModel    = {
                Namespace       = 'crlcp',
                Struct = {
                    NAMESPACE   = 'stCamera',
                    STRUCT_NAME = 'PerspectiveModel',
                    Version              = { },
                    ImageXCenter         = { Writable = 'real' },
                    ImageYCenter         = { Writable = 'real' },
                    ScaleFactor          = { Writable = 'real' },
                    RadialDistortParam1  = { Writable = 'real' },
                    RadialDistortParam2  = { Writable = 'real' },
                    RadialDistortParam3  = { Writable = 'real' },
                    VignetteModel = {
                        Namespace       = 'crlcp',
                        Struct = {
                            NAMESPACE   = 'stCamera',
                            STRUCT_NAME = 'VignetteModel',
                            ImageXCenter         = { Writable = 'real' },
                            ImageYCenter         = { Writable = 'real' },
                            VignetteModelParam1    = { Writable = 'real' },
                            VignetteModelPiecewiseParam = { List = 'Seq' },
                        },
                    },
                },
            },
        },
    },
    CameraProfilesPerspectiveModelVignetteModelVignetteModelPiecewiseParam = {
        Name = 'CameraProfilesPerspectiveModelVignetteModelPiecewiseParam',
        Flat = 1,
    },
    CameraProfilesPerspectiveModelVignetteModelVignetteModelParam1 = {
        Name = 'CameraProfilesPerspectiveModelVignetteModelParam1',
        Flat = 1,
    },
    LabelColor = { },
}

-- XMP namespace properties (xmp, xap)
XMP.xmp = xmpTableDefaults {
    GROUPS = { [1] = 'XMP-xmp', [2] = 'Image' },
    NAMESPACE = 'xmp',
    NOTES = [[
        XMP namespace tags.  If the older "xap", "xapBJ", "xapMM" or "xapRights"
        namespace prefixes are found, they are translated to the newer "xmp",
        "xmpBJ", "xmpMM" and "xmpRights" prefixes for use in family 1 group names.
    ]],
    Advisory    = { List = 'Bag', Notes = 'deprecated' },
    BaseURL     = { },
    -- (date/time tags not as reliable as EXIF)
    CreateDate  = { Groups = { [2] = 'Time' }, Writable = 'date', Shift = 'Time', Validate = dateTimeInfo.Validate, PrintConv = dateTimeInfo.PrintConv,
                    PrintConvInv = dateTimeInfo.PrintConvInv, Priority = 0 },
    CreatorTool = { },
    Identifier  = { Avoid = 1, List = 'Bag' },
    Label       = { },
    MetadataDate= { Groups = { [2] = 'Time' }, Writable = 'date', Shift = 'Time', Validate = dateTimeInfo.Validate, PrintConv = dateTimeInfo.PrintConv,
                    PrintConvInv = dateTimeInfo.PrintConvInv },
    ModifyDate  = { Groups = { [2] = 'Time' }, Writable = 'date', Shift = 'Time', Validate = dateTimeInfo.Validate, PrintConv = dateTimeInfo.PrintConv,
                    PrintConvInv = dateTimeInfo.PrintConvInv, Priority = 0 },
    Nickname    = { },
    Rating      = { Writable = 'real', Notes = 'a value from 0 to 5, or -1 for "rejected"' },
    RatingPercent= { Writable = 'real', Avoid = 1, Notes = 'non-standard' },
    Thumbnails  = {
        FlatName = 'Thumbnail',
        Struct = sThumbnail,
        List = 'Alt',
    },
    -- the following written by Adobe InDesign, not part of XMP spec:
    PageInfo        = {
        FlatName = 'PageImage',
        Struct = sPageInfo,
        List = 'Seq',
    },
    PageInfoImage = { Name = 'PageImage', Flat = 1 },
    Title       = { Avoid = 1, Notes = 'non-standard', Writable = 'lang-alt' }, -- #11
    Author      = { Avoid = 1, Notes = 'non-standard', Groups = { [2] = 'Author' } }, -- #11
    Keywords    = { Avoid = 1, Notes = 'non-standard' }, -- #11
    Description = { Avoid = 1, Notes = 'non-standard', Writable = 'lang-alt' }, -- #11
    Format      = { Avoid = 1, Notes = 'non-standard' }, -- #11
}

-- Adobe PDF namespace properties (pdf)
XMP.pdf = xmpTableDefaults {
    GROUPS = { [1] = 'XMP-pdf', [2] = 'Image' },
    NAMESPACE = 'pdf',
    TABLE_DESC = 'XMP PDF',
    NOTES = [[
        Adobe PDF namespace tags.  The official XMP specification defines only
        Keywords, PDFVersion, Producer and Trapped.  The other tags are included
        because they have been observed in PDF files, but some are avoided when
        writing due to name conflicts with other XMP namespaces.
    ]],
    Author = { Groups = { [2] = 'Author' } },
    ModDate = { Groups = { [2] = 'Time' }, Writable = 'date', Shift = 'Time', Validate = dateTimeInfo.Validate,
                PrintConv = dateTimeInfo.PrintConv, PrintConvInv = dateTimeInfo.PrintConvInv },
    CreationDate = { Groups = { [2] = 'Time' }, Writable = 'date', Shift = 'Time', Validate = dateTimeInfo.Validate, PrintConv = dateTimeInfo.PrintConv,
                     PrintConvInv = dateTimeInfo.PrintConvInv },
    Creator = { Groups = { [2] = 'Author' }, Avoid = 1 },
    Copyright = { Groups = { [2] = 'Author' }, Avoid = 1 },
    Marked = { Writable = 'boolean', Avoid = 1 },
    Subject = { Avoid = 1 },
    Title = { Avoid = 1 },
    Trapped = {
        -- remove leading '/' from '/True' or '/False'
        ValueConv = function(_self, val) return (perlStr(val):gsub('^/', '')) end,
        ValueConvInv = function(_self, val) return '/' .. val end,
        PrintConv = { True = 'True', False = 'False', Unknown = 'Unknown' },
    },
    Keywords = { Priority = -1 }, -- (-1 to get below Priority 0 PDF:Keywords)
    PDFVersion = {},
    Producer = { Groups = { [2] = 'Author' } },
}

-- PDF extension namespace properties (pdfx)
XMP.pdfx = xmpTableDefaults {
    GROUPS = { [1] = 'XMP-pdfx', [2] = 'Document' },
    NAMESPACE   = 'pdfx',
    NOTES = [[
        PDF extension tags.  This namespace is used to store application-defined PDF
        information, so there are few pre-defined tags.  User-defined tags must be
        created to enable writing of other XMP-pdfx information.
    ]],
    SourceModified = {
        Name = 'SourceModified',
        Groups = { [2] = 'Time' },
        Shift = 'Time',
        ValueConv = function(_self, val) return require('lexiftool.PDF').ConvertPDFDate(val) end,
        ValueConvInv = function(self, val)
            val = require('lexiftool.PDF').WritePDFValue(self, val, 'date')
            val = perl.tr(val, '()', '', 'd')
            return val
        end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
        PrintConvInv = function(self, val) return self:InverseDateTime(val) end,
    },
}

-- EXIF tags added by the EXIF 2.32-3.0 for XMP specification (exifEX) --
-- previously entirely unported (read or write). All plain except
-- CompositeImageExposureTimes (Struct-typed, deferred like every other
-- struct in this file).
XMP.exifEX = xmpTableDefaults {
    GROUPS = { [1] = 'XMP-exifEX', [2] = 'Image' },
    NAMESPACE = 'exifEX',
    PRIORITY = 0, -- not as reliable as actual EXIF tags
    NOTES = [[
        EXIF tags added by the EXIF 2.32 for XMP specification (see
        L<https://cipa.jp/std/documents/download_e.html?DC-010-2020_E>).
    ]],
    Gamma = { Writable = 'rational' },
    PhotographicSensitivity = { Writable = 'integer' },
    SensitivityType = {
        Writable = 'integer',
        PrintConv = {
            [0] = 'Unknown',
            [1] = 'Standard Output Sensitivity',
            [2] = 'Recommended Exposure Index',
            [3] = 'ISO Speed',
            [4] = 'Standard Output Sensitivity and Recommended Exposure Index',
            [5] = 'Standard Output Sensitivity and ISO Speed',
            [6] = 'Recommended Exposure Index and ISO Speed',
            [7] = 'Standard Output Sensitivity, Recommended Exposure Index and ISO Speed',
        },
    },
    StandardOutputSensitivity = { Writable = 'integer' },
    RecommendedExposureIndex = { Writable = 'integer' },
    ISOSpeed = { Writable = 'integer' },
    ISOSpeedLatitudeyyy = { Description = 'ISO Speed Latitude yyy', Writable = 'integer' },
    ISOSpeedLatitudezzz = { Description = 'ISO Speed Latitude zzz', Writable = 'integer' },
    CameraOwnerName = { Name = 'OwnerName' },
    BodySerialNumber = { Name = 'SerialNumber', Groups = { [2] = 'Camera' } },
    LensSpecification = {
        Name = 'LensInfo',
        Writable = 'rational',
        Groups = { [2] = 'Camera' },
        List = 'Seq',
        RawJoin = 1, -- join list into a string before ValueConv
        ValueConv = function(_self, val) return XMP.ConvertRationalList(val) end,
        ValueConvInv = function(_self, val)
            local vals = perl.split(' ', val)
            if #vals ~= 4 then return val end
            for i, v in ipairs(vals) do
                if v == 'inf' then
                    vals[i] = '1/0'
                elseif v == 'undef' then
                    vals[i] = '0/0'
                else
                    if not require('lexiftool').IsFloat(v) then return val end
                    vals[i] = perl.join('/', { require('lexiftool.Writer').Rationalize(v) })
                end
            end
            return vals -- return list reference (List-type tag)
        end,
        PrintConv = function(_self, val) return require('lexiftool.Exif').PrintLensInfo(val) end,
        PrintConvInv = function(_self, val) return require('lexiftool.WriteExif').ConvertLensInfo(val) end,
        Notes = [[
            unfortunately the EXIF 2.3 for XMP specification defined this new tag
            instead of using the existing XMP-aux:LensInfo
        ]],
    },
    LensMake = { Groups = { [2] = 'Camera' } },
    LensModel = { Groups = { [2] = 'Camera' } },
    LensSerialNumber = { Groups = { [2] = 'Camera' } },
    InteroperabilityIndex = {
        Name = 'InteropIndex',
        Description = 'Interoperability Index',
        PrintConv = {
            R98 = 'R98 - DCF basic file (sRGB)',
            R03 = 'R03 - DCF option file (Adobe RGB)',
            THM = 'THM - DCF thumbnail file',
        },
    },
    -- new in Exif 2.31
    Temperature = { Writable = 'rational', Name = 'AmbientTemperature' },
    Humidity = { Writable = 'rational' },
    Pressure = { Writable = 'rational' },
    WaterDepth = { Writable = 'rational' },
    Acceleration = { Writable = 'rational' },
    CameraElevationAngle = { Writable = 'rational' },
    -- new in Exif 2.32
    CompositeImage = {
        Writable = 'integer',
        PrintConv = {
            [0] = 'Unknown',
            [1] = 'Not a Composite Image',
            [2] = 'General Composite Image',
            [3] = 'Composite Image Captured While Shooting',
        },
    },
    CompositeImageCount = { List = 'Seq', Writable = 'integer' },
    CompositeImageExposureTimes = {
        FlatName = 'CompImage',
        Struct = {
            STRUCT_NAME = 'CompImageExp',
            NAMESPACE = 'exifEX',
            TotalExposurePeriod     = { Writable = 'rational' },
            SumOfExposureTimesOfAll = { Writable = 'rational', FlatName = 'SumExposureAll' },
            SumOfExposureTimesOfUsed= { Writable = 'rational', FlatName = 'SumExposureUsed' },
            MaxExposureTimesOfAll   = { Writable = 'rational', FlatName = 'MaxExposureAll' },
            MaxExposureTimesOfUsed  = { Writable = 'rational', FlatName = 'MaxExposureUsed' },
            MinExposureTimesOfAll   = { Writable = 'rational', FlatName = 'MinExposureAll'  },
            MinExposureTimesOfUsed  = { Writable = 'rational', FlatName = 'MinExposureUsed' },
            NumberOfSequences       = { Writable = 'integer',  FlatName = 'NumSequences' },
            NumberOfImagesInSequences= { Writable = 'integer',  FlatName = 'ImagesPerSequence' },
            Values =   { List = 'Seq', Writable = 'rational' },
        },
    },
    -- new in Exif 3.0
    ImageUniqueID = {},
    ImageTitle = {},
    ImageEditor = {},
    Photographer = { Groups = { [2] = 'Author' } },
    CameraFirmware = { Groups = { [2] = 'Camera' } },
    RAWDevelopingSoftware = {},
    ImageEditingSoftware = {},
    MetadataEditingSoftware = {},
}

-- Adobe Lightroom namespace properties (lr) (ref PH)
XMP.Lightroom = xmpTableDefaults {
    GROUPS = { [1] = 'XMP-lr', [2] = 'Image' },
    NAMESPACE = 'lr',
    TABLE_DESC = 'XMP Adobe Lightroom',
    NOTES = 'Adobe Lightroom "lr" namespace tags.',
    privateRTKInfo = { },
    hierarchicalSubject = { List = 'Bag' },
    weightedFlatSubject = { List = 'Bag' },
}

-- Adobe Album namespace properties (album)
XMP.Album = xmpTableDefaults {
    GROUPS = { [1] = 'XMP-album', [2] = 'Image' },
    NAMESPACE = 'album',
    TABLE_DESC = 'XMP Adobe Album',
    NOTES = 'Adobe Album namespace tags.',
    Notes = {},
}

-- ExifTool namespace properties (et)
XMP.ExifTool = xmpTableDefaults {
    GROUPS = { [1] = 'XMP-et', [2] = 'Image' },
    NAMESPACE   = 'et',
    OriginalImageHash     = { Notes = 'used to store ExifTool ImageDataHash digest' },
    OriginalImageHashType = { Notes = "ImageHashType API setting, default 'MD5'" },
    OriginalImageMD5      = { Notes = 'deprecated' },
}

-- IPTC Core namespace properties (Iptc4xmpCore) (ref 4)
XMP.iptcCore = xmpTableDefaults {
    GROUPS = { [1] = 'XMP-iptcCore', [2] = 'Author' },
    NAMESPACE = 'Iptc4xmpCore',
    TABLE_DESC = 'XMP IPTC Core',
    NOTES = [[
        IPTC Core namespace tags.  The actual IPTC Core namespace prefix is
        "Iptc4xmpCore", which is the prefix recorded in the file, but ExifTool
        shortens this for the family 1 group name. (see
        L<http://www.iptc.org/IPTC4XMP/>)
    ]],
    CountryCode = { Groups = { [2] = 'Location' } },
    CreatorContactInfo = {
        Struct = {
            STRUCT_NAME = 'ContactInfo',
            NAMESPACE = 'Iptc4xmpCore',
            CiAdrCity = {},
            CiAdrCtry = {},
            CiAdrExtadr = {},
            CiAdrPcode = {},
            CiAdrRegion = {},
            CiEmailWork = {},
            CiTelWork = {},
            CiUrlWork = {},
        },
    },
    CreatorContactInfoCiAdrCity = { Flat = 1, Name = 'CreatorCity' },
    CreatorContactInfoCiAdrCtry = { Flat = 1, Name = 'CreatorCountry' },
    CreatorContactInfoCiAdrExtadr = { Flat = 1, Name = 'CreatorAddress' },
    CreatorContactInfoCiAdrPcode = { Flat = 1, Name = 'CreatorPostalCode' },
    CreatorContactInfoCiAdrRegion = { Flat = 1, Name = 'CreatorRegion' },
    CreatorContactInfoCiEmailWork = { Flat = 1, Name = 'CreatorWorkEmail' },
    CreatorContactInfoCiTelWork = { Flat = 1, Name = 'CreatorWorkTelephone' },
    CreatorContactInfoCiUrlWork = { Flat = 1, Name = 'CreatorWorkURL' },
    IntellectualGenre = { Groups = { [2] = 'Other' } },
    Location = { Groups = { [2] = 'Location' } },
    Scene = { Groups = { [2] = 'Other' }, List = 'Bag' },
    SubjectCode = { Groups = { [2] = 'Other' }, List = 'Bag' },
    -- new IPTC Core 1.3 properties
    AltTextAccessibility = { Groups = { [2] = 'Other' }, Writable = 'lang-alt' },
    ExtDescrAccessibility = { Groups = { [2] = 'Other' }, Writable = 'lang-alt' },
}

-- Generic XML namespace (upstream %XMP::XML, used for the `xml ` boxes in
-- JPEG 2000 files and the lastUpdate property found in Sony MP4s)
XMP.XML = {
    GROUPS = { [0] = 'XML', [1] = 'XML', [2] = 'Unknown' },
    PROCESS_PROC = false, -- set below to XMP.ProcessXMP
    dc = {
        Name = 'dc',
        SubDirectory = { TagTable = 'lexiftool.XMP.dc' },
    },
    lastUpdate = {
        Groups = { [2] = 'Time' },
        ValueConv = function(_self, val) return XMP.ConvertXMPDate(val) end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
}

-- Photoshop Camera Raw namespace properties (crs) - (ref 8,PH)
-- (Upstream defines 'GrainSeed' twice: a bare `{ }` at its "more again"
--  position, later overridden by `{ Writable => 'integer' }` further down --
--  a later Perl hash-literal key always wins.  Lua behaves the same way for
--  a duplicate constructor key, but luacheck rejects it, so only the final
--  `integer` definition is kept, at the first of the two positions.)
XMP.crs = xmpTableDefaults {
    GROUPS = { [1] = 'XMP-crs', [2] = 'Image' },
    NAMESPACE = 'crs',
    TABLE_DESC = 'Photoshop Camera Raw namespace',
    NOTES = [[
        Photoshop Camera Raw namespace tags.  It is a shame that Adobe pollutes the
        metadata space with these incredibly bulky image editing parameters.
    ]],
    AlreadyApplied = { Writable = 'boolean' },
    AutoBrightness = { Writable = 'boolean' },
    AutoContrast = { Writable = 'boolean' },
    AutoExposure = { Writable = 'boolean' },
    AutoShadows = { Writable = 'boolean' },
    BlueHue = { Writable = 'integer' },
    BlueSaturation = { Writable = 'integer' },
    Brightness = { Writable = 'integer' },
    CameraProfile = { },
    ChromaticAberrationB = { Writable = 'integer' },
    ChromaticAberrationR = { Writable = 'integer' },
    ColorNoiseReduction = { Writable = 'integer' },
    Contrast = { Writable = 'integer', Avoid = 1 },
    Converter = { },
    CropTop = { Writable = 'real' },
    CropLeft = { Writable = 'real' },
    CropBottom = { Writable = 'real' },
    CropRight = { Writable = 'real' },
    CropAngle = { Writable = 'real' },
    CropWidth = { Writable = 'real' },
    CropHeight = { Writable = 'real' },
    CropUnits = { Writable = 'integer', PrintConv = { [0] = 'pixels', [1] = 'inches', [2] = 'cm' } },
    Exposure = { Writable = 'real' },
    GreenHue = { Writable = 'integer' },
    GreenSaturation = { Writable = 'integer' },
    HasCrop = { Writable = 'boolean' },
    HasSettings = { Writable = 'boolean' },
    LuminanceSmoothing = { Writable = 'integer' },
    MoireFilter = { PrintConv = { Off = 'Off', On = 'On' } },
    RawFileName = { },
    RedHue = { Writable = 'integer' },
    RedSaturation = { Writable = 'integer' },
    Saturation = { Writable = 'integer', Avoid = 1 },
    Shadows = { Writable = 'integer' },
    ShadowTint = { Writable = 'integer' },
    Sharpness = { Writable = 'integer', Avoid = 1 },
    Smoothness = { Writable = 'integer' },
    Temperature = { Writable = 'integer', Name = 'ColorTemperature' },
    Tint = { Writable = 'integer' },
    ToneCurve = { List = 'Seq' },
    ToneCurveName = { PrintConv = {
        Linear = 'Linear', ['Medium Contrast'] = 'Medium Contrast',
        ['Strong Contrast'] = 'Strong Contrast', Custom = 'Custom',
    } },
    Version = { },
    VignetteAmount = { Writable = 'integer' },
    VignetteMidpoint = { Writable = 'integer' },
    WhiteBalance = { Avoid = 1, PrintConv = {
        ['As Shot'] = 'As Shot', Auto = 'Auto', Daylight = 'Daylight', Cloudy = 'Cloudy',
        Shade = 'Shade', Tungsten = 'Tungsten', Fluorescent = 'Fluorescent', Flash = 'Flash', Custom = 'Custom',
    } },
    CameraProfileDigest = { },
    Clarity = { Writable = 'integer' },
    ConvertToGrayscale = { Writable = 'boolean' },
    Defringe = { Writable = 'integer' },
    FillLight = { Writable = 'integer' },
    HighlightRecovery = { Writable = 'integer' },
    HueAdjustmentAqua = { Writable = 'integer' },
    HueAdjustmentBlue = { Writable = 'integer' },
    HueAdjustmentGreen = { Writable = 'integer' },
    HueAdjustmentMagenta = { Writable = 'integer' },
    HueAdjustmentOrange = { Writable = 'integer' },
    HueAdjustmentPurple = { Writable = 'integer' },
    HueAdjustmentRed = { Writable = 'integer' },
    HueAdjustmentYellow = { Writable = 'integer' },
    IncrementalTemperature = { Writable = 'integer' },
    IncrementalTint = { Writable = 'integer' },
    LuminanceAdjustmentAqua = { Writable = 'integer' },
    LuminanceAdjustmentBlue = { Writable = 'integer' },
    LuminanceAdjustmentGreen = { Writable = 'integer' },
    LuminanceAdjustmentMagenta = { Writable = 'integer' },
    LuminanceAdjustmentOrange = { Writable = 'integer' },
    LuminanceAdjustmentPurple = { Writable = 'integer' },
    LuminanceAdjustmentRed = { Writable = 'integer' },
    LuminanceAdjustmentYellow = { Writable = 'integer' },
    ParametricDarks = { Writable = 'integer' },
    ParametricHighlights = { Writable = 'integer' },
    ParametricHighlightSplit = { Writable = 'integer' },
    ParametricLights = { Writable = 'integer' },
    ParametricMidtoneSplit = { Writable = 'integer' },
    ParametricShadows = { Writable = 'integer' },
    ParametricShadowSplit = { Writable = 'integer' },
    SaturationAdjustmentAqua = { Writable = 'integer' },
    SaturationAdjustmentBlue = { Writable = 'integer' },
    SaturationAdjustmentGreen = { Writable = 'integer' },
    SaturationAdjustmentMagenta = { Writable = 'integer' },
    SaturationAdjustmentOrange = { Writable = 'integer' },
    SaturationAdjustmentPurple = { Writable = 'integer' },
    SaturationAdjustmentRed = { Writable = 'integer' },
    SaturationAdjustmentYellow = { Writable = 'integer' },
    SharpenDetail = { Writable = 'integer' },
    SharpenEdgeMasking = { Writable = 'integer' },
    SharpenRadius = { Writable = 'real' },
    SplitToningBalance = { Writable = 'integer', Notes = 'also used for newer ColorGrade settings' },
    SplitToningHighlightHue = { Writable = 'integer', Notes = 'also used for newer ColorGrade settings' },
    SplitToningHighlightSaturation = { Writable = 'integer', Notes = 'also used for newer ColorGrade settings' },
    SplitToningShadowHue = { Writable = 'integer', Notes = 'also used for newer ColorGrade settings' },
    SplitToningShadowSaturation = { Writable = 'integer', Notes = 'also used for newer ColorGrade settings' },
    Vibrance = { Writable = 'integer' },
    GrayMixerRed = { Writable = 'integer' },
    GrayMixerOrange = { Writable = 'integer' },
    GrayMixerYellow = { Writable = 'integer' },
    GrayMixerGreen = { Writable = 'integer' },
    GrayMixerAqua = { Writable = 'integer' },
    GrayMixerBlue = { Writable = 'integer' },
    GrayMixerPurple = { Writable = 'integer' },
    GrayMixerMagenta = { Writable = 'integer' },
    RetouchInfo = { List = 'Seq' },
    RedEyeInfo = { List = 'Seq' },
    CropUnit = { Writable = 'integer', PrintConv = { [0] = 'pixels', [1] = 'inches', [2] = 'cm' } },
    PostCropVignetteAmount = { Writable = 'integer' },
    PostCropVignetteMidpoint = { Writable = 'integer' },
    PostCropVignetteFeather = { Writable = 'integer' },
    PostCropVignetteRoundness = { Writable = 'integer' },
    PostCropVignetteStyle = { Writable = 'integer', PrintConv = {
        [1] = 'Highlight Priority', [2] = 'Color Priority', [3] = 'Paint Overlay',
    } },
    -- disable List behaviour of flattened Gradient/PaintBasedCorrections
    -- because these are nested in lists and the flattened tags can't
    -- do justice to this complex structure
    GradientBasedCorrections = {
        FlatName = 'GradientBasedCorr',
        Struct = sCorrection,
        List = 'Seq',
    },
    GradientBasedCorrectionsCorrectionMasks = {
        Name = 'GradientBasedCorrMasks',
        FlatName = 'GradientBasedCorrMask',
        Flat = 1
    },
    GradientBasedCorrectionsCorrectionMasksDabs = {
        Name = 'GradientBasedCorrMaskDabs',
        Flat = 1, List = 0,
    },
    PaintBasedCorrections = {
        FlatName = 'PaintCorrection',
        Struct = sCorrection,
        List = 'Seq',
    },
    PaintBasedCorrectionsCorrectionMasks = {
        Name = 'PaintBasedCorrectionMasks',
        FlatName = 'PaintCorrectionMask',
        Flat = 1,
    },
    PaintBasedCorrectionsCorrectionMasksDabs = {
        Name = 'PaintCorrectionMaskDabs',
        Flat = 1, List = 0,
    },
    -- new tags written by LR 3 (thanks Wolfgang Guelcker)
    ProcessVersion = { },
    LensProfileEnable = { Writable = 'integer' },
    LensProfileSetup = { },
    LensProfileName = { },
    LensProfileFilename = { },
    LensProfileDigest = { },
    LensProfileDistortionScale = { Writable = 'integer' },
    LensProfileChromaticAberrationScale = { Writable = 'integer' },
    LensProfileVignettingScale = { Writable = 'integer' },
    LensManualDistortionAmount = { Writable = 'integer' },
    PerspectiveVertical = { Writable = 'integer' },
    PerspectiveHorizontal = { Writable = 'integer' },
    PerspectiveRotate = { Writable = 'real' },
    PerspectiveScale = { Writable = 'integer' },
    CropConstrainToWarp = { Writable = 'integer' },
    LuminanceNoiseReductionDetail = { Writable = 'integer' },
    LuminanceNoiseReductionContrast = { Writable = 'integer' },
    ColorNoiseReductionDetail = { Writable = 'integer' },
    GrainAmount = { Writable = 'integer' },
    GrainSize = { Writable = 'integer' },
    GrainFrequency = { Writable = 'integer' },
    AutoLateralCA = { Writable = 'integer' },
    Exposure2012 = { Writable = 'real' },
    Contrast2012 = { Writable = 'integer' },
    Highlights2012 = { Writable = 'integer' },
    Highlight2012 = { Writable = 'integer' },
    Shadows2012 = { Writable = 'integer' },
    Whites2012 = { Writable = 'integer' },
    Blacks2012 = { Writable = 'integer' },
    Clarity2012 = { Writable = 'integer' },
    PostCropVignetteHighlightContrast = { Writable = 'integer' },
    ToneCurveName2012 = { },
    ToneCurveRed = { List = 'Seq' },
    ToneCurveGreen = { List = 'Seq' },
    ToneCurveBlue = { List = 'Seq' },
    ToneCurvePV2012 = { List = 'Seq' },
    ToneCurvePV2012Red = { List = 'Seq' },
    ToneCurvePV2012Green = { List = 'Seq' },
    ToneCurvePV2012Blue = { List = 'Seq' },
    DefringePurpleAmount = { Writable = 'integer' },
    DefringePurpleHueLo = { Writable = 'integer' },
    DefringePurpleHueHi = { Writable = 'integer' },
    DefringeGreenAmount = { Writable = 'integer' },
    DefringeGreenHueLo = { Writable = 'integer' },
    DefringeGreenHueHi = { Writable = 'integer' },
    AutoWhiteVersion = { Writable = 'integer' },
    CircularGradientBasedCorrections = {
        FlatName = 'CircGradBasedCorr',
        Struct = sCorrection,
        List = 'Seq',
    },
    CircularGradientBasedCorrectionsCorrectionMasks = {
        Name = 'CircGradBasedCorrMasks',
        FlatName = 'CircGradBasedCorrMask',
        Flat = 1
    },
    CircularGradientBasedCorrectionsCorrectionMasksDabs = {
        Name = 'CircGradBasedCorrMaskDabs',
        Flat = 1, List = 0,
    },
    ColorNoiseReductionSmoothness = { Writable = 'integer' },
    PerspectiveAspect = { Writable = 'integer' },
    PerspectiveUpright = { Writable = 'integer', PrintConv = {
        [0] = 'Off', [1] = 'Auto', [2] = 'Full', [3] = 'Level', [4] = 'Vertical', [5] = 'Guided',
    } },
    RetouchAreas = {
        FlatName = 'RetouchArea',
        Struct = sRetouchArea,
        List = 'Seq',
    },
    RetouchAreasMasks = {
        Name = 'RetouchAreaMasks',
        FlatName = 'RetouchAreaMask',
        Flat = 1
    },
    RetouchAreasMasksDabs = {
        Name = 'RetouchAreaMaskDabs',
        Flat = 1, List = 0,
    },
    UprightVersion = { Writable = 'integer' },
    UprightCenterMode = { Writable = 'integer' },
    UprightCenterNormX = { Writable = 'real' },
    UprightCenterNormY = { Writable = 'real' },
    UprightFocalMode = { Writable = 'integer' },
    UprightFocalLength35mm = { Writable = 'real' },
    UprightPreview = { Writable = 'boolean' },
    UprightTransformCount = { Writable = 'integer' },
    UprightDependentDigest = { },
    UprightGuidedDependentDigest = { },
    UprightTransform_0 = { },
    UprightTransform_1 = { },
    UprightTransform_2 = { },
    UprightTransform_3 = { },
    UprightTransform_4 = { },
    UprightTransform_5 = { },
    UprightFourSegments_0 = { },
    UprightFourSegments_1 = { },
    UprightFourSegments_2 = { },
    UprightFourSegments_3 = { },
    What = { },
    LensProfileMatchKeyExifMake = { },
    LensProfileMatchKeyExifModel = { },
    LensProfileMatchKeyCameraModelName = { },
    LensProfileMatchKeyLensInfo = { },
    LensProfileMatchKeyLensID = { },
    LensProfileMatchKeyLensName = { },
    LensProfileMatchKeyIsRaw = { Writable = 'boolean' },
    LensProfileMatchKeySensorFormatFactor = { Writable = 'real' },
    DefaultAutoTone = { Writable = 'boolean' },
    DefaultAutoGray = { Writable = 'boolean' },
    DefaultsSpecificToSerial = { Writable = 'boolean' },
    DefaultsSpecificToISO = { Writable = 'boolean' },
    DNGIgnoreSidecars = { Writable = 'boolean' },
    NegativeCachePath = { },
    NegativeCacheMaximumSize = { Writable = 'real' },
    NegativeCacheLargePreviewSize = { Writable = 'integer' },
    JPEGHandling = { },
    TIFFHandling = { },
    Dehaze = { Writable = 'real' },
    ToneMapStrength = { Writable = 'real' },
    PerspectiveX = { Writable = 'real' },
    PerspectiveY = { Writable = 'real' },
    UprightFourSegmentsCount = { Writable = 'integer' },
    AutoTone = { Writable = 'boolean' },
    Texture = { Writable = 'integer' },
    OverrideLookVignette = { Writable = 'boolean' },
    Look = {
        Struct = {
            STRUCT_NAME = 'Look',
            NAMESPACE   = 'crs',
            Name        = { },
            Amount      = { },
            Cluster     = { },
            UUID        = { },
            SupportsMonochrome = { },
            SupportsAmount     = { },
            SupportsOutputReferred = { },
            Copyright   = { },
            Group       = { Writable = 'lang-alt' },
            Parameters = {
                Struct = {
                    STRUCT_NAME = 'LookParms',
                    NAMESPACE   = 'crs',
                    Version         = { },
                    ProcessVersion  = { },
                    Clarity2012     = { },
                    ConvertToGrayscale = { },
                    CameraProfile   = { },
                    LookTable       = { },
                    ToneCurvePV2012 = { List = 'Seq' },
                    ToneCurvePV2012Red   = { List = 'Seq' },
                    ToneCurvePV2012Green = { List = 'Seq' },
                    ToneCurvePV2012Blue  = { List = 'Seq' },
                    Highlights2012  = { },
                    Shadows2012     = { },
                },
            },
        }
    },
    -- more again (ref forum11258)
    GrainSeed = { Writable = 'integer' },
    ClipboardOrientation = { Writable = 'integer' },
    ClipboardAspectRatio = { Writable = 'integer' },
    PresetType = { },
    Cluster = { },
    UUID = { Avoid = 1 },
    SupportsAmount = { Writable = 'boolean' },
    SupportsColor = { Writable = 'boolean' },
    SupportsMonochrome = { Writable = 'boolean' },
    SupportsHighDynamicRange = { Writable = 'boolean' },
    SupportsNormalDynamicRange = { Writable = 'boolean' },
    SupportsSceneReferred = { Writable = 'boolean' },
    SupportsOutputReferred = { Writable = 'boolean' },
    CameraModelRestriction = { },
    Copyright = { Avoid = 1 },
    ContactInfo = { },
    Name = { Writable = 'lang-alt', Avoid = 1 },
    ShortName = { Writable = 'lang-alt' },
    SortName = { Writable = 'lang-alt' },
    Group = { Writable = 'lang-alt', Avoid = 1 },
    Description = { Writable = 'lang-alt', Avoid = 1 },
    -- new for DNG converter 13.0
    LookName = { NotFlat = 1 }, -- (grr... conflicts with "Name" element of "Look" struct!)
    -- new for Lightroom CC 2021 (ref forum11745)
    ColorGradeMidtoneHue = { Writable = 'integer' },
    ColorGradeMidtoneSat = { Writable = 'integer' },
    ColorGradeShadowLum = { Writable = 'integer' },
    ColorGradeMidtoneLum = { Writable = 'integer' },
    ColorGradeHighlightLum = { Writable = 'integer' },
    ColorGradeBlending = { Writable = 'integer' },
    ColorGradeGlobalHue = { Writable = 'integer' },
    ColorGradeGlobalSat = { Writable = 'integer' },
    ColorGradeGlobalLum = { Writable = 'integer' },
    LensProfileIsEmbedded = { Writable = 'boolean' },
    AutoToneDigest = { },
    AutoToneDigestNoSat = { },
    ToggleStyleDigest = { },
    ToggleStyleAmount = { Writable = 'integer' },
    -- new for LightRoom 11.0
    CompatibleVersion = { },
    MaskGroupBasedCorrections = {
        FlatName = 'MaskGroupBasedCorr',
        Struct = sCorrection,
        List = 'Seq',
    },
    RangeMaskMapInfo = { Name = 'RangeMask', Struct = sRangeMask, FlatName = 'RangeMask' },
    -- new for ACR 15.1 (not sure if these are integer or real, so just guess)
    HDREditMode = { Writable = 'integer' },
    SDRBrightness = { Writable = 'real' },
    SDRContrast = { Writable = 'real' },
    SDRHighlights = { Writable = 'real' },
    SDRShadows = { Writable = 'real' },
    SDRWhites = { Writable = 'real' },
    SDRBlend = { Writable = 'real' },
    -- new for ACR 16 (ref forum15305)
    LensBlur = {
        Struct = {
            STRUCT_NAME     = 'LensBlur',
            NAMESPACE       = 'crs',
            -- (Note: all the following 'real' values could be limited to 'integer')
            Active          = { Writable = 'boolean' },
            BlurAmount      = { FlatName = 'Amount', Writable = 'real' },
            BokehAspect     = { Writable = 'real' },
            BokehRotation   = { Writable = 'real' },
            BokehShape      = { Writable = 'real' },
            BokehShapeDetail = { Writable = 'real' },
            CatEyeAmount    = { Writable = 'real' },
            CatEyeScale     = { Writable = 'real' },
            FocalRange      = { }, -- (eg. "-48 32 64 144")
            FocalRangeSource = { Writable = 'real' },
            HighlightsBoost = { Writable = 'real' },
            HighlightsThreshold = { Writable = 'real' },
            SampledArea     = { }, -- (eg. "0.500000 0.500000 0.500000 0.500000")
            SampledRange    = { }, -- (eg. "0 0")
            SphericalAberration = { Writable = 'real' },
            SubjectRange    = { }, -- (eg. "0 57");
            Version         = { },
         },
    },
    DepthMapInfo = {
        Struct = {
            STRUCT_NAME     = 'DepthMapInfo',
            NAMESPACE       = 'crs',
            BaseHighlightGuideInputDigest = { },
            BaseHighlightGuideTable     = { },
            BaseHighlightGuideVersion   = { },
            BaseLayeredDepthInputDigest = { },
            BaseLayeredDepthTable       = { },
            BaseLayeredDepthVersion     = { },
            BaseRawDepthInputDigest     = { },
            BaseRawDepthTable           = { },
            BaseRawDepthVersion         = { },
            DepthSource                 = { },
        },
    },
    DepthBasedCorrections = {
        List = 'Seq',
        FlatName = 'DepthBasedCorr',
        Struct = {
            STRUCT_NAME      = 'DepthBasedCorr',
            NAMESPACE        = 'crs',
            CorrectionActive = { Writable = 'boolean' },
            CorrectionAmount = { Writable = 'real' },
            CorrectionMasks  = { FlatName = 'Mask', List = 'Seq', Struct = sCorrectionMask },
            CorrectionSyncID = { },
            LocalCorrectedDepth = {  Writable = 'real' },
            LocalCurveRefineSaturation = { Writable = 'real' },
            What             = { },
        },
    },
    -- more new stuff
    PointColors = { List = 'Seq' },
    ColorVariance = { Writable = 'real', List = 'Seq' },
    CropConstrainToUnitSquare = { Writable = 'integer' },
    HDRMaxValue = { Writable = 'real' },
}

-- Tiff namespace properties (tiff)
XMP.tiff = xmpTableDefaults {
    GROUPS = { [1] = 'XMP-tiff', [2] = 'Image' },
    NAMESPACE   = 'tiff',
    PRIORITY = 0, -- not as reliable as actual TIFF tags
    TABLE_DESC = 'XMP TIFF',
    NOTES = [[
        EXIF namespace for TIFF tags.  See
        L<https://web.archive.org/web/20180921145139if_/http://www.cipa.jp:80/std/documents/e/DC-010-2017_E.pdf>
        for the specification.
    ]],
    ImageWidth    = { Writable = 'integer' },
    ImageLength   = { Writable = 'integer', Name = 'ImageHeight' },
    BitsPerSample = { Writable = 'integer', List = 'Seq', AutoSplit = 1 },
    Compression = {
        Writable = 'integer',
        SeparateTable = 'EXIF Compression',
        PrintConv = Exif.compression,
    },
    PhotometricInterpretation = {
        Writable = 'integer',
        PrintConv = Exif.photometricInterpretation,
    },
    Orientation = {
        Writable = 'integer',
        PrintConv = Exif.orientation,
    },
    SamplesPerPixel = { Writable = 'integer' },
    PlanarConfiguration = {
        Writable = 'integer',
        PrintConv = {
            [1] = 'Chunky',
            [2] = 'Planar',
        },
    },
    YCbCrSubSampling = {
        Writable = 'integer',
        List = 'Seq',
        -- join the raw values before conversion to allow PrintConv to operate on
        -- the combined string as it does for the corresponding EXIF tag
        RawJoin = 1,
        Notes = [[
            while technically this is a list-type tag, for compatibility with its EXIF
            counterpart it is written and read as a simple string
        ]],
        PrintConv = JPEG.yCbCrSubSampling,
    },
    YCbCrPositioning = {
        Writable = 'integer',
        PrintConv = {
            [1] = 'Centered',
            [2] = 'Co-sited',
        },
    },
    XResolution = { Writable = 'rational' },
    YResolution = { Writable = 'rational' },
    ResolutionUnit = {
        Writable = 'integer',
        Notes = 'the value 1 is not standard EXIF',
        PrintConv = {
            [1] = 'None',
            [2] = 'inches',
            [3] = 'cm',
        },
    },
    TransferFunction      = { Writable = 'integer',  List = 'Seq', AutoSplit = 1 },
    WhitePoint            = { Writable = 'rational', List = 'Seq', AutoSplit = 1 },
    PrimaryChromaticities = { Writable = 'rational', List = 'Seq', AutoSplit = 1 },
    YCbCrCoefficients     = { Writable = 'rational', List = 'Seq', AutoSplit = 1 },
    ReferenceBlackWhite   = { Writable = 'rational', List = 'Seq', AutoSplit = 1 },
    DateTime = {
        Description = 'Date/Time Modified',
        Groups = { [2] = 'Time' },
        Writable = 'date', Shift = 'Time',
        Validate = dateTimeInfo.Validate,
        PrintConv = dateTimeInfo.PrintConv,
        PrintConvInv = dateTimeInfo.PrintConvInv,
    },
    ImageDescription = { Writable = 'lang-alt' },
    Make = {
        Groups = { [2] = 'Camera' },
        RawConv = function(self, val)
            if perl.truthy(self.Make) then return val end
            self.Make = val
            return val
        end,
    },
    Model = {
        Groups = { [2] = 'Camera' },
        Description = 'Camera Model Name',
        RawConv = function(self, val)
            if perl.truthy(self.Model) then return val end
            self.Model = val
            return val
        end,
    },
    Software = {},
    Artist = { Groups = { [2] = 'Author' } },
    Copyright = { Groups = { [2] = 'Author' }, Writable = 'lang-alt' },
    NativeDigest = { Avoid = 1 }, -- #PH
}

-- Exif namespace properties (exif) -- pragmatic subset: only the fields
-- actually exercised so far; the upstream table has ~170 entries
-- (mirroring most of Exif.pm), not all ported here
XMP.exif = xmpTableDefaults {
    GROUPS = { [1] = 'XMP-exif', [2] = 'Image' },
    NAMESPACE = 'exif',
    PRIORITY = 0, -- not as reliable as actual EXIF tags
    NOTES = [[
        EXIF namespace for EXIF tags.  See
        L<https://web.archive.org/web/20180921145139if_/http://www.cipa.jp:80/std/documents/e/DC-010-2017_E.pdf>
        for the specification.
    ]],
    ExifVersion = {},
    FlashpixVersion = {},
    ColorSpace = {
        Writable = 'integer',
        -- (some applications incorrectly write -1 as a long integer)
        ValueConv = function(_self, val) return perl.num(val) == 0xffffffff and 0xffff or val end,
        ValueConvInv = function(_self, val) return val end,
        PrintConv = { [1] = 'sRGB', [2] = 'Adobe RGB', [0xffff] = 'Uncalibrated' },
    },
    ComponentsConfiguration = {
        Writable = 'integer',
        List = 'Seq',
        AutoSplit = 1,
        PrintConvColumns = 2,
        PrintConv = {
            [0] = '-',
            [1] = 'Y',
            [2] = 'Cb',
            [3] = 'Cr',
            [4] = 'R',
            [5] = 'G',
            [6] = 'B',
        },
    },
    CompressedBitsPerPixel = { Writable = 'rational' },
    PixelXDimension = { Name = 'ExifImageWidth', Writable = 'integer' },
    PixelYDimension = { Name = 'ExifImageHeight', Writable = 'integer' },
    MakerNote = {},
    UserComment = { Writable = 'lang-alt' },
    RelatedSoundFile = {},
    DateTimeOriginal = {
        Description = 'Date/Time Original',
        Groups = { [2] = 'Time' },
        Writable = 'date', Shift = 'Time',
        Validate = dateTimeInfo.Validate,
        PrintConv = dateTimeInfo.PrintConv,
        PrintConvInv = dateTimeInfo.PrintConvInv,
    },
    DateTimeDigitized = { -- (EXIF tag named CreateDate, but this exists in XMP-xmp)
        Description = 'Date/Time Digitized',
        Groups = { [2] = 'Time' },
        Writable = 'date', Shift = 'Time',
        Validate = dateTimeInfo.Validate,
        PrintConv = dateTimeInfo.PrintConv,
        PrintConvInv = dateTimeInfo.PrintConvInv,
    },
    ExposureTime = {
        Writable = 'rational',
        PrintConv = function(_self, val) return require('lexiftool.Exif').PrintExposureTime(val) end,
        PrintConvInv = function(_self, val) return val end,
    },
    FNumber = {
        Writable = 'rational',
        PrintConv = function(_self, val) return require('lexiftool.Exif').PrintFNumber(val) end,
        PrintConvInv = function(_self, val) return val end,
    },
    ExposureProgram = {
        Groups = { [2] = 'Camera' },
        Writable = 'integer',
        PrintConv = {
            [0] = 'Not Defined',
            [1] = 'Manual',
            [2] = 'Program AE',
            [3] = 'Aperture-priority AE',
            [4] = 'Shutter speed priority AE',
            [5] = 'Creative (Slow speed)',
            [6] = 'Action (High speed)',
            [7] = 'Portrait',
            [8] = 'Landscape',
        },
    },
    SpectralSensitivity = { Groups = { [2] = 'Camera' } },
    ISOSpeedRatings = {
        Name = 'ISO',
        Writable = 'integer',
        List = 'Seq',
        AutoSplit = 1,
        Notes = 'deprecated',
    },
    OECF = {
        Name = 'Opto-ElectricConvFactor',
        FlatName = 'OECF',
        Groups = { [2] = 'Camera' },
        Struct = sOECF,
    },
    ShutterSpeedValue = {
        Writable = 'rational',
        ValueConv = function(_self, val)
            val = perl.num(val)
            return math.abs(val) < 100 and (1 / (2 ^ val)) or 0
        end,
        PrintConv = function(_self, val) return require('lexiftool.Exif').PrintExposureTime(val) end,
        ValueConvInv = function(_self, val)
            val = perl.num(val)
            if val > 0 then return -math.log(val) / math.log(2) end
            return 0
        end,
        PrintConvInv = function(_self, val) return require('lexiftool.Exif').ConvertFraction(val) end,
    },
    ApertureValue = {
        Writable = 'rational',
        ValueConv = function(_self, val) return math.sqrt(2) ^ perl.num(val) end,
        PrintConv = function(_self, val) return sprintf('%.1f', val) end,
        ValueConvInv = function(_self, val)
            val = perl.num(val)
            if val > 0 then return 2 * math.log(val) / math.log(2) end
            return 0
        end,
        PrintConvInv = function(_self, val) return val end,
    },
    BrightnessValue = { Writable = 'rational' },
    ExposureBiasValue = {
        Name = 'ExposureCompensation',
        Writable = 'rational',
        PrintConv = function(_self, val) return require('lexiftool.Exif').PrintFraction(val) end,
        PrintConvInv = function(_self, val) return val end,
    },
    MaxApertureValue = {
        Groups = { [2] = 'Camera' },
        Writable = 'rational',
        ValueConv = function(_self, val) return math.sqrt(2) ^ perl.num(val) end,
        PrintConv = function(_self, val) return sprintf('%.1f', val) end,
        ValueConvInv = function(_self, val)
            val = perl.num(val)
            if val > 0 then return 2 * math.log(val) / math.log(2) end
            return 0
        end,
        PrintConvInv = function(_self, val) return val end,
    },
    SubjectDistance = {
        Groups = { [2] = 'Camera' },
        Writable = 'rational',
        PrintConv = function(_self, val)
            if isMatch(val, [[^(inf|undef)$]]) then return val end
            return perlStr(val) .. ' m'
        end,
        PrintConvInv = function(_self, val) return (subst(val, [[\s*m$]], '')) end,
    },
    MeteringMode = {
        Groups = { [2] = 'Camera' },
        Writable = 'integer',
        PrintConv = {
            [1] = 'Average',
            [2] = 'Center-weighted average',
            [3] = 'Spot',
            [4] = 'Multi-spot',
            [5] = 'Multi-segment',
            [6] = 'Partial',
            [255] = 'Other',
        },
    },
    LightSource = {
        Groups = { [2] = 'Camera' },
        SeparateTable = 'EXIF LightSource',
        PrintConv = require('lexiftool.Exif').lightSource,
    },
    Flash = {
        Groups = { [2] = 'Camera' },
        Struct = {
            STRUCT_NAME = 'Flash',
            NAMESPACE = 'exif',
            Fired = { Writable = 'boolean', PrintConv = boolConv.PrintConv },
            Return = {
                Writable = 'integer',
                PrintConv = {
                    [0] = 'No return detection',
                    [2] = 'Return not detected',
                    [3] = 'Return detected',
                },
            },
            Mode = {
                Writable = 'integer',
                PrintConv = {
                    [0] = 'Unknown',
                    [1] = 'On',
                    [2] = 'Off',
                    [3] = 'Auto',
                },
            },
            Function = { Writable = 'boolean', PrintConv = boolConv.PrintConv },
            RedEyeMode = { Writable = 'boolean', PrintConv = boolConv.PrintConv },
        },
    },
    FocalLength = {
        Groups = { [2] = 'Camera' },
        Writable = 'rational',
        PrintConv = function(_self, val) return sprintf('%.1f mm', val) end,
        PrintConvInv = function(_self, val) return (subst(val, [[\s*mm$]], '')) end,
    },
    SubjectArea = { Writable = 'integer', List = 'Seq', AutoSplit = 1 },
    FlashEnergy = { Groups = { [2] = 'Camera' }, Writable = 'rational' },
    SpatialFrequencyResponse = {
        Groups = { [2] = 'Camera' },
        Struct = sOECF,
    },
    FocalPlaneXResolution = { Groups = { [2] = 'Camera' }, Writable = 'rational' },
    FocalPlaneYResolution = { Groups = { [2] = 'Camera' }, Writable = 'rational' },
    FocalPlaneResolutionUnit = {
        Groups = { [2] = 'Camera' },
        Writable = 'integer',
        Notes = 'values 1, 4 and 5 are not standard EXIF',
        PrintConv = {
            [1] = 'None', -- (not standard EXIF)
            [2] = 'inches',
            [3] = 'cm',
            [4] = 'mm', -- (not standard EXIF)
            [5] = 'um', -- (not standard EXIF)
        },
    },
    SubjectLocation = { Writable = 'integer', List = 'Seq', AutoSplit = 1 },
    ExposureIndex   = { Writable = 'rational' },
    SensingMethod = {
        Groups = { [2] = 'Camera' },
        Writable = 'integer',
        Notes = 'values 1 and 6 are not standard EXIF',
        PrintConv = {
            [1] = 'Monochrome area', -- (not standard EXIF)
            [2] = 'One-chip color area',
            [3] = 'Two-chip color area',
            [4] = 'Three-chip color area',
            [5] = 'Color sequential area',
            [6] = 'Monochrome linear', -- (not standard EXIF)
            [7] = 'Trilinear',
            [8] = 'Color sequential linear',
        },
    },
    FileSource = {
        Writable = 'integer',
        PrintConv = {
            [1] = 'Film Scanner',
            [2] = 'Reflection Print Scanner',
            [3] = 'Digital Camera',
        },
    },
    SceneType  = { Writable = 'integer', PrintConv = { [1] = 'Directly photographed' } },
    CFAPattern = {
        Struct = {
            STRUCT_NAME = 'CFAPattern',
            NAMESPACE   = 'exif',
            Columns     = { Writable = 'integer' },
            Rows        = { Writable = 'integer' },
            Values      = { Writable = 'integer', List = 'Seq' },
        },
    },
    CustomRendered = {
        Writable = 'integer',
        PrintConv = {
            [0] = 'Normal',
            [1] = 'Custom',
        },
    },
    ExposureMode = {
        Groups = { [2] = 'Camera' },
        Writable = 'integer',
        PrintConv = {
            [0] = 'Auto',
            [1] = 'Manual',
            [2] = 'Auto bracket',
        },
    },
    WhiteBalance = {
        Groups = { [2] = 'Camera' },
        Writable = 'integer',
        PrintConv = {
            [0] = 'Auto',
            [1] = 'Manual',
        },
    },
    DigitalZoomRatio = { Writable = 'rational' },
    FocalLengthIn35mmFilm = {
        Name = 'FocalLengthIn35mmFormat',
        Writable = 'integer',
        Groups = { [2] = 'Camera' },
        PrintConv = function(_self, val) return perlStr(val) .. ' mm' end,
        PrintConvInv = function(_self, val) return (subst(val, [[\s*mm$]], '')) end,
    },
    SceneCaptureType = {
        Groups = { [2] = 'Camera' },
        Writable = 'integer',
        PrintConv = {
            [0] = 'Standard',
            [1] = 'Landscape',
            [2] = 'Portrait',
            [3] = 'Night',
        },
    },
    GainControl = {
        Groups = { [2] = 'Camera' },
        Writable = 'integer',
        PrintConv = {
            [0] = 'None', [1] = 'Low gain up', [2] = 'High gain up',
            [3] = 'Low gain down', [4] = 'High gain down',
        },
    },
    Contrast = {
        Groups = { [2] = 'Camera' },
        Writable = 'integer',
        PrintConv = {
            [0] = 'Normal',
            [1] = 'Low',
            [2] = 'High',
        },
        PrintConvInv = function(self, val) return require('lexiftool.Exif').ConvertParameter(self, val) end,
    },
    Saturation = {
        Groups = { [2] = 'Camera' },
        Writable = 'integer',
        PrintConv = {
            [0] = 'Normal',
            [1] = 'Low',
            [2] = 'High',
        },
        PrintConvInv = function(self, val) return require('lexiftool.Exif').ConvertParameter(self, val) end,
    },
    Sharpness = {
        Groups = { [2] = 'Camera' },
        Writable = 'integer',
        PrintConv = {
            [0] = 'Normal',
            [1] = 'Soft',
            [2] = 'Hard',
        },
        PrintConvInv = function(self, val) return require('lexiftool.Exif').ConvertParameter(self, val) end,
    },
    DeviceSettingDescription = {
        Groups = { [2] = 'Camera' },
        Struct = {
            STRUCT_NAME = 'DeviceSettings',
            NAMESPACE   = 'exif',
            Columns     = { Writable = 'integer' },
            Rows        = { Writable = 'integer' },
            Settings    = { List = 'Seq' },
        },
    },
    SubjectDistanceRange = {
        Groups = { [2] = 'Camera' },
        Writable = 'integer',
        PrintConv = {
            [0] = 'Unknown',
            [1] = 'Macro',
            [2] = 'Close',
            [3] = 'Distant',
        },
    },
    ImageUniqueID = { Avoid = 1, Notes = 'moved to exifEX namespace in 2024 spec' },
    GPSVersionID = { Groups = { [2] = 'Location' } },
    GPSLatitude = { Groups = { [2] = 'Location' }, ValueConv = latConv.ValueConv, ValueConvInv = latConv.ValueConvInv,
                    PrintConv = latConv.PrintConv, PrintConvInv = latConv.PrintConvInv },
    GPSLongitude = { Groups = { [2] = 'Location' }, ValueConv = longConv.ValueConv, ValueConvInv = longConv.ValueConvInv,
                     PrintConv = longConv.PrintConv, PrintConvInv = longConv.PrintConvInv },
    GPSAltitudeRef  = {
        Groups = { [2] = 'Location' },
        Writable = 'integer',
        PrintConv = {
            OTHER = function(val, inv)
                local c1 = matches(val, [[^([-+0-9])]])
                if not (inv and c1) then return nil end
                return (c1 == '-' and 1 or 0)
            end,
            [0] = 'Above Sea Level',
            [1] = 'Below Sea Level',
        },
    },
    GPSAltitude = {
        Groups = { [2] = 'Location' },
        Writable = 'rational',
        -- extricate unsigned decimal number from string
        ValueConvInv = function(_self, val) return (matches(val, [[((?=\d|\.\d)\d*(?:\.\d*)?)]])) end,
        PrintConv = function(_self, val)
            if isMatch(val, [[^(inf|undef)$]]) then return val end
            return perlStr(val) .. ' m'
        end,
        PrintConvInv = function(_self, val) return (subst(val, [[\s*m$]], '')) end,
    },
    GPSTimeStamp = {
        Name = 'GPSDateTime',
        Description = 'GPS Date/Time',
        Groups = { [2] = 'Time' },
        Notes = [[
            a date/time tag called GPSTimeStamp by the XMP specification.  This tag is
            renamed here to prevent direct copy from EXIF:GPSTimeStamp which is a
            time-only tag.  Instead, the value of this tag should be taken from
            Composite:GPSDateTime when copying from EXIF
        ]],
        Writable = 'date', Shift = 'Time',
        Validate = dateTimeInfo.Validate,
        PrintConv = dateTimeInfo.PrintConv,
        PrintConvInv = dateTimeInfo.PrintConvInv,
    },
    GPSSatellites = { Groups = { [2] = 'Location' } },
    GPSStatus = {
        Groups = { [2] = 'Location' },
        PrintConv = { A = 'Measurement Active', V = 'Measurement Void' },
    },
    GPSMeasureMode = {
        Groups = { [2] = 'Location' },
        Writable = 'integer',
        PrintConv = { [2] = '2-Dimensional Measurement', [3] = '3-Dimensional Measurement' },
    },
    GPSDOP = { Groups = { [2] = 'Location' }, Writable = 'rational' },
    GPSSpeedRef = {
        Groups = { [2] = 'Location' },
        PrintConv = { K = 'km/h', M = 'mph', N = 'knots' },
    },
    GPSSpeed = { Groups = { [2] = 'Location' }, Writable = 'rational' },
    GPSTrackRef = {
        Groups = { [2] = 'Location' },
        PrintConv = { M = 'Magnetic North', T = 'True North' },
    },
    GPSTrack = { Groups = { [2] = 'Location' }, Writable = 'rational' },
    GPSImgDirectionRef = {
        Groups = { [2] = 'Location' },
        PrintConv = { M = 'Magnetic North', T = 'True North' },
    },
    GPSImgDirection = { Groups = { [2] = 'Location' }, Writable = 'rational' },
    GPSMapDatum = { Groups = { [2] = 'Location' } },
    GPSDestLatitude = { Groups = { [2] = 'Location' }, ValueConv = latConv.ValueConv, ValueConvInv = latConv.ValueConvInv,
                        PrintConv = latConv.PrintConv, PrintConvInv = latConv.PrintConvInv },
    GPSDestLongitude = { Groups = { [2] = 'Location' }, ValueConv = longConv.ValueConv, ValueConvInv = longConv.ValueConvInv,
                         PrintConv = longConv.PrintConv, PrintConvInv = longConv.PrintConvInv },
    GPSDestBearingRef = {
        Groups = { [2] = 'Location' },
        PrintConv = { M = 'Magnetic North', T = 'True North' },
    },
    GPSDestBearing = { Groups = { [2] = 'Location' }, Writable = 'rational' },
    GPSDestDistanceRef = {
        Groups = { [2] = 'Location' },
        PrintConv = { K = 'Kilometers', M = 'Miles', N = 'Nautical Miles' },
    },
    GPSDestDistance = { Groups = { [2] = 'Location' }, Writable = 'rational' },
    GPSProcessingMethod = { Groups = { [2] = 'Location' } },
    GPSAreaInformation = { Groups = { [2] = 'Location' } },
    GPSDifferential = {
        Groups = { [2] = 'Location' },
        Writable = 'integer',
        PrintConv = { [0] = 'No Correction', [1] = 'Differential Corrected' },
    },
    GPSHPositioningError = {
        Description = 'GPS Horizontal Positioning Error',
        Groups = { [2] = 'Location' },
        Writable = 'rational',
        PrintConv = function(_self, val) return perlStr(val) .. ' m' end,
        PrintConvInv = function(_self, val) return (subst(val, [[\s*m$]], '')) end,
    },
    NativeDigest = {}, -- #PH
}

-- Adobe-defined auxiliary EXIF tags (aux)
XMP.aux = xmpTableDefaults {
    GROUPS = { [1] = 'XMP-aux', [2] = 'Camera' },
    NAMESPACE = 'aux',
    Firmware = {}, -- #7
    FlashCompensation = { Writable = 'rational' }, -- #7
    ImageNumber = {}, -- #7
    LensInfo = { -- #7
        Notes = '4 rational values giving focal and aperture ranges',
        Avoid = 1,
        -- convert to floating point values (or 'inf' or 'undef')
        ValueConv = function(_self, val) return XMP.ConvertRationalList(val) end,
        ValueConvInv = function(_self, val)
            local vals = perl.split(' ', val)
            if #vals ~= 4 then return val end
            for i, v in ipairs(vals) do
                if v == 'inf' then
                    vals[i] = '1/0'
                elseif v == 'undef' then
                    vals[i] = '0/0'
                else
                    if not require('lexiftool').IsFloat(v) then return val end
                    vals[i] = perl.join('/', { require('lexiftool.Writer').Rationalize(v) })
                end
            end
            return perl.join(' ', vals) -- return string (string tag)
        end,
        -- convert to the form "12-20mm f/3.8-4.5" or "50mm f/1.4"
        PrintConv = function(_self, val) return require('lexiftool.Exif').PrintLensInfo(val) end,
        PrintConvInv = function(_self, val) return require('lexiftool.WriteExif').ConvertLensInfo(val) end,
    },
    Lens = {},
    OwnerName = { Avoid = 1 }, -- #7
    SerialNumber = { Avoid = 1 },
    LensSerialNumber = { Avoid = 1 },
    LensID = {
        Priority = 0,
        -- prevent this from getting set from a LensID that has been converted
        ValueConvInv = function(_self, val)
            -- (Lua: Perl's warn here is the eval warning ConvInv collects)
            if isMatch(val, [=[[^-\d ]]=]) then error('Expected one or more integer values', 0) end
            return val
        end,
    },
    ApproximateFocusDistance = {
        Writable = 'rational',
        PrintConv = {
            [4294967295] = 'infinity',
            OTHER = function(val, inv)
                if inv then return val == 'infinity' and 4294967295 or val end
                return perlStr(val) == '4294967295' and 'infinity' or val
            end,
        },
    }, -- #PH (LR3)
    -- the following new in LR6 (ref forum6497)
    IsMergedPanorama = { Writable = 'boolean' },
    IsMergedHDR = { Writable = 'boolean' },
    DistortionCorrectionAlreadyApplied = { Writable = 'boolean' },
    VignetteCorrectionAlreadyApplied = { Writable = 'boolean' },
    LateralChromaticAberrationCorrectionAlreadyApplied = { Writable = 'boolean' },
    LensDistortInfo = {}, -- (LR 7.5.1, 4 signed rational values)
    NeutralDensityFactor = {}, -- (LR 11.0 - rational value, but denominator seems significant)
    -- the following are ref forum13747
    EnhanceDetailsAlreadyApplied = { Writable = 'boolean' },
    EnhanceDetailsVersion = {}, -- integer?
    EnhanceSuperResolutionAlreadyApplied = { Writable = 'boolean' },
    EnhanceSuperResolutionVersion = {}, -- integer?
    EnhanceSuperResolutionScale = { Writable = 'rational' },
    EnhanceDenoiseAlreadyApplied = { Writable = 'boolean' }, -- #forum14760
    EnhanceDenoiseVersion = {}, -- #forum14760 integer?
    EnhanceDenoiseLumaAmount = {}, -- #forum14760 integer?
    FujiRatingAlreadyApplied = { Writable = 'boolean' }, -- #forum15815 (LR classic 13.2)
}

-- fallback table for unknown XMP namespaces
XMP.other = {
    GROUPS = { [2] = 'Unknown' },
    LANG_INFO = XMP.GetLangInfo,
}

--------------------------------------------------------------------------------
-- Found an XMP property
--------------------------------------------------------------------------------

-- We found an XMP property name/value
-- Inputs: 0) ExifTool object ref, 1) Pointer to tag table
--         2) reference to array of XMP property names (last is current property)
--         3) property value, 4) attribute hash ref (for 'xml:lang' or 'rdf:datatype')
-- Returns: 1 if valid tag was found
function XMP.FoundXMP(et, tagTablePtr, props, val, attrs)
    local lang, rawVal, rational
    local structProps = {}
    local tag, ns = XMP.GetXMPTagID(props, truthy(et.OPTIONS.Struct) and structProps or nil)
    if not truthy(tag) then return 0 end -- ignore things that aren't valid tags

    -- translate namespace if necessary
    if stdXlatNS[ns] then ns = stdXlatNS[ns] end
    local info = tagTablePtr[ns]
    local table_, added, xns, tagID
    if info then
        table_ = info.SubDirectory and info.SubDirectory.TagTable
        if not table_ then perl.warn('Missing TagTable for ' .. tag .. "!\n") end
    elseif props[1] == 'svg:svg' then
        if not truthy(ns) then
            -- disambiguate MetadataID by adding back the 'metadata' we ignored
            if tag == 'id' and props[2] == 'svg:metadata' then tag = 'metadataId' end
            -- use SVG namespace in SVG files if nothing better to use
            table_ = 'lexiftool.XMP.SVG'
        elseif #grep([[^rdf:]], props) == 0 then
            -- only other SVG information if not inside RDF (call it XMP if in RDF)
            table_ = 'lexiftool.XMP.otherSVG'
        end
    end

    local xmlGroups
    local grp0 = tagTablePtr.GROUPS[0]
    if not truthy(ns) and grp0 ~= 'XMP' then
        tagID = tag
    elseif grp0 == 'XML' and not table_ then
        -- this is an XML table (no namespace lookup)
        tagID = ns .. ':' .. tag
    else
        if grp0 == 'XML' then xmlGroups = 1 end
        -- look up this tag in the appropriate table
        if not table_ then table_ = 'lexiftool.XMP.other' end
        tagTablePtr = et:GetTagTable(table_)
        if tagTablePtr.NAMESPACE then
            tagID = tag
        else
            xns = xmpNS[ns]
            if xns == nil then
                xns = ns
                -- validate namespace prefix
                if not (isMatch(ns, [=[^[A-Z_a-z\x80-\xff][-.0-9A-Z_a-z\x80-\xff]*$]=]) or ns == '') then
                    et:Warn("Invalid XMP namespace prefix '" .. ns .. "'")
                    -- clean up prefix for use as an ExifTool group name
                    ns = tr(ns, '-.0-9A-Z_a-z\x80-\xff', '', 'dc')
                    if not isMatch(ns, [=[^[A-Z_a-z\x80-\xff]]=]) then ns = 'ns_' .. ns end
                    stdXlatNS[xns] = ns
                    xmpNS[ns] = xns
                end
            end
            -- add XMP namespace prefix to avoid collisions in variable-namespace tables
            tagID = xns .. ':' .. tag
            -- add namespace to top-level structure property
            if #structProps > 0 then structProps[1][1] = xns .. ':' .. structProps[1][1] end
        end
    end
    local tagInfo = et:GetTagInfo(tagTablePtr, tagID)

    if attrs then lang = attrs['xml:lang'] end

    -- must add a new tag table entry if this tag isn't pre-defined
    -- (or initialize from structure field if this is a pre-defined flattened tag)
    -- (upstream's `NoLoop: while (...) { ... last; }` runs at most once;
    --  `last NoLoop` is the goto to the label after it)
    while not tagInfo or truthy(tagInfo.Flat) do -- luacheck: ignore 512
        local tagList, nsList = {}, {}
        XMP.GetXMPTagID(props, tagList, nsList)
        local t, ti, addedFlat
        -- build tag ID strings for each level in the property path
        for _, ta in ipairs(tagList) do
            -- insert tag ID in index 1 of tagList list
            if truthy(t) then t = t .. ucfirst(ta[1]) else t = ta[1] end
            ta[2] = t
            -- generate flattened tags for top-level structure if necessary
            if addedFlat ~= nil then goto nextTa end
            ti = tagTablePtr[t]
            if not ti then goto nextTa end
            if not (type(ti) == 'table' and ti.Struct) then goto nextTa end
            addedFlat = XMP.AddFlattenedTags(tagTablePtr, t)
            -- all done if we generated the tag we are looking for
            if truthy(addedFlat) then
                tagInfo = tagTablePtr[tagID]
                if tagInfo then goto NoLoopDone end
            end
            ::nextTa::
        end
        local name = ucfirst(tag)

        -- search for the innermost containing structure
        -- (in case tag is an unknown field in a known structure)
        -- (only necessary if we found a structure above)
        -- (Lua index i is upstream's $i + 1)
        if addedFlat ~= nil then
            local t2 = ''
            for i = #tagList - 1, 1, -1 do
                t = tagList[i][2]
                t2 = tagList[i + 1][1] .. ucfirst(t2) -- build relative tag id
                ti = tagTablePtr[t]
                if not ti then goto nextI end
                if type(ti) ~= 'table' then goto nextI end
                local strTable = ti.Struct
                if not strTable then goto nextI end
                local flat = (ti.FlatName ~= nil and ti.FlatName or ti.Name)
                name = flat .. ucfirst(t2)
                -- don't continue if structure is known but field is not
                -- (an existing NAMESPACE with an undef value is false here)
                if truthy(strTable.NAMESPACE) or strTable.NAMESPACE == nil then break end
                -- this is a variable-namespace structure, so we must:
                -- 1) get tagInfo from corresponding top-level XMP tag if it exists
                -- 2) add new entry in this tag table, but with namespace prefix on tag ID
                local n = nsList[i + 1] -- namespace of structure field
                -- translate to standard ExifTool namespace
                if stdXlatNS[n] then n = stdXlatNS[n] end
                local xn = xmpNS[n] or n    -- standard XMP namespace
                -- no need to continue with variable-namespace logic if
                -- we are in our own namespace (right?)
                if xn == (tagTablePtr.NAMESPACE or '') then break end
                tagID = xn .. ':' .. tag    -- add namespace to avoid collisions
                -- change structure properties to add the standard XMP namespace
                -- prefix for this field (needed for variable-namespace fields)
                if #structProps > 0 then
                    if not structProps[i + 1] then structProps[i + 1] = {} end -- (autovivified)
                    structProps[i + 1][1] = xn .. ':' .. perlStr(structProps[i + 1][1])
                end
                -- copy tagInfo entries from the existing top-level XMP tag
                local tg = XMP.Main[n]
                if not (type(tg) == 'table' and tg.SubDirectory) then break end
                local tbl = et:GetTagTable(tg.SubDirectory.TagTable)
                if not tbl then break end
                local sti = et:GetTagInfo(tbl, t2)
                if not sti or truthy(sti.Flat) then
                    -- again, we must initialize flattened tags if necessary
                    -- (but don't bother to recursively apply full logic to
                    --  allow nested variable-namespace strucures until someone
                    --  actually wants to do such a silly thing)
                    local t3 = ''
                    for j = i + 1, #tagList do
                        t3 = tagList[j][1] .. ucfirst(t3)
                        local ti3 = tbl[t3]
                        if not ti3 then goto nextJ end
                        if not (type(ti3) == 'table' and ti3.Struct) then goto nextJ end
                        if not truthy(XMP.AddFlattenedTags(tbl, t3)) then break end
                        sti = tbl[t2]
                        do break end
                        ::nextJ::
                    end
                    if not sti then break end
                end
                -- use existing definition if we already added this tag
                if tagTablePtr[tagID] then
                    tagInfo = tagTablePtr[tagID]
                else
                    -- generate new tagInfo hash based on existing top-level tag
                    tagInfo = {}
                    for k, v in pairs(sti) do tagInfo[k] = v end
                    tagInfo.Name = flat .. perlStr(sti.Name)
                    -- be careful not to copy elements we shouldn't...
                    tagInfo.Description = nil -- Description will be different
                    -- can't copy group hash because group 1 will be different and
                    -- we need to check this when writing tag to a specific group
                    tagInfo.Groups = nil
                    if sti.Groups then tagInfo.Groups = { [2] = sti.Groups[2] } end
                end
                do break end
                ::nextI::
            end
        end
        -- generate a default tagInfo hash if necessary
        if not tagInfo then
            -- shorten tag name if necessary
            if et.ShortenXmpTags then
                local shorten = et.ShortenXmpTags
                name = shorten(name)
            end
            tagInfo = { Name = name, IsDefault = 1, Priority = 0 }
        end
        -- add tag Namespace entry for tags in variable-namespace tables
        if truthy(xns) then tagInfo.Namespace = xns end
        do
            local uri = et.curURI and et.curURI[ns]
            local g0, g1
            if truthy(uri) then
                g0, g1 = matches(uri, [[^http://ns.exiftool.(?:ca|org)/(.*?)/(.*?)/]])
            end
            if g0 then
                local grps = { [0] = g0, [1] = g1 }
                -- apply a little magic to recover original group names
                -- from this exiftool-written RDF/XML file
                if grps[1] == 'System' then
                    grps[1] = 'XML-System'
                    grps[0] = 'XML'
                elseif isMatch(grps[1], [[^\d]]) then
                    -- URI's with only family 0 are internal tags from the source file,
                    -- so change the group name to avoid confusion with tags from this file
                    grps[1] = 'XML-' .. grps[0]
                    grps[0] = 'XML'
                end
                tagInfo.Groups = grps
                -- flag to avoid setting group 1 later
                tagInfo.StaticGroup1 = 1
            end
        end
        -- construct tag information for this unknown tag
        -- -> make this a List or lang-alt tag if necessary
        do
            local listType
            if #props > 2 and isMatch(props[#props], [[^rdf:li \d+$]]) then
                listType = matches(props[#props - 1], [[^rdf:(Bag|Seq|Alt)$]])
            end
            if listType then
                if truthy(lang) and listType == 'Alt' then
                    tagInfo.Writable = 'lang-alt'
                else
                    tagInfo.List = listType
                end
            -- tried this, but maybe not a good idea for complex structures:
            --} elsif (grep / /, @$props) {
            --    $$tagInfo{List} = 1;
            end
        end
        if not (tagTablePtr[tagID] and tagTablePtr[tagID] == tagInfo) then
            -- save property list for verbose "adding" message unless this tag already exists
            if not tagTablePtr[tagID] then added = tagList end
            -- if this is an empty structure, we must add a Struct field
            if length(val) == 0 and attrs and truthy(attrs['rdf:parseType']) and attrs['rdf:parseType'] == 'Resource' then
                if not tagInfo.Struct then tagInfo.Struct = { STRUCT_NAME = 'XMP Unknown' } end
            end
            tagInfo.Hidden = 2  -- (don't show in -list outputs)
            et:AddTagToTable(tagTablePtr, tagID, tagInfo)
        end
        break
    end
    ::NoLoopDone::
    -- decode value if necessary (et:encoding was used before exiftool 7.71)
    if attrs then
        local enc = truthy(attrs['rdf:datatype']) and attrs['rdf:datatype'] or attrs['et:encoding']
        if truthy(enc) and isMatch(enc, [[base64]]) then
            -- (XMP.DecodeBase64 returns the string; the reference is made here)
            val = { ref = 'SCALAR', value = XMP.DecodeBase64(val) } -- (now a value ref)
            if not (length(val.value) > 100 or isMatch(val.value, [=[[\0-\x08\x0b\0x0c\x0e-\x1f]]=])) then
                val = val.value
            end
        end
    end
    if lang ~= nil and lc(lang) ~= 'x-default' then
        lang = XMP.StandardLangCase(lang)
        local langInfo = XMP.GetLangInfo(tagInfo, lang, et)
        if langInfo then tagInfo = langInfo end
    end
    -- un-escape XML character entities (handling CDATA)
    -- (pos($val) = 0; a reference left above is matched in its string form)
    local c, p = matches(val, [[(?s)<!\[CDATA\[(.*?)\]\]>]], 0)
    if c then
        -- unescape everything up to the start of the CDATA section
        -- (the length of "<[[CDATA[]]>" is 12 characters)
        local v = XMP.UnescapeXML(substr(val, 0, p - length(c) - 12)) .. c
        while true do
            local p1
            c, p1 = matches(val, [[(?s)<!\[CDATA\[(.*?)\]\]>]], p)
            if not c then break end
            v = v .. XMP.UnescapeXML(substr(val, p, p1 - p - length(c) - 12)) .. c
            p = p1
        end
        val = v .. XMP.UnescapeXML(substr(val, p))
    else
        val = XMP.UnescapeXML(val)
    end
    -- decode from UTF8
    val = et:Decode(val, 'UTF8')
    -- convert rational and date values to a more sensible format
    local fmt = tagInfo.Writable
    local new = tagInfo.IsDefault and et.OPTIONS.XMPAutoConv
    if truthy(fmt) or truthy(new) then
        rawVal = val -- save raw value for verbose output
        if (truthy(new) or fmt == 'rational') and XMP.ConvertRational(val) ~= nil then
            -- (upstream ConvertRational converts $_[0] in place)
            val = XMP.ConvertRational(val)
            rational = rawVal
        else
            local stdDate
            if truthy(new) or fmt == 'date' then val, stdDate = XMP.ConvertXMPDate(val, new) end
            if stdDate and added then
                if not tagInfo.Groups then tagInfo.Groups = {} end
                tagInfo.Groups[2] = 'Time'
                tagInfo.PrintConv = function(self, v) return self:ConvertDateTime(v) end
            end
        end
        if et.XmpValidate and fmt and fmt == 'boolean' and not isMatch(val, [[^True|False$]]) then
            if isMatch(val, [[^true|false$]]) then
                et:Warn('Boolean value for XMP-' .. ns .. ':' .. tagInfo.Name .. ' should be capitalized', 1)
            else
                et:Warn('Boolean value for XMP-' .. ns .. ':' .. tagInfo.Name .. ' should be "True" or "False"', 1)
            end
        end
        -- protect against large binary data in unknown tags
        if truthy(new) and length(val) > 65536 then tagInfo.Binary = 1 end
    end
    if truthy(et.OPTIONS.Verbose) then
        local tagID_ = tconcat(props, '/')
        et:VerboseInfo(tagID_, tagInfo, { Value = truthy(rawVal) and rawVal or val })
    end
    -- store the value for this tag
    local key = et:FoundTag(tagInfo, val)
    if not key then return 0 end
    -- save original components of rational numbers (used when copying)
    if rational ~= nil then
        if not et.TAG_EXTRA[key] then et.TAG_EXTRA[key] = {} end
        et.TAG_EXTRA[key].Rational = rational
    end
    -- save structure/list information if necessary
    if #structProps > 0 and (#structProps > 1 or structProps[1][2] ~= nil) and
        not et.NO_STRUCT
    then
        if not et.TAG_EXTRA[key] then et.TAG_EXTRA[key] = {} end
        et.TAG_EXTRA[key].Struct = structProps
        et.IsStruct = 1
    end
    if xmlGroups then
        et:SetGroup(key, 'XML', 0)
        et:SetGroup(key, 'XML-' .. ns, 1)
    elseif truthy(ns) and not tagInfo.StaticGroup1 then
        -- set group1 dynamically according to the namespace
        et:SetGroup(key, tagTablePtr.GROUPS[0] .. '-' .. ns)
    end
    if added and truthy(et.OPTIONS.Verbose) then
        local props_
        if #added > 1 then
            tagInfo.Flat = 0    -- this is a flattened tag
            local names = {}
            for i = 1, #added do names[i] = added[i][1] end
            props_ = ' (' .. tconcat(names, '/') .. ')'
        else
            props_ = ''
        end
        local g1 = et:GetGroup(key, 1)
        et:VPrint(0, et.INDENT, '[adding ' .. g1 .. ':' .. tag .. ']' .. props_ .. "\n")
    end
    -- allow read-only subdirectories (eg. embedded base64 XMP/IPTC in NKSC
    -- files, or a c2pa:manifest box in an SVG file)
    if tagInfo.SubDirectory and not et.IsWriting then
        local subdir = tagInfo.SubDirectory
        local dataPt = et.VALUE[key]
        if type(dataPt) == 'table' and dataPt.ref == 'SCALAR' then
            dataPt = dataPt.value
        end
        -- decode if necessary (eg. Nikon XMP-ast:XMLPackets)
        if tagInfo.Encoding and tagInfo.Encoding == 'Base64' then
            dataPt = XMP.DecodeBase64(dataPt)
        end
        -- process subdirectory information
        local subInfo = {
            Name = subdir.DirName or tagInfo.Name,
            DataPt = dataPt,
            DirLen = #dataPt,
            TagInfo = tagInfo,
            IgnoreProp = subdir.IgnoreProp, -- (allow XML to ignore specified properties)
            IsExtended = 1,  -- (hack to avoid Duplicate warning for embedded XMP)
            NoStruct = 1,    -- (don't try to build structures since this isn't true XMP)
            NoBlockSave = 1, -- (don't save as a block because we already did this)
        }
        local oldOrder = et.GetByteOrder()
        if subdir.ByteOrder then et.SetByteOrder(subdir.ByteOrder) end
        local oldNS = et.definedNS
        et.definedNS = nil
        local subTablePtr = et:GetTagTable(subdir.TagTable) or tagTablePtr
        et:ProcessDirectory(subInfo, subTablePtr, subdir.ProcessProc)
        et.SetByteOrder(oldOrder)
        et.definedNS = oldNS
    end
    return 1
end

--------------------------------------------------------------------------------
-- The XML parser
--------------------------------------------------------------------------------


-- Find the next XML token (element, CDATA or comment) at or after position `from`
-- (0-based).  Returns a token table and the new position, or nil.
-- Token fields: kind ('element'/'cdata'/'comment'/'other'), prop, attrs, after,
--               prefix ('?' or '/'), selfClosing
local function findNextToken(data, from, end_)
    local lt = sfind(data, '<', from + 1, true)
    if not lt or lt - 1 > end_ then return nil end
    local i = lt -- 1-based index of '<'
    local c1 = sbyte(data, i + 1)
    if not c1 then return nil end
    if c1 == 0x3f or c1 == 0x2f then -- '?' or '/'
        local gt = sfind(data, '>', i + 2, true)
        if not gt then return nil end
        return { kind = 'other', after = gt }, gt
    end
    if c1 == 0x21 then -- '!'
        if ssub(data, i + 1, i + 3) == '!--' then
            return { kind = 'comment', at = i }, i
        end
        if ssub(data, i + 1, i + 8) == '![CDATA[' then
            return { kind = 'cdata', at = i }, i
        end
        -- neither comment nor CDATA (e.g. "<!DOCTYPE ...>"): the upstream
        -- non-anchored global regex simply doesn't match here and continues
        -- scanning forward for the next '<' -- mirror that by retrying the
        -- search from this position
        return findNextToken(data, i, end_)
    end
    -- parse element name
    local j = i + 1
    while j <= #data do
        local b = sbyte(data, j)
        if b >= 0x80 then
            j = j + 1
        elseif b == 0x2d or b == 0x5f or b == 0x3a or b == 0x2e then -- - _ : .
            j = j + 1
        elseif (b >= 0x30 and b <= 0x39) or (b >= 0x41 and b <= 0x5a) or (b >= 0x61 and b <= 0x7a) then
            j = j + 1
        else
            break
        end
    end
    local prop = ssub(data, i + 1, j - 1)
    if prop == '' then return nil end
    if prop == '!--' then
        return { kind = 'comment', at = i }, i
    end
    -- find '>' (attrs up to '>')
    local gt = sfind(data, '>', j, true)
    if not gt then return nil end
    local attrs = ssub(data, j, gt - 1)
    local selfClosing = false
    if attrs:sub(-1) == '/' then
        selfClosing = true
        attrs = attrs:sub(1, -2)
    end
    return { kind = 'element', prop = prop, attrs = attrs, after = gt, selfClosing = selfClosing }, gt
end

-- Find the next token relevant to closing tag `prop` (the Perl
-- `m{<(?:(/?)\Q$prop\E([-\w:.\x80-\xff]*)(.*?(/?))>|(!\[CDATA\[|!--))}` scan).
-- Returns a token table or nil.  Token fields: kind ('close'/'cdata'/'comment'),
-- closing, cont (name continuation), tail, after, selfClosing.
local function findCloseToken(data, from, prop, end_)
    local n = #prop
    local lt = sfind(data, '<', from + 1, true)
    while lt and lt - 1 <= end_ do
        local i = lt
        local c1 = sbyte(data, i + 1)
        if c1 == 0x21 then -- '!'
            if ssub(data, i + 1, i + 3) == '!--' then
                return { kind = 'comment', at = i, after = i + 3 }
            end
            if ssub(data, i + 1, i + 8) == '![CDATA[' then
                return { kind = 'cdata', at = i, after = i + 8 }
            end
        else
            -- the property name follows the optional '/'
            local nameStart = i + 1
            local closing = false
            if c1 == 0x2f then
                closing = true
                nameStart = i + 2
            end
            if data:sub(nameStart, nameStart + n - 1) == prop then
                -- possible close/open of our property; check that the next
                -- character is not a continuation of the name
                local contStart = nameStart + n
                local b = sbyte(data, contStart)
                local isNameChar = b and ((b >= 0x80) or
                    (b == 0x2d or b == 0x5f or b == 0x3a or b == 0x2e) or
                    (b >= 0x30 and b <= 0x39) or (b >= 0x41 and b <= 0x5a) or (b >= 0x61 and b <= 0x7a))
                if not isNameChar then
                    -- this is our property name; find the '>'
                    local gt = sfind(data, '>', contStart, true)
                    if gt then
                        local attrs = ssub(data, contStart, gt - 1)
                        local selfClosing = attrs:sub(-1) == '/'
                        return { kind = 'close', closing = closing, cont = '', tail = attrs,
                                 after = gt, selfClosing = selfClosing }
                    end
                end
            end
        end
        lt = sfind(data, '<', lt + 1, true)
    end
    return nil
end

-- Recursively parse nested XMP data element
-- Inputs: 0) ExifTool ref, 1) tag table ref, 2) XMP data string
--         3) offset to start of XMP element (0-based), 4) offset to end of XMP element
--         5) reference to array of enclosing XMP property names (nil if none)
--         6) reference to blank node information hash (unused in the subset)
-- Returns: Number of contained XMP elements
function XMP.ParseXMPElement(et, tagTablePtr, dataPt, start, end_, propList, blankInfo)
    local count = 0
    local nItems = 0
    local saveNS -- save xlatNS lookup if changed for the scope of this element
    local err
    local isSVG = et.XMP_IS_SVG
    -- when writing we capture the raw properties instead of extracting tags
    -- (upstream: `my $isWriting = $$et{XMP_CAPTURE}`)
    local isWriting = et.XMP_CAPTURE
    local pos = start or 0
    if not end_ then end_ = #dataPt end
    if not propList then propList = {} end
    -- (upstream: `$blankInfo or $blankInfo = $processBlankInfo = { Prop => { } }`
    --  -- a root-level call creates the blank-info hash and must run
    --  ProcessBlankInfo afterwards)
    local processBlankInfo
    if not blankInfo then
        blankInfo = { Prop = {} }
        processBlankInfo = blankInfo
    end
    -- keep track of current nodeID at this nesting level
    local oldNodeID = blankInfo.NodeID

    -- lookup for translating namespace prefixes
    local xlatNS = et.xlatNS

    while true do
        -- all done if there isn't enough data for another element
        -- (the smallest possible element is 4 bytes, eg. "<a/>")
        if pos > end_ - 4 then break end
        -- reset nodeID before processing each element
        local nodeID = oldNodeID
        blankInfo.NodeID = nodeID

        -- find start of next element, skipping over "<![CDATA[xxx]]>" sections
        local tok
        tok, pos = findNextToken(dataPt, pos, end_)
        if not tok or pos > end_ then break end
        -- (<?...> and </...> tokens are skipped: findNextToken returns
        --  kind='other' after advancing pos past them)
        if tok.kind == 'other' then goto nextElement end
        if tok.kind == 'cdata' then -- skip CDATA
            local cd = sfind(dataPt, ']]>', tok.at + 1, true)
            if cd and cd + 2 <= end_ then
                pos = cd + 2 -- (pos is 0-based index after ']]>')
            else
                err = 'Missing CDATA terminator'
                break
            end
        elseif tok.kind == 'comment' then -- skip comments
            local cd = sfind(dataPt, '-->', tok.at + 1, true)
            if cd and cd + 2 <= end_ then
                pos = cd + 2
            else
                break
            end
        else -- element
            local prop = tok.prop
            local attrsStr = tok.attrs
            local valStart = pos -- pos currently points just past '>'
            local valEnd
            local wasComment

            -- only look for closing token if this is not an empty element
            -- (empty elements end with '/', eg. <a:b/>)
            if not tok.selfClosing then
                local nesting = 1
                while true do
                    -- find next matching closing token, or the next opening token
                    -- of a nested same-named element
                    local ctok = findCloseToken(dataPt, pos, prop, end_)
                    if not ctok or ctok.after > end_ then
                        err = 'XMP format error (no closing tag for ' .. prop .. ')'
                        break
                    end
                    if ctok.kind == 'cdata' then -- find end of CDATA section
                        local cd = sfind(dataPt, ']]>', ctok.at + 1, true)
                        if cd and cd + 2 <= end_ then
                            pos = cd + 2
                        else
                            err = 'Missing CDATA terminator'
                            break
                        end
                    elseif ctok.kind == 'comment' then -- find end of comment section
                        local cd = sfind(dataPt, '-->', ctok.at + 1, true)
                        if cd and cd + 2 <= end_ then
                            wasComment = 1
                            pos = cd + 2
                        else
                            err = 'Missing comment terminator'
                            break
                        end
                    else
                        if ctok.cont ~= '' then
                            -- ignore opening properties with different names
                            pos = ctok.after
                        elseif ctok.closing then
                            nesting = nesting - 1
                            if nesting == 0 then
                                -- 0-based index of '<' of the closing tag
                                valEnd = ctok.after - #prop - #ctok.tail - 3
                                pos = ctok.after
                                break -- this element is complete
                            end
                            pos = ctok.after
                        else
                            -- this is a nested opening token (or empty element)
                            if not ctok.selfClosing then nesting = nesting + 1 end
                            pos = ctok.after
                        end
                    end
                end
                if err then break end
            else
                valEnd = valStart
            end

            -- extract property attributes
            local parseResource
            local attrList = {}
            local attrs = {}
            -- (upstream loops over `(\S+?)\s*=\s*(['"])(.*?)\2`; the "long
            --  attribute" 13.23 corruption patch is not needed here)
            for attrName, _, aVal in attrsStr:gmatch('([^ \t\n\r\f\v]-)[ \t\n\r\f\v]*=[ \t\n\r\f\v]*([%\'"])(.-)%2') do
                if attrName == '' then break end
                local name = attrName
                -- handle namespace prefixes (defined by xmlns:PREFIX, or used with PREFIX:tag)
                if name:find(':') then
                    local pre = name:match('^(.-):')
                    if pre == 'xmlns' then
                        local ns2 = substr(name, 6)
                        local stdNS = uri2ns[aVal]
                        -- (keep track of namespace prefixes defined in this scope
                        --  for Validate; not tracked in the ported subset)
                        if not et.definedNS[ns2] then
                            et.definedNS[ns2] = 1
                        end
                        if not stdNS then
                            local try = aVal
                            -- patch for Nikon NX2 URI bug for Microsoft PhotoInfo namespace
                            if try:sub(-1) == '/' then try = try:sub(1, -2) else try = try .. '/' end
                            stdNS = uri2ns[try]
                            if stdNS then
                                aVal = try
                                et:Warn('Fixed incorrect URI for xmlns:' .. ns2, 1)
                            elseif matches(aVal, [[^http://ns\.nikon\.com/BASIC_PARAM]]) then
                                et:OverrideFileType('NXD', 'application/x-nikon-nxd')
                            else
                                -- look for same namespace with different version number
                                -- (upstream quotemeta's the URI and re-opens just the
                                --  `/N.N/` segment into `\d+\.\d+`, then greps %uri2ns
                                --  for a key matching that pattern.  Lua has no
                                --  quotemeta, so the same comparison is made by
                                --  blanking the version segment on both sides -- which
                                --  is what that pattern tests for.)
                                local blanked = subst(aVal, [[/\d+\.\d+(/|$)]], '/#$1', '')
                                if blanked ~= aVal then
                                    for uri, ns3 in pairs(uri2ns) do
                                        if subst(uri, [[/\d+\.\d+(/|$)]], '/#$1', '') == blanked then
                                            stdNS = ns3
                                            et:VPrint(0, (et.INDENT or '') ..
                                                '[different ' .. stdNS .. ' version: ' .. aVal .. ']\n')
                                            break
                                        end
                                    end
                                end
                            end
                        end
                        local newNS
                        if stdNS then
                            -- use standard namespace prefix if pre-defined
                            if stdNS ~= ns2 then
                                newNS = stdNS
                            elseif xlatNS[ns2] then
                                -- this prefix is re-defined to the standard prefix in this scope
                                newNS = ''
                            end
                        elseif et.curNS[aVal] then
                            -- use a consistent prefix over the entire XMP for a given namespace URI
                            if et.curNS[aVal] ~= ns2 then newNS = et.curNS[aVal] end
                        else
                            local usedNS2 = ns2
                            -- use unique prefixes for all namespaces across the entire XMP
                            if et.curURI[ns2] or nsURI[ns2] then
                                -- generate a temporary namespace prefix to resolve any conflict
                                local tmpI = 0
                                while et.curURI['tmp' .. tmpI] do tmpI = tmpI + 1 end
                                newNS = 'tmp' .. tmpI
                                usedNS2 = newNS
                            end
                            -- keep track of the namespace prefixes and URI's used in this XMP
                            et.curNS[aVal] = usedNS2
                            et.curURI[usedNS2] = aVal
                        end
                        if newNS ~= nil then
                            -- save translation used in containing scope if necessary
                            if not saveNS then
                                saveNS = xlatNS
                                xlatNS = {}
                                for k, v in pairs(et.xlatNS) do xlatNS[k] = v end
                                et.xlatNS = xlatNS
                            end
                            if #newNS > 0 then
                                -- use the new namespace prefix
                                xlatNS[ns2] = newNS
                                name = 'xmlns:' .. newNS
                                -- must go through previous attributes and change prefixes if necessary
                                for j = 1, #attrList do
                                    local oldAttr = attrList[j]
                                    local p2 = oldAttr:match('^(.-):')
                                    if p2 == ns2 and p2 ~= newNS then
                                        local newAttr = newNS .. substr(oldAttr, #ns2)
                                        attrs[newAttr] = attrs[oldAttr]
                                        attrs[oldAttr] = nil
                                        attrList[j] = newAttr
                                    end
                                end
                            else
                                xlatNS[ns2] = nil
                            end
                        end
                    else
                        if xlatNS[pre] then
                            name = xlatNS[pre] .. substr(name, #pre)
                        end
                    end
                end
                attrList[#attrList + 1] = name -- preserve order
                attrs[name] = aVal
            end

            -- translate the property namespace prefix
            if prop:find(':') then
                local pre = prop:match('^(.-):')
                -- tame wild namespace prefixes (patch for Microsoft stupidity)
                if xlatNS[pre] then
                    prop = xlatNS[pre] .. substr(prop, #pre)
                end
            end

            if prop == 'rdf:li' then
                -- impose a reasonable maximum on the number of items in a list
                if nItems == 1000 then
                    if not et.OPTIONS.IgnoreMinorErrors then
                        et:Warn('Extracted only 1000 ' .. propList[#propList] .. ' items. Ignore minor errors to extract all')
                        break
                    end
                end
                -- add index to list items so we can keep them in order
                prop = prop .. ' ' .. #perlStr(nItems) .. nItems
                -- reset LIST_TAGS at the start of the outtermost list
                if nItems == 0 then
                    local hasLi = false
                    for j = 1, #propList do
                        if propList[j]:match('^rdf:li ') then hasLi = true break end
                    end
                    if not hasLi then et.LIST_TAGS = {} end
                end
                nItems = nItems + 1
            elseif prop == 'rdf:Description' then
                -- remove unnecessary rdf:Description elements since parseType='Resource'
                -- is more efficient (also necessary to make property path consistent)
                for j = 1, #propList do
                    if propList[j] == 'rdf:Description' then
                        parseResource = 1
                        -- set parseType so we know this is a structure
                        attrs['rdf:parseType'] = 'Resource'
                        break
                    end
                end
            elseif prop == 'xmp:xmpmeta' then
                -- patch MicrosoftPhoto unconformity
                prop = 'x:xmpmeta'
                if et.XmpValidate then et:Warn('Wrong namespace for xmpmeta') end
            end

            -- hook for special parsing of attributes (upstream AttrProc; e.g.
            -- XISF's HandleXISFAttrs remaps a <Property id="X" value="Y">
            -- element to a plain X=Y tag). Lua has no pass-by-reference
            -- scalars, so the hook mutates attrList/attrs in place (tables
            -- are reference types); it always returns the (possibly
            -- unmodified) prop, plus a separate valChanged flag since
            -- upstream renames $prop via the \$prop reference independently
            -- of whether $val was actually changed.
            local val = nil
            if et.XMPParseOpts and et.XMPParseOpts.AttrProc then
                val = ssub(dataPt, valStart + 1, valEnd)
                local valChanged, newProp, newVal = et.XMPParseOpts.AttrProc(attrList, attrs, prop, val)
                prop = newProp
                if valChanged then
                    val = newVal
                    valStart = valEnd
                end
            end
            -- add nodeID to property path (with leading ' #') if it exists
            if attrs['rdf:nodeID'] ~= nil then
                nodeID = attrs['rdf:nodeID']
                blankInfo.NodeID = nodeID
                attrs['rdf:nodeID'] = nil
                prop = prop .. ' #' .. nodeID
                parseResource = nil -- can't ignore if this is a node
            end
            -- push this property name onto our hierarchy list
            if not parseResource then
                propList[#propList + 1] = prop
            end

            -- upstream XMP.pm lines 4052-4063: SVG file handling (only
            -- exercised by a standalone SVG file, where ProcessXMP sets
            -- et.XMP_IS_SVG; a JPEG-embedded XMP packet is never SVG)
            if isSVG then
                -- ignore everything but top level SVG tags and metadata unless Unknown set
                local unknownGT1 = (et.OPTIONS.Unknown or 0) > 1
                local verbose = et.OPTIONS.Verbose and et.OPTIONS.Verbose > 0
                if not (unknownGT1 or verbose) then
                    -- (upstream `\b(metadata|desc|title)$` word boundary; the
                    --  three frontier patterns are the Lua equivalent of the
                    --  `\b`-anchored alternation, which a single Lua pattern
                    --  with a `%f` frontier plus group alternation can't express)
                    local svgKeep = propList[2] and
                        (propList[2]:match('%f[A-Za-z]metadata$') or
                         propList[2]:match('%f[A-Za-z]desc$') or
                         propList[2]:match('%f[A-Za-z]title$'))
                    if #propList > 1 and not svgKeep then
                        propList[#propList] = nil
                        goto nextElement
                    end
                end
                if prop == 'svg' or prop == 'metadata' then
                    -- add svg namespace prefix if missing to ignore these entries in the tag name
                    propList[#propList] = 'svg:' .. prop
                end
            elseif et.XmpIgnoreProps then -- ignore specified properties for tag name
                local ip = et.XmpIgnoreProps
                for j = 1, #ip do
                    if #propList == 0 then break end
                    if ip[j] == propList[1] then propList[#propList] = nil end
                end
            end

            -- handle properties inside element attributes (RDF shorthand format):
            -- (attributes take the form a:b='c' or a:b="c")
            local shorthand
            local ignoredAttr -- (upstream `$ignored`, only used when writing)
            for j = 1, #attrList do
                local shortName = attrList[j]
                if attrs[shortName] ~= nil then
                    local propName = shortName
                    local pns
                    local colon = sfind(propName, ':', 1, true)
                    if colon then
                        pns = ssub(propName, 1, colon - 1) -- specified namespace
                    else
                        local colon2 = prop:match('([^ \t\n\r\f\v]-):')
                        if colon2 then
                            pns = colon2 -- assume same namespace as parent
                            propName = pns .. ':' .. propName -- generate full property name
                        else
                            pns = ''
                        end
                    end
                    if propName == 'rdf:about' then
                        if not truthy(et.XmpAbout) then
                            et.XmpAbout = attrs[shortName]
                        elseif et.XmpAbout ~= attrs[shortName] then
                            if isWriting then
                                local str = "Different 'rdf:about' attributes not handled"
                                if not et.WAS_WARNED[str] then
                                    et:Error(str, 1)
                                    et.WAS_WARNED[str] = 1
                                end
                            elseif et.XmpValidate then
                                et:Warn("Different 'rdf:about' attributes")
                            end
                        end
                    end
                    local shortVal = attrs[shortName]
                    -- (upstream keeps track of the namespaces in use while
                    --  writing, and never extracts the recognized attributes
                    --  as tags in that case)
                    local skipAttr
                    if isWriting then
                        if pns == 'xmlns' then
                            local nsName = ssub(propName, 7)
                            local stdNS = uri2ns[shortVal]
                            if not (stdNS and (stdNS == 'x' or stdNS == 'iX')) then
                                if et.XMP_NS[nsName] == nil then et.XMP_NS[nsName] = shortVal end
                            end
                            attrs[shortName] = nil -- (handled by namespace logic)
                            skipAttr = true
                        elseif recognizedAttrs[propName] then
                            skipAttr = true
                        end
                    end
                    if skipAttr then -- luacheck: ignore
                        -- (nothing more to do with this attribute)
                    elseif ignoreNamespace[pns] or ignoreProp[prop] or ignoreEtProp[propName] then
                        ignoredAttr = propName
                        -- handle special attributes (extract as tags only once if not empty)
                        local ra = recognizedAttrs[propName]
                        if type(ra) == 'table' and shortVal ~= '' then
                            local tbl, id, name = ra[1], ra[2], ra[3]
                            local tval = XMP.UnescapeXML(shortVal)
                            if not (et.VALUE[name] and et.VALUE[name] == tval) then
                                et:HandleTag(et:GetTagTable(tbl), id, tval)
                            end
                        end
                    else
                        attrs[shortName] = nil -- don't re-use this attribute
                        propList[#propList + 1] = propName
                        -- save this shorthand XMP property (upstream: a
                        -- custom XMPParseOpts.FoundProc, e.g. PLIST.pm's own
                        -- FoundTag, may replace the default FoundXMP)
                        if nodeID then
                            SaveBlankInfo(blankInfo, propList, shortVal)
                        elseif isWriting then
                            CaptureXMP(et, propList, shortVal)
                        else
                            if et.XmpValidate then ValidateProperty(et, propList) end
                            local foundProc = (et.XMPParseOpts and et.XMPParseOpts.FoundProc) or XMP.FoundXMP
                            foundProc(et, tagTablePtr, propList, shortVal)
                        end
                        propList[#propList] = nil
                        shorthand = 1
                    end
                end
            end

            if isWriting then
                -- capture the raw property instead of extracting a tag
                local subCount = XMP.ParseXMPElement(et, tagTablePtr, dataPt, valStart, valEnd, propList, blankInfo)
                if subCount > 0 then
                    -- (no value since we found more properties within this one)
                    -- set an error on any ignored attributes here, because they will be lost
                    if ignoredAttr then
                        et.XMP_ERROR = "Can't handle XMP attribute '" .. ignoredAttr .. "'"
                    end
                elseif not shorthand or valEnd ~= valStart then
                    local rawVal = ssub(dataPt, valStart + 1, valEnd)
                    -- remove comments and whitespace from rdf:Description only
                    if prop == 'rdf:Description' then
                        rawVal = subst(rawVal, [[<!--.*?-->]], '', 'g')
                        rawVal = rawVal:match('^[ \t\n\r\f\v]*(.-)[ \t\n\r\f\v]*$') or ''
                    end
                    if nodeID then
                        SaveBlankInfo(blankInfo, propList, rawVal, attrs)
                    else
                        CaptureXMP(et, propList, rawVal, attrs)
                    end
                end
            else
                -- look for additional elements contained within this one
                local subCount = XMP.ParseXMPElement(et, tagTablePtr, dataPt, valStart, valEnd, propList, blankInfo)
                if valStart == valEnd or subCount == 0 then
                    local wasEmpty
                    if val == nil then
                        val = ssub(dataPt, valStart + 1, valEnd)
                        -- remove comments and whitespace from rdf:Description only
                        if prop == 'rdf:Description' and val ~= '' then
                            val = subst(val, [[<!--.*?-->]], '', 'g')
                            val = val:match('^[ \t\n\r\f\v]*(.-)[ \t\n\r\f\v]*$') or ''
                        elseif wasComment and val ~= '' then
                            val = subst(val, [[<!--.*?-->]], '', 'g')
                        end
                        -- if element value is empty, take value from RDF 'value' or
                        -- 'resource' attribute (preferentially) or 'about' attribute
                        if val == '' then
                            local rv = attrs['rdf:value'] or attrs['rdf:resource']
                            if rv ~= nil then
                                val = rv
                                wasEmpty = 1
                            elseif attrs['rdf:about'] ~= nil then
                                val = attrs['rdf:about']
                                wasEmpty = 1
                            end
                        end
                    end
                    -- there are no contained elements, so this must be a simple property value
                    -- (unless we already extracted shorthand values from this element)
                    if #val > 0 or not shorthand then
                        local lastProp = propList[#propList]
                        if nodeID then
                            SaveBlankInfo(blankInfo, propList, val)
                        else
                            local etKind = lastProp and matches(lastProp, [[^et:(desc|prt|val)$]])
                            local etDesc = etKind and (count > 0 or etKind == 'desc')
                            if (lastProp == 'rdf:type' and wasEmpty) or etDesc then
                                -- do not extract empty structure types (for now);
                                -- ignore et:desc, and et:val if preceded by et:prt
                                if etDesc then count = count - 1 end
                            else
                                if et.XmpValidate then ValidateProperty(et, propList, attrs) end
                                local foundProc = (et.XMPParseOpts and et.XMPParseOpts.FoundProc) or XMP.FoundXMP
                                foundProc(et, tagTablePtr, propList, val, attrs)
                            end
                        end
                    end
                end
            end -- (isWriting)
            if not parseResource then
                propList[#propList] = nil
            end
            count = count + 1

            if pos >= end_ then break end
        end
        ::nextElement::
    end

    -- handle any error which aborted processing
    if err then et:Warn(err) end

    -- process resources referenced by blank nodeID's (upstream, after the
    -- parse loop)
    if processBlankInfo and next(blankInfo.Prop) then
        ProcessBlankInfo(et, tagTablePtr, blankInfo, et.XMP_CAPTURE ~= nil)
        blankInfo.Prop = {} -- free some memory
    end

    -- restore namespace lookup from the containing scope
    if saveNS then et.xlatNS = saveNS end

    return count -- return the number of elements found at this level
end

--------------------------------------------------------------------------------
-- Process XMP data
-- Inputs: 0) ExifTool object reference, 1) DirInfo reference, 2) Pointer to tag table
-- Returns: 1 on success
-- Notes: The following flavours of XMP files are currently recognized:
-- - standard XMP with xpacket, x:xmpmeta and rdf:RDF elements
-- - XMP that is missing the xpacket and/or x:xmpmeta elements
-- - mutant Microsoft XMP with xmp:xmpmeta element
-- - XML files beginning with "<xml"
-- - SVG files that begin with "<svg" or "<!DOCTYPE svg"
-- - XMP and XML files beginning with a UTF-8 byte order mark
-- - UTF-8, UTF-16 and UTF-32 encoded XMP
-- - erroneously double-UTF8 encoded XMP
-- - otherwise valid files with leading XML comment
function XMP.ProcessXMP(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    local dirStart, dirLen, dataLen, double -- luacheck: ignore 231 (dataLen: set, never read, as upstream)
    local buff, fmt, hasXMP, isXML, isRDF, isSVG
    local rtnVal = 0
    local bom = 0
    local path = et:MetadataPath()
    local n, hit, m1, m2

    -- namespaces and prefixes currently in effect while parsing the file,
    -- and lookup to translate brain-dead-Microsoft-Photo-software prefixes
    et.curURI = {}
    et.curNS = {}
    et.xlatNS = {}
    et.definedNS = {}
    et.XmpAbout = nil
    et.XmpValidate = nil        -- don't validate by default
    et.XmpValidateLangAlt = nil

    -- ignore non-standard XMP while in strict MWG compatibility mode
    -- (lexiftool.lua is required here, not at file scope, like the other
    --  ExifTool.* calls in this file)
    local ExifTool = require('lexiftool')
    if (ExifTool.MWGstrict() or truthy(et.OPTIONS.Validate)) and
        not (et.XMP_CAPTURE or et.DOC_NUM) and
        ((dirInfo.DirName or '') == 'XMP' or et.FILE_TYPE == 'XMP')
    then
        if truthy(et.OPTIONS.Validate) then et.XmpValidate = {} end
        local nonStd = (stdPath[et.FILE_TYPE] and path ~= stdPath[et.FILE_TYPE])
        if nonStd and ExifTool.MWGstrict() then
            et:Warn('Ignored non-standard XMP at ' .. path)
            return 1
        end
        if nonStd then
            et:Warn('Non-standard XMP at ' .. path, 1)
        elseif not dirInfo.IsExtended then
            if et.DIR_COUNT.XMP then et:Warn('Duplicate XMP at ' .. path) end
            et.DIR_COUNT.XMP = (et.DIR_COUNT.XMP or 0) + 1 -- count standard XMP
        end
    end
    if dataPt then
        dirStart = truthy(dirInfo.DirStart) and dirInfo.DirStart or 0
        dirLen = truthy(dirInfo.DirLen) and dirInfo.DirLen or (length(dataPt) - dirStart)
        dataLen = truthy(dirInfo.DataLen) and dirInfo.DataLen or length(dataPt)
        -- check leading BOM (may indicate double-encoded UTF)
        m1 = matches(dataPt, [[\G((\0\0)?\xfe\xff|\xff\xfe(\0\0)?|\xef\xbb\xbf)\0*<\0*\?\0*x\0*p\0*a\0*c\0*k\0*e\0*t]], dirStart)
        if m1 then
            double = m1
        else
            -- handle UTF-16/32 XML
            m1 = matches(dataPt, [[\G((\0\0)?\xfe\xff|\xff\xfe(\0\0)?|\xef\xbb\xbf)\0*<\0*\?\0*x\0*m\0*l\0* ]], dirStart)
            if m1 then
                local tmp = m1
                fmt = isMatch(tmp, [[\xfe\xff]]) and 'n' or 'v'
                if isMatch(tmp, [[\0\0]]) then fmt = uc(fmt) end
                isXML = 1
            end
        end
    else
        local type, mime, buf2, buf3
        -- read information from XMP file
        local raf = dirInfo.RAF
        if not raf then return 0 end
        n, buff = raf:Read(256)
        if n == 0 then return 0 end
        buf2 = tr(buff, '\0', '', 'd')  -- cheap conversion to UTF-8
        -- remove leading comments if they exist (eg. ImageIngester)
        while isMatch(buf2, [[^\s*<!--]]) do
            -- remove the comment if it is complete
            -- (`if ($buf2 =~ s/^\s*<!--.*?-->\s+//s)`: the test, then the
            --  substitution -- perl.subst returns no count)
            if isMatch(buf2, [[(?s)^\s*<!--.*?-->\s+]]) then
                buf2 = subst(buf2, [[(?s)^\s*<!--.*?-->\s+]], '')
                -- continue with parsing if we have more than 128 bytes remaining
                if length(buf2) > 128 then goto continue end
            else
                -- don't read more than 10k when looking for the end of comment
                if length(buf2) > 10000 then return 0 end
            end
            n, buf3 = raf:Read(256)  -- read more data if available
            if n == 0 then break end
            buff = buff .. buf3
            buf3 = tr(buf3, '\0', '', 'd')
            buf2 = buf2 .. buf3
            ::continue::
        end
        -- check to see if this is XMP format
        -- (CS2 writes .XMP files without the "xpacket begin")
        if isMatch(buf2, [[^\s*(<\?xpacket begin=|<x(mp)?:x[ma]pmeta)]]) then
            hasXMP = 1
        else
            -- also recognize XML files and .XMP files with BOM and without x:xmpmeta
            -- (isMatch: $1 may be an unmatched optional group)
            hit, m1, m2 = isMatch(buf2, [[^(\xfe\xff)(<\?xml|<rdf:RDF|<x(mp)?:x[ma]pmeta)]])
            if hit then
                fmt = 'n'       -- UTF-16 or 32 MM with BOM
            else
                hit, m1, m2 = isMatch(buf2, [[^(\xff\xfe)(<\?xml|<rdf:RDF|<x(mp)?:x[ma]pmeta)]])
                if hit then
                    fmt = 'v'   -- UTF-16 or 32 II with BOM
                else
                    hit, m1, m2 = isMatch(buf2, [[^(\xef\xbb\xbf)?(<\?xml|<rdf:RDF|<x(mp)?:x[ma]pmeta|<svg\b)]])
                    if hit then
                        fmt = 0     -- UTF-8 with BOM or unknown encoding without BOM
                    else
                        hit, m1, m2 = isMatch(buf2, [[^(\xfe\xff|\xff\xfe|\xef\xbb\xbf)(<\?xpacket begin=)]])
                        if hit then
                            double = m1 -- double-encoded UTF
                        else
                            return 0    -- not recognized XMP or XML
                        end
                    end
                end
            end
            if m1 then bom = 1 end
            if m2 == '<?xml' then
                if fmt ~= nil and not truthy(fmt) and isMatch(buf2, [[(?s)^[^\n\r]*[\n\r]+<\?aid ]]) then
                    et.XmpValidate = nil    -- don't validate INX
                    if et.XMP_CAPTURE then
                        et:Error('ExifTool does not yet support writing of INX files')
                        return 0
                    end
                    type = 'INX'
                elseif isMatch(buf2, [[<x(mp)?:x[ma]pmeta]]) then
                    hasXMP = 1
                else
                    et.XmpValidate = nil    -- don't validate XML
                    -- identify SVG images and PLIST files by DOCTYPE if available
                    local dt = matches(buf2, [[<!DOCTYPE\s+(\w+)]])
                    if dt then
                        if dt == 'svg' then
                            isSVG = 1
                        elseif dt == 'plist' then
                            type = 'PLIST'
                        elseif dt == 'REDXIF' then
                            type = 'RMD'
                            mime = 'application/xml'
                        elseif dt ~= 'fcpxml' then -- Final Cut Pro XML
                            return 0
                        end
                    elseif isMatch(buf2, [=[<svg[\s>]]=]) then
                        isSVG = 1
                    elseif isMatch(buf2, [[<rdf:RDF]]) then
                        isRDF = 1
                    elseif isMatch(buf2, [=[<plist[\s>]]=]) then
                        type = 'PLIST'
                    end
                end
                isXML = 1
            elseif m2 == '<rdf:RDF' then
                isRDF = 1       -- recognize XMP without x:xmpmeta element
            elseif m2 == '<svg' then
                isSVG = 1
                isXML = 1
            end
            if isSVG and et.XMP_CAPTURE then
                et:Error('ExifTool does not yet support writing of SVG images')
                return 0
            end
            if isMatch(buff, [[^\0\0]]) then
                fmt = 'N'       -- UTF-32 MM with or without BOM
            elseif isMatch(buff, [[(?s)^..\0\0]]) then
                fmt = 'V'       -- UTF-32 II with or without BOM
            elseif not truthy(fmt) then
                if isMatch(buff, [[^\0]]) then
                    fmt = 'n'   -- UTF-16 MM without BOM
                elseif isMatch(buff, [[(?s)^.\0]]) then
                    fmt = 'v'   -- UTF-16 II without BOM
                end
            end
        end
        local size
        if type then
            if type == 'PLIST' then
                local ext = et.FILE_EXT
                if ext and ext == 'MODD' then type = ext end
                tagTablePtr = et:GetTagTable('lexiftool.PLIST.Main')
                dirInfo.XMPParseOpts = dirInfo.XMPParseOpts or {}
                dirInfo.XMPParseOpts.FoundProc = require('lexiftool.PLIST').FoundTag
            end
        else
            if isSVG then
                type = 'SVG'
            elseif isXML and not hasXMP and not isRDF then
                type = 'XML'
                local ext = et.FILE_EXT
                if ext and ext == 'COS' then type = ext end -- recognize COS by extension
            end
        end
        et:SetFileType(type, mime)

        local fast = et:Options('FastScan')
        if fast and fast == 3 then return 1 end

        if type and type == 'INX' then
            -- brute force search for first XMP packet in INX file
            -- start: '<![CDATA[<?xpacket begin' (24 bytes)
            -- end:   '<?xpacket end="r"?>]]>'   (22 bytes)
            local gpos     -- (pos($buff))
            if not raf:Seek(0, 0) then return 0 end
            n, buff = raf:Read(65536)
            if n == 0 then return 1 end
            while true do
                -- (a failed //g match resets pos, so each test starts at 0)
                local _, e = matches(buff, [[<!\[CDATA\[<\?xpacket begin]])
                if e then gpos = e break end
                n, buf2 = raf:Read(65536)
                if n == 0 then return 1 end
                buff = substr(buff, -24) .. buf2
            end
            buff = substr(buff, gpos - 15) -- (discard '<![CDATA[' and before)
            gpos = 0
            while true do
                local _, e = matches(buff, [[<\?xpacket end="[rw]"\?>\]\]>]], gpos)
                if e then gpos = e break end
                local n0 = length(buff)
                n, buf2 = raf:Read(65536)
                if n == 0 then et:Warn('Missing xpacket end') return 1 end
                buff = buff .. buf2
                gpos = n0 - 22   -- don't miss end pattern if it was split
                -- (Perl counts a negative pos from the end; with fewer than
                --  22 bytes before the read starting over at 0 finds the same)
                if gpos < 0 then gpos = 0 end
            end
            size = gpos - 3     -- (discard ']]>' and after)
            buff = substr(buff, 0, size)
        else
            -- read the entire file
            if not raf:Seek(0, 2) then return 0 end
            size = raf:Tell()
            if size == 0 then return 0 end
            if not raf:Seek(0, 0) then return 0 end
            n, buff = raf:Read(size)
            if n ~= size then return 0 end
        end
        dataPt = buff
        dirStart = 0
        dirLen = size
        dataLen = size
    end

    -- decode the first layer of double-encoded UTF text (if necessary)
    if double then
        local buf2, fmt -- luacheck: ignore 421 (upstream's `my ($buf2, $fmt)` shadows $fmt too)
        buff = substr(dataPt, dirStart + length(double)) -- remove leading BOM
        ExifTool.SetWarning(nil) -- clear old warning
        local oldWarn = perl.SIG.__WARN__     -- (local $SIG{'__WARN__'})
        perl.SIG.__WARN__ = ExifTool.SetWarning
        -- assume that character data has been re-encoded in UTF, so re-pack
        -- as characters and look for warnings indicating a false assumption
        if double == "\xef\xbb\xbf" then
            local Charset = require('lexiftool.Charset')
            local uni = Charset.Decompose(nil, buff, 'UTF8')
            buf2 = pack('C*', tunpack(uni))
        else
            if length(double) == 2 then
                fmt = (double == "\xfe\xff") and 'n' or 'v'
            else
                fmt = (double == "\0\0\xfe\xff") and 'N' or 'V'
            end
            buf2 = pack('C*', unpack(fmt .. '*', buff))
        end
        perl.SIG.__WARN__ = oldWarn
        if truthy(ExifTool.GetWarning()) then
            if not dirInfo.RAF then et:Warn('Superfluous BOM at start of XMP') end
            dataPt = buff       -- use XMP with the BOM removed
        else
            et:Warn('XMP is double UTF-encoded')
            dataPt = buf2       -- use the decoded XMP
        end
        dirStart = 0
        dirLen = length(dataPt)
        dataLen = dirLen
    end

    -- extract XMP/XML as a block if specified
    local blockName = dirInfo.BlockInfo and dirInfo.BlockInfo.Name or 'XMP'
    local blockExtract = et:Options('BlockExtract')
    if ((et.REQ_TAG_LOOKUP and et.REQ_TAG_LOOKUP[lc(blockName)]) or (et.TAGS_FROM_FILE and
        not (et.EXCL_TAG_LOOKUP and et.EXCL_TAG_LOOKUP[lc(blockName)])) or truthy(blockExtract)) and
        ((et.FileType == 'XMP' and blockName == 'XMP') or
        (dirInfo.DirName and dirInfo.DirName == blockName))
    then
        et:FoundTag(dirInfo.BlockInfo or 'XMP', substr(dataPt, dirStart, dirLen))
        if truthy(blockExtract) and blockExtract > 1 then return 1 end
    end

    if not tagTablePtr then tagTablePtr = et:GetTagTable('lexiftool.XMP.Main') end
    if truthy(et:Options('Verbose')) and not et.XMP_CAPTURE then
        local dirType = isSVG and 'SVG' or tagTablePtr.GROUPS[1]
        et:VerboseDir(dirType, 0, dirLen)
    end
--
-- convert UTF-16 or UTF-32 encoded XMP to UTF-8 if necessary
--
    local begin = '<?xpacket begin='
    local dirEnd = dirStart + dirLen
    et.XMP_IS_XML = nil
    et.XMP_IS_SVG = nil
    -- (the third test's `$$dataPt =~ /<x(mp)?:x[ma]pmeta/gc` from $dirStart and
    --  its pos(), taken up front -- the match has no other effect; the group
    --  is non-capturing, so the end offset is the second result)
    local _, e = matches(dataPt, [[<x(?:mp)?:x[ma]pmeta]], dirStart)
    if isXML or isRDF then
        et.XMP_IS_XML = isXML
        et.XMP_IS_SVG = isSVG
        et.XMP_NO_XPACKET = 1 + bom
    elseif isMatch(dataPt, [[\G<\?xpacket begin=]], dirStart) then -- (`/\G\Q$begin\E/gc`)
        et.XMP_NO_XPACKET = nil
    elseif e and e > dirStart and e < dirEnd then
        et.XMP_NO_XPACKET = 1 + bom
    else
        et.XMP_NO_XPACKET = nil
        -- check for UTF-16 encoding (insert one \0 between characters)
        begin = join("\0", split('', begin))
        -- must reset pos because it was killed by previous unsuccessful //g match
        local badEnc
        m1, e = matchesDyn(dataPt, '(?s)\\G(\\0)?' .. quotemeta(begin) .. '\\0.', dirStart)
        if e then
            -- validate byte ordering by checking for U+FEFF character
            if m1 then
                -- should be big-endian since we had a leading \0
                fmt = 'n'
                if not isMatch(dataPt, [[\G\xfe\xff]], e) then badEnc = 1 end
            else
                fmt = 'v'
                if not isMatch(dataPt, [[\G\0\xff\xfe]], e) then badEnc = 1 end
            end
        else
            -- check for UTF-32 encoding (with three \0's between characters)
            begin = subst(begin, [[\0]], "\0\0\0", 'g')
            m1, e = matchesDyn(dataPt, '(?s)\\G(\\0\\0\\0)?' .. quotemeta(begin) .. '\\0\\0\\0.', dirStart)
            if not e then
                fmt = 0     -- set format to zero as indication we didn't find encoded XMP
            elseif m1 then
                -- should be big-endian
                fmt = 'N'
                if not isMatch(dataPt, [[\G\0\0\xfe\xff]], e) then badEnc = 1 end
            else
                fmt = 'V'
                if not isMatch(dataPt, [[\G\0\0\0\xff\xfe\0\0]], e) then badEnc = 1 end
            end
        end
        if badEnc then et:Warn('Invalid XMP encoding marker') end
    end
    -- warn if standard XMP is missing xpacket wrapper
    if et.XMP_NO_XPACKET and truthy(et.OPTIONS.Validate) and
        stdPath[et.FILE_TYPE] and path == stdPath[et.FILE_TYPE] and
        not dirInfo.IsExtended and not et.DOC_NUM
    then
        et:Warn('XMP is missing xpacket wrapper', 1)
    end
    if truthy(fmt) then
        -- trim if necessary to avoid converting non-UTF data
        if dirStart ~= 0 or dirEnd ~= length(dataPt) then
            buff = substr(dataPt, dirStart, dirLen)
            dataPt = buff
        end
        -- convert into UTF-8
        buff = pack('C0U*', unpack(fmt .. '*', dataPt))
        dataPt = buff
        dirStart = 0
        dirLen = length(dataPt)
        dirEnd = dirStart + dirLen
    end
    -- avoid scanning for XMP later in case ScanForXMP is set
    if tagTablePtr == XMP.Main then et.FoundXMP = 1 end

    -- set XMP parsing options
    et.XMPParseOpts = dirInfo.XMPParseOpts

    -- ignore any specified properties (XML hack)
    for k in pairs(ignoreProp) do ignoreProp[k] = nil end
    if dirInfo.IgnoreProp then
        for k, v in pairs(dirInfo.IgnoreProp) do ignoreProp[k] = v end
    end

    -- need to preserve list indices to be able to handle multi-dimensional lists
    local keepFlat
    if truthy(et.OPTIONS.Struct) then
        if perlStr(et.OPTIONS.Struct) == '2' then
            keepFlat = 1    -- preserve flattened tags
            -- setting NO_LIST to 0 combines list items in a TAG_EXTRA "NoList" element
            -- to allow them to be re-listed later if necessary.  A "NoListDel" element
            -- is also created for tags that wouldn't have existed.
            et.NO_LIST = 0
        else
            et.NO_LIST = 1
        end
    end

    -- don't generate structures if this isn't real XMP
    if dirInfo.BlockInfo or dirInfo.NoStruct then et.NO_STRUCT = 1 end

    -- parse the XMP
    if truthy(XMP.ParseXMPElement(et, tagTablePtr, dataPt, dirStart, dirEnd)) then
        rtnVal = 1
    elseif dirInfo.DirName and dirInfo.DirName == 'XMP' then
        -- if DirName was 'XMP' we expect well-formed XMP, so set Warning since it wasn't
        -- (but allow empty XMP as written by some PhaseOne cameras)
        local xmp = substr(dataPt, dirStart, dirLen)
        if isMatch(xmp, [[^ *\0*$]]) then
            et:Warn('Invalid XMP')
        else
            et:Warn('Empty XMP', 1)
            rtnVal = 1
        end
    end
    et.NO_STRUCT = nil

    -- return DataPt if successful in case we want it for writing
    if rtnVal ~= 0 and dirInfo.RAF then dirInfo.DataPt = dataPt end

    -- restore structures if necessary
    if et.IsStruct then
        if not dirInfo.NoStruct then
            XMP.RestoreStruct(et, keepFlat)
        end
        et.IsStruct = nil
    end
    -- reset NO_LIST flag (must do this _after_ RestoreStruct() above)
    et.NO_LIST = nil
    et.XMPParseOpts = nil
    et.curURI = nil
    et.curNS = nil
    et.xlatNS = nil
    et.definedNS = nil

    return rtnVal
end

-- (PROCESS_PROC is set here so the Main table can reference ProcessXMP, which
--  is defined after the tag tables in this file)
XMP.Main.PROCESS_PROC = XMP.ProcessXMP
XMP.XML.PROCESS_PROC = XMP.ProcessXMP

-- Composite XMP tags
XMP.Composite = {
    -- get latitude/longitude reference from XMP lat/long tags
    -- (used to set EXIF GPS position from XMP tags)
    GPSLatitudeRef = {
        TagID = 'XMP-GPSLatitudeRef',
        Require = 'XMP-exif:GPSLatitude',
        Groups = { [2] = 'Location' },
        -- Note: Do not Inihibit based on EXIF:GPSLatitudeRef (see forum10192)
        ValueConv = function(_self, val)
            if require('lexiftool').IsFloat(val[0]) then return perl.num(val[0]) < 0 and "S" or "N" end
            return (matches(val[0], [[^.*([NS])]]))
        end,
        PrintConv = { N = 'North', S = 'South' },
    },
    GPSLongitudeRef = {
        TagID = 'XMP-GPSLongitudeRef',
        Require = 'XMP-exif:GPSLongitude',
        Groups = { [2] = 'Location' },
        ValueConv = function(_self, val)
            if require('lexiftool').IsFloat(val[0]) then return perl.num(val[0]) < 0 and "W" or "E" end
            return (matches(val[0], [[^.*([EW])]]))
        end,
        PrintConv = { E = 'East', W = 'West' },
    },
    GPSDestLatitudeRef = {
        TagID = 'XMP-GPSDestLatitudeRef',
        Require = 'XMP-exif:GPSDestLatitude',
        Groups = { [2] = 'Location' },
        ValueConv = function(_self, val)
            if require('lexiftool').IsFloat(val[0]) then return perl.num(val[0]) < 0 and "S" or "N" end
            return (matches(val[0], [[^.*([NS])]]))
        end,
        PrintConv = { N = 'North', S = 'South' },
    },
    GPSDestLongitudeRef = {
        TagID = 'XMP-GPSDestLongitudeRef',
        Require = 'XMP-exif:GPSDestLongitude',
        Groups = { [2] = 'Location' },
        ValueConv = function(_self, val)
            if require('lexiftool').IsFloat(val[0]) then return perl.num(val[0]) < 0 and "W" or "E" end
            return (matches(val[0], [[^.*([EW])]]))
        end,
        PrintConv = { E = 'East', W = 'West' },
    },
    LensID = {
        TagID = 'XMP-LensID',
        Notes = 'attempt to convert numerical XMP-aux:LensID stored by Adobe applications',
        Require = {
            [0] = 'XMP-aux:LensID',
            [1] = 'Make',
        },
        Desire = {
            [2] = 'LensInfo',
            [3] = 'FocalLength',
            [4] = 'LensModel',
            [5] = 'MaxApertureValue',
        },
        Inhibit = {
            [6] = 'Composite:LensID',    -- don't override existing Composite:LensID
        },
        Groups = { [2] = 'Camera' },
        -- (upstream `ValueConv => '$val'`: the first Require value; the
        --  PrintConv gets the whole list as @val, see Exif.lua's LensID)
        ValueConv = function(_self, val) return val[0] end,
        PrintConv = function(self, _v, val)
            return XMP.PrintLensID(self, val[0], val[1], val[2], val[3], val[4], val[5], val[6])
        end,
    },
    Flash = {
        TagID = 'XMP-Flash',
        Notes = 'facilitates copying camera flash information between XMP and EXIF',
        Desire = {
            [0] = 'XMP:FlashFired',
            [1] = 'XMP:FlashReturn',
            [2] = 'XMP:FlashMode',
            [3] = 'XMP:FlashFunction',
            [4] = 'XMP:FlashRedEyeMode',
            [5] = 'XMP:Flash', -- handle structured flash information too
        },
        Groups = { [2] = 'Camera' },
        Writable = 1,
        PrintHex = 1,
        SeparateTable = 'EXIF Flash',
        ValueConv = function(_self, val)
            local v = {}
            for i = 0, 4 do v[i] = val[i] end
            if type(val[5]) == 'table' and val[5].ref == nil then
                -- copy structure fields into value array (only under -struct;
                -- otherwise the parser flattens Flash into its own fields)
                local fields = { 'Fired', 'Return', 'Mode', 'Function', 'RedEyeMode' }
                for i = 1, #fields do v[i - 1] = val[5][fields[i]] end
            end
            local bits = 0
            if v[0] and lc(v[0]) == 'true' then bits = bits | 0x01 end
            bits = bits | ((tonumber(v[1]) or 0) << 1)
            bits = bits | ((tonumber(v[2]) or 0) << 3)
            if v[3] and lc(v[3]) == 'true' then bits = bits | 0x20 end
            if v[4] and lc(v[4]) == 'true' then bits = bits | 0x40 end
            return bits
        end,
        PrintConv = Exif.flash,
        WriteAlso = {
            ['XMP:FlashFired']      = function(_self, val) return perl.int(val) & 0x01 ~= 0 and "True" or "False" end,
            ['XMP:FlashReturn']     = function(_self, val) return (perl.int(val) & 0x06) >> 1 end,
            ['XMP:FlashMode']       = function(_self, val) return (perl.int(val) & 0x18) >> 3 end,
            ['XMP:FlashFunction']   = function(_self, val) return perl.int(val) & 0x20 ~= 0 and "True" or "False" end,
            ['XMP:FlashRedEyeMode'] = function(_self, val) return perl.int(val) & 0x40 ~= 0 and "True" or "False" end,
        },
    },
}

-- add our composite tags
require('lexiftool').AddCompositeTags('lexiftool.XMP', nil, XMP)

--------------------------------------------------------------------------------
-- AutoLoad our writer routines when necessary
--
-- (upstream AUTOLOAD/DoAutoLoad loads WriteXMP.pl -- its subs are bound to
--  loader closures at their predeclaration position at the top of this file;
--  the subs of XMPStruct.pl are loaded by a `require
--  'Image/ExifTool/XMPStruct.pl'` right before a call.  Here they are bound as
--  closures that load XMPStruct.lua on first use, so XMP.ConvertStruct,
--  XMP.RestoreStruct, ... work for every caller)
for _, name in ipairs({ 'SerializeStruct', 'InflateStruct', 'EscapeJSON', 'GetLangCode', 'DumpStruct',
                        'CheckStruct', 'DeleteStruct', 'AddNewTag', 'AddNewStruct', 'ConvertStruct',
                        'RestoreStruct' }) do
    XMP[name] = function(...) return require('lexiftool.XMPStruct')[name](...) end
end

return XMP
