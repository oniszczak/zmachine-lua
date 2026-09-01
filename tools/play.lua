-- Terminal harness: play a v3 story file on stdin/stdout.
-- usage: luajit tools/play.lua [story.z3]

package.path = (arg[0]:match("(.*)/tools/") or ".") .. "/?.lua;" .. package.path
local Memory  = require("zm.memory")
local Machine = require("zm.machine")

local path = arg[1] or (os.getenv("HOME") .. "/Downloads/KIF/hhgg.z3")
local mem, err = Memory.load(path)
if not mem then io.stderr:write("error: ", tostring(err), "\n"); os.exit(1) end

local function show_status(m)
    local room = m.mem:u16(m.h.globals)          -- global 0
    local a    = m.mem:u16(m.h.globals + 2)      -- global 1: score or hours
    local b    = m.mem:u16(m.h.globals + 4)      -- global 2: moves or minutes
    local name = room ~= 0 and m.objects:name(room) or ""
    local timed = math.floor(m.mem:u8(0x01) / 2) % 2 == 1
    local right = timed and ("%d:%02d"):format(a, b) or ("Score: %d  Moves: %d"):format(a, b)
    io.write(("\n[ %-40s %s ]\n"):format(name, right))
end

local machine, merr = Machine.new(mem, {
    write = function(s) io.write(s) end,
    read_line = function()
        io.write("")
        io.flush()
        local l = io.read("*l")
        if l == nil then return nil end
        return l
    end,
    show_status = show_status,
})
if not machine then io.stderr:write("error: ", tostring(merr), "\n"); os.exit(1) end
machine.save_file = (os.getenv("HOME") .. "/Documents/MyApps/zmachine-lua/save.dat")

local ok, e = pcall(function() machine:run() end)
io.write("\n")
if not ok then
    io.stderr:write("interpreter error: ", tostring(e), "\n")
    os.exit(1)
end
