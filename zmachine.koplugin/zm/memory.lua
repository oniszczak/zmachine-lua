-- Z-machine memory image.
--
-- Addresses are Z-machine addresses (0-based); Lua strings are 1-based.
-- Only memory below the static base is writable, so we keep that region in a
-- byte table and read everything above it straight out of the original string.
-- For hhgg.z3 that's ~9.7KB mutable out of 113KB, which matters on a K3.

local Memory = {}
Memory.__index = Memory

function Memory.load(path)
    local f, err = io.open(path, "rb")
    if not f then return nil, err end
    local data = f:read("*a")
    f:close()
    if not data or #data < 64 then return nil, "file too short to be a story file" end

    local self = setmetatable({ data = data, size = #data }, Memory)
    self.static_base = self:raw8(0x0e) * 256 + self:raw8(0x0f)

    -- mutable shadow of dynamic memory
    local dyn = {}
    for a = 0, self.static_base - 1 do dyn[a] = string.byte(data, a + 1) end
    self.dyn = dyn
    return self
end

function Memory:raw8(addr)
    local b = string.byte(self.data, addr + 1)
    if not b then error(("read out of bounds at 0x%04x"):format(addr)) end
    return b
end

function Memory:u8(addr)
    if addr < self.static_base then return self.dyn[addr] end
    return self:raw8(addr)
end

function Memory:u16(addr)
    return self:u8(addr) * 256 + self:u8(addr + 1)
end

function Memory:w8(addr, v)
    v = v % 256
    if addr >= self.static_base then
        error(("write to static memory at 0x%04x"):format(addr))
    end
    self.dyn[addr] = v
end

function Memory:w16(addr, v)
    v = v % 65536
    self:w8(addr, math.floor(v / 256))
    self:w8(addr + 1, v % 256)
end

function Memory:bytes(addr, n)
    local t = {}
    for i = 0, n - 1 do t[i + 1] = string.char(self:u8(addr + i)) end
    return table.concat(t)
end

function Memory:header()
    local h = {
        version     = self:u8(0x00),
        flags1      = self:u8(0x01),
        release     = self:u16(0x02),
        high_mem    = self:u16(0x04),
        initial_pc  = self:u16(0x06),
        dictionary  = self:u16(0x08),
        objects     = self:u16(0x0a),
        globals     = self:u16(0x0c),
        static_mem  = self:u16(0x0e),
        flags2      = self:u16(0x10),
        serial      = self:bytes(0x12, 6),
        abbrev      = self:u16(0x18),
        length_word = self:u16(0x1a),
        checksum    = self:u16(0x1c),
    }
    local scale = (h.version <= 3 and 2) or (h.version <= 5 and 4) or 8
    h.file_length = h.length_word * scale
    return h
end

function Memory:verify_checksum()
    local h = self:header()
    if h.file_length == 0 then return nil, "no length in header" end
    if h.file_length > self.size then return false, nil end
    local sum = 0
    for i = 0x40, h.file_length - 1 do
        sum = (sum + string.byte(self.data, i + 1)) % 65536
    end
    return sum == h.checksum, sum
end

function Memory:unpack_addr(paddr)
    local v = self:u8(0x00)
    if v <= 3 then return paddr * 2
    elseif v <= 5 then return paddr * 4
    else error("packed addresses for version " .. v .. " not supported") end
end

-- snapshot / restore of dynamic memory, for save games
function Memory:snapshot_dynamic()
    local t = {}
    for a = 0, self.static_base - 1 do t[a] = self.dyn[a] end
    return t
end

function Memory:restore_dynamic(t)
    for a = 0, self.static_base - 1 do self.dyn[a] = t[a] end
end

return Memory
