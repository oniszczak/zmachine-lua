-- Dictionary: word encoding, lookup, and input tokenising (v1-3).
--
-- Header at the dictionary address:
--   1 byte  n, the number of word separators
--   n bytes the separator characters (these tokenise as words in their own right)
--   1 byte  length of each entry
--   2 bytes number of entries
--   then the entries, sorted, each starting with 4 bytes of encoded text

local Dict = {}
Dict.__index = Dict

local A0 = "abcdefghijklmnopqrstuvwxyz"
local A2 = "\0\n0123456789.,!?_#'\"/\\-:()"

function Dict.new(mem)
    local h = mem:header()
    local d = h.dictionary
    local nsep = mem:u8(d)
    local seps = {}
    for i = 1, nsep do seps[string.char(mem:u8(d + i))] = true end
    local entry_len = mem:u8(d + 1 + nsep)
    local count = mem:u16(d + 2 + nsep)
    return setmetatable({
        mem = mem,
        seps = seps,
        entry_len = entry_len,
        count = count,
        first = d + 4 + nsep,
        resolution = (h.version <= 3) and 6 or 9,
    }, Dict)
end

-- Convert a word to the fixed-width z-character sequence used for lookup.
function Dict:zchars_for(word)
    local n = self.resolution
    local z = {}
    for i = 1, #word do
        if #z >= n then break end
        local c = word:sub(i, i)
        local a0 = A0:find(c, 1, true)
        if a0 then
            z[#z + 1] = a0 + 5
        else
            local a2 = A2:find(c, 1, true)
            if a2 and a2 > 2 then          -- skip the escape/newline slots
                z[#z + 1] = 5
                if #z < n then z[#z + 1] = a2 + 5 end
            else
                -- ZSCII escape: shift to A2, code 6, then two 5-bit halves
                local b = string.byte(c)
                z[#z + 1] = 5
                if #z < n then z[#z + 1] = 6 end
                if #z < n then z[#z + 1] = math.floor(b / 32) % 32 end
                if #z < n then z[#z + 1] = b % 32 end
            end
        end
    end
    while #z < n do z[#z + 1] = 5 end      -- pad with shift characters
    return z
end

-- Pack the z-characters into words, marking the last one.
function Dict:encode(word)
    local z = self:zchars_for(word)
    local words = {}
    for i = 1, #z, 3 do
        words[#words + 1] = z[i] * 1024 + z[i + 1] * 32 + z[i + 2]
    end
    words[#words] = words[#words] + 0x8000
    return words
end

-- Binary search; the dictionary is sorted by encoded value.
function Dict:lookup(word)
    local enc = self:encode(word)
    local lo, hi = 0, self.count - 1
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        local addr = self.first + mid * self.entry_len
        local cmp = 0
        for i = 1, #enc do
            local got = self.mem:u16(addr + (i - 1) * 2)
            if enc[i] < got then cmp = -1 break
            elseif enc[i] > got then cmp = 1 break end
        end
        if cmp == 0 then return addr
        elseif cmp < 0 then hi = mid - 1
        else lo = mid + 1 end
    end
    return 0
end

-- Split an input line into tokens. Spaces separate but are discarded;
-- the dictionary's separator characters are themselves tokens.
-- Returns a list of { text = , pos = } with pos 1-based within the line.
function Dict:tokenise(line)
    local out = {}
    local i = 1
    while i <= #line do
        local c = line:sub(i, i)
        if c == " " then
            i = i + 1
        elseif self.seps[c] then
            out[#out + 1] = { text = c, pos = i }
            i = i + 1
        else
            local start = i
            while i <= #line do
                local ch = line:sub(i, i)
                if ch == " " or self.seps[ch] then break end
                i = i + 1
            end
            out[#out + 1] = { text = line:sub(start, i - 1), pos = start }
        end
    end
    return out
end

return Dict
