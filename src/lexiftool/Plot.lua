--------------------------------------------------------------------------------
-- File:         lexiftool/Plot.lua
-- Ported from:  lib/Image/ExifTool/Plot.pm
--
-- Description:  Plot tag values in SVG format
--
-- Revisions:    2025-02-14 - P. Harvey Created
--
-- Port notes:   complete.  Two Perl idioms need naming here because they recur
--               throughout:  Perl's `int()` truncates toward zero (Lua's
--               math.floor() rounds down), and a number interpolated into a
--               string uses %.15g with no trailing ".0" -- ExifTool.NumStr does
--               that, and every coordinate that reaches the SVG goes through
--               it.  The data arrays are 0-based like the Perl ones and may
--               have holes, so each carries its own `n` (Perl's `$#array`)
--               instead of relying on Lua's `#`.  Perl's own drand48 is
--               reimplemented here (see the comment at `srand` below) because
--               the colour generator seeds it with a fixed value, so its
--               output is part of the file format, not noise.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local perl = require('lexiftool.perl')
local sprintf = perl.sprintf
local str = perl.str
local lc = perl.lc

local Plot = {}
Plot.__index = Plot

local NumStr = ExifTool.NumStr

-- Perl's int(): truncate toward zero
local function int(x)
    return x >= 0 and math.floor(x) or -math.floor(-x)
end

-- default plot settings (lower-case settings may be overridden by the user)
local defaults = {
    size   = { 800, 600 },         -- width,height of output image
    margin = { 60, 15, 15, 30 },   -- left,top,right,bottom margins around plot area
    legend = { 0, 0 },             -- top,right offset for legend
    txtpad = { 10, 10 },           -- padding between text and x,y scale
    linespacing = 20,              -- text line spacing
    -- colours for plot lines
    cols   = { 'red', 'green', 'blue', 'black', 'orange', 'gray', 'fuchsia', 'brown', 'turquoise', 'gold',
               'lime', 'violet', 'maroon', 'aqua', 'navy', 'pink', 'olive', 'indigo', 'silver', 'teal' },
    marks  = { 'circle', 'square', 'triangle', 'diamond', 'star', 'plus', 'pentagon', 'left', 'down', 'right' },
    stroke = 1,                    -- stroke width and marker scaling
    grid   = 'darkgray',           -- grid colour
    text   = 'black',              -- text and plot frame colour
    type   = 'line',               -- plot type, 'line' or 'scatter'
    style  = '',                   -- 'line', 'marker' or 'line+marker'
    xlabel = '',                   -- x axis label
    ylabel = '',                   -- y axis label
    title  = '',                   -- plot title
    nbins  = 20,                   -- number of histogram bins
    -- xmin, xmax                  -- x axis minimum,maximum
    -- ymin, ymax                  -- y axis minimum,maximum
    -- split                       -- split list of numbers into separate plot lines
    -- bkg                         -- background colour
    -- multi                       -- flag to make one plot per dataset
--
-- members containing capital letters are used internally
--
    Data   = { },                  -- data arrays for each variable
    Name   = { },                  -- variable names
    -- XMin, XMax                  -- min/max data index
    -- YMin, YMax                  -- min/max data value
    -- SaveName, Save              -- saved variables between plots
}

local markerData = {
    circle   = '<circle cx="4" cy="4" r="2.667"',
    square   = '<path d="M1.667 1.667 l4.667 0 0 4.667 -4.667 0 z"',
    triangle = '<path d="M4 0.8 l2.667 5.333 -5.333 0 z"',
    diamond  = '<path d="M4 1 l3 3 -3 3 -3 -3 z"',
    star     = '<path d="M4 0.8 L5 2.625 7.043 3.011 5.617 4.525 5.881 6.589 4 5.7 2.119 6.589 2.383 4.525 0.957 3.011 3 2.625 z"',
    plus     = '<path d="M2.75 1 l2.5 0 0 1.75 1.75 0 0 2.5 -1.75 0 0 1.75 -2.5 0 0 -1.75 -1.75 0 0 -2.5 1.75 0 z"',
    pentagon = '<path d="M4 1 L6.853 3.073 5.763 6.427 2.237 6.427 1.147 3.073 z"',
    left     = '<path d="M0.8 4 l5.333 2.667 0 -5.333 z"',
    down     = '<path d="M4 7.2 l2.667 -5.333 -5.333 0 z"',
    right    = '<path d="M7.2 4 l-5.333 2.667 0 -5.333 z"',
}

-- Perl's own `rand`, needed because Draw() below seeds it with a FIXED value
-- (srand(141)) and so produces the same colours on every run -- these are not
-- random numbers in any meaningful sense, they are a cheap deterministic
-- colour generator, and the port has to reproduce the exact sequence.
-- Perl uses its bundled drand48 (`perl -V:randfunc` says Perl_drand48):
--   state = 0x330e + (seed << 16)
--   state = (0x5deece66d * state + 0xb) mod 2^48;  value = (state >> 15) / 2^33
-- (the multiply overflows 64 bits, but Lua wraps modulo 2^64 and the low 48
--  bits -- the only ones the mask keeps -- come out the same)
local drand48State
local function srand(seed)
    drand48State = 0x330e | (seed << 16)
end
local function rand(n)
    drand48State = (0x5deece66d * drand48State + 0xb) & 0xffffffffffff
    return (drand48State >> 15) / 2 ^ 33 * n
end

local ng = { 20, 15 }  -- optimal number grid lines in X and Y for a 800x600 plot
local wch = 8          -- nominal width of a character (measured at 7.92)

--------------------------------------------------------------------------------
-- Create new plot object
--------------------------------------------------------------------------------
function Plot.new()
    local self = setmetatable({ }, Plot)
    for k, v in pairs(defaults) do
        if type(v) == 'table' then
            local copy = { }
            for k2, v2 in pairs(v) do copy[k2] = v2 end
            self[k] = copy
        else
            self[k] = v
        end
    end
    return self
end

--------------------------------------------------------------------------------
-- Set plot settings
-- Inputs: 0) Plot ref, 1) comma-separated options
--------------------------------------------------------------------------------
function Plot:Settings(set)
    if not set or set == '' then return end
    for _, item in ipairs(perl.split([[,\s*]], set)) do
        local name, val = perl.matches(item, [[(?i)^([a-z].*?)(?:=(.*))?$]])
        if name then
            name = lc(name)
            if type(self[name]) == 'table' then
                if val ~= nil then
                    local isNum = str(self[name][1]):match('^%d+$') ~= nil
                    -- also allow numbers to also be separated by 'x'
                    local vals = perl.splitDyn(isNum and [[\s*[x\s/+]\s*]] or [[\s*[\s/+]\s*]], val)
                    local i = 0
                    while #vals > 0 do
                        local v = lc(table.remove(vals, 1))
                        if #v > 0 then
                            if name == 'marks' then
                                local m = perl.split('-', v)
                                if m[1] and m[1] ~= '' then
                                    if m[1]:sub(1, 1) == 'n' then
                                        m[1] = 'none'
                                    else
                                        local found
                                        for _, d in ipairs(defaults.marks) do
                                            if d:sub(1, #m[1]) == m[1] then found = d break end
                                        end
                                        m[1] = found
                                        if not m[1] then self.Warn = 'Invalid marker name' end
                                    end
                                else
                                    -- cycle through default markers if none specified
                                    m[1] = defaults.marks[(i % #defaults.marks) + 1]
                                end
                                if m[1] then v = table.concat(m, '-') else v = nil end
                            end
                            if v then self[name][i + 1] = v end
                        end
                        i = i + 1
                    end
                end
            else
                if val == nil then val = 1 end   -- default to 1 if no "="
                local charName = { ['&'] = 'amp', ['<'] = 'lt', ['>'] = 'gt' }
                -- escape necessary XML characters, but allow numerical entities
                local n
                val, n = str(val):gsub('[&><]', function(c) return '&' .. charName[c] .. ';' end)
                if n > 0 then
                    val = perl.subst(val, [[&amp;(#(\d+|x[0-9a-fA-F]+);)]], '&$1')
                end
                if #val == 0 then val = nil end
                self[name] = val
            end
        end
    end
end

--------------------------------------------------------------------------------
-- Add points to SVG plot
-- Inputs: 0) Plot object ref, 1) tag value hash ref, 2) tag ID list ref
--------------------------------------------------------------------------------
-- (the number pattern upstream applies to every candidate value)
local NUMPAT = [[^[+-]?(?=\.?\d)\d*\.?\d*(?:e[+-]?\d+)?$]]
local NUMSEP = [[(?i)^[+-]?(?=\.?\d)\d*\.?\d*(?:e[+-]?\d+)?([ ,;\t\n\r]+|$)]]

function Plot:AddPoints(info, tags)
    local tag, name, index, mod, val
    local num, vals = { }, { }
    local ee, docNumTbl, data = self.EE, self.DocNum, self.Data
    local xmin, xmax = self.XMin, self.XMax
    if not self.type then self.type = 'line' end
    local scat = self.type:sub(1, 1) == 's' and 1 or 0
    local xname = self.Name[1]      -- (x-axis name if using scatter plot)
    local maxLines = (self.type:sub(1, 1) == 'h' and not self.multi) and 1 or 20
    while true do
        local skip = false
        if #vals > 0 then
            val = table.remove(vals, 1)
            if not perl.matches(str(val), NUMPAT) then goto continue end
        else
            tag = table.remove(tags, 1)
            if not tag then break end
            -- ignore non-floating-point values
            val = info[tag]
            name = str(tag):match('^([^ \t\n\r\f\v]+)')    -- remove index number
            if type(val) == 'table' then
                if val.ref == 'SCALAR' then
                    val = val.value     -- handle binary values
                elseif val[1] ~= nil or next(val) == nil then
                    index = index and index + 1 or 0
                    local v = val[index + 1]
                    if v == nil then index, mod = nil, nil goto continue end
                    val = v
                    name = name .. (mod and ('[' .. (index % mod) .. ']') or ('[' .. index .. ']'))
                    table.insert(tags, 1, tag)      -- will continue with this tag later
                else
                    goto continue
                end
            end
        end
        if val == nil then goto continue end
        do
            local sep = perl.matches(str(val), NUMSEP)
            if sep == nil then goto continue end
            if sep ~= '' then
                -- split a string of numbers into separate plot points (eg. histogram tags)
                if self['split'] then
                    -- make an array
                    info[tag] = perl.split([[[ ,;\t\n\r][\n\r]? *]], str(val))
                    table.insert(tags, 1, tag)
                    -- split into lists of 'split' elements if split > 1
                    if tonumber(self['split']) and tonumber(self['split']) > 1 then
                        mod = tonumber(self['split'])
                    end
                    goto continue
                else
                    vals = perl.split([[[ ,;\t\n\r][\n\r]? *]], str(val))
                    val = table.remove(vals, 1)
                end
            end
        end
        val = tonumber(val)
        do
            local docNum = docNumTbl and (docNumTbl[tag] or 0) or 0
            if docNum ~= 0 and not ee then goto continue end
            if not data[name] then
                if #self.Name >= maxLines + scat then
                    if not self.MaxTags then
                        if self.type:sub(1, 1) == 'h' and not self.multi then
                            self.Warn = 'Use the Multi setting to make a separate histogram for each dataset'
                        else
                            self.Warn = 'Too many variables to plot all of them'
                        end
                        self.MaxTags = 1
                    end
                    goto continue
                end
                self.Name[#self.Name + 1] = name
                if not xname then xname = name end  -- x-axis data for scatter plot
                if not (scat == 1 and name == xname) then
                    if self.Max == nil or val > self.Max then self.Max = val end
                    if self.Min == nil or val < self.Min then self.Min = val end
                end
                if xmin == nil then xmin, xmax = docNum, docNum end
                num[name] = xmax
                if xmax >= xmin then
                    data[name] = { n = -1 }
                    data[name][xmax - xmin] = val
                    if xmax - xmin > data[name].n then data[name].n = xmax - xmin end
                end
                goto continue
            end
            if docNum ~= 0 and num[name] and num[name] < docNum then
                num[name] = docNum  -- keep documents synchronized if some tags are missing
            else
                if num[name] == nil then num[name] = xmax end
                num[name] = num[name] + 1
            end
            if num[name] >= xmin then
                local d = data[name]
                d[num[name] - xmin] = val
                if num[name] - xmin > d.n then d.n = num[name] - xmin end
            end
            if not (scat == 1 and name == xname) then
                if val > self.Max then self.Max = val end
                if val < self.Min then self.Min = val end
            end
        end
        ::continue::
        if skip then break end
    end
    -- start next file at x value so far
    for k in pairs(num) do
        if xmax == nil or xmax < num[k] then xmax = num[k] end
    end
    self.XMin = xmin
    self.XMax = xmax
end

--------------------------------------------------------------------------------
-- Calculate a nice round number for grid spacing
-- Inputs: 0) nominal spacing (must be positive), 1) flag to increment to next number
-- Returns: spacing rounded to an even number
--------------------------------------------------------------------------------
local function GetGridSpacing(nom, inc)
    local div = sprintf('%.3e', nom)
    local num = tonumber(div:sub(1, 1))
    local exp = tonumber(div:match('e(.*)$')) or 0
    if inc then
        -- increment to next highest even number
        if num < 2 then num = 2 elseif num < 5 then num = 5 else exp = exp + 1 num = 1 end
    else
        -- look for nearest factor to 1, 2 or 5 * 10^x
        if num > 2 then
            if num < 8 then num = 5 else exp = exp + 1 num = 1 end
        end
    end
    if exp >= 0 then
        return tonumber(num .. string.rep('0', exp))
    end
    return tonumber('.' .. string.rep('0', -exp - 1) .. num)
end
Plot.GetGridSpacing = GetGridSpacing

--------------------------------------------------------------------------------
-- Get plot range
-- Inputs: 0) minimum, 1) maximum
-- Returns: difference, and the (possibly adjusted) minimum and maximum
-- Notes: Adjusts min/max if necessary to make difference positive
--        (upstream modifies its arguments in place; Lua returns them)
--------------------------------------------------------------------------------
local function GetRange(a, b)
    if a >= b then
        a = (a + b) / 2
        if a ~= 0 then a = a - 0.5 end
        b = a + 1
    end
    return b - a, a, b
end
Plot.GetRange = GetRange

--------------------------------------------------------------------------------
-- Draw SVG plot
-- Inputs: 0) Plot ref, 1) Output file reference
--------------------------------------------------------------------------------
-- Perl's @margin/@size are 0-based (left,top,right,bottom / width,height); the
-- Lua tables are 1-based, so every index below is the upstream one plus 1.
function Plot:Draw(fp)
    local function out(...)
        local parts = { }
        for i = 1, select('#', ...) do
            local v = select(i, ...)
            parts[#parts + 1] = type(v) == 'number' and NumStr(v) or str(v)
        end
        fp:write(table.concat(parts))
    end

    local min, max = self.Min, self.Max
    local xmin, xmax = self.XMin, self.XMax
    local name, style = self.Name, self.style
    local multiMulti

    if min == nil or xmin == nil then
        self.Error = 'Nothing to plot'
        return
    end
    local scat = self.type:sub(1, 1) == 's' and 1 or 0
    local hist = self.type:sub(1, 1) == 'h' and { } or nil
    local multi = self.multi or 0
    local multiList = { }
    for d in str(multi):gmatch('%d+') do multiList[#multiList + 1] = tonumber(d) end
    local names = { }
    for i = 1, #name do names[i] = name[i] end
    if scat == 1 then table.remove(names, 1) end
    multi = table.remove(multiList, 1) or 0
    if multi <= 0 then multi = 0 end
    if not style or style == '' then style = hist and 'line+fill' or 'line' end
    if not (perl.matches(style, [==[\b[mpl]]==]) or (hist and perl.matches(style, [[\bf]]))) then
        self.Error = 'Invalid plot Style setting'
        return
    end
    local numPlots = 0
    if multi ~= 0 then
        local n = 0
        while n < #name - scat do
            n = n + (multiList[numPlots + 1] or 1)
            if multiList[numPlots + 1] and multiList[numPlots + 1] > 1 then multiMulti = 1 end
            numPlots = numPlots + 1
        end
    else
        numPlots = 1
    end
    local size = { self.size[1], self.size[2] }
    local sy = size[2]
    if multi ~= 0 then
        sy = sy * int((numPlots + multi - 1) / multi) / multi
        size[1] = size[1] / multi
        size[2] = size[2] / multi
    end
    local tmp = self.title
    if not tmp or tmp == '' then tmp = 'Plot by ExifTool ' .. ExifTool.VERSION end
    out('<?xml version="1.0" standalone="no"?>\n' ..
        '<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 20010904//EN" "http://www.w3.org/TR/2001/REC-SVG-20010904/DTD/svg10.dtd">\n' ..
        '<svg version="1.1" xmlns="http://www.w3.org/2000/svg" width="', self.size[1], '" height="', sy, '"\n' ..
        ' preserveAspectRatio="xMidYMid meet" viewBox="0 0 ', self.size[1], ' ', sy, '">\n' ..
        '<title>', tmp, '</title>')
  -- loop through all plots
  for plotNum = 0, numPlots - 1 do
    local col, class, markID = { }, { }, { }
    local dx, dy, dx2, xAxis, x, y, px, py
    local og = { }
    local noLegend, xname, xdat, xdiff, diff
    if numPlots > 1 then
        out("\n<g transform='translate(", (plotNum % multi) * size[1],
            ',', int(plotNum / multi) * size[2], ")'>")
        if plotNum ~= 0 then
            self.XMin, self.XMax, self.title, self.xlabel, self.ylabel =
                self.Save[1], self.Save[2], self.Save[3], self.Save[4], self.Save[5]
        else
            self.Save = { self.XMin, self.XMax, self.title, self.xlabel, self.ylabel }
            self.SaveName = { }
            for i = 1, #self.Name do self.SaveName[i] = self.Name[i] end
        end
        self.Name = { }
        name = self.Name
        if scat == 1 then self.Name[#self.Name + 1] = self.SaveName[1] end
        for _ = 1, (multiList[plotNum + 1] or 1) do
            self.Name[#self.Name + 1] = table.remove(names, 1)
        end
        min, max = nil, nil
        for i = scat + 1, #self.Name do
            local dat = self.Data[self.Name[i]]
            if dat then
                for j = 0, dat.n do
                    local v = dat[j]
                    if v ~= nil then
                        if min == nil then min, max = v, v
                        else
                            if min > v then min = v end
                            if max < v then max = v end
                        end
                    end
                end
            end
        end
        xmin, xmax = self.XMin, self.XMax
    end
    local data, title, xlabel, ylabel = self.Data, self.title, self.xlabel, self.ylabel
    local cols, marks, tpad, wid = self.cols, self.marks, self.txtpad, self.stroke
    local nm = { }
    for i = 1, #name do nm[i] = name[i] end
    local margin = { self.margin[1], self.margin[2], self.margin[3], self.margin[4] }

    -- set reasonable default titles and labels
    if scat == 1 then xname = table.remove(nm, 1) end
    if scat == 1 and title ~= nil and title == '' and #nm == 1 and multi == 0 then
        title = nm[1] .. ' vs ' .. xname
    end
    if (scat == 1 or hist) and xlabel ~= nil and xlabel == '' then
        xlabel = name[1]
        if hist then noLegend = 1 end
    end
    if ylabel ~= nil and ylabel == '' and #nm == 1 and not multiMulti then
        ylabel = hist and 'Count' or nm[1]
        if not hist then noLegend = 1 end
    end

    -- make room for title/labels
    if title and title ~= '' then margin[2] = margin[2] + self.linespacing * 1.5 end
    if xlabel and xlabel ~= '' then margin[4] = margin[4] + self.linespacing end
    if ylabel and ylabel ~= '' then margin[1] = margin[1] + self.linespacing end

    -- calculate optimal number of X/Y grid lines
    for i = 1, 2 do
        og[i] = ng[i] * (size[i] - margin[i] - margin[i + 2]) /
                    (defaults.size[i] - defaults.margin[i] - defaults.margin[i + 2])
        if og[i] <= 0 then self.Error = 'Invalid plot size' return end
    end
    if scat == 1 then
        xdat = self.Data[xname]
        if not (self.xmin ~= nil and self.xmax ~= nil) then
            local set
            for i = 0, xdat.n do
                local v = xdat[i]
                if v ~= nil then
                    if not set then xmin, xmax, set = v, v, true
                    else
                        if xmin > v then xmin = v end
                        if xmax < v then xmax = v end
                    end
                end
            end
            local dnx2 = (xmax - xmin) / (og[1] * 2)
            -- leave a bit of a left/right margin, but don't pass 0
            xmin = (xmin >= 0 and xmin < dnx2) and 0 or xmin - dnx2
            xmax = (xmax <= 0 and -xmax < dnx2) and 0 or xmax + dnx2
        end
        if self.xmin ~= nil then xmin = tonumber(self.xmin) end
        if self.xmax ~= nil then xmax = tonumber(self.xmax) end
    else
        -- shift x range to correspond with index in data list
        xmax = xmax - xmin
        xmin = 0
    end
    if hist then
        -- (Settings stores every scalar as a string; Perl compares it
        --  numerically without fuss, Lua needs the conversion said out loud)
        local nbins = tonumber(self.nbins) or 0
        if nbins <= 0 then self.Error = 'Invalid number of histogram bins' return end
        noLegend = 1
        -- y axis becomes histogram x axis after binning
        if self.xmin ~= nil then min = tonumber(self.xmin) end
        if self.xmax ~= nil then max = tonumber(self.xmax) end
    else
        -- leave a bit of a margin above/below data when autoscaling but don't pass 0
        local dny2 = (max - min) / (og[2] * 2)
        min = (min >= 0 and min < dny2) and 0 or min - dny2
        max = (max <= 0 and -max < dny2) and 0 or max + dny2
        -- adjust to user-defined range if specified
        if self.ymin ~= nil then min = tonumber(self.ymin) end
        if self.ymax ~= nil then max = tonumber(self.ymax) end
    end
    -- generate random colors if we need more
    while #cols < #name do
        if not self.seeded then srand(141) self.seeded = 1 end
        cols[#cols + 1] = sprintf('#%.2x%.2x%.2x',
            int(rand(220)), int(rand(220)), int(rand(220)))
    end
    diff, min, max = GetRange(min, max)
    xdiff, xmin, xmax = GetRange(xmin, xmax)

    -- determine y grid spacing (nice even numbers)
    dy = GetGridSpacing(diff / (hist and tonumber(self.nbins) or og[2]))
    -- expand plot min/max to the nearest even multiple of our grid spacing
    min = (min > 0 and int(min / dy) or int(min / dy - 0.9999)) * dy
    max = (max > 0 and int(max / dy + 0.9999) or int(max / dy)) * dy

    -- bin histogram
    if hist then
        local dat = data[nm[1]]
        local nmax = int((max - min) / dy + 0.5)
        for i = 0, nmax - 1 do hist[i] = 0 end
        hist.n = nmax - 1
        for i = 0, dat.n do
            local v = dat[i]
            if v ~= nil then
                local n = (v - min) / dy
                if not (n < 0 or n > nmax + 0.00001) then
                    n = int(n)
                    local k = n < nmax and n or nmax - 1
                    hist[k] = hist[k] + 1
                end
            end
        end
        xmin, xmax, min, max = min, max, 0, 0
        -- (Perl's `if ($$self{ymax})` is FALSE for the string "0"; Lua's
        --  truthiness is not, hence perlTruthy)
        if ExifTool.perlTruthy(self.ymax) then
            max = tonumber(self.ymax)
        else
            for i = 0, hist.n do if max < hist[i] then max = hist[i] end end
        end
        diff, min, max = GetRange(min, max)
        dx = dy
        dy = GetGridSpacing(diff / og[2])
        max = (max > 0 and int(max / dy + 0.9999) or int(max / dy)) * dy
        data[nm[1]] = hist
    else
        dx = GetGridSpacing(xdiff / og[1])
    end
    if scat == 1 then
        xmin = (xmin > 0 and int(xmin / dx) or int(xmin / dx - 0.9999)) * dx
        xmax = (xmax > 0 and int(xmax / dx + 0.9999) or int(xmax / dx)) * dx
    end
    diff, min, max = GetRange(min, max)
    xdiff, xmin, xmax = GetRange(xmin, xmax)
    -- width/height of plot area
    local width  = size[1] - margin[1] - margin[3]
    local height = size[2] - margin[2] - margin[4]
    local yscl = height / diff
    local xscl = width / xdiff
    local px0 = margin[1] - xmin * xscl
    local py0 = margin[2] + height + min * yscl
    local clip = { margin[1] - 6 * wid, margin[2] - 6 * wid, width + 12 * wid, height + 12 * wid }
    out("\n<!-- Definitions -->\n<defs>\n<clipPath id='plot-area'>")
    out("<rect x='", clip[1], "' y='", clip[2], "' width='", clip[3], "' height='", clip[4], "'/></clipPath>")
    if perl.matches(style, [==[\b[mp]]==]) then -- 'm' for 'marker' or 'p' for 'point' (undocumented)
        for i = 1, #nm do
            local m = perl.split('-', marks[i] or defaults.marks[((i - 1) % #defaults.marks) + 1])
            local fill, mark
            local wantFill = (m[2] and m[2] ~= '') and m[2]:sub(1, 1) == 'f' or
                             ((not m[2] or m[2] == '') and perl.matches(style, [[\bf]]) ~= nil)
            if wantFill then fill = (m[3] and m[3] ~= '') and m[3] or cols[i] end
            mark = markerData[m[1]]
            if not mark then
                markID[''] = ''             -- skip 'none' or unrecognized marker name
            else
                if fill and fill ~= 'none' then
                    local op = (m[4] and m[4] ~= '') and m[4] or (cols[i] == 'none' and 50 or 20)
                    mark = mark .. ' fill="' .. fill .. '" style="fill-opacity: ' .. NumStr(tonumber(op) or op) .. '%"'
                else
                    mark = mark .. ' fill="none"'
                end
                -- (was using 'context-stroke', but Chrome didn't show this properly)
                mark = mark .. " stroke='" .. cols[i] .. "'/>"
                -- don't re-define mark if it is the same as a previous one
                if markID[mark] then
                    markID[i] = markID[mark]
                else
                    markID[mark] = 'mark' .. (i - 1)
                    markID[i] = markID[mark]
                    out("\n<marker id='", markID[i], "' markerWidth='8' markerHeight='8' refX='4'",
                        " refY='4'>\n", mark, "\n</marker>")
                end
            end
        end
        out("\n</defs>\n<style>")
        for i = 1, #nm do
            if markID[i] == 'mark' .. (i - 1) then
                out("\n  path.mark", i - 1, " { marker: url(#mark", i - 1, ") }")
            end
        end
    else
        out("\n</defs>\n<style>")
    end
    out("\n  text { fill: ", self.text, " }\n</style>")
    if self.bkg then
        out("\n<rect x='0' y='0' width='", size[1], "' height='", size[2], "' fill='", self.bkg, "'/>")
    end
    out("\n<!-- X axis -->")
    out("\n<g dominant-baseline='hanging' text-anchor='middle'>")
    py = int((margin[2] + height + tpad[2]) * 10 + 0.5) / 10
    px = int((margin[1] + width / 2) * 10 + 0.5) / 10
    if title and title ~= '' then
        out("\n<text x='", px, "' y='14' font-size='150%'>", title, "</text>")
    end
    if xlabel and xlabel ~= '' then
        y = py + self.linespacing
        out("\n<text x='", px, "' y='", y, "'>", xlabel, "</text>")
    end
    if ylabel and ylabel ~= '' then
        y = margin[2] + height / 2
        out("\n<text x='10' y='", y, "' transform='rotate(-90,10,", y, ")'>", ylabel, "</text>")
    end
    -- make sure the X labels will fit
    local spc = dx
    while true do
        -- find longest label at current spacing
        local len = 0
        local x0 = int(xmax / spc + 0.5) * spc      -- get value of last x label
        local xv = x0
        for _ = 1, 3 do
            local n = #sprintf('%g', xv)
            if len < n then len = n end
            xv = xv - spc
        end
        if spc >= (len + 1) * wch * xdiff / width then break end
        -- increase label spacing by one increment and try again
        spc = GetGridSpacing(spc, true)
        dx2 = spc
    end
    local grid, lastLen = '', 0
    x = int(xmin / dx - 1) * dx
    while true do
        px = int((margin[1] + (x - xmin) * width / xdiff) * 10 + 0.5) / 10
        if px > margin[1] + width + 0.5 then break end
        if px >= margin[1] - 0.5 then
            local h = height
            if not dx2 or math.abs(x / dx2 - int(x / dx2 + (x > 0 and 0.5 or -0.5))) < 0.01 then
                out("\n<text x='", px, "' y='", py, "'>", sprintf('%g', x), "</text>")
                h = h + tpad[2] / 2
            end
            if #grid - lastLen > 80 then grid = grid .. '\n' lastLen = #grid end
            grid = grid .. 'M' .. NumStr(px) .. ' ' .. NumStr(margin[2]) .. ' v' .. NumStr(h) .. ' '
        end
        x = x + dx
    end
    out("\n<path stroke='", self.grid, "' stroke-width='0.5' d='\n", grid, "'/>")
    out("\n</g>\n<!-- Y axis -->\n<g dominant-baseline='middle' text-anchor='end'>")
    px = int((margin[1] - tpad[1]) * 10 + 0.5) / 10
    grid, lastLen = '', 0
    local gx, gw = margin[1] - tpad[1] / 2, width + tpad[1] / 2
    y = min
    while true do
        py = int((margin[2] + height - (y - min) * yscl) * 10 + 0.5) / 10
        if py < margin[2] - 0.5 then break end
        if y < dy / 2 and y > -dy / 2 then y = 0 end    -- (avoid round-off errors)
        out("\n<text x='", px, "' y='", py, "'>", sprintf('%g', y), "</text>")
        if y < dy / 2 and y > -dy / 2 then xAxis = 1 end -- redraw x axis later
        if #grid - lastLen > 80 then grid = grid .. '\n' lastLen = #grid end
        grid = grid .. 'M' .. NumStr(gx) .. ' ' .. NumStr(py) .. ' h' .. NumStr(gw) .. ' '
        y = y + dy
    end
    if xAxis and min ~= 0 then
        py = margin[2] + height + min * yscl
        out("\n<path stroke='", self.text, "' d='M", margin[1], ' ', py, ' h', width, "'/>")
    end
    out("\n<path stroke='", self.grid, "' stroke-width='0.5' d='\n", grid, "'/>")
    out("\n</g>\n<!-- Plot box and legend -->\n<g dominant-baseline='middle' text-anchor='start'>")
    out("\n<path stroke='", self.text, "' fill='none' d='M", margin[1], ' ', margin[2],
        ' l0 ', height, ' ', width, ' 0 0 -', height, " z'/>")
    if not noLegend then
        for i = 1, #nm do
            x = size[1] - margin[3] - 175 + self.legend[1]
            y = margin[2] + self.legend[2] + 15 + self.linespacing * ((i - 1) + 0.5)
            local c = cols[i]
            local mark = markID[i] and (" marker-end='url(#" .. markID[i] .. ")' fill='none'") or ''
            local line = perl.matches(style, [[\bl]]) and ' l-20 0' or sprintf(' m%.4g 0', -5 * wid)
            local sw = (perl.matches(style, [[\bm]]) and 1.5 or 2) * wid
            out("\n<path", mark, " stroke-width='", sw, "' stroke='", c, "' d='M", x, ' ', y, ' m-7 -1', line, "'/>")
            out("\n<text x='", x, "' y='", y, "'>", nm[i], "</text>")
        end
    end
    -- print the data
    for i = 1, #nm do
        col[nm[i]] = cols[i]
        class[nm[i]] = markID[i] and (" class='" .. markID[i] .. "'") or ''
    end
    local i0, i1, xsclr
    local fill = ''
    if scat == 1 then
        i0, i1 = 0, xdat.n
    elseif hist then
        i0, i1 = 0, hist.n
        xscl = width / (hist.n + 1)
        px0 = margin[1]
        xsclr = int(xscl * 100 + 0.5) / 100
        if perl.matches(style, [[\bf]]) then
            local m = perl.split('-', marks[1])
            local op = (m[4] and m[4] ~= '') and m[4] or (perl.matches(style, [[\bl]]) and 20 or 50)
            fill = " fill='" .. cols[1] .. "'"
            if cols[1] ~= 'none' then
                fill = fill .. " style='fill-opacity: " .. NumStr(tonumber(op) or op) .. "%'"
            end
        end
    else
        i0 = int(xmin) - 1
        if i0 < 0 then i0 = 0 end
        i1 = int(xmax) + 1
    end
    out("\n</g>\n<!-- Datasets -->\n<g fill='none' clip-path='url(#plot-area)'",
        " stroke-linejoin='round' stroke-linecap='round' stroke-width='", 1.5 * wid, "'>")
    local doLines = perl.matches(style, [[\bl]]) ~= nil
    for _, n in ipairs(nm) do
        local stroke = (hist and not doLines) and 'none' or col[n]
        local dat = data[n]
        out("\n<!-- ", n, " -->")
        out("\n<path", class[n], fill, " stroke='", stroke, "' d='")
        if doLines then out('M') end
        local m = doLines and '' or ' M'
        for i = i0, i1 do
            local v = dat and dat[i]
            if v ~= nil then
                y = int((py0 - v * yscl) * 10 + 0.5) / 10
                local skip = false
                if scat == 1 then
                    if xdat[i] == nil then skip = true
                    else x = int((px0 + xdat[i] * xscl) * 10 + 0.5) / 10 end
                else
                    x = int((px0 + i * xscl) * 10 + 0.5) / 10
                    if hist then
                        out(m, (i % 5 ~= 0) and ' ' or '\n', x, ' ', y, ' h', xsclr)
                        m = ' L'    -- (draw lines after the first point)
                        skip = true
                    end
                end
                if not skip then
                    out(m, (i % 10 ~= 0) and ' ' or '\n', x, ' ', y)
                end
            end
        end
        if hist and fill ~= '' then
            out(' V', margin[2] + height, ' H', margin[1], ' z')
        end
        out("'/>")
    end
    out("\n</g>")
    if numPlots > 1 then out("\n</g>") end
  end
  out("</svg>\n")
end

return Plot
