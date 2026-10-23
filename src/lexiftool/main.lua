--------------------------------------------------------------------------------
-- File:         lexiftool/main.lua
-- Ported from:  exiftool
--
-- Description:  Read/write meta information
--
-- Revisions:    Nov. 12/03 - P. Harvey Created
--               (See html/history.html for revision history)
--
-- Port notes:   The command-line script, sub for sub and in upstream order;
--               the main script (the "Command" loop over the sets of
--               arguments separated by -execute) is the function `main`,
--               which the repo-root `lexiftool` launcher calls with `arg`.
--               File scope: upstream declares ~155 file-scope `my`
--               variables next to 55 subs -- more than the 200 locals a Lua
--               function (here: the chunk) may have -- so the module runs
--               in a private environment (`local _ENV`, falling back to _G
--               for the Lua globals): the variables and subs are named
--               exactly as upstream and are visible to the whole file, but
--               to nothing outside it. Perl names that differ only by the
--               sigil get one: `%csvTags`/`%endDir`/`%preserveTime`/
--               `%seqFileDir` are `csvTags_h`/`endDir_h`/`preserveTime_h`/
--               `seqFileDir_h` next to the plain array/scalar, `$end` (a Lua
--               keyword) is `end_`, `@ARGV` is `ARGV`, and `$_` is the
--               local `_`. %SIG is perl.SIG: SigInt/SigCont are installed
--               after their definitions (upstream assigns them at the top,
--               by name) and run between two Lua instructions, like Perl's
--               safe signals (lexiftool.sys.signal). Term::ReadKey for -k
--               is perl.TermReadKey: termios on POSIX, the console mode
--               and console key events of STDIN on Windows, where ReadMode
--               croaks when STDIN is no console -- a die nothing catches,
--               which `runMain` (end of file) ends as Perl does: message,
--               END block, exit status from errno. The Windows branches are
--               ported: the console title (SetWindowTitle, `title` through
--               cmd.exe), wildcard expansion (perl.bsd_glob for File::Glob,
--               FindFileWindows for Win32::FindFile) and Perl's text mode:
--               a file Perl opens without binmode gets the :crlf layer on
--               Windows (LF written as CR/LF), so every such open() here is
--               followed by perl.binmode(FH, ':crlf') -- ExifTool:Open opens
--               binary -- and a line read from one (the -p FMTFILE) has its
--               CR/LF end folded to LF; the ARGFILE reads (line by line,
--               or sysread for -stay_open) give the same arguments binary.
--               STDOUT starts in text mode and binmode switches it as
--               upstream does. Absent: perldoc for the usage (the help text of
--               the vendored exiftool is printed instead, generated into
--               lexiftool/usage.lua), loading of Perl config files (-config
--               names are collected as upstream does and the library looks
--               the files up, ExifTool.LoadConfigFiles, which loads a Lua
--               config file, doc/configuration.md, and warns about a Perl
--               one instead of running it) and -use of
--               anything but MWG. The -if condition is Perl code: it runs
--               through perl.eval, an interpreter for the part of Perl such
--               code uses (see perl.lua); Perl outside that subset is
--               reported as "Perl syntax unsupported in lexiftool: ...",
--               also without -v. -ver -v names the Lua counterpart of each
--               optional Perl module (luaRecommends) and adds a line for
--               the port (portVersion -- the build's git-describe identity,
--               _G.LEXIFTOOL_PORT_VERSION, see below; Lua release; bytecode
--               -- the last from the launcher's second argument to main).
--               -stay_open reads its ARGFILE line by line (perl.sysread);
--               the "{ready}" flush and the -v0 autoflush go through
--               perl.autoflush/perl.print.
--               Port-only: the script as a library for an embedding host
--               (the C API, doc/capi.md) -- `session`/`execute` at the end
--               of the file run the -stay_open loop in a coroutine; three
--               port branches keyed on launchInfo.readArgs (ReadStayOpen,
--               the "{ready}" print, Exit()) are all the loop knows of it.
--               The module's value is therefore a table that is callable
--               as `main` and carries the two entry points.
--------------------------------------------------------------------------------

-- (the script's own file scope, see the Port notes)
local _ENV = setmetatable({}, { __index = _G }) -- luacheck: ignore 211/_ENV

local version = '13.59'

-- ($^W = 1 -- enable global warnings: Lua has no counterpart)

local ExifTool = require('lexiftool')     -- (use Image::ExifTool qw{:Public})
local perl = require('lexiftool.perl')
local sysLib = require('lexiftool.sys')
local matches = perl.matches
local isMatch = perl.isMatch
local isMatchDyn = perl.isMatchDyn
local subst = perl.subst
local split = perl.split
local sprintf = perl.sprintf
local print = perl.print
local printf = perl.printf
local push = perl.push
local shift = perl.shift
local unshift = perl.unshift
local grep = perl.grep
local join = perl.join
local keys = perl.keys
local sort = perl.sort
local ref = perl.ref
local lc = perl.lc
local uc = perl.uc
local length = perl.length
local substr = perl.substr
local truthy = perl.truthy      -- (0 and '' are false in Perl)
local TermReadKey = perl.TermReadKey    -- (Term::ReadKey, loaded on demand upstream)
local perlStr = perl.str

-- the :Public functions upstream imports from Image::ExifTool
local GetTagName = ExifTool.GetTagName
local GetShortcuts = ExifTool.GetShortcuts
local GetAllTags = ExifTool.GetAllTags
local GetWritableTags = ExifTool.GetWritableTags
local GetDeleteGroups = ExifTool.GetDeleteGroups
local GetFileType = ExifTool.GetFileType
local CanWrite = ExifTool.CanWrite
local CanCreate = ExifTool.CanCreate
local OrderedKeys = ExifTool.OrderedKeys

-- add our 'lib' directory to the include list BEFORE 'use Image::ExifTool'
-- (upstream BEGIN block: the `lexiftool` launcher sets up package.path; the
--  -xpath and -config handling is at the top of `main` below, where @ARGV is)
exePath = nil

-- function prototypes
-- (Lua: the subs are fields of the file-scope environment, assigned where
--  upstream defines them, so no forward declaration is needed)

-- (upstream: $SIG{INT} = 'SigInt'; $SIG{CONT} = 'SigCont'; END { Cleanup() }
--  -- the two handlers are installed below their definitions, as Lua needs
--  the functions first; Exit() calls Cleanup() before it exits)

-- declare all static file-scope variables
commonArgs = {}     -- arguments common to all commands
condition = {}      -- conditional processing of files
csvExclude = {}     -- list of tags excluded from CSV import
csvFiles = {}       -- list of files when reading with CSV option (in ExifTool Charset)
csvTags = {}        -- order of tags for first file with CSV option (lower case)
delFiles = {}       -- list of files to delete
dynamicFiles = {}   -- list of -tagsFromFile files with dynamic names and -TAG<=FMT pairs
echo3, echo4 = {}, {} -- stdout and stderr echo after processing is complete
efile = {}          -- files for writing list of error/fail/same file names
exclude = {}        -- list of excluded tags
files = {}          -- list of files and directories to scan
moreArgs = {}       -- more arguments to process after -stay_open -@
newValues = {}      -- list of new tag values to set
requestTags = {}    -- tags to request (for -p or -if option arguments)
srcFmt = {}         -- source file name format strings
tags = {}           -- list of tags to extract
altFile = {}        -- alternate files to extract information (keyed by lower-case family 8 group)
appended = {}       -- list of files appended to
countLink = {}      -- count hard and symbolic links made
created = {}        -- list of files we created
csvTags_h = {}      -- lookup for all found tags with CSV option (lower case keys)
database = {}       -- lookup for database information based on file name (in ExifTool Charset)
filterExt = {}      -- lookup for filtered extensions
ignore = {}         -- directory names to ignore
outComma = {}       -- flag that output text file needs a comma
outTrailer = {}     -- trailer for output text file
preserveTime_h = {} -- preserved timestamps for files
printFmt = {}       -- the contents of the print format file
seqFileDir_h = {}   -- file sequence number in each directory
setTags = {}        -- hash of list references for tags to set from files
setTagsList = {}    -- list of other tag lists for multiple -tagsFromFile from the same file
usedFileName = {}   -- lookup for file names we already used in TestName feature
utf8FileName = {}   -- lookup for file names that are UTF-8 encoded
warnedOnce = {}     -- lookup for once-only warnings
wext = {}           -- -W extensions to write
wroteHEAD = {}      -- list of output txt files to which we wrote HEAD
allGroup = nil      -- show group name for all tags
altEnc = nil        -- alternate character encoding if not UTF-8
argFormat = nil     -- use exiftool argument-format output
binaryOutput = nil  -- flag for binary output (undef or 1, or 0 for binary XML/PHP)
binaryStdout = nil  -- flag set if we output binary to stdout
binSep = nil        -- separator used for list items in binary output
binTerm = nil       -- terminator used for binary output
comma = nil         -- flag set if we need a comma in JSON output
count = nil         -- count of files scanned when reading or deleting originals
countBad = nil      -- count of files with errors
countBadCr = nil    -- count files not created due to errors
countBadWr = nil    -- count write errors
countCopyWr = nil   -- count of files copied without being changed
countDir = nil      -- count of directories scanned
countFailed = nil   -- count files that failed condition
countGoodCr = nil   -- count files created OK
countGoodWr = nil   -- count files written OK
countNewDir = nil   -- count of directories created
countSameWr = nil   -- count files written OK but not changed
critical = nil      -- flag for critical operations (disable CTRL-C)
csv = nil           -- flag for CSV option (set to "CSV", or maybe "JSON" when writing)
csvDelim = nil      -- delimiter for CSV files
dbAdd = nil         -- flag to add CSV/JSON information to existing lists
dbSaveCount = nil   -- save counter for last CSV/JSON file loaded
deleteOrig = nil    -- 0=restore original files, 1=delete originals, 2=delete w/o asking
diff = nil          -- file name for comparing differences
disableOutput = nil -- flag to disable normal output
doSetFileName = nil -- flag set if FileName may be written
doUnzip = nil       -- flag to extract info from .gz and .bz2 files
end_, endDir, endDir_h = nil, nil, {}  -- flags to end processing
escapeC = nil       -- C-style escape
escapeHTML = nil    -- flag to escape printed values for html
evalWarning = nil   -- warning from eval
executeID = nil     -- -execute ID number
failCondition = nil -- flag to fail -if condition
fastCondition = nil -- flag for fast -if condition
fileHeader = nil    -- header to print to output file (or console, once)
fileTrailer = nil   -- trailer for output file
filtered = nil      -- flag indicating file was filtered by name
filterFlag = nil    -- file filter flag (0x01=deny extensions, 0x02=allow extensions, 0x04=add ext)
fixLen = nil        -- flag to fix description lengths when writing alternate languages
forcePrint = nil    -- string to use for missing tag values (undef to not print them)
geoOnly = nil       -- flag to extract Geolocation tags only
helped = nil        -- flag to avoid printing help if no tags specified
html = nil          -- flag for html-formatted output (2=html dump)
ignoreHidden = nil  -- flag to ignore hidden files
interrupted = nil   -- flag set if CTRL-C is pressed during a critical process
isBinary = nil      -- true if value is a SCALAR ref
isWriting = nil     -- flag set if we are writing tags
joinLists = nil     -- flag set to join list values into a single string
json = nil          -- flag for JSON/PHP output format (1=JSON, 2=PHP)
langOpt = nil       -- language option
listDir = nil       -- treat a directory as a regular file
listItem = nil      -- item number for extracting single item from a list
listSep = nil       -- list item separator (', ' by default)
mt = nil            -- main ExifTool object
multiFile = nil     -- non-zero if we are scanning multiple files
noBinary = nil      -- flag set to ignore binary tags
outFormat = nil     -- -1=Canon format, 0=same-line, 1=tag names, 2=values only
outOpt = nil        -- output file or directory name
overwriteOrig = nil -- flag to overwrite original file (1=overwrite, 2=in place)
pause = nil         -- pause before returning
plot = nil          -- flag for plot output format
preserveTime = nil  -- flag to preserve times of updated files (2=preserve FileCreateDate only)
progress = nil      -- flag to calculate total files to process (0=calculate but don't display)
progressCount = nil -- count of files processed
progressIncr = nil  -- increment for progress counter
progressMax = nil   -- total number of files to process
progressNext = nil  -- next progress count to output
progStr = nil       -- progress message string
purge = nil         -- flag to purge memory
quiet = nil         -- flag to disable printing of informational messages / warnings
rafStdin = nil      -- File::RandomAccess for stdin (if necessary to rewind)
recurse = nil       -- recurse into subdirectories (2=also hidden directories)
rtnVal = nil        -- command return value (0=success)
rtnValPrev = nil    -- previous command return value (0=success)
saveCount = nil     -- count the number of times we will/did call SaveNewValues()
scanWritable = nil  -- flag to process only writable file types
sectHeader = nil    -- current section header for -p option
sectTrailer = nil   -- section trailer for -p option
seqFileDir = nil    -- sequential file number used for %-C
seqFileNum = nil    -- sequential file number used for %C
setCharset = nil    -- character set setting ('default' if not set and -csv -b used)
showGroup = nil     -- number of group to show (may be zero or '')
showTagID = nil     -- non-zero to show tag ID's
stayOpenBuff = ''   -- buffer for -stay_open file
stayOpenFile = nil  -- name of the current -stay_open argfile
structOpt = nil     -- output structured XMP information (JSON and XML output only)
tabFormat = nil     -- non-zero for tab output format
tagOut = nil        -- flag for separate text output file for each tag
textOut = nil       -- extension for text output file (or undef for no output)
textOut2 = nil      -- complete file name for single text output file
textOverwrite = nil -- flag to overwrite existing text output file (2=append, 3=over+append)
tmpFile = nil       -- temporary file to delete on exit
tmpText = nil       -- temporary text file
validFile = nil     -- flag indicating we processed a valid file
verbose = nil       -- verbose setting
vout = nil          -- verbose output file reference (\*STDOUT or \*STDERR by default)
windowTitle = nil   -- title for console window
xml = nil           -- flag for XML-formatted output

ARGV = {}           -- (Perl's @ARGV: the arguments still to be processed)

-- (the file handles upstream opens by name: ARGFILE, STAYOPEN, CSVFILE, ...;
--  STAYOPEN must outlive a single command, so it is file-scope here too)
STAYOPEN = nil

-- flag to keep the input -@ argfile open:
-- 0 = normal behaviour
-- 1 = received "-stay_open true" and waiting for argfile to keep open
-- 2 = currently reading from STAYOPEN argfile
-- 3 = waiting for -@ to switch to a new STAYOPEN argfile
stayOpen = 0

rtnValApp = 0   -- app return value (0=success)
curTitle = ''   -- current window title

-- lookup for O/S names which use CR/LF newlines
isCRLF = ({ MSWin32 = 1, os2 = 1, dos = 1 })[perl.osname()]

-- lookup for JSON characters that we escape specially
jsonChar = { ['"'] = '"', ['\\'] = '\\', ["\t"] = 't', ["\n"] = 'n', ["\r"] = 'r' }

-- lookup for C-style escape sequences
escC = { ["\n"] = '\\n', ["\r"] = '\\r', ["\t"] = '\\t', ['\\'] = '\\\\' }
unescC = { a = "\a", b = "\b", f = "\f", n = "\n", r = "\r",
           t = "\t", ['0'] = "\0", ['\\'] = '\\' }

-- options requiring additional arguments
-- (used only to skip over these arguments when reading -stay_open ARGFILE)
-- (arg is converted to lower case then tested again unless an entry was found with the same case)
optArgs = {
    ['-tagsfromfile'] = 1, ['-addtagsfromfile'] = 1, ['-alltagsfromfile'] = 1,
    ['-@'] = 1,
    ['-api'] = 1,
    ['-c'] = 1, ['-coordformat'] = 1,
    ['-charset'] = 0, -- (optional arg; OK because arg cannot begin with "-")
    ['-config'] = 1,
    ['-csvdelim'] = 1,
    ['-d'] = 1, ['-dateformat'] = 1,
    ['-D'] = 0, -- necessary to avoid matching lower-case equivalent
    ['-diff'] = 1,
    ['-echo'] = 1, ['-echo#'] = 1,
    ['-efile'] = 1, ['-efile#'] = 1, ['-efile!'] = 1, ['-efile#!'] = 1,
    ['-ext'] = 1, ['--ext'] = 1, ['-ext+'] = 1, ['--ext+'] = 1,
        ['-extension'] = 1, ['--extension'] = 1, ['-extension+'] = 1, ['--extension+'] = 1,
    ['-fileorder'] = 1, ['-fileorder#'] = 1,
    ['-file#'] = 1,
    ['-geotag'] = 1,
    ['-globaltimeshift'] = 1,
    ['-i'] = 1, ['-ignore'] = 1,
    ['-if'] = 1, ['-if#'] = 1,
    ['-lang'] = 0, -- (optional arg; cannot begin with "-")
    ['-listitem'] = 1,
    ['-o'] = 1, ['-out'] = 1,
    ['-p'] = 1, ['-printformat'] = 1, ['-p-'] = 1, ['-printformat-'] = 1,
    ['-P'] = 0,
    ['-password'] = 1,
    ['-require'] = 1,
    ['-sep'] = 1, ['-separator'] = 1,
    ['-srcfile'] = 1,
    ['-stay_open'] = 1,
    ['-use'] = 1,
    ['-userparam'] = 1,
    ['-w'] = 1, ['-w!'] = 1, ['-w+'] = 1, ['-w+!'] = 1, ['-w!+'] = 1,
        ['-textout'] = 1, ['-textout!'] = 1, ['-textout+'] = 1, ['-textout+!'] = 1, ['-textout!+'] = 1,
         ['-tagout'] = 1,  ['-tagout!'] = 1,  ['-tagout+'] = 1,  ['-tagout+!'] = 1,  ['-tagout!+'] = 1,
    ['-wext'] = 1,
    ['-wm'] = 1, ['-writemode'] = 1,
    ['-x'] = 1, ['-exclude'] = 1,
    ['-X'] = 0,
}

-- recommended packages and alternatives
recommends = {
    'Archive::Zip',
    'Compress::Zlib',
    'Digest::MD5',
    'Digest::SHA',
    'IO::Compress::Bzip2',
    'POSIX::strptime',
    'Time::Local',
    'Unicode::LineBreak',
    'File::StatX',
    'Compress::Raw::Lzma',
    'IO::Compress::RawDeflate',
    'IO::Uncompress::RawInflate',
    'IO::Compress::Brotli',
    'IO::Uncompress::Brotli',
    'Win32::API',
    'Win32::FindFile',
    'Win32API::File',
}
altRecommends = {
   ['POSIX::strptime'] = 'Time::Piece', -- (can use Time::Piece instead of POSIX::strptime)
}
-- (port: for -ver -v, the Lua counterpart of each recommended Perl module --
--  what the port uses in its place -- and its version where the module has
--  one to ask; nil means the counterpart is missing, "(not installed)".
--  Upstream prints `$Module::VERSION` of the Perl module instead.)
local function luaZlib()
    local ok, zlib = pcall(require, 'compress.zlib')
    if not ok then return nil end
    -- (the zlib C library's version)
    return 'compress.zlib ' .. perlStr(zlib._VERSION) .. ' (zlib ' .. perlStr((zlib.version())) .. ')'
end
local function luaBrotli()
    local ok, brotli = pcall(require, 'compress.brotli')
    if not ok then return nil end
    -- (the libbrotli version)
    return 'compress.brotli ' .. perlStr(brotli._VERSION) .. ' (libbrotli ' .. perlStr((brotli.version())) .. ')'
end
local function luaLzma()
    local ok, lzma = pcall(require, 'compress.lzma')
    if not ok then return nil end
    -- (the liblzma version)
    return 'compress.lzma ' .. perlStr(lzma._VERSION) .. ' (liblzma ' .. perlStr((lzma.version())) .. ')'
end
local function luaBzip2()
    local ok, bzip2 = pcall(require, 'compress.bzip2')
    if not ok then return nil end
    -- (the libbz2 version: "1.0.8, 13-Jul-2019", its first word)
    return 'compress.bzip2 ' .. perlStr(bzip2._VERSION) .. ' (libbz2 ' ..
        (matches(perlStr((bzip2.version())), [[^([^,\s]+)]]) or '') .. ')'
end
-- (Digest::MD5 and Digest::SHA are both the `digest` rock; last word of its
--  _VERSION: "0.0.1", or "scm" for a build from the scm rockspec)
local function luaDigest()
    local ok, digest = pcall(require, 'digest')
    if not ok then return nil end
    return 'digest ' .. (matches(perlStr(digest._VERSION), [[(\S+)$]]) or '')
end
luaRecommends = {
    ['Archive::Zip'] = function()
        if not luaZlib() then return nil end
        return 'lexiftool.ArchiveZip + compress.zlib'
    end,
    ['Compress::Zlib'] = luaZlib,
    ['Digest::MD5'] = luaDigest,
    ['Digest::SHA'] = luaDigest,
    ['File::StatX'] = function()
        if sysLib.get_btime then return 'lexiftool.sys (statx)' end
        return nil
    end,
    ['Time::Piece'] = function() return 'lexiftool.perl (TimePieceStrptime)' end,
    ['Time::Local'] = function() return 'lexiftool.perl (timegm)' end,
    ['IO::Compress::RawDeflate'] = function()
        if not luaZlib() then return nil end
        return 'lexiftool (deflateRaw) + compress.zlib'
    end,
    ['IO::Uncompress::RawInflate'] = function()
        if not luaZlib() then return nil end
        return 'lexiftool (inflateRaw) + compress.zlib'
    end,
    ['IO::Compress::Brotli'] = luaBrotli,
    ['IO::Uncompress::Brotli'] = luaBrotli,
    ['IO::Compress::Bzip2'] = luaBzip2,
    ['Compress::Raw::Lzma'] = luaLzma,
    -- (Unicode::GCString in the facade, over the character data of a
    --  Unicode-LineBreak release)
    ['Unicode::LineBreak'] = function()
        local _, GCString = perl.evalRequire('Unicode::GCString')
        return 'lexiftool.perl (GCString, Unicode-LineBreak ' .. GCString.VERSION ..
            ' data, Unicode ' .. GCString.UNICODE_VERSION .. ')'
    end,
    -- (the Windows-only file APIs: the port reaches the same Win32 calls
    --  natively through lexiftool.sys/perl.bsd_glob, so on Windows they have
    --  a counterpart and elsewhere "(not installed)" exactly as in Perl)
    ['Win32::API'] = function()
        if perl.osname() == 'MSWin32' then return 'lexiftool.sys' end
        return nil
    end,
    ['Win32::FindFile'] = function()
        if perl.osname() == 'MSWin32' then return 'lexiftool.sys (read_dir) + perl.bsd_glob' end
        return nil
    end,
    ['Win32API::File'] = function()
        if perl.osname() == 'MSWin32' then return 'lexiftool.sys' end
        return nil
    end,
}
-- (port: the version of the port itself -- the build's git-describe
--  identity, baked in by the launcher/build script as _G.LEXIFTOOL_PORT_VERSION
--  (CONTRIBUTING.md "Configuration"); "Unknown" when nothing set it (a bare
--  source checkout, or a rock install -- luarocks' "builtin" build type
--  has no step to bake a real identity in))
portVersion = _G.LEXIFTOOL_PORT_VERSION or 'Unknown'
-- (port: how the launcher loaded the port, set by main from its second
--  argument)
launchInfo = { }

unescapeChar = { t = "\t", n = "\n", r = "\r" }

-- special subroutines used in -if condition
function ExifTool.EndDir() endDir = 1 return endDir end
function ExifTool.End()    end_ = 1 return end_ end

-- exit routine
-- (Lua: also runs upstream's `END { Cleanup() }` block, then exits)
function Exit(code)
    if pause then
        if perl.evalRequire('Term::ReadKey') then
            print(io.stderr, "-- press any key --")
            TermReadKey.ReadMode('cbreak')
            TermReadKey.ReadKey(0)
            TermReadKey.ReadMode(0)
            print(io.stderr, ("\b \b"):rep(20))
        else
            print(io.stderr, "-- press RETURN --\n")
            io.stdin:read('L')
        end
    end
    Cleanup()
    io.stdout:flush()
    -- (port: in a session of an embedding host the script ends, not the
    --  process; see `session` at the end of this file)
    if launchInfo.readArgs then return code end
    os.exit(code)
end
-- my warning and error routines (NEVER say "die"!)
-- (Lua: returns true if the warning was issued, for WarnOnce)
function Warn(...)
    if perl.num(quiet) < 2 or isMatch((...), '^Error') then
        local oldWarn = perl.SIG.__WARN__
        perl.SIG.__WARN__ = nil
        perl.warn(...)
        if oldWarn ~= nil then perl.SIG.__WARN__ = oldWarn end
        return 1
    end
end
function Error(...) Warn(...) rtnVal = 1 return 1 end
function WarnOnce(msg)
    if not warnedOnce[msg] then
        if Warn(msg) then warnedOnce[msg] = 1 end
    end
end

-- define signal handlers and cleanup routine
function SigInt()
    if critical then interrupted = 1 return end
    Cleanup()
    os.exit(1)
end
function SigCont() end
function Cleanup()
    if tmpFile ~= nil then mt:Unlink(tmpFile) end
    if tmpText ~= nil then mt:Unlink(tmpText) end
    tmpFile = nil
    tmpText = nil
    if next(preserveTime_h) then PreserveTime() end
    SetWindowTitle('')
end
perl.SIG.INT  = SigInt  -- do cleanup on Ctrl-C
perl.SIG.CONT = SigCont -- (allows break-out of delays)

--------------------------------------------------------------------------------
-- main script
--
-- (Lua: the script body is this function, called by the `lexiftool` launcher
--  with Lua's `arg`; it does not return -- Exit() ends the process.  The
--  launcher also says how it loaded the port, `launch.bytecode` (for the
--  port line of -ver -v); nil when called otherwise)
local function main(argv, launch)
launchInfo = launch or { }
for i = 1, #argv do ARGV[i] = argv[i] end

-- (upstream BEGIN block, as far as it concerns the arguments:)
-- (undocumented -xpath option added in 11.91, must come before other options)
-- ($^X is the interpreter, $0 the script: Lua's arg[-1] and arg[0])
if #ARGV > 0 and lc(ARGV[1]) == '-xpath' and shift(ARGV) then exePath = _G.arg[-1] else exePath = _G.arg[0] end
do
    -- get exe directory
    local exeDir = matches(perlStr(exePath), [=[(.*)[\\\/]]=]) or '.'
    local script = perlStr(_G.arg[0])
    if perl.filetest('l', script) then
        -- (readlink $0: lfs reports the link target)
        local attr = require('lfs').symlinkattributes(script)
        local lnk = attr and attr.target
        if lnk ~= nil then
            local lnkDir = matches(lnk, [=[(.*)[\\\/]]=]) or '.'
            exeDir = (isMatch(lnk, '^/') and '' or exeDir .. '/') .. lnkDir
        end
    end
    ExifTool.exeDir = exeDir -- use our exeDir for loading config file
end
-- load or disable config file if specified
while #ARGV > 0 and lc(ARGV[1]) == '-config' do
    shift(ARGV)
    push(ExifTool.configFiles, shift(ARGV))
end
-- (port: here upstream's `use Image::ExifTool` loads the config files, see
--  ExifTool.LoadConfigFiles)
ExifTool.LoadConfigFiles()

-- isolate arguments common to all commands
if #grep([[(?i)^-common_args$]], ARGV) > 0 then
    local newArgs, common, end_ = {}, nil, nil
    for _, a in ipairs(ARGV) do
        if isMatch(a, [[(?i)^-common_args$]]) and not end_ then
            common = 1
        elseif common then
            push(commonArgs, a)
        else
            if a == '--' then end_ = 1 end
            push(newArgs, a)
        end
    end
    if common then ARGV = newArgs end
end

--..............................................................................
-- loop over sets of command-line arguments separated by "-execute"
while true do   -- Command:

if #echo3 > 0 then
    local str = join("\n", echo3) .. "\n"
    str = subst(str, [[(?i)\$\{status\}]], perlStr(rtnVal), 'g')
    print(io.stdout, str)
end
if #echo4 > 0 then
    local str = join("\n", echo4) .. "\n"
    str = subst(str, [[(?i)\$\{status\}]], perlStr(rtnVal), 'g')
    print(io.stderr, str)
end

if rafStdin then rafStdin:Close() end
rafStdin = nil

-- save our previous return codes
rtnValPrev = rtnVal
if truthy(rtnVal) then rtnValApp = rtnVal end

-- exit Command loop now if we are all done processing commands
if not (#ARGV > 0 or rtnVal == nil or stayOpen >= 2 or #commonArgs > 0) then break end

-- attempt to restore text mode for STDOUT if necessary
if truthy(binaryStdout) then
    if truthy(isCRLF) then perl.binmode(io.stdout, ':crlf') end
    binaryStdout = 0
end

-- flush console and print "{ready}" message if -stay_open is in effect
-- (port: not in a session of an embedding host, which has the command's end
--  from ReadStayOpen; see `session` at the end of this file)
if stayOpen >= 2 and not launchInfo.readArgs then
    if truthy(quiet) and executeID == nil then
        -- flush output if possible
        io.stderr:flush()
        io.stdout:flush()
    else
        io.stderr:flush()
        local id = executeID ~= nil and executeID or ''
        local save = perl.autoflush(io.stdout)
        perl.autoflush(io.stdout, 1)     -- turn on output autoflush for stdout
        print(io.stdout, "{ready" .. id .. "}\n")
        perl.autoflush(io.stdout, save)  -- restore original autoflush setting
    end
end

-- initialize necessary static file-scope variables
-- (not done: @commonArgs, @moreArgs, $critical, $binaryStdout, $helped,
--  $interrupted, $mt, $pause, $rtnValApp, $rtnValPrev, $stayOpen, $stayOpenBuff, $stayOpenFile)
condition = {}
csvExclude = {}
csvFiles = {}
csvTags = {}
delFiles = {}
dynamicFiles = {}
echo3 = {}
echo4 = {}
efile = {}
exclude = {}
files = {}
newValues = {}
requestTags = {}
srcFmt = {}
tags = {}
altFile = {}
appended = {}
countLink = {}
created = {}
csvTags_h = {}
database = {}
endDir_h = {}
filterExt = {}
ignore = {}
outComma = {}
outTrailer = {}
preserveTime_h = {}
printFmt = {}
seqFileDir_h = {}
setTags = {}
setTagsList = {}
usedFileName = {}
utf8FileName = {}
warnedOnce = {}
wext = {}
wroteHEAD = {}
allGroup = nil
altEnc = nil
argFormat = nil
binaryOutput = nil
binSep = nil
binTerm = nil
comma = nil
csv = nil
dbAdd = nil
deleteOrig = nil
diff = nil
disableOutput = nil
doSetFileName = nil
doUnzip = nil
end_ = nil
endDir = nil
escapeC = nil
escapeHTML = nil
evalWarning = nil
executeID = nil
failCondition = nil
fastCondition = nil
fileHeader = nil
filtered = nil
fixLen = nil
forcePrint = nil
geoOnly = nil
ignoreHidden = nil
isBinary = nil
joinLists = nil
langOpt = nil
listDir = nil
listItem = nil
multiFile = nil
noBinary = nil
outOpt = nil
plot = nil
preserveTime = nil
progress = nil
progressCount = nil
progressIncr = nil
progressMax = nil
progressNext = nil
purge = nil
rafStdin = nil
recurse = nil
scanWritable = nil
sectHeader = nil
setCharset = nil
showGroup = nil
showTagID = nil
structOpt = nil
tagOut = nil
textOut = nil
textOut2 = nil
textOverwrite = nil
tmpFile = nil
tmpText = nil
validFile = nil
verbose = nil
windowTitle = nil

count = 0
countBad = 0
countBadCr = 0
countBadWr = 0
countCopyWr = 0
countDir = 0
countFailed = 0
countGoodCr = 0
countGoodWr = 0
countNewDir = 0
countSameWr = 0
csvDelim = ','
dbSaveCount = 0
fileTrailer = ''
filterFlag = 0
html = 0
isWriting = 0
json = 0
listSep = ', '
outFormat = 0
overwriteOrig = 0
progStr = ''
quiet = 0
rtnVal = 0
saveCount = 0
sectTrailer = ''
seqFileDir = 0
seqFileNum = 0
tabFormat = 0
vout = io.stdout
xml = 0

-- define local variables used only in this command loop
local fileOrder = {}    -- tags to use for ordering of input files
local fileOrderFast     -- -fast level for -fileOrder option
local addGeotime        -- automatically added geotime argument
local doGlob            -- flag set to do filename wildcard expansion
local endOfOpts         -- flag set if "--" option encountered
local escapeXML         -- flag to escape printed values for xml
local setTagsFile       -- filename for last TagsFromFile option
local sortOpt           -- sort option is used
local srcStdin          -- one of the source files is STDIN
local tagsFrom = ''     -- tags on command line come from 'CSV' or 'File'
local useMWG            -- flag set if we are using any MWG tag

local argsLeft, nextPass, badCmd = nil, {}, nil
local pass = 0
local _                 -- (Perl's $_: the argument being processed)

-- for Windows, use globbing for wildcard expansion if available - MK/20061010
-- (the port expands wildcards natively there: perl.bsd_glob stands in for
-- File::Glob and FindFileWindows below for Win32::FindFile, so the globbing
-- path is always available on Windows)
if perl.osname() == 'MSWin32' then
    -- override the core glob forcing case insensitivity
    doGlob = 1
end

mt = ExifTool.new()     -- create ExifTool object

-- don't extract duplicates by default unless set by UserDefined::Options
if not (ExifTool.UserDefinedOptions and next(ExifTool.UserDefinedOptions)
    and ExifTool.UserDefinedOptions.Duplicates ~= nil) then
    mt:Options('Duplicates', 0)
end

-- default is to join lists if the List option was set to zero in the config file
if mt:Options('List') ~= nil and not truthy(mt:Options('List')) then joinLists = 1 end

-- preserve FileCreateDate if possible
if not truthy(preserveTime) and perl.osname() == 'MSWin32' and sysLib.get_file_time then
    -- (Win32::API/Win32API::File upstream; lexiftool.sys here)
    preserveTime = 2
end

-- add user-defined command-line arguments
if ExifTool.UserDefinedArguments and #ExifTool.UserDefinedArguments > 0 then
    unshift(ARGV, table.unpack(ExifTool.UserDefinedArguments))
end

if version ~= ExifTool.VERSION then
    Warn("Application version " .. version .. " does not match Image::ExifTool library version " .. ExifTool.VERSION .. "\n")
end

-- parse command-line options in 2 passes...
-- pass 1: set all of our ExifTool options
-- pass 2: print all of our help and informational output (-list, -ver, etc)
while true do

  -- execute the command now if no more arguments or -execute is used
  local isExecute, _dash, exeNum
  if #ARGV > 0 then isExecute, _dash, exeNum = isMatch(ARGV[1], [[(?i)^(-|\xe2\x88\x92)execute(\d+)?$]]) end
  if #ARGV == 0 or (isExecute and not endOfOpts) then
    if #ARGV > 0 then
        executeID = exeNum      -- save -execute number for "{ready}" response
        helped = 1              -- don't show help if we used -execute
        if badCmd then shift(ARGV) rtnVal = 1 goto nextCommand end
    elseif stayOpen >= 2 then
        ReadStayOpen(ARGV)      -- read more arguments from -stay_open file
        goto nextArg
    elseif badCmd then
        commonArgs = {}         -- all done.  Flush common arguments
        rtnVal = 1
        goto nextCommand
    end
    if pass == 0 then
        -- insert common arguments now if not done already
        if #commonArgs > 0 and argsLeft == nil then
            -- count the number of arguments remaining for subsequent commands
            argsLeft = #ARGV + #moreArgs
            unshift(ARGV, table.unpack(commonArgs))
            -- all done with commonArgs if this is the end of the command
            if argsLeft == 0 then commonArgs = {} end
            goto nextArg
        end
        -- check if we have more arguments now than we did before we processed
        -- the common arguments.  If so, then we have an infinite processing loop
        if argsLeft ~= nil and argsLeft < #ARGV + #moreArgs then
            Warn("Ignoring -common_args from " .. ARGV[1] .. " onwards to avoid infinite recursion\n")
            while argsLeft < #ARGV + #moreArgs do
                if #ARGV > 0 then
                    shift(ARGV)
                else
                    shift(moreArgs)
                end
            end
        end
        -- require MWG module if used in any argument
        -- (note: doesn't cover the -p option because these tags will be parsed on the 2nd pass)
        if not useMWG and (#grep([[(?i)^([--_0-9A-Z]+:)*1?mwg:]], tags) > 0 or
                           #grep([[(?i)^([--_0-9A-Z]+:)*1?mwg:]], requestTags) > 0) then
            useMWG = 1
        end
        if useMWG then
            require('lexiftool.MWG').Load()
        end
        -- update necessary variables for 2nd pass
        if forcePrint ~= nil then
            if mt:Options('MissingTagValue') == nil then
                mt:Options('MissingTagValue', '-')
            end
            forcePrint = mt:Options('MissingTagValue')
        end
    end
    if #nextPass > 0 then
        -- process arguments which were deferred to the next pass
        unshift(ARGV, table.unpack(nextPass))
        nextPass = {}
        endOfOpts = nil
        pass = pass + 1
        goto nextArg
    end
    if #ARGV > 0 then shift(ARGV) end   -- remove -execute from argument list
    break                               -- process the command now
  end
  _ = shift(ARGV)
  if badCmd then goto nextArg end      -- flush remaining arguments if aborting this command

  -- allow funny dashes (nroff dash bug for cut-n-paste from pod)
  if not endOfOpts and isMatch(_, [[^(-|\xe2\x88\x92)]]) then
    _ = subst(_, [[^(-|\xe2\x88\x92)]], '')
    _ = subst(_, [[^\xe2\x88\x92]], '-')    -- translate double-dash too
    if _ == '-' then
        if pass == 0 then push(nextPass, '--') end
        endOfOpts = 1
        goto nextArg
    end
    local a = lc(_)
    local isList, listType, listFamily = isMatch(_, [[(?i)^list([wfrdx]|wf|g(\d*)|geo)?$]])
    if isList then
        if pass == 0 then push(nextPass, "-" .. _) end
        local type_ = lc(listType or '')
        if type_ == '' or type_ == 'w' or type_ == 'x' then
            local group
            local isGrp, _dash2, grp
            if #ARGV > 0 and truthy(ARGV[1]) then
                isGrp, _dash2, grp = isMatch(ARGV[1], [[(?i)^(-|\xe2\x88\x92)(.+):(all|\*)$]])
            end
            if isGrp then
                if pass == 0 then
                    if lc(grp) == 'mwg' then useMWG = 1 end
                    push(nextPass, shift(ARGV))
                    goto nextArg
                end
                group = grp
                shift(ARGV)
                if isMatch(group, [[(?i)IFD]]) then
                    Warn("Can't list tags for specific IFD\n")
                    helped = 1
                    goto nextArg
                end
                if isMatch(group, [[^(all|\*)$]]) then group = nil end
            else
                if pass == 0 then goto nextArg end
            end
            helped = 1
            if type_ == 'x' then
                local TagInfoXML = require('lexiftool.TagInfoXML')
                local opts = {}
                if forcePrint ~= nil then opts.Flags = 1 end
                if outFormat > 0 then opts.NoDesc = 1 end
                opts.Lang = langOpt
                TagInfoXML.Write(nil, group, opts)
                goto nextArg
            end
            local wr = (type_ == 'w')
            local msg = (wr and 'Writable' or 'Available') .. (group and (" " .. group) or '') .. ' tags'
            PrintTagList(msg, table.unpack(wr and GetWritableTags(group) or GetAllTags(group)))
            -- also print shortcuts if listing all tags
            if group or wr then goto nextArg end
            local tagList = GetShortcuts()
            if #tagList > 0 then PrintTagList('Command-line shortcuts', table.unpack(tagList)) end
            goto nextArg
        end
        if pass == 0 then goto nextArg end
        helped = 1
        if type_ == 'wf' then
            local wf = {}
            for _, t in ipairs(GetFileType()) do
                if truthy(CanWrite(t)) then push(wf, t) end
            end
            PrintTagList('Writable file extensions', table.unpack(wf))
        elseif type_ == 'f' then
            PrintTagList('Supported file extensions', table.unpack(GetFileType()))
        elseif type_ == 'r' then
            PrintTagList('Recognized file extensions', table.unpack(GetFileType(nil, 0)))
        elseif type_ == 'd' then
            PrintTagList('Deletable groups', table.unpack(GetDeleteGroups()))
        elseif type_ == 'geo' then
            local Geolocation = require('lexiftool.Geolocation')
            Geolocation.init()  -- (the module's load-time statements)
            local i
            if not truthy(quiet) then print(io.stdout, "Geolocation database:\n") end
            local isAlt = truthy(mt:Options('GeolocAltNames')) and ',AltNames' or ''
            if isAlt ~= '' and not Geolocation.ReadAltNames() then isAlt = '' end
            print(io.stdout, "City,Region,Subregion,CountryCode,Country,TimeZone,FeatureCode,Population,Latitude,Longitude" .. isAlt .. "\n")
            if truthy(sortOpt) then Geolocation.SortDatabase('City') end
            local minPop = mt:Options('GeolocMinPop')
            local feature = mt:Options('GeolocFeature')
            if not truthy(feature) then feature = '' end
            local neg = isMatch(feature, '^-')
            feature = subst(feature, '^-', '')
            local fcodes = {}
            for _, f in ipairs(split([[\s*,\s*]], feature)) do fcodes[lc(f)] = 1 end
            local isUTF8 = { 0, 1, 2, 4 }   -- items that need converting from UTF8
            if isAlt ~= '' then push(isUTF8, 10) end
            i = 0
            while true do
                local entry = table.pack(Geolocation.GetEntry(i, langOpt, 1))
                if entry[1] == nil then break end
                entry.n = 10    -- remove everything after latitude (eg. feature type)
                for k = 11, #entry do entry[k] = nil end
                if truthy(minPop) and perl.num(entry[8]) < perl.num(minPop) then goto nextEntry end
                if next(fcodes) then
                    if neg then
                        if fcodes[lc(entry[7])] then goto nextEntry end
                    elseif not fcodes[lc(entry[7])] then
                        goto nextEntry
                    end
                end
                if isAlt ~= '' then
                    entry.n = 11
                    entry[11] = Geolocation.GetAltNames(i, 1)
                end
                for _, k in ipairs(isUTF8) do
                    entry[k + 1] = entry[k + 1] ~= nil and mt:Decode(entry[k + 1], 'UTF8') or ''
                end
                if isAlt ~= '' and not truthy(entry[11]) then entry.n = 10 entry[11] = nil end
                print(io.stdout, join(',', { table.unpack(entry, 1, entry.n) }), "\n")
                ::nextEntry::
                i = i + 1
            end
        else -- 'g(\d*)'
            -- list all groups in specified family
            local family = truthy(listFamily) and listFamily or 0
            PrintTagList("Groups in family " .. family, table.unpack(mt:GetAllGroups(family)))
        end
        goto nextArg
    end
    if a == 'ver' then
        if pass == 0 then push(nextPass, '-ver') goto nextArg end
        local libVer = ExifTool.VERSION
        local str = libVer == version and '' or (" [Warning: Library version is " .. libVer .. "]")
        if truthy(verbose) then
            print(io.stdout, "ExifTool version " .. version .. str .. ExifTool.RELEASE .. "\n")
            -- (Lua: the interpreter version instead of $] and ${^UNICODE})
            printf(io.stdout, "Perl version %s%s\n", _VERSION, '')
            -- (port: the port itself -- its version, the interpreter's full
            --  release and whether the launcher loaded precompiled bytecode)
            local okSys, sys = pcall(require, 'lexiftool.sys')
            local luaRelease = okSys and sys.lua_release or _VERSION
            printf(io.stdout, "lexiftool port %s, %s, bytecode %s\n", portVersion, luaRelease,
                   launchInfo.bytecode and 'yes' or 'no')
            print(io.stdout, "Platform: " .. perl.osname() .. "\n")
            if perl.num(verbose) > 8 then
                print(io.stdout, "Current Dir: " .. (require('lfs').currentdir() or '') .. "\n")
                print(io.stdout, "Script Name: " .. perlStr(_G.arg and _G.arg[0]) .. "\n")
                print(io.stdout, "Exe Name:    " .. perlStr(_G.arg and _G.arg[-1]) .. "\n")
                print(io.stdout, "Exe Dir:     " .. perlStr(ExifTool.exeDir) .. "\n")
                print(io.stdout, "Exe Path:    " .. perlStr(exePath) .. "\n")
            end
            print(io.stdout, "Optional libraries:\n")
            for _, recommend in ipairs(recommends) do
                local lib = recommend
                if isMatch(lib, '^Win32') and perl.osname() ~= 'MSWin32' then goto nextLib end
                if isMatch(lib, 'StatX') and perl.osname() ~= 'linux' then goto nextLib end
                do
                    -- (no Perl module loads here: the version is that of
                    --  the Lua counterpart, see luaRecommends)
                    local ver = luaRecommends[lib] and luaRecommends[lib]()
                    local alt = altRecommends[lib]
                    -- check for alternative if primary not available
                    if not ver and alt then
                        ver = luaRecommends[alt] and luaRecommends[alt]()
                        if ver then lib = alt end
                    end
                    printf(io.stdout, "  %-28s %s\n", lib, truthy(ver) and ver or '(not installed)')
                end
                ::nextLib::
            end
            if perl.num(verbose) > 1 then
                print(io.stdout, "Include directories:\n")
                for _, dir in ipairs(split(';', package.path)) do print(io.stdout, "  " .. dir .. "\n") end
            end
        else
            print(io.stdout, version .. str .. ExifTool.RELEASE .. "\n")
        end
        helped = 1
        goto nextArg
    end
    do
        local isTFF, addAll, eqFile = isMatch(_, [[(?i)^(all|add)?tagsfromfile(=.*)?$]])
        if isTFF then
            if truthy(eqFile) then
                setTagsFile = substr(eqFile, 1)
            else
                setTagsFile = #ARGV > 0 and shift(ARGV) or ''
            end
            if setTagsFile == '' then
                Error("File must be specified for -tagsFromFile option\n")
                badCmd = 1
                goto nextArg
            end
            -- create necessary lists, etc for this new -tagsFromFile file
            AddSetTagsFile(setTagsFile, { Replace = (truthy(addAll) and lc(addAll) == 'add') and 0 or 1 })
            tagsFrom = 'File'
            goto nextArg
        end
    end
    if a == '@' then
        local argFile = shift(ARGV)
        if not truthy(argFile) then Error("Expecting filename for -@ option\n") badCmd = 1 goto nextArg end
        -- switch to new ARGFILE if using chained -stay_open options
        if stayOpen == 1 then
            -- defer remaining arguments until we close this argfile
            moreArgs = ARGV
            ARGV = {}
        elseif stayOpen == 3 then
            if truthy(stayOpenFile) and stayOpenFile ~= '-' and argFile == stayOpenFile then
                -- don't allow user to switch to the same -stay_open argfile
                -- because it will result in endless recursion
                stayOpen = 2
                Warn("Ignoring request to switch to the same -stay_open ARGFILE (" .. argFile .. ")\n")
                goto nextArg
            end
            STAYOPEN:close()
            stayOpen = 1    -- switch to this -stay_open file
        end
        -- (\*STAYOPEN if stayOpen == 1, \*ARGFILE otherwise: ExifTool:Open
        --  returns the handle instead of filling one in; binary, which reads
        --  what Perl's text mode does here: FilterArgfileLine strips the CR
        --  of a CR/LF line end anyway, and sysread is raw in Perl too)
        local fp = mt:Open(argFile)
        if not fp then
            if not isMatch(argFile, '^/') then fp = mt:Open(perlStr(ExifTool.exeDir) .. '/' .. argFile) end
            if not fp then
                Error("Error opening arg file " .. argFile .. "\n")
                badCmd = 1
                goto nextArg
            end
        end
        if stayOpen == 1 then
            STAYOPEN = fp
            stayOpenFile = argFile  -- remember the name of the file we have open
            stayOpenBuff = ''       -- initialize buffer for reading this file
            stayOpen = 2
            helped = 1
            ReadStayOpen(ARGV)
            goto nextArg
        end
        local ARGFILE = fp
        local newArgs, didBOM = {}, nil
        for argLine in ARGFILE:lines('L') do
            local line = argLine
            -- filter Byte Order Mark if it exists from start of UTF-8 text file
            if not didBOM then
                line = subst(line, [[^\xef\xbb\xbf]], '')
                didBOM = 1
            end
            line = FilterArgfileLine(line)
            if line ~= nil then push(newArgs, line) end
        end
        if ARGFILE ~= io.stdin then ARGFILE:close() end
        unshift(ARGV, table.unpack(newArgs))
        goto nextArg
    end
    do
        local isDup, noDup = isMatch(_, [[(?i)^(-?)(a|duplicates)$]])
        if isDup then mt:Options('Duplicates', truthy(noDup) and 0 or 1) goto nextArg end
    end
    if a == 'api' then
        local opt = shift(ARGV)
        if opt ~= nil and length(opt) > 0 then
            local val
            local hasVal, v = isMatch(opt, [[(?s)=(.*)]])
            if hasVal then
                opt = subst(opt, [[(?s)=(.*)]], '')
                val = v
            else
                val = 1
            end
            -- empty string means an undefined value unless ^= is used
            local caret = isMatch(opt, [[\^$]])
            if caret then opt = subst(opt, [[\^$]], '') end
            if not (caret or truthy(length(val))) then val = nil end
            mt:Options(opt, val)
        else
            if pass == 0 then
                push(nextPass, '-api')
                if opt ~= nil then push(nextPass, opt) end
                goto nextArg
            end
            print(io.stdout, "Available API Options:\n")
            local availableOptions = ExifTool.AvailableOptions()
            for _, o in ipairs(availableOptions) do
                if not truthy(o[4]) then printf(io.stdout, "  %-17s - %s\n", o[1], o[3]) end
            end
            helped = 1
        end
        goto nextArg
    end
    if isMatch(_, [[(?i)^arg(s|format)$]]) then argFormat = 1 goto nextArg end
    do
        local isBin, notBin = isMatch(_, [[(?i)^(-?)b(inary)?$]])
        if isBin then
            if truthy(notBin) then binaryOutput, noBinary = nil, 1 else binaryOutput, noBinary = 1, nil end
            mt:Options('Binary', binaryOutput, 'NoPDFList', binaryOutput)
            goto nextArg
        end
    end
    if isMatch(_, [[(?i)^c(oordFormat)?$]]) then
        local fmt = shift(ARGV)
        if not truthy(fmt) then Error("Expecting coordinate format for -c option\n") badCmd = 1 goto nextArg end
        mt:Options('CoordFormat', fmt)
        goto nextArg
    end
    if a == 'charset' then
        local charset
        if #ARGV > 0 and not isMatch(ARGV[1], [[^(-|\xe2\x88\x92)]]) then charset = shift(ARGV) end
        local isType, typeName
        if truthy(charset) then isType, typeName = isMatch(charset, [[^(\w+)=]]) end
        if not truthy(charset) then
            if pass == 0 then
                push(nextPass, '-charset')
                if charset ~= nil then push(nextPass, charset) end
                goto nextArg
            end
            local charsets = {}
            for _, v in pairs(ExifTool.charsetName) do charsets[v] = 1 end
            PrintTagList('Available character sets', table.unpack(sort(keys(charsets))))
            helped = 1
        elseif not isType or lc(typeName) == 'exiftool' then
            if isType then charset = subst(charset, [[^(\w+)=]], '') end
            do
                local oldWarn = perl.SIG.__WARN__
                perl.SIG.__WARN__ = function(msg) evalWarning = msg end
                evalWarning = nil
                mt:Options('Charset', charset)
                perl.SIG.__WARN__ = oldWarn
            end
            if evalWarning then
                Warn(evalWarning)
            else
                setCharset = mt:Options('Charset')
            end
        else
            charset = subst(charset, [[^(\w+)=]], '')
            -- set internal encoding of specified metadata type
            local type_ = ({ id3 = 'ID3', iptc = 'IPTC', exif = 'EXIF', filename = 'FileName',
                             photoshop = 'Photoshop', quicktime = 'QuickTime', riff = 'RIFF' })[lc(typeName)]
            if not type_ then Warn("Unknown type for -charset option: " .. typeName .. "\n") goto nextArg end
            mt:Options("Charset" .. type_, charset)
        end
        goto nextArg
    end
    if isMatch(_, [[(?i)^config$]]) then
        Warn("Ignored -config option (not first on command line)\n")
        shift(ARGV)
        goto nextArg
    end
    do
        local isDb, dbName, _j, dbFile = isMatch(_, [[(?i)^(csv|j(son)?)(\+?=.*)?$]])
        if isDb then
            local dbType = lc(dbName) == 'csv' and 'CSV' or 'JSON'
            if not truthy(dbFile) then
                if dbType == 'CSV' then
                    csv = dbType
                else
                    json = 1
                    html, xml = 0, 0
                    mt:Options('Duplicates', 1)
                    require('lexiftool.XMP')    -- for FixUTF8()
                end
                goto nextArg
            end
            -- must process on 2nd pass so -f and -charset options are available
            if pass == 0 then
                if #tags > 0 then Warn("Tag arguments should come after the -" .. dbName .. "= option\n") end
                push(nextPass, "-" .. _)
                saveCount = saveCount + 1
                push(newValues, { SaveCount = saveCount })  -- marker to save new values now
                dbSaveCount = saveCount
                tagsFrom = 'CSV'
                goto nextArg
            end
            local _m, eq = isMatch(dbFile, [[^(\+?=)]])
            dbFile = subst(dbFile, [[^(\+?=)]], '')
            if eq == '+=' then dbAdd = 2 end
            if srcStdin then vout = io.stderr end
            if truthy(verbose) then print(vout, "Reading " .. dbType .. " file " .. dbFile .. "\n") end
            local msg
            local CSVFILE = mt:Open(dbFile)
            if CSVFILE then
                perl.binmode(CSVFILE)
                local Import = require('lexiftool.Import')
                if dbType == 'CSV' then
                    msg = Import.ReadCSV(CSVFILE, database, forcePrint, csvDelim)
                else
                    local chset = mt:Options('Charset')
                    msg = Import.ReadJSON(CSVFILE, database, forcePrint, chset)
                end
                if CSVFILE ~= io.stdin then CSVFILE:close() end
            else
                msg = "Error opening " .. dbType .. " file '" .. dbFile .. "'"
            end
            if truthy(msg) then Warn(msg .. "\n") end
            isWriting = 1
            csv = dbType
            goto nextArg
        end
    end
    if isMatch(_, [[(?i)^csvdelim$]]) then
        csvDelim = shift(ARGV)
        if csvDelim == nil then Error("Expecting argument for -csvDelim option\n") badCmd = 1 goto nextArg end
        if isMatch(csvDelim, '"') then Error("CSV delimiter can not contain a double quote\n") badCmd = 1 goto nextArg end
        local unescape = { t = "\t", n = "\n", r = "\r", ['\\'] = '\\' }
        csvDelim = subst(csvDelim, [[(?s)\\(.)]], function(c) return unescape[c] or ("\\" .. c) end, 'g')
        mt:Options('CSVDelim', csvDelim)
        goto nextArg
    end
    if isMatch(_, '^d$') or a == 'dateformat' then
        local fmt = shift(ARGV)
        if not truthy(fmt) then Error("Expecting date format for -d option\n") badCmd = 1 goto nextArg end
        mt:Options('DateFormat', fmt)
        goto nextArg
    end
    if isMatch(_, '^D$') or a == 'decimal' then showTagID = 'D' goto nextArg end
    if isMatch(_, [[(?i)^diff$]]) then
        diff = shift(ARGV)
        if diff == nil then Error("Expecting file name for -" .. _ .. " option\n") badCmd = 1 end
        diff = CleanFilename(diff)  -- change to forward slashes if necessary
        goto nextArg
    end
    do
        local isDel, bang = isMatch(_, [[(?i)^delete_original(!?)$]])
        if isDel then deleteOrig = truthy(bang) and 2 or 1 goto nextArg end
    end
    if isMatch(_, [[(?i)^list_dir$]]) then listDir = 1 goto nextArg end
    if isMatch(_, '^e$') or a == '-composite' then mt:Options('Composite', 0) goto nextArg end
    if isMatch(_, '^-e$') or a == 'composite' then mt:Options('Composite', 1) goto nextArg end
    -- (-eh is undocumented)
    if isMatch(_, '^E$') or a == 'escapehtml' or a == 'eh' then
        require('lexiftool.HTML')
        escapeHTML = 1
        goto nextArg
    end
    if a == 'ec' or a == 'escapec' then escapeC = 1 goto nextArg end
    if a == 'ex' or a == 'escapexml' then escapeXML = 1 goto nextArg end
    do
        local isEcho, num = isMatch(_, [[(?i)^echo(\d)?$]])
        if isEcho then
            local n = truthy(num) and perl.num(num) or 1
            local arg = shift(ARGV)
            if arg == nil then goto nextArg end
            if n > 4 then Warn("Invalid -echo number\n") goto nextArg end
            if n > 2 then
                if n == 3 then push(echo3, arg) else push(echo4, arg) end
            else
                print(n == 2 and io.stderr or io.stdout, arg, "\n")
            end
            helped = 1
            goto nextArg
        end
    end
    do
        local isEE, _ee, num = isMatch(_, [[(?i)^(ee|extractembedded)(\d*)$]])
        if isEE then
            mt:Options('ExtractEmbedded', truthy(num) and num or 1)
            mt:Options('Duplicates', 1)
            goto nextArg
        end
    end
    do
        local isEfile, num, bang = isMatch(_, [[(?i)^efile(\d+)?(!)?$]])
        if isEfile then
            local arg = shift(ARGV)
            if arg == nil then Error("Expecting file name for -" .. _ .. " option\n") badCmd = 1 goto nextArg end
            num = num and perl.num(num)
            if not truthy(num) or (num & 0x01) ~= 0 then efile[1] = arg end   -- error
            if truthy(num) and (num & 0x02) ~= 0 then efile[2] = arg end      -- unchanged
            if truthy(num) and (num & 0x04) ~= 0 then efile[3] = arg end      -- failed -if condition
            if truthy(num) and (num & 0x08) ~= 0 then efile[4] = arg end      -- updated
            if truthy(num) and (num & 0x016) ~= 0 then efile[5] = arg end     -- created
            if truthy(bang) then perl.unlink(arg) end
            goto nextArg
        end
    end
    -- (-execute handled at top of loop)
    do
        local isExt, _ext, plus = isMatch(_, [[(?i)^-?ext(ension)?(\+)?$]])
        if isExt then
            local ext = shift(ARGV)
            if ext == nil then Error("Expecting extension for -ext option\n") badCmd = 1 goto nextArg end
            local flag = isMatch(_, '^-') and 0 or (truthy(plus) and 2 or 1)
            filterFlag = filterFlag | (0x01 << flag)
            ext = subst(ext, [[^\.]], '')   -- remove leading '.' if it exists
            filterExt[uc(ext)] = flag ~= 0 and 1 or 0
            goto nextArg
        end
    end
    if isMatch(_, '^f$') or a == 'forceprint' then
        forcePrint = 1
        goto nextArg
    end
    do
        local isF, base = isMatch(_, [[^F([-+]?\d*)$]])
        if not isF then isF, base = isMatch(_, [[(?i)^fixbase([-+]?\d*)$]]) end
        if isF then
            mt:Options('FixBase', base)
            goto nextArg
        end
    end
    do
        local isFast, num = isMatch(_, [[(?i)^fast(\d*)$]])
        if isFast then
            mt:Options('FastScan', length(num) > 0 and num or 1)
            goto nextArg
        end
    end
    do
        local isFile, g8 = isMatch(_, [[(?i)^(file\d+)$]])
        if isFile then
            altFile[lc(g8)] = shift(ARGV)
            if not truthy(altFile[lc(g8)]) then Error("Expecting file name for -file option\n") badCmd = 1 goto nextArg end
            goto nextArg
        end
    end
    do
        local isOrder, num = isMatch(_, [[(?i)^fileorder(\d*)$]])
        if isOrder then
            if #ARGV > 0 then push(fileOrder, shift(ARGV)) end
            num = truthy(num) and perl.num(num) or 0
            if fileOrderFast == nil or fileOrderFast > num then fileOrderFast = num end
            goto nextArg
        end
    end
    if a == 'globaltimeshift' then mt:Options('GlobalTimeShift', shift(ARGV)) goto nextArg end
    do
        local isG, g1, g2, num = isMatch(_, [[(?i)^(g)(roupHeadings|roupNames)?([\d:]*)$]])
        if isG then
            showGroup = truthy(num) and num or 0
            if g2 then allGroup = lc(g2) == 'roupnames' else allGroup = g1 == 'G' end
            if isMatch(perlStr(showGroup), [[\b5\b]]) then mt:Options('SavePath', 1) end
            if isMatch(perlStr(showGroup), [[\b6\b]]) then mt:Options('SaveFormat', 1) end
            goto nextArg
        end
    end
    if a == 'geotag' then
        local trkfile = shift(ARGV)
        if pass == 0 then
            -- defer to next pass so the filename charset is available
            push(nextPass, '-geotag', trkfile)
            goto nextArg
        end
        if not truthy(trkfile) then Error("Expecting file name for -geotag option\n") badCmd = 1 goto nextArg end
        -- allow wildcards in filename
        if HasWildcards(trkfile) then
            -- CORE::glob() splits on white space, so use File::Glob if possible
            local trks
            if perl.osname() == 'MSWin32' then
                -- ("-charset filename=UTF8" must be set for this to work with Unicode file names)
                trks = FindFileWindows(mt, trkfile)
            else
                trks = perl.bsd_glob(trkfile)
            end
            if #trks == 0 then Error("No matching file found for -geotag option\n") badCmd = 1 goto nextArg end
            while #trks > 1 do push(newValues, 'geotag=' .. shift(trks)) end
            trkfile = table.remove(trks)
        end
        _ = "geotag=" .. trkfile
        -- (fall through!)
    end
    if isMatch(_, '^h$') or a == 'htmlformat' then
        require('lexiftool.HTML')
        html, escapeHTML = 1, 1
        json, xml = 0, 0
        goto nextArg
    end
    if isMatch(_, '^H$') or a == 'hex' then showTagID = 'H' goto nextArg end
    do
        local isDump, base = isMatch(_, [[(?i)^htmldump([-+]?\d+)?$]])
        if isDump then
            verbose = perl.num(truthy(verbose) and verbose or 0) + 1
            html = 2
            if base ~= nil then mt:Options('HtmlDumpBase', base) end
            goto nextArg
        end
    end
    if isMatch(_, [[(?i)^i(gnore)?$]]) then
        local dir = shift(ARGV)
        if dir == nil then Error("Expecting directory name for -i option\n") badCmd = 1 goto nextArg end
        ignore[dir] = 1
        if dir == 'HIDDEN' then ignoreHidden = 1 end
        goto nextArg
    end
    do
        local isIf, num = isMatch(_, [[(?i)^if(\d*)$]])
        if isIf then
            local cond = shift(ARGV)
            local fast = length(num) > 0 and num or nil
            if cond == nil then Error("Expecting expression for -if option\n") badCmd = 1 goto nextArg end
            -- use lowest -fast setting if multiple conditions
            if #condition == 0 or fast == nil or (fastCondition ~= nil and perl.num(fastCondition) > perl.num(fast)) then
                fastCondition = fast
            end
            -- prevent processing file unnecessarily for simple case of failed '$ok' or 'not $ok'
            local isOk, notOk = isMatch(cond, [[(?i)^\s*(not\s*)\$ok\s*$]])
            if isOk and (truthy(notOk) ~= truthy(rtnValPrev)) then failCondition = 1 end
            -- add to list of requested tags
            push(requestTags, table.unpack(perl.findAll(cond, [[(?i)\$\{?((?:[-_0-9A-Z]+:)*[-_0-9A-Z?*]+)]])))
            push(condition, cond)
            goto nextArg
        end
    end
    if isMatch(_, [[(?i)^(k|pause)$]]) then pause = 1 goto nextArg end
    if isMatch(_, '^l$') or a == 'long' then outFormat = outFormat - 1 goto nextArg end
    if isMatch(_, '^L$') or a == 'latin' then mt:Options('Charset', 'Latin') goto nextArg end
    if a == 'lang' then
        if #ARGV > 0 and not isMatch(ARGV[1], [[^(-|\xe2\x88\x92)]]) then langOpt = shift(ARGV) else langOpt = nil end
        if truthy(langOpt) then
            -- make lower case and use underline as a separator (eg. 'en_ca')
            langOpt = perl.tr(langOpt, '-A-Z', '_a-z')
            mt:Options('Lang', langOpt)
            if langOpt == mt:Options('Lang') then goto nextArg end
        elseif pass == 0 then
            push(nextPass, '-lang')
            if langOpt ~= nil then push(nextPass, langOpt) end
            goto nextArg
        end
        local langs = truthy(quiet) and '' or "Available languages:\n"
        for _, l in ipairs(ExifTool.langs) do langs = langs .. "  " .. l .. " - " .. ExifTool.langName[l] .. "\n" end
        langs = perl.tr(langs, '_', '-')    -- display dashes instead of underlines in language codes
        if truthy(escapeHTML) then langs = require('lexiftool.HTML').EscapeHTML(langs) end
        langs = mt:Decode(langs, 'UTF8')
        if truthy(langOpt) then Error("Invalid or unsupported language '" .. langOpt .. "'.\n" .. langs) badCmd = 1 goto nextArg end
        print(io.stdout, langs)
        helped = 1
        goto nextArg
    end
    if a == 'listitem' then
        local li = shift(ARGV)
        if not (li ~= nil and ExifTool.IsInt(li)) then Warn("Expecting integer for -listItem option\n") goto nextArg end
        mt:Options('ListItem', li)
        listItem = li
        goto nextArg
    end
    if isMatch(_, [[(?i)^(m|ignoreminorerrors)$]]) then mt:Options('IgnoreMinorErrors', 1) goto nextArg end
    if isMatch(_, [[(?i)^(n|-printconv)$]]) then mt:Options('PrintConv', 0) goto nextArg end
    if isMatch(_, [[(?i)^(-n|printconv)$]]) then mt:Options('PrintConv', 1) goto nextArg end
    if a == 'nop' then helped = 1 goto nextArg end -- (undocumented) no operation, added in 11.25
    if isMatch(_, [[(?i)^o(ut)?$]]) then
        outOpt = shift(ARGV)
        if outOpt == nil then Error("Expected output file or directory name for -o option\n") badCmd = 1 goto nextArg end
        outOpt = CleanFilename(outOpt)
        -- verbose messages go to STDERR of output is to console
        -- (upstream tests $vout here, a file handle, which never matches)
        if isMatch(perlStr(vout), [[^-(\.\w+)?$]]) then vout = io.stderr end
        goto nextArg
    end
    if a == 'overwrite_original' then overwriteOrig = 1 goto nextArg end
    if a == 'overwrite_original_in_place' then overwriteOrig = 2 goto nextArg end
    if a == 'plot' then plot = require('lexiftool.Plot').new() goto nextArg end
    do
        local isP, noNL = isMatch(_, [[^p(-?)$]])
        if not isP then isP, noNL = isMatch(_, [[(?i)^printformat(-?)$]]) end
        if isP then
            local fmt = shift(ARGV)
            if pass ~= 0 then
                LoadPrintFormat(fmt, truthy(noNL) and noNL or binaryOutput)
                -- load MWG module now if necessary
                if not useMWG and #grep([[(?i)^([-_0-9A-Z]+:)*1?mwg:]], requestTags) > 0 then
                    useMWG = 1
                    require('lexiftool.MWG').Load()
                end
            else
                -- defer to next pass so the filename charset is available
                push(nextPass, "-" .. _, fmt)
            end
            goto nextArg
        end
    end
    if isMatch(_, '^P$') or a == 'preserve' then preserveTime = 1 goto nextArg end
    if a == 'password' then mt:Options('Password', shift(ARGV)) goto nextArg end
    do
        local isProg, num, title = isMatch(_, [[(?i)^progress(\d*)(:.*)?$]])
        if isProg then
            progressIncr = truthy(num) and perl.num(num) or 1
            progressNext = 0 -- start showing progress at the first file
            if truthy(title) then
                windowTitle = substr(title, 1)
                if not truthy(length(windowTitle)) then windowTitle = 'ExifTool %p%%' end
                if isMatch(windowTitle, [=[%\d*[bpr]]=]) and progress == nil then progress = 0 end
            else
                progress = 1
                if verbose == nil then verbose = 0 end
            end
            progressCount = 0
            goto nextArg
        end
    end
    do
        local isPurge, num = isMatch(_, [[(?i)^purge(\d*)$]])
        if isPurge then -- (undocumented) added in 13.53
            purge = truthy(num) and num or 1
            ExifTool.Purge(purge)
            goto nextArg
        end
    end
    if isMatch(_, [[(?i)^q(uiet)?$]]) then quiet = quiet + 1 goto nextArg end
    do
        local isR, _rec, dot = isMatch(_, [[(?i)^r(ecurse)?(\.?)$]])
        if isR then recurse = truthy(dot) and 2 or 1 goto nextArg end
    end
    if a == 'require' then -- (undocumented) added in version 8.65
        local ver = shift(ARGV)
        if not (ver ~= nil and ExifTool.IsFloat(ver)) then
            Error("Expecting version number for -require option\n")
            badCmd = 1
            goto nextArg
        end
        if perl.num(ExifTool.VERSION) < perl.num(ver) then
            Error("Requires ExifTool version " .. ver .. " or later\n")
            badCmd = 1
        end
        goto nextArg
    end
    if a == 'restore_original' then deleteOrig = 0 goto nextArg end
    if isMatch(_, '^S$') or a == 'veryshort' then outFormat = outFormat + 2 goto nextArg end
    do
        local isS, _hort, num = isMatch(_, [[(?i)^s(hort)?(\d*)$]])
        if isS then
            if num == '' then outFormat = outFormat + 1 else outFormat = perl.num(num) end
            goto nextArg
        end
    end
    if a == 'scanforxmp' then mt:Options('ScanForXMP', 1) goto nextArg end
    if isMatch(_, [[(?i)^sep(arator)?$]]) then
        listSep = shift(ARGV)
        local sep = listSep
        if listSep == nil then Error("Expecting list item separator for -sep option\n") badCmd = 1 goto nextArg end
        sep = subst(sep, [[(?s)\\(.)]], function(c) return unescapeChar[c] or c end, 'g')  -- translate escape sequences
        if binSep ~= nil then binTerm = sep else binSep = sep end
        mt:Options('ListSep', listSep)
        joinLists = 1
        -- also split when writing values
        local listSplit = perl.quotemeta(listSep)
        -- a space in the string matches zero or more whitespace characters
        listSplit = subst(listSplit, [[(\\ )+]], [[\\s\*]], 'g')
        -- but a single space alone matches one or more whitespace characters
        if listSplit == '\\s*' then listSplit = '\\s+' end
        mt:Options('ListSplit', listSplit)
        goto nextArg
    end
    do
        local isSort, neg = isMatch(_, [[(?i)^(-)?sort$]])
        if isSort then sortOpt = neg and 0 or 1 goto nextArg end
    end
    if a == 'srcfile' then
        if #ARGV == 0 then Warn("Expecting FMT for -srcfile option\n") goto nextArg end
        push(srcFmt, shift(ARGV))
        goto nextArg
    end
    if a == 'stay_open' then
        local arg = shift(ARGV)
        if arg == nil then Warn("Expecting argument for -stay_open option\n") goto nextArg end
        if isMatch(arg, [[(?i)^(1|true)$]]) then
            if stayOpen == 0 then
                stayOpen = 1
            elseif stayOpen == 2 then
                stayOpen = 3    -- chained -stay_open options
            else
                Warn("-stay_open already active\n")
            end
        elseif isMatch(arg, [[(?i)^(0|false)$]]) then
            if stayOpen >= 2 then
                -- close -stay_open argfile and process arguments up to this point
                if STAYOPEN ~= io.stdin then STAYOPEN:close() end
                push(ARGV, table.unpack(moreArgs))
                moreArgs = {}
            elseif stayOpen == 0 then
                Warn("-stay_open wasn't active\n")
            end
            stayOpen = 0
        else
            Warn("Invalid argument for -stay_open\n")
        end
        goto nextArg
    end
    do
        local isStruct, neg = isMatch(_, [[(?i)^(-)?struct$]])
        if isStruct then
            mt:Options('Struct', neg and 0 or 1)
            goto nextArg
        end
    end
    if isMatch(_, '^t(ab)?$') then tabFormat = 1 goto nextArg end
    if isMatch(_, '^T$') or a == 'table' then
        tabFormat, forcePrint = 1, 1
        outFormat = outFormat + 2
        quiet = quiet + 1
        goto nextArg
    end
    do
        local isU, u, nknown, two = isMatch(_, [[(?i)^(u)(nknown(2)?)?$]])
        if isU then
            local inc = (truthy(two) or (not nknown and u == 'U')) and 2 or 1
            mt:Options('Unknown', perl.num(mt:Options('Unknown')) + inc)
            goto nextArg
        end
    end
    if a == 'use' then
        local module = shift(ARGV)
        if not truthy(module) then Error("Expecting module name for -use option\n") badCmd = 1 goto nextArg end
        if lc(module) == 'mwg' then useMWG = 1 goto nextArg end
        if isMatch(module, [=[[^\w:]]=]) then Error("Invalid module name: " .. module .. "\n") badCmd = 1 goto nextArg end
        -- (Lua: only modules of this port can be loaded)
        if not (perl.evalRequire('lexiftool::' .. module) or perl.evalRequire(module)) then
            Error("Error using module " .. module .. "\n")
            badCmd = 1
        end
        goto nextArg
    end
    if a == 'userparam' then
        local opt = shift(ARGV)
        if opt == nil then Error("Expected parameter for -userParam option\n") badCmd = 1 goto nextArg end
        if not isMatch(opt, '=') then opt = opt .. '=1' end
        mt:Options('UserParam', opt)
        goto nextArg
    end
    do
        local isV, _erbose, num = isMatch(_, [[(?i)^v(erbose)?(\d*)$]])
        if isV then
            if num == '' then verbose = perl.num(truthy(verbose) and verbose or 0) + 1 else verbose = num end
            goto nextArg
        end
    end
    do
        local isW, t1, t2 = isMatch(_, [[(?i)^(w|textout|tagout)([!+]*)$]])
        if isW then
            -- (note: all logic ignores $textOut of 0 or '')
            textOut = shift(ARGV)
            if not truthy(textOut) then textOut = Warn("Expecting argument for -" .. _ .. " option\n") end
            textOverwrite = 0
            if isMatch(t2, '!') then textOverwrite = textOverwrite + 1 end     -- overwrite
            if isMatch(t2, [[\+]]) then textOverwrite = textOverwrite + 2 end  -- append
            if t1 ~= 'W' and lc(t1) ~= 'tagout' then
                tagOut = nil
            elseif textOverwrite >= 2 and not isMatch(perlStr(textOut), [=[%[-+]?\d*[.:]?\d*[lu]?[tgso]]=]) then
                tagOut = 0 -- append tags to one file
            else
                tagOut = 1 -- separate file for each tag
            end
            goto nextArg
        end
    end
    do
        local isWext, neg = isMatch(_, [[(?i)^(-?)(wext|tagoutext)$]])
        if isWext then
            local ext = shift(ARGV)
            if ext == nil then Error("Expecting extension for -wext option\n") badCmd = 1 goto nextArg end
            local flag = 1
            if truthy(neg) then wext['*'] = 1 flag = -1 end
            ext = subst(ext, [[^\.]], '')
            wext[lc(ext)] = flag
            goto nextArg
        end
    end
    if a == 'wm' or a == 'writemode' then
        local wm = shift(ARGV)
        if wm == nil then Error("Expecting argument for -" .. _ .. " option\n") badCmd = 1 goto nextArg end
        if not isMatch(wm, [[(?i)^[wcg]*$]]) then Error("Invalid argument for -" .. _ .. " option\n") badCmd = 1 goto nextArg end
        mt:Options('WriteMode', wm)
        goto nextArg
    end
    if isMatch(_, '^x$') or a == 'exclude' then
        local tag = shift(ARGV)
        if tag == nil then Error("Expecting tag name for -x option\n") badCmd = 1 goto nextArg end
        tag = subst(tag, [[(?i)\ball\b]], '*', 'g')  -- replace 'all' with '*' in tag names
        if not truthy(tagsFrom) then
            push(exclude, tag)
        elseif tagsFrom == 'CSV' then
            push(csvExclude, tag)
        else
            push(setTags[setTagsFile], "-" .. tag)
        end
        goto nextArg
    end
    if isMatch(_, '^X$') or a == 'xmlformat' then
        xml = 1
        html, json = 0, 0
        mt:Options('Duplicates', 1)
        goto nextArg
    end
    if a == 'php' then
        json = 2
        html, xml = 0, 0
        mt:Options('Duplicates', 1)
        goto nextArg
    end
    if isMatch(_, [[(?i)^z(ip)?$]]) then
        doUnzip = 1
        mt:Options('Compress', 1, 'XMPShorthand', 1)
        if not truthy(mt:Options('Compact')) then mt:Options('Compact', 1) end
        goto nextArg
    end
    if _ == '' then push(files, '-') srcStdin = 1 goto nextArg end    -- read STDIN
    if length(_) == 1 and _ ~= '*' then Error("Unknown option -" .. _ .. "\n") badCmd = 1 goto nextArg end
    local isSet, redir, val = isMatch(_, [[(?s)^[^<]+(<?)=(.*)]])
    if isSet then
        if truthy(redir) and truthy(length(val)) and (val == '@' or FilenameSPrintf(val) == nil) then
            -- save count of new values before a dynamic value
            saveCount = saveCount + 1
            push(newValues, { SaveCount = saveCount })
        end
        push(newValues, _)
        local isGeo, grp, geoName = isMatch(_, [[(?i)^([-_0-9A-Z]+:)*(geotag|geotime|geosync|geolocate)\b]])
        if isMatch(_, [[(?i)^([-_0-9A-Z]+:)*1?mwg:]]) then
            useMWG = 1
        elseif isMatch(_, [[(?i)^([-_0-9A-Z]+:)*(filename|directory|testname)\b]]) then
            doSetFileName = 1
        elseif isGeo then
            if lc(geoName) == 'geotime' then
                addGeotime = ''
            else
                -- add geotag/geosync/geolocate commands first
                unshift(newValues, table.remove(newValues))
                if lc(geoName) == 'geotag' and (addGeotime == nil or truthy(addGeotime)) and truthy(length(val)) then
                    addGeotime = (grp or '') .. [[Geotime<${DateTimeOriginal#;$_=$self->GetValue('SubSecDateTimeOriginal','ValueConv') || $_}]]
                end
            end
        end
    else
        -- assume '-tagsFromFile @' if tags are being redirected
        -- and not from CSV and -tagsFromFile hasn't already been specified
        local isRedir, arrow = isMatch(_, '(<|>)')
        if not truthy(setTagsFile) and tagsFrom ~= 'CSV' and isRedir then
            setTagsFile = '@'
            AddSetTagsFile(setTagsFile)
            tagsFrom = 'File'
        end
        if tagsFrom == 'CSV' then
            local lst = tags
            if isMatch(_, '^-') then _ = subst(_, '^-', '') lst = csvExclude end
            push(lst, _)
        elseif truthy(setTagsFile) then
            push(setTags[setTagsFile], _)
            if arrow == '>' then
                if isMatch(_, [[(?si)^(.*>\s*)?([-_0-9A-Z]+:)*1?mwg:]]) then useMWG = 1 end
                if isMatch(_, [[(?i)\b(filename|directory|testname)#?$]]) then
                    doSetFileName = 1
                elseif isMatch(_, [[(?i)\bgeotime#?$]]) then
                    addGeotime = ''
                end
            else
                if isMatch(_, [[(?si)^([^<]+<\s*(.*\$\{?)?)?([-_0-9A-Z]+:)*1?mwg:]]) then useMWG = 1 end
                if isMatch(_, [[(?i)^([-_0-9A-Z]+:)*(filename|directory|testname)\b]]) then
                    doSetFileName = 1
                elseif isMatch(_, [[(?i)^([-_0-9A-Z]+:)*geotime\b]]) then
                    addGeotime = ''
                end
            end
        else
            local lst = tags
            if isMatch(_, '^-') then _ = subst(_, '^-', '') lst = exclude end
            if not isMatch(_, [[(?i)^([-_0-9A-Z*]+:)*([-_0-9A-Z*?]+)#?$]]) then Warn('Invalid TAG name: "' .. _ .. '"\n') end
            push(lst, _) -- (push everything for backward compatibility)
        end
    end
  else
    if pass == 0 then
        -- defer to next pass so the filename charset is available
        push(nextPass, _)
        goto nextArg
    end
    if doGlob and HasWildcards(_) then
        if perl.osname() == 'MSWin32' then
            push(files, table.unpack(FindFileWindows(mt, _)))
        else
            -- glob each filespec if necessary - MK/20061010
            push(files, table.unpack(perl.bsd_glob(_)))
        end
        doGlob = 2
    else
        push(files, _)
        if _ == '-' then srcStdin = 1 end
    end
  end
  ::nextArg::
end

-- set "OK" UserParam based on result of last command
mt:Options('UserParam', 'OK=' .. (truthy(rtnValPrev) and '' or '1'))

-- set verbose output to STDERR if output could be to console
if srcStdin and (truthy(isWriting) or #newValues > 0) then vout = io.stderr end
if vout == io.stderr then mt:Options('TextOut', vout) end

-- change default EXIF string encoding if MWG used
if useMWG and mt:Options('CharsetEXIF') == nil then
    mt:Options('CharsetEXIF', 'UTF8')
end

-- allow geolocation without input file if set to a position
if #files == 0 and not truthy(outOpt) and #newValues == 0 then
    local loc = mt:Options('Geolocation')
    -- use undocumented feature to input JSON file directly from command line
    if truthy(loc) and loc ~= '1' and loc ~= 1 then push(files, '@JSON:{}') geoOnly = 1 end
end

-- print help
if not ((#tags > 0 and not truthy(outOpt)) or #files > 0 or #newValues > 0 or geoOnly) then
    if doGlob and doGlob == 2 then
        Error("No matching files\n")
        goto nextCommand
    end
    if truthy(outOpt) then Error("Nothing to write\n") goto nextCommand end
    if not helped then
        -- catch warnings if we have problems running perldoc
        -- (Lua: no perldoc -- the help text of the vendored exiftool,
        --  generated into lexiftool/usage.lua, is what `perldoc $0` shows)
        print(io.stdout, (require('lexiftool.usage')))
    end
    goto nextCommand
end

-- do sanity check on -delete_original and -restore_original
if deleteOrig ~= nil and (#newValues > 0 or #tags > 0) then
    if #newValues == 0 then
        local verb = truthy(deleteOrig) and 'deleting' or 'restoring from'
        Error("Can't specify tags when " .. verb .. " originals\n")
    elseif truthy(deleteOrig) then
        Error("Can't use -delete_original when writing.\n")
        Error("Maybe you meant -overwrite_original ?\n")
    else
        Error("It makes no sense to use -restore_original when writing\n")
    end
    goto nextCommand
end

if overwriteOrig > 1 and truthy(outOpt) then
    Error("Can't overwrite in place when -o option is used\n")
    goto nextCommand
end

if (truthy(tagOut) or diff ~= nil) and (truthy(csv) or truthy(json) or next(printFmt) or truthy(tabFormat) or
    truthy(xml) or plot or (truthy(verbose) and truthy(html)))
then
    local opt = truthy(tagOut) and '-W' or '-diff'
    Error("Sorry, " .. opt .. " may not be combined with -csv, -htmlDump, -j, -p, -t or -X\n")
    goto nextCommand
end

if csv and csv == 'CSV' and not truthy(isWriting) then
    json = 0    -- (not compatible)
    if truthy(textOut) then
        textOut2 = textOut
        textOut = nil
    end
    if truthy(binaryOutput) then
        binaryOutput = 0
        if setCharset == nil then setCharset = 'default' end
    end
    if next(printFmt) then
        Warn("The -csv option has no effect when -p is used\n")
        csv = nil
    end
    if truthy(setCharset) then require('lexiftool.XMP') end
end
if plot and truthy(textOut) then
    textOut2 = textOut
    textOut = nil
end
if truthy(textOut2) then
    if textOverwrite > 1 then
        Error("Can not append to multi-file output format\n")
        textOut2 = nil
        goto nextCommand
    end
    if not truthy(textOverwrite) and mt:Exists(textOut2, 1) then
        Error("Output file " .. textOut2 .. " already exists\n")
        textOut2 = nil
        goto nextCommand
    end
    -- make sure we can write the output text file before processing all input files
    CreateDirectory(textOut2)   -- create directory if necessary
    local OUTFILE = mt:Open(textOut2, '>')
    if OUTFILE then
        OUTFILE:close()
        perl.unlink(textOut2)   -- (this was just a test)
    else
        Error("Error creating " .. textOut2 .. "\n")
        textOut2 = nil
        goto nextCommand
    end
end

if truthy(escapeHTML) or truthy(json) then
    -- must be UTF8 for HTML conversion and JSON output
    if truthy(json) then mt:Options('Charset', 'UTF8') end
    -- use Escape option to do our HTML escaping unless XML output
    if truthy(escapeHTML) and not truthy(xml) then mt:Options('Escape', 'HTML') end
elseif escapeXML and not truthy(xml) then
    mt:Options('Escape', 'XML')
end

-- set sort option
if truthy(sortOpt) then
    -- (note that -csv sorts alphabetically by default anyway if more than 1 file)
    local sort_ = (outFormat > 0 or truthy(xml) or truthy(json) or truthy(csv) or plot) and 'Tag' or 'Descr'
    mt:Options('Sort', sort_, 'Sort2', sort_)
end

-- set $structOpt in case set by API option
if truthy(mt:Options('Struct')) and not truthy(structOpt) then
    structOpt = mt:Options('Struct')
    require('lexiftool.XMPStruct')
end

-- set up for RDF/XML, JSON and PHP output formats
if plot then
    joinLists = nil
    mt:Options('List', 1)
    plot:Settings(mt:Options('Plot'))
elseif truthy(xml) then
    require('lexiftool.XMP')    -- for EscapeXML()
    local charset = mt:Options('Charset')
    -- standard XML encoding names for supported Charset settings
    -- (ref http://www.iana.org/assignments/character-sets)
    local encoding = {
        UTF8     = 'UTF-8',
        Latin    = 'windows-1252',
        Latin2   = 'windows-1250',
        Cyrillic = 'windows-1251',
        Greek    = 'windows-1253',
        Turkish  = 'windows-1254',
        Hebrew   = 'windows-1255',
        Arabic   = 'windows-1256',
        Baltic   = 'windows-1257',
        Vietnam  = 'windows-1258',
        MacRoman = 'macintosh',
    }
    -- switch to UTF-8 if we don't have a standard encoding name
    if not encoding[charset] then
        charset = 'UTF8'
        mt:Options('Charset', charset)
    end
    -- set file header/trailer for XML output
    fileHeader = "<?xml version='1.0' encoding='" .. encoding[charset] .. "'?>\n" ..
                 "<rdf:RDF xmlns:rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#'>\n"
    fileTrailer = "</rdf:RDF>\n"
    -- extract as a list unless short output format
    if outFormat > 0 then joinLists = 1 end
    if not joinLists then mt:Options('List', 1) end
    showGroup, allGroup = 1, 1          -- always show group 1
    -- set binaryOutput flag to 0 or undef (0 = output encoded binary in XML)
    if truthy(binaryOutput) then
        if outFormat > 0 then binaryOutput = nil else binaryOutput = 0 end
    end
    if truthy(tabFormat) and not truthy(showTagID) then showTagID = 'D' end
elseif truthy(json) then
    if json == 1 then -- JSON
        fileHeader = '['
        fileTrailer = "]\n"
    else -- PHP
        fileHeader = 'Array('
        fileTrailer = ");\n"
    end
    -- allow binary output in a text-mode file when -php/-json and -b used together
    -- (this works because PHP strings are simple arrays of bytes, and CR/LF
    --  won't be messed up in the text mode output because they are converted
    --  to escape sequences in the strings)
    if truthy(binaryOutput) then
        binaryOutput = 0
        if json == 1 then require('lexiftool.XMP') end  -- (for EncodeBase64)
    end
    if not joinLists then mt:Options('List', 1) end
    if truthy(tabFormat) and not truthy(showTagID) then showTagID = 'D' end
elseif truthy(structOpt) then
    mt:Options('List', 1)
else
    joinLists = 1       -- join lists for all other unstructured output formats
end

if argFormat then
    outFormat = 3
    if showGroup ~= nil then allGroup = 1 end
end

-- change to forward slashes if necessary in all filenames (like CleanFilename)
if ExifTool.IsPC() then
    for i = 1, #files do files[i] = perl.tr(files[i], '\\', '/') end
end

-- can't do anything if no file specified
if #files == 0 then
    if not truthy(outOpt) then
        if doGlob and doGlob == 2 then
            Error("No matching files\n")
        else
            Error("No file specified\n")
        end
        goto nextCommand
    end
    push(files, '')     -- create file from nothing
end

-- set Verbose and HtmlDump options
if truthy(verbose) then
    if not (#tags > 0 or #exclude > 0 or truthy(tagOut)) then disableOutput = 1 end
    if not truthy(tagOut) then binaryOutput = nil end   -- disable conflicting option
    if truthy(html) then
        html = 2    -- flag for html dump
        mt:Options('HtmlDump', verbose)
    else
        if not truthy(tagOut) then mt:Options('Verbose', verbose) end
    end
elseif verbose ~= nil then
    -- auto-flush output when -v0 is used
    perl.autoflush(io.stdout, 1)
    perl.autoflush(io.stderr, 1)
end

-- validate all tags we're writing
do
local needSave = 1
if #newValues > 0 then
    -- assume -geotime value if -geotag specified without -geotime
    if truthy(addGeotime) then
        if not (setTagsFile and setTagsFile == '@') then
            setTagsFile = '@'
            AddSetTagsFile(setTagsFile)
        end
        push(setTags[setTagsFile], addGeotime)
        if truthy(verbose) then print(vout, 'Using default "-' .. addGeotime .. '"\n') end
    end
    local setTagsIndex = {}
    -- add/delete option lookup
    local addDelOpt = { ['+'] = 'AddValue', ['-'] = 'DelValue', ["\xe2\x88\x92"] = 'DelValue' }
    saveCount = 0
    for _, nv in ipairs(newValues) do
        if type(nv) == 'table' then
            -- save new values now if we stored a "SaveCount" marker
            if truthy(nv.SaveCount) then
                saveCount = mt:SaveNewValues()
                needSave = 0
                -- insert marker to load values from CSV file now if this was the CSV file
                if nv.SaveCount == dbSaveCount then push(dynamicFiles, { ref = 'SCALAR', name = 'csv' }) end
            end
            goto nextValue
        end
        do
            local isNV, tag, newVal = isMatch(nv, [[(?s)(.*?)=(.*)]])
            if not isNV then goto nextValue end
            tag = subst(tag, [[(?i)\ball\b]], '*', 'g')    -- replace 'all' with '*' in tag names
            if isMatch(tag, [[\^([-+]*)$]]) then
                tag = subst(tag, [[\^([-+]*)$]], '$1')
            elseif newVal == '' then
                newVal = nil    -- undefined to delete tag
            end
            if isMatch(tag, [[(?i)^(All)?TagsFromFile$]]) then
                if newVal == nil then Error("Need file name for -tagsFromFile\n") goto nextCommand end
                isWriting = isWriting + 1
                if newVal == '@' or FilenameSPrintf(newVal) == nil or
                    -- can't set tags yet if we are using tags from other files with the -fileNUM option
                    #grep([[(?i)\bfile\d+:]], setTags[newVal]) > 0
                then
                    push(dynamicFiles, newVal)
                    goto nextValue  -- set tags from dynamic file later
                end
                if not (mt:Exists(newVal) or newVal == '-') then
                    Error("File '" .. newVal .. "' does not exist for -tagsFromFile option\n")
                    goto nextCommand
                end
                local setTags_ = setTags[newVal]
                -- do we have multiple -tagsFromFile options with this file?
                if setTagsList[newVal] then
                    -- use the tags set in the i-th occurrence
                    local i = setTagsIndex[newVal] or 0
                    setTagsIndex[newVal] = i + 1
                    if setTagsList[newVal][i + 1] then setTags_ = setTagsList[newVal][i + 1] end
                end
                -- set specified tags from this file
                if not truthy(DoSetFromFile(mt, newVal, setTags_)) then
                    rtnVal = 1
                    goto nextCommand
                end
                needSave = 1
                goto nextValue
            end
            local opts = { Shift = 0 }  -- shift values if possible instead of adding/deleting
            -- allow writing of 'Unsafe' tags unless specified by wildcard
            if not isMatch(tag, '[?*]') then opts.Protected = 1 end

            if isMatch(tag, '<') and newVal ~= nil then
                tag = subst(tag, '<', '')
                if FilenameSPrintf(newVal) ~= nil then
                    local ok
                    ok, newVal = SlurpFile(newVal)  -- read file data into $newVal
                    if not ok then goto nextValue end
                else
                    local isAD, ad = isMatch(tag, [[([-+]|\xe2\x88\x92)$]])
                    if isAD then
                        tag = subst(tag, [[([-+]|\xe2\x88\x92)$]], '')
                        opts[addDelOpt[ad]] = 1
                    end
                    -- verify that this tag can be written
                    local result = ExifTool.IsWritable(tag)
                    if truthy(result) then
                        opts.ProtectSaved = saveCount   -- protect new values set after this
                        -- add to list of dynamic tag values
                        push(dynamicFiles, { tag, newVal, opts })
                        isWriting = isWriting + 1
                    elseif result ~= nil then
                        Warn("Tag '" .. tag .. "' is not writable\n")
                    else
                        Warn("Tag '" .. tag .. "' does not exist\n")
                    end
                    goto nextValue
                end
            elseif isMatch(tag, '<') then
                tag = subst(tag, '<', '')
            end
            local isAD, ad = isMatch(tag, [[([-+]|\xe2\x88\x92)$]])
            if isAD then
                tag = subst(tag, [[([-+]|\xe2\x88\x92)$]], '')
                opts[addDelOpt[ad]] = 1    -- set AddValue or DelValue option
                -- set $newVal to '' if deleting nothing
                if ad == '-' and newVal == nil then newVal = '' end
            end
            if escapeC and newVal ~= nil then
                -- (`s/\\(x([0-9a-fA-F]{2})|.)/$2 ? chr(hex($2)) : $unescC{$1} || $1/seg`,
                --  with the optional inner group folded into the one capture)
                newVal = subst(newVal, [[(?s)\\(x[0-9a-fA-F]{2}|.)]], function(c1)
                    if #c1 == 3 then return perl.chr(perl.hex(substr(c1, 1))) end
                    return unescC[c1] or c1
                end, 'g')
            end
            local rtn, wrn = mt:SetNewValue(tag, newVal, opts)
            needSave = 1
            if truthy(rtn) then isWriting = isWriting + 1 end
            if truthy(wrn) then Warning(mt, wrn) end
        end
        ::nextValue::
    end
    -- exclude specified tags
    for _, ex in ipairs(exclude) do
        mt:SetNewValue(ex, nil, { Replace = 2 })
        needSave = 1
    end
    if not (truthy(isWriting) or truthy(outOpt) or #tags > 0) then
        Error("Nothing to do.\n")
        goto nextCommand
    end
elseif #grep([[^(\*:)?\*$]], exclude) > 0 then
    Error("All tags excluded -- nothing to do.\n")
    goto nextCommand
end
if truthy(isWriting) then
    if diff ~= nil then
        Error("Can't use -diff option when writing tags\n")
        goto nextCommand
    elseif plot then
        Error("Can't use -plot option when writing tags\n")
        goto nextCommand
    elseif #tags > 0 and not truthy(outOpt) and not truthy(csv) then
        local tg, s
        if #tags > 1 then tg, s = tags[1] .. ' ...', 's' else tg, s = tags[1], '' end
        Warn("Ignored superfluous tag name" .. s .. " or invalid option" .. s .. ": -" .. tg .. "\n")
    end
end
-- save current state of new values if setting values from target file
-- or if we may be translating to a different format
if truthy(outOpt) or (#dynamicFiles > 0 and truthy(needSave)) then mt:SaveNewValues() end
end

if #files > 1 then multiFile = 1 end
if #exclude > 0 then mt:Options('Exclude', exclude) end

if truthy(html) then binaryOutput = nil end

if truthy(binaryOutput) then
    outFormat = 99      -- shortest possible output format
    mt:Options('PrintConv', 0)
    if not (truthy(textOut) or truthy(binaryStdout)) then
        perl.binmode(io.stdout)
        binaryStdout = 1
        vout = io.stderr
        mt:Options('TextOut', vout)
    end
    -- disable conflicting options
    showGroup = nil
end

-- sort by groups to look nicer depending on options
if showGroup ~= nil and not (#tags > 0 and (truthy(allGroup) or truthy(csv))) and (truthy(sortOpt) or sortOpt == nil) then
    mt:Options('Sort', "Group" .. showGroup)
end

if truthy(textOut) then
    textOut = CleanFilename(textOut)    -- make all forward slashes
    -- add '.' before output extension if necessary
    if not (isMatch(textOut, '[.%]') or tagOut ~= nil) then textOut = "." .. textOut end
end

-- determine if we should scan for only writable files
if truthy(outOpt) then
    local type_ = GetFileType(outOpt)
    if truthy(type_) then
        -- (must test original file name because we can write .webp but not other RIFF types)
        local canWrite = CanWrite(outOpt)
        if not truthy(canWrite) then
            if canWrite ~= nil and canWrite == '' then
                type_ = ExifTool.GetFileExtension(outOpt)
                if type_ == nil then type_ = uc(outOpt) end
            end
            Error("Can't write " .. type_ .. " files\n")
            goto nextCommand
        end
        if not truthy(CanCreate(type_)) then scanWritable = type_ end
    else
        scanWritable = 1
    end
    isWriting = 1   -- set writing flag
elseif truthy(isWriting) or deleteOrig ~= nil then
    scanWritable = 1
end

-- initialize alternate encoding flag
altEnc = mt:Options('Charset')
if altEnc == 'UTF8' then altEnc = nil end

-- set flag to fix description lengths if necessary
if not altEnc and mt:Options('Lang') ~= 'en' then
    -- (note that Unicode::GCString is part of the Unicode::LineBreak package)
    fixLen = perl.evalRequire('Unicode::GCString') and 2 or 1
end

-- sort input files if specified
if #fileOrder > 0 then
    local allFiles = {}
    ProcessFiles(mt, allFiles)
    local sortTool = ExifTool.new()
    if truthy(fileOrderFast) then sortTool:Options('FastScan', fileOrderFast) end
    sortTool:Options('PrintConv', mt:Options('PrintConv'))
    sortTool:Options('Duplicates', 0)
    local sortBy, isFloat, rev = {}, {}, {}
    -- save reverse sort flags
    for i, o in ipairs(fileOrder) do
        if isMatch(o, '^-') then
            fileOrder[i] = subst(o, '^-', '')
            push(rev, 1)
        else
            push(rev, 0)
        end
    end
    for _, file in ipairs(allFiles) do
        local tags_ = {}
        local args = { table.unpack(fileOrder) }
        push(args, tags_)
        local info = sortTool:ImageInfo(Infile(file, 1), table.unpack(args))
        -- get values of all tags (or '~' to sort last if not defined)
        for i, t in ipairs(tags_) do
            local v = info[t]   -- put tag value into @tag list
            if v == nil then
                v = '~'
            else
                isFloat[v] = ExifTool.IsFloat(v)
                -- pad numbers to 12 digits to keep them sequential
                if not isFloat[v] then
                    v = subst(perlStr(v), [[(\d+)]], function(d)
                        return (length(d) < 12 and string.rep('0', 12 - length(d)) or '') .. d
                    end, 'g')
                end
            end
            tags_[i] = v
        end
        sortBy[file] = tags_    -- save tag values for each file
    end
    -- sort in specified order
    files = sort(allFiles, function(a, b)
        local cmp
        for i = 1, #rev do
            local u = sortBy[a][i]
            local v = sortBy[b][i]
            if not isFloat[u] and not isFloat[v] then
                cmp = perl.cmp(u, v)    -- alphabetically
            elseif isFloat[u] and isFloat[v] then
                cmp = perl.num(u) < perl.num(v) and -1 or (perl.num(u) > perl.num(v) and 1 or 0)    -- numerically
            else
                cmp = isFloat[u] and -1 or 1    -- numbers first
            end
            if cmp ~= 0 then return rev[i] == 1 and -cmp or cmp end
        end
        return perl.cmp(a, b)   -- default to sort by name
    end)
elseif progress ~= nil then
    -- expand FILE argument to count the number of files to process
    local allFiles = {}
    ProcessFiles(mt, allFiles)
    files = allFiles
end
-- set file count for progress message
if progress ~= nil then progressMax = #files end

-- store duplicate database information under absolute path and with standardized case
do
local dbKeys = keys(database)
if #dbKeys > 0 then
    evalWarning = nil
    for _, key in ipairs(dbKeys) do
        local db = database[key]
        if isMatch(key, [[\\]]) then
            key = perl.tr(key, '\\', '/')
            database[key] = db  -- allow for backslashes in SourceFile
        end
        if not database[lc(key)] then database[lc(key)] = db end   -- duplicate entry with lower case
        -- (punt on using ConvertFileName here, so $absPath may be a mix of encodings)
        local absPath = AbsPath(key)
        if absPath ~= nil then
            if not database[absPath] then database[absPath] = db end
            if truthy(verbose) and perl.num(verbose) > 1 then
                print(vout, "Imported entry for '" .. key .. "' (full path: '" .. absPath .. "')\n")
            end
            if not database[lc(absPath)] then database[lc(absPath)] = db end
        elseif truthy(verbose) and perl.num(verbose) > 1 then
            print(vout, "Imported entry for '" .. key .. "' (no full path)\n")
        end
    end
end
end

-- process all specified files
ProcessFiles(mt)

if filtered and not validFile then Error("No file with specified extension\n") end

-- print folder/file trailer if necessary
if truthy(textOut) then
    for _, file in ipairs(keys(outTrailer)) do
        if truthy(outTrailer[file]) then
            local OUTTRAIL = mt:Open(file, '>>')
            if OUTTRAIL then
                perl.binmode(OUTTRAIL, ':crlf') -- (port: Perl's text-mode open, see Port notes)
                local fp = OUTTRAIL
                print(fp, outTrailer[file])
                fp:close()
            else
                Error("Error appending to " .. file .. "\n")
            end
        end
    end
else
    if truthy(sectTrailer) then print(io.stdout, sectTrailer) end
    if truthy(fileTrailer) and not truthy(fileHeader) then print(io.stdout, fileTrailer) end
    -- print CSV or SVG output file if necessary
    local fp, err
    if truthy(textOut2) then
        local OUTFILE = mt:Open(textOut2, '>')
        if OUTFILE then
            perl.binmode(OUTFILE, ':crlf')  -- (port: Perl's text-mode open, see Port notes)
            fp = OUTFILE
        else
            Error("Error creating " .. textOut2 .. "\n")
            err = 1
        end
    end
    if not err then
        if truthy(csv) and not truthy(isWriting) then PrintCSV(fp) end
        -- print SVG plot
        if plot then
            plot:Draw(fp or io.stdout)
            if truthy(plot.Error) then
                Error("Error: " .. plot.Error .. "\n")
                err = 1
            elseif truthy(plot.Warn) then
                Warn("Warning: " .. plot.Warn .. "\n")
            end
        end
    end
    if fp then
        if not fp:close() then err = 1 end
        if err then
            mt:Unlink(textOut2)
        else
            created[textOut2] = 1
        end
    end
end

do
local totWr = countGoodWr + countBadWr + countSameWr + countCopyWr +
              countGoodCr + countBadCr

if deleteOrig ~= nil then

    -- print summary and delete requested files
    if not truthy(quiet) then
        if countDir > 0 then printf(io.stdout, "%5d directories scanned\n", countDir) end
        if countNewDir > 0 then printf(io.stdout, "%5d directories created\n", countNewDir) end
        if countFailed > 0 then printf(io.stdout, "%5d files failed condition\n", countFailed) end
        printf(io.stdout, "%5d image files found\n", count)
    end
    if #delFiles > 0 then
        -- verify deletion unless "-delete_original!" was specified
        if deleteOrig == 1 then
            printf(io.stdout, '%5d originals will be deleted!  Are you sure [y/n]? ', #delFiles)
            io.stdout:flush()
            local response = io.stdin:read('L')
            if not isMatch(response, [[(?i)^(y|yes)\s*$]]) then
                Warn("Originals not deleted.\n")
                goto nextCommand
            end
        end
        countGoodWr = mt:Unlink(table.unpack(delFiles))
        countBad = #delFiles - countGoodWr
    end
    if truthy(quiet) then -- luacheck: ignore 542
        -- no more messages
    elseif count > 0 and countGoodWr == 0 and countBad == 0 then
        printf(io.stdout, "%5d original files found\n", countGoodWr) -- (this will be 0)
    elseif truthy(deleteOrig) then
        if count > 0 then printf(io.stdout, "%5d original files deleted\n", countGoodWr) end
        if countBad > 0 then printf(io.stdout, "%5d originals not deleted due to errors\n", countBad) end
    else
        if count > 0 then printf(io.stdout, "%5d image files restored from original\n", countGoodWr) end
        if countBad > 0 then printf(io.stdout, "%5d files not restored due to errors\n", countBad) end
    end

elseif (not truthy(binaryStdout) or truthy(verbose)) and not truthy(quiet) then

    -- print summary
    local tot = count + countBad
    if countDir > 0 or totWr > 0 or countFailed > 0 or tot > 1 or truthy(textOut) or next(countLink) then
        local o = ((truthy(html) or truthy(json) or truthy(xml) or next(printFmt) or truthy(csv) or plot) and
                   not truthy(textOut)) and io.stderr or vout
        if countDir > 0 then printf(o, "%5d directories scanned\n", countDir) end
        if countNewDir > 0 then printf(o, "%5d directories created\n", countNewDir) end
        if countFailed > 0 then printf(o, "%5d files failed condition\n", countFailed) end
        if countGoodCr > 0 then printf(o, "%5d image files created\n", countGoodCr) end
        if totWr - countGoodCr - countBadCr - countCopyWr ~= 0 then printf(o, "%5d image files updated\n", countGoodWr) end
        if countSameWr > 0 then printf(o, "%5d image files unchanged\n", countSameWr) end
        if countCopyWr > 0 then printf(o, "%5d image files %s\n", countCopyWr, truthy(overwriteOrig) and 'moved' or 'copied') end
        if countBadWr > 0 then printf(o, "%5d files weren't updated due to errors\n", countBadWr) end
        if countBadCr > 0 then printf(o, "%5d files weren't created due to errors\n", countBadCr) end
        if (tot + countFailed) > 1 or (countDir > 0 and totWr == 0) then printf(o, "%5d image files read\n", count) end
        if countBad > 0 then printf(o, "%5d files could not be read\n", countBad) end
        if truthy(textOut) or truthy(textOut2) then printf(o, "%5d output files created\n", #keys(created)) end
        if next(appended) then printf(o, "%5d output files appended\n", #keys(appended)) end
        if truthy(countLink.Hard) or truthy(countLink.BadHard) then printf(o, "%5d hard links created\n", countLink.Hard or 0) end
        if truthy(countLink.BadHard) then printf(o, "%5d hard links could not be created\n", countLink.BadHard) end
        if truthy(countLink.Sym) or truthy(countLink.BadSym) then printf(o, "%5d symbolic links created\n", countLink.Sym or 0) end
        if truthy(countLink.BadSym) then printf(o, "%5d symbolic links could not be created\n", countLink.BadSym) end
    end
end

-- set error status if we had any errors or if all files failed the "-if" condition
if countBadWr > 0 or countBadCr > 0 or countBad > 0 then
    rtnVal = 1
elseif countFailed > 0 and not (count > 0 or totWr > 0) and not truthy(rtnVal) then
    rtnVal = 2
end
end

if purge then ExifTool.Purge(0) end -- do final purging

-- clean up after each command
Cleanup()

::nextCommand::
end -- end "Command" loop ......................................................

if stayOpen >= 2 and STAYOPEN ~= io.stdin then STAYOPEN:close() end

Exit(rtnValApp)     -- all done
end

--------------------------------------------------------------------------------
-- Get image information from EXIF data in file (or write file if writing)
-- Inputs: 0) ExifTool object reference, 1) file name
function GetImageInfo(et, orig)
    local foundTags, found2 = {}, {}
    local info, info2, et2, file, file2, ind

    -- set window title for this file if necessary
    if windowTitle ~= nil then
        if progressCount >= progressNext then
            local prog = truthy(progressMax) and (progressCount .. '/' .. progressMax) or '0/0'
            local title = windowTitle
            local num, denom = table.unpack(split('/', prog))
            local frac = perl.num(num) / (truthy(denom) and perl.num(denom) or 1)
            local n = 20    -- length of bar
            local hasLen, barLen = isMatch(title, [[%(\d+)b]])
            if hasLen then
                title = subst(title, [[%(\d+)b]], '%b')
                n = perl.num(barLen)
            end
            local bar = perl.int(frac * n + 0.5)
            local lkup = {
                b = string.rep('I', bar) .. string.rep('.', n - bar),
                f = orig,
                p = perl.int(100 * frac + 0.5),
                r = prog,
               ['%'] = '%',
            }
            title = subst(title, '%([%bfpr])', function(c) return perlStr(lkup[c]) end, 'g')
            SetWindowTitle(title)
            if progressMax ~= nil then
                progressNext = nil
            else
                progressNext = progressNext + progressIncr
            end
        end
        -- ($progressMax is not defined for "-progress:%f")
        if progressMax == nil then progressCount = progressCount + 1 end
    end
    if not (truthy(length(orig)) or truthy(outOpt)) then
        Warn('Error: Zero-length file name - ""\n')
        countBad = countBad + 1
        return
    end
    -- determine the name of the source file based on the original input file name
    if #srcFmt > 0 then
        local first
        for _, fmt in ipairs(srcFmt) do
            file = fmt == '@' and orig or FilenameSPrintf(fmt, orig)
            -- use this file if it exists
            if et:Exists(file) then first = nil break end
            if truthy(verbose) then print(vout, "Source file " .. perlStr(file) .. " does not exist\n") end
            if first == nil then first = file end
        end
        if first ~= nil then file = first end
        local d, f = ExifTool.SplitFileName(orig)
        et:Options('UserParam', "OriginalDirectory#=" .. d)
        et:Options('UserParam', "OriginalFileName#=" .. f)
    else
        file = orig
    end
    -- set alternate file names
    for _, g8 in ipairs(sort(keys(altFile))) do
        local altName = orig
        if altFile[g8] ~= '@' then
            -- must double any '$' symbols in the original file name because
            -- they are used for tag names in a -fileNUM argument
            altName = subst(altName, [[\$]], [[\$\$]], 'g')
            altName = FilenameSPrintf(altFile[g8], altName)
        end
        et:SetAlternateFile(g8, altName)
    end

    local pipe = file
    if doUnzip then
        -- pipe through gzip or bzip2 if necessary
        local isZip, zipType = isMatch(file, [[(?i)\.(gz|bz2)$]])
        if isZip then
            local type_ = lc(zipType)
            if isMatch(file, [=[[^-_.'A-Za-z0-9\/\\]]=]) then
                Warn("Error: Insecure zip file name. Skipped\n")
                EFile(file)
                countBad = countBad + 1
                return
            end
            if type_ == 'gz' then
                pipe = 'gzip -dc "' .. file .. '" |'
            else
                pipe = 'bzip2 -dc "' .. file .. '" |'
            end
            et.TRUST_PIPE = 1
        end
    end
    -- evaluate -if expression for conditional processing
    if #condition > 0 then
        local result
        if not failCondition then
            -- catch run time errors as well as compile errors
            evalWarning = nil
            local oldWarn = perl.SIG.__WARN__
            perl.SIG.__WARN__ = function(msg) evalWarning = msg end

            -- extract information and build expression for evaluation
            local opts = { Duplicates = 1, RequestTags = requestTags, Verbose = 0, HtmlDump = 0 }
            if fastCondition ~= nil then opts.FastScan = fastCondition end
            -- return all tags but explicitly mention tags on command line so
            -- requested images will generate the appropriate warnings
            if #tags > 0 then foundTags = { '*', table.unpack(tags) } end
            info = et:ImageInfo(Infile(pipe, isWriting), foundTags, opts)
            for _, cond in ipairs(condition) do
                local info_h = {}   -- (upstream's %info, next to $info)
                cond = et:InsertTagValues(cond, foundTags, info_h)
                do
                    -- set package so eval'd functions are in Image::ExifTool namespace
                    -- (Lua: perl.eval runs the condition; it calls the
                    --  Image::ExifTool functions, End/EndDir among them,
                    --  through ExifTool.evalFuncs)

                    --### eval "-if" condition (%info, $self)
                    local ok, res = pcall(perl.eval, cond, { info = info_h, self = et },
                                          ExifTool.evalFuncs({ End = ExifTool.End, EndDir = ExifTool.EndDir }))
                    if ok then
                        result = res
                    else
                        result = nil
                        evalWarning = perl.isDie(res) and res.msg or tostring(res)
                    end
                end
                if evalWarning then
                    -- fail condition if warning is issued
                    result = nil
                    -- (port: a condition in Perl syntax that perl.eval does
                    --  not interpret is reported even without -v -- it is
                    --  not a condition that failed, see doc/differences.md)
                    if truthy(verbose) or isMatch(evalWarning, '^Perl syntax unsupported in lexiftool: ') then
                        evalWarning = perl.chomp(evalWarning)
                        evalWarning = subst(evalWarning, [[(?s) at \(eval .*]], '')
                        Warn("Condition: " .. evalWarning .. " - " .. file .. "\n")
                    end
                end
                if not truthy(result) then break end
            end
            if truthy(fastCondition) then foundTags = {} end -- ignore if we didn't get all tags
            perl.SIG.__WARN__ = oldWarn
        end
        if truthy(result) then
            -- discard $info for non-existent file
            if not (file == '-' or et:Exists(file)) then info = nil end
        else
            if truthy(verbose) then Progress(vout, "-------- " .. file .. " (failed condition)") end
            EFile(file, 2)
            countFailed = countFailed + 1
            return
        end
        -- can't make use of $info if verbose because we must reprocess
        -- the file anyway to generate the verbose output
        -- (also if writing just to avoid double-incrementing FileSequence)
        if truthy(isWriting) or truthy(verbose) or fastCondition ~= nil or diff ~= nil then
            info = nil
            et.FILE_SEQUENCE = et.FILE_SEQUENCE - 1
        end
    elseif isMatch(file, [[(?s)^(@JSON:)(.*)]]) then
        -- read JSON file from command line
        local _j, dat = matches(file, [[(?s)^(@JSON:)(.*)]])
        file = subst(file, [[(?s)^(@JSON:)(.*)]], '$1')
        info = et:ImageInfo({ ref = 'SCALAR', value = dat }, foundTags)
        if geoOnly then
            for _, k in ipairs(keys(info)) do
                if not isMatch(k, '^Geolocation') then info[k] = nil end
            end
            file = ' '
        end
    end
    if deleteOrig ~= nil then
        if verbose ~= nil then Progress(vout, "======== " .. file) end
        count = count + 1
        local original = file .. "_original"
        if not et:Exists(original) then return end
        if truthy(deleteOrig) then
            if truthy(verbose) then print(vout, "Scheduled for deletion: " .. original .. "\n") end
            push(delFiles, original)
        elseif et:Rename(original, file) then
            if truthy(verbose) then print(vout, "Restored from " .. original .. "\n") end
            EFile(file, 3)
            countGoodWr = countGoodWr + 1
        else
            Warn("Error renaming " .. original .. "\n")
            EFile(file)
            countBad = countBad + 1
        end
        return
    end
    seqFileNum = seqFileNum + 1     -- increment our file counter
    local dir = ExifTool.SplitFileName(orig)
    seqFileDir_h[dir] = (seqFileDir_h[dir] or 0) + 1
    seqFileDir = seqFileDir_h[dir]

    local lineCount = 0
    local fp, outfile, append
    if truthy(textOut) and (truthy(verbose) or truthy(et:Options('PrintCSV'))) and
        not (truthy(tagOut) or diff ~= nil or plot)
    then
        fp, outfile, append = OpenOutputFile(orig)
        if not fp then EFile(file) countBad = countBad + 1 return end
        -- delete file if we exit prematurely (unless appending)
        if not append then tmpText = outfile end
        et:Options('TextOut', fp)
    end

    if truthy(isWriting) then
        if verbose ~= nil then Progress(vout, "======== " .. file) end
        SetImageInfo(et, file, orig)
        info = et:GetInfo('Warning', 'Error')
        PrintErrors(et, info, file)
        -- close output text file if necessary
        if outfile ~= nil then
            tmpText = nil
            fp:close()
            et:Options('TextOut', vout)
            if info.Error then
                et:Unlink(outfile)  -- erase bad file
            elseif append then
                if not created[outfile] then appended[outfile] = 1 end
            else
                created[outfile] = 1
            end
        end
        return
    end

    -- extract information from this file
    if not (file == '-' or et:Exists(file) or info) then
        Warn("Error: File not found - " .. file .. "\n")
        FileNotFound(file)
        if outfile ~= nil then fp:close() tmpText = nil et:Unlink(outfile) end
        EFile(file)
        countBad = countBad + 1
        return
    end
    -- print file/progress message
    local o
    if not (truthy(binaryOutput) or truthy(textOut) or next(printFmt) or html > 1 or truthy(csv) or plot) then
        if truthy(html) then
            local HTML = require('lexiftool.HTML')
            local f = HTML.EscapeHTML(file)
            print(io.stdout, "<!-- " .. f .. " -->\n")
        elseif not (truthy(json) or truthy(xml) or diff ~= nil) then
            if (truthy(multiFile) and not truthy(quiet)) or truthy(progress) then o = io.stdout end
        end
    end
    if truthy(progress) and not o then o = io.stderr end
    if o then Progress(o, "======== " .. file) end
    if info then
        -- get the information we wanted
        if #tags > 0 and not next(printFmt) then
            foundTags = { table.unpack(tags) }
            info = et:GetInfo(foundTags)
        end
    else
        -- request specified tags unless using print format option
        local oldDups = et:Options('Duplicates')
        if next(printFmt) then
            et:Options('Duplicates', 1)
            et:Options('RequestTags', requestTags)
            if printFmt.SetTags then
                -- initialize options so we can set any tags we want
                et.TAGS_FROM_FILE = 1
                et:Options('MakerNotes', 1)
                et:Options('Struct', 2)
                et:Options('List', 1)
                if not truthy(et:Options('CoordFormat')) then et:Options('CoordFormat', '%d %d %.8f') end
            end
        else
            foundTags = { table.unpack(tags) }
        end
        if diff ~= nil then
            file2 = FilenameSPrintf(diff, orig)
            if file == file2 then
                Warn("Error: Diffing file with itself - " .. file2 .. "\n")
                EFile(file)
                countBad = countBad + 1
                return
            end
            if et:Exists(file2) then
                if showGroup == nil then showGroup = 1 end
                if allGroup == nil then allGroup = 1 end
                et:Options('Duplicates', 1, 'Sort', "Group" .. showGroup, 'Verbose', 0)
                et2 = ExifTool.new()
                for k, v in pairs(et.OPTIONS) do et2:Options(k, v) end
                -- must set list options specifically because they may have been
                -- set incorrectly from deprecated List settings
                et2:Options('ListSep', et.OPTIONS.ListSep)
                et2:Options('ListSplit', et.OPTIONS.ListSplit)
                found2 = { table.unpack(foundTags) }
                info2 = et2:ImageInfo(file2, found2)
            else
                info2 = { Error = "Diff file not found" }
            end
            if info2.Error then
                Warn("Error: " .. info2.Error .. " - " .. file2 .. "\n")
                EFile(file)
                countBad = countBad + 1
                return
            end
        end
        -- extract the information
        info = et:ImageInfo(Infile(pipe), foundTags)
        et:Options('Duplicates', oldDups)
    end

    -- all done now if we already wrote output text file (eg. verbose option)
    if fp then
        if outfile ~= nil then
            et:Options('TextOut', io.stdout)
            tmpText = nil
            if info.Error then
                fp:close()
                et:Unlink(outfile)  -- erase bad file
            else
                lineCount = lineCount + 1   -- output text file (likely) is not empty
            end
        end
        if info.Error then
            Warn("Error: " .. info.Error .. " - " .. file .. "\n")
            EFile(file)
            countBad = countBad + 1
            return
        end
    end

    -- print warnings to stderr if using binary output
    -- (because we are likely ignoring them and piping stdout to file)
    -- or if there is none of the requested information available
    if truthy(binaryOutput) or next(info) == nil then
        local errs = et:GetInfo('Warning', 'Error')
        if PrintErrors(et, errs, file) then EFile(file) rtnVal = 1 end
    elseif truthy(et:GetValue('Error')) or (truthy(et.Validate) and truthy(et:GetValue('Warning'))) then
        rtnVal = 1
    end

    -- open output file (or stdout if no output file) if not done already
    if not (outfile ~= nil or truthy(tagOut)) then
        fp, outfile, append = OpenOutputFile(orig)
        if not fp then EFile(file) countBad = countBad + 1 return end
        if outfile ~= nil and not append then tmpText = outfile end
    end

    -- print differences if requested
    if diff ~= nil then
        local done, done2, wasDiff, diffs, groupTags2 = {}, {}, nil, {}, {}
        local v = truthy(verbose) and verbose or 0
        print(fp, "======== diff < " .. file .. " > " .. file2 .. "\n")
        local g2, same = 0, 0   -- start with $g2 false, but not equal to '' to avoid infinite loop
        while true do
            local g, tag2, val2, equal
            local dupl, used = {}, {}
            local tag = shift(foundTags)
            if tag ~= nil then
                done[tag] = 1
                g = et:GetGroup(tag, showGroup)
            end
            if not truthy(g) then -- ($g could be '' if requesting non-existent tag, and this will sort last)
                while true do
                    tag2 = shift(found2)
                    if tag2 == nil then g = '' break end
                    if not done2[tag2] then g = et2:GetGroup(tag2, showGroup) break end
                end
            end
            if g ~= g2 then
                -- add any outstanding tags from diff file not yet handled in previous group ($g2)
                for _, t2 in ipairs(groupTags2) do
                    if done2[t2] then goto nextT2 end
                    do
                        local val2_ = et2:GetValue(t2)
                        if val2_ == nil then goto nextT2 end
                        local name = outFormat < 1 and et2:GetDescription(t2) or GetTagName(t2)
                        local len = LengthUTF8(name)
                        local pad = outFormat < 2 and string.rep(' ', len < 32 and 32 - len or 0) or ''
                        if truthy(allGroup) then
                            local grp = "[" .. perlStr(g2) .. "]"
                            if length(grp) < 15 and outFormat < 2 then grp = grp .. string.rep(' ', 15 - length(grp)) end
                            push(diffs, sprintf("> %s %s%s: %s\n", grp, name, pad, Printable(val2_)))
                        else
                            push(diffs, sprintf("> %s%s: %s\n", name, pad, Printable(val2_)))
                        end
                        done2[t2] = 1
                    end
                    ::nextT2::
                end
                local str = ''
                if truthy(v) and (same ~= 0 or perl.num(v) > 1) then
                    str = "  (" .. same .. " same tag" .. (same == 1 and '' or 's') .. ')'
                end
                if not truthy(allGroup) then
                    if truthy(g2) and (str ~= '' or #diffs > 0) then print(fp, "---- " .. g2 .. " ----" .. str .. "\n") end
                elseif str ~= '' and truthy(g2) then
                    printf(fp, "   %-13s%s\n", g2, str)
                end
                -- print all differences for this group
                if #diffs > 0 then print(fp, table.unpack(diffs)) wasDiff = 1 diffs = {} end
                if not truthy(g) then break end
                g2, same = g, 0
                -- build list of all tags in the new group of the diff file
                groupTags2 = {}
                if tag2 ~= nil then push(groupTags2, tag2) end
                for _, t2 in ipairs(found2) do
                    if not done2[t2] and g == et2:GetGroup(t2, showGroup) then push(groupTags2, t2) end
                end
            end
            if tag == nil then goto nextDiff end
            do
                local val = et:GetValue(tag)
                if val == nil then goto nextDiff end  -- (just in case)
                local name = GetTagName(tag)
                local desc = outFormat < 1 and et:GetDescription(tag) or name
                -- get matching tag key(s) from diff file
                local tags2 = perl.grepDyn('^' .. name .. '( |$)', groupTags2)
                for _, t2 in ipairs(tags2) do   -- T2:
                    if done2[t2] then goto nextTag2 end
                    tag2 = t2
                    val2 = et2:GetValue(t2)
                    if val2 == nil then goto nextTag2 end
                    if IsEqual(val, val2) then equal = 1 break end
                    -- look ahead for upcoming duplicate tags in this group to see
                    -- if any would later match this value (and skip those for now)
                    if et.DUPL_TAG[name] and #dupl == 0 then
                        local key = name
                        for i = 0, et.DUPL_TAG[name] do
                            if not done[key] and g == et:GetGroup(key, showGroup) then push(dupl, key) end
                            key = name .. " (" .. (i + 1) .. ")"
                        end
                        if #dupl > 1 then
                            dupl = sort(dupl, function(a, b)
                                return et.FILE_ORDER[a] < et.FILE_ORDER[b] and -1 or
                                       (et.FILE_ORDER[a] > et.FILE_ORDER[b] and 1 or 0)
                            end)
                        end
                    end
                    for _, d in ipairs(dupl) do
                        if not used[d] then
                            local dv = et:GetValue(d)
                            if dv ~= nil and IsEqual(dv, val2) then
                                used[d] = 1     -- would match this upcoming tag
                                tag2, val2 = nil, nil
                                goto nextTag2
                            end
                        end
                    end
                    break
                    ::nextTag2::
                end
                if equal then
                    same = same + 1
                else
                    local len = LengthUTF8(desc)
                    local pad = outFormat < 2 and string.rep(' ', len < 32 and 32 - len or 0) or ''
                    if truthy(allGroup) then
                        local grp = "[" .. g .. "]"
                        if length(grp) < 15 and outFormat < 2 then grp = grp .. string.rep(' ', 15 - length(grp)) end
                        push(diffs, sprintf("< %s %s%s: %s\n", grp, desc, pad, Printable(val)))
                        if val2 ~= nil then
                            if perl.num(v) < 3 then grp, desc = string.rep(' ', length(grp)), string.rep(' ', len) end
                            push(diffs, sprintf("> %s %s%s: %s\n", grp, desc, pad, Printable(val2)))
                        end
                    else
                        push(diffs, sprintf("< %s%s: %s\n", desc, pad, Printable(val)))
                        if perl.num(v) < 3 then desc = string.rep(' ', len) end
                        if val2 ~= nil then push(diffs, sprintf("> %s%s: %s\n", desc, pad, Printable(val2))) end
                    end
                end
                if tag2 ~= nil then done2[tag2] = 1 end
            end
            ::nextDiff::
        end
        if not wasDiff then print(fp, "(no metadata differences)\n") end
        if outfile ~= nil then
            created[outfile] = 1
            fp:close()
            tmpText = nil
        end
        count = count + 1
        return
    end
    -- restore state of comma flag for this file if appending
    if append and (textOverwrite & 0x02) ~= 0 then comma = outComma[outfile] end

    -- print the results for this file
    if next(printFmt) then
        -- output using print format file (-p) option
        local doc = { 0 }
        local grp, lastDoc, cache
        fileTrailer = ''
        -- repeat for each embedded document if necessary (only if -ee used)
        if truthy(et:Options('ExtractEmbedded')) then
            -- (cache tag keys if there are sub-documents)
            lastDoc = et.DOC_COUNT or 0
            if truthy(lastDoc) then cache = {} end
        else
            lastDoc = 0
        end
        while doc[1] <= lastDoc do
            local docStr = join('-', doc)   -- (upstream's $doc next to @doc)
            local skipBody, opt
            for _, type_ in ipairs({ 'HEAD', 'SECT', 'IF', 'BODY', 'ENDS', 'TAIL' }) do
                local prf = printFmt[type_]
                if not prf then goto nextType end
                if type_ == 'HEAD' and outfile ~= nil then
                    if wroteHEAD[outfile] then goto nextType end
                    wroteHEAD[outfile] = 1
                end
                if type_ == 'BODY' and skipBody then goto nextType end
                -- silence "IF" warnings and warnings for subdocuments > 1
                if type_ == 'IF' or ((doc[1] > 1 or #doc > 1) and not truthy(et.OPTIONS.IgnoreMinorErrors)) then
                    opt = 'Silent'
                else
                    opt = 'Warn'
                end
                if truthy(lastDoc) then
                    if truthy(docStr) then
                        if type_ == 'HEAD' or type_ == 'TAIL' then goto nextType end -- only repeat SECT/IF/BODY/ENDS
                        grp = "Doc" .. docStr
                    else
                        grp = 'Main'
                    end
                end
                do
                    local lines = {}
                    for _, l in ipairs(prf) do
                        local line = et:InsertTagValues(l, foundTags, opt, grp, cache)
                        if type_ == 'IF' then
                            if line == nil then skipBody = 1 end
                        elseif line ~= nil then
                            push(lines, line)
                        end
                    end
                    lineCount = lineCount + #lines
                    if type_ == 'SECT' then
                        local thisHeader = join('', lines)
                        if truthy(sectHeader) and sectHeader ~= thisHeader then
                            if truthy(sectTrailer) then print(fp, sectTrailer) end
                            sectHeader = nil
                        end
                        sectTrailer = ''
                        if not truthy(sectHeader) then
                            sectHeader = thisHeader
                            print(fp, sectHeader)
                        end
                    elseif type_ == 'ENDS' then
                        if sectHeader ~= nil then sectTrailer = sectTrailer .. join('', lines) end
                    elseif type_ == 'TAIL' then
                        fileTrailer = fileTrailer .. join('', lines)
                    elseif #lines > 0 then
                        print(fp, table.unpack(lines))
                    end
                end
                ::nextType::
            end
            -- find next available doc-subdoc
            push(doc, 1)
            while #doc > 1 do
                local nextDoc = join('-', doc)
                if et.HAS_DOC[nextDoc] then break end
                table.remove(doc)
                doc[#doc] = doc[#doc] + 1
            end
        end
        if outfile == nil then printFmt.HEAD = nil end -- print header only once per output file
        local errs = et:GetInfo('Warning', 'Error')
        if PrintErrors(et, errs, file) then EFile(file) end
    elseif plot then
        -- add points from this file to the plot
        local tagExtra = et.TAG_EXTRA
        local docNum = {}
        for _, tag in ipairs(keys(info)) do
            if tagExtra[tag] and tagExtra[tag].G3 then
                local isNum, num = isMatch(perlStr(tagExtra[tag].G3), [[(\d+)]])
                if isNum then docNum[tag] = num end
            end
        end
        plot.DocNum = docNum
        if truthy(et:Options('ExtractEmbedded')) then plot.EE = 1 end
        plot:AddPoints(info, foundTags)
    elseif not disableOutput then
        local line, noDups, csvInfo, bra, ket, sep, quote = nil, {}, {}, nil, nil, nil, nil
        if fp then
            -- print file header (only once)
            if truthy(fileHeader) then
                if not (outfile ~= nil and (created[outfile] or appended[outfile])) then print(fp, fileHeader) end
                if not truthy(textOut) then fileHeader = nil end
            end
            if truthy(html) then
                print(fp, "<table>\n")
            elseif truthy(xml) then
                local f = CleanXML(file)
                print(fp, "\n<rdf:Description rdf:about='" .. f .. "'")
                print(fp, "\n  xmlns:et='http://ns.exiftool.org/1.0/'")
                print(fp, " et:toolkit='Image::ExifTool " .. ExifTool.VERSION .. "'")
                -- define namespaces for all tag groups
                local groups_h, groups = {}, {}
                for _, tag in ipairs(foundTags) do
                    local g = et:GetGroup(tag)    -- (the group list, 0-based like Perl's)
                    local grp0, grp1 = g[0], g[1]
                    if not truthy(grp1) then
                        if forcePrint == nil then goto nextNS end
                        grp0, grp1 = 'Unknown', 'Unknown'
                    end
                    -- add groups from structure fields
                    if ref(info[tag]) ~= '' then AddGroups(info[tag], grp0, groups_h, groups) end
                    if groups_h[grp1] then goto nextNS end
                    -- include family 0 and 1 groups in URI except for internal tags
                    -- (this will put internal tags in the "XML" group on readback)
                    groups_h[grp1] = grp0
                    push(groups, grp1)
                    ::nextNS::
                end
                for _, grp1 in ipairs(groups) do
                    local grp = groups_h[grp1]
                    if not (grp == grp1 and isMatch(grp, '^(ExifTool|File|Composite|Unknown)$')) then
                        grp = grp .. "/" .. grp1
                    end
                    print(fp, "\n  xmlns:" .. grp1 .. "='http://ns.exiftool.org/" .. grp .. "/1.0/'")
                end
                if outFormat < 1 then print(fp, '>') end -- finish rdf:Description token unless short format
                ind = outFormat >= 0 and ' ' or '   '
            elseif truthy(json) then
                -- set delimiters for JSON or PHP output
                if json == 1 then bra, ket, sep = '{', '}', ':' else bra, ket, sep = 'Array(', ')', ' =>' end
                if et.OPTIONS.StructFormat and et.OPTIONS.StructFormat == 'JSONQ' then quote = 1 end
                if truthy(comma) then print(fp, ",\n") end
                print(fp, bra .. "\n  \"SourceFile\"" .. sep .. " ", EscapeJSON(MyConvertFileName(et, file), 1))
                comma = 1
                ind = (showGroup ~= nil and not truthy(allGroup)) and '    ' or '  '
            elseif truthy(csv) then
                local file2_ = MyConvertFileName(et, file)
                database[file2_] = csvInfo
                push(csvFiles, file2_)
            end
        end
        -- suppress duplicates manually in JSON and short XML output
        local noDups_ = (truthy(json) or (truthy(xml) and outFormat > 0))
        local printConv = et:Options('PrintConv')
        local lastGroup = ''
        local i = -1
        for _, tag in ipairs(foundTags) do     -- TAG:
            i = i + 1   -- keep track on index in @foundTags
            local tagName = GetTagName(tag)
            local group, valList
            -- get the value for this tag
            local val = info[tag]
            -- set flag if this is binary data
            isBinary = (ref(val) == 'SCALAR' and binaryOutput ~= nil)
            if ref(val) ~= '' then
                -- happens with -X, -j or -php when combined with -b:
                if binaryOutput ~= nil and not truthy(binaryOutput) and et.TAG_INFO[tag] and et.TAG_INFO[tag].Protected then
                    -- avoid extracting Unsafe binary tags (eg. data blocks) [insider information]
                    local lcTag = lc(tag)
                    lcTag = subst(lcTag, ' .*', '')
                    if not (et.REQ_TAG_LOOKUP[lcTag] or perl.num(et.OPTIONS.RequestAll) > 2) then goto nextTag end
                end
                val = ConvertBinary(val)    -- convert SCALAR references
                if val == nil then goto nextTag end
                if truthy(structOpt) and ref(val) ~= '' then
                    -- serialize structure if necessary
                    if not (truthy(xml) or truthy(json)) then val = require('lexiftool.XMP').SerializeStruct(et, val) end
                elseif ref(val) == 'ARRAY' then
                    if listItem ~= nil then
                        -- take only the specified item
                        val = perl.at(val, perl.num(listItem))
                    -- join arrays of simple values (with newlines for binary output)
                    elseif truthy(binaryOutput) then
                        if truthy(tagOut) then
                            valList = val
                            val = shift(valList)
                        else
                            val = join(binSep ~= nil and binSep or "\n", val)
                        end
                    elseif joinLists then
                        val = join(listSep, val)
                    end
                end
            end
            if val == nil then
                -- ignore tags that weren't found unless necessary
                if truthy(binaryOutput) then goto nextTag end
                if forcePrint ~= nil then
                    val = forcePrint    -- forced to print all tag values
                elseif not truthy(csv) then
                    goto nextTag
                end
            end
            if showGroup ~= nil then
                group = et:GetGroup(tag, showGroup)
                -- look ahead to see if this tag may suppress a priority tag in
                -- the same group, and if so suppress this tag instead
                -- (note that the tag key may look like "TAG #(1)" when the "#" feature is used)
                if noDups_ then
                    local isDup, base = isMatch(tag, [[^(.*?) ?\(]])
                    if isDup and info[base] ~= nil and group == et:GetGroup(base, showGroup) then goto nextTag end
                end
                if not truthy(group) and (truthy(xml) or truthy(json) or truthy(csv)) then
                    if not isMatch(perlStr(showGroup), [[\b4\b]]) then
                        group = 'Unknown'
                    elseif truthy(json) and not truthy(allGroup) then
                        group = 'Copy0'
                    end
                end
                if fp and not (truthy(allGroup) or truthy(csv)) then
                    if lastGroup ~= group then
                        if truthy(html) then
                            local cols = 1
                            if outFormat == 0 or outFormat == 1 then cols = cols + 1 end
                            if truthy(showTagID) then cols = cols + 1 end
                            print(fp, "<tr><td colspan=" .. cols .. " bgcolor='#dddddd'>" .. group .. "</td></tr>\n")
                        elseif truthy(json) then
                            if lastGroup ~= '' then print(fp, "\n  " .. ket) end
                            if lastGroup ~= '' or truthy(comma) then print(fp, ',') end
                            print(fp, "\n  \"" .. group .. "\"" .. sep .. " " .. bra)
                            comma = nil
                            noDups = {}     -- allow duplicate names in different groups
                        else
                            print(fp, "---- " .. group .. " ----\n")
                        end
                        lastGroup = group
                    end
                    group = nil     -- undefine so we don't print it below
                end
            elseif noDups_ then
                -- don't allow duplicates, but avoid suppressing the priority tag
                local isDup, base = isMatch(tag, [[^(.*?) ?\(]])
                if isDup and info[base] ~= nil then goto nextTag end
            end

            lineCount = lineCount + 1   -- we are printing something meaningful

            -- loop through list values when -b -W used
            while true do
                if truthy(tagOut) then
                    -- determine suggested extension for output file
                    local ext = SuggestedExtension(et, val, tagName)
                    if next(wext) and perl.num(wext[ext] or wext['*'] or -1) < 0 then
                        if truthy(verbose) and perl.num(verbose) > 1 then
                            print(vout, "Not writing " .. ext .. " output file for " .. tagName .. "\n")
                        end
                        goto nextTag
                    end
                    local groups = et:GetGroup(tag)   -- (the group list, 0-based like Perl's)
                    if outfile ~= nil then fp:close() tmpText = nil end -- (shouldn't happen)
                    local org = et:GetValue('OriginalRawFileName')
                    if not truthy(org) then org = et:GetValue('OriginalFileName') end
                    fp, outfile, append = OpenOutputFile(orig, tagName, groups, ext, org)
                    if not fp then countBad = countBad + 1 goto nextTag end
                    if not append then tmpText = outfile end
                end
                -- write binary output
                if truthy(binaryOutput) then
                    print(fp, val)
                    if binTerm ~= nil then print(fp, binTerm) end
                    if truthy(tagOut) then
                        if append then
                            if not created[outfile] then appended[outfile] = 1 end
                        else
                            created[outfile] = 1
                        end
                        fp:close()
                        tmpText = nil
                        if truthy(verbose) then print(vout, "Wrote " .. tagName .. " to " .. outfile .. "\n") end
                        outfile = nil
                        fp = nil
                        if not (valList and #valList > 0) then goto nextTag end
                        val = shift(valList)
                        goto nextValue  -- loop over values of List tag
                    end
                    goto nextTag
                end
                break
                ::nextValue::
            end
            -- save information for CSV output
            if truthy(csv) then
                local tn = tagName
                if isMatch(tag, '#') then tn = tn .. '#' end  -- add ValueConv "#" suffix if used
                local gt = truthy(group) and (group .. ":" .. tn) or tn
                -- (tag-name case may be different if some tags don't exist
                -- in a file, so all logic must use lower-case tag names)
                local lcTag = lc(gt)
                -- override existing entry only if top priority
                if csvInfo[lcTag] ~= nil and isMatch(tag, [[\(]]) then goto nextTag end
                csvInfo[lcTag] = val
                if csvTags_h[lcTag] ~= nil then
                    -- overwrite with actual extracted tag name
                    -- (note: can't check "if defined $val" here because -f may be used)
                    if info[tag] ~= nil then csvTags_h[lcTag] = gt end
                    goto nextTag
                end
                -- must check for "Unknown" group (for tags that don't exist)
                if truthy(group) and csvTags[i + 1] ~= nil then
                    local isGrp, csvGrp = isMatchDyn(csvTags[i + 1], '(?i)^(.*):' .. tn .. '$')
                    if isGrp then
                        if group == 'Unknown' then goto nextTag end   -- nothing more to do if we don't know tag group
                        if csvGrp == 'unknown' then
                            -- replace unknown entry in CSV tag lookup and list
                            csvTags_h[csvTags[i + 1]] = nil
                            csvTags_h[lcTag] = val ~= nil and gt or ''
                            csvTags[i + 1] = lcTag
                            goto nextTag
                        end
                    end
                end
                -- (don't save unextracted tag name unless -f was used)
                csvTags_h[lcTag] = val ~= nil and gt or ''
                if #csvFiles == 1 then
                    push(csvTags, lcTag) -- save order of tags for first file
                elseif #csvTags > 0 then
                    csvTags = {}
                end
                goto nextTag
            end

            do
            -- get description if we need it (use tag name if $outFormat > 0)
            local desc = outFormat > 0 and tagName or et:GetDescription(tag)

            if truthy(xml) then
                -- RDF/XML output format
                local tok = group .. ":" .. tagName
                if outFormat > 0 then
                    if truthy(structOpt) and ref(val) ~= '' then
                        val = require('lexiftool.XMP').SerializeStruct(et, val)
                    end
                    if truthy(escapeHTML) then
                        val = perl.tr(perlStr(val), "\0-\x08\x0b\x0c\x0e-\x1f", '.')
                        if not altEnc then val = select(2, require('lexiftool.XMP').FixUTF8(val)) end
                        val = require('lexiftool.HTML').EscapeHTML(val, altEnc)
                    else
                        val = CleanXML(val)
                    end
                    if not noDups[tok] then
                        -- manually un-do CR/LF conversion in Windows because output
                        -- is in text mode, which will re-convert newlines to CR/LF
                        if isCRLF then val = subst(val, [[\x0d\x0a]], "\x0a", 'g') end
                        print(fp, "\n " .. tok .. "='" .. val .. "'")
                        -- XML does not allow duplicate attributes
                        noDups[tok] = 1
                    end
                    goto nextTag
                end
                local xtra, descClose
                if truthy(showTagID) then
                    local id, lang = et:GetTagID(tag)
                    if isMatch(perlStr(id), [[^\d+$]]) then
                        if showTagID == 'H' then id = sprintf("0x%.4x", id) end
                    else
                        id = require('lexiftool.XMP').FullEscapeXML(id)
                    end
                    xtra = " et:id='" .. perlStr(id) .. "'"
                    if truthy(lang) then xtra = xtra .. " xml:lang='" .. lang .. "'" end
                else
                    xtra = ''
                end
                if truthy(tabFormat) then
                    local table_ = et:GetTableName(tag)
                    local index = et:GetTagIndex(tag)
                    xtra = xtra .. " et:table='" .. table_ .. "'"
                    if index ~= nil then xtra = xtra .. " et:index='" .. perlStr(index) .. "'" end
                end
                -- Note: New $xtra attributes must be added to %ignoreEtProp in XMP.pm!
                local lastVal = val
                for valNum = 0, 1 do
                    val = FormatXML(val, ind, group)
                    -- manually un-do CR/LF conversion in Windows because output
                    -- is in text mode, which will re-convert newlines to CR/LF
                    if isCRLF then val = subst(val, [[\x0d\x0a]], "\x0a", 'g') end
                    if outFormat >= 0 then
                        -- normal output format (note: this will give
                        -- non-standard RDF/XML if there are any attributes)
                        print(fp, "\n <" .. tok .. xtra .. val .. "</" .. tok .. ">")
                        break
                    elseif valNum == 0 then
                        desc = CleanXML(desc)
                        if xtra ~= '' then
                            print(fp, "\n <" .. tok .. ">")
                            print(fp, "\n  <rdf:Description" .. xtra .. ">")
                            descClose = "\n  </rdf:Description>"
                        else
                            print(fp, "\n <" .. tok .. " rdf:parseType='Resource'>")
                            descClose = ''
                        end
                        -- print tag Description
                        print(fp, "\n   <et:desc>" .. desc .. "</et:desc>")
                        if truthy(printConv) then
                            -- print PrintConv value
                            print(fp, "\n   <et:prt" .. val .. "</et:prt>")
                            val = et:GetValue(tag, 'ValueConv')
                            if val == nil then val = '' end
                            -- go back to print ValueConv value only if different
                            if not IsEqual(val, lastVal, 1) then goto nextValNum end
                            print(fp, descClose .. "\n </" .. tok .. ">")
                            break
                        end
                    end
                    -- print ValueConv value
                    print(fp, "\n   <et:val" .. val .. "</et:val>")
                    print(fp, descClose .. "\n </" .. tok .. ">")
                    break
                    ::nextValNum::
                end
                goto nextTag
            elseif truthy(json) then
                -- JSON or PHP output format
                local tok = truthy(allGroup) and (group .. ":" .. tagName) or tagName
                -- (removed due to backward incompatibility)
                -- $tok .= '#' if $tag =~ /#/; # add back '#' suffix if used
                if noDups[tok] then goto nextTag end
                noDups[tok] = 1
                if truthy(comma) then print(fp, ',') end
                print(fp, "\n" .. ind .. '"' .. tok .. '"' .. sep .. " ")
                if truthy(showTagID) or outFormat < 0 then
                    val = { val = val }
                    if truthy(showTagID) then
                        local id, lang = et:GetTagID(tag)
                        if showTagID == 'H' and isMatch(perlStr(id), [[^\d+$]]) then id = sprintf('0x%.4x', id) end
                        if truthy(lang) then val.lang = lang end
                        val.id = id
                    end
                    if truthy(tabFormat) then
                        val.table = et:GetTableName(tag)
                        local index = et:GetTagIndex(tag)
                        if index ~= nil then val.index = index end
                    end
                    if outFormat < 0 then
                        val.desc = desc
                        if truthy(printConv) then
                            local num = et:GetValue(tag, 'ValueConv')
                            if num ~= nil and not IsEqual(num, val.val, 1) then val.num = num end
                        end
                        local ex = et.TAG_EXTRA[tag] or {}
                        if ex.G6 ~= nil then val['fmt'] = ex.G6 end
                        if ex.BinVal ~= nil then
                            local max = (perl.num(et.OPTIONS.LimitLongValues) - 5) / 3
                            if max >= 0 and length(ex.BinVal) > perl.int(max) then
                                max = perl.int(max)
                                val['hex'] = join(' ', { perl.unpack('(H2)' .. max, ex.BinVal) }) .. ' [...]'
                            else
                                val['hex'] = join(' ', { perl.unpack('(H2)*', ex.BinVal) })
                            end
                        end
                        if ex.Rational ~= nil and truthy(et.OPTIONS.SaveBin) then val.rat = ex.Rational end
                    end
                end
                FormatJSON(fp, val, ind, quote)
                comma = 1
                goto nextTag
            end
            local id
            if truthy(showTagID) then
                id = et:GetTagID(tag)
                local isNum, n1 = isMatch(perlStr(id), [[^(\d+)(\.\d+)?$]])
                if isNum then -- only print numeric ID's
                    if showTagID == 'H' then id = sprintf("0x%.4x", n1) end
                else
                    id = '-'
                end
            end

            val = perlStr(val)
            if escapeC then
                val = subst(val, [[([\0-\x1f\\\x7f])]], function(c)
                    return escC[c] or sprintf('\\x%.2x', perl.ord(c))
                end, 'g')
            else
                -- translate unprintable chars in value and remove trailing spaces
                val = perl.tr(val, "\x01-\x1f\x7f", '.')
                val = subst(val, [[\x00]], '', 'g')
                val = subst(val, [[\s+$]], '')
            end

            if truthy(html) then
                print(fp, "<tr>")
                if group ~= nil then print(fp, "<td>" .. group .. "</td>") end
                if truthy(showTagID) then print(fp, "<td>" .. id .. "</td>") end
                if outFormat <= 1 then print(fp, "<td>" .. desc .. "</td>") end
                print(fp, "<td>" .. val .. "</td></tr>\n")
            else
                local buff = ''
                if truthy(tabFormat) then
                    if group ~= nil then buff = group .. "\t" end
                    if truthy(showTagID) then buff = buff .. id .. "\t" end
                    if outFormat <= 1 then
                        buff = buff .. desc .. "\t" .. val .. "\n"
                    elseif line ~= nil then
                        line = line .. "\t" .. val
                    else
                        line = val
                    end
                elseif outFormat < 0 then   -- long format
                    if group ~= nil then buff = "[" .. group .. "] " end
                    if truthy(showTagID) then buff = buff .. id .. " " end
                    buff = buff .. desc .. "\n      " .. val .. "\n"
                elseif outFormat == 0 or outFormat == 1 then
                    local wid
                    local len = 0
                    if group ~= nil then
                        buff = sprintf("%-15s ", "[" .. group .. "]")
                        len = 16
                    end
                    if truthy(showTagID) then
                        wid = (showTagID == 'D') and 5 or 6
                        len = len + wid + 1
                        wid = len - length(buff) - 1
                        if wid < 1 then wid = 1 end
                        buff = buff .. sprintf("%" .. wid .. "s ", id)
                    end
                    wid = 32 - (length(buff) - len)
                    -- pad description to a constant length
                    -- (get actual character length when using alternate languages
                    -- because these descriptions may contain UTF8-encoded characters)
                    local padLen = wid - LengthUTF8(desc)
                    if padLen < 0 then padLen = 0 end
                    buff = buff .. desc .. string.rep(' ', padLen) .. ": " .. val .. "\n"
                elseif outFormat == 2 then
                    if group ~= nil then buff = "[" .. group .. "] " end
                    if truthy(showTagID) then buff = buff .. id .. " " end
                    buff = buff .. tagName .. ": " .. val .. "\n"
                elseif argFormat then
                    buff = '-'
                    if group ~= nil then buff = buff .. group .. ":" end
                    if isMatch(tag, '#') then tagName = tagName .. '#' end -- add '#' suffix if used
                    buff = buff .. tagName .. "=" .. val .. "\n"
                else
                    if group ~= nil then buff = group .. " " end
                    if truthy(showTagID) then buff = buff .. id .. " " end
                    buff = buff .. val .. "\n"
                end
                print(fp, buff)
            end
            if truthy(tagOut) then
                if append then
                    if not created[outfile] then appended[outfile] = 1 end
                else
                    created[outfile] = 1
                end
                fp:close()
                tmpText = nil
                if truthy(verbose) then print(vout, "Wrote " .. tagName .. " to " .. outfile .. "\n") end
                outfile = nil
                fp = nil
            end
            end
            ::nextTag::
        end
        if fp then
            if truthy(html) then
                print(fp, "</table>\n")
            elseif truthy(xml) then
                -- close rdf:Description element
                print(fp, outFormat < 1 and "\n</rdf:Description>\n" or "/>\n")
            elseif truthy(json) then
                if lastGroup ~= '' then print(fp, "\n  " .. ket) end
                print(fp, "\n" .. ket)
                comma = 1
            elseif truthy(tabFormat) and outFormat > 1 then
                if line ~= nil then print(fp, line .. "\n") end
            end
        end
    end
    if outfile ~= nil then
        if (textOverwrite & 0x02) ~= 0 then
            -- save state of this file if we may be appending
            outComma[outfile] = comma
            outTrailer[outfile] = ''
            if truthy(sectTrailer) then
                outTrailer[outfile] = outTrailer[outfile] .. sectTrailer
                sectTrailer = ''
            end
            if truthy(fileTrailer) then outTrailer[outfile] = outTrailer[outfile] .. fileTrailer end
        else
            -- write section and file trailers before closing the file
            if truthy(sectTrailer) then
                print(fp, sectTrailer)
                sectTrailer = ''
            end
            if truthy(fileTrailer) then print(fp, fileTrailer) end
        end
        fp:close()
        tmpText = nil
        if lineCount > 0 then
            if append then
                if not created[outfile] then appended[outfile] = 1 end
            else
                created[outfile] = 1
            end
        else
            if not append then et:Unlink(outfile) end -- don't keep empty output files
        end
        comma = nil
    end
    count = count + 1
end

--------------------------------------------------------------------------------
-- Set information in file
-- Inputs: 0) ExifTool object reference, 1) source file name
--         2) original source file name ('' to create from scratch)
-- Returns: true on success
function SetImageInfo(et, file, orig)
    local outfile, restored, isTemporary, isStdout, outType, tagsFromSrc
    local hardLink, symLink, testName, sameFile
    local infile = file     -- save infile in case we change it again

    -- clean up old temporary file if necessary
    if tmpFile ~= nil then
        et:Unlink(tmpFile)
        tmpFile = nil
    end
    -- clear any existing errors or warnings since we check these on return
    et.VALUE.Error = nil
    et.VALUE.Warning = nil

    -- first, try to determine our output file name so we can return quickly
    -- if it already exists (note: this test must be delayed until after we
    -- set tags from dynamic files if writing FileName or Directory)
    if outOpt ~= nil then
        local isDash, ext = isMatch(outOpt, [[^-(\.\w+)?$]])
        if isDash then
            -- allow output file type to be specified with "-o -.EXT"
            if ext then outType = GetFileType(outOpt) end
            outfile = '-'
            isStdout = 1
        else
            outfile = FilenameSPrintf(outOpt, orig)
            if outfile == '' then
                Warn("Error: Can't create file with zero-length name from " .. orig .. "\n")
                EFile(infile)
                countBadCr = countBadCr + 1
                return 0
            end
        end
        if not isStdout and ((et:IsDirectory(outfile) and not listDir) or isMatch(outfile, '/$')) then
            if not isMatch(outfile, '/$') then outfile = outfile .. '/' end
            local name = file
            name = subst(name, [[(?s)^.*/]], '')    -- remove directory name
            outfile = outfile .. name
        else
            local srcType = GetFileType(file) or ''
            if not truthy(outType) then outType = GetFileType(outfile) end
            if truthy(outType) and (srcType ~= outType or outType == 'ICC') and file ~= '-' then
                if not truthy(CanCreate(outType)) then
                    local what = truthy(srcType) and 'other types' or 'scratch'
                    WarnOnce("Error: Can't create " .. outType .. " files from " .. what .. "\n")
                    EFile(infile)
                    countBadCr = countBadCr + 1
                    return 0
                end
                if file ~= '' then
                    -- restore previous new values unless done already
                    if not restored then et:RestoreNewValues() end -- luacheck: ignore 321
                    restored = 1
                    -- translate to this type by setting specified tags from file
                    local setTags_ = { table.unpack(tags) }
                    for _, ex in ipairs(exclude) do
                        push(setTags_, "-" .. ex)
                    end
                    -- force some tags to be copied for certain file types
                    local forceCopy = {
                        ICC = 'ICC_Profile',
                        VRD = 'CanonVRD',
                        DR4 = 'CanonDR4',
                    }
                    if forceCopy[outType] then push(setTags_, forceCopy[outType]) end
                    -- assume "-tagsFromFile @" unless -tagsFromFile already specified
                    -- (%setTags won't be empty if -tagsFromFile used)
                    if not next(setTags) or (#setTags_ > 0 and not setTags['@']) then
                        if not truthy(DoSetFromFile(et, file, setTags_)) then return 0 end
                    elseif #setTags_ > 0 then
                        -- add orphaned tags to existing "-tagsFromFile @" for this file only
                        push(setTags_, table.unpack(setTags['@']))
                        tagsFromSrc = setTags_
                    end
                    -- all done with source file -- create from meta information alone
                    file = ''
                end
            end
        end
        if not isStdout then
            outfile = NextUnusedFilename(outfile)
            if et:Exists(outfile, 1) and not doSetFileName then
                Warn("Error: '" .. outfile .. "' already exists - " .. infile .. "\n")
                EFile(infile)
                countBadWr = countBadWr + 1
                return 0
            end
        end
    elseif file == '-' then
        isStdout = 1
    end
    -- set tags from destination file if required
    if #dynamicFiles > 0 then
        -- restore previous values if necessary
        if not restored then et:RestoreNewValues() end
        local setTagsIndex = {}
        for _, dyFile in ipairs(dynamicFiles) do
            if ref(dyFile) == '' then
                local fromFile, setTags_
                if dyFile == '@' then
                    fromFile = orig
                    setTags_ = tagsFromSrc or setTags[dyFile]
                else
                    fromFile = FilenameSPrintf(dyFile, orig)
                    if fromFile == nil then EFile(infile) countBadWr = countBadWr + 1 return 0 end
                    setTags_ = setTags[dyFile]
                end
                -- do we have multiple -tagsFromFile options with this file?
                if setTagsList[dyFile] then
                    -- use the tags set in the i-th occurrence
                    local i = setTagsIndex[dyFile] or 0
                    setTagsIndex[dyFile] = i + 1
                    if setTagsList[dyFile][i + 1] then setTags_ = setTagsList[dyFile][i + 1] end
                end
                -- set new values values from file
                if not truthy(DoSetFromFile(et, fromFile, setTags_)) then return 0 end
            elseif ref(dyFile) == 'ARRAY' then
                -- a dynamic file containing a simple tag value
                local fname = FilenameSPrintf(dyFile[2], orig)
                local buff, rtn, wrn
                local opts = dyFile[3]
                local ok
                if fname ~= nil then ok, buff = SlurpFile(fname) end
                if ok then
                    if truthy(verbose) then print(vout, "Reading " .. dyFile[1] .. " from " .. fname .. "\n") end
                    local o = {}
                    for k, v in pairs(opts) do o[k] = v end
                    rtn, wrn = et:SetNewValue(dyFile[1], buff, o)
                    if truthy(wrn) then Warn(wrn .. "\n") end
                end
                -- remove this tag if we couldn't set it properly
                if not truthy(rtn) then
                    et:SetNewValue(dyFile[1], nil, { Replace = 2, ProtectSaved = opts.ProtectSaved })
                end
                goto nextDyFile
            elseif ref(dyFile) == 'SCALAR' then
                -- set new values from CSV or JSON database
                local found, csvEtPrt, csvEtVal
                evalWarning = nil
                local oldWarn = perl.SIG.__WARN__
                perl.SIG.__WARN__ = function(msg) evalWarning = msg end
                -- force UTF-8 if the database was JSON
                local old = et:Options('Charset')
                if csv == 'JSON' then et:Options('Charset', 'UTF8') end
                -- read tags for SourceFile '*' plus the specific file
                for _, f in ipairs({ '*', MyConvertFileName(et, file) }) do
                    local csvInfo = database[f]
                    if not csvInfo then
                        if f == '*' then goto nextF end
                        -- check absolute path and case-insensitive name
                        -- (punt on using ConvertFileName here, so $absPath may be a mix of encodings)
                        local absPath = AbsPath(f)
                        if absPath ~= nil and database[absPath] then
                            csvInfo = database[absPath]
                        elseif database[lc(f)] then
                            csvInfo = database[lc(f)]
                        elseif absPath ~= nil and database[lc(absPath)] then
                            csvInfo = database[lc(absPath)]
                        else
                            goto nextF
                        end
                    end
                    found = 1
                    if truthy(verbose) then
                        print(vout, "Setting new values from " .. csv .. " database\n")
                        if #tags > 0 then print(vout, 'Including tags: ', join(' ', tags), "\n") end
                        if #csvExclude > 0 then print(vout, 'Excluding tags: ', join(' ', csvExclude), "\n") end
                    end
                    if #tags > 0 then
                        -- prepare a dummy ExifTool object to hold appropriate tags from the database
                        if not csvEtPrt then csvEtPrt = ExifTool.new() end
                        for _, csvTag in ipairs(OrderedKeys(csvInfo)) do
                            if isMatch(csvTag, [[(?i)^([-_0-9A-Z]+:)*(SourceFile|Directory|FileName)$]]) then goto nextCsvTag end
                            do
                                local grps = split(':', csvTag)
                                local name = table.remove(grps)
                                while #grps < 2 do unshift(grps, 'All') end
                                if isMatch(name, '#$') then
                                    name = subst(name, '#$', '')
                                    -- handle ValueConv tags separately
                                    if not csvEtVal then csvEtVal = ExifTool.new() end
                                    csvEtVal:FoundTag(name, csvInfo[csvTag], table.unpack(grps))
                                else
                                    csvEtPrt:FoundTag(name, csvInfo[csvTag], table.unpack(grps))
                                end
                            end
                            ::nextCsvTag::
                        end
                        goto nextF
                    end
                    do
                        local exclTags = { table.unpack(csvExclude) }
                        for k, exclTag in ipairs(exclTags) do
                            local ex = exclTag
                            ex = perl.tr(ex, '-0-9a-zA-Z_:#?*', '', 'dc')   -- remove illegal characters
                            ex = subst(ex, [[(?i)(^|:)(all:)+]], '$1', 'g')  -- remove 'all' group names
                            ex = subst(ex, [[(?i)(^|:)all(#?)$]], '$1*$2')    -- convert 'all' tag name to '*'
                            ex = perl.tr(ex, '?', '.')
                            ex = subst(ex, [[\*]], '.*', 'g')                 -- convert wildcards for regex
                            exclTags[k] = ex
                        end
                        -- run through tags in database order
                        for _, csvTag in ipairs(OrderedKeys(csvInfo)) do
                            -- don't write SourceFile, Directory or FileName
                            if isMatch(csvTag, [[(?i)^([-_0-9A-Z]+:)*(SourceFile|Directory|FileName)$]]) then goto nextDbTag end
                            if #exclTags > 0 then
                                local excluded
                                for _, exclTag in ipairs(exclTags) do     -- ExclMatch:
                                    if isMatch(exclTag, ':') then
                                        if not isMatch(csvTag, ':') then goto nextExcl end   -- db entry must also specify group
                                        do
                                            local csvGrps = split(':', csvTag)
                                            local exclGrps = split(':', exclTag)
                                            local exclName = table.remove(exclGrps)
                                            if not isMatchDyn(table.remove(csvGrps), '(?i)^' .. exclName .. '$') then goto nextExcl end -- tag name must match
                                            for _, exclGrp in ipairs(exclGrps) do
                                                -- each specified group name must match db entry
                                                if #perl.grepDyn('(?i)^' .. exclGrp .. '$', csvGrps) == 0 then goto nextExcl end
                                            end
                                            excluded = 1
                                            break
                                        end
                                    end
                                    -- no group specified, so match by tag name only
                                    if isMatchDyn(csvTag, '(?i)^([-_0-9A-Z]+:)*' .. exclTag .. '$') then excluded = 1 break end
                                    ::nextExcl::
                                end
                                if excluded then goto nextDbTag end
                            end
                            do
                                local _rtn, wrn = et:SetNewValue(csvTag, csvInfo[csvTag],
                                                  { Protected = 1, AddValue = dbAdd,
                                                    ProtectSaved = dbSaveCount })
                                if truthy(wrn) and truthy(verbose) then Warn(wrn .. "\n") end
                            end
                            ::nextDbTag::
                        end
                    end
                    ::nextF::
                end
                -- set specified tags now
                if csvEtPrt then
                    local excl = {}
                    for _, ex in ipairs(csvExclude) do push(excl, "-" .. ex) end  -- add back leading dashes
                    local opts = { AddValue = dbAdd, Replace = 0 }
                    local args = { table.unpack(tags) }
                    push(args, table.unpack(excl))
                    et:SetNewValuesFromFile(csvEtPrt, opts, table.unpack(args))
                    if csvEtVal then
                        opts.Type = 'ValueConv'
                        et:SetNewValuesFromFile(csvEtVal, opts, table.unpack(args))
                    end
                end
                if csv == 'JSON' then et:Options('Charset', old) end
                perl.SIG.__WARN__ = oldWarn
                if not found then
                    Warn("No SourceFile '" .. file .. "' in imported " .. csv .. " database\n")
                    local absPath = AbsPath(file)
                    if absPath ~= nil and absPath ~= file then Warn("(full path: '" .. absPath .. "')\n") end
                    return 0
                end
            end
            ::nextDyFile::
        end
    end
    if isStdout then
        -- write to STDOUT
        outfile = io.stdout
        if not truthy(binaryStdout) then
            perl.binmode(io.stdout)
            binaryStdout = 1
        end
    else
        -- get name of hard link if we are creating one
        hardLink = et:GetNewValues('HardLink')
        symLink = et:GetNewValues('SymLink')
        testName = et:GetNewValues('TestName')
        if hardLink ~= nil then hardLink = FilenameSPrintf(hardLink, orig) end
        if symLink ~= nil then symLink = FilenameSPrintf(symLink, orig) end
        -- determine what our output file name should be
        local newFileName = et:GetNewValues('FileName')
        local newDir = et:GetNewValues('Directory')
        if newFileName ~= nil and not truthy(length(newFileName)) then
            Warning(et, "New file name is empty - " .. infile)
            newFileName = nil
        end
        if testName ~= nil then
            local err
            if newFileName ~= nil or newDir ~= nil then err = "You shouldn't write FileName or Directory with TestFile" end
            if outfile ~= nil then err = "The -o option shouldn't be used with TestFile" end
            if err then
                Warn("Error: " .. err .. " - " .. infile .. "\n")
                EFile(infile)
                countBadWr = countBadWr + 1
                return 0
            end
            testName = FilenameSPrintf(testName, orig)
            if file ~= '' then testName = ExifTool.GetNewFileName(file, testName) end
        end
        if newFileName ~= nil or newDir ~= nil or (doSetFileName and outfile ~= nil) then
            if truthy(newFileName) then
                newFileName = FilenameSPrintf(newFileName, orig)
                if outfile ~= nil then
                    if file ~= '' then outfile = ExifTool.GetNewFileName(file, outfile) end
                    outfile = ExifTool.GetNewFileName(outfile, newFileName)
                elseif file ~= '' then
                    outfile = ExifTool.GetNewFileName(file, newFileName)
                end
            end
            if truthy(newDir) then
                newDir = FilenameSPrintf(newDir, orig)
                outfile = ExifTool.GetNewFileName(outfile ~= nil and outfile or file, newDir)
            end
            outfile = NextUnusedFilename(outfile, infile)
            if et:Exists(outfile, 1) then
                if infile == outfile then
                    outfile = nil   -- not changing the file name after all
                -- (allow for case-insensitive filesystems)
                elseif et:IsSameFile(infile, outfile) then
                    sameFile = outfile  -- same file, but the name has a different case
                else
                    Warn("Error: '" .. outfile .. "' already exists - " .. infile .. "\n")
                    EFile(infile)
                    countBadWr = countBadWr + 1
                    return 0
                end
            end
        end
        if outfile ~= nil then
            if verbose ~= nil then print(vout, "'" .. infile .. "' --> '" .. outfile .. "'\n") end
            -- create output directory if necessary
            CreateDirectory(outfile)
            -- set temporary file (automatically erased on abnormal exit)
            if outOpt ~= nil then tmpFile = outfile end
        end
        if tmpFile == nil then
            -- count the number of tags and pseudo-tags we are writing
            local numSet, numPseudo = et:CountNewValues()
            if numSet ~= numPseudo and et:IsDirectory(file) then
                if verbose ~= nil then print(vout, "Can't write real tags to a directory - " .. infile .. "\n") end
                numSet = numPseudo
            end
            if et:Exists(file) then
                if not truthy(numSet) then
                    -- no need to write if no tags set
                    if verbose ~= nil then print(vout, "Nothing changed in " .. file .. "\n") end
                    EFile(infile, 1)
                    countSameWr = countSameWr + 1
                    return 1
                end
            elseif truthy(CanCreate(file)) then
                if numSet == numPseudo then
                    -- no need to write if no real tags
                    Warn("Error: Nothing to write - " .. file .. "\n")
                    EFile(infile, 1)
                    countBadWr = countBadWr + 1
                    return 0
                end
                if outfile == nil then
                    -- create file from scratch
                    outfile = file
                    file = ''
                end
            else
                -- file doesn't exist, and we can't create it
                Warn("Error: File not found - " .. file .. "\n")
                EFile(infile)
                FileNotFound(file)
                countBadWr = countBadWr + 1
                return 0
            end
            -- quickly rename file and/or set file date if this is all we are doing
            if numSet == numPseudo then
                local r0, r1, r2, r3 = 0, 0, 0, 0
                if outfile ~= nil then
                    r0 = et:SetFileName(file, outfile)
                    if r0 > 0 then file = et.NewName end    -- continue with new name if changed
                end
                if r0 >= 0 then
                    r1 = et:SetFileModifyDate(file, nil, 'FileCreateDate')
                    r2 = et:SetFileModifyDate(file)
                    r3 = et:SetSystemTags(file)
                end
                if r0 > 0 or r1 > 0 or r2 > 0 or r3 > 0 then
                    EFile(infile, 3)
                    countGoodWr = countGoodWr + 1
                elseif r0 < 0 or r1 < 0 or r2 < 0 or r3 < 0 then
                    EFile(infile)
                    countBadWr = countBadWr + 1
                    return 0
                else
                    EFile(infile, 1)
                    countSameWr = countSameWr + 1
                end
                if hardLink ~= nil or symLink ~= nil or testName ~= nil then
                    DoHardLink(et, file, hardLink, symLink, testName)
                end
                return 1
            end
            if outfile == nil or sameFile ~= nil then
                -- write to a truly temporary file
                outfile = file .. "_exiftool_tmp"
                if et:Exists(outfile) then
                    Warn("Error: Temporary file already exists: " .. outfile .. "\n")
                    EFile(infile)
                    countBadWr = countBadWr + 1
                    return 0
                end
                isTemporary = 1
            end
            -- new output file is temporary until we know it has been written properly
            tmpFile = outfile
        end
    end
    -- rewrite the file
    local success = et:WriteInfo(Infile(file), outfile, outType)

    -- create hard link if specified
    if truthy(success) and (hardLink ~= nil or symLink ~= nil or testName ~= nil) then
        local src = outfile ~= nil and outfile or file
        DoHardLink(et, src, hardLink, symLink, testName)
    end

    -- get file time if preserving it
    local aTime, mTime, cTime, doPreserve
    if file ~= '' then doPreserve = preserveTime end
    if truthy(doPreserve) and truthy(success) then
        aTime, mTime, cTime = et:GetFileTime(file)
        -- don't override date/time values written by the user
        local written = et.WRITTEN or {}
        if written.FileCreateDate then cTime = nil end
        if written.FileModifyDate or doPreserve == 2 then
            if cTime ~= nil then
                aTime = nil     -- only preserve FileCreateDate
                mTime = nil
            else
                doPreserve = nil    -- (nothing to preserve)
            end
        end
    end

    if success == 1 then
        -- preserve the original file times
        if tmpFile ~= nil then
            if et:Exists(file) then
                if truthy(doPreserve) then et:SetFileTime(tmpFile, aTime, mTime, cTime) end
                if isTemporary then
                    -- preserve original file attributes if possible
                    et:CopyFileAttrs(file, outfile)
                    -- move original out of the way
                    local original = file .. "_original"
                    if not truthy(overwriteOrig) and not et:Exists(original) then
                        -- rename the file and check again to be sure the file doesn't exist
                        -- (in case, say, the filesystem truncated the file extension)
                        if not et:Rename(file, original) or et:Exists(file) then
                            Error("Error renaming " .. file .. "\n")
                            return 0
                        end
                    end
                    local dstFile = sameFile ~= nil and sameFile or file
                    if overwriteOrig > 1 then
                        -- copy temporary file over top of original to preserve attributes
                        local err, buff
                        local newFile = tmpFile
                        local NEW_FILE = et:Open(newFile)
                        if not NEW_FILE then Error("Error opening " .. newFile .. "\n") return 0 end
                        perl.binmode(NEW_FILE)

                        --..........................................................
                        -- temporarily disable CTRL-C during this critical operation
                        critical = 1
                        tmpFile = nil       -- handle deletion of temporary file ourself
                        local ORIG_FILE = et:Open(file, '+<')
                        if ORIG_FILE then
                            perl.binmode(ORIG_FILE)
                            while true do
                                buff = NEW_FILE:read(65536)
                                if not buff then break end
                                if not ORIG_FILE:write(buff) then err = 1 end
                            end
                            NEW_FILE:close()
                            -- Handle files being shorter than the original
                            -- (Lua has no truncate: rewrite the file if it shrank)
                            local pos = ORIG_FILE:seek('cur')
                            if pos and pos < ORIG_FILE:seek('end') then
                                ORIG_FILE:seek('set', 0)
                                local data = ORIG_FILE:read(pos)
                                ORIG_FILE:close()
                                ORIG_FILE = et:Open(file, '>')
                                if not (ORIG_FILE and ORIG_FILE:write(data or '')) then err = 1 end
                            end
                            if not (ORIG_FILE and ORIG_FILE:close()) then err = 1 end
                            if err then
                                Warn("Couldn't overwrite in place - " .. file .. "\n")
                                if not (et:Rename(newFile, file) or
                                    (et:Unlink(file) and et:Rename(newFile, file)))
                                then
                                    Error("Error renaming " .. newFile .. " to " .. file .. "\n")
                                    critical = nil
                                    if interrupted then SigInt() end
                                    return 0
                                end
                            else
                                et:SetFileModifyDate(file, cTime, 'FileCreateDate', 1)
                                et:SetFileModifyDate(file, mTime, 'FileModifyDate', 1)
                                et:Unlink(newFile)
                                if truthy(doPreserve) then
                                    et:SetFileTime(file, aTime, mTime, cTime)
                                    -- save time to set it later again to patch OS X 10.6 bug
                                    preserveTime_h[file] = { aTime, mTime, cTime }
                                end
                            end
                            EFile(infile, 3)
                            countGoodWr = countGoodWr + 1
                        else
                            NEW_FILE:close()
                            Warn("Error opening " .. file .. " for writing\n")
                            EFile(infile)
                            et:Unlink(newFile)
                            countBadWr = countBadWr + 1
                        end
                        critical = nil              -- end critical section
                        if interrupted then SigInt() end -- issue delayed SIGINT if necessary
                        --..........................................................

                    -- simply rename temporary file to replace original
                    -- (if we didn't already rename it to add "_original")
                    elseif et:Rename(tmpFile, dstFile) then
                        EFile(infile, 3)
                        countGoodWr = countGoodWr + 1
                    else
                        local newFile = tmpFile
                        tmpFile = nil   -- (avoid deleting file if we get interrupted)
                        -- unlink may fail if already renamed or no permission
                        if not truthy(et:Unlink(file)) then
                            Warn("Error renaming temporary file to " .. dstFile .. "\n")
                            EFile(infile)
                            et:Unlink(newFile)
                            countBadWr = countBadWr + 1
                        -- try renaming again now that the target has been deleted
                        elseif not et:Rename(newFile, dstFile) then
                            Warn("Error renaming temporary file to " .. dstFile .. "\n")
                            EFile(infile)
                            -- (don't delete tmp file now because it is all we have left)
                            countBadWr = countBadWr + 1
                        else
                            EFile(infile, 3)
                            countGoodWr = countGoodWr + 1
                        end
                    end
                elseif truthy(overwriteOrig) then
                    -- erase original file
                    EFile(infile, 3)
                    if not truthy(et:Unlink(file)) then Warn("Error erasing original " .. file .. "\n") end
                    countGoodWr = countGoodWr + 1
                else
                    EFile(infile, 4)
                    countGoodCr = countGoodCr + 1
                end
            else
                -- this file was created from scratch, not edited
                EFile(infile, 4)
                countGoodCr = countGoodCr + 1
            end
        else
            EFile(infile, 3)
            countGoodWr = countGoodWr + 1
        end
    elseif truthy(success) then
        EFile(infile, 1)
        if isTemporary then
            -- just erase the temporary file since no changes were made
            et:Unlink(tmpFile)
            countSameWr = countSameWr + 1
        else
            if truthy(doPreserve) then et:SetFileTime(outfile, aTime, mTime, cTime) end
            if truthy(overwriteOrig) then
                if not truthy(et:Unlink(file)) then Warn("Error erasing original " .. file .. "\n") end
            end
            countCopyWr = countCopyWr + 1
        end
        if verbose ~= nil then print(vout, "Nothing changed in " .. file .. "\n") end
    else
        EFile(infile)
        if tmpFile ~= nil then et:Unlink(tmpFile) end
        countBadWr = countBadWr + 1
    end
    tmpFile = nil
    return success
end

--------------------------------------------------------------------------------
-- Make hard link and handle TestName if specified
-- Inputs: 0) ExifTool ref, 1) source file name, 2) HardLink name,
--         3) SymLink name, 4) TestFile name
function DoHardLink(et, src, hardLink, symLink, testName)
    if hardLink ~= nil then
        hardLink = NextUnusedFilename(hardLink)
        if et:SetFileName(src, hardLink, 'Link') > 0 then
            countLink.Hard = (countLink.Hard or 0) + 1
        else
            countLink.BadHard = (countLink.BadHard or 0) + 1
        end
    end
    if symLink ~= nil then
        symLink = NextUnusedFilename(symLink)
        if et:SetFileName(src, symLink, 'SymLink') > 0 then
            countLink.Sym = (countLink.Sym or 0) + 1
        else
            countLink.BadSym = (countLink.BadSym or 0) + 1
        end
    end
    if testName ~= nil then
        testName = NextUnusedFilename(testName, src)
        if truthy(usedFileName[testName]) then
            et:Warn("File '" .. testName .. "' would exist")
        elseif et:SetFileName(src, testName, 'Test', usedFileName[testName]) == 1 then
            usedFileName[testName] = 1
            usedFileName[src] = 0
        end
    end
end

--------------------------------------------------------------------------------
-- Clean string for XML (also removes invalid control chars and malformed UTF-8)
-- Inputs: 0) string ref
-- Returns: nothing, but input string is escaped
-- (Lua: takes the string and returns the escaped one)
function CleanXML(strPt)
    strPt = perlStr(strPt)
    -- translate control characters that are invalid in XML
    strPt = perl.tr(strPt, "\0-\x08\x0b\x0c\x0e-\x1f", '.')
    -- fix malformed UTF-8 characters
    if not altEnc then strPt = select(2, require('lexiftool.XMP').FixUTF8(strPt)) end
    -- escape necessary characters for XML
    strPt = require('lexiftool.XMP').EscapeXML(strPt)
    return strPt
end

--------------------------------------------------------------------------------
-- Encode string for XML
-- Inputs: 0) string ref
-- Returns: encoding used (and input string is translated)
-- (Lua: takes the string and returns the encoding and the translated string)
function EncodeXML(strPt)
    strPt = perlStr(strPt)
    if isMatch(strPt, "[\0-\x08\x0b\x0c\x0e-\x1f]") or
        (not altEnc and ExifTool.IsUTF8(strPt) < 0)
    then
        -- encode binary data and non-UTF8 with special characters as base64
        strPt = require('lexiftool.XMP').EncodeBase64(strPt)
        -- #ATV = Alexander Vonk, private communication
        return 'http://www.w3.org/2001/XMLSchema#base64Binary', strPt --ATV
    elseif truthy(escapeHTML) then
        strPt = require('lexiftool.HTML').EscapeHTML(strPt, altEnc)
    else
        strPt = require('lexiftool.XMP').EscapeXML(strPt)
    end
    return '', strPt    -- not encoded
end

--------------------------------------------------------------------------------
-- Format value for XML output
-- Inputs: 0) value, 1) indentation, 2) group
-- Returns: formatted value
function FormatXML(val, ind, grp)
    local gt = '>'
    if ref(val) == 'ARRAY' then
        -- convert ARRAY into an rdf:Bag
        local val2 = "\n" .. ind .. " <rdf:Bag>"
        for _, item in ipairs(val) do
            val2 = val2 .. "\n" .. ind .. "  <rdf:li" .. FormatXML(item, ind .. "  ", grp) .. "</rdf:li>"
        end
        val = val2 .. "\n" .. ind .. " </rdf:Bag>\n" .. ind
    elseif ref(val) == 'HASH' then
        gt = " rdf:parseType='Resource'>"
        local val2 = ''
        for _, key in ipairs(OrderedKeys(val)) do
            -- (some variable-namespace XML structure fields may have a different group)
            local ns, tg = grp, key
            local isNs, n1, n2 = isMatch(key, '^(.*?):(.*)')
            if isNs then
                if grp == 'JSON' then
                    tg = perl.tr(tg, ':', '_')  -- colons in JSON structure elements are not namespaces
                else
                    ns, tg = n1, n2
                end
            end
            -- validate XML attribute name
            -- make sure name is valid for XML
            ns = perl.tr(ns, '-_A-Za-z0-9.', '', 'dc')
            if not isMatch(ns, '^[_A-Za-z]') then ns = '_' .. ns end
            tg = perl.tr(tg, '-_A-Za-z0-9.', '', 'dc')
            if not isMatch(tg, '^[_A-Za-z]') then tg = '_' .. tg end
            local tok = ns .. ':' .. tg
            val2 = val2 .. "\n" .. ind .. " <" .. tok .. FormatXML(val[key], ind .. " ", grp) .. "</" .. tok .. ">"
        end
        val = val2 .. "\n" .. ind
    else
        -- (note: SCALAR reference should have already been converted)
        local enc
        enc, val = EncodeXML(val)
        if enc ~= '' then gt = " rdf:datatype='" .. enc .. "'>\n" end --ATV
    end
    return gt .. val
end

--------------------------------------------------------------------------------
-- Escape string for JSON or PHP
-- Inputs: 0) string, 1) flag to force numbers to be quoted too
-- Returns: Escaped string (quoted if necessary)
function EscapeJSON(str, quote)
    str = perlStr(str)
    if not truthy(quote) then
        -- JSON boolean (true or false)
        if isMatch(str, [[(?i)^(true|false)$]]) and json < 2 then return lc(str) end
        -- JSON/PHP number (see json.org for numerical format)
        -- return $str if $str =~ /^-?(\d|[1-9]\d+)(\.\d+)?(e[-+]?\d+)?$/i;
        -- (these big numbers caused problems for some JSON parsers, so be more conservative)
        if isMatch(str, [[(?i)^-?(\d|[1-9]\d{1,14})(\.\d{1,16})?(e[-+]?\d{1,3})?$]]) then return str end
    end
    -- encode JSON string in base64 if necessary
    if json < 2 and binaryOutput ~= nil and ExifTool.IsUTF8(str) < 0 then
        return '"base64:' .. require('lexiftool.XMP').EncodeBase64(str, 1) .. '"'
    end
    -- escape special characters
    str = subst(str, [[(?s)(["\t\n\r\\])]], function(c) return "\\" .. jsonChar[c] end, 'g')
    if json < 2 then -- JSON
        str = perl.tr(str, "\0", '', 'd')   -- remove all nulls
        -- escape other control characters with \u
        str = subst(str, [[(?s)([\0-\x1f\x7f])]], function(c) return sprintf("\\u%.4X", perl.ord(c)) end, 'g')
        -- JSON strings must be valid UTF8
        if not altEnc then str = select(2, require('lexiftool.XMP').FixUTF8(str)) end
    else -- PHP
        if not isBinary then str = subst(str, [[\0+$]], '') end  -- remove trailing nulls unless binary
        -- must escape "$" too for PHP
        str = subst(str, [[(?s)\$]], [[\\\$]], 'g')
        -- escape other control characters with \x
        str = subst(str, [[(?s)([\0-\x1f\x7f])]], function(c) return sprintf("\\x%.2X", perl.ord(c)) end, 'g')
    end
    return '"' .. str .. '"'    -- return the quoted string
end

--------------------------------------------------------------------------------
-- Print JSON or PHP value
-- Inputs: 0) file reference, 1) value, 2) indentation, 3) true to quote numbers
function FormatJSON(fp, val, ind, quote)
    local comma_
    if ref(val) == '' then
        print(fp, EscapeJSON(val, quote))
    elseif ref(val) == 'ARRAY' then
        if joinLists and ref(val[1]) == '' then
            print(fp, EscapeJSON(join(listSep, val), quote))
        else
            local bra, ket
            if json == 1 then bra, ket = '[', ']' else bra, ket = 'Array(', ')' end
            print(fp, bra)
            for _, item in ipairs(val) do
                if comma_ then print(fp, ',') end
                FormatJSON(fp, item, ind, quote)
                comma_ = 1
            end
            print(fp, ket)
        end
    elseif ref(val) == 'HASH' then
        local bra, ket, sep
        if json == 1 then bra, ket, sep = '{', '}', ':' else bra, ket, sep = 'Array(', ')', ' =>' end
        print(fp, bra)
        for _, k in ipairs(OrderedKeys(val)) do
            if comma_ then print(fp, ',') end
            local key = EscapeJSON(k, 1)
            print(fp, "\n" .. ind .. "  " .. key .. sep .. " ")
            -- hack to force decimal id's to be printed as strings with -H
            if truthy(showTagID) and k == 'id' and showTagID == 'H' and isMatch(perlStr(val[k]), [[^\d+\.\d+$]]) then
                print(fp, '"' .. perlStr(val[k]) .. '"')
            else
                FormatJSON(fp, val[k], ind .. "  ", quote)
            end
            comma_ = 1
        end
        print(fp, "\n" .. ind .. ket)
    else
        -- (note: SCALAR reference should have already been converted)
        print(fp, '"<err>"')
    end
end

--------------------------------------------------------------------------------
-- Format value for CSV file
-- Inputs: value
-- Returns: value quoted if necessary
function FormatCSV(val)
    val = perlStr(val)
    -- check for valid encoding if the Charset option was used
    if truthy(setCharset) and (isMatch(val, "[^\x09\x0a\x0d\x20-\x7e\x80-\xff]") or
        (setCharset == 'UTF8' and ExifTool.IsUTF8(val) < 0))
    then
        val = 'base64:' .. require('lexiftool.XMP').EncodeBase64(val, 1)
    end
    -- currently, there is a chance that the value may contain NULL characters unless
    -- the -b option is used to encode as Base64.  It is unclear whether or not this
    -- is valid CSV, but some readers may not like it.  (If this becomes a problem,
    -- in the future values may need to be truncated at the first NULL character.)
    local hasQuote = isMatch(val, '"')
    if hasQuote then val = subst(val, '"', '""', 'g') end
    if hasQuote or isMatch(val, [[(^\s+|\s+$)]]) or isMatchDyn(val, [[[\n\r]|\Q]] .. csvDelim .. [[\E]]) then
        val = '"' .. val .. '"'
    end
    return val
end

--------------------------------------------------------------------------------
-- Print accumulated CSV information
-- Inputs: 0) file ref
function PrintCSV(fp)
    fp = fp or io.stdout
    local tags_ = {}

    if #csvTags == 0 then csvTags = sort(keys(csvTags_h)) end
    -- make a list of tags actually found
    for _, lcTag in ipairs(csvTags) do
        if truthy(csvTags_h[lcTag]) then push(tags_, FormatCSV(csvTags_h[lcTag])) end
    end
    print(fp, join(csvDelim, { 'SourceFile', table.unpack(tags_) }), "\n")
    local empty = forcePrint ~= nil and forcePrint or ''
    for _, file in ipairs(csvFiles) do
        local vals = { FormatCSV(file) }   -- start with full file name
        local csvInfo = database[file]
        for _, lcTag in ipairs(csvTags) do
            if not truthy(csvTags_h[lcTag]) then goto nextCsvTag end
            do
                local val = csvInfo[lcTag]
                if val == nil then push(vals, empty) goto nextCsvTag end
                push(vals, FormatCSV(val))
            end
            ::nextCsvTag::
        end
        print(fp, join(csvDelim, vals), "\n")
    end
end

--------------------------------------------------------------------------------
-- Add tag groups from structure fields to a list for xmlns
-- Inputs: 0) tag value, 1) parent group, 2) group hash ref, 3) group list ref
function AddGroups(val, grp, groupHash, groupList)
    if ref(val) == 'HASH' then
        for _, key in ipairs(sort(keys(val))) do
            local isNs, ns = isMatch(key, '^(.*?):')
            if isNs and not groupHash[ns] and grp ~= 'JSON' then
                groupHash[ns] = grp
                push(groupList, ns)
            end
            if ref(val[key]) ~= '' then AddGroups(val[key], grp, groupHash, groupList) end
        end
    elseif ref(val) == 'ARRAY' then
        for _, val2 in ipairs(val) do
            if ref(val2) ~= '' then AddGroups(val2, grp, groupHash, groupList) end
        end
    end
end

--------------------------------------------------------------------------------
-- Convert binary data (SCALAR references) for printing
-- Inputs: 0) object reference
-- Returns: converted object, or undef if we don't want binary objects
function ConvertBinary(obj)
    if ref(obj) == 'HASH' then
        for _, key in ipairs(keys(obj)) do
            if ref(obj[key]) == '' or key == '_ordered_keys_' then goto nextKey end
            obj[key] = ConvertBinary(obj[key])
            if obj[key] == nil then return nil end
            ::nextKey::
        end
    elseif ref(obj) == 'ARRAY' then
        for i, val in ipairs(obj) do
            if ref(val) ~= '' then
                obj[i] = ConvertBinary(val)
                if obj[i] == nil then return nil end
            end
        end
    elseif ref(obj) == 'SCALAR' then
        if noBinary then return nil end
        -- (binaryOutput flag is set to 0 for binary mode of XML/PHP/JSON output formats)
        if binaryOutput ~= nil then
            obj = perlStr(obj.value)
            -- encode in base64 if necessary (0xf7 allows for up to 21-bit UTF-8 code space)
            if json == 1 and (isMatch(obj, "[^\x09\x0a\x0d\x20-\x7e\x80-\xf7]") or
                              ExifTool.IsUTF8(obj) < 0)
            then
                obj = 'base64:' .. require('lexiftool.XMP').EncodeBase64(obj, 1)
            end
        else
            -- (-b is not valid for HTML output)
            local bOpt = truthy(html) and '' or ', use -b option to extract'
            if isMatch(perlStr(obj.value), [[^Binary data \d+ bytes$]]) then
                obj = "(" .. obj.value .. bOpt .. ")"
            else
                obj = '(Binary data ' .. length(perlStr(obj.value)) .. " bytes" .. bOpt .. ")"
            end
        end
    end
    return obj
end

--------------------------------------------------------------------------------
-- Compare ValueConv and PrintConv values of a tag to see if they are equal
-- Inputs: 0) value1, 1) value2, 2) flag to return true for any scalar references
-- Returns: true if they are equal
function IsEqual(a, b, trueScalar)
    -- (scalar values are not print-converted)
    if ref(a) == '' and ref(b) == '' and perlStr(a) == perlStr(b) then return 1 end
    if ref(a) == 'SCALAR' then
        if truthy(trueScalar) then return 1 end
        if ref(b) == 'SCALAR' and perlStr(a.value) == perlStr(b.value) then return 1 end
        return nil
    end
    if ref(a) == 'HASH' and ref(b) == 'HASH' then
        if #keys(a) ~= #keys(b) then return nil end
        for _, key in ipairs(keys(a)) do
            if not IsEqual(a[key], b[key], trueScalar) then return nil end
        end
    else
        if ref(a) ~= 'ARRAY' or ref(b) ~= 'ARRAY' or #a ~= #b then return nil end
        for i = 1, #a do
            if not IsEqual(a[i], b[i], trueScalar) then return nil end
        end
    end
    return 1
end

--------------------------------------------------------------------------------
-- Get the printable rendition of a value
-- Inputs: 0) value (may be a reference)
-- Returns: de-referenced value
function Printable(val)
    if ref(val) ~= '' then
        if truthy(structOpt) then
            val = require('lexiftool.XMP').SerializeStruct(mt, val)
        elseif ref(val) == 'ARRAY' then
            val = join(listSep, val)
        elseif ref(val) == 'SCALAR' then
            val = '(Binary data ' .. length(perlStr(val.value)) .. ' bytes)'
        end
    end
    val = perlStr(val)
    if escapeC then
        val = subst(val, [[([\0-\x1f\\\x7f])]], function(c)
            return escC[c] or sprintf('\\x%.2x', perl.ord(c))
        end, 'g')
    else
        -- translate unprintable chars in value and remove trailing spaces
        val = perl.tr(val, "\x01-\x1f\x7f", '.')
        val = subst(val, [[\x00]], '', 'g')
        val = subst(val, [[\s+$]], '')
    end
    return val
end

--------------------------------------------------------------------------------
-- Get character length of a UTF-8 string
-- Inputs: 0) string
-- Returns: number of characters (not bytes) in the UTF-8 string
function LengthUTF8(str)
    if not fixLen then return length(str) end
    -- (Encode::decode_utf8, and pack('U0C*') when that hangs: a Perl
    --  character string is the UTF-8 string itself here; Lua's utf8 library
    --  counts its characters, an invalid sequence counts by bytes)
    str = perlStr(str)
    local len
    if fixLen == 1 then
        len = utf8.len(str) or length(str)
    else
        local _, GCString = perl.evalRequire('Unicode::GCString')
        local ok, gcstr = pcall(GCString.new, str)
        if ok and gcstr then
            len = gcstr:columns()
        else
            len = utf8.len(str) or length(str)
            Warning(mt, 'Unicode::GCString problem.  Columns may be misaligned')
            fixLen = 1
        end
    end
    return len
end

--------------------------------------------------------------------------------
-- Add tag list for copying tags from specified file
-- Inputs: 0) set tags file name (or FMT), 1) options for SetNewValuesFromFile()
-- Returns: nothing
-- Notes: Uses global variables: %setTags, %setTagsList, @newValues, $saveCount
function AddSetTagsFile(setFile, opts)
    if setTags[setFile] then
        -- move these tags aside and make a new list for the next invocation of this file
        if not setTagsList[setFile] then setTagsList[setFile] = {} end
        push(setTagsList[setFile], setTags[setFile])
    end
    setTags[setFile] = {}   -- create list for tags to copy from this file
    -- insert marker to save new values now (necessary even if this is not a dynamic
    -- file in case the same file is source'd multiple times in a single command)
    saveCount = saveCount + 1
    push(newValues, { SaveCount = saveCount }, "TagsFromFile=" .. setFile)
    -- add option to protect the tags which are assigned after this
    -- (this is the mechanism by which the command-line order-of-operations is preserved)
    if not opts then opts = {} end
    opts.ProtectSaved = saveCount
    push(setTags[setFile], opts)
end

--------------------------------------------------------------------------------
-- Get input file name or reference for calls to the ExifTool API
-- Inputs: 0) file name ('-' for STDIN), 1) flag to buffer STDIN
-- Returns: file name, or RAF reference for buffering STDIN
function Infile(file, bufferStdin)
    if file == '-' and (truthy(bufferStdin) or rafStdin) then
        if rafStdin then
            rafStdin:Seek(0)    -- rewind
        else
            local RandomAccess = require('lexiftool.RandomAccess')
            rafStdin = RandomAccess.new(io.stdin)
            rafStdin:BinMode()
        end
        if rafStdin then return rafStdin end
    end
    return file
end

--------------------------------------------------------------------------------
-- Issue warning to stderr, adding leading "Warning: " and trailing newline
-- if the warning isn't suppressed by the API NoWarning option
-- Inputs: 0) ExifTool ref, 1) warning string
function Warning(et, str)
    local noWarn = et:Options('NoWarning')
    if noWarn == nil or not (pcall(isMatchDyn, str, noWarn) and isMatchDyn(str, noWarn)) then
        Warn("Warning: " .. str .. "\n")
    end
end

--------------------------------------------------------------------------------
-- Set new values from file
-- Inputs: 0) ExifTool ref, 1) filename, 2) reference to list of values to set
-- Returns: 0 on error (and increments $countBadWr)
function DoSetFromFile(et, file, setTags_)
    if truthy(verbose) then print(vout, "Setting new values from " .. file .. "\n") end
    local info = et:SetNewValuesFromFile(Infile(file, 1), table.unpack(setTags_ or {}))
    local numSet = #keys(info)
    if info.Error then
        -- delete all error and warning tags
        local warns = perl.grep([[^(Error|Warning)\b]], keys(info))
        numSet = numSet - #warns
        -- issue a warning only for the main error
        local err = info.Error
        for _, w in ipairs(warns) do info[w] = nil end
        local noWarn = et:Options('NoWarning')
        if not (noWarn ~= nil and pcall(isMatchDyn, err, noWarn) and isMatchDyn(err, noWarn)) then info.Warning = err end
    elseif info.Warning then
        local warns = 1
        while info["Warning (" .. warns .. ")"] do warns = warns + 1 end
        numSet = numSet - warns
    end
    if PrintErrors(et, info, file) then EFile(file) countBadWr = countBadWr + 1 return 0 end
    if numSet == 0 then Warning(et, "No writable tags set from " .. file) end
    return 1
end

--------------------------------------------------------------------------------
-- Translate backslashes to forward slashes in filename if necessary
-- Inputs: 0) Filename
-- Returns: nothing, but changes filename if necessary
-- (Lua: returns the changed file name)
function CleanFilename(file)
    if file ~= nil and ExifTool.IsPC() then file = perl.tr(file, '\\', '/') end
    return file
end

--------------------------------------------------------------------------------
-- Does path name contain wildcards
-- Inputs: 0) path name
-- Returns: true if path contains wildcards
function HasWildcards(path)

    -- if this is a Windows path with the long path prefix, then wildcards are not supported
    if perl.osname() == 'MSWin32' and isMatch(path, [=[^[\\/]{2}\?[\\/]]=]) then return 0 end
    return isMatch(path, '[*?]')
end

--------------------------------------------------------------------------------
-- Check for valid UTF-8 of a file name
-- Inputs: 0) string, 1) original encoding
-- Returns: 0=plain ASCII, 1=valid UTF-8, -1=invalid UTF-8 (and print warning)
function CheckUTF8(file, enc)
    local isUTF8 = 0
    if isMatch(file, "[\x80-\xff]") then
        isUTF8 = ExifTool.IsUTF8(file)
        if isUTF8 < 0 then
            if truthy(enc) then
                Warn("Invalid filename encoding for " .. file .. "\n")
            elseif enc == nil then
                WarnOnce('FileName encoding not specified.  Use "-charset FileName=CHARSET"\n')
            end
        end
    end
    return isUTF8
end

--------------------------------------------------------------------------------
-- Set window title
-- Inputs: title string or '' to reset title
function SetWindowTitle(title)
    if curTitle ~= title then
        curTitle = title
        if perl.osname() == 'MSWin32' then
            -- allow only safe characters
            title = perl.tr(title, "-_a-zA-Z0-9 ()[]{}%.+/:;,=?*!@#$~'", '', 'dc')
            perl.system('title ' .. title)
        else
            -- (this only works for XTerm terminals, and STDERR must go to the console)
            printf(io.stderr, "\27]0;%s\7", title)
        end
    end
end

--------------------------------------------------------------------------------
-- Process files in our @files list
-- Inputs: 0) ExifTool ref, 1) list ref to just return full file names
function ProcessFiles(et, list)
    local enc = et:Options('CharsetFileName')
    for _, file in ipairs(files) do
        if utf8FileName[file] then et:Options('CharsetFileName', 'UTF8') end
        if progressMax ~= nil then
            if progressNext == nil then
                progressNext = progressCount + progressIncr
                progressNext = progressNext - progressNext % progressIncr -- (show even multiples)
                if progressNext > progressMax then progressNext = progressMax end
            end
            progressCount = progressCount + 1
            if truthy(progress) then
                if progressCount >= progressNext then
                    progStr = " [" .. progressCount .. "/" .. progressMax .. "]"
                else
                    progStr = nil   -- don't update progress yet
                end
            end
        end
        if et:IsDirectory(file) and not listDir then
            multiFile, validFile = 1, 1
            ScanDir(et, file, list)
        elseif truthy(filterFlag) and not truthy(AcceptFile(file)) then
            if et:Exists(file) then
                filtered = 1
                if truthy(verbose) then Progress(vout, "-------- " .. file .. " (wrong extension)") end
            else
                Error("Error: File not found - " .. file .. "\n")
                FileNotFound(file)
            end
        else
            validFile = 1
            if list then
                push(list, file)
            else
                if next(endDir_h) then
                    local d = ExifTool.SplitFileName(file)
                    if endDir_h[d] then goto nextFile end
                end
                GetImageInfo(et, file)
                if truthy(purge) then ExifTool.Purge(purge) end
                if end_ then Warn("End called - " .. file .. "\n") end
                if endDir then
                    Warn("EndDir called - " .. file .. "\n")
                    local d = ExifTool.SplitFileName(file)
                    endDir_h[d] = 1
                    endDir = nil
                end
            end
        end
        if utf8FileName[file] then et:Options('CharsetFileName', enc) end
        if end_ then break end
        ::nextFile::
    end
end

--------------------------------------------------------------------------------
-- Scan directory for image files
-- Inputs: 0) ExifTool ref, 1) directory name, 2) list ref to return file names
function ScanDir(et, dir, list)
    local fileList, done, utf8Name, endThisDir
    local winSurrogate
    local enc = et:Options('CharsetFileName')
    -- recode as UTF-8 if necessary
    if truthy(enc) then
        if enc ~= 'UTF8' then
            dir = et:Decode(dir, enc, nil, 'UTF8')
            et:Options('CharsetFileName', 'UTF8')   -- now using UTF8
        end
        utf8Name = 1
    end
    if ignore[dir] then return end
    -- use Win32::FindFile on Windows if available
    -- (ReadDir will croak if there is a wildcard, so check for this)
    if perl.osname() == 'MSWin32' and not HasWildcards(dir) then
        if CheckUTF8(dir, enc) >= 0 then
            -- (Win32::FindFile::ReadDir is lexiftool.sys's wide
            --  FindFirstFileW/FindNextFileW, so Unicode names need no module;
            --  its error text stands in for the module's warning/croak)
            fileList, evalWarning = sysLib.read_dir(dir)
            if evalWarning then
                Warning(et, "[Win32::FindFile] " .. evalWarning .. " - " .. dir)
                if isMatch(evalWarning, 'surrogate') then winSurrogate = 1 end
            else
                et:Options('CharsetFileName', 'UTF8')   -- now using UTF8
                utf8Name = 1    -- ReadDir returns UTF-8 file names
                done = 1
            end
        end
    end
    if not truthy(done) then
        -- use standard perl library routines to read directory
        fileList = perl.readdir(dir)
        if not fileList then
            Warn("Error opening directory " .. dir .. "\n")
            return
        end
        if done ~= nil then
            -- issue warning if some names would have required Win32::FindFile
            for _, file in ipairs({ dir, table.unpack(fileList) }) do
                if isMatch(file, "[\\?\x80-\xff]") then
                    WarnOnce("Install Win32::FindFile to support Windows Unicode file names in directories\n")
                    break
                end
            end
        end
    end
    if not isMatch(dir, '/$') then dir = dir .. '/' end  -- make sure directory name ends with '/'
    for _, file in ipairs(fileList) do
        if file == '.' or file == '..' then goto nextFile end
        do
            local path = dir .. file
            if et:IsDirectory(path) then
                if not truthy(recurse) then goto nextFile end
                -- ignore directories starting with "." by default
                if isMatch(file, [[^\.]]) and recurse == 1 then goto nextFile end
                -- note: this doesn't work in Windows cmd (see forum17243)
                if ignore[file] or (ignore.SYMLINKS and perl.filetest('l', path)) then goto nextFile end
                ScanDir(et, path, list)
                if end_ then break end
                goto nextFile
            end
            if endThisDir then goto nextFile end
            if ignoreHidden and isMatch(file, [[^\.]]) then goto nextFile end  -- ignore hidden files if specified
            -- apply rules from -ext options
            local accepted
            if truthy(filterFlag) then
                accepted = AcceptFile(file)
                if not truthy(accepted) then goto nextFile end
                -- must be specifically accepted to bypass selection logic
                accepted = accepted & 0x01
            end
            if not truthy(accepted) then
                -- read/write this file if it is a supported type
                if truthy(scanWritable) then
                    if perlStr(scanWritable) == '1' then
                        if not truthy(CanWrite(file)) then goto nextFile end
                    else
                        local type_ = GetFileType(file)
                        if not (type_ ~= nil and type_ == scanWritable) then goto nextFile end
                    end
                elseif not truthy(GetFileType(file)) then
                    if not doUnzip then goto nextFile end
                    if not isMatch(file, [[(?i)\.(gz|bz2)$]]) then goto nextFile end
                end
            end
            -- Windows patch to avoid replacing filename containing Unicode surrogate with 8.3 name
            if winSurrogate and truthy(isWriting) and
                (not truthy(overwriteOrig) or overwriteOrig ~= 2) and
                not doSetFileName and isMatch(file, '~')   -- (8.3 name will contain a tilde)
            then
                Warn("Not writing " .. path .. "\n")
                WarnOnce("Use -overwrite_original_in_place to write files with Unicode surrogate characters\n")
                EFile(file)
                countBad = countBad + 1
                goto nextFile
            end
            if utf8Name then utf8FileName[path] = 1 end
            if list then
                push(list, path)
            else
                GetImageInfo(et, path)
                if truthy(purge) then ExifTool.Purge(purge) end
                if end_ then
                    Warn("End called - " .. file .. "\n")
                    break
                end
                if endDir then
                    path = subst(path, '/$', '')
                    Warn("EndDir called - " .. path .. "\n")
                    endDir_h[path] = 1
                    endThisDir = 1
                    endDir = nil
                end
            end
        end
        ::nextFile::
    end
    countDir = countDir + 1
    et:Options('CharsetFileName', enc)  -- restore original setting
end

--------------------------------------------------------------------------------
-- Find files with wildcard expression on Windows
-- Inputs: 0) ExifTool ref, 1) file name with wildcards
-- Returns: list of matching file names
-- Notes:
-- 1) Win32::FindFile must already be loaded
-- 2) Sets flag in %utf8FileName for each file found
-- (Lua: Win32::FindFile::FindFile is perl.bsd_glob with its matchDot flag
--  (FindFile, unlike File::Glob, matches names beginning with '.'); it
--  returns the paths, so cFileName is their last component)
function FindFileWindows(et, wildfile) -- luacheck: ignore 131

    -- recode file name as UTF-8 if necessary
    local enc = et:Options('CharsetFileName')
    if truthy(enc) and enc ~= 'UTF8' then wildfile = et:Decode(wildfile, enc, nil, 'UTF8') end
    wildfile = CleanFilename(wildfile) -- use forward slashes
    local dir, wildname = matches(wildfile, '(.*[:/])(.*)')
    if dir == nil then dir, wildname = '', wildfile end
    if HasWildcards(dir) then
        Warn("Wildcards don't work in the directory specification\n")
        return {}
    end
    if CheckUTF8(wildfile, enc) < 0 then return {} end
    local files = {}
    local names = perl.bsd_glob(wildfile, 1)
    if #names == 0 then return files end
    -- (apparently this isn't always sorted, so do a case-insensitive sort here)
    names = sort(names, function(a, b)
        return perl.cmp(uc(a), uc(b))
    end)
    local rname
    -- replace "\?" with ".", and "\*" with ".*" for regular expression
    rname = subst(perl.quotemeta(wildname), [[\\\?]], '.', 'g')
    rname = subst(rname, [[\\\*]], '.*', 'g')
    for _, nm in ipairs(names) do
        nm = matches(nm, '([^/]*)$')    -- (port: $nm->cFileName)
        -- make sure that FindFile behaves
        -- (otherwise "*.jpg" matches things like "a.jpg_original"!)
        if not isMatchDyn(nm, '(?i)^' .. rname .. '$') then goto nextName end
        if nm == '.' or nm == '..' then goto nextName end  -- don't match "." and ".."
        do
            local file = dir .. nm      -- add back directory name
            push(files, file)
            utf8FileName[file] = 1  -- flag this file name as UTF-8 encoded
        end
        ::nextName::
    end
    return files
end

--------------------------------------------------------------------------------
-- Handle missing file on the command line
-- Inputs: 0) file name
function FileNotFound(file)
    if isMatch(file, '^(DIR|FILE)$') then
        local type_ = ({ DIR = 'directory', FILE = 'file' })[file]
        Warn('You were meant to enter any valid ' .. type_ .. ' name, not "' .. file .. '" literally.\n')
    end
end

--------------------------------------------------------------------------------
-- Patch for OS X 10.6 to preserve file modify date
-- (this probably isn't a 100% fix, but it may solve a majority of the cases)
function PreserveTime()
    for _, file in ipairs(keys(preserveTime_h)) do
        mt:SetFileTime(file, table.unpack(preserveTime_h[file], 1, 3))
    end
    preserveTime_h = {}
end

--------------------------------------------------------------------------------
-- Return absolute path for a file
-- Inputs: 0) file name
-- Returns: absolute path string, or undef if path could not be determined
-- Note: Warnings should be suppressed when calling this routine
function AbsPath(file)
    local path
    if file ~= nil then
        if file == '*' then return nil end  -- (CSV SourceFile may be '*' -- no absolute path for that)
        if perl.osname() == 'MSWin32' and truthy(mt:Options('WindowsLongPath')) then
            path = mt:WindowsLongPath(file)
        else
            path = perl.abs_path(file)
        end
        if path ~= nil then path = CleanFilename(path) end  -- use forward slashes
    end
    return path
end

--------------------------------------------------------------------------------
-- Convert file name to ExifTool Charset
-- Inputs: 0) ExifTool ref, 1) file name in CharsetFileName
-- Returns: file name in ExifTool Charset
function MyConvertFileName(et, file)
    local enc = et:Options('CharsetFileName')
    if utf8FileName[file] then et:Options('CharsetFileName', 'UTF8') end
    local convFile = et:ConvertFileName(file)
    if utf8FileName[file] then et:Options('CharsetFileName', enc) end
    return convFile
end

--------------------------------------------------------------------------------
-- Add print format entry
-- Inputs: 0) expression string
function AddPrintFormat(expr)
    local type_
    if isMatch(expr, '^#') then
        local isType, t = isMatch(expr, [=[^#\[(HEAD|SECT|IF|BODY|ENDS|TAIL)\]]=])
        if not isType then return end   -- ignore comments
        expr = subst(expr, [=[^#\[(HEAD|SECT|IF|BODY|ENDS|TAIL)\]]=], '')
        type_ = t
    else
        type_ = 'BODY'
    end
    if not printFmt[type_] then printFmt[type_] = {} end
    push(printFmt[type_], expr)
    -- add to list of requested tags
    push(requestTags, table.unpack(perl.findAll(expr, [[(?i)\$\{?((?:[-_0-9A-Z]+:)*[-_0-9A-Z?*]+)]])))
    if isMatch(expr, [[\bSetTags\b]]) then printFmt.SetTags = 1 end
end

--------------------------------------------------------------------------------
-- Get suggested file extension based on tag value for binary output
-- Inputs: 0) ExifTool ref, 1) data ref, 2) tag name
-- Returns: file extension (lower case), or 'dat' if unknown
-- (Lua: the data itself instead of a reference to it)
function SuggestedExtension(et, valPt, tag)
    local ext
    valPt = perlStr(valPt)
    if not truthy(binaryOutput) then
        ext = 'txt'
    elseif isMatch(valPt, [[^\xff\xd8\xff]]) then
        ext = 'jpg'
    elseif isMatch(valPt, [[^(\0\0\0\x0cjP(  |\x1a\x1a)\x0d\x0a\x87\x0a|\xff\x4f\xff\x51\0)]]) then
        ext = 'jp2'
    elseif isMatch(valPt, [[^(\x89P|\x8aM|\x8bJ)NG\r\n\x1a\n]]) then
        ext = 'png'
    elseif isMatch(valPt, '^GIF8[79]a') then
        ext = 'gif'
    elseif isMatch(valPt, [[^<\?xpacket]]) or tag == 'XMP' then
        ext = 'xmp'
    elseif isMatch(valPt, [[^<\?xml]]) or tag == 'XML' then
        ext = 'xml'
    elseif isMatch(valPt, '(?s)^RIFF....WAVE') then
        ext = 'wav'
    elseif tag == 'OriginalRawImage' and et:GetValue('OriginalRawFileName') ~= nil then
        ext = perlStr(et:GetValue('OriginalRawFileName'))
        ext = subst(ext, [[(?s)^.*\.]], '')
        ext = truthy(ext) and lc(ext) or 'raw'
    elseif tag == 'EXIF' then
        ext = 'exif'
    elseif tag == 'ICC_Profile' then
        ext = 'icc'
    elseif isMatch(valPt, [[^(MM\0\x2a|II\x2a\0)]]) then
        ext = 'tiff'
    elseif isMatch(valPt, '(?s)^.{4}ftyp(3gp|mp4|f4v|qt  )') then
        local movType = { ['qt  '] = 'mov' }
        local _m, t = isMatch(valPt, '(?s)^.{4}ftyp(3gp|mp4|f4v|qt  )')
        ext = movType[t] or t
    elseif isMatch(valPt, [[(?i)^<(!DOCTYPE )?html]]) then
        ext = 'html'
    elseif isMatch(valPt, [[^[\n\r]*\{[\n\r]*\\rtf]]) then
        ext = 'rtf'
    elseif not isMatch(valPt, [[(?s)^.{0,4096}\0]]) then
        ext = 'txt'
    elseif isMatch(valPt, '(?s)^BM.{15}\0') then
        ext = 'bmp'
    elseif isMatch(valPt, [[^CANON OPTIONAL DATA\0]]) then
        ext = 'vrd'
    elseif isMatch(valPt, [[^IIII\x04\0\x04\0]]) then
        ext = 'dr4'
    elseif isMatch(valPt, [[(?s)^(.{10}|.{522})(\x11\x01|\x00\x11)]]) then
        ext = 'pict'
    elseif isMatch(valPt, [[(?s)^\xff\x0a|\0\0\0\x0cJXL \x0d\x0a......ftypjxl]]) then
        ext = 'jxl'
    elseif isMatch(valPt, [[(?s)^.{4}jumb\0.{3}jumdc2pa]]) then
        ext = 'c2pa'
    elseif tag == 'JUMBF' then
        ext = 'jumbf'
    else
        ext = 'dat'
    end
    return ext
end

--------------------------------------------------------------------------------
-- Load print format file
-- Inputs: 0) file name, 1) flag to avoid adding newline to input argument
-- - saves lines of file to %printFmt list
-- - adds tag names to @tags list
function LoadPrintFormat(arg, noNL)
    local FMT_FILE
    if arg == nil then
        Error("Must specify file or expression for -p option\n")
    elseif not isMatch(arg, "\n") and perl.filetest('f', arg) and (function()
            FMT_FILE = mt:Open(arg)
            return FMT_FILE
        end)() then
        for fmtLine in FMT_FILE:lines('L') do
            local line = fmtLine
            -- (port: Perl's text-mode read, see Port notes)
            if truthy(isCRLF) then line = line:gsub('\r\n$', '\n') end
            AddPrintFormat(line)
        end
        FMT_FILE:close()
    else
        if not truthy(noNL) then arg = arg .. "\n" end
        AddPrintFormat(arg)
    end
end

--------------------------------------------------------------------------------
-- A sort of sprintf for filenames
-- Inputs: 0) format string (%d=dir, %f=file name, %e=ext),
--         1) source filename or undef to test format string
--         2-4) [%t %g %s %o only] tag name, ref to array of group names,
--              suggested extension, original raw file name
-- Returns: new filename or undef on error (or if no file and fmt contains token)
function FilenameSPrintf(fmt, file, ...)
    local extra = { ... }
    -- return format string straight away if no tokens
    if not isMatch(fmt, '%[-+]?\\d*[.:]?\\d*[lu]?[dDfFeEtgso]') then return fmt end
    if file == nil then return nil end
    file = CleanFilename(file)  -- make sure we are using forward slashes
    -- split filename into directory, file, extension
    local part = {}
    part.d, part.f, part.E = matches(file, [[^(.*?)([^/]*?)(\.[^./]*)?$]])
    if part.f == nil then Warn("Error: Bad pattern match for file " .. file .. "\n") return nil end
    if truthy(part.E) then
        part.e = substr(part.E, 1)
    else
        part.e, part.E = '', ''
    end
    part.F = part.f .. part.E
    part.D = subst(part.d, '/+$', '')
    part.t, part.g, part.s, part.o = extra[1], extra[2], extra[3], extra[4]
    if truthy(part.o) then part.o = subst(part.o, [=[(?s)^.*[/\\]]=], '') end -- remove directory if it exists
    local filename, pos = '', 0
    local groups
    -- (Perl's `while ($fmt =~ /.../g)` with pos(): matches from the last end)
    while true do
        local whole, sign, wid, dot, skip, mod, code, en = matches(fmt,
            [[(%([-+]?)(\d*)([.:]?)(\d*)([lu]?)([dDfFeEtgso]))]], pos)
        if not whole then break end
        filename = filename .. substr(fmt, pos, en - pos - length(whole))
        pos = en
        skip = truthy(skip) and perl.num(skip) or 0
        local path = {}
        local part_, len
        if lc(code) == 'd' and truthy(dot) and dot == ':' then
            -- field width applies to directory levels instead of characters
            path = split('/', part[code])
            len = #path
        else
            if code == 'g' then
                if groups == nil then groups = part.g or {} end
                local gnum, gen = matches(fmt, [[\G(\d?)]], pos)    -- look for %g1, %g2, etc
                part.g = groups[truthy(gnum) and perl.num(gnum) or 0]  -- (0-based, see GetGroup)
                pos = gen
            end
            if part[code] == nil then part[code] = '' end
            len = length(part[code])
        end
        if skip >= len then goto nextToken end
        if wid == '' or perl.num(wid) + skip > len then wid = len - skip else wid = perl.num(wid) end
        if sign == '-' then skip = len - wid - skip end
        if #path > 0 then
            part_ = join('/', { table.unpack(path, skip + 1, skip + wid) })
            if code ~= 'D' then part_ = part_ .. '/' end
        else
            part_ = substr(part[code], skip, wid)
        end
        if truthy(mod) then part_ = (mod == 'u') and uc(part_) or lc(part_) end
        filename = filename .. part_
        ::nextToken::
    end
    filename = filename .. substr(fmt, pos)  -- add rest of file name
    -- remove double slashes (except at beginning to allow Windows UNC paths)
    filename = subst(filename, '(?!^)//', '/', 'g')
    return filename
end

--------------------------------------------------------------------------------
-- Convert number to alphabetical index: a, b, c, ... z, aa, ab ...
-- Inputs: 0) number
-- Returns: alphabetical index string
function Num2Alpha(num)
    local alpha = perl.chr(97 + (num % 26))
    while num >= 26 do
        num = perl.int(num / 26) - 1
        alpha = perl.chr(97 + (num % 26)) .. alpha
    end
    return alpha
end

--------------------------------------------------------------------------------
-- Expand '%c' and '%C' codes if filename to get next unused file name
-- Inputs: 0) file name format string, 1) filename ok to use even if it exists
-- Returns: new file name
function NextUnusedFilename(fmt, okfile)
    if not isMatch(fmt, '%[-+]?\\d*[.:]?\\d*[lun]?[cC]') then return fmt end
    local sep = { ['-'] = '-', ['+'] = '_' }
    local copy, alpha = 0, 'a'
    local lastFile
    while true do
        local filename, pos = '', 0
        while true do
            local whole, sign, wid, dec, wid2, mod, tok, en = matches(fmt,
                [[(%([-+]?)(\d*)([.:]?)(\d*)([lun]?)([cC]))]], pos)
            if not whole then break end
            filename = filename .. substr(fmt, pos, en - pos - length(whole))
            pos = en
            wid = truthy(wid) and perl.num(wid) or 0
            wid2 = truthy(wid2) and perl.num(wid2) or 0
            local seq
            if tok == 'C' then
                -- increment sequence number for %C on collision if ':' is used
                if copy ~= 0 and dec == ':' then
                    if sign == '-' then seqFileDir = seqFileDir + 1 else seqFileNum = seqFileNum + 1 end
                end
                seq = wid + (sign == '-' and seqFileDir or seqFileNum) - 1
                wid = wid2
            else
                if not (truthy(dec) or copy ~= 0) then goto nextToken end
                if wid < wid2 then wid = wid2 end
                -- add dash or underline separator if '-' or '+' specified
                if truthy(sign) then filename = filename .. sep[sign] end
            end
            if truthy(mod) and mod ~= 'n' then
                local a = tok == 'C' and Num2Alpha(seq) or alpha
                local str = (truthy(wid) and wid > length(a)) and string.rep('a', wid - length(a)) or ''
                str = str .. a
                if mod == 'u' then str = uc(str) end
                filename = filename .. str
            else
                local c = tok == 'C' and seq or copy
                local num = c + (truthy(mod) and 1 or 0)
                filename = filename .. (truthy(wid) and sprintf("%." .. wid .. "d", num) or perlStr(num))
            end
            ::nextToken::
        end
        filename = filename .. substr(fmt, pos) -- add rest of file name
        -- return now with filename unless file exists
        if not ((mt:Exists(filename, 1) and usedFileName[filename] == nil) or truthy(usedFileName[filename])) then
            return filename
        end
        if okfile ~= nil then
            if filename == okfile then return filename end
            local fn, ok = AbsPath(filename), AbsPath(okfile)
            if fn ~= nil and ok ~= nil and fn == ok then return okfile end
        end
        if lastFile ~= nil and lastFile == filename then return filename end
        lastFile = filename
        copy = copy + 1
        alpha = perl.increment(alpha)   -- (Perl's magic string increment)
    end
end

--------------------------------------------------------------------------------
-- Create directory for specified file
-- Inputs: 0) complete file name including path
-- Returns: true if a directory was created
function CreateDirectory(file)
    local err = mt:CreateDirectory(file)
    if err ~= nil then
        if truthy(err) then Error(err .. "\n") return 0 end
        if truthy(verbose) then
            local dir = subst(file, '/[^/]*$', '')
            print(vout, "Created directory " .. dir .. "\n")
        end
        countNewDir = countNewDir + 1
        return 1
    end
    return 0
end

--------------------------------------------------------------------------------
-- Open output text file
-- Inputs: 0) file name format string, 1-N) extra arguments for FilenameSPrintf
-- Returns: 0) file reference (or undef on error), 1) file name if opened, 2) append flag
-- Notes: returns reference to STDOUT and no file name if no textOut file needed
function OpenOutputFile(file, ...)
    local fp, outfile, append
    if truthy(textOut) then
        outfile = file
        outfile = CleanFilename(outfile)
        if isMatch(textOut, '%[-+]?\\d*[.:]?\\d*[lun]?[dDfFeEtgsocC]') or tagOut ~= nil then
            -- make filename from printf-like $textOut
            outfile = FilenameSPrintf(textOut, file, ...)
            if outfile == nil then return end
            outfile = NextUnusedFilename(outfile)
            CreateDirectory(outfile)    -- create directory if necessary
        else
            outfile = subst(outfile, [[\.[^./]*$]], '')  -- remove extension if it exists
            outfile = outfile .. textOut
        end
        local mode = '>'
        if mt:Exists(outfile, 1) then
            if not truthy(textOverwrite) then
                Warn("Output file " .. outfile .. " already exists for " .. file .. "\n")
                return
            end
            if textOverwrite == 2 or (textOverwrite == 3 and created[outfile]) then
                mode = '>>'
                append = 1
            end
        end
        local OUTFILE = mt:Open(outfile, mode)
        if not OUTFILE then
            local what = mode == '>' and 'creating' or 'appending to'
            Error("Error " .. what .. " " .. outfile .. "\n")
            return
        end
        perl.binmode(OUTFILE, ':crlf')      -- (port: Perl's text-mode open, see Port notes)
        if truthy(binaryOutput) then perl.binmode(OUTFILE) end
        fp = OUTFILE
    else
        fp = io.stdout
    end
    return fp, outfile, append
end

--------------------------------------------------------------------------------
-- Filter files based on extension
-- Inputs: 0) file name
-- Returns: 0 = rejected, 1 = specifically accepted, 2 = accepted by default
-- Notes: This routine should only be called if $filterFlag is set
function AcceptFile(file)
    local isExt, e = isMatch(file, [[(?s)^.*\.(.+)$]])
    local ext = isExt and uc(e) or ''
    if filterExt[ext] ~= nil then return filterExt[ext] end
    if filterExt['*'] ~= nil then return filterExt['*'] end
    if (filterFlag & 0x02) ~= 0 then return 0 end   -- reject if accepting specific extensions
    return 2    -- accept by default
end

--------------------------------------------------------------------------------
-- Slurp file into buffer
-- Inputs: 0) file name, 1) buffer reference
-- Returns: 1 on success
-- (Lua: returns 1 and the file data on success)
function SlurpFile(file)
    local INFILE = mt:Open(file)
    if not INFILE then Warn("Error opening file " .. file .. "\n") return 0 end
    perl.binmode(INFILE)
    -- (CAREFUL!:  must clear buffer first to reset possible utf8 flag because the data
    --  would be corrupted if it was read into a buffer which had the utf8 flag set!)
    local buff = INFILE:read('a')
    if buff == nil then
        INFILE:close()
        Warn("Error reading " .. file .. "\n")
        return 0
    end
    if INFILE ~= io.stdin then INFILE:close() end
    return 1, buff
end


--------------------------------------------------------------------------------
-- Filter argfile line
-- Inputs: 0) line of argfile
-- Returns: filtered line or undef to ignore
function FilterArgfileLine(arg)
    if isMatch(arg, '^#') then          -- comment lines begin with '#'
        if not isMatch(arg, [=[^#\[CSTR\]]=]) then return nil end
        arg = subst(arg, [=[^#\[CSTR\]]=], '')
        arg = subst(arg, [[(?s)[\x0d\x0a]+$]], '')   -- remove trailing newline
        -- escape double quotes, dollar signs and ampersands if they aren't already
        -- escaped by an odd number of backslashes, and escape a single backslash
        -- if it occurs at the end of the string
        -- (`s{\\(.)|(["\$\@]|\\$)}{'\\'.($2 || $1)}sge`, with both
        --  alternatives in the one capture: an escaped character stays as it
        --  is, anything else gets its backslash)
        arg = subst(arg, [[(?s)(\\.|["\$\@]|\\$)]], function(c)
            if #c == 2 then return c end
            return '\\' .. c
        end, 'g')
        -- un-escape characters in C string
        local esc = { a = "\a", b = "\b", f = "\f", n = "\n",
                      r = "\r", t = "\t", ['"'] = '"', ['\\'] = '\\' }
        arg = subst(arg, [[(?s)\\(.)]], function(c) return esc[c] or ('\\' .. c) end, 'g')
    else
        arg = subst(arg, [[^\s+]], '')              -- remove leading white space
        arg = subst(arg, [[(?s)[\x0d\x0a]+$]], '')   -- remove trailing newline
        -- remove white space before, and single space after '=', '+=', '-=' or '<='
        arg = subst(arg, [[(?i)^(-[-_0-9A-Z:]+#?)\s*([-+<]?=) ?]], '$1$2')
        if arg == '' then return nil end
    end
    return arg
end

--------------------------------------------------------------------------------
-- Read arguments from -stay_open argfile
-- Inputs: 0) argument list ref
-- Notes: blocks until -execute, -stay_open or -@ option is available
--        (or until there was an error reading from the file)
function ReadStayOpen(args)
    -- (port: in a session of an embedding host the host hands in the next
    --  command's arguments itself, verbatim, ending with -execute -- see
    --  `session` at the end of this file)
    if launchInfo.readArgs then
        unshift(args, table.unpack(launchInfo.readArgs(rtnValPrev)))
        return
    end
    local newArgs = {}
    local processArgs, result, optArgs_
    local lastOpt = ''
    local unparsed = length(stayOpenBuff)
    while true do
        if truthy(unparsed) then
            -- parse data already read from argfile
            result = unparsed
            unparsed = nil
        else
            -- read more data from argfile
            -- - this read may block (which is good) if reading from a pipe
            stayOpenBuff, result = perl.sysread(STAYOPEN, stayOpenBuff, 65536, length(stayOpenBuff))
        end
        if truthy(result) then
            local pos = 0
            -- (Perl's `while ($stayOpenBuff =~ /\n/g)` with pos())
            while true do
                local nl = perl.index(stayOpenBuff, "\n", pos)
                if nl < 0 then break end
                local len = nl + 1 - pos
                local arg = substr(stayOpenBuff, pos, len)
                pos = pos + len
                arg = FilterArgfileLine(arg)
                if arg == nil then goto nextLine end
                push(newArgs, arg)
                if optArgs_ then
                    -- this is an argument for the last option
                    optArgs_ = nil
                    if not (lastOpt == '-stay_open' or lastOpt == '-@') then goto nextLine end
                else
                    lastOpt = lc(arg)
                    optArgs_ = optArgs[arg]
                    if optArgs_ == nil then
                        optArgs_ = optArgs[lastOpt]
                        -- handle options with trailing numbers
                        if optArgs_ == nil then
                            local isNum, base, bang = isMatch(lastOpt, [[^(.*?)\d+(!?)$]])
                            if isNum then optArgs_ = optArgs[base .. "#" .. bang] end
                        end
                    end
                    -- (0 is false in Perl: an optional argument is not skipped)
                    if not truthy(optArgs_) then optArgs_ = nil end
                    if not isMatch(lastOpt, [[^-execute\d*$]]) then goto nextLine end
                end
                processArgs = 1
                break   -- process arguments up to this point
                ::nextLine::
            end
            if pos == 0 then goto continue end  -- nothing to do if we didn't read any arguments
            -- keep unprocessed data in buffer
            stayOpenBuff = substr(stayOpenBuff, pos)
            if processArgs then
                -- process new arguments after -execute or -stay_open option
                unshift(args, table.unpack(newArgs))
                break
            end
        elseif result == 0 then
            -- sysread() didn't block (eg. when reading from a file),
            -- so wait for a short time (1/100 sec) then try again
            -- Note: may break out of this early if SIGCONT is received
            perl.select(nil, nil, nil, 0.01)
        else
            Warn("Error reading from ARGFILE\n")
            if STAYOPEN ~= io.stdin then STAYOPEN:close() end
            stayOpen = 0
            break
        end
        ::continue::
    end
end

--------------------------------------------------------------------------------
-- Add new entry to -efile output file
-- Inputs: 0) file name, 1) -efile option number (0=error, 1=same, 2=failed, 3=updated, 4=created)
function EFile(entry, num)
    local efile_ = efile[(num or 0) + 1]
    if efile_ ~= nil and truthy(length(entry)) and entry ~= '-' then
        local err
        CreateDirectory(efile_)
        local EFILE_FILE = mt:Open(efile_, '>>')
        if EFILE_FILE then
            perl.binmode(EFILE_FILE, ':crlf')   -- (port: Perl's text-mode open, see Port notes)
            if not truthy(print(EFILE_FILE, entry, "\n")) then Warn("Error writing to " .. efile_ .. "\n") err = 1 end
            EFILE_FILE:close()
        else
            Warn("Error opening '" .. efile_ .. "' for append\n")
            err = 1
        end
        if err then
            for k = 1, 5 do
                if efile[k] ~= nil and efile[k] == efile_ then efile[k] = nil end
            end
        end
    end
end

--------------------------------------------------------------------------------
-- Print progress message if it is time for it
-- Inputs: 0) file ref, 1) message
function Progress(file, msg)
    if progStr ~= nil then
        print(file, msg, progStr, "\n")
        if progressMax ~= nil then progressNext = nil end
    end
end

--------------------------------------------------------------------------------
-- Print list of tags
-- Inputs: 0) message, 1-N) list of tag names
function PrintTagList(msg, ...)
    local list = { ... }
    if not truthy(quiet) then print(io.stdout, msg, ":\n") end
    if (outFormat < 0 or truthy(verbose)) and isMatch(msg, 'file extensions$') and #list > 0 then
        for _, tag in ipairs(list) do
            printf(io.stdout, "  %-11s %s\n", tag, GetFileType(tag, 1))
        end
        return
    end
    local len, pad = 0, truthy(quiet) and '' or '  '
    for _, tag in ipairs(list) do
        local taglen = length(tag)
        if len + taglen > 77 then
            print(io.stdout, "\n")
            len, pad = 0, truthy(quiet) and '' or '  '
        end
        print(io.stdout, pad, tag)
        len = len + taglen + 1
        pad = ' '
    end
    if #list == 0 then print(io.stdout, pad, '[empty list]') end
    print(io.stdout, "\n")
end

--------------------------------------------------------------------------------
-- Print warnings and errors from info hash
-- Inputs: 0) ExifTool object ref, 1) info hash, 2) file name
-- Returns: true if there was an Error
function PrintErrors(et, info, file)
    for _, tag in ipairs({ 'Warning', 'Error' }) do
        if not truthy(info[tag]) then goto nextTag end
        do
            local keys_ = { tag }
            if truthy(et:Options('Duplicates')) then
                push(keys_, table.unpack(sort(perl.grepDyn('^' .. tag .. ' ', keys(info)))))
            end
            for _, key in ipairs(keys_) do
                Warn(tag .. ": " .. perlStr(info[key]) .. " - " .. file .. "\n")
            end
        end
        ::nextTag::
    end
    return info.Error
end

--------------------------------------------------------------------------------
-- (port: the script as a library, for an embedding host such as the C API --
--  no counterpart upstream; doc/capi.md)
--
-- A session is the script itself, started as
--     lexiftool [-config FILE] -stay_open True -@ - [-common_args ARGS...]
-- and run in a coroutine, so that its own -stay_open command loop does all
-- the work: -common_args, the per-command reset of the file-scope
-- variables, -echo3/-echo4, ${status} and the state that outlives a
-- command (rtnValPrev, the loaded config, ...) behave as for a -stay_open
-- client.  Three port branches in the script make that possible, all keyed
-- on launchInfo.readArgs: ReadStayOpen takes the next command's arguments
-- from readArgs (here: a yield to `execute`) instead of reading the
-- ARGFILE, the loop prints no "{ready}", and Exit() returns instead of
-- ending the process.  The output of a command goes into two Lua tables
-- through perl.redirect while the coroutine runs, never to the process's
-- STDOUT/STDERR.
-- The script's file scope is one per Lua state, so is a session.  The host
-- sets up `arg` (arg[0]: the program name, for -ver -v and the config file
-- lookup) and, before this module is loaded, lexiftool.sys.nosignals(true)
-- -- the script installs its $SIG{INT}/$SIG{CONT} handlers when it is
-- loaded, and a library must not take over the process's signals.
local current       -- the session of this Lua state, if one was opened

-- resume the session's coroutine, its output going into the session's
-- buffers
local function resume(s, ...)
    perl.redirect(io.stdout, s.out)
    perl.redirect(io.stderr, s.err)
    local ok, what = coroutine.resume(s.co, ...)
    perl.redirect(io.stdout, nil)
    perl.redirect(io.stderr, nil)
    if not ok then
        s.state, s.message = 'failed', debug.traceback(s.co, tostring(what))
    elseif coroutine.status(s.co) == 'dead' then
        s.state = 'ended'       -- (the loop has ended: -stay_open False)
    end
end

-- Inputs: 0) options table or nil: config = list of -config files,
--         commonArgs = list of arguments for -common_args, launch = the
--         launcher's information for main (bytecode)
-- Returns: the session, after the script's start (output of the start, such
--          as a config file warning, stays for the first command's result);
--          check session.state ('ok', or 'failed' with session.message)
local function session(opts)
    opts = opts or { }
    if current then error('lexiftool.main: one session per Lua state', 2) end
    local args = { }
    for _, file in ipairs(opts.config or { }) do push(args, '-config', file) end
    push(args, '-stay_open', 'True', '-@', '-')
    if opts.commonArgs and #opts.commonArgs > 0 then
        push(args, '-common_args', table.unpack(opts.commonArgs))
    end
    local launch = { }
    for k, v in pairs(opts.launch or { }) do launch[k] = v end
    launch.readArgs = coroutine.yield
    local s = { co = coroutine.create(main), out = { }, err = { }, state = 'ok' }
    current = s
    resume(s, args, launch)         -- main(args, launch), up to the first command
    return s
end

-- One command, with the arguments a -stay_open client writes before
-- "-execute" (argv, a list; passed verbatim) -- or, with argv nil, the end
-- of the session as a client's "-stay_open False".
-- Returns: 0) the command's STDOUT bytes, 1) its STDERR bytes, 2) its exit
--          status as ${status} (0 ok, 1 error, 2 all files failed -if),
--          3) the session's state afterwards: 'ok', 'ended' (the command
--          contained -stay_open False) or 'failed' (a Lua error; 4) is the
--          message with traceback)
local function execute(s, argv)
    if s.state == 'ok' then
        local args = { '-stay_open', 'False' }
        if argv ~= nil then
            args = { }
            for i = 1, #argv do args[i] = argv[i] end
            push(args, '-execute')
        end
        resume(s, args)
    end
    local out, err = table.concat(s.out), table.concat(s.err)
    s.out, s.err = { }, { }
    return out, err, math.tointeger(tonumber(rtnValPrev)) or 0, s.state, s.message
end

-- (port: a die that nothing catches -- such as Term::ReadKey's croak in
--  Exit() when STDIN is no Windows console -- ends Perl with the message on
--  STDERR, the END block (Cleanup) and perl.dieExitStatus(); a Lua error
--  stays a Lua error)
local function dieHandler(e)
    if perl.isDie(e) then return e end
    return debug.traceback(tostring(e), 2)
end
local function runMain(...)
    local res = table.pack(xpcall(main, dieHandler, ...))
    if res[1] then return table.unpack(res, 2, res.n) end
    local e = res[2]
    if not perl.isDie(e) then error(e, 0) end
    -- (perl.c die_unwind: the message, then my_failure_exit takes the status
    --  from errno as the die left it -- Perl's write to STDERR does not touch
    --  errno, Lua's resets it, so the status is taken first -- and the END
    --  block runs after that)
    local status = perl.dieExitStatus()
    print(io.stderr, tostring(e))
    Cleanup()
    io.stdout:flush()
    os.exit(status)
end

-- the module: callable as the script, main(argv, launch), as the launchers
-- use it, plus the session entry points
return setmetatable({ session = session, execute = execute }, {
    __call = function(_, ...) return runMain(...) end,
})
