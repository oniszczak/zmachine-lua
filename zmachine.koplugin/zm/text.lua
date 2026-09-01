-- ZSCII text decoding (Z-Machine Standards 1.1, section 3).
--
-- Text is stored as 16-bit words, each packing three 5-bit Z-characters:
--   bit 15    = end-of-string marker
--   bits 14-10, 9-5, 4-0 = the three Z-characters
--
-- Z-characters 6..31 index the current alphabet. 0 is a space. 1-3 introduce
-- an abbreviation. 4 and 5 shift the *next* character into A1 or A2 (in v3
-- these are single-character shifts, not locks).

local Text = {}

local A0 = "abcdefghijklmnopqrstuvwxyz"
local A1 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
-- A2 position 6 is the ZSCII escape and 7 is newline; both handled specially,
-- so those two slots are placeholders here.
local A2 = "\0\n0123456789.,!?_#'\"/\\-:()"

local ALPHABETS = { [0] = A0, [1] = A1, [2] = A2 }

-- Pull the raw Z-character stream starting at addr.
-- Returns the array of z-chars and the address just past the string.
function Text.zchars(mem, addr)
    local out, a = {}, addr
    while true do
        local w = mem:u16(a)
        a = a + 2
        out[#out + 1] = math.floor(w / 1024) % 32
        out[#out + 1] = math.floor(w / 32) % 32
        out[#out + 1] = w % 32
        if w >= 0x8000 then break end
        if a > mem.size then error("unterminated string at " .. addr) end
    end
    return out, a
end

-- Decode a string at addr. `depth` guards against abbreviation recursion,
-- which the standard forbids but corrupt files can still contain.
function Text.decode(mem, addr, depth)
    depth = depth or 0
    local zchars, next_addr = Text.zchars(mem, addr)
    local h = mem:header()
    local out = {}
    local alphabet = 0
    local i = 1

    while i <= #zchars do
        local z = zchars[i]

        if z == 0 then
            out[#out + 1] = " "
            alphabet = 0

        elseif z >= 1 and z <= 3 then
            -- abbreviation: 32*(z-1) + next zchar, indexing the abbrev table
            i = i + 1
            local x = zchars[i]
            if x and depth < 3 and h.abbrev ~= 0 then
                local entry = h.abbrev + 2 * (32 * (z - 1) + x)
                local target = mem:u16(entry) * 2   -- word address
                out[#out + 1] = Text.decode(mem, target, depth + 1)
            end
            alphabet = 0

        elseif z == 4 then
            alphabet = 1

        elseif z == 5 then
            alphabet = 2

        else
            if alphabet == 2 and z == 6 then
                -- ZSCII escape: the next two z-chars form a 10-bit code
                local hi, lo = zchars[i + 1], zchars[i + 2]
                i = i + 2
                if hi and lo then
                    local code = hi * 32 + lo
                    if code >= 32 and code <= 126 then
                        out[#out + 1] = string.char(code)
                    elseif code == 13 then
                        out[#out + 1] = "\n"
                    end
                end
            elseif alphabet == 2 and z == 7 then
                out[#out + 1] = "\n"
            else
                out[#out + 1] = ALPHABETS[alphabet]:sub(z - 5, z - 5)
            end
            alphabet = 0
        end

        i = i + 1
    end

    return table.concat(out), next_addr
end

return Text
