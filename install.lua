-- install.lua -- installs or updates ocui on an OpenComputers computer
-- straight from GitHub. Needs an Internet Card.
--
--   wget -f https://raw.githubusercontent.com/EugenPrinz/ocui/main/install.lua /tmp/install.lua
--   /tmp/install.lua            -- latest main
--   /tmp/install.lua <ref>      -- a branch, tag or commit
--
-- Library -> /lib/ocui, programs -> /usr/bin (ocpool, hud, hudctl,
-- ae2_dashboard run from any directory). Your settings in /etc/ocui are
-- never touched. Everything is downloaded first and written only if every
-- file arrived, so a dropped connection can't leave a half-updated install.

local component = require("component")
local filesystem = require("filesystem")

local REPO = "EugenPrinz/ocui"
local ref = (...) or "main"
local BASE = "https://raw.githubusercontent.com/" .. REPO .. "/" .. ref .. "/"

-- { path in the repo, install path }
local FILES = {
  { "ocui/ae2.lua",                "/lib/ocui/ae2.lua" },
  { "ocui/app.lua",                "/lib/ocui/app.lua" },
  { "ocui/canvas.lua",             "/lib/ocui/canvas.lua" },
  { "ocui/config.lua",             "/lib/ocui/config.lua" },
  { "ocui/format.lua",             "/lib/ocui/format.lua" },
  { "ocui/hud.lua",                "/lib/ocui/hud.lua" },
  { "ocui/loop.lua",               "/lib/ocui/loop.lua" },
  { "ocui/lsc.lua",                "/lib/ocui/lsc.lua" },
  { "ocui/pool.lua",               "/lib/ocui/pool.lua" },
  { "ocui/storage.lua",            "/lib/ocui/storage.lua" },
  { "ocui/theme.lua",              "/lib/ocui/theme.lua" },
  { "ocui/util.lua",               "/lib/ocui/util.lua" },
  { "ocui/widget.lua",             "/lib/ocui/widget.lua" },
  { "ocui/widgets.lua",            "/lib/ocui/widgets.lua" },
  { "ocui/apps/dashboard.lua",     "/lib/ocui/apps/dashboard.lua" },
  { "ocui/apps/hud.lua",           "/lib/ocui/apps/hud.lua" },
  { "ocui/apps/hudctl.lua",        "/lib/ocui/apps/hudctl.lua" },
  { "ocui/services/crafting.lua",  "/lib/ocui/services/crafting.lua" },
  { "ocui/services/energy.lua",    "/lib/ocui/services/energy.lua" },
  { "apps/ocpool.lua",             "/usr/bin/ocpool.lua" },
  { "apps/hud.lua",                "/usr/bin/hud.lua" },
  { "apps/hudctl.lua",             "/usr/bin/hudctl.lua" },
  { "apps/ae2_dashboard.lua",      "/usr/bin/ae2_dashboard.lua" },
}

-- Copies from the first ocui version, which was copied into /home by hand.
-- They don't shadow the new programs (PATH is /bin:/usr/bin:/home/bin:.,
-- so /usr/bin wins), but they are outdated and only cause confusion.
local OLD_COPIES = { "/home/hud.lua", "/home/ae2_dashboard.lua", "/home/ocpool.lua" }

-- Files earlier ocui versions installed that no longer exist (the `tube`
-- video player). Removed so the old program can't be run against the new
-- library; settings in /etc/ocui are left alone.
local OBSOLETE = { "/usr/bin/tube.lua", "/lib/ocui/apps/tube.lua", "/lib/ocui/tubeproto.lua" }

local function fail(msg)
  io.stderr:write("install: " .. msg .. "\n")
  os.exit(1)
end

if not component.isAvailable("internet") then
  fail("this needs an Internet Card")
end
local internet = require("internet")

local function fetch(url)
  local ok, handle = pcall(internet.request, url, nil, { ["user-agent"] = "ocui-install/OpenComputers" })
  if not ok or not handle then return nil, tostring(handle) end
  local chunks = {}
  local readOk, err = pcall(function()
    for chunk in handle do chunks[#chunks + 1] = chunk end
  end)
  if not readOk then return nil, tostring(err) end
  if handle.response then
    local okResp, code, message = pcall(handle.response)
    if okResp and type(code) == "number" and code ~= 200 then
      return nil, string.format("HTTP %d %s", code, tostring(message or ""))
    end
  end
  return table.concat(chunks)
end

-- 1. download everything
print(string.format("ocui: downloading %d files from %s (%s)", #FILES, REPO, ref))
local contents = {}
for i, f in ipairs(FILES) do
  io.write(string.format("  [%2d/%d] %s ... ", i, #FILES, f[1]))
  local body, err = fetch(BASE .. f[1])
  if not body then
    print("FAILED")
    fail(f[1] .. ": " .. tostring(err) .. "\nnothing was changed")
  end
  if #body == 0 then
    print("FAILED")
    fail(f[1] .. ": empty file\nnothing was changed")
  end
  contents[i] = body
  print(string.format("%d bytes", #body))
end

-- 2. write
for i, f in ipairs(FILES) do
  local dir = filesystem.path(f[2])
  if not filesystem.exists(dir) then
    local ok, err = filesystem.makeDirectory(dir)
    if not ok then fail("cannot create " .. dir .. ": " .. tostring(err)) end
  end
  local out, err = io.open(f[2], "w")
  if not out then fail("cannot write " .. f[2] .. ": " .. tostring(err)) end
  out:write(contents[i])
  out:close()
end

-- 3. drop cached modules so the next run loads the new code (OpenOS keeps
-- required libraries in memory between programs)
for name in pairs(package.loaded) do
  if name == "ocui" or name:match("^ocui%.") then
    package.loaded[name] = nil
  end
end

for _, path in ipairs(OBSOLETE) do
  if filesystem.exists(path) then
    filesystem.remove(path)
    print("ocui: removed obsolete " .. path)
  end
end

print("ocui: installed to /lib/ocui and /usr/bin")

local stale = {}
for _, path in ipairs(OLD_COPIES) do
  if filesystem.exists(path) then table.insert(stale, path) end
end
if #stale > 0 then
  print("\nOutdated copies from the first version are still here (not used by")
  print("`hud`, `ocpool` & co., which now run from /usr/bin):")
  for _, path in ipairs(stale) do print("  " .. path) end
  print("You can remove them: rm " .. table.concat(stale, " "))
end

print("\nIf a background pool is running (ocpool -b), restart it to load the new code:")
print("  ocpool quit && ocpool -b")
print("Your settings in /etc/ocui are kept; older hud.cfg files are converted on first start.")
