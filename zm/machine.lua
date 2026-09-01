-- The Z-machine itself: instruction decode, opcode dispatch, call frames.
-- Targets version 3.
--
-- Instruction forms (Standards 1.1, section 4):
--   0xC0-0xFF  variable form  - bit 5 clear = 2OP, set = VAR; a types byte follows
--   0x80-0xBF  short form     - bits 4-5 give the operand type; 3 means 0OP
--   0x00-0x7F  long form      - always 2OP; bits 6 and 5 give the two types

local Memory  = require("zm.memory")
local Text    = require("zm.text")
local Objects = require("zm.objects")
local Dict    = require("zm.dict")

local Machine = {}
Machine.__index = Machine

local function signed(v)   if v >= 0x8000 then return v - 0x10000 end return v end
local function unsigned(v) return v % 65536 end

function Machine.new(mem, io_)
    local h = mem:header()
    if h.version ~= 3 then
        return nil, ("only version 3 is supported (this file is version %d)"):format(h.version)
    end
    local self = setmetatable({
        mem = mem, h = h, io = io_,
        objects = Objects.new(mem),
        dict = Dict.new(mem),
        pc = h.initial_pc,
        stack = {},
        frames = {},
        halted = false,
        rng = { seeded = false },
    }, Machine)

    -- Tell the game what kind of interpreter we are: no status line of its own,
    -- no split screen, variable-pitch font off.
    local f1 = mem:u8(0x01)
    f1 = f1 - (f1 % 2)                 -- clear bit 0 (we do provide a status line)
    if math.floor(f1 / 16) % 2 == 1 then f1 = f1 - 16 end   -- no split screen
    mem:w8(0x01, f1)

    self.frames[1] = { locals = {}, ret_pc = nil, store = nil, stack_base = 0 }
    return self
end

-- variables ---------------------------------------------------------------
function Machine:frame() return self.frames[#self.frames] end

function Machine:read_var(n)
    if n == 0 then
        local v = table.remove(self.stack)
        if v == nil then error("stack underflow") end
        return v
    elseif n < 16 then
        return self:frame().locals[n] or 0
    else
        return self.mem:u16(self.h.globals + (n - 16) * 2)
    end
end

function Machine:write_var(n, v)
    v = unsigned(v)
    if n == 0 then
        self.stack[#self.stack + 1] = v
    elseif n < 16 then
        self:frame().locals[n] = v
    else
        self.mem:w16(self.h.globals + (n - 16) * 2, v)
    end
end

-- instruction stream ------------------------------------------------------
function Machine:next8()  local v = self.mem:u8(self.pc);  self.pc = self.pc + 1; return v end
function Machine:next16() local v = self.mem:u16(self.pc); self.pc = self.pc + 2; return v end

function Machine:operand(kind)
    if kind == 0 then return self:next16()
    elseif kind == 1 then return self:next8()
    elseif kind == 2 then return self:read_var(self:next8())
    end
end

-- branching and returning -------------------------------------------------
function Machine:branch(cond)
    local b = self:next8()
    local on_true = b >= 0x80
    local off
    if math.floor(b / 64) % 2 == 1 then
        off = b % 64
    else
        off = (b % 64) * 256 + self:next8()
        if off >= 8192 then off = off - 16384 end
    end
    if (cond and true or false) == on_true then
        if off == 0 or off == 1 then
            self:do_return(off)
        else
            self.pc = self.pc + off - 2
        end
    end
end

function Machine:do_return(value)
    local frame = table.remove(self.frames)
    if not frame or frame.ret_pc == nil then
        self.halted = true
        return
    end
    for i = #self.stack, frame.stack_base + 1, -1 do self.stack[i] = nil end
    self.pc = frame.ret_pc
    if frame.store then self:write_var(frame.store, value) end
end

function Machine:call(paddr, args, store)
    if paddr == 0 then
        if store then self:write_var(store, 0) end
        return
    end
    local addr = self.mem:unpack_addr(paddr)
    local nlocals = self.mem:u8(addr)
    addr = addr + 1
    local locals = {}
    for i = 1, nlocals do
        locals[i] = self.mem:u16(addr)   -- v3 stores initial values
        addr = addr + 2
    end
    for i = 1, #args do
        if i <= nlocals then locals[i] = args[i] end
    end
    self.frames[#self.frames + 1] = {
        locals = locals, ret_pc = self.pc, store = store, stack_base = #self.stack,
    }
    self.pc = addr
end

-- output ------------------------------------------------------------------
function Machine:print(s) self.io.write(s) end

function Machine:print_inline()
    local s, nxt = Text.decode(self.mem, self.pc)
    self.pc = nxt
    self:print(s)
end

-- input -------------------------------------------------------------------
function Machine:sread(text_buf, parse_buf)
    if self.io.show_status then self.io.show_status(self) end
    local line = self.io.read_line()
    if line == nil then self.halted = true; return end
    line = line:lower()

    local max = self.mem:u8(text_buf)
    if #line > max then line = line:sub(1, max) end
    for i = 1, #line do self.mem:w8(text_buf + i, string.byte(line, i)) end
    self.mem:w8(text_buf + #line + 1, 0)

    local tokens = self.dict:tokenise(line)
    local maxw = self.mem:u8(parse_buf)
    local n = math.min(#tokens, maxw)
    self.mem:w8(parse_buf + 1, n)
    for i = 1, n do
        local t = tokens[i]
        local base = parse_buf + 2 + (i - 1) * 4
        self.mem:w16(base, self.dict:lookup(t.text))
        self.mem:w8(base + 2, #t.text)
        self.mem:w8(base + 3, t.pos)
    end
end

-- random ------------------------------------------------------------------
function Machine:random(range)
    range = signed(range)
    if range > 0 then
        return math.random(1, range)
    elseif range < 0 then
        math.randomseed(-range)
        return 0
    else
        math.randomseed(os.time())
        return 0
    end
end

-- ------------------------------------------------------------------------
-- opcode implementations
-- ------------------------------------------------------------------------

function Machine:store_result(v)
    self:write_var(self:next8(), v)
end

local OP2, OP1, OP0, OPV = {}, {}, {}, {}

-- 2OP --------------------------------------------------------------------
OP2[1]  = function(s, ...)                          -- je
    local a = select(1, ...)
    local n = select("#", ...)
    local eq = false
    for i = 2, n do if select(i, ...) == a then eq = true break end end
    s:branch(eq)
end
OP2[2]  = function(s, a, b) s:branch(signed(a) < signed(b)) end          -- jl
OP2[3]  = function(s, a, b) s:branch(signed(a) > signed(b)) end          -- jg
OP2[4]  = function(s, a, b)                                              -- dec_chk
    local v = signed(s:read_var(a)) - 1
    s:write_var(a, v)
    s:branch(v < signed(b))
end
OP2[5]  = function(s, a, b)                                              -- inc_chk
    local v = signed(s:read_var(a)) + 1
    s:write_var(a, v)
    s:branch(v > signed(b))
end
OP2[6]  = function(s, a, b) s:branch(a ~= 0 and s.objects:parent(a) == b) end  -- jin
OP2[7]  = function(s, a, b)                                              -- test
    local both = 0
    for bit = 0, 15 do
        local m = 2 ^ bit
        if math.floor(a / m) % 2 == 1 and math.floor(b / m) % 2 == 1 then both = both + m end
    end
    s:branch(both == b)
end
OP2[8]  = function(s, a, b)                                              -- or
    local r = 0
    for bit = 0, 15 do
        local m = 2 ^ bit
        if math.floor(a / m) % 2 == 1 or math.floor(b / m) % 2 == 1 then r = r + m end
    end
    s:store_result(r)
end
OP2[9]  = function(s, a, b)                                              -- and
    local r = 0
    for bit = 0, 15 do
        local m = 2 ^ bit
        if math.floor(a / m) % 2 == 1 and math.floor(b / m) % 2 == 1 then r = r + m end
    end
    s:store_result(r)
end
OP2[10] = function(s, a, b) s:branch(a ~= 0 and s.objects:test_attr(a, b)) end   -- test_attr
OP2[11] = function(s, a, b) if a ~= 0 then s.objects:set_attr(a, b, true) end end  -- set_attr
OP2[12] = function(s, a, b) if a ~= 0 then s.objects:set_attr(a, b, false) end end -- clear_attr
OP2[13] = function(s, a, b) s:write_var(a, b) end                        -- store
OP2[14] = function(s, a, b) if a ~= 0 and b ~= 0 then s.objects:insert(a, b) end end -- insert_obj
OP2[15] = function(s, a, b) s:store_result(s.mem:u16(a + 2 * signed(b))) end      -- loadw
OP2[16] = function(s, a, b) s:store_result(s.mem:u8(a + signed(b))) end           -- loadb
OP2[17] = function(s, a, b) s:store_result(s.objects:get_prop(a, b)) end          -- get_prop
OP2[18] = function(s, a, b) s:store_result(s.objects:get_prop_addr(a, b)) end     -- get_prop_addr
OP2[19] = function(s, a, b) s:store_result(s.objects:next_prop(a, b)) end         -- get_next_prop
OP2[20] = function(s, a, b) s:store_result(signed(a) + signed(b)) end             -- add
OP2[21] = function(s, a, b) s:store_result(signed(a) - signed(b)) end             -- sub
OP2[22] = function(s, a, b) s:store_result(signed(a) * signed(b)) end             -- mul
OP2[23] = function(s, a, b)                                                       -- div
    local x, y = signed(a), signed(b)
    if y == 0 then error("division by zero") end
    local q = x / y
    s:store_result(q >= 0 and math.floor(q) or -math.floor(-q))
end
OP2[24] = function(s, a, b)                                                       -- mod
    local x, y = signed(a), signed(b)
    if y == 0 then error("division by zero") end
    local q = x / y
    q = q >= 0 and math.floor(q) or -math.floor(-q)
    s:store_result(x - q * y)
end

-- 1OP --------------------------------------------------------------------
OP1[0]  = function(s, a) s:branch(a == 0) end                            -- jz
OP1[1]  = function(s, a)                                                 -- get_sibling
    local v = a ~= 0 and s.objects:sibling(a) or 0
    s:store_result(v); s:branch(v ~= 0)
end
OP1[2]  = function(s, a)                                                 -- get_child
    local v = a ~= 0 and s.objects:child(a) or 0
    s:store_result(v); s:branch(v ~= 0)
end
OP1[3]  = function(s, a) s:store_result(a ~= 0 and s.objects:parent(a) or 0) end  -- get_parent
OP1[4]  = function(s, a)                                                 -- get_prop_len
    if a == 0 then s:store_result(0) return end
    s:store_result(math.floor(s.mem:u8(a - 1) / 32) + 1)
end
OP1[5]  = function(s, a) s:write_var(a, signed(s:read_var(a)) + 1) end   -- inc
OP1[6]  = function(s, a) s:write_var(a, signed(s:read_var(a)) - 1) end   -- dec
OP1[7]  = function(s, a) s:print((Text.decode(s.mem, a))) end            -- print_addr
OP1[9]  = function(s, a) if a ~= 0 then s.objects:remove(a) end end      -- remove_obj
OP1[10] = function(s, a) s:print(s.objects:name(a)) end                  -- print_obj
OP1[11] = function(s, a) s:do_return(a) end                              -- ret
OP1[12] = function(s, a) s.pc = s.pc + signed(a) - 2 end                 -- jump
OP1[13] = function(s, a) s:print((Text.decode(s.mem, s.mem:unpack_addr(a)))) end  -- print_paddr
OP1[14] = function(s, a) s:store_result(s:read_var(a)) end               -- load
OP1[15] = function(s, a) s:store_result(65535 - a) end                   -- not

-- 0OP --------------------------------------------------------------------
OP0[0]  = function(s) s:do_return(1) end                                 -- rtrue
OP0[1]  = function(s) s:do_return(0) end                                 -- rfalse
OP0[2]  = function(s) s:print_inline() end                               -- print
OP0[3]  = function(s) s:print_inline(); s:print("\n"); s:do_return(1) end -- print_ret
OP0[4]  = function(s) end                                                -- nop
OP0[5]  = function(s) s:branch(s:save_game()) end                        -- save
OP0[6]  = function(s)                                                    -- restore
    -- On success the saved state replaces ours, and the PC now points at the
    -- *save* instruction's branch byte. Resume by taking that branch as though
    -- the save had just succeeded. On failure, fall through our own branch.
    if s:restore_game() then s:branch(true) else s:branch(false) end
end
OP0[7]  = function(s) s:restart() end                                    -- restart
OP0[8]  = function(s) s:do_return(table.remove(s.stack) or 0) end        -- ret_popped
OP0[9]  = function(s) table.remove(s.stack) end                          -- pop
OP0[10] = function(s) s.halted = true end                                -- quit
OP0[11] = function(s) s:print("\n") end                                  -- new_line
OP0[12] = function(s) if s.io.show_status then s.io.show_status(s) end end -- show_status
OP0[13] = function(s) s:branch((s.mem:verify_checksum())) end            -- verify

-- VAR --------------------------------------------------------------------
OPV[0]  = function(s, ...)                                               -- call
    local paddr = select(1, ...)
    local args = {}
    for i = 2, select("#", ...) do args[#args + 1] = select(i, ...) end
    s:call(paddr, args, s:next8())
end
OPV[1]  = function(s, a, b, c) s.mem:w16(a + 2 * signed(b), c) end       -- storew
OPV[2]  = function(s, a, b, c) s.mem:w8(a + signed(b), c) end            -- storeb
OPV[3]  = function(s, a, b, c) s.objects:put_prop(a, b, c) end           -- put_prop
OPV[4]  = function(s, a, b) s:sread(a, b) end                            -- sread
OPV[5]  = function(s, a) s:print(string.char(a)) end                     -- print_char
OPV[6]  = function(s, a) s:print(tostring(signed(a))) end                -- print_num
OPV[7]  = function(s, a) s:store_result(s:random(a)) end                 -- random
OPV[8]  = function(s, a) s.stack[#s.stack + 1] = unsigned(a) end         -- push
OPV[9]  = function(s, a) s:write_var(a, table.remove(s.stack) or 0) end  -- pull
OPV[10] = function(s, a) end                                             -- split_window (no-op here)
OPV[11] = function(s, a) end                                             -- set_window   (no-op here)
OPV[19] = function(s, a, b) end                                          -- output_stream
OPV[20] = function(s, a) end                                             -- input_stream
OPV[21] = function(s, ...) end                                           -- sound_effect

-- ------------------------------------------------------------------------
-- decode and run
-- ------------------------------------------------------------------------

function Machine:step()
    local start = self.pc
    -- sread is VAR:4, encoded 0xE4. Notify before decoding, so a caller can
    -- capture a state that resumes cleanly at the prompt.
    if self.on_prompt and self.mem:u8(start) == 0xE4 then
        self.on_prompt(start)
    end
    local op = self:next8()
    local kinds, handler, name

    if op >= 0xC0 then                        -- variable form
        local types = self:next8()
        kinds = {}
        for i = 0, 3 do
            local t = math.floor(types / 4 ^ (3 - i)) % 4
            if t == 3 then break end
            kinds[#kinds + 1] = t
        end
        if op < 0xE0 then
            handler, name = OP2[op % 32], "2OP:" .. (op % 32)
        else
            handler, name = OPV[op % 32], "VAR:" .. (op % 32)
        end
    elseif op >= 0x80 then                    -- short form
        local t = math.floor(op / 16) % 4
        if t == 3 then
            kinds = {}
            handler, name = OP0[op % 16], "0OP:" .. (op % 16)
        else
            kinds = { t }
            handler, name = OP1[op % 16], "1OP:" .. (op % 16)
        end
    else                                      -- long form, always 2OP
        kinds = {
            (math.floor(op / 64) % 2 == 1) and 2 or 1,
            (math.floor(op / 32) % 2 == 1) and 2 or 1,
        }
        handler, name = OP2[op % 32], "2OP:" .. (op % 32)
    end

    if not handler then
        error(("unimplemented opcode %s (byte 0x%02x) at 0x%04x"):format(name, op, start))
    end

    local a, b, c, d
    local n = #kinds
    if n > 0 then a = self:operand(kinds[1]) end
    if n > 1 then b = self:operand(kinds[2]) end
    if n > 2 then c = self:operand(kinds[3]) end
    if n > 3 then d = self:operand(kinds[4]) end

    if n == 0 then handler(self)
    elseif n == 1 then handler(self, a)
    elseif n == 2 then handler(self, a, b)
    elseif n == 3 then handler(self, a, b, c)
    else handler(self, a, b, c, d) end
end

function Machine:run()
    while not self.halted do
        self:step()
    end
end

-- save / restore ----------------------------------------------------------

-- A complete, self-contained snapshot of the interpreter.
function Machine:capture_state(pc)
    local stack = {}
    for i = 1, #self.stack do stack[i] = self.stack[i] end
    local frames = {}
    for i = 1, #self.frames do
        local fr = self.frames[i]
        local locals = {}
        for j = 1, 15 do locals[j] = fr.locals[j] or 0 end
        frames[i] = { ret_pc = fr.ret_pc, store = fr.store,
                      stack_base = fr.stack_base, locals = locals }
    end
    local dyn = {}
    for a = 0, self.mem.static_base - 1 do dyn[a] = self.mem.dyn[a] end
    return { pc = pc or self.pc, stack = stack, frames = frames, dyn = dyn }
end

function Machine:apply_state(st)
    self.pc = st.pc
    self.stack = {}
    for i = 1, #st.stack do self.stack[i] = st.stack[i] end
    self.frames = {}
    for i = 1, #st.frames do
        local fr = st.frames[i]
        local locals = {}
        for j = 1, 15 do locals[j] = fr.locals[j] end
        self.frames[i] = { ret_pc = fr.ret_pc, store = fr.store,
                           stack_base = fr.stack_base, locals = locals }
    end
    for a = 0, self.mem.static_base - 1 do self.mem.dyn[a] = st.dyn[a] end
    self.halted = false
end

function Machine.serialize_state(st)
    local t = { "ZLUA2", tostring(st.pc), tostring(#st.stack) }
    for i = 1, #st.stack do t[#t + 1] = tostring(st.stack[i]) end
    t[#t + 1] = tostring(#st.frames)
    for i = 1, #st.frames do
        local fr = st.frames[i]
        t[#t + 1] = table.concat({ fr.ret_pc or -1, fr.store or 0, fr.stack_base,
                                   table.concat(fr.locals, " ") }, " ")
    end
    local dyn, n = {}, 0
    for a = 0, #st.dyn do dyn[a + 1] = st.dyn[a]; n = a + 1 end
    t[#t + 1] = tostring(n)
    t[#t + 1] = table.concat(dyn, " ")
    return table.concat(t, "\n")
end

function Machine.deserialize_state(str)
    -- The KOReader plugin wraps the state with a transcript so the visible
    -- history is restored too. Skip that wrapper if present, so the plugin's
    -- Save button and the game's own SAVE command share one slot.
    local n, after = str:match("^ZSAVEUI1\n(%d+)\n()")
    if n then str = str:sub(after + tonumber(n) + 1) end

    local pos = 1
    local function line()
        local nl = str:find("\n", pos, true)
        local out
        if nl then out = str:sub(pos, nl - 1); pos = nl + 1
        else out = str:sub(pos); pos = #str + 1 end
        return out
    end
    if line() ~= "ZLUA2" then return nil, "not a save file" end
    local st = { stack = {}, frames = {}, dyn = {} }
    st.pc = tonumber(line())
    local ns = tonumber(line()) or 0
    for i = 1, ns do st.stack[i] = tonumber(line()) end
    local nf = tonumber(line()) or 0
    for i = 1, nf do
        local parts = {}
        for w in line():gmatch("%S+") do parts[#parts + 1] = tonumber(w) end
        local locals = {}
        for j = 1, 15 do locals[j] = parts[3 + j] or 0 end
        st.frames[i] = { ret_pc = parts[1] >= 0 and parts[1] or nil,
                         store = parts[2] ~= 0 and parts[2] or nil,
                         stack_base = parts[3], locals = locals }
    end
    local nd = tonumber(line()) or 0
    local a = 0
    for w in line():gmatch("%S+") do st.dyn[a] = tonumber(w); a = a + 1 end
    if a ~= nd then return nil, "truncated save file" end
    if not st.pc then return nil, "bad save file" end
    return st
end

function Machine:save_path()
    return (self.save_file or "zmachine-save.dat")
end

function Machine:save_game()
    local f = io.open(self:save_path(), "wb")
    if not f then return false end
    f:write(Machine.serialize_state(self:capture_state()))
    f:close()
    return true
end

function Machine:restore_game()
    local f = io.open(self:save_path(), "rb")
    if not f then return false end
    local data = f:read("*a")
    f:close()
    local st = Machine.deserialize_state(data)
    if not st then return false end
    self:apply_state(st)
    return true
end

function Machine:restart()
    for a = 0, self.mem.static_base - 1 do
        self.mem.dyn[a] = string.byte(self.mem.data, a + 1)
    end
    self.pc = self.h.initial_pc
    self.stack = {}
    self.frames = { { locals = {}, ret_pc = nil, store = nil, stack_base = 0 } }
end

return Machine
