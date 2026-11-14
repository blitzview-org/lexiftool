--------------------------------------------------------------------------------
-- File:         test/test_geolangdata.lua
--
-- Description:  Port-only: lexiftool.GeoLangData, the parser that reads the
--               Geolocation language files GeoLang/<lang>.pm as data
--               instead of running them as Perl:
--                 1. the pure-data form is read with Perl's single-quote
--                    rules (\' and \\ are escapes, any other backslash
--                    stays), bareword keys, comments, blank lines, CRLF
--                    line ends, a missing final newline or `1;`
--                 2. anything else is refused with the line number: code,
--                    other statements, double-quoted, concatenated or
--                    multi-line strings, heredocs, a missing terminator
--                 3. Geolocation.GetEntry: a .pm declaring another
--                    language's hash gives no translations (Perl's
--                    %Image::ExifTool::GeoLang::<lang>::Translate stays
--                    empty), a refused .pm warns and gives none either
--               The expected values of 1 are what Perl itself makes of the
--               same lines (`perl -e` over the hash assignment).
--------------------------------------------------------------------------------

local TestLib = require('test.TestLib')
local GeoLangData = require('lexiftool.GeoLangData')

local is, ok = TestLib.is, TestLib.ok

local HEAD = '%Image::ExifTool::GeoLang::ru::Translate = (\n'
local TAIL = ');\n\n1; #end\n'

local function translate(text)
    local lines, lang = GeoLangData.Parse(text)
    if not lines then return nil, lang end
    return GeoLangData.Translate(lines), lang
end

--------------------------------------------------------------------------------
-- 1. the pure-data form
--------------------------------------------------------------------------------
do
    local trans, lang = translate('# header\n#\n\n' .. HEAD ..
        "\t'\\'Abās Ābād' => 'Абассабад',\n" ..
        "\t'A\\'ana' => 'Аана',\n" ..
        "\t'back\\\\slash' => 'one \\\\ two',\n" ..
        "\t'keep\\n' => 'keep\\x',\n" ..
        "\n\t# feature types\n" ..
        '\tPPL => \'Населенный Пункт\',\n' ..
        "  STLMT=>'x' ,\n" ..
        "\t'dup' => 'first',\n" ..
        "\t'dup' => 'second',\n" ..
        TAIL)
    is('ru', lang, 'the declared language')
    is('Абассабад', trans["'Abās Ābād"], "\\' at the start of a key")
    is('Аана', trans["A'ana"], "\\' inside a key")
    is('one \\ two', trans['back\\slash'], '\\\\ in key and value')
    is('keep\\x', trans['keep\\n'], 'any other backslash stays')
    is('Населенный Пункт', trans.PPL, 'bareword key')
    is('x', trans.STLMT, 'bareword key without blanks around =>')
    is('second', trans.dup, 'a later entry replaces an earlier one')

    local lines = GeoLangData.Parse('# a\n' .. HEAD .. "\t'k' => 'v',\n" .. TAIL)
    local types = {}
    for _, item in ipairs(lines) do types[#types + 1] = item.type end
    is('comment open entry close blank end', table.concat(types, ' '), 'the line types in order')
    is('\t', lines[3].indent, 'entry indentation')
    is(' a', lines[1].text, 'comment text after the #')

    trans = translate(HEAD:gsub('\n', '\r\n') .. "\t'k' => 'v',\r\n);\r\n1;\r\n")
    is('v', trans and trans.k, 'CRLF line ends')
    trans = translate(HEAD .. "\t'k' => 'v',\n);")
    is('v', trans and trans.k, 'no final newline and no 1;')
    trans = translate(HEAD .. ');\n')
    ok(trans and next(trans) == nil, 'an empty table')
end

--------------------------------------------------------------------------------
-- 2. refused
--------------------------------------------------------------------------------
do
    local function refused(text, wantLine, name)
        local lines, msg, lineNo = GeoLangData.Parse(text)
        is(nil, lines, name .. ': refused')
        is(wantLine, lineNo, name .. ': line number')
        ok(type(msg) == 'string' and msg ~= '', name .. ': message')
    end
    refused('system("rm -rf /");\n' .. HEAD .. TAIL, 1, 'code before the table')
    refused('package Image::ExifTool::GeoLang::ru;\n' .. HEAD .. TAIL, 1, 'package statement')
    refused('use strict;\n' .. HEAD .. TAIL, 1, 'use statement')
    refused(HEAD .. "\t'k' => 'v',\n", 2, 'missing terminator')
    refused(HEAD .. "\t'k' => 'v',\n);\n1;\nprint 'x';\n", 5, 'statement after 1;')
    refused(HEAD .. "\t'k' => 'v',\n);\n`id`;\n1;\n", 4, 'statement after the table')
    refused(HEAD .. "\t'k' => 'v',\n);\n1;\n1;\n", 5, 'a second 1;')
    refused(HEAD .. "\t'k' => 'a' . 'b',\n" .. TAIL, 2, 'string concatenation')
    refused(HEAD .. "\t'k' => 'a' . `id`,\n" .. TAIL, 2, 'concatenation with code')
    refused(HEAD .. "\t'k' => \"v\",\n" .. TAIL, 2, 'double-quoted value')
    refused(HEAD .. "\t\"k\" => 'v',\n" .. TAIL, 2, 'double-quoted key')
    refused(HEAD .. "\t'k' => <<EOF,\nv\nEOF\n" .. TAIL, 2, 'heredoc')
    refused(HEAD .. "\t'k' => 'line one\nline two',\n" .. TAIL, 2, 'string over two lines')
    refused(HEAD .. "\t'k' => 'v'\n" .. TAIL, 2, 'missing comma')
    refused(HEAD .. "\t'k' => 'v', 'k2' => 'v2',\n" .. TAIL, 2, 'two entries on one line')
    refused(HEAD .. "\t'k' => 'v', # comment\n" .. TAIL, 2, 'trailing comment')
    refused(HEAD .. "\t'k' => v,\n" .. TAIL, 2, 'bareword value')
    refused(HEAD .. "\t'k' => 'v\\',\n" .. TAIL, 2, 'escaped closing quote')
    refused(HEAD .. "\tdo { 1 } => 'v',\n" .. TAIL, 2, 'code as key')
    refused(HEAD .. "\t'k' => 'v',\n\t%other,\n" .. TAIL, 3, 'another hash')
    refused('%Image::ExifTool::GeoLang::ru::Translate = (%ENV);\n1;\n', 1, 'list on the assignment line')
    refused('%Translate = (\n' .. TAIL, 1, 'other hash name')
    refused('', 0, 'empty file')
end

--------------------------------------------------------------------------------
-- 3. Geolocation.GetEntry with .pm files
--------------------------------------------------------------------------------
do
    local perl = require('lexiftool.perl')
    local tmpDir = os.tmpname()
    os.remove(tmpDir)
    local lfs = require('lfs')
    lfs.mkdir(tmpDir)
    lfs.mkdir(tmpDir .. '/GeoLang')
    local function writeFile(path, text)
        local fh = assert(io.open(path, 'wb'))
        fh:write(text)
        fh:close()
    end
    -- a city name the bundled database has at its first entry, in English
    local function entry(lang)
        package.loaded['lexiftool.Geolocation'] = nil
        local Geolocation = require('lexiftool.Geolocation')
        Geolocation.init()
        Geolocation.geoDir = tmpDir
        return (Geolocation.GetEntry(0, lang))
    end
    local city = entry(nil)
    ok(type(city) == 'string' and city ~= '', 'untranslated city: ' .. tostring(city))
    local key = city:gsub("[\\']", '\\%0')

    writeFile(tmpDir .. '/GeoLang/ru.pm', HEAD .. "\t'" .. key .. "' => 'RU',\n" .. TAIL)
    is('RU', entry('ru'), 'a pure-data .pm in geoDir is read')

    writeFile(tmpDir .. '/GeoLang/de.pm', HEAD .. "\t'" .. key .. "' => 'RU',\n" .. TAIL)
    is(city, entry('de'), 'a .pm declaring another language: no translations')

    writeFile(tmpDir .. '/GeoLang/fr.pm', HEAD:gsub('::ru::', '::fr::') .. "\t'" .. key ..
              "' => 'FR',\n);\nsystem('true');\n1;\n")
    -- (under a $SIG{__WARN__} handler, as GetEntry runs in ExtractInfo: the
    --  warning goes to stderr all the same)
    local warned = {}
    local oldHandler = perl.SIG.__WARN__
    perl.SIG.__WARN__ = function() end
    perl.redirect(io.stderr, warned)
    local okCall, got = pcall(entry, 'fr')
    perl.redirect(io.stderr, nil)
    perl.SIG.__WARN__ = oldHandler
    if not okCall then got = 'error: ' .. tostring(got) end
    warned = table.concat(warned)
    is(city, got, 'a refused .pm: no translations')
    is('GeoLang file not supported by lexiftool (Perl code, not a pure data table): ' ..
       tmpDir .. '/GeoLang/fr.pm\n', warned, 'a refused .pm warns with its file name')

    for _, f in ipairs({ 'ru.pm', 'de.pm', 'fr.pm' }) do os.remove(tmpDir .. '/GeoLang/' .. f) end
    lfs.rmdir(tmpDir .. '/GeoLang')
    lfs.rmdir(tmpDir)
    package.loaded['lexiftool.Geolocation'] = nil
end

ok(true, 'done')
TestLib.done()
