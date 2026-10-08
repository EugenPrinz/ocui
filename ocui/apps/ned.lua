-- ned: a nano-like text editor with Lua syntax highlighting.
--
--   ned [file]        (apps/ned.lua; a missing file is created on save)
--
-- Ctrl+S save, Ctrl+Shift+S save as, Ctrl+O open, Ctrl+F (or Ctrl+W) find,
-- F3 / Shift+F3 next / previous, Ctrl+R replace all, Ctrl+G go to line,
-- F5 run the file, F1 help, Ctrl+Q quit -- plus the editing keys of
-- ocui.editor (Ctrl+C/X/V, Ctrl+K/U, Ctrl+Z/Y, Shift+arrows...).

local Dialog = require("ocui.dialog")
local Editor = require("ocui.editor")
local Host = require("ocui.host")
local TextBuffer = require("ocui.textbuffer")
local storage = require("ocui.storage")
local syntax = require("ocui.syntax")
local theme = require("ocui.theme")
local widgets = require("ocui.widgets")

local M = {
  name = "ned",
  description = "text editor (nano-like, Lua highlighting)",
  keyboard = true,
  defaults = {
    tabWidth = 2,       -- spaces per indent level / tab stop
    lineNumbers = true,
  },
  path = nil, -- file to open, set by apps/ned.lua
}

local HELP = [[
Files    Ctrl+S save   Ctrl+Shift+S save as   Ctrl+O open   Ctrl+Q quit
Search   Ctrl+F find   F3 / Shift+F3 next / previous   Ctrl+R replace all
         Ctrl+G go to line[:column]
Edit     Ctrl+C copy   Ctrl+X cut   Ctrl+V paste   Ctrl+A select all
         Ctrl+K cut line (repeat for more)   Ctrl+U paste the cut lines
         Ctrl+Z undo   Ctrl+Y redo   Tab / Shift+Tab indent / unindent
Move     arrows, Home/End, PgUp/PgDn, Ctrl+Home/End, Ctrl+Left/Right;
         Shift + a move selects. Mouse: click, drag, double click, wheel.
Run      F5 saves and runs the file, then comes back to the editor]]

function M.start(ctx, cfg)
  local host = Host.new({ gpu = cfg.gpu, screen = cfg.screen, background = theme.background })
  host:mount(ctx)
  M.host = host

  local state = { path = M.path, search = "" }
  local root = widgets.VBox.new({})
  local titleBar = root:add(widgets.HBox.new({ h = 1, bg = theme.header }))
  local title = titleBar:add(widgets.Label.new({ fg = theme.text }))
  local info = titleBar:add(widgets.Label.new({ w = 30, align = "right", fg = theme.textDim }))
  local editor
  -- like nano: a message line above the key hints
  local status = widgets.StatusBar.new({ bg = theme.background })
  local hints = widgets.StatusBar.new({
    hints = {
      { key = "^S", label = "Save" }, { key = "^O", label = "Open" }, { key = "^F", label = "Find" },
      { key = "^R", label = "Replace" }, { key = "^G", label = "Go to" }, { key = "^K", label = "Cut" },
      { key = "^U", label = "Paste" }, { key = "^Z", label = "Undo" }, { key = "F5", label = "Run" },
      { key = "F1", label = "Help" }, { key = "^Q", label = "Quit" },
    },
  })

  local function message(text, color) status:setText(text or "", color) end

  local function updateTitle()
    local name = state.path or "(new file)"
    title:setText(" ned  " .. name .. (editor.buffer:isModified() and "  [modified]" or ""))
  end

  local function updateCursor()
    local c = editor.cursor
    info:setText(string.format("Ln %d/%d  Col %d  %s ", c.line, editor.buffer:lineCount(), c.col + 1,
      editor.highlighter and editor.highlighter.name or "Text"))
  end

  editor = Editor.new({
    flex = 1,
    tabWidth = cfg.tabWidth, lineNumbers = cfg.lineNumbers,
    onChange = function() updateTitle() end,
    onCursor = function() updateCursor() end,
  })
  root:add(editor)
  root:add(status)
  root:add(hints)
  M.editor = editor

  -- ------------------------------------------------------------- files --
  local function load(path)
    local text = path and storage.read(path)
    editor:setBuffer(TextBuffer.new(text or ""))
    editor:setHighlighter(syntax.forPath(path))
    state.path = path
    updateTitle()
    updateCursor()
    if path and not text then
      message("New file: " .. path)
    elseif path then
      message(string.format("Read %d lines", editor.buffer:lineCount()))
    end
  end

  local function save(path, after)
    local ok, err = storage.write(path, editor.buffer:getText())
    if not ok then
      message("Cannot save " .. path .. ": " .. tostring(err), theme.bad)
      return
    end
    editor.buffer:markSaved()
    if path ~= state.path then
      state.path = path
      editor:setHighlighter(syntax.forPath(path))
    end
    updateTitle()
    updateCursor()
    message(string.format("Saved %d lines to %s", editor.buffer:lineCount(), path), theme.good)
    if after then after() end
  end

  local function saveAs(after)
    Dialog.prompt(host, "Save as", "File name:", state.path or "/home/", function(path)
      if path and path ~= "" then save(path, after) end
    end)
  end

  local function saveOrAsk(after)
    if state.path then save(state.path, after) else saveAs(after) end
  end

  -- Runs `next` once unsaved changes are saved or knowingly dropped.
  local function confirmDiscard(next)
    if not editor.buffer:isModified() then return next() end
    Dialog.open(host, {
      title = "Unsaved changes",
      text = "Save the changes to " .. (state.path or "the new file") .. "?",
      buttons = { "Save", "Don't save", "Cancel" },
      onResult = function(index)
        if index == 1 then saveOrAsk(next) elseif index == 2 then next() end
      end,
    })
  end

  local function open()
    confirmDiscard(function()
      local dir = state.path and state.path:match("^(.*/)") or "/home/"
      Dialog.prompt(host, "Open", "File name:", dir, function(path)
        if path and path ~= "" then load(path) end
      end)
    end)
  end

  -- ------------------------------------------------------------ search --
  local function findNext(backwards)
    if state.search == "" then return end
    if editor:find(state.search, backwards) then
      message("")
    else
      message("Not found: " .. state.search, theme.warn)
    end
  end

  local function find()
    local initial = editor:hasSelection() and editor:selectedText() or state.search
    if initial:find("\n", 1, true) then initial = state.search end
    Dialog.prompt(host, "Find", "Text to find (F3 next, Shift+F3 previous):", initial, function(text)
      if text and text ~= "" then
        state.search = text
        findNext(false)
      end
    end)
  end

  local function replace()
    Dialog.prompt(host, "Replace", "Replace every:", state.search, function(needle)
      if not needle or needle == "" then return end
      state.search = needle
      Dialog.prompt(host, "Replace", "with:", "", function(replacement)
        if not replacement then return end
        local n = editor:replaceAll(needle, replacement)
        message(string.format("Replaced %d occurrence%s", n, n == 1 and "" or "s"), n > 0 and theme.good or theme.warn)
      end)
    end)
  end

  local function gotoLine()
    Dialog.prompt(host, "Go to", "Line (or line:column):", tostring(editor.cursor.line), function(text)
      local line, col = (text or ""):match("^%s*(%d+)%s*:?%s*(%d*)")
      if line then editor:gotoLine(tonumber(line), (tonumber(col) or 1) - 1) end
    end)
  end

  -- --------------------------------------------------------------- run --
  local function run()
    saveOrAsk(function()
      local path = state.path
      local ok, err = host:suspend(function()
        local shell = require("shell")
        local result, reason = shell.execute(path)
        if not result and reason then io.stderr:write(tostring(reason) .. "\n") end
        io.write("\n[ned] program ended -- press any key to return")
        require("event").pull("key_down")
      end)
      if ok then message("Ran " .. path) else message("Run failed: " .. tostring(err), theme.bad) end
    end)
  end

  local function quit()
    confirmDiscard(function() ctx:stop() end)
  end

  host:setView({
    root = root,
    bindings = {
      ["ctrl+s"] = function() saveOrAsk() end,
      ["ctrl+shift+s"] = function() saveAs() end,
      ["ctrl+o"] = open,
      ["ctrl+f"] = find, ["ctrl+w"] = find,
      f3 = function() findNext(false) end,
      ["shift+f3"] = function() findNext(true) end,
      ["ctrl+r"] = replace,
      ["ctrl+g"] = gotoLine,
      f5 = run,
      f1 = function() Dialog.message(host, "ned keys", HELP) end,
      ["ctrl+q"] = quit,
    },
  })
  load(state.path)
  editor:focus()
  if not state.path then message("New file -- Ctrl+S asks for a name") end
end

return M
