--------------------------------------------------------------------------------
-- File:         lexiftool/Plot.lua
-- Ported from:  lib/Image/ExifTool/Plot.pm
--
-- Description:  Plot tag values in SVG format
--
-- Revisions:    2025-02-14 - P. Harvey Created
--
-- Port notes:   complete.  The settings lists (size, margin, legend, txtpad,
--               cols, marks) are 1-based Lua lists, so `$size[$i]` is
--               `size[i + 1]`; the data arrays are 0-based like the Perl ones
--               and may have holes, so each carries its own `n` (Perl's
--               `$#array`).  Tag values and settings stay the strings Perl
--               keeps (GetGridSpacing returns one too); arithmetic on them
--               goes through the facade's Perl numification, and an order
--               comparison of two of them through perl.num.  GetRange
--               returns the difference and the adjusted minimum and maximum
--               (upstream modifies its arguments in place).  srand/rand are
--               the facade's (perl.srand/perl.rand, Perl's own drand48): the
--               colour generator seeds it with a fixed value, so its output
--               is part of the file format, not noise.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local perl = require('lexiftool.perl')
local sprintf = perl.sprintf
local perlStr = perl.str
local lc = perl.lc
local srand = perl.srand
local rand = perl.rand
local int, num = perl.int, perl.num
local matches, isMatch, findAll = perl.matches, perl.isMatch, perl.findAll
local subst, substN = perl.subst, perl.substN
local split, join = perl.split, perl.join
local shift, unshift, push = perl.shift, perl.unshift, perl.push
local length, substr = perl.length, perl.substr
local ref = perl.ref
local print, printf = perl.print, perl.printf
local perlTruthy = perl.truthy

local Plot = {}
Plot.__index = Plot

-- (port: `$arr[$i] = $val` on one of the 0-based data arrays, keeping its
--  `n` -- Perl's `$#arr` -- up to date; the array is created if necessary,
--  as Perl autovivifies `$$data{$name}[$i]`)
local function aset(h, k, i, v)
    local a = h[k]
    if a == nil then a = { n = -1 } h[k] = a end
    a[i] = v
    if i > a.n then a.n = i end
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

local ng = { 20, 15 }  -- optimal number grid lines in X and Y for a 800x600 plot
local wch = 8          -- nominal width of a character (measured at 7.92)

--------------------------------------------------------------------------------
-- Create new plot object
function Plot.new()
    -- (Lua: `ref($that) || $that || 'Image::ExifTool::Plot'` is always Plot)
    local self = setmetatable({ }, Plot)
    for _, k in ipairs(perl.keys(defaults)) do
        if perl.ref(defaults[k]) == 'HASH' then self[k] = { } for k2, v in pairs(defaults[k]) do self[k][k2] = v end goto next end
        if perl.ref(defaults[k]) == 'ARRAY' then self[k] = { table.unpack(defaults[k]) } goto next end
        self[k] = defaults[k]
        ::next::
    end
    return self
end

--------------------------------------------------------------------------------
-- Set plot settings
-- Inputs: 0) Plot ref, 1) comma-separated options
function Plot:Settings(set)
    if not perlTruthy(set) then return end
    for _, item in ipairs(split([[,\s*]], set)) do
        local m1, _, m3 = matches(item, [[(?i)^([a-z].*?)(=(.*))?$]])
        if m1 == nil then goto continue end
        do
            local name, val = lc(m1), m3
            if ref(self[name]) == 'ARRAY' then
                if val == nil then goto continue end
                local isNum = isMatch(self[name][1], [[^\d+$]])
                -- also allow numbers to also be separated by 'x'
                local vals = isNum and split([[\s*[x\s\/+]\s*]], val) or split([[\s*[\s\/+]\s*]], val)
                local i = 0
                while #vals > 0 do
                    do
                        local val_ = lc(shift(vals))
                        if length(val_) == 0 then goto next_i end
                        if name == 'marks' then
                            local v = split('-', val_)
                            if perlTruthy(v[1]) then
                                if isMatch(v[1], [[^n]]) then
                                    v[1] = 'none'
                                else
                                    v[1] = perl.grepDyn('^' .. v[1], defaults.marks)[1]
                                    if not perlTruthy(v[1]) then self.Warn = 'Invalid marker name' goto next_i end
                                end
                            else
                                -- cycle through default markers if none specified
                                v[1] = defaults.marks[i % #defaults.marks + 1]
                            end
                            val_ = join('-', v)
                        end
                        self[name][i + 1] = val_
                    end
                    ::next_i::
                    i = i + 1
                end
            else
                if val == nil then val = 1 end  -- default to 1 if no "="
                local charName = { ['&'] = 'amp', ['<'] = 'lt', ['>'] = 'gt' }
                -- escape necessary XML characters, but allow numerical entities
                local n
                val, n = substN(val, [[(?s)([&><])]], function(c) return '&' .. charName[c] .. ';' end, 'g')
                if n then val = subst(val, [[(?s)&amp;(#(\d+|x[0-9a-fA-F]+);)]], '&$1') end
                if length(val) == 0 then val = nil end
                self[name] = val
            end
        end
        ::continue::
    end
end

--------------------------------------------------------------------------------
-- Add points to SVG plot
-- Inputs: 0) Plot object ref, 1) tag value hash ref, 2) tag ID list ref
function Plot:AddPoints(info, tags)
    local tag, name, index, mod, val
    local num_, vals = { }, { }     -- (Perl's %num, @vals)
    local ee, docNum, data, xmin, xmax = self.EE, self.DocNum, self.Data, self.XMin, self.XMax
    if not perlTruthy(self.type) then self.type = 'line' end
    local scat = isMatch(self.type, [[^s]]) and 1 or 0
    local xname = self.Name[1]      -- (x-axis name if using scatter plot)
    local maxLines = (isMatch(self.type, [[^h]]) and not perlTruthy(self.multi)) and 1 or 20
    while true do
        if #vals > 0 then
            val = shift(vals)
            if not isMatch(val, [[^[+-]?(?=\.?\d)\d*\.?\d*(?:e[+-]?\d+)?$]]) then goto continue end
        else
            tag = shift(tags)
            if not perlTruthy(tag) then break end
            -- ignore non-floating-point values
            val = info[tag]
            name = matches(tag, [[^(\S+)]])     -- remove index number
            if ref(val) ~= '' then
                if ref(val) == 'ARRAY' then
                    index = index ~= nil and index + 1 or 0
                    val = val[index + 1]
                    if val == nil then index, mod = nil, nil goto continue end
                    name = name .. (perlTruthy(mod) and ('[' .. perlStr(index % mod) .. ']') or ('[' .. index .. ']'))
                    unshift(tags, tag)  -- will continue with this tag later
                elseif ref(val) == 'SCALAR' then
                    val = val.value     -- handle binary values
                else
                    goto continue
                end
            end
        end
        do
            if val == nil then goto continue end
            local ok, sep = isMatch(val, [[(?i)^[+-]?(?=\.?\d)\d*\.?\d*(?:e[+-]?\d+)?([ ,;\t\n\r]+|$)]])
            if not ok then goto continue end
            if perlTruthy(sep) then
                -- split a string of numbers into separate plot points (eg. histogram tags)
                if perlTruthy(self['split']) then
                    -- make an array
                    info[tag] = split([[[ ,;\t\n\r][\n\r]? *]], val)
                    unshift(tags, tag)
                    -- split into lists of 'split' elements if split > 1
                    if self['split'] > 1 then mod = self['split'] end
                    goto continue
                else
                    vals = split([[[ ,;\t\n\r][\n\r]? *]], val)
                    val = shift(vals)
                end
            end
            local docNum_ = perlTruthy(docNum) and (perlTruthy(docNum[tag]) and docNum[tag] or 0) or 0
            if perlTruthy(docNum_) and not perlTruthy(ee) then goto continue end
            if not perlTruthy(data[name]) then
                if #self.Name >= maxLines + scat then
                    if not perlTruthy(self.MaxTags) then
                        if isMatch(self.type, [[^h]]) and not perlTruthy(self.multi) then
                            self.Warn = 'Use the Multi setting to make a separate histogram for each dataset'
                        else
                            self.Warn = 'Too many variables to plot all of them'
                        end
                        self.MaxTags = 1
                    end
                    goto continue
                end
                push(self.Name, name)
                if not perlTruthy(xname) then xname = name end  -- x-axis data for scatter plot
                if not (scat ~= 0 and name == xname) then
                    if self.Max == nil or num(val, '>') > num(self.Max, '>') then self.Max = val end
                    if self.Min == nil or num(val, '<') < num(self.Min, '<') then self.Min = val end
                end
                if xmin == nil then xmin = docNum_ xmax = docNum_ end
                num_[name] = xmax
                if num(xmax, '>=') >= num(xmin, '>=') then aset(data, name, xmax - xmin, val) end
                goto continue
            end
            if perlTruthy(docNum_) and num_[name] ~= nil and num(num_[name], '<') < num(docNum_, '<') then
                num_[name] = docNum_    -- keep documents synchronized if some tags are missing
            else
                if num_[name] == nil then num_[name] = xmax end
                num_[name] = num_[name] + 1
            end
            if num(num_[name], '>=') >= num(xmin, '>=') then aset(data, name, num_[name] - xmin, val) end
            if not (scat ~= 0 and name == xname) then
                if num(val, '>') > num(self.Max, '>') then self.Max = val end
                if num(val, '<') < num(self.Min, '<') then self.Min = val end
            end
        end
        ::continue::
    end
    -- start next file at x value so far
    for _, k in ipairs(perl.keys(num_)) do
        if num(xmax, '<') < num(num_[k], '<') then xmax = num_[k] end
    end
    self.XMin = xmin
    self.XMax = xmax
end

--------------------------------------------------------------------------------
-- Calculate a nice round number for grid spacing
-- Inputs: 0) nominal spacing (must be positive), 1) flag to increment to next number
-- Returns: spacing rounded to an even number
function Plot.GetGridSpacing(nom, inc)
    local div = sprintf('%.3e', nom)
    local num1 = substr(div, 0, 1)  -- (Perl's $num)
    local n
    div, n = substN(div, [[.*e]], '')
    local exp = n and div or 0
    if perlTruthy(inc) then
        -- increment to next highest even number
        if num1 < 2 then num1 = 2 elseif num1 < 5 then num1 = 5 else exp = exp + 1 num1 = 1 end
    else
        -- look for nearest factor to 1, 2 or 5 * 10^x
        if num1 > 2 then
            if num1 < 8 then num1 = 5 else exp = exp + 1 num1 = 1 end
        end
    end
    if exp >= 0 then return perlStr(num1) .. string.rep('0', int(exp)) end
    return '.' .. string.rep('0', int(-exp - 1)) .. perlStr(num1)
end
local GetGridSpacing = Plot.GetGridSpacing

--------------------------------------------------------------------------------
-- Get plot range
-- Inputs: 0) minimum, 1) maximum
-- Returns: difference
-- Notes: Adjusts min/max if necessary to make difference positive
-- (port: returns the difference, then the minimum and maximum)
function Plot.GetRange(min, max)
    if num(min, '>=') >= num(max, '>=') then
        min = (min + max) / 2
        if perlTruthy(min) then min = min - 0.5 end
        max = min + 1
    end
    return max - min, min, max
end
local GetRange = Plot.GetRange

--------------------------------------------------------------------------------
-- Draw SVG plot
-- Inputs: 0) Plot ref, 1) Output file reference
function Plot:Draw(fp)
    local min, max, xmin, xmax, name, style = self.Min, self.Max, self.XMin, self.XMax, self.Name, self.style
    local plotNum, multiMulti

    if min == nil or xmin == nil then
        self.Error = 'Nothing to plot'
        return
    end
    local scat = isMatch(self.type, [[^s]]) and 1 or 0
    local hist = isMatch(self.type, [[^h]]) and { n = -1 } or false
    local multi = perlTruthy(self.multi) and self.multi or 0
    local multiL = findAll(perlStr(multi), [[\d+]])     -- (Perl's @multi)
    local names = { table.unpack(name) }
    if scat ~= 0 then shift(names) end
    multi = shift(multiL)
    if num(multi, '>') <= 0 then multi = 0 end
    if not perlTruthy(style) then style = hist and 'line+fill' or 'line' end
    if not (isMatch(style, [==[\b[mpl]]==]) or (hist and isMatch(style, [[\bf]]))) then
        self.Error = 'Invalid plot Style setting'
        return
    end
    local numPlots = 0
    if perlTruthy(multi) then
        local n = 0
        while n < #name - scat do
            n = n + (perlTruthy(multiL[numPlots + 1]) and multiL[numPlots + 1] or 1)
            if perlTruthy(multiL[numPlots + 1]) and multiL[numPlots + 1] > 1 then multiMulti = 1 end
            numPlots = numPlots + 1
        end
    else
        numPlots = 1
    end
    local size = { table.unpack(self.size) }
    local sy = size[2]
    if perlTruthy(multi) then
        sy = sy * int((numPlots + multi - 1) / multi) / multi
        for k = 1, #size do size[k] = size[k] / multi end
    end
    local tmp = perlTruthy(self.title) and self.title or 'Plot by ExifTool ' .. ExifTool.VERSION
    print(fp, '<?xml version="1.0" standalone="no"?>\n' ..
'<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 20010904//EN" "http://www.w3.org/TR/2001/REC-SVG-20010904/DTD/svg10.dtd">\n' ..
'<svg version="1.1" xmlns="http://www.w3.org/2000/svg" width="', self.size[1], '" height="', sy, '"\n' ..
' preserveAspectRatio="xMidYMid meet" viewBox="0 0 ', self.size[1], ' ', sy, '">\n' ..
'<title>', tmp, '</title>')
  -- loop through all plots
  plotNum = 0
  while plotNum < numPlots do
    local i, n, x, y, px, py, dx, dy, dx2, xAxis
    local col, class, og = { }, { }, { }
    local noLegend, xname, xdat, xdiff, diff
    local markID = { }
    if numPlots > 1 then
        print(fp, "\n<g transform='translate(", (plotNum % multi) * size[1],
                  ',', int(plotNum / multi) * size[2], ")'>")
        if plotNum ~= 0 then
            local save = self.Save
            self.XMin, self.XMax, self.title, self.xlabel, self.ylabel = save[1], save[2], save[3], save[4], save[5]
        else
            self.Save = { self.XMin, self.XMax, self.title, self.xlabel, self.ylabel }
            self.SaveName = { table.unpack(self.Name) }
        end
        self.Name = { }
        name = self.Name
        if scat ~= 0 then push(self.Name, self.SaveName[1]) end
        -- (an undef name -- when the datasets run out -- is not stored)
        for _ = 0, (perlTruthy(multiL[plotNum + 1]) and multiL[plotNum + 1] or 1) - 1 do
            push(self.Name, shift(names))
        end
        min = nil max = nil
        for k = scat, #self.Name - 1 do
            local dat = self.Data[self.Name[k + 1]]
            for j = 0, dat and dat.n or -1 do
                local v = dat[j]
                if v ~= nil then
                    if min == nil then
                        min = v max = v
                    else
                        if num(min, '>') > num(v, '>') then min = v end
                        if num(max, '<') < num(v, '<') then max = v end
                    end
                end
            end
        end
    end
    local data, title, xlabel, ylabel, cols, marks, tpad, wid =
        self.Data, self.title, self.xlabel, self.ylabel, self.cols, self.marks, self.txtpad, self.stroke
    local nameList = { table.unpack(name) }     -- (Perl's @name)
    local margin = { table.unpack(self.margin) }

    -- set reasonable default titles and labels
    if scat ~= 0 then xname = shift(nameList) end
    if scat ~= 0 and title ~= nil and not perlTruthy(title) and #nameList == 1 and not perlTruthy(multi) then
        title = perlStr(nameList[1]) .. ' vs ' .. perlStr(xname)
    end
    if (scat ~= 0 or hist) and xlabel ~= nil and not perlTruthy(xlabel) then
        xlabel = name[1]
        if hist then noLegend = 1 end
    end
    if ylabel ~= nil and not perlTruthy(ylabel) and #nameList == 1 and not multiMulti then
        ylabel = hist and 'Count' or nameList[1]
        if not hist then noLegend = 1 end
    end

    -- make room for title/labels
    if perlTruthy(title) then margin[2] = margin[2] + self.linespacing * 1.5 end
    if perlTruthy(xlabel) then margin[4] = margin[4] + self.linespacing end
    if perlTruthy(ylabel) then margin[1] = margin[1] + self.linespacing end

    -- calculate optimal number of X/Y grid lines
    for k = 0, 1 do
        og[k + 1] = ng[k + 1] * (size[k + 1] - margin[k + 1] - margin[k + 3]) /
                     (defaults.size[k + 1] - defaults.margin[k + 1] - defaults.margin[k + 3])
        if og[k + 1] <= 0 then self.Error = 'Invalid plot size' return end
    end
    if scat ~= 0 then
        xdat = self.Data[xname]
        if not (self.xmin ~= nil and self.xmax ~= nil) then
            local set
            for j = 0, xdat and xdat.n or -1 do
                local v = xdat[j]
                if v == nil then goto next_x end
                if not set then xmin = v xmax = v set = 1 goto next_x end
                if num(xmin, '>') > num(v, '>') then xmin = v end
                if num(xmax, '<') < num(v, '<') then xmax = v end
                ::next_x::
            end
            local dnx2 = (xmax - xmin) / (og[1] * 2)
            -- leave a bit of a left/right margin, but don't pass 0
            xmin = (xmin >= 0 and  xmin < dnx2) and 0 or xmin - dnx2
            xmax = (xmax <= 0 and -xmax < dnx2) and 0 or xmax + dnx2
        end
        if self.xmin ~= nil then xmin = self.xmin end
        if self.xmax ~= nil then xmax = self.xmax end
    else
        -- shift x range to correspond with index in data list
        xmax = xmax - xmin
        xmin = 0
    end
    if hist then
        if num(self.nbins, '>') <= 0 then self.Error = 'Invalid number of histogram bins' return end
        noLegend = 1
        -- y axis becomes histogram x axis after binning
        if self.xmin ~= nil then min = self.xmin end
        if self.xmax ~= nil then max = self.xmax end
    else
        -- leave a bit of a margin above/below data when autoscaling but don't pass 0
        local dny2 = (max - min) / (og[2] * 2)
        min = (min >= 0 and  min < dny2) and 0 or min - dny2
        max = (max <= 0 and -max < dny2) and 0 or max + dny2
        -- adjust to user-defined range if specified
        if self.ymin ~= nil then min = self.ymin end
        if self.ymax ~= nil then max = self.ymax end
    end
    -- generate random colors if we need more
    while #cols < #name do
        if not perlTruthy(self.seeded) then srand(141) self.seeded = 1 end
        push(cols, sprintf('#%.2x%.2x%.2x', int(rand(220)), int(rand(220)), int(rand(220))))
    end
    diff, min, max = GetRange(min, max)
    xdiff, xmin, xmax = GetRange(xmin, xmax)

    -- determine y grid spacing (nice even numbers)
    dy = GetGridSpacing(diff / (hist and self.nbins or og[2]))
    -- expand plot min/max to the nearest even multiple of our grid spacing
    min = (min > 0 and int(min / dy) or int(min / dy - 0.9999)) * dy
    max = (max > 0 and int(max / dy + 0.9999) or int(max / dy)) * dy

    -- bin histogram
    if hist then
        local dat = data[nameList[1]]
        local nmax = int((max - min) / dy + 0.5)
        for k = 0, nmax - 1 do hist[k] = 0 end
        hist.n = nmax - 1
        for j = 0, dat and dat.n or -1 do
            local v = dat[j]
            if v == nil then goto next_v end
            n = (v - min) / dy
            if n < 0 or n > nmax + 0.00001 then goto next_v end
            n = int(n)
            do
                local k = n < nmax and n or nmax - 1
                hist[k] = hist[k] + 1
            end
            ::next_v::
        end
        xmin, xmax, min, max = min, max, 0, 0
        if perlTruthy(self.ymax) then
            max = self.ymax
        else
            for k = 0, hist.n do if max < hist[k] then max = hist[k] end end  -- find max count
        end
        diff, min, max = GetRange(min, max)
        dx = dy
        dy = GetGridSpacing(diff / og[2])
        max = (max > 0 and int(max / dy + 0.9999) or int(max / dy)) * dy
        data[nameList[1]] = hist
    else
        dx = GetGridSpacing(xdiff / og[1])
    end
    if scat ~= 0 then
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
    print(fp, "\n<!-- Definitions -->\n<defs>\n<clipPath id='plot-area'>")
    print(fp, "<rect x='", clip[1], "' y='", clip[2], "' width='", clip[3], "' height='", clip[4], "'/></clipPath>")
    if isMatch(style, [==[\b[mp]]==]) then -- 'm' for 'marker' or 'p' for 'point' (undocumented)
        for k = 0, #nameList - 1 do
            local m = split('-', perlTruthy(marks[k + 1]) and marks[k + 1] or defaults.marks[k % #defaults.marks + 1])
            local fill, mark
            local wantFill
            if perlTruthy(m[2]) then wantFill = isMatch(m[2], [[^f]]) else wantFill = isMatch(style, [[\bf]]) end
            if wantFill then fill = perlTruthy(m[3]) and m[3] or cols[k + 1] end
            mark = markerData[m[1]]
            if not perlTruthy(mark) then markID[perlStr(mark)] = '' goto next_k end -- skip 'none' or unrecognized marker name
            if perlTruthy(fill) and fill ~= 'none' then
                local op = perlTruthy(m[4]) and m[4] or (cols[k + 1] == 'none' and 50 or 20)
                mark = mark .. ' fill="' .. perlStr(fill) .. '" style="fill-opacity: ' .. perlStr(op) .. '%"'
            else
                mark = mark .. ' fill="none"'
            end
            -- (was using 'context-stroke', but Chrome didn't show this properly)
            mark = mark .. " stroke='" .. perlStr(cols[k + 1]) .. "'/>"
            -- don't re-define mark if it is the same as a previous one
            if perlTruthy(markID[mark]) then markID[k] = markID[mark] goto next_k end
            markID[mark] = 'mark' .. k
            markID[k] = markID[mark]
            print(fp, "\n<marker id='", markID[k], "' markerWidth='8' markerHeight='8' refX='4'",
                      " refY='4'>\n", mark, "\n</marker>")
            ::next_k::
        end
        print(fp, "\n</defs>\n<style>")
        for k = 0, #nameList - 1 do
            if perlStr(markID[k]) == 'mark' .. k then
                print(fp, "\n  path.mark", k, " { marker: url(#mark", k, ") }")
            end
        end
    else
        print(fp, "\n</defs>\n<style>")
    end
    print(fp, "\n  text { fill: ", self.text, " }\n</style>")
    if perlTruthy(self.bkg) then print(fp, "\n<rect x='0' y='0' width='", size[1], "' height='", size[2], "' fill='", self.bkg, "'/>") end
    print(fp, "\n<!-- X axis -->")
    print(fp, "\n<g dominant-baseline='hanging' text-anchor='middle'>")
    py = int((margin[2] + height + tpad[2]) * 10 + 0.5) / 10
    px = int((margin[1] + width / 2) * 10 + 0.5) / 10
    if perlTruthy(title) then
        print(fp, "\n<text x='", px, "' y='14' font-size='150%'>", title, "</text>")
    end
    if perlTruthy(xlabel) then
        y = py + self.linespacing
        print(fp, "\n<text x='", px, "' y='", y, "'>", xlabel, "</text>")
    end
    if perlTruthy(ylabel) then
        y = margin[2] + height / 2
        print(fp, "\n<text x='10' y='", y, "' transform='rotate(-90,10,", y, ")'>", ylabel, "</text>")
    end
    -- make sure the X labels will fit
    local spc = dx
    while true do
        -- find longest label at current spacing
        local len = 0
        local x0 = int(xmax / spc + 0.5) * spc     -- get value of last x label
        i = 0 x = x0
        while i < 3 do
            n = length(sprintf('%g', x))
            if len < n then len = n end
            i = i + 1 x = x - spc
        end
        if spc >= (len + 1) * wch * xdiff / width then break end
        -- increase label spacing by one increment and try again
        dx2 = GetGridSpacing(spc, 1)
        spc = dx2
    end
    local grid, lastLen = '', 0
    x = int(xmin / dx - 1) * dx
    while true do
        px = int((margin[1] + (x - xmin) * width / xdiff) * 10 + 0.5) / 10
        if px < margin[1] - 0.5 then goto next_grid end
        if px > margin[1] + width + 0.5 then break end
        do
            local h = height
            if not perlTruthy(dx2) or math.abs(x / dx2 - int(x / dx2 + (x > 0 and 0.5 or -0.5))) < 0.01 then
                printf(fp, "\n<text x='" .. perlStr(px) .. "' y='" .. perlStr(py) .. "'>%g</text>", x)
                h = h + tpad[2] / 2
            end
            if length(grid) - lastLen > 80 then grid = grid .. "\n" lastLen = length(grid) end
            grid = grid .. sprintf('M' .. perlStr(px) .. ' ' .. perlStr(margin[2]) .. ' v' .. perlStr(h) .. ' ')
        end
        ::next_grid::
        x = x + dx
    end
    print(fp, "\n<path stroke='", self.grid, "' stroke-width='0.5' d='\n", grid, "'/>")
    print(fp, "\n</g>\n<!-- Y axis -->\n<g dominant-baseline='middle' text-anchor='end'>")
    px = int((margin[1] - tpad[1]) * 10 + 0.5) / 10
    grid, lastLen = '', 0
    local gx, gw = margin[1] - tpad[1] / 2, width + tpad[1] / 2
    y = min
    while true do
        py = int((margin[2] + height - (y - min) * yscl) * 10 + 0.5) / 10
        if py < margin[2] - 0.5 then break end
        if y < dy / 2 and y > -dy / 2 then y = 0 end    -- (avoid round-off errors)
        printf(fp, "\n<text x='" .. perlStr(px) .. "' y='" .. perlStr(py) .. "'>%g</text>", y)
        if y < dy / 2 and y > -dy / 2 then xAxis = 1 end    -- redraw x axis later
        if length(grid) - lastLen > 80 then grid = grid .. "\n" lastLen = length(grid) end
        grid = grid .. 'M' .. perlStr(gx) .. ' ' .. perlStr(py) .. ' h' .. perlStr(gw) .. ' '
        y = y + dy
    end
    if xAxis and num(min, '!=') ~= 0 then
        py = margin[2] + height + min * yscl
        print(fp, "\n<path stroke='", self.text, "' d='M", margin[1], ' ', py, ' h', width, "'/>")
    end
    print(fp, "\n<path stroke='", self.grid, "' stroke-width='0.5' d='\n", grid, "'/>")
    print(fp, "\n</g>\n<!-- Plot box and legend -->\n<g dominant-baseline='middle' text-anchor='start'>")
    print(fp, "\n<path stroke='", self.text, "' fill='none' d='M", margin[1], ' ', margin[2], ' l0 ', height, ' ',
              width, ' 0 0 -', height, " z'/>")
    i = 0
    while i < #nameList and not noLegend do
        x = size[1] - margin[3] - 175 + self.legend[1]
        y = margin[2] + self.legend[2] + 15 + self.linespacing * (i + 0.5)
        local col_ = cols[i + 1]
        local mark = perlTruthy(markID[i]) and (" marker-end='url(#" .. markID[i] .. ")' fill='none'") or ''
        local line = isMatch(style, [[\bl]]) and ' l-20 0' or sprintf(' m%.4g 0', -5 * wid)
        local sw = (isMatch(style, [[\bm]]) and 1.5 or 2) * wid -- (wider for line-only style so colour is more visible)
        print(fp, "\n<path", mark, " stroke-width='", sw, "' stroke='", col_, "' d='M", x, ' ', y, ' m-7 -1', line, "'/>")
        print(fp, "\n<text x='", x, "' y='", y, "'>", nameList[i + 1], "</text>")
        i = i + 1
    end
    -- print the data
    for k = 0, #nameList - 1 do
        col[nameList[k + 1]] = cols[k + 1]
        class[nameList[k + 1]] = perlTruthy(markID[k]) and (" class='" .. markID[k] .. "'") or ''
    end
    local i0, i1, xsclr
    local fill = ''
    if scat ~= 0 then
        i0, i1 = 0, xdat.n
    elseif hist then
        i0, i1 = 0, hist.n
        xscl = width / (hist.n + 1)
        px0 = margin[1]
        xsclr = int(xscl * 100 + 0.5) / 100
        if isMatch(style, [[\bf]]) then
            local m = split('-', marks[1])
            local op = perlTruthy(m[4]) and m[4] or (isMatch(style, [[\bl]]) and 20 or 50)
            fill = " fill='" .. perlStr(cols[1]) .. "'"
            if cols[1] ~= 'none' then fill = fill .. " style='fill-opacity: " .. perlStr(op) .. "%'" end
        end
    else
        i0 = int(xmin) - 1
        if i0 < 0 then i0 = 0 end
        i1 = int(xmax) + 1
    end
    print(fp, "\n</g>\n<!-- Datasets -->\n<g fill='none' clip-path='url(#plot-area)'",
              " stroke-linejoin='round' stroke-linecap='round' stroke-width='", 1.5 * wid, "'>")
    local doLines = isMatch(style, [[\bl]])
    for _, nm in ipairs(nameList) do
        local stroke = (hist and not doLines) and 'none' or col[nm]
        local dat = data[nm] or { }
        print(fp, "\n<!-- ", nm, " -->")
        print(fp, "\n<path", class[nm], fill, " stroke='", stroke, "' d='")
        if doLines then print(fp, 'M') end
        local m = doLines and '' or ' M'
        for k = i0, i1 do
            if dat[k] == nil then goto next_pt end
            y = int((py0 - dat[k] * yscl) * 10 + 0.5) / 10
            if scat ~= 0 then
                if xdat[k] == nil then goto next_pt end
                x = int((px0 + xdat[k] * xscl) * 10 + 0.5) / 10
            else
                x = int((px0 + k * xscl) * 10 + 0.5) / 10
                if hist then
                    print(fp, m, (k % 5 ~= 0) and ' ' or "\n", perlStr(x) .. ' ' .. perlStr(y) .. ' h' .. perlStr(xsclr))
                    m = ' L'    -- (draw lines after the first point)
                    goto next_pt
                end
            end
            print(fp, m, (k % 10 ~= 0) and ' ' or "\n", perlStr(x) .. ' ' .. perlStr(y))
            ::next_pt::
        end
        if hist and perlTruthy(fill) then print(fp, ' V', margin[2] + height, " H", margin[1], ' z') end
        print(fp, "'/>")
    end
    print(fp, "\n</g>")
    if numPlots > 1 then print(fp, "\n</g>") end
    plotNum = plotNum + 1
  end
  if not perlTruthy(print(fp, "</svg>\n")) then self.Error = 'Error writing output plot file' end
end

return Plot
