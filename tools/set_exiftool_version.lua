--------------------------------------------------------------------------------
-- File:         tools/set_exiftool_version.lua
--
-- Description:  Copies the vendored exiftool's $VERSION
--               (vendor/exiftool/lib/Image/ExifTool.pm) into the port's own
--               hardcoded mentions of it: src/lexiftool.lua's VERSION
--               local, src/lexiftool/main.lua's version local, and the
--               prose in README.md and doc/differences.md. Run after
--               updating the vendor/exiftool submodule; each mention is
--               patched only where it differs, a no-op (prints and exits
--               0) if all are at that version.
--
--               Deliberately not touched: rockspecs/*.rockspec (its own
--               release-version numbering, set by rockspecs/setversion.lua,
--               a separate, tag-driven step -- not every exiftool bump is
--               a new lexiftool release); src/lexiftool/usage.lua (text
--               generated fresh from the vendored Perl each time, `make
--               usage`); doc/capi.md's "13.59" (a generic example of how a
--               Perl scalar stringifies, not a version statement).
--
-- Syntax:       lua tools/set_exiftool_version.lua
--               (run from the repository root; needs no package.path)
--------------------------------------------------------------------------------

local function slurp(path)
    local f = assert(io.open(path, 'r'), 'cannot open ' .. path)
    local data = f:read('a')
    f:close()
    return data
end

local function spit(path, data)
    local f = assert(io.open(path, 'w'), 'cannot open ' .. path .. ' for writing')
    f:write(data)
    f:close()
end

-- replaces old with new inside every line matching pattern (which must
-- capture old literally via a %s-substituted plain-text anchor); asserts
-- it fired exactly `expect` times, so a reworded line is caught, not
-- silently skipped
local function patchLines(path, old, new, anchors)
    local data = slurp(path)
    local lines = {}
    local n = 0
    for line in (data .. '\n'):gmatch('([^\n]*)\n') do
        lines[#lines + 1] = line
    end
    for _, anchor in ipairs(anchors) do
        local found = false
        for i, line in ipairs(lines) do
            if line:find(anchor, 1, true) then
                local escOld = old:gsub('%p', '%%%1')
                local patched, cnt = line:gsub(escOld, new)
                assert(cnt == 1, path .. ': expected exactly one "' .. old ..
                    '" on the matched line, found ' .. cnt)
                lines[i] = patched
                found = true
                n = n + 1
                break
            end
        end
        assert(found, path .. ': anchor not found: ' .. anchor)
    end
    spit(path, table.concat(lines, '\n'))
    return n
end

local newVersion = assert(slurp('vendor/exiftool/lib/Image/ExifTool.pm')
    :match("\n%$VERSION%s*=%s*'([%d.]+)';"), 'cannot find $VERSION in vendor/exiftool')

-- each mention with the pattern that finds the version it carries now; a
-- file is patched only where it is not at the vendored version yet (so a
-- mention that was missed on an earlier run is still brought up to date)
local targets = {
    { path = 'src/lexiftool.lua', anchors = { "local VERSION = '%s'" } },
    { path = 'src/lexiftool/main.lua', anchors = { "local version = '%s'" } },
    { path = 'README.md', anchors = { 'Tracks ExifTool %s (' } },
    { path = 'doc/differences.md', anchors = {
        'exiftool` %s and gives',
        '`-ver` prints `%s`',
    } },
}

local changed = 0
for _, t in ipairs(targets) do
    local data = slurp(t.path)
    for _, anchor in ipairs(t.anchors) do
        local pat = anchor:gsub('%p', '%%%0'):gsub('%%%%s', '([%%d.]+)')
        local old = assert(data:match(pat), t.path .. ': anchor not found: ' .. anchor)
        if old ~= newVersion then
            patchLines(t.path, old, newVersion, { anchor:format(old) })
            data = slurp(t.path)
            changed = changed + 1
            print(string.format('%-24s %s -> %s', t.path, old, newVersion))
        end
    end
end

if changed == 0 then
    print('set_exiftool_version: already at ' .. newVersion)
    os.exit(0)
end
print('set_exiftool_version: ' .. changed .. ' mention(s) set to ' .. newVersion)
print('remaining by hand: rockspecs/setversion.lua (release version), make usage,')
print('and a full re-run of make check / make test-cli / make test-corpus')
