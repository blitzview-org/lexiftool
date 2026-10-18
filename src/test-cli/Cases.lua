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
--               is no per-kind comparison logic anywhere. The three tables
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
--------------------------------------------------------------------------------

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
    -- NOTE: a config file is Perl code, which lexiftool does not run (it warns
    -- "Config file not supported by lexiftool (Perl code): FILE" instead,
    -- docs/differences.md), so an existing config file can never match.
    -- What both share is the lookup: a missing file warns "Config file not
    -- found" and the command runs without configuration.
    { label = 'd-config',       args = '-config %REPO%/vendor/exiftool/config_files/missing.config -S -FileType %IN%' },
    { label = 'd-geotag',       args = '-geotag %AUX%/Geotag.log "-Geotime<DateTimeOriginal" %IN%' },
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
-- Groups
--
-- There is no "track" mechanism. Every case is prepared, run and observed the
-- SAME way; the three matrices above differ only in two orthogonal, declarative
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
}

-- One flat, ordered list of cases. Every case carries everything needed to run
-- it, so the harness is a single loop and sharding across parallel workers is a
-- plain index modulo.
--
-- opts.images      all selected images (absolute paths)
-- opts.coreImages  the core subset (see the SCOPE note above)
-- opts.groups      set of group names to include, e.g. { read = true }
-- opts.allScope    true to force every variant onto the full image set
--
-- A case's `dir` is its slot in an observation tree: <group>/<label>/<name>.
-- Labels that differ only in case (`S` and `s`, `j-G1` and `j-g1`) would be
-- ONE directory on a case-insensitive filesystem (NTFS, APFS), with two
-- workers writing into it; the lower-case twin therefore gets `~lc` appended
-- in the directory name (the label itself, and so the report, is unchanged).
function Cases.build(opts)
    local cases = {}
    for _, group in ipairs(Cases.GROUPS) do
        if opts.groups[group.name] then
            local lowerCount = {}
            for _, v in ipairs(group.list) do
                local lc = v.label:lower()
                lowerCount[lc] = (lowerCount[lc] or 0) + 1
            end
            for _, v in ipairs(group.list) do
                local imgs = (opts.allScope or v.scope == 'all')
                    and opts.images or opts.coreImages
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
