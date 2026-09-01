-- Development harness: parse a story file and dump what we can decode so far.
-- usage: luajit tools/inspect.lua <story.z3>

package.path = (arg[0]:match("(.*)/tools/") or ".") .. "/?.lua;" .. package.path
local Memory = require("zm.memory")
local Text   = require("zm.text")

local path = arg[1] or (os.getenv("HOME") .. "/Downloads/KIF/hhgg.z3")
local mem, err = Memory.load(path)
if not mem then io.stderr:write("error: ", tostring(err), "\n"); os.exit(1) end

local h = mem:header()
print(("file          %s (%d bytes)"):format(path:match("[^/]+$"), mem.size))
print(("version       %d"):format(h.version))
print(("release       %d"):format(h.release))
print(("serial        %s"):format(h.serial))
print(("declared len  %d"):format(h.file_length))
print(("initial PC    0x%04x"):format(h.initial_pc))
print(("dictionary    0x%04x"):format(h.dictionary))
print(("objects       0x%04x"):format(h.objects))
print(("globals       0x%04x"):format(h.globals))
print(("abbreviations 0x%04x"):format(h.abbrev))
print(("static base   0x%04x"):format(h.static_mem))

local ok, sum = mem:verify_checksum()
print(("checksum      stored 0x%04x, computed 0x%04x -> %s")
      :format(h.checksum, sum or 0, ok and "MATCH" or "MISMATCH"))

print("\n--- abbreviations (first 32) ---")
for i = 0, 31 do
    local entry = h.abbrev + 2 * i
    local target = mem:u16(entry) * 2
    local s = Text.decode(mem, target)
    io.write(("%3d %-22s"):format(i, "[" .. s .. "]"))
    if (i + 1) % 3 == 0 then io.write("\n") end
end
print()

-- Dictionary (v3): n separators, then entry length, then entry count.
local d = h.dictionary
local nsep = mem:u8(d)
local entry_len = mem:u8(d + 1 + nsep)
local entry_count = mem:u16(d + 1 + nsep + 1)
local first = d + 1 + nsep + 1 + 2
print(("--- dictionary: %d entries, %d bytes each ---"):format(entry_count, entry_len))
io.write("separators: ")
for i = 1, nsep do io.write("'", string.char(mem:u8(d + i)), "' ") end
print()

local words = {}
for i = 0, math.min(entry_count, 40) - 1 do
    words[#words + 1] = (Text.decode(mem, first + i * entry_len))
end
print(table.concat(words, " "))

print("\n--- a sample from the middle of the dictionary ---")
local mid = math.floor(entry_count / 2)
local sample = {}
for i = mid, math.min(mid + 29, entry_count - 1) do
    sample[#sample + 1] = (Text.decode(mem, first + i * entry_len))
end
print(table.concat(sample, " "))
