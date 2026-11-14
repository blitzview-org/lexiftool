--------------------------------------------------------------------------------
-- File:         test/test_macos.lua
-- Ported from:  t/MacOS.t
--
-- Description:  Lua port of test 2 of the upstream MacOS.t (the Perl
--               original): extracts information from t/images/MacOS.macos
--               (a MacOS "._" AppleDouble sidecar file) and compares against
--               the vendored standard output (t/MacOS_2.out).
--
-- Port notes:   Test 3 has no upstream counterpart: the darwin branch of
--               SetSystemTags (MacOS SetMacOSTags, which runs setfile,
--               tag, xattr and osascript) on any host.  Both sides run with
--               $^O set to 'darwin' and System replaced by a recorder that
--               returns a preset exit code per command: Perl through the
--               vendored library (`perl`, or the test-only global
--               LEXIFTOOL_TEST_PERL), lexiftool through perl.osname and
--               perl.system, which MacOS.lua binds when it is loaded.  The
--               expected lines (SetNewValue results, verbose output, the
--               recorded commands, the result and the warnings) are the
--               ones the Perl run prints.  Skipped without a Perl and on
--               Windows (shell quoting of the Perl call).
--------------------------------------------------------------------------------

-- (the stand-ins must be in place before MacOS.lua binds perl.system)
local perl = require('lexiftool.perl')
local fake = { on = false, log = { }, ret = { } }
local realSystem, realOsname, realRedirect = perl.system, perl.osname, perl.redirectStdio
perl.system = function(...)
    if not fake.on then return realSystem(...) end
    fake.log[#fake.log + 1] = table.concat({ ... }, '|')
    local c = (select(1, ...)):gsub('.*/', '')
    return fake.ret[c] or 0
end
perl.osname = function()
    if fake.on then return 'darwin' end
    return realOsname()
end
perl.redirectStdio = function(...)
    if fake.on then return nil, nil end
    return realRedirect(...)
end

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local ok = TestLib.ok
local is = TestLib.is
local check = TestLib.check
local done = TestLib.done

local T_DIR = TestLib.T_DIR

-- test 1: Load the module(s)
ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'MacOS'

-- test 2: Extract information from MacOS.macos
do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/MacOS.macos')
    ok(check(exifTool, info, testname, 2), 'test 2 matches')
end

-- test 3: SetSystemTags/SetMacOSTags as on MacOS, against Perl
do
    -- one case per line: the target file ('-' for a file handle), then
    -- operations OP:TAG:VALUE (OP set/add/del/shift; ret:CMD:CODE presets
    -- the exit code of CMD; a VALUE of \3 is undef), separated by \1
    local cases = {
        { '/tmp/a b.jpg', 'set:MDItemFSCreationDate:2024:01:02 03:04:05' },
        { '/tmp/x.jpg', 'set:FileCreateDate:2024:01:02 03:04:05Z' },
        { '/tmp/x.jpg', 'set:FileCreateDate:2024:01:02 03:04:05+02:00', 'set:FileModifyDate:2020:01:01 00:00:00' },
        { '/tmp/x.jpg', 'set:MDItemUserTags:red', 'add:MDItemUserTags:blue' },
        { '/tmp/x.jpg', 'del:MDItemUserTags:old', 'add:MDItemUserTags:new' },
        { '/tmp/x.jpg', 'del:MDItemUserTags:old' },
        { '/tmp/x.jpg', 'set:MDItemUserTags:\3' },
        { '/tmp/x.jpg', 'set:XAttrQuarantine:\3', 'ret:xattr:256' },
        { '/tmp/x.jpg', 'set:XAttrMDItemWhereFroms:\3', 'ret:xattr:512' },
        { '/tmp/x.jpg', 'set:XAttrQuarantine:abc' },
        { '/tmp/q"u\\o.jpg', 'set:MDItemFinderComment:say "hi" \\ there' },
        { '/tmp/x.jpg', 'set:MDItemFinderComment:\3' },
        { '/tmp/x.jpg', 'set:MDItemFSLabel:3' },
        { '/tmp/x.jpg', 'set:MDItemFSLabel:\3' },
        { '/tmp/x.jpg', 'set:MDItemFSLabel:9' },
        { '/tmp/x.jpg', 'del:MDItemFinderComment:old', 'set:MDItemFSLabel:1' },
        { '/tmp/x.jpg', 'shift:MDItemFSCreationDate:1' },
        { '/tmp/x.jpg', 'set:MDItemFSCreationDate:\3' },
        { '/tmp/x.jpg', 'set:MDItemFSCreationDate:2024:01:02 03:04:05', 'ret:setfile:256' },
        { '/tmp/x.jpg', 'set:MDItemFSLabel:2', 'set:MDItemUserTags:a', 'ret:osascript:1', 'ret:tag:2' },
        { '-', 'set:MDItemFSLabel:2' },
        { '/tmp/x.jpg', 'set:FileCreateDate:2024:01:02 03:04:05' },
    }
    local lines = { }
    for _, c in ipairs(cases) do lines[#lines + 1] = table.concat(c, '\1') end
    local caseFile = os.tmpname()
    local fh = io.open(caseFile, 'wb')
    fh:write(table.concat(lines, '\n'), '\n')
    fh:close()

    local SCRIPT = [==[
use strict;
use Image::ExifTool;
require Image::ExifTool::MacOS;
my (@log, %ret);
{
    no warnings 'redefine';
    *Image::ExifTool::MacOS::System = sub {
        push @log, join('|', @_);
        (my $c = $_[0]) =~ s(.*/)();
        return $ret{$c} || 0;
    };
}
$^O = 'darwin';
open(my $in, '<', $ARGV[0]) or die;
while (my $line = <$in>) {
    chomp $line;
    my ($file, @ops) = split /\x01/, $line;
    @log = (); %ret = ();
    my $et = Image::ExifTool->new;
    my $out = '';
    open(my $fh, '>', \$out);
    $et->Options(Verbose => 2, TextOut => $fh);
    print "case $file\n";
    foreach (@ops) {
        my ($op, $tag, $val) = split /:/, $_, 3;
        if ($op eq 'ret') { $ret{$tag} = $val; next }
        my @opts = (Protected => 1);
        push @opts, AddValue => 1 if $op eq 'add';
        push @opts, DelValue => 1 if $op eq 'del';
        push @opts, Shift => 1 if $op eq 'shift';
        undef $val if $val eq "\x03";
        my ($n, $err) = $et->SetNewValue($tag, $val, @opts);
        print "set $tag: $n", (defined $err ? " ($err)" : ''), "\n";
    }
    my $res = $et->SetSystemTags($file eq '-' ? \*STDERR : $file);
    close $fh;
    print "out: $_\n" foreach split /\n/, $out;
    print "cmd: $_\n" foreach @log;
    print "result: $res\n";
    foreach (sort keys %{$$et{VALUE}}) {
        print "warn: $$et{VALUE}{$_}\n" if /^Warning/;
    }
}
]==]
    local scriptFile = os.tmpname()
    fh = io.open(scriptFile, 'wb')
    fh:write(SCRIPT)
    fh:close()

    -- lexiftool's run of the same cases
    local function luaRun()
        local outLines = { }
        local function say(s) outLines[#outLines + 1] = s end
        fake.on = true
        for _, c in ipairs(cases) do
            local file = c[1]
            fake.log, fake.ret = { }, { }
            local et = lexiftool.new()
            local tmp = io.tmpfile()
            et:Options('Verbose', 2)
            et:Options('TextOut', tmp)
            say('case ' .. file)
            for i = 2, #c do
                local op, tag, val = c[i]:match('^([^:]*):([^:]*):(.*)$')
                if op == 'ret' then
                    fake.ret[tag] = tonumber(val)
                else
                    local opts = { Protected = 1 }
                    if op == 'add' then opts.AddValue = 1 end
                    if op == 'del' then opts.DelValue = 1 end
                    if op == 'shift' then opts.Shift = 1 end
                    if val == '\3' then val = nil end
                    local n, err = et:SetNewValue(tag, val, opts)
                    say('set ' .. tag .. ': ' .. perl.str(n) .. (err ~= nil and (' (' .. err .. ')') or ''))
                end
            end
            local res = et:SetSystemTags(file == '-' and io.stderr or file)
            tmp:seek('set', 0)
            local out = tmp:read('a')
            tmp:close()
            for l in out:gmatch('([^\n]*)\n') do say('out: ' .. l) end
            for _, l in ipairs(fake.log) do say('cmd: ' .. l) end
            say('result: ' .. perl.str(res))
            local keys = { }
            for k in pairs(et.VALUE) do
                if k:match('^Warning') then keys[#keys + 1] = k end
            end
            perl.tsort(keys)
            for _, k in ipairs(keys) do say('warn: ' .. et.VALUE[k]) end
        end
        fake.on = false
        return outLines
    end

    local isWin = package.config:sub(1, 1) == '\\'
    local wantPerl = rawget(_G, 'LEXIFTOOL_TEST_PERL')
    if wantPerl == '' then wantPerl = nil end
    local perlCmd = "'" .. (wantPerl or 'perl'):gsub("'", [['\'']]) .. "'"
    local plines
    if not isWin then
        local p = io.popen(perlCmd .. " -I'" .. TestLib.REPO_DIR .. "/vendor/exiftool/lib' " ..
                           scriptFile .. ' ' .. caseFile .. ' 2>&1')
        if p then
            local pout = p:read('a')
            p:close()
            if pout:match('^case ') then
                plines = { }
                for l in pout:gmatch('([^\n]*)\n') do plines[#plines + 1] = l end
            end
        end
    end
    if not plines then
        ok(isWin or wantPerl == nil, 'SetMacOSTags vs Perl SKIPPED: no Perl to compare with')
    else
        local llines = luaRun()
        local n = math.max(#plines, #llines)
        local same = true
        for i = 1, n do
            if plines[i] ~= llines[i] then
                same = false
                is(plines[i], llines[i], 'SetMacOSTags line ' .. i)
            end
        end
        ok(same and #plines > #cases, 'test 3: SetMacOSTags as Perl (' .. #plines .. ' lines)')
    end
    os.remove(caseFile)
    os.remove(scriptFile)
end

done() -- end
