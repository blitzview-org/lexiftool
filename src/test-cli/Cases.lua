--------------------------------------------------------------------------------
-- File:         test-cli/Cases.lua
--
-- Description:  The CLI test matrix -- pure data, plus the flattening into the
--               list of individual test cases.
--
--               This is where new variants are added, and the only file one
--               needs to read to know WHAT is tested. It contains no logic
--               about how a case is executed or compared.
--
--               Every case is prepared, run and observed the SAME way -- there
--               is no per-kind comparison logic anywhere. The tables
--               below are declaration groups that share two defaults (see
--               Cases.GROUPS at the bottom): how the case's work/ directory is
--               filled, and whether the variant runs once per image or once
--               over the whole selection.
--
-- Matrices are derived 1:1 from the upstream POD OPTIONS reference
-- (vendor/exiftool/exiftool, "Option Details").
--
-- SCOPE: how many images a variant is run against. Crossing every option with
-- all 194 images is mostly redundant -- an output formatter like -s3 or -csv
-- exercises the same code path on the 195th file as on the 15th, and the cost
-- (reference cache size, generation time) grows with every option added.
--
--   'core' (default) -- one representative per format family (see CORE_IMAGES).
--                       Right for everything whose logic is format-independent:
--                       output formatting, tag selection, grouping, options.
--   'all'            -- all selected images. Reserved for variants where the
--                       format variety IS the test: plain extraction and the
--                       core write paths (writability differs wildly per
--                       format).
--
-- TEST_CLI_SCOPE=all overrides this and runs the full cross product.
--
-- IMAGES: a row may instead name its images explicitly, as basenames looked up
-- in both image directories: `images = { 'lex_Vorbis_TagNames.flac' }`. That is
-- for an option branch that only one format (or one fixture) reaches -- a
-- verbose dump, an embedded stream, a tag-name rule. Such a row is not a scope:
-- TEST_CLI_SCOPE=all leaves it alone, TEST_CLI_IMAGES/LIMIT narrow it like any
-- other selection, and a basename that exists in neither directory stops the
-- matrix build.
--------------------------------------------------------------------------------

local Expressions = require('test-cli.Expressions')

local Cases = {}

-- One file per format family: JPEG flavours (EXIF/IPTC/XMP/maker notes/GPS),
-- raw, TIFF, PNG/GIF, video, audio, documents, sidecar, container.
Cases.CORE_IMAGES = {
    'ExifTool.jpg',   -- EXIF + IPTC + XMP in one file (the all-rounder)
    'Canon.jpg',      -- maker notes
    'Nikon.jpg',      -- different maker notes
    'GPS.jpg',        -- GPS group
    'IPTC.jpg',       -- IPTC-heavy
    'ExifTool.tif',   -- TIFF
    'CanonRaw.cr2',   -- raw
    'PNG.png',        -- PNG chunks
    'GIF.gif',        -- GIF
    'QuickTime.mov',  -- video / QuickTime atoms
    'MP3.mp3',        -- audio / ID3
    'PDF.pdf',        -- document
    'XMP.xmp',        -- sidecar
    'Photoshop.psd',  -- PSD (no layers: LayerCount 0; the layer records are
                      --  covered by lex_PhotoshopLayers.psd via `default`)
}

-- Images whose readers print verbose output of their own (the dump-*
-- variants in READ)
local DUMP_IMAGES = {
    'DjVu.djvu', 'Font.dfont', 'ICO.ico', 'Jpeg2000.jp2', 'JXL2.jxl', 'LNK.lnk',
    'Lytro.lfp', 'M2TS.mts', 'MIFF.miff', 'Real.ra', 'Real.rm', 'Red.r3d',
    'Sigma.x3f', 'SigmaDP2.x3f', 'TNEF.tnef', 'WTV.wtv', 'ZIP.rar',
}

--------------------------------------------------------------------------------
-- Reading and other single-file calls. One case per image; work/in holds the
-- one file, and '@@' is its (quoted) path.

--------------------------------------------------------------------------------
Cases.READ = {
    -- The one variant that keeps the FULL image set: a plain `exiftool FILE`
    -- is what gives every one of the 148 format modules at least one CLI test,
    -- and it exercises more reader code than any other single call. Every
    -- other variant rides on the core formats -- see the SCOPE note above.
    { label = 'default',        args = '@@', scope = 'all' },
    { label = 'j',              args = '-j @@' },
    { label = 'ver',            args = '-ver @@' },
    { label = 'g',              args = '-g @@' },
    { label = 'g1',             args = '-g1 @@' },
    { label = 'g2',             args = '-g2 @@' },
    { label = 'g3',             args = '-g3 @@' },
    { label = 'G',              args = '-G @@' },
    { label = 'G1',             args = '-G1 @@' },
    { label = 'G2',             args = '-G2 @@' },
    { label = 'G3',             args = '-G3 @@' },
    { label = 'j-g1',           args = '-j -g1 @@' },
    { label = 'j-g2',           args = '-j -g2 @@' },
    { label = 'a',              args = '-a @@' },
    { label = 'a-G1',           args = '-a -G1 @@' },
    { label = 's',              args = '-s @@' },
    { label = 'S',              args = '-S @@' },
    { label = 's2',             args = '-s2 @@' },
    { label = 's3',             args = '-s3 @@' },
    { label = 'n',              args = '-n @@' },
    { label = 'D',              args = '-D @@' },
    { label = 'H',              args = '-H @@' },
    { label = 'struct',         args = '-struct @@' },
    { label = 'd',              args = "-d %Y-%m-%dT%H:%M:%S @@" },
    { label = 'c',              args = "-c %.6f @@" },
    -- Coordinate formatting is -c FMT; there is no -coord option (an earlier
    -- matrix entry invented one, which exiftool silently ignored -- the INERT
    -- check in the summary is what surfaced it).
    { label = 'c-gps',          args = '-c "%+.6f" -GPS:all @@' },
    { label = 'T',              args = '-T @@' },
    { label = 'csv',            args = '-csv @@' },
    { label = 'args',           args = '-args @@' },
    { label = 'f',              args = '-f @@' },
    { label = 'u',              args = '-u @@' },
    { label = 'U',              args = '-U @@' },
    { label = 'l',              args = '-l @@' },
    { label = 'L',              args = '-L @@' },
    { label = 'h',              args = '-h @@' },
    { label = 'E',              args = '-E @@' },
    { label = 'b',              args = '-b -MIMEType @@' },
    { label = 'x',              args = '-x File:all @@' },
    { label = 'e',              args = '-e @@' },
    { label = 'ee',             args = '-ee @@' },
    -- Everything the reader can reach, over the FULL image set: -a keeps the
    -- duplicates, -u the unknown tags, -ee the embedded/sub-document data, and
    -- -G1 names the family-1 group of each. `default` only shows what survives
    -- the priority rules; this variant is what catches a tag that is missing
    -- or misnamed underneath (e.g. unknown maker-note entries, ee-only
    -- streams) on formats outside the core selection.
    { label = 'a-u-ee-G1',      args = '-a -u -ee -G1 @@', scope = 'all' },
    { label = 'm',              args = '-m @@' },
    { label = 'q',              args = '-q @@' },
    { label = 'sort',           args = '-sort @@' },
    { label = 'sep',            args = "-sep ' | ' @@" },
    -- Output formats beyond -j/-csv.
    { label = 'X',              args = '-X @@' },
    { label = 'X-struct',       args = '-X -struct @@' },
    { label = 'php',            args = '-php @@' },
    { label = 'php-g1',         args = '-php -g1 @@' },
    -- NOTE: exiftool's $TAG references must be single-quoted -- the harness
    -- runs commands through a shell, which would otherwise expand them itself
    -- (leaving exiftool with an empty expression that silently does nothing).
    { label = 'p-fmt',          args = "-p '$FileName|$FileType|$MIMEType' @@" },
    { label = 't',              args = '-t @@' },
    { label = 's1',             args = '-s1 @@' },
    { label = 'csv-sel',        args = '-csv -FileName -FileType @@' },
    { label = 'csvDelim',       args = "-csv -csvDelim ';' @@" },
    { label = 'listItem',       args = '-listItem 0 -a -Keywords @@' },
    -- Tag selection: single tags, groups, exclusion, wildcards, numeric.
    { label = 'tag-one',        args = '-Model @@' },
    { label = 'tag-many',       args = '-Make -Model -FileType -FileSize @@' },
    { label = 'tag-group',      args = '-EXIF:all @@' },
    { label = 'tag-group2',     args = '-XMP:all -IPTC:all @@' },
    { label = 'tag-exclude',    args = '-a --System:all @@' },
    { label = 'tag-wildcard',   args = '"-*Date*" @@' },
    { label = 'tag-numeric',    args = '-Orientation# -FNumber# @@' },
    { label = 'tag-common',     args = '-S -ImageSize -Megapixels @@' },
    -- Verbose / diagnostic output.
    { label = 'v1',             args = '-v1 @@' },
    { label = 'v2',             args = '-v2 @@' },
    -- Behaviour and API switches.
    { label = 'fast',           args = '-fast -S @@' },
    { label = 'fast2',          args = '-fast2 -S @@' },
    { label = 'scanForXMP',     args = '-scanForXMP -S -XMP:all @@' },
    { label = 'charset-utf8',   args = '-charset UTF8 -S @@' },
    { label = 'charset-latin',  args = '-charset Latin -S @@' },
    { label = 'lang-de',        args = '-lang de -EXIF:all @@' },
    -- translated PrintConv values (XMP boolean structs, PrintConv lists) and
    -- their Decode into the output charset (-L: Latin-1)
    { label = 'lang-de-all',    args = '-lang de @@' },
    { label = 'lang-fr-L',      args = '-lang fr -L @@' },
    -- double-width descriptions: aligned by their display width in columns
    -- (Unicode::GCString), not by their number of characters
    { label = 'lang-ja',        args = '-lang ja @@' },
    { label = 'lang-zh_cn-s',   args = '-lang zh_cn -s @@' },
    { label = 'lang-ko-G1',     args = '-lang ko -a -G1 @@' },
    { label = 'lang-ru-G1',     args = '-lang ru -G1 @@' },
    -- Geolocation names translated by a GeoLang file in the GeoDir (an
    -- extract of the ru translations of the Geolocation500 package; Perl
    -- reads GeoLang/ru.pm, lexiftool the converted GeoLang/ru.lua beside
    -- it): city, region-specific, country and feature type entries; ja has
    -- no file there
    { label = 'geolang-ru',     args = '-api GeoDir=%REPO%/src/test/images/lex_Geolocation_GeoDir ' ..
                                       '-api Geolocation=1 -lang ru -G1 "-Geolocation*" @@',
      images = { 'GPS.jpg', 'Apple.jpg', 'GoPro.jpg', 'Google.jpg' } },
    { label = 'geolang-ru-j',   args = '-api GeoDir=%REPO%/src/test/images/lex_Geolocation_GeoDir ' ..
                                       '-api Geolocation=1 -lang ru -j "-Geolocation*" @@',
      images = { 'Google.jpg' } },
    { label = 'geolang-ja',     args = '-api GeoDir=%REPO%/src/test/images/lex_Geolocation_GeoDir ' ..
                                       '-api Geolocation=1 -lang ja "-Geolocation*" @@',
      images = { 'Google.jpg' } },
    -- the same GeoLang/ru.pm alone in its GeoDir: both read the .pm (lexiftool
    -- as data); the .lua-before-.pm order is a port test (test_cli_port.lua)
    { label = 'geolang-ru-pm',  args = '-api GeoDir=%REPO%/src/test/images/lex_Geolocation_GeoDirPm ' ..
                                       '-api Geolocation=1 -lang ru -G1 "-Geolocation*" @@',
      images = { 'GPS.jpg', 'Apple.jpg', 'GoPro.jpg', 'Google.jpg' } },
    { label = 'api-compact',    args = '-api Compact=NoPadding -j @@' },
    -- ImageDataHash over the FULL image set: the digest is fed by a hash path
    -- of each format module's own (JPEG segments, TIFF strip/tile offsets,
    -- PNG IDAT, QuickTime/HEIC media data, RIFF chunks, JP2/JXL boxes, the
    -- raw readers), so only the full set reaches them all. The other digest
    -- variants ride on the core formats.
    { label = 'imageDataHash',  args = '-ImageDataHash @@', scope = 'all' },
    { label = 'hash-v',         args = '-v -ImageDataHash @@' },
    { label = 'imageDataMD5',   args = '-ImageDataMD5 @@' },
    { label = 'hash-sha256',    args = '-api ImageHashType=SHA256 -ImageDataHash @@' },
    { label = 'hash-sha512',    args = '-api ImageHashType=sha512 -ImageDataHash @@' },
    -- an unknown type warns and keeps MD5; a type without a request does nothing
    { label = 'hash-bad',       args = '-api ImageHashType=SHA1 -ImageDataHash @@' },
    { label = 'hash-type-only', args = '-api ImageHashType=SHA256 -S -FileType @@' },
    { label = 'userParam',      args = "-userParam Lexi=1 -p '$Lexi $FileName' @@" },
    { label = 'echo',           args = '-echo LexiStart -S -FileName @@' },
    { label = 'if-jpeg',        args = [[-if '$FileType eq "JPEG"' -S -FileType @@]] },
    { label = 'v',              args = '-v @@' },
    { label = 'F',              args = '-F -S -MakerNotes:all @@' },
    { label = 'z',              args = '-z -S @@' },
    { label = 'use-mwg',        args = '-use MWG -S -MWG:all @@' },
    { label = 'htmlDump',       args = '-htmlDump @@' },
    { label = 'k-pause',        args = '-k -S -FileName @@' },
    { label = 'a-G1-s2',        args = '-a -G1 -s2 @@' },
    { label = 'g1-struct',      args = '-g1 -struct @@' },
    { label = 'n-j',            args = '-n -j @@' },
    { label = 'a-s-G1',         args = '-a -s -G1 @@' },
    -- -g/-G crossed with the structured formats: each of these once took a
    -- path of its own in the tag loop (exiftool:2740-2767) and differed.
    { label = 'j-G1',           args = '-j -G1 @@' },
    { label = 'csv-g1',         args = '-csv -g1 @@' },
    { label = 'h-g1',           args = '-h -g1 @@' },
    { label = 'T-G1',           args = '-T -G1 @@' },
    { label = 'args-g1',        args = '-args -g1 @@' },
    -- several families in one group name, and the last -g/-G winning
    { label = 'G0-1',           args = '-G0:1 @@' },
    { label = 'G1-g0',          args = '-G1 -g0 @@' },
    -- -G with requested tags keeps their order: no group sort (exiftool:1853)
    { label = 'G1-tags',        args = '-G1 -FileType -Make -Model @@' },
    -- -v0 defines $verbose but leaves it false: normal listing (exiftool:1695)
    { label = 'v0-g1',          args = '-v0 -g1 @@' },
    -- -D/-H/-l/-s change the value shape of -j and -X (exiftool:2863-2982)
    { label = 'j-D',            args = '-j -D @@' },
    { label = 'j-H',            args = '-j -H @@' },
    { label = 'j-l',            args = '-j -l @@' },
    { label = 'X-D',            args = '-X -D @@' },
    { label = 'X-l',            args = '-X -l @@' },
    { label = 'X-s',            args = '-X -s @@' },
    -- -f prints requested tags that were not found (exiftool:2732-2736)
    { label = 'f-tags',         args = '-f -G1 -Make -LexiNothing @@' },
    { label = 'X-f-tags',       args = '-X -f -Make -LexiNothing @@' },
    -- an Exclude picks one key per tag name BEFORE the group sort
    { label = 'G2-exclude',     args = '-G2 --FileModifyDate @@' },
    -- the whole IPTC/EXIF block, extracted only when requested
    -- (IPTC.pm:1117-1125, ExifTool.pm:3147-3154)
    { label = 'b-IPTC',         args = '-b -IPTC @@' },
    { label = 'b-EXIF',         args = '-b -EXIF @@' },
    -- -v with requested tags keeps the tag listing (exiftool:1696)
    { label = 'v-tag',          args = '-v -Make @@' },
    -- -t names the tag table as upstream spells it: 'Exif::Main', 'Extra',
    -- one 'Composite' (ExifTool.pm:4613, 8978)
    { label = 'j-t',            args = '-j -t @@' },
    { label = 'X-t',            args = '-X -t @@' },
    -- -E in XML: non-ASCII as HTML entities (exiftool:3741)
    { label = 'X-E',            args = '-X -E @@' },
    -- -b with -X/-j: binary data as base64 ($binaryOutput = 0, exiftool:1645)
    { label = 'X-b',            args = '-X -b @@' },
    { label = 'j-b',            args = '-j -b @@' },
    -- -b alone: PrintConv off, lists joined with newlines (exiftool:1840, 2719)
    { label = 'b-all',          args = '-b @@' },
    -- -n leaves lists to the CLI, which joins them with -sep (exiftool:2726)
    { label = 'n-sep',          args = "-n -sep '|' @@" },
    -- -htmlDump with tags appends them as an HTML table ($html = 2)
    { label = 'htmlDump-tag',   args = '-htmlDump -Make -FileSize @@' },
    -- -htmlDump is -v plus html mode; $html decides after the argument loop
    -- which dump the verbose level becomes (exiftool:1119-1124, 1694-1704)
    { label = 'v-h',            args = '-v -h @@' },
    -- (short label: the -v trace snips Directory, the case path must fit)
    { label = 'hd-j',           args = '-htmlDump -j @@' },
    -- -h/-X/-j exclude each other, the last one wins (exiftool:947-949,
    -- 1114-1115, 1379); -j leaves Duplicates on, -h leaves $escapeHTML set
    { label = 'X-h',            args = '-X -h @@' },
    { label = 'j-h',            args = '-j -h @@' },
    { label = 'h-X',            args = '-h -X @@' },
    { label = 'h-j',            args = '-h -j @@' },
    -- -E escapes through the library's Escape option unless -X (exiftool:1590)
    { label = 'E-j',            args = '-E -j @@' },
    { label = 'E-csv',          args = '-E -csv @@' },
    -- -csv next to -X/-h: the XML/HTML frame per file wins, the tag loop
    -- only collects the CSV header, PrintCSV prints it (exiftool:2643-2685)
    { label = 'X-csv',          args = '-X -csv @@' },
    { label = 'h-csv',          args = '-h -csv @@' },
    -- pure binary output: the first -sep separates list items, a second one
    -- terminates each value (exiftool:1249-1250, 2724, 2802)
    { label = 'b-sep',          args = "-b -sep '|' -sep '\\n' -Keywords -Make @@" },
    -- Option branches only certain formats reach, each on the files that
    -- reach it (an explicit `images` list, see the IMAGES note above).
    -- Vorbis comment names (Vorbis.pm:189-195): the description hides them,
    -- only the tag names in -s/-j show the rule
    { label = 'vorbis-s',       args = '-s -a -u -G1 @@',
      images = { 'lex_Vorbis_TagNames.flac' } },
    { label = 'vorbis-j',       args = '-j @@',
      images = { 'lex_Vorbis_TagNames.flac' } },
    -- Ogg page and packet dumps (Ogg.pm ProcessPacket/ProcessOGG): Theora,
    -- Vorbis and Ogg-FLAC streams
    { label = 'ogg-v2',         args = '-v2 @@',
      images = { 'lex_Ogg_Theora.ogv', 'Vorbis.ogg', 'FLAC.ogg' } },
    -- RIFF chunk trace: chained RIFF/AVIX chunks, LIST_movi under -ee, RF64
    -- with its 64-bit data size
    { label = 'riff-ee-v3',     args = '-ee -v3 @@',
      images = { 'lex_RIFF_AVIX.avi', 'RIFF.avi', 'lex_RIFF_RF64.wav' } },
    { label = 'riff-ee-valid',  args = '-ee -validate @@',
      images = { 'lex_RIFF_AVIX.avi', 'RIFF.avi', 'lex_RIFF_RF64.wav' } },
    -- FastScan: no buffering, LIST_movi ends the parse without -ee
    { label = 'riff-fast-v',    args = '-fast -v @@',
      images = { 'lex_RIFF_AVIX.avi', 'RIFF.avi', 'lex_RIFF_RF64.wav' } },
    -- audio readers: FLAC block loop, ID3 trailers, APE and MPC headers
    { label = 'audio-v3',       args = '-v3 @@',
      images = { 'lex_FLAC_ID3.flac', 'lex_FLAC_ID3v1.flac', 'lex_FLAC_ManyBlocks.flac',
                 'FLAC.flac', 'lex_APE_ID3v1.ape', 'APE.ape', 'lex_MPC_NoID3.mpc',
                 'APE.mpc' } },
    -- compressed containers: Flash CWS/FWS tags, compressed and binary PLIST,
    -- deflated DICOM
    { label = 'flash-v3',       args = '-v3 @@',
      images = { 'Flash.swf', 'lex_Flash_CWS.swf' } },
    { label = 'plist-v3',       args = '-v3 @@',
      images = { 'PLIST.aae', 'lex_PLIST_Compressed.aae', 'PLIST-bin.plist' } },
    { label = 'dicom-v',        args = '-v @@',
      images = { 'DICOM.dcm', 'lex_DICOM_Deflated.dcm' } },
    -- 7z headers (LZMA-encoded, plain, encrypted) and Rawzor's bzip2-
    -- compressed metadata, from which the original raw is re-assembled and
    -- read recursively
    { label = 'archive-v3',     args = '-v3 @@',
      images = { 'lex_7Z_EncodedHeader.7z', 'lex_7Z_PlainHeader.7z',
                 'lex_7Z_Encrypted.7z', 'lex_Rawzor_NEF.rwz' } },
    { label = 'archive-j',      args = '-j @@',
      images = { 'lex_7Z_EncodedHeader.7z', 'lex_7Z_PlainHeader.7z',
                 'lex_7Z_Encrypted.7z', 'lex_Rawzor_NEF.rwz' } },
    -- the dump of the outer file with the offsets of the embedded raw:
    -- blocks beyond its end are read partially, as Perl's Read does
    { label = 'rwz-htmlDump',   args = '-htmlDump @@',
      images = { 'lex_Rawzor_NEF.rwz' } },
    -- XMP parsing paths: prefix validation, base64 datatype, double-encoded
    -- UTF-8/UTF-16, superfluous BOM
    { label = 'xmp-v',          args = '-v @@',
      images = { 'lex_XMP_InvalidPrefix.xmp', 'lex_XMP_Base64.xmp',
                 'lex_XMP_DoubleUTF8.xmp', 'lex_XMP_DoubleUTF16.xmp',
                 'lex_XMP_SuperfluousBOM.jpg' } },
    -- FastScan 3 stops a TIFF after its type is known (DoProcessTIFF)
    { label = 'tiff-fast3',     args = '-fast3 -S @@',
      images = { 'ExifTool.tif', 'BigTIFF.btf', 'lex_ExifTool_MultiPage.tif',
                 'lex_ExifTool_DNGVersion.tif', 'lex_ExifTool_NRW.nrw' } },
    -- Sony ARW: SR2Private/SR2SubIFD, IDC previews, the MRW block of an A100
    { label = 'arw-v3',         args = '-v3 @@',
      images = { 'lex_Sony_SR2Private.arw', 'lex_Sony_A100.arw' } },
    { label = 'arw-htmlDump',   args = '-htmlDump @@',
      images = { 'lex_Sony_SR2Private.arw', 'lex_Sony_A100.arw' } },
    { label = 'arw-X',          args = '-X @@',
      images = { 'lex_Sony_SR2Private.arw', 'lex_Sony_A100.arw' } },
    -- PPM header parse over more than one read buffer, a comment after the
    -- size, a SEAL comment
    { label = 'ppm-v3',         args = '-v3 @@',
      images = { 'lex_PPM_LongComment.ppm', 'lex_PPM_SEAL.pgm', 'PPM.ppm' } },
    -- OpenEXR attributes: EXIF/XMP subdirectories, generated tag names,
    -- tiledesc/stringvector values, the frames of a multipart image
    { label = 'exr-v3',         args = '-v3 @@',
      images = { 'lex_OpenEXR_ExifXMP.exr', 'lex_OpenEXR_Multipart.exr', 'OpenEXR.exr' } },
    { label = 'exr-ee',         args = '-ee -a -u -G3:1 @@',
      images = { 'lex_OpenEXR_ExifXMP.exr', 'lex_OpenEXR_Multipart.exr', 'OpenEXR.exr' } },
    -- M2TS dashcam GPS on the PIDs the -ee3 scan registers
    { label = 'm2ts-ee3',       args = '-ee3 -a -u -G3:1 @@',
      images = { 'lex_M2TS_DashcamGPS.ts', 'M2TS.mts' } },
    { label = 'm2ts-ee3-v3',    args = '-ee3 -v3 @@',
      images = { 'lex_M2TS_DashcamGPS.ts' } },
    -- the hash paths' -v messages on the fixtures that feed them
    { label = 'hash-v-fx',      args = '-v -ImageDataHash @@',
      images = { 'lex_RIFF_AVIX.avi', 'lex_Sony_SR2Private.arw', 'lex_Sony_A100.arw',
                 'lex_ExifTool_DNGVersion.tif', 'lex_ExifTool_NRW.nrw' } },
    -- file type detection (ExtractInfo's loop over the candidate types): the
    -- extension's types first, then all others; unknown-header JPEG/TIFF
    -- scan; unsupported types; FastScan 3 (type only, processType procs) and
    -- FastScan 4 (type from the extension, file not read)
    { label = 'ft-v',           args = '-v @@',
      images = { 'lex_ExifTool_UnknownHeader.jpg', 'lex_ExifTool_WrongExt.tif',
                 'lex_ExifTool_Unsupported.bz2', 'lex_QuickTime_NoExt',
                 'lex_Red_Truncated.r3d', 'lex_FLIR_FFF.fff', 'lex_DICOM_ACR.acr',
                 'lex_MPEG_Video.mpg', 'lex_ExifTool_RecognizedExt.dir',
                 'lex_ExifTool_Zeros.jpg' } },
    { label = 'ft-fast3',       args = '-fast3 -G1 -FileType -FileTypeExtension -MIMEType -Error -Warning @@',
      images = { 'lex_ExifTool_UnknownHeader.jpg', 'lex_ExifTool_WrongExt.tif',
                 'lex_ExifTool_Unsupported.bz2', 'lex_QuickTime_NoExt',
                 'lex_Red_Truncated.r3d', 'lex_FLIR_FFF.fff', 'lex_DICOM_ACR.acr',
                 'lex_MPEG_Video.mpg', 'lex_ExifTool_RecognizedExt.dir',
                 'lex_ExifTool_Zeros.jpg', 'AIFF.aif', 'DjVu.djvu', 'Real.rm', 'Real.ram',
                 'Text.csv', 'XMP.xmp', 'EXE.exe', 'Font.ttf', 'VCard.vcf' } },
    { label = 'ft-fast4',       args = '-fast4 -G1 -FileType -FileTypeExtension -MIMEType -Error -Warning @@',
      images = { 'lex_ExifTool_UnknownHeader.jpg', 'lex_ExifTool_WrongExt.tif',
                 'lex_ExifTool_Unsupported.bz2', 'lex_QuickTime_NoExt',
                 'lex_DICOM_ACR.acr', 'Font.pfm', 'PFM.pfm', 'Canon.jpg' } },
    -- maker notes base fix (MakerNotes.pm FixBase): -fixBase without a value
    -- applies the suggested fix, with a value it forces that base; the
    -- fixtures have shifted value offsets, entry-based offsets and a Canon
    -- TIFF footer with the original maker note offset
    { label = 'fixbase',        args = '-fixBase -a -u -G1 @@',
      images = { 'lex_MakerNotes_BadOffsets.jpg', 'lex_MakerNotes_EntryBased.jpg',
                 'lex_MakerNotes_CanonFooter.jpg', 'Canon.jpg', 'Olympus.jpg',
                 'Sony.jpg' } },
    { label = 'fixbase-8',      args = '-fixBase8 -a -u -G1 @@',
      images = { 'lex_MakerNotes_BadOffsets.jpg', 'lex_MakerNotes_EntryBased.jpg',
                 'lex_MakerNotes_CanonFooter.jpg', 'Canon.jpg', 'Canon1DmkIII.jpg',
                 'Olympus.jpg', 'Pentax.jpg', 'Panasonic.jpg' } },
    { label = 'fixbase-neg',    args = '-F-4 -a -u -G1 @@',
      images = { 'lex_MakerNotes_BadOffsets.jpg', 'lex_MakerNotes_CanonFooter.jpg',
                 'Sony.jpg' } },
    { label = 'makernotes-v',   args = '-v @@',
      images = { 'lex_MakerNotes_BadOffsets.jpg', 'lex_MakerNotes_EntryBased.jpg',
                 'lex_MakerNotes_CanonFooter.jpg' } },
    -- shortcuts in the RequestTags/IgnoreTags API options (ExpandShortcuts)
    { label = 'api-reqtags',    args = '-api RequestTags=ls-l -G1 @@' },
    { label = 'api-ignoretags', args = '-api IgnoreTags=CommonIFD0 -a -G1 @@' },
    { label = 'api-reqtags-grp', args = '-api RequestTags=System:ls-l -G1 @@',
      images = { 'Canon.jpg' } },
    -- Plot settings accumulate over several -api Plot options
    { label = 'api-plot',       args = '-plot -api Plot=Size=300x200 -api Plot=Title=T -FNumber -ISO @@',
      images = { 'Canon.jpg', 'ExifTool.jpg' } },
    -- GlobalTimeShift taken from a given tag, onto a date Time::Local
    -- rejects (month 18): the shift fails and the value stays as it is
    { label = 'gts-baddate',    args = '-globalTimeShift FileModifyDate+1 -PostScript:CreateDate @@',
      images = { 'PostScript.eps' } },
    -- Geolocation database directory set through Options (GeoDir)
    { label = 'api-geodir-bad', args = '-api GeoDir=nonexistent -api Geolocation -G1 -Geolocation* @@',
      images = { 'GPS.jpg' } },
    { label = 'api-geodir-off', args = '-api GeoDir^= -api Geolocation -G1 -Geolocation* @@',
      images = { 'GPS.jpg' } },
    -- family 5 groups (SavePath): the metadata path of each tag, MXF's
    -- object-tree names, XMP-embedded directories
    { label = 'G5',             args = '-G5 -a -u @@' },
    { label = 'G5-path',        args = '-G5 -a -u @@',
      images = { 'MXF.mxf', 'Google.jpg', 'XMP.svg' } },
    { label = 'G1-5-j',         args = '-j -G1:5 -a @@',
      images = { 'MXF.mxf' } },
    -- family 6 groups and binary values (SaveFormat, SaveBin): EXIF formats,
    -- the "hex" and "rat" fields of -j -l
    { label = 'G6',             args = '-G6 -a -u @@' },
    { label = 'j-l-savebin',    args = '-j -l -G1:6 -api SaveBin -a @@' },
    { label = 'j-l-savebin-fx', args = '-j -l -G1:6 -api SaveBin -a @@',
      images = { 'LNK.lnk', 'CanonVRD.dr4', 'lex_PhotoshopLayers.psd' } },
    -- DR4 directory entries: verbose directory headers, per-entry format/flags
    { label = 'dr4-v3',         args = '-v3 @@',
      images = { 'CanonVRD.dr4' } },
    -- ExtractEmbedded: the frames of an MRC extended header (one more frame
    -- claimed than present) and of a FLIR SEQ file (raw data of the later
    -- frames only with -ee2)
    { label = 'mrc-ee',         args = '-ee -a -u -G3:1 @@',
      images = { 'MRC.mrc', 'lex_MRC_Frames.mrc' } },
    { label = 'mrc-ee-v3',      args = '-ee -v3 @@',
      images = { 'lex_MRC_Frames.mrc' } },
    { label = 'seq-ee',         args = '-ee -a -u -G3:1 @@',
      images = { 'lex_FLIR_SEQ.seq', 'lex_FLIR_FFF.fff', 'FLIR.jpg' } },
    { label = 'seq-ee2',        args = '-ee2 -a -u -G3:1 @@',
      images = { 'lex_FLIR_SEQ.seq' } },
    { label = 'seq-ee-v3',      args = '-ee -v3 @@',
      images = { 'lex_FLIR_SEQ.seq' } },
    -- ExtractEmbedded given as a string through -api
    { label = 'api-ee-0',       args = '-api ExtractEmbedded=0 -a -u -G1 @@',
      images = { 'QuickTime.mov', 'Garmin.fit', 'ExifTool.jpg' } },
    { label = 'api-ee-3',       args = '-api ExtractEmbedded=3 -a -u -G3:1 @@',
      images = { 'QuickTime.mov', 'lex_FLIR_SEQ.seq' } },
    -- LargeFileSupport: headers that claim offsets or sizes beyond 2 GB in
    -- small files; 0 refuses them, 2 warns, the default 1 goes on
    { label = 'lfs-0',          args = '-api LargeFileSupport=0 -a -u -G1 @@',
      images = { 'lex_BigTIFF_HugeOffsets.btf', 'lex_InDesign_Large.indd',
                 'lex_ASF_LargeObject.wmv', 'lex_AIFF_LargeChunk.aif',
                 'lex_ZIP_RARLargeBlock.rar', 'lex_Matroska_LargeBlock.mkv' } },
    { label = 'lfs-2',          args = '-api LargeFileSupport=2 -a -u -G1 @@',
      images = { 'lex_BigTIFF_HugeOffsets.btf', 'lex_InDesign_Large.indd',
                 'lex_ASF_LargeObject.wmv', 'lex_AIFF_LargeChunk.aif',
                 'lex_ZIP_RARLargeBlock.rar', 'lex_Matroska_LargeBlock.mkv' } },
    { label = 'lfs-2-v3',       args = '-api LargeFileSupport=2 -v3 @@',
      images = { 'lex_BigTIFF_HugeOffsets.btf', 'lex_InDesign_Large.indd',
                 'lex_ASF_LargeObject.wmv', 'lex_AIFF_LargeChunk.aif' } },
    -- verbose and HTML dumps of the readers around them
    { label = 'btf-htmlDump',   args = '-htmlDump @@',
      images = { 'BigTIFF.btf', 'lex_BigTIFF_HugeOffsets.btf' } },
    { label = 'lfs-fmt-v3',     args = '-v3 @@',
      images = { 'ASF.wmv', 'InDesign.indd', 'AIFF.aif', 'lex_AIFF_EmptyChunks.aif' } },
    -- Option values as Perl passes them: -api and -v2/-fast2/-if2/-htmlDump0
    -- hand over strings ('0', '2'), which Perl reads as false resp. as a
    -- number; one image per reader that tests or compares the value
    { label = 'api-v2',         args = '-api Verbose=2 @@',
      images = { 'ExifTool.tif', 'QuickTime.heic', 'CanonRaw.crw' } },
    { label = 'api-v3',         args = '-api Verbose=3 @@',
      images = { 'PICT.pict', 'AFCP.jpg' } },
    { label = 'api-fast2',      args = '-api FastScan=2 -a -u -G1 @@',
      images = { 'Canon.jpg', 'Text1.txt' } },
    { label = 'api-fast3',      args = '-api FastScan=3 -a -G1 @@',
      images = { 'PostScript.eps', 'XMP.xmp' } },
    { label = 'if2',            args = [[-if2 '$make' -Make @@]],
      images = { 'Canon.jpg' } },
    { label = 'api-limit-10',   args = '-api LimitLongValues=10 -a -u -U -G1 @@',
      images = { 'Canon.jpg' } },
    { label = 'api-nowarning',  args = '-api NoWarning -a -G1 @@',
      images = { 'ExifTool.jpg' } },
    { label = 'api-composite-0', args = '-api Composite=0 -a -G1 @@',
      images = { 'ExifTool.jpg' } },
    { label = 'api-m-0',        args = '-api IgnoreMinorErrors=0 -a -G1 @@',
      images = { 'ExifTool.jpg' } },
    { label = 'api-binary-0',   args = '-api Binary=0 -a -G1 @@',
      images = { 'ExifTool.jpg' } },
    { label = 'api-validate-0', args = '-api Validate=0 -a -u -G1 @@',
      images = { 'ExifTool.jpg' } },
    -- -validate: the Validate tag with its warnings on the core formats, and
    -- the module-local checks on the images that reach them (EXIF text
    -- headers, PNG date and CRC, QuickTime duplicates, Sony HiddenData, XMP
    -- namespace scopes, wrong extension, IPTC record without a tag)
    { label = 'validate',       args = '-validate -warning -error -a -G1 @@' },
    { label = 'validate-fx',    args = '-validate -warning -error -a -G1 @@',
      images = { 'lex_Exif_TextHeader.tif', 'lex_PNG_Validate.png',
                 'lex_QuickTime_Validate.mov', 'lex_Sony_HiddenData.jpg',
                 'lex_Sony_HiddenDataMissing.jpg', 'lex_XMP_Namespaces.xmp',
                 'lex_ExifTool_DNGVersion.tif', 'lex_ExifTool_WrongExt.tif',
                 'lex_ExifTool_NRW.nrw', 'FotoStation.jpg' } },
    { label = 'validate-v',     args = '-validate -v @@',
      images = { 'lex_PNG_Validate.png', 'lex_QuickTime_Validate.mov',
                 'lex_Sony_HiddenData.jpg' } },
    { label = 'api-datefmt-0',  args = '-api DateFormat=0 -a -G1 @@',
      images = { 'IPTC.jpg' } },
    { label = 'api-coordfmt-0', args = '-api CoordFormat=0 -a -u -G1 @@',
      images = { 'GPS.jpg' } },
    { label = 'api-coordfmt',   args = '-api CoordFormat -a -u -G1 @@',
      images = { 'GPS.jpg' } },
    { label = 'api-blockext-2', args = '-api BlockExtract=2 -a -u -G1 @@',
      images = { 'XMP.jpg' } },
    { label = 'api-unknown-2',  args = '-api Unknown=2 -a -u -G1 @@',
      images = { 'Matroska.mkv' } },
    { label = 'api-struct-2',   args = '-api Struct=2 -a -u -G1 @@',
      images = { 'JSON.json' } },
    { label = 'api-makernotes-0', args = '-api MakerNotes=0 -a -u -G1 @@',
      images = { 'CanonRaw.crw' } },
    { label = 'api-qtutc-0',    args = '-api QuickTimeUTC=0 -a -G1 -Time:All @@',
      images = { 'QuickTime.mov' } },
    { label = 'api-htmlDump-2', args = '-api HtmlDump=2 @@',
      images = { 'ExifTool.jpg' } },
    { label = 'htmlDump0',      args = '-htmlDump0 @@',
      images = { 'GE.jpg' } },
    { label = 'm-ge',           args = '-m -a -u -G1 @@',
      images = { 'GE.jpg' } },
    -- Composite values as numbers (ToFloat sees the inputs as Perl strings)
    -- and their build order when maker notes are skipped; a GeoTiff
    -- directory kept by RequestAll and met again in a later TIFF
    { label = 'composite-n',    args = '-n -a -G1 -Composite:all @@',
      images = { 'Lytro.lfp', 'DNG.dng' } },
    { label = 'composite-j-l',  args = '-j -l -Composite:all @@',
      images = { 'Lytro.lfp' } },
    { label = 'fast2-a-u-G1',   args = '-fast2 -a -u -G1 @@',
      images = { 'DNG.dng' } },
    { label = 'api-reqall-geotiff', args = '-api RequestAll -a -G1 -Warning -GTModelType -GeoTiffAsciiParams @@',
      images = { 'Jpeg2000.jp2' } },
    -- verbose and HTML dumps found on the way
    { label = 'opt-v2',         args = '-v2 @@',
      images = { 'Flash.flv', 'FLIF.flif' } },
    { label = 'opt-v3',         args = '-v3 @@',
      images = { 'Garmin.fit', 'FLIF.flif', 'GIF.gif' } },
    { label = 'opt-htmlDump',   args = '-htmlDump @@',
      images = { 'Panasonic.rw2' } },
    -- verbose dumps of the container readers: every level prints its own
    -- lines (directory headers, chunk/box/resource traces, decoded blocks,
    -- extension tails, descriptor lists), -v5 the unabridged hex
    { label = 'dump-v',         args = '-v @@',     images = DUMP_IMAGES },
    { label = 'dump-v2',        args = '-v2 @@',    images = DUMP_IMAGES },
    { label = 'dump-v3',        args = '-v3 @@',    images = DUMP_IMAGES },
    { label = 'dump-v5',        args = '-v5 @@',    images = DUMP_IMAGES },
    { label = 'dump-htmlDump',  args = '-htmlDump @@',
      images = { 'Jpeg2000.jp2', 'JXL2.jxl', 'MIFF.miff', 'SigmaDP2.x3f',
                 'lex_OpenEXR_ExifXMP.exr' } },
    -- encrypted PDFs (RC4 40/128-bit, AES-128/256; empty user password):
    -- the owner password, and -m to decrypt the large AES-encrypted stream
    -- that is skipped otherwise
    { label = 'pdf-password',   args = '-password owner -a -G1 @@',
      images = { 'lex_PDF_RC4_40.pdf', 'lex_PDF_RC4_128.pdf',
                 'lex_PDF_AES128.pdf', 'lex_PDF_AES256.pdf' } },
    { label = 'pdf-aes-large',  args = '-m -a -G1 @@',
      images = { 'lex_PDF_AES128.pdf' } },
}

--------------------------------------------------------------------------------
-- Writing and copying. Like the group above, plus work/src.jpg as the '%SRC%'
-- source for -tagsFromFile/-file1. What the call did shows up in work/ and thus
-- in stat.txt -- no special "which file counts" rule is needed.
--------------------------------------------------------------------------------
Cases.WRITE = {
    -- The write-side counterpart to read/default: XMP is the most widely
    -- writable group, so this one call gives every format module at least one
    -- write test -- and the "which formats are writable at all" matrix that
    -- goes with it. Every other write variant rides on the core formats.
    { label = 'w-Subject',      args = '-XMP:Subject=LexiTest @@', scope = 'all' },
    { label = 'w-Keywords+',    args = '-Keywords+=LexiTest @@' },
    { label = 'w-Author',       args = '-Author=Jane Doe @@' },
    { label = 'w-Orientation',  args = '-Orientation#=1 @@' },
    { label = 'w-all-del',      args = '-all= @@' },
    { label = 'w-tagsFromFile', args = '-tagsFromFile %SRC% -all:all @@' },
    -- Trailing slash: -o takes a DIRECTORY here, so the output keeps the source
    -- name and extension. (A bare path would make exiftool derive the output
    -- format from that path's extension instead.)
    { label = 'w-o',            args = '-o %OUT%/ -all @@' },
    { label = 'w-overwrite',    args = '-overwrite_original -XMP:Subject=LexiTest @@' },
    { label = 'w-in-place',     args = '-overwrite_original_in_place -Artist=LexiTest @@' },
    -- -P keeps FileModifyDate across the write.
    { label = 'w-preserve',     args = '-P -overwrite_original -Artist=LexiTest @@' },
    -- Date arithmetic instead of assignment.
    { label = 'w-shift',        args = '-overwrite_original "-AllDates+=1:0:0 0:0:0" @@' },
    { label = 'w-shift-copy',   args = '-overwrite_original -globalTimeShift "0:0:0 1:0:0" -tagsFromFile %SRC% -AllDates @@' },
    -- Dates through GetUnixTime: one Time::Local rejects, one it takes with
    -- fractional seconds
    { label = 'w-baddate',      args = '-overwrite_original "-QuickTime:CreateDate=2007:02:30 00:00:00" "-QuickTime:ModifyDate=2007:01:01 12:00:60.5" @@',
      images = { 'QuickTime.mov' } },
    -- Geotime without a track log
    { label = 'w-geotime-notrack', args = '-overwrite_original "-geotime=2011:10:26 19:07:28Z" @@',
      images = { 'Canon.jpg' } },
    -- Deletion at tag and group level.
    { label = 'w-del-tag',      args = '-overwrite_original -Artist= @@' },
    { label = 'w-del-group',    args = '-overwrite_original -EXIF:all= @@' },
    { label = 'w-del-xmp',      args = '-overwrite_original -XMP:all= @@' },
    -- Write-mode restrictions (-wm cg: create groups only, never update).
    { label = 'w-wm-cg',        args = '-overwrite_original -wm cg -Artist=LexiTest @@' },
    { label = 'w-wm-w',         args = '-overwrite_original -wm w -Artist=LexiTest @@' },
    -- Conditional and typed writes.
    { label = 'w-if',           args = [[-overwrite_original -if '$FileType eq "JPEG"' -Artist=LexiTest @@]] },
    { label = 'w-numeric',      args = '-overwrite_original -Orientation#=6 @@' },
    { label = 'w-sep',          args = '-overwrite_original -sep ", " -Keywords="a, b, c" @@' },
    { label = 'w-charset',      args = '-overwrite_original -charset UTF8 -Artist="Ümläut" @@' },
    { label = 'w-struct',       args = '-overwrite_original "-XMP:Contributor=[{Name=A},{Name=B}]" @@' },
    -- Copying with an explicit source->target mapping, not just -all:all.
    { label = 'w-tff-map',      args = '-overwrite_original -tagsFromFile %SRC% "-XMP:Creator<EXIF:Artist" @@' },
    { label = 'w-tff-group',    args = '-overwrite_original -tagsFromFile %SRC% -EXIF:all @@' },
    { label = 'w-addTFF',       args = '-overwrite_original -addTagsFromFile %SRC% -Keywords @@' },
    -- -v0 while writing prints the "========" line (exiftool:2291)
    { label = 'w-v0',           args = '-v0 -overwrite_original -Artist=LexiTest @@' },
    -- Info strings encrypted on writing, RC4 only: AES encrypts with a random
    -- IV (seeded from the time and the process id), so the written bytes
    -- differ from run to run
    { label = 'w-pdf-rc4',      args = '-overwrite_original -Title=LexiTest -Author=LexiTest @@',
      images = { 'lex_PDF_RC4_40.pdf', 'lex_PDF_RC4_128.pdf' } },
    -- PPM comment rewrite, and the SEAL comment deleted with its group
    { label = 'w-ppm-comment',  args = '-Comment=LexiTest @@',
      images = { 'lex_PPM_LongComment.ppm', 'lex_PPM_SEAL.pgm', 'PPM.ppm' } },
    { label = 'w-ppm-seal-del', args = '-v -SEAL:all= @@',
      images = { 'lex_PPM_LongComment.ppm', 'lex_PPM_SEAL.pgm' } },
    -- MinoltaRaw ISOSetting in an ARW: the inverse conversion, the PrintConv
    -- names, a zero and a value it rejects (and the A100 rewrite through
    -- FinishARW)
    { label = 'w-mrw-iso',      args = '-MinoltaRaw:ISOSetting=283 @@',
      images = { 'lex_Sony_SR2Private.arw', 'lex_Sony_A100.arw' } },
    { label = 'w-mrw-iso-auto', args = '-MinoltaRaw:ISOSetting=Auto @@',
      images = { 'lex_Sony_SR2Private.arw', 'lex_Sony_A100.arw' } },
    { label = 'w-mrw-iso-0',    args = '-MinoltaRaw:ISOSetting=0 @@',
      images = { 'lex_Sony_SR2Private.arw', 'lex_Sony_A100.arw' } },
    { label = 'w-mrw-iso-bad',  args = '-MinoltaRaw:ISOSetting=abc @@',
      images = { 'lex_Sony_SR2Private.arw', 'lex_Sony_A100.arw' } },
    -- option values given as strings on the write side
    { label = 'w-api-m-0',      args = '-api IgnoreMinorErrors=0 -Artist=LexiTest @@',
      images = { 'JXL.jxl' } },
    { label = 'w-api-v2',       args = '-api Verbose=2 -Artist=LexiTest @@',
      images = { 'ExifTool.jpg', 'GE.jpg' } },
    -- writing EXIF next to Sony HiddenData (a wrong offset is fixed, missing
    -- data is dropped) and into a PNG with bad CRCs (minor error)
    { label = 'w-hidden',       args = '-Artist=LexiTest @@',
      images = { 'lex_Sony_HiddenData.jpg', 'lex_Sony_HiddenDataMissing.jpg' } },
    { label = 'w-png-crc',      args = '-Artist=LexiTest @@',
      images = { 'lex_PNG_Validate.png' } },
    { label = 'w-png-crc-m',    args = '-m -Artist=LexiTest @@',
      images = { 'lex_PNG_Validate.png' } },
    -- a large iCCP chunk deflated again (memLevel decides the bytes beyond
    -- about 16k deflate symbols): rewritten in place, and created anew
    { label = 'w-png-iccp',     args = '-tagsFromFile @ -ICC_Profile @@',
      images = { 'lex_PNG_LargeICC.png' } },
    { label = 'w-png-iccp-new', args = '-tagsFromFile %REPO%/src/test/images/lex_PNG_LargeICC.png -ICC_Profile @@',
      images = { 'PNG.png' } },
    -- GeoHPosErr: a Perl expression of $GPSDOP (any case) evaluated for each
    -- geotagged fix with a DOP; an invalid one is a minor warning, which only
    -- -v shows
    { label = 'w-geotag-hposerr', args = [[-geotag %REPO%/src/test/images/lex_Geotag_DOP.gpx -api 'GeoHPosErr=$GPSDOP*5' ]] ..
                                         [['-Geotime=2003:05:24 17:09:21Z' @@]],
      images = { 'ExifTool.jpg' } },
    { label = 'w-geotag-hposerr-lc', args = [[-geotag %REPO%/src/test/images/lex_Geotag_DOP.gpx ]] ..
                                         [[-api 'GeoHPosErr=sprintf("%.1f", $gpsdop * 2 + 1)' '-Geotime=2003:05:24 17:09:41Z' @@]],
      images = { 'ExifTool.jpg' } },
    { label = 'w-geotag-hposerr-syntax', args = [[-v -geotag %REPO%/src/test/images/lex_Geotag_DOP.gpx -api 'GeoHPosErr=$GPSDOP*' ]] ..
                                         [['-Geotime=2003:05:24 17:09:21Z' @@]],
      images = { 'ExifTool.jpg' } },
    { label = 'w-geotag-hposerr-die', args = [[-v -geotag %REPO%/src/test/images/lex_Geotag_DOP.gpx -api 'GeoHPosErr=$GPSDOP/0' ]] ..
                                         [['-Geotime=2003:05:24 17:09:21Z' @@]],
      images = { 'ExifTool.jpg' } },
    -- QuickTime alternate-language tags: Keys entries (created, kept alive
    -- by an alternate while the default is deleted), ItemList 'data' atoms
    -- with language/country codes, UserData international text, and the
    -- codes they reject
    { label = 'w-qt-lang-keys', args = '-v3 -Keys:Title=K1 -Keys:Title-de=K2 -Keys:Artist-fr-FR=K3 @@',
      images = { 'QuickTime.mov', 'QuickTime.m4a' } },
    { label = 'w-qt-lang-keys-alt', args = '-v3 -Keys:Artist= -Keys:Artist-fr=X -Keys:Album-de=Y @@',
      images = { 'QuickTime.mov' } },
    { label = 'w-qt-lang-ilst', args = '-v3 -ItemList:Title-de=X -ItemList:Title-fr-CA=Y -ItemList:Title-ger=W -ItemList:Artist=Z @@',
      images = { 'QuickTime.mov', 'QuickTime.m4a' } },
    { label = 'w-qt-lang-ilst-def', args = '-v3 -ItemList:Title= -ItemList:Title-de=X @@',
      images = { 'QuickTime.mov', 'QuickTime.m4a' } },
    { label = 'w-qt-lang-udta', args = '-v3 -UserData:Title-ger=G -UserData:Title=T -UserData:Information-ger=I -UserData:Artist=A2 -UserData:Composer= @@',
      images = { 'QuickTime.mov', 'QuickTime.m4a' } },
    { label = 'w-qt-lang-bad',  args = '-v3 -ItemList:Title-x=Y -UserData:Artist-ger-DE=X -UserData:Make-fr=Y @@',
      images = { 'QuickTime.mov' } },
    -- Keys entries deleted (the ItemList renumbered), and track Keys
    -- (Audio/VideoKeys, created once the track's media type is known)
    { label = 'w-qt-keys-del',  args = '-v3 -Keys:Album= -Keys:Comment=C2 @@',
      images = { 'QuickTime.mov' } },
    { label = 'w-qt-keys-av',   args = '-v3 -AudioKeys:AudioGain=0.5 -VideoKeys:LensModel=L -VideoKeys:LensModel-de=LL @@',
      images = { 'QuickTime.mov', 'lex_WriteQuickTime_ExtRef.mp4' } },
    -- QuickTime writes per track (CUR_WRITE_GROUP Track1..n)
    { label = 'w-qt-track',     args = '-v3 "-Track1:TrackModifyDate=2020:01:01 00:00:00" @@',
      images = { 'QuickTime.mov' } },
    -- QuickTime files with trailers (known ones identified from the end of
    -- the file, others from their first bytes after the last atom), garbage
    -- or HTML at the end, an Insta360 box, an external data reference,
    -- movie fragments, a sidx box, and boxes that must come last
    { label = 'w-qt-file',      args = '-v -XMP:Subject=x @@',
      images = { 'lex_WriteQuickTime_Trailers.mov', 'lex_WriteQuickTime_Kenwood.mov',
                 'lex_WriteQuickTime_RIFFTrailer.mov', 'lex_WriteQuickTime_UnknownTrailer.mov',
                 'lex_WriteQuickTime_Garbage.mov', 'lex_WriteQuickTime_HTML.mov',
                 'lex_WriteQuickTime_InstBox.mp4', 'lex_WriteQuickTime_ExtRef.mp4',
                 'lex_WriteQuickTime_Fragmented.mp4', 'lex_WriteQuickTime_SIDX.mp4',
                 'lex_WriteQuickTime_VRD.cr3', 'lex_WriteQuickTime_MotionPhoto.heic' } },
    { label = 'w-qt-file-m',    args = '-v -m -XMP:Subject=x @@',
      images = { 'lex_WriteQuickTime_Garbage.mov', 'lex_WriteQuickTime_HTML.mov' } },
    { label = 'w-qt-trail-del', args = '-v -Trailer:all= @@',
      images = { 'lex_WriteQuickTime_Trailers.mov', 'lex_WriteQuickTime_Kenwood.mov' } },
    { label = 'w-qt-trail-one', args = '-v -Insta360:all= -MIE-Doc:Title=new @@',
      images = { 'lex_WriteQuickTime_Trailers.mov' } },
    { label = 'w-qt-trail-mie', args = '-v -MIE:all= @@',
      images = { 'lex_WriteQuickTime_Trailers.mov' } },
    -- HEIC item properties: only those of the primary item are written, and
    -- none is deleted
    { label = 'w-qt-iprp',      args = '-v3 -QuickTime:Rotation#=3 @@',
      images = { 'lex_WriteQuickTime_Rotation.heic' } },
    { label = 'w-qt-iprp-del',  args = '-v3 -QuickTime:Rotation= @@',
      images = { 'lex_WriteQuickTime_Rotation.heic' } },
    -- WriteLast boxes (after the media data): rewritten, created, deleted
    { label = 'w-qt-last',      args = '-v3 "-MotionPhotoVideo<=%AUX%/Writer.jpg" @@',
      images = { 'lex_WriteQuickTime_MotionPhoto.heic' } },
    { label = 'w-qt-last-del',  args = '-v3 -MotionPhotoVideo= @@',
      images = { 'lex_WriteQuickTime_MotionPhoto.heic' } },
    { label = 'w-qt-vrd',       args = '-v3 "-CanonVRD<=%AUX%/CanonVRD.vrd" @@',
      images = { 'CanonRaw.cr3', 'lex_WriteQuickTime_VRD.cr3' } },
    { label = 'w-qt-vrd-del',   args = '-v3 -CanonVRD:all= @@',
      images = { 'lex_WriteQuickTime_VRD.cr3' } },
    -- new XMP item in a HEIC, deflated by the Compress option
    { label = 'w-qt-compress',  args = '-v3 -api Compress=1 -XMP:Subject=x @@',
      images = { 'QuickTime.heic' } },
    -- QuickTimePad: padded XMP rewritten in place
    { label = 'w-qt-pad',       args = '-v3 -api QuickTimePad=1 -XMP:Subject=x @@',
      images = { 'CanonRaw.cr3', 'lex_WriteQuickTime_VRD.cr3' } },
    -- TIFF-based files rewritten by DoProcessTIFF: the 'ExifMeta' header
    -- signature of an EXIF file, an EXIF file larger than its block read,
    -- TIFF variants told apart by the header identifier, a BigTIFF named
    -- .tif, trailers after the TIFF data (blank, unknown after 64 kB of
    -- zeros, after a pad byte, AFCP, A100 raw data), a DOS EPS preview and
    -- an empty APP1 EXIF segment
    { label = 'w-tiff-file',    args = '-v -Artist=x @@',
      images = { 'lex_ExifTool_ExifMeta.exif', 'lex_ExifTool_LargeExif.exif',
                 'lex_ExifTool_ORF.tif', 'lex_ExifTool_DCP.tif', 'lex_ExifTool_HDP2.tif',
                 'lex_ExifTool_PanasonicRaw.raw', 'lex_ExifTool_BigTIFF.tif',
                 'lex_ExifTool_BlankTrailer.tif', 'lex_ExifTool_LongTrailer.tif',
                 'lex_ExifTool_PadTrailer.tif', 'lex_ExifTool_AFCPTrailer.tif',
                 'lex_Sony_A100.arw', 'lex_PostScript_DOSTIFF.eps',
                 'lex_ExifTool_EmptyExif.jpg' } },
    { label = 'w-tiff-trail-del', args = '-v -Trailer:all= @@',
      images = { 'lex_ExifTool_LongTrailer.tif', 'lex_ExifTool_AFCPTrailer.tif' } },
    -- an EXIF file created from scratch, a new EXIF block in the requested
    -- byte order, a new GPS directory in a CR3 (byte order of its EXIF)
    { label = 'w-exif-new',     args = '-o out/new.exif @@',
      images = { 'Canon.jpg' } },
    { label = 'w-exif-order',   args = '-api ByteOrder=II -Artist=x @@',
      images = { 'PNG.png' } },
    { label = 'w-cr3-gps',      args = '-v -GPSLatitude=12.5 -GPSLatitudeRef=N @@',
      images = { 'lex_ExifTool_NoGPS.cr3' } },
    -- DNG version check after writing (a minor error unless -m)
    { label = 'w-dng-version',  args = '"-DNGVersion=1 8 0 0" @@',
      images = { 'DNG.dng' } },
    { label = 'w-dng-version-m', args = '-m "-DNGVersion=1 8 0 0" @@',
      images = { 'DNG.dng' } },
    -- CompositeImageExposureTimes: packed EXIF values and the XMP structure
    { label = 'w-compexp',      args = '"-CompositeImageExposureTimes=1/8 0.5 0.25 1/30 1/60 1/1000 0.001 3 4 0.01 0.02 1.5" '
          .. '"-XMP-exifEX:CompositeImageExposureTimes={TotalExposurePeriod=0.5,NumberOfSequences=2,Values=[0.1,0.2]}" @@',
      images = { 'Canon.jpg' } },
    -- a new file name that differs from an existing file in case only
    -- (IsSameFile: a temporary file tells a case-insensitive filesystem)
    { label = 'w-samefile',     args = '-o SRC.JPG %SRC% -execute -FileName=SRC.JPG %SRC%',
      images = { 'Canon.jpg' } },
}

--------------------------------------------------------------------------------
-- Whole-directory invocations, and calls that need no file at all. These run
-- ONCE over the whole image selection rather than per image, because their
-- subject is the directory: renames, changed mtimes, backup files, extra output
-- files.
-- Placeholders: %IN% work/in, %OUT% the empty work/out, %SRC% the
-- shared -tagsFromFile source, %AUX% the pristine image dir (read-only helper
-- inputs like geotag logs), %REPO% the checkout root (config files). Note that
-- exiftool's own %-formats (%Y, %%f, %%e) live in the same string --
-- placeholder substitution is literal, so they pass through untouched.
--------------------------------------------------------------------------------
Cases.DIR = {
    -- Rename into a target dir via a date format (the classic archiving call).
    { label = 'd-rename',       args = '"-FileName<CreateDate" -o %OUT% -d "%Y-%m-%d-%H.%Cases.%S-<NAME>-%%f.%%e" %IN%' },
    -- Same, with a weekday name (%a) -- locale-dependent, hence the pinned LC_ALL.
    { label = 'd-rename-wday',  args = '"-FileName<CreateDate" -o %OUT% -d "%Y-%m-%d-%a-%H%M%S-name.%%e" %IN%' },
    -- Copy a tag onto the filesystem timestamp: the result is stat(), not bytes.
    { label = 'd-tag2mtime',    args = "'-CreateDate>FileModifyDate' %IN%" },
    -- Time shift on the AllDates shortcut, in place (no _original backups).
    { label = 'd-shift',        args = '-overwrite_original "-AllDates-=0:0:0 1:0:0" %IN%' },
    -- Same shift without -overwrite_original: _original backups MUST appear.
    { label = 'd-shift-backup', args = '"-AllDates+=0:0:0 0:30:0" %IN%' },
    -- -P preserves FileModifyDate across a write.
    { label = 'd-preserve',     args = '-P -overwrite_original -Artist=LexiTest %IN%' },
    { label = 'd-recurse',      args = '-r -S -FileName -FileSize %IN%' },
    { label = 'd-ext',          args = '-ext jpg -S -FileType %IN%' },
    { label = 'd-if',           args = [[-if '$FileType eq "JPEG"' -S -FileName %IN%]] },
    -- Every Perl expression the documentation shows (exiftool POD: -if,
    -- "Advanced formatting feature" with its helper functions; ExifTool.pod
    -- SetNewValuesFromFile; the shipped fmt_files), run by perl.eval in the
    -- port: they must give exactly upstream's result.
    { label = 'd-expr-if-eq',   args = [[-S -FileName -if '$make eq "Canon"' %IN%]] },
    { label = 'd-expr-if-ge',   args = [[-S -FileName -if '$CreateDate ge "2006:04:02"' %IN%]] },
    { label = 'd-expr-if-not',  args = [[-S -FileName -if 'not $exif:iso' %IN%]] },
    { label = 'd-expr-if-re',   args = [[-S -FileName -if '$keywords =~ /harvey/i' %IN%]] },
    { label = 'd-expr-if-nre',  args = [[-S -FileName -if '$fileattributes !~ /Hidden/' %IN%]] },
    { label = 'd-expr-trs',     args = [[-p '${make;tr/ /_/;s/__+/_/g}' %IN%]] },
    { label = 'd-expr-list',    args = [[-p '${subject@;$_=undef if /xxx/}' %IN%]] },
    { label = 'd-expr-empty',   args = [[-p '${model;}' %IN%]] },
    { label = 'd-expr-datefmt', args = [[-d %Y -p '${createdate#;DateFmt("%Y-%m-%d_%H%M%S")}' %IN%]] },
    { label = 'd-expr-shift',   args = [[-p '${createdate;ShiftTime("-1:0:0 0")}' %IN%]] },
    { label = 'd-expr-nodups',  args = [[-sep '##' -p '${keywords;NoDups}' %IN%]] },
    { label = 'd-expr-nodups1', args = [[-sep '##' -p '${keywords;NoDups(1)}' %IN%]] },
    { label = 'd-expr-settags', args = [[-p '${previewimage;SetTags}' -b %IN%/ExifTool.jpg]] },
    { label = 'd-expr-settag2', args = [[-p '${previewimage;SetTags("comment=test","title<filename")}' -b %IN%/ExifTool.jpg]] },
    { label = 'd-expr-subst',   args = [[-p '${FileName;s/\.[^.]*$//}' %IN%]] },
    { label = 'd-expr-trparen', args = [[-p '${model; tr(/\\\\?*:|"><)(_) }.jpg' %IN%]] },
    { label = 'd-expr-gpx',     args = [[-p %REPO%/vendor/exiftool/fmt_files/gpx.fmt %IN%]] },
    { label = 'd-expr-kmltrk',  args = [[-ee -p %REPO%/vendor/exiftool/fmt_files/kml_track.fmt %IN%]] },
    -- (beyond the documentation: constructs users write, run by perl.eval)
    { label = 'd-expr-my',      args = [[-p '${keywords;my @a = split /, /, $_; $_ = "$a[0]/" . scalar(@a)}' %IN%]] },
    { label = 'd-expr-sprintf', args = [[-p '${make;$_ = lc($_) . sprintf("_%03d", length)}' %IN%]] },
    { label = 'd-expr-block',   args = [[-p '${createdate;my ($y,$m) = /^(\d+):(\d+)/; if ($y > 2003) { $_ = "new $m" } else { $_ = "old $1" }}' %IN%]] },
    { label = 'd-expr-foreach', args = [[-p '${keywords;my $n = 0; for my $k (split /, /) { $n++ unless $k =~ /^\d/ } $_ = "$n words"}' ]] ..
                                       [[-p '${filename;my $s = ""; foreach (split //) { last if $_ eq "."; next if /\d/; $s .= $_ } $_ = $s}' %IN%]] },
    { label = 'd-expr-cfor',    args = [[-p '${createdate;my @t = /(\d+)/g; my $s = 0; for (my $i = 0; $i < @t; $i += 2) { $s += $t[$i] } $_ = $s}' ]] ..
                                       [[-p '${createdate;my @t = /(\d+)/g; my $s = 0; $s += shift @t while @t; $_ = $s}' %IN%]] },
    { label = 'd-expr-hash',    args = [[-p '${make;my %abbr = (Canon => "C", NIKON => "N", FUJIFILM => "F"); ]] ..
                                       [[$_ = exists $abbr{$_} ? $abbr{$_} : "?"} ${keywords;my %seen; ]] ..
                                       [[$_ = join "+", grep { !$seen{lc $_}++ } split /, /}' %IN%]] },
    { label = 'd-expr-refs',    args = [[-p '${keywords;my $r = [split /, /]; $_ = scalar(@$r) . ":" . ($$r[-1] // "") . ":$r->[0]"} ]] ..
                                       [[${make;my $h = { name => $_, len => length }; $_ = "$h->{name}/$$h{len}/" . ref $h}' %IN%]] },
    { label = 'd-expr-return',  args = [[-S -FileName -if 'return 0 unless defined $Make; my @w = split / /, $Make; return @w == 1' %IN%]] },
    { label = 'd-expr-self',    args = [[-p '${filename;$_ = ref $self} ${make;$_ = $self->GetValue("Model") . "|" . ]] ..
                                       [[join(",", sort { $a <=> $b } (3, 1, 2))}' %IN%]] },
    -- (-if fails on a Perl warning: an undef tag value, a string that is no
    --  number; with -v the warning is shown)
    { label = 'd-expr-if-raw',  args = [[-S -FileName -if '$Orientation# != 1' %IN%]],
      images = { 'Canon.jpg', 'MWG.jpg', 'Pentax.jpg', 'QuickTime.mov' } },
    { label = 'd-expr-if-nreb', args = [[-S -FileName -if '$Keywords !~ /\btest\b/i' %IN%]],
      images = { 'IPTC.jpg', 'ExifTool.jpg', 'ExifTool.tif', 'MWG.jpg', 'QuickTime.mov' } },
    { label = 'd-expr-if-rvar', args = [[-S -FileName -if '$Make and $Model =~ /$Make/i' %IN%]],
      images = { 'Canon.jpg', 'Nikon.jpg', 'ExifTool.jpg', 'QuickTime.mov' } },
    { label = 'd-expr-if-warn', args = [[-v -if '$Orientation# != 1 or $Make != 1' %IN%]],
      images = { 'Canon.jpg', 'Nikon.jpg', 'QuickTime.mov' } },
    { label = 'd-expr-case',    args = [[-p '${model;s/(\w+)/\u\L$1/g}' %IN%]] },
    { label = 'd-expr-case2',   args = [[-p '${make;$_ = "\U$_\E-\l$_-\Q$_"} ${model;s/(\w)(\w*)/\l$1\U$2/g}' %IN%]] },
    { label = 'd-expr-slice',   args = [[-p '${CreateDate;$_ = (split / /)[0]}' %IN%]] },
    { label = 'd-expr-slice2',  args = [[-p '${CreateDate;my ($s, @r) = (split /:/)[-1, 0, 1]; $_ = join "|", $s, @r, (1, 2)[5]}' %IN%]] },
    { label = 'd-expr-sort',    args = [[-p '${keywords;$_ = join ",", sort { lc($a) cmp lc($b) } split /, /} ]] ..
                                       [[${ImageSize;$_ = join "x", sort { $b <=> $a } split /x/}' %IN%]] },
    { label = 'd-expr-reverse', args = [[-p '${filename;$_ = reverse} ${keywords;$_ = join "/", reverse split /, /}' %IN%]] },
    { label = 'd-expr-pkgfunc', args = [[-p '${FileSize#;$_ = Image::ExifTool::ConvertFileSize($_)} ${FileSize#;$_ = ConvertFileSize($_ * 3)}' %IN%]] },
    { label = 'd-expr-warn',    args = [[-p '${model;$_ = $_ + 1}' %IN%]] },
    -- (Perl's compile-time "Useless use of ... in void context": -if fails on
    --  it, ${TAG;EXPR} warns -- the last warning is the one shown)
    { label = 'd-expr-if-void', args = [[-v -if '$Model; $Make eq "Canon"' -p '$filename' %IN%]],
      images = { 'Canon.jpg', 'Nikon.jpg' } },
    { label = 'd-expr-void',    args = [[-p '${make;$self;"abc" if $_;s/C/K/}' %IN%]],
      images = { 'Canon.jpg', 'Nikon.jpg' } },
    { label = 'd-expr-void2',   args = [[-p '${filename;my @a = (1); @a; $_ .= "x", 1}' %IN%]],
      images = { 'Canon.jpg', 'Nikon.jpg' } },
    -- map/grep (blocks and expressions, list and scalar context), s///e,
    -- keys of %info (the tags the condition names), seeded rand (Perl's
    -- drand48 sequence), $1 before the expression's own first match (the
    -- caller's, here the text up to the first '}'), substr outside of the
    -- string (undef and a warning), the two-argument ShiftTime
    { label = 'd-expr-map',     args = [[-p '${keywords;$_ = join "|", map { uc } split /, /} ${keywords;$_ = scalar(grep { /e/ } split /, /)} ]] ..
                                       [[${model;$_ = join ",", map { ($_, length) } grep !/^\d/, split / /}' %IN%]] },
    { label = 'd-expr-subste',  args = [[-p '${filename;s/(\d)/$1*2/ge} ${model;s/(\w+)/length($1)/e} ${make;s/(.)/sprintf("%02x",ord $1)/ge}' %IN%]] },
    { label = 'd-expr-keys',    args = [[-if 'defined $Make and join(",", sort keys %info) eq "Make,Model" and ]] ..
                                       [[scalar(keys %info) == 2 and $Model =~ /^[A-Z]/' -p '$filename' %IN%]] },
    { label = 'd-expr-rand',    args = [[-p '${filename;srand(42);$_ = int(rand(1000)) . " " . rand(10) . " " . srand(7) . " " . rand}' %IN%]],
      images = { 'Canon.jpg', 'Nikon.jpg' } },
    { label = 'd-expr-outer1',  args = [[-p '${model;/(\d+)/;$_ = "$1|$&"} ${make;/(Z+)/;$_ = "$1|$&"}' %IN%]] },
    { label = 'd-expr-substr',  args = [[-p '${filename;$_ = substr($_, 9)} ${make;$_ = substr($_, -9, 2) // "u"}' %IN%]] },
    { label = 'd-expr-shift2',  args = [[-p '${DateTimeOriginal;ShiftTime($_,"1:2:3 4:5:6")} ]] ..
                                       [[${CreateDate;my $t = $_; ShiftTime($t, "-0:0:1 0:0:0"); $_ = $t}' %IN%]] },
    { label = 'd-fileorder',    args = '-fileOrder FileName -S -FileName %IN%' },
    -- -w writes one sidecar text file per input; the tree is the result.
    { label = 'd-sidecar',      args = '-w %OUT%/%%f.txt -S -Model %IN%' },
    { label = 'd-csv',          args = '-csv -FileName -FileSize %IN%' },
    -- a missing file among the found ones: error message, no empty [] and
    -- the right "could not be read" count (exiftool:1990, 2312)
    -- the column order comes from the first file, including the tags it
    -- lacks; -f fills them with '-' (exiftool:2818-2856, 3903-3926)
    { label = 'd-csv-order',    args = '-csv -Make -Keywords -Artist %IN%' },
    { label = 'd-csv-f',        args = '-csv -f -G1 -Keywords -Make -LexiNothing %IN%' },
    { label = 'd-j-missing',    args = '-j -FileName %IN%/lex_missing.jpg %IN%/ExifTool.jpg' },
    { label = 'd-tagsFromFile', args = '-tagsFromFile %SRC% -Artist -Copyright -o %OUT% %IN%' },
    -- Two commands in one invocation, with shared trailing arguments.
    { label = 'd-execute',      args = '-S -FileName %IN% -execute -S -FileType %IN%' },
    { label = 'd-common_args',  args = '-FileName -execute -FileType -common_args -S %IN%' },
    -- Options that need a second file, a helper input or produce extra files.
    { label = 'd-W',            args = '-W %OUT%/%%f_%%t.txt -S -Model %IN%' },
    { label = 'd-Wext',         args = '-W %OUT%/%%f.txt -Wext jpg -S -Model %IN%' },
    { label = 'd-efile',        args = '-efile %OUT%/errors.txt -S -FileType %IN%' },
    { label = 'd-echo4',        args = '-echo4 LexiStderr -S -FileName %IN%' },
    { label = 'd-progress',     args = '-progress -S -FileName %IN%' },
    { label = 'd-ignore',       args = '-r -i out -S -FileName %IN%' },
    { label = 'd-srcfile',      args = '-srcfile %%d%%f.jpg -S -FileName %IN%' },
    { label = 'd-file1',        args = '-file1 %SRC% -S -File1:Artist %IN%' },
    { label = 'd-diff',         args = '-diff %SRC% %IN%/ExifTool.jpg' },
    -- NOTE: a config file is Perl code; lexiftool reads only its data
    -- (doc/configuration.md, compared with Perl in test_perlconfig.lua).
    -- Here: the lookup, a missing file warns "Config file not found" and the
    -- command runs without configuration.
    { label = 'd-config',       args = '-config %REPO%/vendor/exiftool/config_files/missing.config -S -FileType %IN%' },
    -- The bundled config files whose conversions are Perl code -- loops,
    -- return, references, nested structures -- which perl.eval runs.
    -- (local_time.config is left out: it sets the TimeZone option to the
    -- city's zone name, and what that gives depends on the platform's zone
    -- database.)
    { label = 'd-config-age',   args = '-config %REPO%/vendor/exiftool/config_files/age.config ' ..
                                       '-userParam Birthday=1975:06:07 -S -Age -DateTimeOriginal %IN%',
      images = { 'ExifTool.jpg', 'Canon.jpg', 'GPS.jpg', 'QuickTime.mov', 'PNG.png' } },
    { label = 'd-config-agefmt', args = '-config %REPO%/vendor/exiftool/config_files/age.config ' ..
                                        "-userParam Birthday=2003:11:30 -userParam 'AgeFormat=%d y %d m %d d %d:%d:%d' " ..
                                        '-S -Age %IN%',
      images = { 'ExifTool.jpg', 'Canon.jpg', 'GPS.jpg' } },
    { label = 'd-config-timezone', args = '-config %REPO%/vendor/exiftool/config_files/time_zone.config -S -TimeZone %IN%',
      images = { 'GPS.jpg', 'PhotoMechanic.jpg', 'Apple.jpg', 'Google.jpg', 'CanonRaw.cr3', 'GoPro.jpg', 'MWG.jpg',
                 'Ricoh2.jpg', 'ExifTool.jpg' } },
    { label = 'd-config-framecount', args = '-config %REPO%/vendor/exiftool/config_files/frameCount.config ' ..
                                            '-S -FrameCount %IN%',
      images = { 'QuickTime.mov', 'Pentax.avi', 'CanonRaw.cr3', 'ExifTool.jpg' } },
    { label = 'd-config-regions', args = '-config %REPO%/vendor/exiftool/config_files/convert_regions.config ' ..
                                         '-struct -j -Composite:all %IN%',
      images = { 'lex_MWG_Regions.xmp' } },
    { label = 'd-config-regions-rot', args = '-config %REPO%/vendor/exiftool/config_files/rotate_regions.config ' ..
                                             '-struct -j -Composite:all %IN%',
      images = { 'lex_MWG_Regions.xmp' } },
    { label = 'd-config-regions-w', args = '-config %REPO%/vendor/exiftool/config_files/convert_regions.config ' ..
                                           "'-RegionInfoMP<MyRegionMP' '-ImageRegion<MyRegionIPTC' " ..
                                           '-o %OUT%/regions.xmp %IN%/lex_MWG_Regions.xmp',
      images = { 'lex_MWG_Regions.xmp' } },
    { label = 'd-geotag',       args = '-geotag %AUX%/Geotag.log "-Geotime<DateTimeOriginal" %IN%' },
    -- The GlobalTimeShift offset carries over to the next file, where a date
    -- Time::Local rejects ("2007-30-01") keeps its value
    { label = 'd-gts-baddate',  args = '-api "GlobalTimeShift=DateCreated+0:0:1 0" -DateCreated -HTML-dc:Date %IN%/PostScript.eps %IN%/HTML.html',
      images = { 'PostScript.eps', 'HTML.html' } },
    -- NOTE: -w, not -W. exiftool rejects "-plot -W" outright ("Sorry, -W may
    -- not be combined with ..."), which made this variant test nothing at all
    -- until the INERT check flagged it. With -plot the -w argument is a
    -- complete file name with no format codes (POD, "-plot").
    { label = 'd-plot',         args = '-plot -w %OUT%/plot.svg -FileSize %IN%' },
    { label = 'd-zip',          args = '-z -S -FileType %IN%' },
    -- Two-step: write, then remove the backups the write created.
    { label = 'd-del-original', args = '-Artist=LexiTest %IN% -execute -delete_original! %IN%' },
    { label = 'd-restore',      args = '-Artist=LexiTest %IN% -execute -restore_original %IN%' },
    { label = 'd-list_dir',     args = '-list_dir -S -FileName %IN%' },
    -- File-less calls: their answer does not depend on any image, so running
    -- them once here beats repeating them for every file in the read track.
    { label = 'd-list',         args = '-list' },
    { label = 'd-listw',        args = '-listw' },
    { label = 'd-listf',        args = '-listf' },
    { label = 'd-listr',        args = '-listr' },
    -- (with -v the extension lists print each type's description, the
    --  description form of GetFileType)
    { label = 'd-listf-v',      args = '-listf -v' },
    { label = 'd-listr-v',      args = '-listr -v' },
    { label = 'd-listd',        args = '-listd' },
    { label = 'd-listg',        args = '-listg' },
    { label = 'd-listg1',       args = '-listg1' },
    { label = 'd-listwf',       args = '-listwf' },
    { label = 'd-listgeo',      args = '-listgeo' },
    { label = 'd-listx',        args = '-listx -EXIF:all' },
    -- (the whole database: -listx -EXIF:all never reaches a maker-note or
    --  XMP table, so a PrintConv list of code refs (CanonCustom) or a missing
    --  TABLE_DESC (XMP::pdf) slipped past d-listx alone)
    { label = 'd-listx-all',    args = '-listx' },
    { label = 'd-ver',          args = '-ver' },
    -- NOTE: the help text is deliberately NOT tested here. lexiftool's usage is
    -- not upstream's verbatim but derived from it by tools/usage_rules.lua, so
    -- comparing the two would need a tool-specific rewrite in the comparison --
    -- the one asymmetry this harness must not have. What that check really
    -- guards is "src/lexiftool/usage.lua is not stale after a vendor update",
    -- which is a freshness check on a generated file: it lives in
    -- src/test/test_usage.lua and gates `make check`, rather than sitting in a
    -- report-only comparison run.
}

--------------------------------------------------------------------------------
-- -stay_open sessions. A long-running exiftool reads its arguments from an
-- ARGFILE that keeps growing: commands are appended one at a time, each closed
-- by -execute[NUM], and the caller waits for the "{ready[NUM]}" line on stdout
-- before it sends the next one. Upstream has no .t file for this mode, so the
-- harness plays the caller itself: `feed` is the session as the caller sends
-- it -- strings are written as they are, `{ ready = N }` waits until the
-- tool's stdout holds N "{ready" markers (which only works if the tool
-- flushes after each, as upstream does), `{ sleep = S }` pauses S seconds.
-- `via` says where the strings go: 'stdin' (default; args read `-@ -`) or
-- 'file', a growing work/args.txt that the args name as %ARGFILE%. The
-- session runs in work/, and %IN% inside a feed string is the relative 'in'
-- (unquoted: an ARGFILE line is one argument as it stands), so the ARGFILE
-- is the same in both trees. Same prepare as DIR: the core images in
-- work/in, the session names the ones it wants.
-- A wait that runs out (20 s) is not an error of the harness but an
-- observation: feed.txt in the case directory records every step and whether
-- its wait was answered, so a missing or unflushed "{ready}" shows up as a
-- difference like any other.
--------------------------------------------------------------------------------
Cases.STAY = {
    -- (a) several commands in one session, each on another file, each
    --     answered by its own {readyNUM}
    { label = 's-execute', args = '-stay_open True -@ -', feed = {
        '-S\n-FileName\n%IN%/ExifTool.jpg\n-execute1\n', { ready = 1 },
        '-S\n-Make\n-Model\n%IN%/Canon.jpg\n-execute2\n', { ready = 2 },
        '-j\n-FileType\n%IN%/PNG.png\n-execute3\n', { ready = 3 },
        '-stay_open\nFalse\n',
    } },
    -- (b) write in the session, then read the written value back in the next
    --     command of the same session
    { label = 's-write-read', args = '-stay_open True -@ -', feed = {
        '-overwrite_original\n-Artist=LexiStay\n-XMP:Subject=stay\n%IN%/ExifTool.jpg\n-execute1\n', { ready = 1 },
        '-S\n-Artist\n-XMP:Subject\n%IN%/ExifTool.jpg\n-execute2\n', { ready = 2 },
        '-stay_open\nFalse\n',
    } },
    -- (c) failing commands in the middle (a missing file, an aborted command);
    --     the session carries on, and ${status} reports the command's result
    { label = 's-error', args = '-stay_open True -@ -', feed = {
        '-S\n-FileName\n%IN%/lex_missing.jpg\n-echo3\nstatus ${status}\n-execute1\n', { ready = 1 },
        '-S\n-FileName\n-require\n99\n%IN%/ExifTool.jpg\n-execute2\n', { ready = 2 },
        '-S\n-FileName\n%IN%/ExifTool.jpg\n-echo3\nstatus ${status}\n-execute3\n', { ready = 3 },
        '-stay_open\nFalse\n',
    } },
    -- (d) -stay_open False ends the session: the arguments that followed
    --     `-@ -` on the command line run as the last command, then the tool
    --     exits at the end of the input; a plain -execute answers {ready}
    { label = 's-false', args = '-stay_open True -@ - -S -FileType %IN%/GIF.gif', feed = {
        '-S\n-FileName\n%IN%/Canon.jpg\n-execute\n', { ready = 1 },
        '-stay_open\nFalse\n',
    } },
    -- (d') with -q and no -execute number upstream flushes but prints no
    --     {ready}; a numbered -execute still gets its marker
    { label = 's-quiet', args = '-stay_open True -@ -', feed = {
        '-q\n-S\n-FileName\n%IN%/ExifTool.jpg\n-execute7\n', { ready = 1 },
        '-q\n-S\n-Make\n%IN%/Canon.jpg\n-execute\n', { sleep = 1 },
        '-stay_open\nFalse\n',
    } },
    -- (e) the ARGFILE is a regular file that grows while it is read: lines
    --     arrive late and split in the middle, the reader waits at its end
    { label = 's-growing', args = '-stay_open True -@ %ARGFILE%', via = 'file', feed = {
        '-S\n-File', { sleep = 0.4 }, 'Name\n%IN%/ExifTool.jpg\n-exec', { sleep = 0.4 },
        'ute1\n', { ready = 1 },
        '# a comment line\n  -Make  \n%IN%/Canon.jpg\n', { sleep = 0.4 }, '-execute2\n', { ready = 2 },
        '-stay_open\nFalse\n',
    } },
}

--------------------------------------------------------------------------------
-- The expression corpus (Expressions.lua): one case per expression, over the
-- fixed image set Expressions.IMAGES placed in work/in. Like the dir group,
-- one call over the whole directory; nothing is written.
--------------------------------------------------------------------------------
-- (a shell-quoted word for Util.shellSplit: '...' with every ' as '"'"')
local function shellQuote(s)
    return "'" .. s:gsub("'", [['"'"']]) .. "'"
end
Cases.EXPR = {}
for _, e in ipairs(Expressions.LIST) do
    if not e.skip then
        local x = e.variant or e.expr
        local args
        if e.kind == 'if' then
            args = '-if ' .. shellQuote(x) .. [[ -p '$filename']]
        elseif e.kind == 'api' then
            args = '-api ' .. shellQuote(e.option .. '=' .. x) .. ' -S ' .. Expressions.API_TAGS
        else
            args = '-p ' .. shellQuote(x)
        end
        if e.opts then args = e.opts .. ' ' .. args end
        Cases.EXPR[#Cases.EXPR + 1] = { label = 'x-' .. e.id, args = args .. ' %IN%',
                                        images = Expressions.IMAGES }
    end
end

--------------------------------------------------------------------------------
-- Groups
--
-- There is no "track" mechanism. Every case is prepared, run and observed the
-- SAME way; the matrices above differ only in two orthogonal, declarative
-- properties, and the group name is a label for the report, not a code path.
--
--   prepare -- how the case's work/ directory is filled
--   over    -- 'each': one case per image; 'all': one case over the whole
--              selection (a call whose subject is a directory, or which needs
--              no file at all)
--------------------------------------------------------------------------------
Cases.GROUPS = {
    { name = 'read',  list = Cases.READ,  prepare = 'file',     over = 'each' },
    { name = 'write', list = Cases.WRITE, prepare = 'file+src', over = 'each' },
    { name = 'dir',   list = Cases.DIR,   prepare = 'corpus',   over = 'all'  },
    { name = 'stay',  list = Cases.STAY,  prepare = 'corpus',   over = 'all'  },
    { name = 'expr',  list = Cases.EXPR,  prepare = 'corpus',   over = 'all'  },
}

-- One flat, ordered list of cases. Every case carries everything needed to run
-- it, so the harness is a single loop and sharding across parallel workers is a
-- plain index modulo.
--
-- opts.images      all selected images (absolute paths)
-- opts.coreImages  the core subset (see the SCOPE note above)
-- opts.known       basename -> path of every image in both directories,
--                  selected or not (resolves a row's `images`)
-- opts.groups      set of group names to include, e.g. { read = true }
-- opts.allScope    true to force every variant onto the full image set
--
-- A case's `dir` is its slot in an observation tree: <group>/<label>/<name>.
-- Labels that differ only in case (`S` and `s`, `j-G1` and `j-g1`) would be
-- ONE directory on a case-insensitive filesystem (NTFS, APFS), with two
-- workers writing into it; the lower-case twin therefore gets `~lc` appended
-- in the directory name (the label itself, and so the report, is unchanged).
function Cases.build(opts)
    local selected = {}
    for _, img in ipairs(opts.images) do selected[img] = true end
    -- A row's explicit image list: every name must exist (checked for all
    -- groups, so a typo surfaces whatever TEST_CLI_TRACK says); only the
    -- selected ones become cases.
    local function explicit(group, v)
        local imgs = {}
        for _, name in ipairs(v.images) do
            local path = opts.known[name]
            if not path then
                error(('%s/%s: unknown image "%s"'):format(group.name, v.label, name), 0)
            end
            if selected[path] then imgs[#imgs + 1] = path end
        end
        return imgs
    end
    for _, group in ipairs(Cases.GROUPS) do
        for _, v in ipairs(group.list) do
            if v.images then explicit(group, v) end
        end
    end

    local cases = {}
    for _, group in ipairs(Cases.GROUPS) do
        if opts.groups[group.name] then
            local lowerCount = {}
            for _, v in ipairs(group.list) do
                local lc = v.label:lower()
                lowerCount[lc] = (lowerCount[lc] or 0) + 1
            end
            for _, v in ipairs(group.list) do
                local imgs
                if v.images then
                    imgs = explicit(group, v)
                else
                    imgs = (opts.allScope or v.scope == 'all')
                        and opts.images or opts.coreImages
                end
                local dirLabel = v.label
                if lowerCount[v.label:lower()] > 1 and v.label == v.label:lower() then
                    dirLabel = v.label .. '~lc'
                end
                local function add(name, images)
                    cases[#cases + 1] = {
                        group = group.name, label = v.label, name = name,
                        args = v.args, images = images, feed = v.feed, via = v.via,
                        prepare = group.prepare, over = group.over,
                        dir = group.name .. '/' .. dirLabel .. '/' .. name,
                    }
                end
                if group.over == 'all' then
                    add('all', imgs)
                else
                    for _, img in ipairs(imgs) do
                        add(img:match('[^/]+$'), { img })
                    end
                end
            end
        end
    end
    return cases
end

return Cases
