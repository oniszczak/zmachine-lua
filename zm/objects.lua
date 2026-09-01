-- Object table (v1-3 layout).
--
--   <31 words of property defaults>
--   <objects, 9 bytes each>
--       4 bytes attributes (32 flags, bit 0 = attribute 0, MSB first)
--       1 byte parent, 1 byte sibling, 1 byte child
--       2 bytes address of the property table
--
-- Property table:
--   1 byte  length of the short name in 2-byte words
--   n words encoded short name
--   then properties, highest number first, each:
--       1 size byte: bits 0-4 property number, bits 5-7 (length - 1)
--       data
--   terminated by a size byte of 0

local Text = require("zm.text")

local Objects = {}
Objects.__index = Objects

local ENTRY_SIZE = 9
local DEFAULTS   = 31

function Objects.new(mem)
    local h = mem:header()
    return setmetatable({
        mem = mem,
        base = h.objects,
        first = h.objects + DEFAULTS * 2,
    }, Objects)
end

function Objects:addr(obj)
    if obj < 1 or obj > 255 then error("bad object number " .. tostring(obj)) end
    return self.first + (obj - 1) * ENTRY_SIZE
end

function Objects:property_default(n)
    return self.mem:u16(self.base + (n - 1) * 2)
end

-- attributes ------------------------------------------------------------
function Objects:test_attr(obj, attr)
    local byte = self.mem:u8(self:addr(obj) + math.floor(attr / 8))
    local bit = 7 - (attr % 8)
    return math.floor(byte / 2 ^ bit) % 2 == 1
end

function Objects:set_attr(obj, attr, on)
    local a = self:addr(obj) + math.floor(attr / 8)
    local byte = self.mem:u8(a)
    local bit = 2 ^ (7 - (attr % 8))
    local has = math.floor(byte / bit) % 2 == 1
    if on and not has then byte = byte + bit
    elseif (not on) and has then byte = byte - bit end
    self.mem:w8(a, byte)
end

-- tree ------------------------------------------------------------------
function Objects:parent(obj)  return self.mem:u8(self:addr(obj) + 4) end
function Objects:sibling(obj) return self.mem:u8(self:addr(obj) + 5) end
function Objects:child(obj)   return self.mem:u8(self:addr(obj) + 6) end

function Objects:set_parent(obj, v)  self.mem:w8(self:addr(obj) + 4, v) end
function Objects:set_sibling(obj, v) self.mem:w8(self:addr(obj) + 5, v) end
function Objects:set_child(obj, v)   self.mem:w8(self:addr(obj) + 6, v) end

function Objects:remove(obj)
    local p = self:parent(obj)
    if p == 0 then return end
    local c = self:child(p)
    if c == obj then
        self:set_child(p, self:sibling(obj))
    else
        while c ~= 0 do
            local nxt = self:sibling(c)
            if nxt == obj then
                self:set_sibling(c, self:sibling(obj))
                break
            end
            c = nxt
        end
    end
    self:set_parent(obj, 0)
    self:set_sibling(obj, 0)
end

function Objects:insert(obj, dest)
    self:remove(obj)
    self:set_sibling(obj, self:child(dest))
    self:set_child(dest, obj)
    self:set_parent(obj, dest)
end

-- properties ------------------------------------------------------------
function Objects:prop_table(obj)
    return self.mem:u16(self:addr(obj) + 7)
end

function Objects:name(obj)
    local p = self:prop_table(obj)
    local words = self.mem:u8(p)
    if words == 0 then return "" end
    return (Text.decode(self.mem, p + 1))
end

-- iterate properties: returns addr of size byte, number, length, data addr
function Objects:each_prop(obj)
    local p = self:prop_table(obj)
    local a = p + 1 + self.mem:u8(p) * 2
    return function()
        local size = self.mem:u8(a)
        if size == 0 then return nil end
        local num = size % 32
        local len = math.floor(size / 32) + 1
        local data = a + 1
        a = data + len
        return num, len, data
    end
end

function Objects:find_prop(obj, num)
    for n, len, data in self:each_prop(obj) do
        if n == num then return len, data end
    end
    return nil
end

function Objects:get_prop(obj, num)
    local len, data = self:find_prop(obj, num)
    if not len then return self:property_default(num) end
    if len == 1 then return self.mem:u8(data) end
    return self.mem:u16(data)
end

function Objects:get_prop_addr(obj, num)
    local _, data = self:find_prop(obj, num)
    return data or 0
end

function Objects:put_prop(obj, num, value)
    local len, data = self:find_prop(obj, num)
    if not len then error("put_prop on missing property " .. num) end
    if len == 1 then self.mem:w8(data, value % 256)
    else self.mem:w16(data, value) end
end

-- property number after `num` in the object's list (0 = first / end)
function Objects:next_prop(obj, num)
    if num == 0 then
        for n in self:each_prop(obj) do return n end
        return 0
    end
    local found = false
    for n in self:each_prop(obj) do
        if found then return n end
        if n == num then found = true end
    end
    if not found then error("get_next_prop on missing property " .. num) end
    return 0
end

return Objects
