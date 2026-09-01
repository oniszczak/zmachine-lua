-- Verifies the plugin's drive model: the VM runs inside a coroutine and
-- yields whenever it wants a line, exactly as main.lua resumes it.
package.path = (arg[0]:match("(.*)/tools/") or ".") .. "/?.lua;" .. package.path
local Memory  = require("zm.memory")
local Machine = require("zm.machine")

local path = arg[1] or (os.getenv("HOME") .. "/Downloads/KIF/hhgg.z3")
local mem = assert(Memory.load(path))

local out, status = {}, ""
local m = assert(Machine.new(mem, {
    write = function(s) out[#out+1] = s end,
    read_line = function() return coroutine.yield() end,
    show_status = function(mm)
        local room = mm.mem:u16(mm.h.globals)
        status = room ~= 0 and mm.objects:name(room) or "?"
    end,
}))
m.save_file = "/tmp/zm-co-test.sav"

local co = coroutine.create(function() m:run() end)
local function pump(line)
    local ok, err = coroutine.resume(co, line)
    if not ok then error(err) end
    local text = table.concat(out); out = {}
    return text, coroutine.status(co) == "dead"
end

local text, dead = pump(nil)
print("--- boot (" .. #text .. " chars), status=[" .. status .. "] dead=" .. tostring(dead))
assert(text:find("HITCHHIKER"), "banner missing")

for _, cmd in ipairs({"turn on light", "get up", "look", "inventory", "save", "restore"}) do
    text, dead = pump(cmd)
    local first = (text:gsub("^%s+", ""):gsub("\n.*", ""))
    print(("> %-16s -> [%s] status=[%s] yielded=%s"):format(
        cmd, first:sub(1, 46), status, tostring(not dead)))
    assert(not dead, "coroutine died unexpectedly at: " .. cmd)
end
print("\ncoroutine drive model: OK")
os.remove("/tmp/zm-co-test.sav")
