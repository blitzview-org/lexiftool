--------------------------------------------------------------------------------
-- File:         lexiftool/HtmlDump.lua
-- Ported from:  lib/Image/ExifTool/HtmlDump.pm
--
-- Description:  Dump information in hex to HTML page
--
-- Revisions:    12/05/2005 - P. Harvey Created
--
-- Port notes:   read subset -- the `-htmlDump` HTML generator. `new`, `Add`,
--               `Print`, `Open`, `DumpTable`, `FinishTiffDump` and `Write`
--               are ported line-for-line. The header/CSS/JS literal strings
--               ($htmlHeader1/2/3, $preMouse) are carried over verbatim.
--               `$bkgStart`/`$bkgEnd`/`@bkgSpan` are upstream *module*
--               globals (shared across HtmlDump objects within one process);
--               kept as module-local upvalues here for the same reason
--               upstream keeps them outside the object -- `DumpTable` reads
--               them mid-loop while `Print` is still iterating.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local substr = require('lexiftool.perl').substr
local perl = require('lexiftool.perl')
local sprintf = perl.sprintf
local tsort = perl.tsort
local perlStr = perl.str
local HTML = require('lexiftool.HTML')
local perlTruthy = ExifTool.perlTruthy

local HtmlDump = {}
HtmlDump.__index = HtmlDump

-- upstream: `my ($bkgStart, $bkgEnd, @bkgSpan);` -- shared across Print()
-- invocations exactly as in Perl (module-level, not per-object)
local bkgStart, bkgEnd
local bkgSpan = {}

local htmlHeader1 = [[
<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.0 Transitional//EN"
 "http://www.w3.org/TR/1998/REC-html40-19980424/loose.dtd">
<html>
<head>
<title>
]]

-- Note: Don't change font-weight style because it can affect line height
local htmlHeader2 = [[
</title>
<meta http-equiv="Content-Type" content="text/html; charset=UTF-8">
<style type="text/css">
<!--
/* character style ID's */
.D { color: #000000 } /* default color */
.V { color: #ff0000 } /* duplicate block 1 */
.W { color: #004400 } /* normal block 1 */
.X { color: #ff4488 } /* duplicate block 2 */
.Y { color: #448844 } /* normal block 2 */
.U { color: #cc8844 } /* unused data block */
.H { color: #0000ff } /* highlighted tag name */
.F { color: #aa00dd } /* actual offset differs */
.M { text-decoration: underline } /* maker notes data */
.tt { /* tooltip text */
    visibility: hidden;
    position: absolute;
    white-space: nowrap;
    top: 0;
    left: 0;
    font-family: Verdana, sans-serif;
    font-size: .7em;
    padding: 2px 4px;
    border: 1px solid gray;
    z-index: 3;
}
.tb { /* tooltip background */
    visibility: hidden;
    position: absolute;
    background: #ffffdd;
    zoom: 1;
    -moz-opacity: 0.8;
    -khtml-opacity: 0.8;
    -ms-filter: 'progid:DXImageTransform.Microsoft.Alpha(Opacity=80)';
    filter: alpha(opacity=80);
    opacity: 0.8;
    z-index: 2;
}
/* table styles */
table.dump {
  border-top: 1px solid gray;
  border-bottom: 1px solid gray;
}
table.dump td { padding: .2em .3em }
td.c2 {
  border-left: 1px solid gray;
  border-right: 1px solid gray;
}
pre   { margin: 0 }
table { font-size: .9em }
body  { color: black; background: white }
-->
</style>
<script language="JavaScript" type="text/JavaScript">
<!-- Begin
// tooltip positioning constants
var TMAR = 4;   // top/left margins
var BMAR = 16;  // bottom/right margins (scrollbars may overhang inner dimensions)
var XOFF = 10;  // x offset from cursor
var YOFF = 40;  // y offset
var YMIN = 10;  // minimum y offset
var YTOP = 20;  // y offset when above cursor
// common variables
var safari1 = navigator.userAgent.indexOf("Safari/312.6") >= 0;
var ie6 = navigator.userAgent.toLowerCase().indexOf('msie 6') >= 0;
var mspan = new Array;
var clicked = 0;
var hlist, tt, tb, firstOutEvt, lastInEvt;

function GetElementsByClass(classname, tagname) {
  var found = new Array();
  var list = document.getElementsByTagName(tagname);
  var len = list.length;
  for (var i=0, j=0; i<len; ++i) {
    var classes = list[i].className.split(' ');
    for (var k=0; k<classes.length; ++k) {
      if (classes[k] == classname) {
        found[j++] = list[i];
        break;
      }
    }
  }
  return found;
}

// click mouse
function doClick(e)
{
  if (!clicked) {
    firstOutEvt = lastInEvt = undefined;
    high(e, 2);
    if (hlist) clicked = 1;
  } else {
    clicked = 0;
    if (firstOutEvt) high(firstOutEvt, 0);
    if (lastInEvt) high(lastInEvt, 1);
  }
}

// move tooltip
function move(e)
{
  if (!tt) return;
  if (ie6 && (tt.style.top  == '' || tt.style.top  == 0) &&
             (tt.style.left == '' || tt.style.left == 0))
  {
    tt.style.width  = tt.offsetWidth  + 'px';
    tt.style.height = tt.offsetHeight + 'px';
  }
  var w, h;
  // browser inconsistencies make getting window size more complex than it should be,
  // and even then we don't know if it is smaller due to scrollbar width
  if (typeof(window.innerWidth) == 'number') {
    w = window.innerWidth;
    h = window.innerHeight;
  } else if (document.documentElement && document.documentElement.clientWidth) {
    w = document.documentElement.clientWidth;
    h = document.documentElement.clientHeight;
  } else {
    w = document.body.clientWidth;
    h = document.body.clientHeight;
  }
  var x = e.clientX + XOFF;
  var y = e.clientY + YOFF;
  if (safari1) { // patch for people still using OS X 10.3.9
    x -= document.body.scrollLeft + document.documentElement.scrollLeft;
    y -= document.body.scrollTop  + document.documentElement.scrollTop;
  }
  var mx = w - BMAR - tt.offsetWidth;
  var my = h - BMAR - tt.offsetHeight;
  if (y > my + YOFF - YMIN) y = e.clientY - YTOP - tt.offsetHeight;
  if (x > mx) x = mx;
  if (y > my) y = my;
  if (x < TMAR) x = TMAR;
  if (y < TMAR) y = TMAR;
  x += document.body.scrollLeft + document.documentElement.scrollLeft;
  y += document.body.scrollTop  + document.documentElement.scrollTop;
  tb.style.width  = tt.offsetWidth  + 'px';
  tb.style.height = tt.offsetHeight + 'px';
  tt.style.top  = tb.style.top  = y + 'px';
  tt.style.left = tb.style.left = x + 'px';
  tt.style.visibility = tb.style.visibility = 'visible';
}

// highlight/unhighlight text
function high(e,on) {
  if (on) {
    lastInEvt = e;
  } else {
    if (!firstOutEvt) firstOutEvt = e;
  }
  if (clicked) return;
  var targ;
  if (e.target) targ = e.target;
  else if (e.srcElement) targ = e.srcElement;
  if (targ.nodeType == 3) targ = targ.parentNode; // defeat Safari bug
  if (!targ.name) targ = targ.parentNode; // go up another level if necessary
  if (targ.name && document.getElementsByName) {
    // un-highlight current objects
    if (hlist) {
      for (var i=0; i<hlist.length; ++i) {
        for (var j=0; j<hlist[i].length; ++j) {
          hlist[i][j].style.background = 'transparent';
        }
      }
      hlist = null;
    }
    if (tt) {
      // hide old tooltip
      tt.style.visibility = tb.style.visibility = 'hidden';
      tt = null;
    }
    if (on) {
      if (targ.name.substring(0,1) == 't') {
        // show our tooltip (ID is different than name to avoid confusing IE)
        tt = document.getElementById('p' + targ.name.substring(1));
        if (tt) {
          tb = document.getElementById('tb');
          move(e);
        }
      }
      // highlight anchor elements with the same name
      hlist = new Array;
      hlist.push(document.getElementsByName(targ.name));
      // is this an IFD pointer?
      var pos = targ.className.indexOf('Offset_');
      if (pos > 0) {
        // add elements from this IFD to our highlight list
        hlist.push(document.getElementsByClassName(targ.className.substr(pos+7)));
      }
      // use class name to highlight span elements if necessary
      for (var i=0; i<mspan.length; ++i) {
        if (mspan[i] != targ.name) continue;
        // add these span elements to our highlight list
        hlist.push(GetElementsByClass(targ.name, 'span'));
        break;
      }
      for (var i=0; i<hlist.length; ++i) {
        for (var j=0; j<hlist[i].length; ++j) {
          hlist[i][j].style.background = on == 2 ? '#ffbbbb' : '#ffcc99';
        }
      }
    }
  }
}
]]

local htmlHeader3 = [[

// End --->
</script></head>
<body><noscript><b class=V>--&gt;
Enable JavaScript for active highlighting and information tool tips!
</b></noscript>
<table class=dump cellspacing=0 cellpadding=2>
<tr><td valign='top'><pre>]]

local preMouse = '<pre onmouseover="high(event,1)" onmouseout="high(event,0)" onmousemove="move(event)" onmousedown="doClick(event)">'

--------------------------------------------------------------------------------
-- New - create new HtmlDump object
-- Inputs: (none)
function HtmlDump.new()
    return setmetatable({ Block = {}, TipNum = 0 }, HtmlDump)
end

--------------------------------------------------------------------------------
-- Add information to dump
-- Inputs: 0) HTML dump hash ref, 1) absolute offset in file, 2) data size,
--         3) comment string, 4) tool tip (or SAME to use previous tip),
--         5) bit flags (see below), 6) IFD name
-- Bits: 0x01 - print at start of line
--       0x02 - print red address
--       0x04 - maker notes data ('M'-class span)
--       0x08 - limit block length
--       0x10 - allow double references
--       0x100 - (reserved)
-- Notes: Block will be shown in 'unused' color if comment string begins with '['
function HtmlDump:Add(start, size, msg, tip, flag, ifd)
    local block = self.Block
    -- (a Perl hash key is the stringified offset, so 12 and '12' share one
    --  entry; the port keys by the numeric value instead, which keeps that
    --  identity and gives Print's numeric sort numbers to compare)
    start = perl.num(start)
    block[start] = block[start] or {}
    local htip
    if tip and tip == 'SAME' then
        htip = ''
    else
        -- use message as first line of tip, and make bold unless in brackets
        if msg:match('^[%[%(]') then
            htip = msg
        else
            htip = '<b>' .. msg .. '</b>'
        end
        if tip ~= nil then
            tip = (HTML.EscapeHTML(tip):gsub('\n', '<br>')) -- HTML-ize tooltip text
            htip = htip .. '<br>' .. tip
        end
        -- add size if not already done
        if not htip:match('<br>Size:') then
            htip = htip .. '<br>(' .. size .. ' bytes)'
        end
        self.TipNum = self.TipNum + 1
    end
    table.insert(block[start], { size, msg, htip, flag, self.TipNum, ifd })
end

--------------------------------------------------------------------------------
-- utility routine to write to file or memory
-- Inputs: 0) file or scalar reference, 1-N) list of stuff to write
-- Returns: true on success
local function Write(outfile, ...)
    outfile:write(...)
    return true
end

--------------------------------------------------------------------------------
-- Open or close a specified html element
-- Inputs: 0) HtmlDump object ref, 1) element id, 2) element string,
--         3-N) list of column numbers (empty for all columns)
-- - element id may be '' to close all elements
-- - element string may be '' to close element by ID (or 0 to close without reopening)
-- - element id and string may both be 1 to reopen temporarily closed elements
function HtmlDump:Open(id, element, ...)
    local colNums = { ... }
    if #colNums == 0 then
        -- upstream: `@colNums or @colNums = (0 .. $#{$self->{Open}})` --
        -- $self->{Open} is always the 4-element array Print() pre-inits
        -- (address/hex/ASCII/comment columns), so this is always 0..3
        for i = 0, 3 do colNums[#colNums + 1] = i end
    end
    for _, col in ipairs(colNums) do
        -- get information about open elements in this column
        local opHash = self.Open_[col]
        local opElem = opHash.Element
        if element and element ~= '' then
            -- next if already open
            if opElem[id] and opElem[id] == element then goto continueCol end
        elseif id ~= '' and not opElem[id] then
            -- next if already closed and nothing to reopen
            if not (element == '' and #self.Closed[col].ID > 0) then goto continueCol end
        end
        local opID = opHash.ID
        local clHash = self.Closed[col]
        local clID = clHash.ID
        local clElem = clHash.Element
        -- get reference to output column list (use temp list if available)
        local cols = self.TmpCols or self.Cols
        -- close everything down to this element if necessary
        if opElem[id] or id == '' then
            while #opID > 0 do
                local tid = table.remove(opID)
                local e = opElem[tid]
                e = (e:gsub('^<([^ \t\n\r\f\v]+).*', '</%1>'))
                cols[col + 1] = cols[col + 1] .. e
                if id == tid or id == '' then
                    opElem[tid] = nil
                    if id ~= '' then break end
                    goto continueWhile
                end
                -- add this to the temporarily closed list
                -- (because we really didn't want to close it)
                table.insert(clID, tid)
                clElem[tid] = opElem[tid]
                opElem[tid] = nil
                ::continueWhile::
            end
            if id == '' then
                -- forget all temporarily closed elements
                clID = {}
                clHash.ID = clID
                clElem = {}
                clHash.Element = clElem
            end
        elseif clElem[id] then
            -- delete from the list of temporarily closed elements
            clElem[id] = nil
            local kept = {}
            for _, tid in ipairs(clID) do
                if tid ~= id then kept[#kept + 1] = tid end
            end
            clID = kept
            clHash.ID = clID
        end
        if element == '0' then goto continueCol end -- 0 = don't reopen temporarily closed elements

        -- re-open temporarily closed elements
        while #clID > 0 do
            local tid = table.remove(clID)
            cols[col + 1] = cols[col + 1] .. clElem[tid]
            table.insert(opID, tid)
            opElem[tid] = clElem[tid]
            clElem[tid] = nil
        end
        -- open specified element
        if element and element ~= '' and element ~= '1' then
            cols[col + 1] = cols[col + 1] .. element
            table.insert(opID, id)
            opElem[id] = element
        end
        ::continueCol::
    end
end

--------------------------------------------------------------------------------
-- Dump a block of data in HTML table form
-- Inputs: 0) HtmlDump object ref, 1) data position, 2) block pointer (string),
--         3) message, 4) object name, 5) flag, 6) full block length (actual
--         data may be shorter), 7) data end position, 8) IFD name
function HtmlDump:DumpTable(pos, blockPt, msg, name, flag, len, endPos, ifd)
    len = len or #blockPt
    endPos = endPos or 0
    local f0, dblRef, id
    local skipped = 0
    if (endPos ~= 0 and pos < endPos) or (flag and (flag & 0x02) ~= 0) then
        -- display double-reference addresses in red
        f0 = '<span class=V>'
        if endPos ~= 0 and pos < endPos then dblRef = true end
    else
        f0 = ''
    end
    local c = { '', '', '', '' }
    self.TmpCols = c
    if name and name ~= '' then
        if msg and msg:match('^%[') then
            id = 'U'
        else
            if self.A then
                id = 'X'
                self.A = false
            else
                id = 'V'
                self.A = true
            end
            if not dblRef then id = (id == 'V') and 'W' or 'Y' end
        end
        local class = ifd and ("'" .. id .. ' ' .. ifd .. "'") or id
        local nameElem = '<a name=' .. name .. ' class=' .. class .. '>'
        if msg then msg = nameElem .. msg .. '</a>' end
        name = nameElem
    else
        name = ''
    end
    -- use base-relative offsets from now on
    local cols = 0
    local p = pos
    if self.Cont then
        cols = pos & 0x0f
        c[2] = c[2] .. (cols == 8 and '  ' or ' ')
    else
        local addr = pos < 0 and sprintf('-%.4x', -pos) or sprintf('%5.4x', pos)
        self:Open('fgd', f0, 0)
        self:Open('fgd', '', 3)
        c[1] = c[1] .. addr
        if not (flag and (flag & 0x01) ~= 0) then p = p - (pos & 0x0f) end
        if p < pos then
            self:Open('bkg', '', 1, 2) -- don't underline white space
            cols = pos - p
            local nsp = 3 * cols
            if cols > 7 then nsp = nsp + 1 end
            c[2] = c[2] .. string.rep(' ', nsp)
            c[3] = c[3] .. string.rep(' ', cols)
            p = pos
        end
    end
    -- loop through each column of hex numbers
    while true do
        local spanClass, spanCont, spanClose = {}, {}, false
        if bkgStart and bkgEnd and p >= bkgStart and p < bkgEnd then
            for _, bkg in ipairs(bkgSpan) do
                if p >= bkg.Start and p < bkg.End then
                    spanClass[#spanClass + 1] = bkg.Class
                    if p + 1 == bkg.End then
                        spanClose = true
                    else
                        spanCont[#spanCont + 1] = bkg.Class -- this span continues
                    end
                end
            end
            local elem = #spanClass > 0 and ("<span class='" .. table.concat(spanClass, ' ') .. "'>") or ''
            self:Open('bkg', elem, 1, 2)
        else
            self:Open('bkg', '', 1, 2)
        end
        self:Open('a', name, 1, 2)
        local ch = substr(blockPt, p - pos - skipped, 1)
        c[2] = c[2] .. sprintf('%.2x', perl.ord(ch))
        -- make the character HTML-friendly
        local b = perl.ord(ch)
        if b < 0x20 or b >= 0x7f then
            ch = '.'
        end
        ch = ch:gsub('&', '&amp;'):gsub('>', '&gt;'):gsub('<', '&lt;')
        c[3] = c[3] .. ch
        p = p + 1
        cols = cols + 1
        -- close necessary elements
        if spanClose then
            local elem = #spanCont > 0 and ("<span class='" .. table.concat(spanCont, ' ') .. "'>") or ''
            -- close without reopening if closing anchor later
            local arg = (p - pos >= len) and '0' or elem
            self:Open('bkg', arg, 1, 2)
        end
        if dblRef and p >= endPos then
            dblRef = false
            id = (id == 'V') and 'W' or (id == 'W') and 'X' or (id == 'X') and 'Y' or (id == 'Y') and 'V' or id
            local class = ifd and ("'" .. id .. ' ' .. ifd .. "'") or id
            name = (name:gsub('class=[A-Za-z0-9]+%f[^A-Za-z]', 'class=' .. class, 1))
            f0 = ''
            self:Open('fgd', f0, 0)
        end
        if p - pos >= len then
            self:Open('a', '', 1, 2) -- close our anchor
            break
        end
        if cols < 16 then
            c[2] = c[2] .. (cols == 8 and '  ' or ' ')
            goto continueLoop
        elseif flag and (flag & 0x01) ~= 0 and cols < len then
            c[2] = c[2] .. ' '
            goto continueLoop -- put it all on one line
        end
        if not self.Msg then
            c[4] = c[4] .. (msg or '')
            msg = ''
        end
        for k = 1, 4 do c[k] = c[k] .. '\n' end -- add CR to all lines
        self.Msg = false
        -- limit data length if specified
        if self.Limit then
            local div = (flag and (flag & 0x08) ~= 0) and 4 or 1
            local lim = self.Limit / (2 * div) - 16
            if p - pos > lim and len - p + pos > lim then
                local nn = (len - p + pos - lim) & ~0x0f
                if nn > 16 then -- (no use just cutting out one line)
                    self:Open('bkg', '', 1, 2) -- no underline
                    local note = sprintf('[snip %d lines]', nn / 16)
                    note = string.rep(' ', math.floor(24 - #note / 2)) .. note
                    c[1] = c[1] .. '  ...\n'
                    c[2] = c[2] .. note .. string.rep(' ', 48 - #note) .. '\n'
                    c[3] = c[3] .. '     [snip]     \n'
                    c[4] = c[4] .. '\n'
                    p = p + nn
                    skipped = skipped + len - #blockPt
                end
            end
        end
        c[1] = c[1] .. (p < 0 and sprintf('-%.4x', -p) or sprintf('%5.4x', p))
        cols = 0
        ::continueLoop::
    end
    if msg and msg ~= '' then
        if self.Msg then msg = ' ' .. msg end
        c[4] = c[4] .. msg
    end
    if flag and (flag & 0x100) ~= 0 and cols < 16 then -- continue on same line?
        self.Cont = true
        if msg and msg ~= '' then self.Msg = true end
    else
        for k = 1, 4 do c[k] = c[k] .. '\n' end
        self.Msg = false
        self.Cont = false
    end
    -- add temporary column data to our real columns
    for k = 1, 4 do
        self.Cols[k] = self.Cols[k] .. c[k]
    end
    self.TmpCols = nil
end

--------------------------------------------------------------------------------
-- Print dump information to HTML page
-- Inputs: 0) Dump information hash reference, 1) source file RAF reference,
--         2) data pointer, 3) data position, 4) output file or scalar reference,
--         5) limit level (1-3), 6) title
-- Returns: non-zero if useful output was generated,
--          or -1 on error loading data and "ERROR" is set to offending data name
-- Note: The "Error" member may be set externally to print a specific error
--       message instead of doing the dump.
function HtmlDump:Print(raf, dataPt, dataPos, outfile, level, title)
    local block = self.Block
    if not perlTruthy(dataPos) then dataPos = 0 end
    -- (HtmlDumpBase arrives as a string, e.g. '256' from -htmlDump256 or
    --  -api; every use of $dataPos below is numeric, so numify it once)
    dataPos = perl.num(dataPos)
    outfile = outfile or io.stdout
    title = (title and title ~= '') and title or 'HtmlDump'
    if not perlTruthy(level) then level = 0 end
    local tell = raf:Tell()
    if not raf:Seek(0, 2) then
        self.Error = 'Seek error'
        return -1
    end
    local fileLen = raf:Tell()
    local pos = 0
    local dataEnd = dataPos + (dataPt and #dataPt or 0)
    -- initialize member variables
    self.Open_ = {}
    self.Closed = {}
    self.TipList = {}
    local tipListMax = 0 -- highest 1-based TipList index set (may have holes)
    self.MSpanList = {}
    self.Cols = { '', '', '', '' } -- text columns
    -- set dump size limits (limits are 4x smaller if bit 0x08 set in flags)
    local limit
    if perl.num(level) <= 1 then
        limit = 1024
    elseif perl.num(level) <= 2 then
        limit = 16384
    else
        limit = 256 * 1024 * 1024 -- never dump bigger than 256 MB
    end
    self.Limit = limit
    -- pre-initialize open/closed hashes for all columns
    for i = 0, 3 do
        self.Open_[i] = { ID = {}, Element = {} }
        self.Closed[i] = { ID = {}, Element = {} }
    end
    bkgStart, bkgEnd = 0, 0
    bkgSpan = {}
    local index = 0 -- initialize tooltip index
    local names, wasUnused = {}, nil
    -- only do dump if we didn't have a serious error
    local starts = {}
    if not self.Error then
        for k in pairs(block) do starts[#starts + 1] = k end
        tsort(starts, function(a, b) return a < b end)    -- sort { $a <=> $b }
    end
    local i = 0
    local err
    while i <= #starts do
        local start = starts[i + 1]
        local parmList
        if start ~= nil then
            parmList = block[start]
        elseif bkgEnd ~= 0 and pos < bkgEnd and wasUnused == nil then
            start = bkgEnd -- finish last bkg block
        else
            break
        end
        if start > fileLen then start = fileLen end -- handle case of bad start offset
        local len = start - pos
        if len > 0 and not wasUnused then
            -- we have unused bytes before this data block
            i = i - 1 -- dump the data block next time around
            -- split unused data into 2 blocks if it spans end of a bkg block
            local nextBkgEnd
            if wasUnused == nil and bkgEnd ~= 0 then
                for _, bkg in ipairs(bkgSpan) do
                    if not (pos >= bkg.End + dataPos or pos + len <= bkg.End + dataPos) then
                        if not (nextBkgEnd and nextBkgEnd < bkg.End) then nextBkgEnd = bkg.End end
                    end
                end
            end
            if nextBkgEnd then
                start = pos
                len = nextBkgEnd + dataPos - pos
                wasUnused = false
            else
                start = pos -- dump the unused bytes now
                wasUnused = true -- avoid re-dumping unused bytes if we get a read error
            end
            local str = (len > 1) and ('unused ' .. len .. ' bytes') or 'pad byte'
            parmList = { { len, '[' .. str .. ']', nil, 0x108 } }
        else
            wasUnused = nil
        end
        for _, parms in ipairs(parmList or {}) do
            local plen, msg, tip, flag, tipNum, ifd = parms[1], parms[2], parms[3], parms[4], parms[5], parms[6]
            if plen > 0 then
                flag = flag or 0
                -- generate same name for all blocks indexed by this tooltip
                local name
                if tipNum ~= nil then name = names[tipNum] end
                local idx = index
                if name then
                    -- get index from existing ID
                    idx = tonumber(substr(name, 1))
                else
                    name = 't' .. index
                    if tipNum ~= nil then names[tipNum] = name end
                    index = index + 1
                end
                if (flag & 0x14) ~= 0 then
                    local class = (flag & 0x04) ~= 0 and (name .. ' M') or name
                    if ifd and ifd ~= '' then class = class .. ' ' .. ifd end
                    local bkg = {
                        Class = class,
                        Start = start - dataPos,
                        End = start - dataPos + plen,
                    }
                    bkgSpan[#bkgSpan + 1] = bkg
                    if not (bkgStart ~= 0 and bkgStart < bkg.Start) then bkgStart = bkg.Start end
                    if not (bkgEnd ~= 0 and bkgEnd > bkg.End) then bkgEnd = bkg.End end
                    self.MSpanList[#self.MSpanList + 1] = name
                    goto continueParms
                end
                -- loop until we read the value properly
                local buff, endB
                for _try = 0, 1 do -- luacheck: ignore _try
                    endB = start + plen
                    -- only load as much of the block as we are going to dump
                    -- (read 32 more bytes than necessary just in case there
                    -- is only one skipped line that we decide to print)
                    local size = (plen > limit + 32) and (limit / 2 + 16) or plen
                    size = math.floor(size)
                    if start >= dataPos and endB <= dataEnd then
                        buff = substr(dataPt, start - dataPos, size)
                        if plen ~= size then
                            buff = buff .. substr(dataPt, start - dataPos + plen - size, size)
                        end
                    else
                        buff = ''
                        local okSeek = raf:Seek(start, 0)
                        local n1, r1 = nil, nil
                        if okSeek then n1, r1 = raf:Read(size) end
                        -- (Read fills $buff with whatever it got, also when
                        --  that is less than requested)
                        if r1 then buff = r1 end
                        if okSeek and n1 == size then
                            -- read end of block
                            if plen ~= size then
                                local ok2 = raf:Seek(start + plen - size, 0)
                                local n2, r2
                                if ok2 then n2, r2 = raf:Read(size) end
                                if not (ok2 and n2 == size) then
                                    err = msg
                                    -- reset $len to the actual length of available data
                                    plen = fileLen - start
                                    if perlTruthy(tip) then tip = tip .. '<br>Error: Only ' .. plen .. ' bytes available!' end
                                    goto nextTry
                                end
                                buff = buff .. r2
                            end
                        else
                            err = msg
                            plen = #buff
                            if perlTruthy(tip) then tip = tip .. '<br>Error: Only ' .. plen .. ' bytes available!' end
                        end
                    end
                    break
                    ::nextTry::
                end
                -- upstream: `$tip and $self->{TipList}->[$idx] = $tip;` -- Perl
                -- truthiness: an empty string (the htip='' from Add()'s 'SAME'
                -- case) is falsy, so it must NOT clobber an already-set real
                -- tip sharing the same idx (e.g. a tag's external value-data
                -- block reusing its 12-byte entry's tipNum)
                if tip and tip ~= '' then
                    self.TipList[idx + 1] = tip
                    if idx + 1 > tipListMax then tipListMax = idx + 1 end
                end
                if #buff > 0 then
                    -- set flag to continue this line if next block is contiguous
                    if i + 1 < #starts and parms == parmList[#parmList] and
                        (endB == starts[i + 2] or (endB < starts[i + 2] and endB >= pos)) then
                        local nextParms = block[starts[i + 2]]
                        local nextFlag = (nextParms and nextParms[1] and nextParms[1][4]) or 0
                        if (flag & 0x01) == 0 and (nextFlag & 0x01) == 0 then flag = flag | 0x100 end
                    end
                    self:DumpTable(start - dataPos, buff, msg, name, flag, plen, pos - dataPos, ifd)
                    if pos < endB then pos = endB end
                end
            end
            ::continueParms::
        end
        i = i + 1
    end
    self:Open('', '') -- close all open elements
    raf:Seek(tell, 0)

    -- write output HTML file
    Write(outfile, htmlHeader1, title)
    local rtnVal
    if self.Cols[1] ~= '' then
        Write(outfile, htmlHeader2)
        for k = 1, #self.MSpanList do
            Write(outfile, 'mspan[' .. (k - 1) .. '] = "' .. self.MSpanList[k] .. '";\n')
        end
        Write(outfile, htmlHeader3, self.Cols[1])
        Write(outfile, '</pre></td><td valign="top">', preMouse, self.Cols[2])
        Write(outfile, '</pre></td><td class=c2 valign="top">', preMouse, self.Cols[3])
        Write(outfile, '</pre></td><td valign="top">', preMouse, self.Cols[4])
        Write(outfile, '</pre></td></tr></table>\n<div id=tb class=tb> </div>\n')
        for k = 1, tipListMax do
            local tip = self.TipList[k]
            if tip ~= nil then
                Write(outfile, '<div id=p' .. (k - 1) .. ' class=tt>' .. tip .. '</div>\n')
            end
        end
        self.TipList = nil
        rtnVal = 1
    else
        local errMsg = self.Error or 'No EXIF or TIFF information found in image'
        Write(outfile, title .. '</title></head><body>\n' .. errMsg .. '\n')
        rtnVal = 0
    end
    Write(outfile, '</body></html>\n')
    for k = 1, 4 do self.Cols[k] = '' end -- free memory
    if err then
        err = (err:gsub('[()]', ''))
        self.ERROR = err
        return -1
    end
    return rtnVal
end

--------------------------------------------------------------------------------
-- Finish dumping of TIFF image data
-- Inputs: 0) HtmlDump object ref, 1) ExifTool object ref, 2) length of file
-- (this really belongs in Image::ExifTool::Exif, but is placed here so it
--  is only compiled when needed)

-- list of all indirectly referenced TIFF data tags
local offsetPair = {
    StripOffsets = 'StripByteCounts',
    TileOffsets = 'TileByteCounts',
    FreeOffsets = 'FreeByteCounts',
    ThumbnailOffset = 'ThumbnailLength',
    PreviewImageStart = 'PreviewImageLength',
    JpgFromRawStart = 'JpgFromRawLength',
    OtherImageStart = 'OtherImageLength',
    PreviewJXLStart = 'PreviewJXLLength',
    ImageOffset = 'ImageByteCount',
    AlphaOffset = 'AlphaByteCount',
    MPImageStart = 'MPImageLength',
    IDCPreviewStart = 'IDCPreviewLength',
    SamsungRawPointersOffset = 'SamsungRawPointersLength',
}

-- Minimal stand-in for `$et->GetInfo($tagName, {Group1 => $g})`: full
-- GetInfo (ExifTool.pm:3235) runs ParseArguments/SetFoundTags, which this
-- port's ExifTool:GetInfo does not yet accept a bare tag-name selector for.
-- Scoped locally here rather than widening the shared GetInfo, since the
-- only two callers (both below) just need "every VALUE key with this bare
-- tag name, optionally restricted to one Group1".
local function getInfoByTag(et, tagName, group1)
    local info = {}
    for key in pairs(et.VALUE) do
        local bare = key:match('^(.-) %(%d+%)$') or key
        if bare == tagName and (group1 == nil or et:GetGroup(key, 1) == group1) then
            local v = et:GetValue(key)
            if v ~= nil then info[key] = v end
        end
    end
    return info
end

function HtmlDump:FinishTiffDump(et, size)
    -- add TIFF data to html dump
    local tags = {}
    for tag in pairs(offsetPair) do tags[#tags + 1] = tag end
    tsort(tags)
    for _, tag in ipairs(tags) do
        local info = getInfoByTag(et, tag)
        if next(info) == nil then goto nextTag end
        -- Panasonic hack: StripOffsets is not valid for Panasonic RW2 files,
        -- and StripRowBytes is not valid for some RAW images
        if tag == 'StripOffsets' and et.TAG_INFO[tag] and et.TAG_INFO[tag].PanasonicHack then
            -- use RawDataOffset instead if available since it is valid in RW2
            local info2 = getInfoByTag(et, 'RawDataOffset')
            if next(info2) == nil then info2 = info end
            local keys = {}
            for k in pairs(info2) do keys[#keys + 1] = k end
            local offset = info2[keys[1]]
            local raf = et.RAF
            -- ignore StripByteCounts and assume raw data runs to the end of file
            if #keys == 1 and perl.isMatch(offset, [[^\d+$]]) and raf then
                local pos = raf:Tell()
                raf:Seek(0, 2)  -- seek to end
                local len = raf:Tell() - perl.num(offset)
                raf:Seek(pos, 0)
                if len > 0 then
                    self:Add(perl.num(offset), len, '(Panasonic raw data)', 'Size: ' .. len .. ' bytes', 0x08)
                    goto nextTag
                end
            end
        end
        do
            local keys = {}
            for k in pairs(info) do keys[#keys + 1] = k end
            tsort(keys)
            for _, key in ipairs(keys) do
                -- upstream: `my $name = Image::ExifTool::GetTagName($key);`
                -- here too -- computed but never actually used below (dead
                -- in the Perl original as well); dropped to avoid an unused-
                -- local lint warning
                local grp1 = et:GetGroup(key, 1)
                local info2 = getInfoByTag(et, offsetPair[tag], grp1)
                local key2 = offsetPair[tag]
                local suffix = key:match('( .*)')
                if suffix then key2 = key2 .. suffix end
                if perlTruthy(info2[key2]) then
                    local offsets = info[key]
                    local byteCounts = info2[key2]
                    -- ignore primary MPImage (this is the whole JPEG)
                    local skip = tag == 'MPImageStart' and offsets == '0'
                    if not skip then
                        -- upstream shift()s both lists in lockstep, merging
                        -- (mutating) the new front element when it is
                        -- contiguous with the block just consumed -- ported
                        -- literally with table.remove(_, 1) as the shift
                        local offList = perl.split(' ', perlStr(offsets))
                        local bcList = perl.split(' ', perlStr(byteCounts))
                        local num = #offList
                        local li = 0
                        local padBytes = 0
                        local idx = 0
                        while #offList > 0 and #bcList > 0 do
                            local offset = tonumber(table.remove(offList, 1))
                            local byteCount = tonumber(table.remove(bcList, 1))
                            local endOff = offset + byteCount
                            local combined = false
                            if #offList > 0 and #bcList > 0 then
                                -- show data as contiguous if only normal pad bytes between blocks
                                local nextOff = tonumber(offList[1])
                                if (endOff & 0x01) ~= 0 and endOff + 1 == nextOff then
                                    endOff = endOff + 1
                                    padBytes = padBytes + 1 -- count them
                                end
                                if endOff == nextOff then
                                    -- combine these two blocks
                                    bcList[1] = perlStr(tonumber(bcList[1]) + (nextOff - offset))
                                    offList[1] = perlStr(offset)
                                    combined = true
                                end
                            end
                            if not combined then
                                local msg = et:GetGroup(key, 1) .. ':' .. tag
                                -- upstream: `$msg =~ s/(Offsets?|Start)$/ /;` --
                                -- a real regex alternation, must go through the
                                -- perl facade (raw Lua patterns have no `|`)
                                msg = perl.subst(msg, [[(Offsets?|Start)$]], ' ')
                                if num > 1 then
                                    if li ~= idx then msg = msg .. li .. '-' end
                                    msg = msg .. idx .. ' '
                                    li = idx + 1
                                end
                                msg = msg .. 'data'
                                local tipStr = 'Size: ' .. byteCount .. ' bytes'
                                if padBytes > 0 then tipStr = tipStr .. ', incl. ' .. padBytes .. ' pad bytes' end
                                self:Add(offset, byteCount, '(' .. msg .. ')', tipStr, 0x08)
                            end
                            idx = idx + 1
                        end
                    end
                end
            end
        end
        ::nextTag::
    end
    -- find offset of last dumped information, and dump any unknown trailer
    local last = 0
    for start, list in pairs(self.Block) do
        for _, blockInfo in ipairs(list) do
            local endB = start + blockInfo[1]
            if last < endB then last = endB end
        end
    end
    local diff = size - last
    if diff > 0 and (last ~= 0 or perl.truthy(et:Options('Unknown'))) then
        if diff > 1 or (size & 0x01) ~= 0 then
            self:Add(last, diff, '[unknown data]', 'Size: ' .. diff .. ' bytes', 0x08)
        else
            self:Add(last, diff, '[trailing pad byte]', nil, 0x08)
        end
    end
end

return HtmlDump
