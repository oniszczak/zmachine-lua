-- Headless harness for the KOReader plugin: stubs the KOReader modules so the
-- plugin's control flow can be exercised without KOReader.
--
-- The lfs stub deliberately mimics the real contract - lfs.dir returns BOTH an
-- iterator and a directory handle - which is what the crash was about.

local root = (arg[0]:match("(.*)/tools/") or ".")
package.path = root .. "/zmachine.koplugin/?.lua;" .. root .. "/?.lua;" .. package.path

local shown = {}
local function stub(name, t) package.preload[name] = function() return t end end

stub("gettext", setmetatable({}, { __call = function(_, s) return s end }))
stub("datastorage", { getDataDir = function() return "/tmp/zmtest" end })
os.execute("mkdir -p /tmp/zmtest")   -- the game writes its save file here
stub("device", {
    screen = { getWidth = function() return 600 end, getHeight = function() return 800 end },
    hasKeyboard = function() return true end,
})
local ticks, broadcasts = {}, {}
stub("ui/uimanager", {
    show = function(_, w) shown[#shown + 1] = w end,
    close = function(_, w) end,
    nextTick = function(_, fn) ticks[#ticks + 1] = fn end,
    broadcastEvent = function(_, ev) broadcasts[#broadcasts + 1] = ev.name end,
})
local function runTicks() local t = ticks; ticks = {}; for _, fn in ipairs(t) do fn() end end
stub("ui/event", { new = function(_, name) return { name = name } end })
local function widget(kind)
    return { new = function(_, o) o = o or {}; o.__kind = kind; return o end }
end
stub("ui/widget/infomessage", widget("InfoMessage"))
local InputDialogStub = {}
InputDialogStub.new = function(_, o)
    o = o or {}
    o.__kind = "InputDialog"
    o._text = o.input or ""
    o._input_widget = { scrollToTop = function() end, scrollToBottom = function() end }
    o.title_bar = { setTitle = function(_, t) o.title = t end }
    o.getInputText = function(self) return self._text end
    o.setInputText = function(self, t) self._text = t end
    o.onShowKeyboard = function() end
    -- test helper: type a line and press Enter
    o.typeLine = function(self, line)
        self._text = self._text .. line
        self.enter_callback()
    end
    return o
end
stub("ui/widget/inputdialog", InputDialogStub)
stub("ui/widget/menu", widget("Menu"))
local confirms = {}
stub("ui/widget/confirmbox", { new = function(_, o) o.__kind="ConfirmBox"; confirms[#confirms+1]=o; return o end })
local notes = {}
stub("ui/widget/notification", { new = function(_, o) o.__kind="Notification"; notes[#notes+1]=o.text; return o end })
stub("ui/widget/textviewer", widget("TextViewer"))
stub("ui/widget/container/widgetcontainer", {
    extend = function(_, t) t.extend = function(s, o) return setmetatable(o or {}, {__index = s}) end; return t end,
})

-- lfs stub: dir() returns (iterator, handle), and the iterator REQUIRES the handle.
local real_dirs = {
    ["/tmp/zmtest/stories"] = { ".", "..", "hhgg.z3", "notes.txt", "ZORK1.DAT" },
}
local launch_flag_mtime = nil   -- set to fake a NickelMenu launch
stub("libs/libkoreader-lfs", {
    attributes = function(p, what)
        if real_dirs[p] then return what == "mode" and "directory" or {} end
        if p == "/tmp/zmachine.launch" and launch_flag_mtime then
            return what == "modification" and launch_flag_mtime or {}
        end
        return nil
    end,
    dir = function(p)
        local names = real_dirs[p]
        if not names then error("cannot open " .. p) end
        local handle = { i = 0, names = names }
        return function(state)
            if state == nil then error("directory metatable expected, got nil") end
            state.i = state.i + 1
            return state.names[state.i]
        end, handle
    end,
})

_G.G_reader_settings = { readSetting = function() return nil end }

local ZMachine = require("main")
local inst = setmetatable({ ui = { menu = { registerToMainMenu = function() end } } },
                          { __index = ZMachine })

-- 1. the directory scan (this is what crashed on the device)
local found = inst:findStories()
print("findStories ->")
for _, s in ipairs(found) do print("   " .. s.name) end
assert(#found == 2, "expected 2 story files, got " .. #found)
assert(found[1].name == "hhgg.z3" and found[2].name == "ZORK1.DAT", "wrong files or order")

-- 2. the menu registers, under its new name
local items = {}
inst:addToMainMenu(items)
assert(items.zmachine and items.zmachine.callback, "menu item missing")
assert(items.zmachine.text == "Text Game", "menu item should be called Text Game")
print("menu item        -> " .. items.zmachine.text .. "  (hint: " .. items.zmachine.sorting_hint .. ")")

-- 3. the callback runs without error and shows a Menu
items.zmachine.callback()
assert(#shown >= 1, "nothing shown")
assert(shown[#shown].__kind == "Menu", "expected a Menu, got " .. tostring(shown[#shown].__kind))
print("callback         -> showed " .. shown[#shown].__kind ..
      " with " .. #shown[#shown].item_table .. " entries")

-- 4. guard() turns an error into a message instead of a crash
local ok = inst:guard(function() error("boom") end)
assert(ok == false, "guard should report failure")
assert(shown[#shown].__kind == "InfoMessage", "guard should show an InfoMessage")
print("guard(error)     -> showed InfoMessage, KOReader survives")

-- 4b. NickelMenu launch: a fresh flag opens the story list; leaving goes back to Nickel
local real_remove = os.remove
local removed = {}
os.remove = function(p) removed[#removed + 1] = p; return true end
local function newInstance()
    local i = setmetatable({ ui = { menu = { registerToMainMenu = function() end } } }, { __index = ZMachine })
    i:init()
    return i
end
shown, broadcasts = {}, {}
local plain = newInstance()
runTicks()
assert(#shown == 0 and not plain.from_nickel, "no flag: nothing should open")

launch_flag_mtime = os.time() - 5
local nm = newInstance()
assert(removed[#removed] == "/tmp/zmachine.launch", "the flag should be consumed")
runTicks()
assert(nm.from_nickel and shown[#shown].__kind == "Menu", "a fresh flag should open the story list")
shown[#shown].close_callback()            -- closed with X, nothing picked
runTicks()
assert(broadcasts[1] == "Exit", "closing the list without a pick should exit KOReader")
print("NickelMenu launch -> story list opens; closing it exits to Kobo")

broadcasts = {}
launch_flag_mtime = os.time() - 5
nm = newInstance(); runTicks()
local list = shown[#shown]
nm.start = function() end                 -- picking a story mustn't count as leaving
list.item_table[1].callback()
list.close_callback()
runTicks()
assert(#broadcasts == 0, "picking a story should not exit KOReader")
print("  pick a story   -> stays in KOReader")

launch_flag_mtime = os.time() - 600
shown = {}
local stale = newInstance(); runTicks()
assert(#shown == 0 and not stale.from_nickel, "a stale flag should be ignored")
print("  stale flag     -> ignored")
launch_flag_mtime = nil
os.remove = real_remove

-- from KOReader's own menu, closing the list just closes
broadcasts = {}
inst:chooseStory()
shown[#shown].close_callback()
runTicks()
assert(#broadcasts == 0, "from KOReader's menu, closing the list should not exit")

-- 5. the full terminal loop against the real interpreter
local story = os.getenv("HOME") .. "/Downloads/KIF/hhgg.z3"
local f = io.open(story, "rb")
if f then
    f:close()
    shown = {}
    inst:start(story)
    local dlg = shown[#shown]
    assert(dlg and dlg.__kind == "InputDialog", "terminal view not shown")
    assert(dlg.fullscreen == true, "should be fullscreen")
    assert(dlg.allow_newline == false, "allow_newline must be false for enter_callback")
    assert(dlg:getInputText():find("HITCHHIKER"), "banner not in the buffer")
    print("\nterminal view    -> fullscreen InputDialog, banner present")

    for _, cmd in ipairs({ "turn on light", "get up", "inventory" }) do
        local before = #dlg:getInputText()
        dlg:typeLine(cmd)
        local after = dlg:getInputText()
        assert(#after > before, "buffer did not grow after: " .. cmd)
        local reply = after:sub(before)
        print(("  > %-14s -> %s"):format(cmd,
              (reply:gsub("^%s*" .. cmd:gsub("%W","%%%0") .. "%s*", ""):gsub("\n.*", ""):sub(1, 44))))
    end
    assert(dlg:getInputText():find("splitting headache"), "game state not advancing")
    assert(inst.status ~= "", "status line never set")
    print("  status bar     -> " .. inst.status)
    print("  buffer grew to -> " .. #dlg:getInputText() .. " chars, one persistent view")

    -- 6. save / load via the game's own opcodes
    os.remove("/tmp/zmtest/zmachine-hhgg_z3.sav")
    notes = {}
    local btns = {}
    for _, b in ipairs(dlg.buttons[1]) do btns[b.text] = b.callback end
    assert(btns["Save"] and btns["Load"] and btns["Exit"], "Save/Load/Exit buttons missing")
    assert(not btns["Top"] and not btns["Bottom"], "Top/Bottom should be gone")
    print("\nbuttons          -> Save, Load, Exit")

    local before_save = #dlg:getInputText()
    btns["Save"]()
    local after_save = dlg:getInputText()
    assert(after_save:sub(before_save):find("save"), "the command should appear in the log")
    assert(after_save:sub(before_save):find("Ok%."), "the game should confirm the save")
    local saved_status = inst.status
    print("  save button    -> game replied \"Ok.\"  (" .. saved_status .. ")")

    local f3 = io.open("/tmp/zmtest/zmachine-hhgg_z3.sav", "rb")
    assert(f3, "no save file was written")
    local sz = #f3:read("*a"); f3:close()
    print("  save file      -> " .. sz .. " bytes, written by the game's own opcode")

    dlg:typeLine("wait")
    dlg:typeLine("wait")
    assert(inst.status ~= saved_status, "state should have advanced")
    print("  played on      -> " .. inst.status)

    btns["Load"]()
    assert(inst.status == saved_status,
           "state did not rewind: " .. inst.status .. " vs " .. saved_status)
    print("  load button    -> " .. inst.status .. " — rewound")

    dlg:typeLine("look")
    assert(dlg:getInputText():find("bedroom is a mess"), "not playable after load")
    print("  playable after load -> yes")

    -- typing the commands must behave identically to pressing the buttons
    local typed_before = inst.status
    dlg:typeLine("save")
    dlg:typeLine("north")
    dlg:typeLine("restore")
    assert(inst.status == typed_before, "typed save/restore should behave the same")
    print("  typed save/restore -> identical behaviour, same file")

    btns["Exit"]()
    assert(#confirms == 1, "Exit should ask for confirmation")
    assert(confirms[1].text:find("without saving"), "wrong confirmation text")
    assert(confirms[1].ok_text == "Yes" and confirms[1].cancel_text == "Cancel", "wrong buttons")
    print("  exit           -> asked: \"" .. confirms[1].text .. "\" [" ..
          confirms[1].cancel_text .. "] [" .. confirms[1].ok_text .. "]")
    confirms[1].ok_callback()
    runTicks()
    assert(inst.dialog == nil and inst.co == nil, "Yes should close the game")
    assert(#broadcasts == 0, "from KOReader's menu, exiting the game should stay in KOReader")
    print("  exit confirmed -> game closed")

    -- the same exit, when launched from NickelMenu, goes back to Nickel
    inst.from_nickel = true
    shown, confirms = {}, {}
    inst:start(story)
    for _, b in ipairs(shown[#shown].buttons[1]) do if b.text == "Exit" then b.callback() end end
    confirms[1].ok_callback()
    runTicks()
    assert(broadcasts[1] == "Exit", "from NickelMenu, exiting the game should exit KOReader")
    print("  exit (from NickelMenu) -> back to Kobo")
else
    print("\n(story file not found; skipped the live terminal test)")
end

print("\nplugin harness: OK")
