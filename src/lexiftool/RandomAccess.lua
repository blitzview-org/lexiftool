--------------------------------------------------------------------------------
-- File:         lexiftool/RandomAccess.lua
-- Ported from:  lib/File/RandomAccess.pm
--
-- Description:  Buffer to support random access reading of sequential file
--
-- Revisions:    02/11/2004 - P. Harvey Created
--               02/20/2004 - P. Harvey Added flag to disable SeekTest in new()
--               11/18/2004 - P. Harvey Fixed bug with seek relative to end of file
--               01/02/2005 - P. Harvey Added DEBUG code
--               01/09/2006 - P. Harvey Fixed bug in ReadLine() when using
--                            multi-character EOL sequences
--               02/20/2006 - P. Harvey Fixed bug where seek past end of file could
--                            generate "substr outside string" warning
--               06/10/2006 - P. Harvey Decreased $CHUNK_SIZE from 64k to 8k
--               11/23/2006 - P. Harvey Limit reads to < 0x80000000 bytes
--               11/26/2008 - P. Harvey Fixed bug in ReadLine when reading from a
--                            scalar with a multi-character newline
--               01/24/2009 - PH Protect against reading too much at once
--               10/04/2018 - PH Added NoBuffer option
--               01/20/2024 - PH Set ERROR on file read error
--
-- Notes:        Calls the normal file i/o routines unless SeekTest() fails, in
--               which case the file is buffered in memory to allow random access.
--               SeekTest() is called automatically when the object is created
--               unless specified.
--
--               May also be used for string i/o (just pass a scalar reference)
--
--               Sets internal ERROR member from $! if there is an error reading
--               the file.
--
-- Legal:        Copyright (c) 2003-2026, Phil Harvey (philharvey66 at gmail.com)
--               This library is free software; you can redistribute it and/or
--               modify it under the same terms as Perl itself.
--
-- Port notes:   Complete port of RandomAccess.pm: every sub, in upstream
--               order.  Deviations forced by Lua:
--               - Read and ReadLine return (count, data) instead of writing
--                 the caller's buffer through $_[0]; ReadLine takes the
--                 record separator as argument (Perl's global `$/`, default
--                 "\n").
--               - A Lua string is a value, so BUFF_PT holds the buffer
--                 string itself (replaced on append) instead of a reference;
--                 new() takes a string -- or the carray of a written
--                 in-memory file, read through a copy -- for string i/o
--                 (upstream: a SCALAR ref).
--               - Direct (unbuffered) ReadLine on a seekable file reads
--                 CHUNK_SIZE blocks and seeks back past the separator, since
--                 Lua's file:read has no `$/` (upstream: `<$fp>`).
--               - Port helpers without an upstream sub (after Close):
--                 Length, ReadFile, IsPlainFile.
--------------------------------------------------------------------------------

local perl = require('lexiftool.perl')
local sprintf = perl.sprintf
local tsort = perl.tsort

local RandomAccess = {}
RandomAccess.__index = RandomAccess

-- constants
local CHUNK_SIZE = 8192  -- size of chunks to read from file (must be power of 2)
local SKIP_SIZE = 65536  -- size to skip when fast-forwarding over sequential data
local SLURP_CHUNKS = 16  -- read this many chunks at a time when slurping

-- (port helper: Perl's read($fp, $buff, $len) -- returns the number of bytes
--  read (0 at EOF, nil on error) and the data; sets ERROR like `$!`)
local function read(self, fp, len)
    local ok, data = pcall(fp.read, fp, len)
    if not ok then
        self.ERROR = data or 'Error reading from file'
        return nil, ''
    end
    if not data then return 0, '' end
    return #data, data
end

--------------------------------------------------------------------------------
-- Create new RandomAccess object
-- Inputs: 0) file reference or scalar reference
--         1) flag set if file is already random access (disables automatic SeekTest)
function RandomAccess.new(filePt, isRandom)
    local self

    if type(filePt) == 'string' or type(filePt) == 'number' or perl.isCarray(filePt) then
        -- string i/o
        -- (a carray -- the mutable scalar a WriteInfo output box holds --
        --  is read through a copy of its bytes; a number is a scalar too,
        --  read through its string form)
        filePt = perl.str(filePt)
        self = {
            BUFF_PT = filePt,
            BASE = 0,
            POS = 0,
            LEN = #filePt,
            TESTED = -1,
        }
        setmetatable(self, RandomAccess)
    else
        -- file i/o
        local buff = ''
        self = {
            FILE_PT = filePt,   -- file pointer
            BUFF_PT = buff,     -- reference to file data
            BASE = 0,           -- location of start of buffer in file
            POS = 0,            -- current position in buffer
            LEN = 0,            -- length of data in buffer
            TESTED = 0,         -- 0=untested, 1=passed, -1=failed (requires buffering)
        }
        setmetatable(self, RandomAccess)
        if not isRandom then self:SeekTest() end
    end
    return self
end

--------------------------------------------------------------------------------
-- Enable DEBUG code
-- Inputs: 0) reference to RandomAccess object
function RandomAccess:Debug()
    self.DEBUG = { }
end

--------------------------------------------------------------------------------
-- Perform seek test and turn on buffering if necessary
-- Inputs: 0) reference to RandomAccess object
-- Returns: 1 if seek test passed (ie. no buffering required)
-- Notes: Must be done before any other i/o
function RandomAccess:SeekTest()
    if self.TESTED == 0 then
        local fp = self.FILE_PT
        if fp:seek('cur', 1) and fp:seek('cur', -1) then
            self.TESTED = 1     -- test passed
        else
            self.TESTED = -1    -- test failed (requires buffering)
        end
    end
    return self.TESTED == 1 and 1 or 0
end

--------------------------------------------------------------------------------
-- Get current position in file
-- Inputs: 0) reference to RandomAccess object
-- Returns: current position in file
function RandomAccess:Tell()
    local rtnVal
    if self.TESTED < 0 then
        rtnVal = self.POS + self.BASE
    else
        rtnVal = self.FILE_PT:seek('cur')
    end
    return rtnVal
end

--------------------------------------------------------------------------------
-- Seek to position in file
-- Inputs: 0) reference to RandomAccess object
--         1) position, 2) whence (0 or undef=from start, 1=from cur pos, 2=from end)
-- Returns: 1 on success
-- Notes: When buffered, this doesn't quite behave like seek() since it will return
--        success even if you seek outside the limits of the file.  However if you
--        do this, you will get an error on your next Read().
local WHENCE = { [0] = 'set', [1] = 'cur', [2] = 'end' }
function RandomAccess:Seek(num, whence)
    if whence == nil then whence = 0 end
    local rtnVal
    if self.TESTED < 0 then
        local newPos
        if whence == 0 then
            newPos = num - self.BASE    -- from start of file
        elseif whence == 1 then
            newPos = num + self.POS     -- relative to current position
        elseif self.NoBuffer and self.FILE_PT then
            newPos = -1     -- (can't seek relative to end if no buffering)
        else
            self:Slurp()                -- read whole file into buffer
            newPos = num + self.LEN     -- relative to end of file
        end
        if newPos >= 0 and
            -- can't go backwards in unbuffered non-seekable file
            (not self.NoBuffer or newPos >= self.POS)
        then
            self.POS = newPos
            rtnVal = 1
        end
    else
        if self.FILE_PT:seek(WHENCE[whence] or 'set', num) then rtnVal = 1 end
    end
    return rtnVal
end

--------------------------------------------------------------------------------
-- Read from the file
-- Inputs: 0) reference to RandomAccess object, 1) bytes to read
-- Returns: Number of bytes read, and the data read
function RandomAccess:Read(len)
    local rtnVal, data
    len = math.tointeger(len) or math.floor(len)    -- (Perl truncates the length)

    -- protect against reading too much at once
    -- (also from dying with a "Negative length" error)
    if len & 0xf8000000 ~= 0 then
        if len < 0 then return 0, '' end
        -- read in smaller blocks because Windows attempts to pre-allocate
        -- memory for the full size, which can lead to an out-of-memory error
        local maxLen = 0x4000000 -- (MUST be less than bitmask in "if" above)
        local num, buf0 = RandomAccess.Read(self, maxLen)
        if num < maxLen then return num, buf0 end
        local parts = { buf0 }
        while true do
            len = len - maxLen
            if len <= 0 then break end
            local l = len < maxLen and len or maxLen
            local n, buff = RandomAccess.Read(self, l)
            if n == 0 then break end
            parts[#parts + 1] = buff
            num = num + n
            if n < l then break end
        end
        return num, table.concat(parts)
    end
    -- read through our buffer if necessary
    if self.TESTED < 0 then
        -- purge old data before reading in NoBuffer mode
        if self.NoBuffer then
            if self:Purge() == 0 then return 0, '' end
        end
        local buff
        local newPos = self.POS + len
        -- number of bytes to read from file
        local num = newPos - self.LEN
        if num > 0 and self.FILE_PT then
            -- read data from file in multiples of $CHUNK_SIZE
            num = ((num - 1) | (CHUNK_SIZE - 1)) + 1
            num, buff = read(self, self.FILE_PT, num)
            if num and num > 0 then
                self.BUFF_PT = self.BUFF_PT .. buff
                self.LEN = self.LEN + num
            end
        end
        -- number of bytes left in data buffer
        num = self.LEN - self.POS
        if len <= num then
            rtnVal = len
        elseif num <= 0 then
            return 0, ''
        else
            rtnVal = num
        end
        -- return data from our buffer
        data = self.BUFF_PT:sub(self.POS + 1, self.POS + rtnVal)
        self.POS = self.POS + rtnVal
    else
        -- read directly from file
        rtnVal, data = read(self, self.FILE_PT, len)
        if rtnVal == nil then
            rtnVal = 0
        end
    end
    if self.DEBUG then
        local pos = self:Tell() - rtnVal
        if not (self.DEBUG[pos] and self.DEBUG[pos] > rtnVal) then
            self.DEBUG[pos] = rtnVal
        end
    end
    return rtnVal, data
end

--------------------------------------------------------------------------------
-- Read a line from file (end of line is $/)
-- Inputs: 0) reference to RandomAccess object, 1) end of line ($/, default "\n")
-- Returns: Number of bytes read, and the line read
function RandomAccess:ReadLine(rs)
    rs = rs or '\n'
    local rtnVal, line
    local fp = self.FILE_PT

    if self.TESTED < 0 then
        local num, buff
        if self.NoBuffer then
            if self:Purge() == 0 then return 0, '' end
        end
        local pos = self.POS
        if fp then
            -- make sure we have some data after the current position
            while self.LEN <= pos do
                num, buff = read(self, fp, CHUNK_SIZE)
                if not num or num == 0 then
                    return 0, ''
                end
                self.BUFF_PT = self.BUFF_PT .. buff
                self.LEN = self.LEN + num
            end
            -- scan and read until we find the EOL (or hit EOF)
            while true do
                local p = self.BUFF_PT:find(rs, pos + 1, true)
                pos = p and p - 1 or -1
                if pos >= 0 then
                    pos = pos + #rs
                    break
                end
                pos = self.LEN  -- have scanned to end of buffer
                num, buff = read(self, fp, CHUNK_SIZE)
                if not num or num == 0 then
                    break
                end
                self.BUFF_PT = self.BUFF_PT .. buff
                self.LEN = self.LEN + num
            end
        else
            -- string i/o
            local p = self.BUFF_PT:find(rs, pos + 1, true)
            pos = p and p - 1 or -1
            if pos < 0 then
                pos = self.LEN
                if self.POS > pos then self.POS = pos end
            else
                pos = pos + #rs
            end
        end
        -- read the line from our buffer
        rtnVal = pos - self.POS
        line = self.BUFF_PT:sub(self.POS + 1, self.POS + rtnVal)
        self.POS = pos
    else
        -- (upstream: `$_[0] = <$fp>` -- Lua's file:read knows no `$/`, so
        --  read chunks and give back what follows the separator)
        local parts = {}
        local tail = '' -- (end of the previous chunk, for a separator split across chunks)
        while true do
            local n, chunk = read(self, fp, CHUNK_SIZE)
            if not n or n == 0 then break end
            local search = tail .. chunk
            local _, e = search:find(rs, 1, true)
            if e then
                -- found the separator: keep up to it, give back the rest
                local keep = e - #tail
                parts[#parts + 1] = chunk:sub(1, keep)
                if keep < n then fp:seek('cur', keep - n) end
                break
            end
            parts[#parts + 1] = chunk
            if #rs > 1 then tail = search:sub(-(#rs - 1)) end
        end
        line = table.concat(parts)
        rtnVal = #line
    end
    if self.DEBUG then
        local pos = self:Tell() - rtnVal
        if not (self.DEBUG[pos] and self.DEBUG[pos] > rtnVal) then
            self.DEBUG[pos] = rtnVal
        end
    end
    return rtnVal, line
end

--------------------------------------------------------------------------------
-- Read whole file into buffer (without changing read pointer)
-- Inputs: 0) reference to RandomAccess object
function RandomAccess:Slurp()
    local fp = self.FILE_PT
    if not fp then return end
    -- read whole file into buffer (in large chunks)
    local buff, num
    while true do
        num, buff = read(self, fp, CHUNK_SIZE * SLURP_CHUNKS)
        if not num or num == 0 then
            break
        end
        self.BUFF_PT = self.BUFF_PT .. buff
        self.LEN = self.LEN + num
    end
end

--------------------------------------------------------------------------------
-- Purge internal buffer [internal use only]
-- Inputs: 0) reference to RandomAccess object
-- Returns: 1 on success, or 0 if current buffer position is negative
-- Notes: This is called only in NoBuffer mode
function RandomAccess:Purge()
    if not self.FILE_PT then return 1 end
    if self.POS < 0 then return 0 end   -- error if we can't read from here
    if self.POS > CHUNK_SIZE then
        local purge = self.POS - (self.POS % CHUNK_SIZE)
        if purge >= self.LEN then
            -- read up to current position in 64k chunks, discarding as we go
            while self.POS > self.LEN do
                self.BASE = self.BASE + self.LEN
                self.POS = self.POS - self.LEN
                self.BUFF_PT = ''
                local num, buff = read(self, self.FILE_PT, SKIP_SIZE)
                if num == nil then
                    self.LEN = 0
                    break
                end
                self.BUFF_PT = buff
                self.LEN = num
                if self.LEN < SKIP_SIZE then break end
            end
        elseif purge > 0 then
            self.BUFF_PT = self.BUFF_PT:sub(purge + 1)
            self.BASE = self.BASE + purge
            self.POS = self.POS - purge
            self.LEN = self.LEN - purge
        end
    end
    return 1
end

--------------------------------------------------------------------------------
-- Set binary mode
-- Inputs: 0) reference to RandomAccess object
function RandomAccess:BinMode()
    if self.FILE_PT then perl.binmode(self.FILE_PT) end
end

--------------------------------------------------------------------------------
-- Close the file and free the buffer
-- Inputs: 0) reference to RandomAccess object
function RandomAccess:Close()
    if self.DEBUG then
        if self:Seek(0, 2) then
            self.DEBUG[self:Tell()] = 0     -- set EOF marker
            local last
            local tot = 0
            local bad = 0
            local keys = {}
            for k in pairs(self.DEBUG) do keys[#keys + 1] = k end
            tsort(keys)
            for _, pos in ipairs(keys) do
                local len = self.DEBUG[pos]
                if last ~= nil and last < pos then
                    local bytes = pos - last
                    tot = tot + bytes
                    self:Seek(last)
                    local _, buff = self:Read(bytes)
                    local warn = ''
                    if buff:find('[^%z]') then
                        bad = bad + (pos - last)
                        warn = ' - NON-ZERO!'
                    end
                    perl.print(io.stdout, sprintf("0x%.8x - 0x%.8x (%d bytes)" .. warn .. "\n", last, pos, bytes))
                end
                local cur = pos + len
                if not (last ~= nil and last > cur) then last = cur end
            end
            perl.print(io.stdout, tot .. " bytes missed")
            if bad ~= 0 then perl.print(io.stdout, ", " .. bad .. " non-zero!") end
            perl.print(io.stdout, "\n")
        else
            perl.print(io.stderr, "File::RandomAccess DEBUG not working (file already closed?)\n")
        end
        self.DEBUG = nil
    end
    -- close the file
    if self.FILE_PT then
        self.FILE_PT:close()
        self.FILE_PT = nil
    end
    -- reset the buffer
    local emptyBuff = ''
    self.BUFF_PT = emptyBuff
    self.BASE = 0
    self.LEN = 0
    self.POS = 0
end

--------------------------------------------------------------------------------
-- (port helpers -- no upstream counterpart)

-- Get file length without changing the read position.
-- Returns: length in bytes
function RandomAccess:Length()
    if self.TESTED < 0 then
        self:Slurp()
        return self.BASE + self.LEN
    end
    local fp = self.FILE_PT
    local cur = fp:seek('cur')
    local len = fp:seek('end')
    fp:seek('set', cur)
    return len
end

-- Read the whole file into a string, from the start.
-- Returns: file contents ('' on failure)
function RandomAccess:ReadFile()
    self:Seek(0, 0)
    local _, data = self:Read(self:Length())
    return data or ''
end

-- Return true if the underlying source is a file (not string i/o).
function RandomAccess:IsPlainFile()
    return self.FILE_PT ~= nil
end

return RandomAccess
