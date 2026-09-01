--[[--
Interactive Fiction for KOReader — a pure-Lua Z-machine (version 3).

The interpreter is synchronous: it runs until the game asks for a line of
input. A GUI can't block, so the VM runs inside a coroutine and its
`read_line` yields back to us. Typing a command resumes the coroutine.

@module koplugin.zmachine
--]]--

local DataStorage     = require("datastorage")
local Device          = require("device")
local InfoMessage     = require("ui/widget/infomessage")
local InputDialog     = require("ui/widget/inputdialog")
local ConfirmBox      = require("ui/widget/confirmbox")
local Menu            = require("ui/widget/menu")
local Notification    = require("ui/widget/notification")
local UIManager       = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs             = require("libs/libkoreader-lfs")
local _               = require("gettext")

local plugin_dir = debug.getinfo(1, "S").source:match("@?(.*/)") or "./"
package.path = plugin_dir .. "?.lua;" .. package.path

local Memory  = require("zm.memory")
local Machine = require("zm.machine")

local MAX_TRANSCRIPT = 20000   -- characters of scrollback to keep

local ZMachine = WidgetContainer:extend{
    name = "zmachine",
    is_doc_only = false,
}

function ZMachine:init()
    self.ui.menu:registerToMainMenu(self)
end

-- Run fn, reporting any error as a message rather than crashing KOReader.
function ZMachine:guard(fn)
    local ok, err = pcall(fn)
    if not ok then
        UIManager:show(InfoMessage:new{
            text = _("Interactive fiction error:\n") .. tostring(err),
        })
    end
    return ok
end

function ZMachine:addToMainMenu(menu_items)
    menu_items.zmachine = {
        text = _("Interactive fiction"),
        sorting_hint = "more_tools",
        callback = function() self:guard(function() self:chooseStory() end) end,
    }
end

-- finding stories ---------------------------------------------------------

function ZMachine:storyDirs()
    local dirs = {}
    local home = G_reader_settings and G_reader_settings:readSetting("home_dir")
    if home then dirs[#dirs + 1] = home end
    dirs[#dirs + 1] = DataStorage:getDataDir() .. "/stories"
    dirs[#dirs + 1] = "/mnt/us/stories"
    dirs[#dirs + 1] = "/mnt/us/documents"
    dirs[#dirs + 1] = plugin_dir .. "stories"
    return dirs
end

function ZMachine:findStories()
    local found, seen = {}, {}
    for _i, dir in ipairs(self:storyDirs()) do
        if lfs.attributes(dir, "mode") == "directory" then
            local ok, iter, dir_obj = pcall(lfs.dir, dir)
            if ok and iter then
                for name in iter, dir_obj do
                    if name:match("%.[zZ][123]$") or name:match("%.[dD][aA][tT]$") then
                        local full = dir .. "/" .. name
                        if not seen[full] then
                            seen[full] = true
                            found[#found + 1] = { name = name, path = full }
                        end
                    end
                end
            end
        end
    end
    table.sort(found, function(a, b) return a.name:lower() < b.name:lower() end)
    return found
end

function ZMachine:chooseStory()
    local stories = self:findStories()
    if #stories == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No story files found.\n\nPut a .z3 file in your library folder, in koreader/stories, or in /mnt/us/stories."),
        })
        return
    end

    local menu
    local items = {}
    for _i, s in ipairs(stories) do
        items[#items + 1] = {
            text = s.name,
            callback = function()
                UIManager:close(menu)
                self:guard(function() self:start(s.path) end)
            end,
        }
    end
    menu = Menu:new{
        title = _("Choose a story"),
        item_table = items,
        is_popout = false,
        width = Device.screen:getWidth(),
        height = Device.screen:getHeight(),
        close_callback = function() UIManager:close(menu) end,
    }
    UIManager:show(menu)
end

-- running -----------------------------------------------------------------

function ZMachine:start(path)
    local mem, err = Memory.load(path)
    if not mem then
        UIManager:show(InfoMessage:new{ text = _("Could not open story: ") .. tostring(err) })
        return
    end

    self.transcript = {}
    self.status = ""
    self.story_name = path:match("([^/]+)$")

    local machine, merr = Machine.new(mem, {
        write = function(s) self.transcript[#self.transcript + 1] = s end,
        read_line = function() return coroutine.yield() end,
        show_status = function(m) self:setStatus(m) end,
    })
    if not machine then
        UIManager:show(InfoMessage:new{ text = _("Unsupported story file: ") .. tostring(merr) })
        return
    end

    -- One save file per story. The Save/Load buttons and the game's own
    -- SAVE/RESTORE commands are the same mechanism, so they share it.
    machine.save_file = DataStorage:getDataDir() .. "/zmachine-" ..
                        self.story_name:gsub("%W", "_") .. ".sav"
    self.machine = machine
    self.co = coroutine.create(function() machine:run() end)
    self:pump(nil)          -- run up to the game's first prompt
    self:showTerminal()
end

function ZMachine:setStatus(m)
    local room = m.mem:u16(m.h.globals)
    local a    = m.mem:u16(m.h.globals + 2)
    local b    = m.mem:u16(m.h.globals + 4)
    local name = room ~= 0 and m.objects:name(room) or ""
    local timed = math.floor(m.mem:u8(0x01) / 2) % 2 == 1
    self.status = timed and ("%s   %d:%02d"):format(name, a, b)
                        or  ("%s   %d / %d"):format(name, a, b)
end

-- Resume the VM with `line`, gathering output until it wants input again.
function ZMachine:pump(line)
    local ok, err = coroutine.resume(self.co, line)
    if not ok then
        self.co = nil
        error(err, 0)
    end
    if coroutine.status(self.co) == "dead" then
        self.transcript[#self.transcript + 1] = "\n\n[The story has ended.]\n"
        self.co = nil
    end
end

-- The visible buffer: the whole transcript, trimmed from the front so the
-- text widget doesn't grow unbounded on a slow device.
function ZMachine:buffer()
    local s = table.concat(self.transcript)
    if #s > MAX_TRANSCRIPT then
        s = "[earlier text trimmed]\n" .. s:sub(#s - MAX_TRANSCRIPT)
        self.transcript = { s }
    end
    return s
end

function ZMachine:setTitle()
    if not (self.dialog and self.dialog.title_bar) then return end
    local t = self.status ~= "" and self.status or self.story_name
    pcall(function() self.dialog.title_bar:setTitle(t) end)
end

-- One persistent full-screen view. The game's text and everything you type
-- live in the same buffer; Enter submits whatever was added after the mark.
function ZMachine:showTerminal()
    local text = self:buffer()
    self.mark = #text

    local dialog
    dialog = InputDialog:new{
        title = self.status ~= "" and self.status or self.story_name,
        input = text,
        fullscreen = true,
        condensed = true,
        allow_newline = false,      -- required for enter_callback to fire
        cursor_at_end = true,
        use_available_height = true,
        enter_callback = function()
            self:guard(function() self:submit() end)
        end,
        buttons = {{
            {
                -- Exactly what typing SAVE does: the game's own save opcode.
                text = _("Save"),
                callback = function() self:guard(function() self:runCommand("save") end) end,
            },
            {
                text = _("Load"),
                callback = function() self:guard(function() self:runCommand("restore") end) end,
            },
            {
                text = _("Exit"),
                callback = function() self:confirmExit() end,
            },
        }},
    }
    self.dialog = dialog
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function ZMachine:notify(msg)
    UIManager:show(Notification:new{ text = msg })
end

function ZMachine:closeGame()
    if self.dialog then UIManager:close(self.dialog) end
    self.dialog, self.co, self.machine, self.snapshot = nil, nil, nil, nil
end

function ZMachine:confirmExit()
    UIManager:show(ConfirmBox:new{
        text = _("Are you sure you want to exit without saving?"),
        cancel_text = _("Cancel"),
        ok_text = _("Yes"),
        ok_callback = function() self:closeGame() end,
    })
end

-- Send one command to the game and refresh the view.
function ZMachine:runCommand(cmd)
    if not (self.dialog and self.co) then return end
    self.transcript[#self.transcript + 1] = cmd .. "\n"
    self:pump(cmd)
    local text = self:buffer()
    self.mark = #text
    self:setTitle()
    self.dialog:setInputText(text, nil, false)   -- false = cursor at end, scroll down
end

-- Enter was pressed: take the text typed after the mark as the command.
function ZMachine:submit()
    if not self.dialog then return end
    if not self.co then                    -- story finished; Enter just closes
        UIManager:close(self.dialog)
        self.dialog = nil
        return
    end
    local full = self.dialog:getInputText() or ""
    local typed = full:sub(self.mark + 1):gsub("^%s+", ""):gsub("%s+$", "")
    self:runCommand(typed)
end

return ZMachine
