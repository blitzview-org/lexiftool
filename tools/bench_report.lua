--------------------------------------------------------------------------------
-- File:         tools/bench_report.lua
--
-- Description:  Report of a tools/bench_cli.sh run: reads the measurements the
--               script left in its output directory and writes
--                 README.md          Markdown tables (job summary, release notes)
--                 index.html         the chart and the tables as a web page
--                 benchmark.svg      bar chart, light theme
--                 benchmark-dark.svg the same for a dark background
--                 results.json       everything, machine-readable
--
--               The chart tells one story in four short blocks. A single
--               call on a file (one process per file, the everyday use)
--               is one stacked bar per tool: start-up (the -ver case),
--               the loading of the format modules, and the processing of
--               the file -- the mean over the mix of file types. The
--               processing is what a -stay_open session of SESSION
--               commands on the same file costs per command (the empty
--               session subtracted); the module loading is what remains
--               of the single call. Then the processing alone (steady
--               state), the throughput of one process over all test
--               images, and the peak memory of the single call (mix) and
--               of that one process. The tables below break the mix down
--               by file type.
--
--               Inputs (tab-separated, written by bench_cli.sh):
--                 cases.def.tsv  name, description, arguments as shown
--                 cases.tsv      name, tool, mean, min, stddev, user, system
--                                (seconds; tool = exiftool | lexiftool)
--                 rss.tsv        name, tool, peak RSS in KB (may be empty)
--                 meta.tsv       key, value (date, identity, versions, cpu,
--                                os, runs, warmup, session, images, ...)
--               Case names: start, read-<type>, session-<type>,
--               session-empty, write-jpeg, session-write, dir-read.
--
-- Syntax:       lua tools/bench_report.lua OUTDIR
--               (Lua 5.4 or 5.5, standard library only)
--------------------------------------------------------------------------------

local outdir = arg[1]
if not outdir then
    io.stderr:write('usage: bench_report.lua OUTDIR\n')
    os.exit(2)
end

local TOOLS = { 'exiftool', 'lexiftool' }

local function readTSV(name)
    local rows = {}
    local f = io.open(outdir .. '/' .. name, 'r')
    if not f then return rows end
    for line in f:lines() do
        if line ~= '' then
            local fields = {}
            for field in (line .. '\t'):gmatch('([^\t]*)\t') do fields[#fields + 1] = field end
            rows[#rows + 1] = fields
        end
    end
    f:close()
    return rows
end

local function writeFile(name, text)
    local f = assert(io.open(outdir .. '/' .. name, 'wb'))
    f:write(text)
    f:close()
end

-- the data --------------------------------------------------------------------

local meta = {}
for _, r in ipairs(readTSV('meta.tsv')) do meta[r[1]] = r[2] end
local runs = tonumber(meta.runs) or 0
local session = tonumber(meta.session) or 30
local images = tonumber(meta.images) or 0

local cases, byName = {}, {}
for _, r in ipairs(readTSV('cases.def.tsv')) do
    local c = { name = r[1], desc = r[2], args = r[3], exiftool = {}, lexiftool = {} }
    cases[#cases + 1] = c
    byName[c.name] = c
end
for _, r in ipairs(readTSV('cases.tsv')) do
    local c = byName[r[1]]
    if c and c[r[2]] then
        local t = c[r[2]]
        t.mean, t.min, t.stddev = tonumber(r[3]), tonumber(r[4]), tonumber(r[5])
        t.user, t.system = tonumber(r[6]), tonumber(r[7])
    end
end
for _, r in ipairs(readTSV('rss.tsv')) do
    local c = byName[r[1]]
    if c and c[r[2]] then c[r[2]].rss = tonumber(r[3]) end
end

local function measured(c) return c and c.exiftool.mean and c.lexiftool.mean end

-- the mix: every read-<type> with its session-<type>, in case order
local start, empty, write, dir = byName['start'], byName['session-empty'], byName['write-jpeg'], byName['dir-read']
local mix = {}      -- { type, read, session, [tool] = { single, proc, load, rss } }
for _, c in ipairs(cases) do
    local ty = c.name:match('^read%-(.+)$')
    local sess = ty and byName['session-' .. ty]
    if ty and measured(c) and measured(sess) and measured(start) and measured(empty) then
        local m = { type = ty, read = c, session = sess, desc = c.desc }
        for _, tool in ipairs(TOOLS) do
            local single = c[tool].mean
            local proc = math.max((sess[tool].mean - empty[tool].mean) / session, 0)
            local load = math.max(single - start[tool].mean - proc, 0)
            m[tool] = { single = single, min = c[tool].min, proc = proc, load = load,
                        rss = c[tool].rss, sessionRss = sess[tool].rss }
        end
        mix[#mix + 1] = m
    end
end
-- the mean over the mix
local mixMean = {}
if #mix > 0 then
    for _, tool in ipairs(TOOLS) do
        local a = { single = 0, proc = 0, load = 0, rss = 0, rssN = 0 }
        for _, m in ipairs(mix) do
            a.single = a.single + m[tool].single
            a.proc = a.proc + m[tool].proc
            a.load = a.load + m[tool].load
            if m[tool].rss then a.rss = a.rss + m[tool].rss; a.rssN = a.rssN + 1 end
        end
        a.single, a.proc, a.load = a.single / #mix, a.proc / #mix, a.load / #mix
        a.start = start[tool].mean
        a.rss = a.rssN > 0 and a.rss / a.rssN or nil
        mixMean[tool] = a
    end
end
if measured(dir) and images > 0 then
    for _, tool in ipairs(TOOLS) do dir[tool].filesPerSecond = images / dir[tool].mean end
end
-- the write, split the same way through its session
local writeSession = byName['session-write']
local writeParts
if measured(write) and measured(writeSession) and measured(start) and measured(empty) then
    writeParts = {}
    for _, tool in ipairs(TOOLS) do
        local proc = math.max((writeSession[tool].mean - empty[tool].mean) / session, 0)
        writeParts[tool] = { single = write[tool].mean, proc = proc,
                             load = math.max(write[tool].mean - start[tool].mean - proc, 0), rss = write[tool].rss }
    end
end

-- formatting ------------------------------------------------------------------

local function ms(seconds)
    if not seconds then return '-' end
    local v = seconds * 1000
    if v < 10 then return string.format('%.1f', v) end
    return string.format('%.0f', v)
end

local function ratio(a, b)
    if not (a and b) or b <= 0 then return nil end
    return a / b
end

local function ratioText(r)
    if not r then return '-' end
    if r >= 10 then return string.format('%.0f×', r) end
    return string.format('%.1f×', r)
end

local function mb(kb)
    if not kb then return '-' end
    return string.format('%.1f', kb / 1024)
end

local function esc(s)
    return (tostring(s):gsub('[&<>]', { ['&'] = '&amp;', ['<'] = '&lt;', ['>'] = '&gt;' }))
end

-- Markdown ----------------------------------------------------------------------

local md = {}
local function out(s) md[#md + 1] = s end
out(string.format('## Performance comparison: lexiftool %s and Perl ExifTool %s',
    meta.lexiftool_version or meta.identity or '?', meta.exiftool_version or '?'))
out('')
out(string.format('%s, %s, %s; Perl %s; %d timed runs per case and tool after %s warm-up runs ([hyperfine](https://github.com/sharkdp/hyperfine) %s); sessions of %d commands.',
    meta.date or '', meta.os or '', meta.cpu or '', meta.perl_version or '?', runs, meta.warmup or '?',
    (meta.hyperfine or ''):gsub('^hyperfine ', ''), session))
out('')
if #mix > 0 then
    out('### One process per file, by file type')
    out('')
    out('Single call: one process for one file, wall clock. Processing: the time per command of a `-stay_open` session on the same file (the empty session subtracted). Module loading: what remains of the single call after start-up and processing. Memory: peak RSS of the single call.')
    out('')
    out('| File type | Single call ms exiftool / lexiftool | faster by | Processing ms exiftool / lexiftool | faster by | Module loading ms exiftool / lexiftool | Memory MB exiftool / lexiftool |')
    out('|---|---:|---:|---:|---:|---:|---:|')
    for _, m in ipairs(mix) do
        local a, b = m.exiftool, m.lexiftool
        out(string.format('| %s (`%s`) | %s / %s | %s | %s / %s | %s | %s / %s | %s / %s |',
            m.desc, m.read.args:match('%S+$'), ms(a.single), ms(b.single), ratioText(ratio(a.single, b.single)),
            ms(a.proc), ms(b.proc), ratioText(ratio(a.proc, b.proc)), ms(a.load), ms(b.load), mb(a.rss), mb(b.rss)))
    end
    local a, b = mixMean.exiftool, mixMean.lexiftool
    out(string.format('| **mean over the mix** | **%s / %s** | **%s** | **%s / %s** | **%s** | **%s / %s** | **%s / %s** |',
        ms(a.single), ms(b.single), ratioText(ratio(a.single, b.single)), ms(a.proc), ms(b.proc),
        ratioText(ratio(a.proc, b.proc)), ms(a.load), ms(b.load), mb(a.rss), mb(b.rss)))
    if writeParts then
        local wa, wb = writeParts.exiftool, writeParts.lexiftool
        out(string.format('| write a tag (`%s`, JPEG copy) | %s / %s | %s | %s / %s | %s | %s / %s | %s / %s |',
            write.args:match('^%S+%s+(%S+)') or '-Artist', ms(wa.single), ms(wb.single), ratioText(ratio(wa.single, wb.single)),
            ms(wa.proc), ms(wb.proc), ratioText(ratio(wa.proc, wb.proc)), ms(wa.load), ms(wb.load), mb(wa.rss), mb(wb.rss)))
    end
    out(string.format('| start-up alone (`-ver`) | %s / %s | %s | | | | %s / %s |',
        ms(a.start), ms(b.start), ratioText(ratio(a.start, b.start)), mb(start.exiftool.rss), mb(start.lexiftool.rss)))
    out('')
end
out('### Other cases')
out('')
out('| Case | Command | exiftool ms mean (min) | lexiftool ms mean (min) | faster by | CPU ms exiftool / lexiftool | Memory MB exiftool / lexiftool |')
out('|---|---|---:|---:|---:|---:|---:|')
for _, c in ipairs(cases) do
    local a, b = c.exiftool, c.lexiftool
    if measured(c) and not c.name:match('^read%-') then
        out(string.format('| %s | `%s` | %s (%s) | %s (%s) | %s | %s / %s | %s / %s |',
            c.name, c.args, ms(a.mean), ms(a.min), ms(b.mean), ms(b.min), ratioText(ratio(a.mean, b.mean)),
            ms(a.user + a.system), ms(b.user + b.system), mb(a.rss), mb(b.rss)))
    end
end
out('')
if dir and dir.exiftool.filesPerSecond then
    out(string.format('One process over all %d test images: exiftool %.0f files/s, lexiftool %.0f files/s, %s faster.',
        images, dir.exiftool.filesPerSecond, dir.lexiftool.filesPerSecond, ratioText(ratio(dir.exiftool.mean, dir.lexiftool.mean))))
    out('')
end
out('Both tools run on the same machine, directly after each other, in one hyperfine invocation per case; the files come from `vendor/exiftool/t/images`. '
    .. 'On a shared runner the absolute times vary from run to run, the ratio between the two tools does not. '
    .. 'CPU is user plus system time of the process; memory is the maximum resident set size'
    .. ((start and start.exiftool.rss) and ' (GNU time).' or ' (not measured in this run).'))
writeFile('README.md', table.concat(md, '\n') .. '\n')

-- index.html for the Pages site: the chart, then the Markdown above as HTML
-- (the subset this file writes: ##/### headings, paragraphs, tables, lists,
-- `code`, **bold**, [text](url))
local function inlineHtml(t)
    t = esc(t)
    t = t:gsub('`([^`]+)`', '<code>%1</code>')
    t = t:gsub('%*%*(.-)%*%*', '<strong>%1</strong>')
    t = t:gsub('%[([^%]]+)%]%(([^%)]+)%)', '<a href="%2">%1</a>')
    return t
end
local html = {}
local inTable, inList = false, false
local function closeBlocks()
    if inTable then html[#html + 1] = '</tbody></table>'; inTable = false end
    if inList then html[#html + 1] = '</ul>'; inList = false end
end
local tableRow = 0
for _, line in ipairs(md) do
    if line:match('^|') then
        if not inTable then
            closeBlocks()
            html[#html + 1] = '<table><thead>'
            inTable, tableRow = true, 0
        end
        tableRow = tableRow + 1
        if tableRow == 2 then
            html[#html + 1] = '</thead><tbody>'
        elseif not line:match('^|%s*%-') then
            local cells = {}
            for cell in (line:sub(2)):gmatch('(.-)|') do cells[#cells + 1] = cell:match('^%s*(.-)%s*$') end
            local tag = tableRow == 1 and 'th' or 'td'
            local row = {}
            for i, c in ipairs(cells) do
                row[#row + 1] = string.format('<%s%s>%s</%s>', tag, (i > 1 and tableRow > 1) and ' class="n"' or '', inlineHtml(c), tag)
            end
            html[#html + 1] = '<tr>' .. table.concat(row) .. '</tr>'
        end
    elseif line:match('^%- ') then
        if inTable then html[#html + 1] = '</tbody></table>'; inTable = false end
        if not inList then html[#html + 1] = '<ul>'; inList = true end
        html[#html + 1] = '<li>' .. inlineHtml(line:sub(3)) .. '</li>'
    else
        closeBlocks()
        local h3 = line:match('^### (.*)')
        local h2 = line:match('^## (.*)')
        if h3 then html[#html + 1] = '<h3>' .. inlineHtml(h3) .. '</h3>'
        elseif h2 then html[#html + 1] = '<h2>' .. inlineHtml(h2) .. '</h2>'
        elseif line ~= '' then html[#html + 1] = '<p>' .. inlineHtml(line) .. '</p>' end
    end
end
closeBlocks()
writeFile('index.html', table.concat({
    '<!DOCTYPE html>',
    '<html lang="en"><head><meta charset="utf-8"><title>lexiftool performance comparison</title>',
    '<meta name="viewport" content="width=device-width, initial-scale=1">',
    '<style>body{font-family:system-ui,sans-serif;max-width:900px;margin:2em auto;padding:0 1em;line-height:1.45;color:#1f2328;background:#fff}',
    'table{border-collapse:collapse;margin:1em 0;font-size:.92em}th,td{border:1px solid #d1d9e0;padding:.3em .6em;text-align:left}td.n{text-align:right;white-space:nowrap}',
    'code{font-size:.92em}img{max-width:100%}',
    '@media (prefers-color-scheme:dark){body{color:#e6edf3;background:#0d1117}a{color:#58a6ff}th,td{border-color:#3d444d}}</style></head>',
    '<body>',
    '<p><a href="benchmark.svg"><picture><source media="(prefers-color-scheme: dark)" srcset="benchmark-dark.svg">'
        .. '<img src="benchmark.svg" alt="Performance comparison with Perl ExifTool"></picture></a></p>',
    table.concat(html, '\n'),
    '<p>Raw data: <a href="results.json">results.json</a>. How it is measured: <a href="https://github.com/blitzview-org/lexiftool/blob/master/doc/benchmark.md">doc/benchmark.md</a>. '
        .. 'The executables this was measured on: <a href="https://github.com/blitzview-org/lexiftool/releases/tag/latest-dev">latest-dev</a>.</p>',
    '</body></html>' }, '\n') .. '\n')

-- SVG -----------------------------------------------------------------------------

local function svg(theme)
    local col = theme == 'dark'
        and { text = '#e6edf3', muted = '#9198a1', line = '#3d444d',
              a = { '#8b949e', '#6e7681', '#484f58' }, b = { '#79c0ff', '#58a6ff', '#1f6feb' } }
        or  { text = '#1f2328', muted = '#59636e', line = '#d1d9e0',
              a = { '#6e7781', '#8c959f', '#afb8c1' }, b = { '#0550ae', '#0969da', '#54aeff' } }
    -- a[1]/b[1] start-up, [2] module loading, [3] processing; a plain bar uses [2]
    local W, x0, bw, xr = 880, 236, 420, 864      -- width, bar start, bar width, ratio column (right edge)
    local rowH, barH = 42, 13
    local font = "ui-sans-serif, system-ui, -apple-system, 'Segoe UI', Helvetica, Arial, sans-serif"
    local parts, y = {}, 0
    local function add(s) parts[#parts + 1] = s end
    local function text(x, yy, s, size, opts)
        opts = opts or {}
        add(string.format('<text x="%g" y="%g" font-size="%g"%s%s fill="%s">%s</text>',
            x, yy, size, opts.anchor and (' text-anchor="' .. opts.anchor .. '"') or '',
            opts.bold and ' font-weight="600"' or '', opts.color or col.text, esc(s)))
    end
    local function total(v) if type(v) == 'table' then local s = 0; for _, x in ipairs(v) do s = s + x end; return s end return v end
    -- rows: { label, note, a, b } with a/b a number or a list of segments
    local function block(title, unit, rows, fmt)
        y = y + 30
        text(16, y, title, 15, { bold = true })
        text(xr, y, unit, 12, { anchor = 'end', color = col.muted })
        y = y + 9
        local max = 0
        for _, r in ipairs(rows) do max = math.max(max, total(r.a), total(r.b)) end
        if max <= 0 then max = 1 end
        for _, r in ipairs(rows) do
            local top = y
            text(16, top + 17, r.label, 13.5)
            if r.note then text(16, top + 33, r.note, 11, { color = col.muted }) end
            for i, v in ipairs { r.a, r.b } do
                local shades = i == 1 and col.a or col.b
                local by = top + 5 + (i - 1) * (barH + 3)
                local segs = type(v) == 'table' and v or { v }
                local x = x0
                for k, sv in ipairs(segs) do
                    local len = math.max(0.5, sv / max * bw)
                    local shade = type(v) == 'table' and shades[k] or shades[2]
                    add(string.format('<rect x="%.1f" y="%g" width="%.1f" height="%g" fill="%s"><title>%s</title></rect>',
                        x, by, len, barH, shade, fmt(sv)))
                    x = x + len
                end
                text(x + 7, by + 10.5, fmt(total(v), segs), 11.5, { color = col.muted })
            end
            text(xr, top + 24, ratioText(ratio(total(r.a), total(r.b))), 18, { anchor = 'end', bold = true, color = col.b[2] })
            y = y + rowH
            add(string.format('<line x1="16" y1="%g" x2="%g" y2="%g" stroke="%s" stroke-width="0.5"/>', y, xr, y, col.line))
        end
    end
    local function msFmt(v, segs)
        if segs and #segs > 1 then
            local p = {}
            for _, s in ipairs(segs) do p[#p + 1] = ms(s) end
            return ms(v) .. ' ms  (' .. table.concat(p, ' + ') .. ')'
        end
        return ms(v) .. ' ms'
    end

    -- header
    y = 30
    text(16, y, string.format('Performance comparison: lexiftool %s and Perl ExifTool %s',
        meta.lexiftool_version or meta.identity or '?', meta.exiftool_version or '?'), 19, { bold = true })
    y = y + 24
    text(16, y, string.format('%s · %s · %s · Perl %s', meta.date or '', meta.os or '', meta.cpu or '', meta.perl_version or '?'),
        12.5, { color = col.muted })
    y = y + 22
    add(string.format('<rect x="16" y="%g" width="13" height="12" fill="%s"/>', y - 10, col.a[2]))
    text(34, y, 'Perl ExifTool', 12.5)
    add(string.format('<rect x="140" y="%g" width="13" height="12" fill="%s"/>', y - 10, col.b[2]))
    text(158, y, 'lexiftool', 12.5)
    -- the segments of a stacked bar, shown in lexiftool's shades
    local lx = 260
    for k, name in ipairs { 'start-up', 'module loading', 'processing' } do
        add(string.format('<rect x="%g" y="%g" width="13" height="12" fill="%s"/>', lx, y - 10, col.b[k]))
        text(lx + 18, y, name, 12.5, { color = col.muted })
        lx = lx + 18 + 7.6 * #name + 16
    end
    text(xr, y, 'ratio: exiftool ÷ lexiftool', 12.5, { anchor = 'end', color = col.muted })
    y = y + 8

    if #mix > 0 then
        local a, b = mixMean.exiftool, mixMean.lexiftool
        local rows = { { label = 'read a file', note = string.format('mean over %d file types', #mix),
                         a = { a.start, a.load, a.proc }, b = { b.start, b.load, b.proc } } }
        if writeParts then
            local wa, wb = writeParts.exiftool, writeParts.lexiftool
            rows[#rows + 1] = { label = 'write a tag', note = 'JPEG, a fresh copy per run',
                                a = { start.exiftool.mean, wa.load, wa.proc }, b = { start.lexiftool.mean, wb.load, wb.proc } }
        elseif measured(write) then
            rows[#rows + 1] = { label = 'write a tag', note = 'JPEG, a fresh copy per run', a = write.exiftool.mean, b = write.lexiftool.mean }
        end
        block(string.format('One process per file (wall clock, mean of %d runs)', runs), 'ms', rows, msFmt)
        local procRows = { { label = 'read a file', note = string.format('mean over %d file types', #mix), a = a.proc, b = b.proc } }
        if writeParts then
            procRows[#procRows + 1] = { label = 'write a tag', note = 'JPEG', a = writeParts.exiftool.proc, b = writeParts.lexiftool.proc }
        end
        block(string.format('Processing alone (per command in a -stay_open session of %d commands)', session), 'ms', procRows, msFmt)
    end
    if dir and dir.exiftool.filesPerSecond then
        block(string.format('One process over all %d test images', images), 's',
            { { label = 'read them all', a = dir.exiftool.mean, b = dir.lexiftool.mean } },
            function(v) return string.format('%.1f s  (%.0f files/s)', v, images / v) end)
    end
    local memRows = {}
    if #mix > 0 and mixMean.exiftool.rss and mixMean.lexiftool.rss then
        memRows[#memRows + 1] = { label = 'read a file', note = string.format('one process, mean over %d file types', #mix),
                                  a = mixMean.exiftool.rss / 1024, b = mixMean.lexiftool.rss / 1024 }
    end
    if dir and dir.exiftool.rss and dir.lexiftool.rss then
        memRows[#memRows + 1] = { label = 'read them all', note = string.format('all %d test images, one process', images),
                                  a = dir.exiftool.rss / 1024, b = dir.lexiftool.rss / 1024 }
    end
    if #memRows > 0 then
        block('Peak memory (max RSS)', 'MB', memRows, function(v) return string.format('%.1f MB', v) end)
    end
    y = y + 28
    text(16, y, 'Same machine, same run, one hyperfine invocation per case; GitHub-hosted runner: absolute times vary, the ratio does not.',
        11.5, { color = col.muted })
    y = y + 16
    text(16, y, 'Files from vendor/exiftool/t/images; the table breaks the mix down by file type. Source: tools/bench_cli.sh, data: results.json.',
        11.5, { color = col.muted })
    y = y + 14

    return string.format('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d" font-family="%s">\n'
        .. '<title>Performance comparison: lexiftool and Perl ExifTool</title>\n%s\n</svg>\n',
        W, y, W, y, font, table.concat(parts, '\n'))
end
writeFile('benchmark.svg', svg('light'))
writeFile('benchmark-dark.svg', svg('dark'))

-- JSON ----------------------------------------------------------------------------

local function jstr(s)
    return '"' .. tostring(s):gsub('[%c"\\]', function(c) return string.format('\\u%04x', c:byte()) end) .. '"'
end
local function jnum(v)
    if v == nil then return 'null' end
    return string.format('%.6g', v)
end
local j = { '{\n  "meta": {' }
local keys = {}
for k in pairs(meta) do keys[#keys + 1] = k end
table.sort(keys)
for i, k in ipairs(keys) do
    j[#j + 1] = string.format('    %s: %s%s', jstr(k), jstr(meta[k]), i < #keys and ',' or '')
end
j[#j + 1] = '  },\n  "mix": ['
for i, m in ipairs(mix) do
    local function tool(t)
        return string.format('{ "single": %s, "processing": %s, "module_loading": %s, "rss_kb": %s }',
            jnum(t.single), jnum(t.proc), jnum(t.load), jnum(t.rss))
    end
    j[#j + 1] = string.format('    { "type": %s, "description": %s, "exiftool": %s, "lexiftool": %s }%s',
        jstr(m.type), jstr(m.desc), tool(m.exiftool), tool(m.lexiftool), i < #mix and ',' or '')
end
if writeParts then
    j[#j] = j[#j] .. ','
    j[#j + 1] = string.format('    { "type": "write", "description": %s, "exiftool": { "single": %s, "processing": %s, "module_loading": %s, "rss_kb": %s }, "lexiftool": { "single": %s, "processing": %s, "module_loading": %s, "rss_kb": %s } }',
        jstr(write.desc), jnum(writeParts.exiftool.single), jnum(writeParts.exiftool.proc), jnum(writeParts.exiftool.load), jnum(writeParts.exiftool.rss),
        jnum(writeParts.lexiftool.single), jnum(writeParts.lexiftool.proc), jnum(writeParts.lexiftool.load), jnum(writeParts.lexiftool.rss))
end
j[#j + 1] = '  ],\n  "cases": ['
for i, c in ipairs(cases) do
    local function tool(t)
        return string.format('{ "mean": %s, "min": %s, "stddev": %s, "user": %s, "system": %s, "rss_kb": %s%s }',
            jnum(t.mean), jnum(t.min), jnum(t.stddev), jnum(t.user), jnum(t.system), jnum(t.rss),
            t.filesPerSecond and (', "files_per_second": ' .. jnum(t.filesPerSecond)) or '')
    end
    j[#j + 1] = string.format('    { "name": %s, "description": %s, "args": %s,\n      "exiftool": %s,\n      "lexiftool": %s }%s',
        jstr(c.name), jstr(c.desc), jstr(c.args), tool(c.exiftool), tool(c.lexiftool), i < #cases and ',' or '')
end
j[#j + 1] = '  ]\n}'
writeFile('results.json', table.concat(j, '\n') .. '\n')

print(string.format('bench_report.lua: %d cases, mix of %d file types -> %s', #cases, #mix, outdir))
