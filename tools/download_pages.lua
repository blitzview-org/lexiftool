--------------------------------------------------------------------------------
-- File:         tools/download_pages.lua
--
-- Description:  The download pages of the Pages site, next to the benchmark
--               page (tools/bench_report.lua, index.html):
--                 download/index.html  the standalone executables
--                 capi/index.html      the C API zips
--               One table per page and section: platform, system
--               requirements, file name with its direct link, size, SHA-256.
--
--               The pages are generated from the zips themselves, the ones
--               that are published (CI: the run's artifacts, after the
--               publishing job attached them to the release), so name, size
--               and checksum always belong to the files behind the links.
--
--               Sections: each --tag starts one, with the files that follow
--               it; today only latest-dev, a "latest release" section is a
--               second --tag group (in the order given). Files are sorted
--               onto the pages by name:
--                 lexiftool-capi-<platform>-<version>.zip  C API
--                 lexiftool-<platform>-<version>.zip       executable
--               platform linux, macos or windows; any other file, or a
--               platform missing from a section, is an error.
--
-- Syntax:       lua tools/download_pages.lua OUTDIR
--                   --tag TAG --title TITLE --commit SHA --date ISODATE ZIP...
--                   [--tag ...]
--               (Lua 5.4 or 5.5, standard library only; sha256sum on PATH)
--               Repository from GITHUB_REPOSITORY, else blitzview-org/lexiftool.
--------------------------------------------------------------------------------

local REPO = os.getenv('GITHUB_REPOSITORY') or 'blitzview-org/lexiftool'
local GH = 'https://github.com/' .. REPO

local function usage(msg)
    io.stderr:write('download_pages.lua: ' .. msg .. '\n'
        .. 'usage: download_pages.lua OUTDIR --tag TAG --title TITLE --commit SHA --date ISODATE ZIP... [--tag ...]\n')
    os.exit(2)
end

-- the platforms, in page order; requirements as README.md, "Platforms"
local PLATFORMS = {
    { id = 'linux', name = 'Linux',
      app = 'x86-64, glibc 2.17 or newer (RHEL/CentOS 7, Debian 8, Ubuntu 14.04 and newer); '
          .. 'not for musl systems such as Alpine (install the rock there)',
      capi = 'x86-64, glibc 2.17 or newer (RHEL/CentOS 7, Debian 8, Ubuntu 14.04 and newer)' },
    { id = 'macos', name = 'macOS',
      app = '11 or newer, universal binary (x86-64 and Apple Silicon)',
      capi = '11 or newer, universal (x86-64 and Apple Silicon)' },
    { id = 'windows', name = 'Windows',
      app = 'x64',
      capi = 'x64, Windows 7 or newer (MSVC, MinGW)' },
}
local PLATFORM = {}
for _, p in ipairs(PLATFORMS) do PLATFORM[p.id] = p end

-- the command line ------------------------------------------------------------------

local outdir = arg[1]
if not outdir or outdir:match('^%-%-') then usage('OUTDIR missing') end
local sections, cur = {}, nil
local i = 2
while arg[i] do
    local a = arg[i]
    local key = a:match('^%-%-(%a+)$')
    if key then
        local v = arg[i + 1] or usage(a .. ' without a value')
        if key == 'tag' then
            cur = { tag = v, app = {}, capi = {} }
            sections[#sections + 1] = cur
        elseif not cur then
            usage(a .. ' before --tag')
        elseif key == 'title' or key == 'commit' or key == 'date' then
            cur[key] = v
        else
            usage('unknown option ' .. a)
        end
        i = i + 2
    else
        if not cur then usage(a .. ' before --tag') end
        local name = a:match('([^/\\]+)$')
        local kind, platform, version = 'capi', name:match('^lexiftool%-capi%-(%a+)%-(.+)%.zip$')
        if not platform then
            kind, platform, version = 'app', name:match('^lexiftool%-(%a+)%-(.+)%.zip$')
        end
        if not (platform and PLATFORM[platform]) then usage('not a release zip: ' .. a) end
        if cur[kind][platform] then usage('two ' .. kind .. ' zips for ' .. platform .. ' in ' .. cur.tag) end
        local f = assert(io.open(a, 'rb'))
        local size = f:seek('end')
        f:close()
        local p = assert(io.popen("sha256sum '" .. a:gsub("'", "'\\''") .. "'"))
        local sha = p:read('a'):match('^(%x+)')
        p:close()
        if not (sha and #sha == 64) then usage('sha256sum failed on ' .. a) end
        cur[kind][platform] = { name = name, size = size, sha256 = sha, version = version }
        cur.version = cur.version or version
        i = i + 1
    end
end
if #sections == 0 then usage('no --tag') end
for _, s in ipairs(sections) do
    if not (s.title and s.commit and s.date) then usage(s.tag .. ': --title, --commit and --date are required') end
    if not s.commit:match('^%x+$') or #s.commit < 7 then usage(s.tag .. ': not a commit: ' .. s.commit) end
    for _, kind in ipairs { 'app', 'capi' } do
        for _, p in ipairs(PLATFORMS) do
            if not s[kind][p.id] then usage(s.tag .. ': no ' .. kind .. ' zip for ' .. p.id) end
        end
    end
end

-- the pages -------------------------------------------------------------------------

local function esc(s)
    return (tostring(s):gsub('[&<>"]', { ['&'] = '&amp;', ['<'] = '&lt;', ['>'] = '&gt;', ['"'] = '&quot;' }))
end

local function sizeText(n)
    if n >= 1024 * 1024 then return string.format('%.1f MB', n / (1024 * 1024)) end
    return string.format('%.0f KB', n / 1024)
end

-- YYYY-MM-DDThh:mm:ssZ (or +hh:mm, as the GitHub API gives it) -> YYYY-MM-DD hh:mm UTC
local function dateText(iso)
    local d, t, z = iso:match('^(%d%d%d%d%-%d%d%-%d%d)[T ](%d%d:%d%d)[%d:.]*(.*)$')
    if not d then return iso end
    if z == 'Z' or z == '' or z == '+00:00' then z = 'UTC' end
    return d .. ' ' .. t .. ' ' .. z
end

local PAGES = {
    app = { dir = 'download', title = 'lexiftool downloads: command-line tool',
            heading = 'Download the lexiftool command-line tool',
            intro = 'Standalone executables: unzip and run, no Lua or Perl needed. Each zip holds a folder '
                .. '<code>lexiftool-&lt;platform&gt;-&lt;version&gt;/</code> with the executable, <code>LICENSE</code>, '
                .. '<code>LICENSE-THIRD-PARTY</code> and the license texts of all built-in components; '
                .. '<code>lexiftool -ver -v</code> prints the build\'s identity.',
            notes = {
                'The executables are not signed: macOS asks for confirmation on the first start (or run '
                    .. '<code>xattr -d com.apple.quarantine lexiftool-macos-&lt;version&gt;/lexiftool</code>), '
                    .. 'Windows SmartScreen may warn. They need nothing but the system\'s C library.',
                'They are built reproducibly (<a href="' .. GH .. '/blob/master/standalone/README.md">standalone/README.md</a>): '
                    .. 'the same commit gives the same bytes, so the SHA-256 can be checked against a build of your own.',
                'For C and C++ programs, the same build as a library: <a href="../capi/">C API downloads</a>. '
                    .. 'As a Lua module, through LuaRocks: <a href="' .. GH .. '#with-luarocks">README, "With LuaRocks"</a>.',
            } },
    capi = { dir = 'capi', title = 'lexiftool downloads: C API',
             heading = 'Download the lexiftool C API',
             intro = 'The C API as a library for C and C++ programs: header, static and shared library with Lua, '
                 .. 'the lexiftool modules and every C library built in, <code>example.c</code>, the API documentation '
                 .. 'and the license texts. Each zip unpacks into one folder of its own name; its <code>README.txt</code> '
                 .. 'says what is where and how to link. Documentation: <a href="' .. GH .. '/blob/master/doc/capi.md">doc/capi.md</a> '
                 .. '(<a href="' .. GH .. '/blob/master/doc/capi.md#getting-the-library">Getting the library</a>).',
             notes = {
                 'The libraries need nothing but the system\'s C library: <code>libc</code>, <code>libm</code> and '
                     .. '<code>libpthread</code> on Linux, <code>libSystem</code> on macOS, <code>KERNEL32.dll</code> and '
                     .. '<code>msvcrt.dll</code> on Windows.',
                 'The command-line tool of the same build: <a href="../download/">standalone executables</a>.',
             } },
}

local STYLE = table.concat({
    '<style>body{font-family:system-ui,sans-serif;max-width:900px;margin:2em auto;padding:0 1em;line-height:1.45;color:#1f2328;background:#fff}',
    'table{border-collapse:collapse;margin:1em 0;font-size:.92em}th,td{border:1px solid #d1d9e0;padding:.3em .6em;text-align:left;vertical-align:top}',
    'td.n{text-align:right;white-space:nowrap}td.sha code{font-size:.8em;word-break:break-all}',
    'code{font-size:.92em}nav{font-size:.92em;margin-bottom:1.5em}nav a{margin-right:1em}.meta{color:#59636e}',
    '@media (prefers-color-scheme:dark){body{color:#e6edf3;background:#0d1117}a{color:#58a6ff}th,td{border-color:#3d444d}.meta{color:#9198a1}}',
    '</style>' }, '\n')

local function page(kind)
    local pg = PAGES[kind]
    local h = {}
    local function out(s) h[#h + 1] = s end
    out('<!DOCTYPE html>')
    out('<html lang="en"><head><meta charset="utf-8"><title>' .. esc(pg.title) .. '</title>')
    out('<meta name="viewport" content="width=device-width, initial-scale=1">')
    out(STYLE .. '</head>')
    out('<body>')
    out('<nav><a href="../download/">Command-line tool</a><a href="../capi/">C API</a>'
        .. '<a href="../">Performance comparison</a><a href="' .. GH .. '/releases">All releases</a>'
        .. '<a href="' .. GH .. '">Repository</a></nav>')
    out('<h1>' .. esc(pg.heading) .. '</h1>')
    out('<p>' .. pg.intro .. '</p>')
    for _, s in ipairs(sections) do
        local short = s.commit:sub(1, 7)
        out('<h2>' .. esc(s.title) .. ' <small class="meta">(' .. esc(s.version) .. ')</small></h2>')
        out(string.format('<p class="meta">Built from commit <a href="%s/commit/%s"><code>%s</code></a> of %s; '
            .. 'release page: <a href="%s/releases/tag/%s">%s</a>.</p>',
            GH, esc(s.commit), esc(short), esc(dateText(s.date)), GH, esc(s.tag), esc(s.tag)))
        if s.tag == 'latest-dev' then
            out('<p>A snapshot of the latest commit on master, rebuilt on every push; not a release.</p>')
        end
        out('<table><thead><tr><th>Platform</th><th>System requirements</th><th>File</th><th>Size</th><th>SHA-256</th></tr></thead><tbody>')
        for _, p in ipairs(PLATFORMS) do
            local f = s[kind][p.id]
            out(string.format('<tr><td>%s</td><td>%s</td><td><a href="%s/releases/download/%s/%s">%s</a></td>'
                .. '<td class="n" title="%d bytes">%s</td><td class="sha"><code>%s</code></td></tr>',
                esc(p.name), esc(p[kind]), GH, esc(s.tag), esc(f.name), esc(f.name), f.size, sizeText(f.size), f.sha256))
        end
        out('</tbody></table>')
    end
    out('<p>Check a download: <code>sha256sum &lt;file&gt;</code> (Linux), <code>shasum -a 256 &lt;file&gt;</code> (macOS), '
        .. '<code>certutil -hashfile &lt;file&gt; SHA256</code> (Windows).</p>')
    out('<ul>')
    for _, n in ipairs(pg.notes) do out('<li>' .. n .. '</li>') end
    out('</ul>')
    out('</body></html>')
    os.execute("mkdir -p '" .. (outdir .. '/' .. pg.dir):gsub("'", "'\\''") .. "'")
    local f = assert(io.open(outdir .. '/' .. pg.dir .. '/index.html', 'wb'))
    f:write(table.concat(h, '\n'), '\n')
    f:close()
end

page('app')
page('capi')
print(string.format('download_pages.lua: %d section(s) -> %s/download/index.html, %s/capi/index.html', #sections, outdir, outdir))
