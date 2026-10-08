-- install.lua -- installs or updates ocui on an OpenComputers computer
-- straight from GitHub. Needs an Internet Card.
--
--   wget -f https://raw.githubusercontent.com/EugenPrinz/ocui/main/install.lua /tmp/install.lua
--   /tmp/install.lua              -- latest main
--   /tmp/install.lua <ref>        -- a branch, tag or commit
--   /tmp/install.lua -f [ref]     -- download every file, even unchanged ones
--
-- The file list comes from manifest.lua in the repository, with each
-- file's size and checksum: files you already have in the same version
-- are not downloaded again, and every download is checked before
-- anything is written. Library -> /lib/ocui, programs -> /usr/bin, the
-- boot hook -> /boot. Your settings in /etc/ocui are never touched.
-- Everything is downloaded first and written only if every file arrived
-- intact, so a dropped connection can't leave a half-updated install.

local component = require("component")
local filesystem = require("filesystem")

local REPO = "EugenPrinz/ocui"
local force, ref = false, nil
for _, a in ipairs({ ... }) do
  if a == "-f" or a == "--force" then force = true else ref = ref or a end
end
ref = ref or "main"
local BASE = "https://raw.githubusercontent.com/" .. REPO .. "/" .. ref .. "/"

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

-- Same function as tools/manifest.lua: 32-bit djb2, 8 hex digits.
local function checksum(s)
  local h = 5381
  for i = 1, #s, 4096 do
    local bytes = { s:byte(i, math.min(i + 4095, #s)) }
    for j = 1, #bytes do h = (h * 33 + bytes[j]) % 4294967296 end
  end
  return string.format("%08x", h)
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

local function readLocal(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local text = f:read("*a")
  f:close()
  return text
end

-- 1. the manifest
print(string.format("ocui: checking %s (%s)", REPO, ref))
local manifestText, mErr = fetch(BASE .. "manifest.lua")
if not manifestText then fail("manifest.lua: " .. tostring(mErr) .. "\nnothing was changed") end
local chunk = load(manifestText, "=manifest", "t", {})
local okManifest, FILES = false, nil
if chunk then okManifest, FILES = pcall(chunk) end
if not okManifest or type(FILES) ~= "table" or #FILES == 0 then
  fail("manifest.lua is not readable\nnothing was changed")
end

-- 2. what is missing or different here
local needed = {}
for _, f in ipairs(FILES) do
  local have = not force and readLocal(f[2])
  if not (have and #have == f[3] and checksum(have) == f[4]) then
    needed[#needed + 1] = f
  end
end
if #needed == 0 then
  print(string.format("ocui: up to date (%d files)", #FILES))
else
  print(string.format("ocui: %d of %d files to download", #needed, #FILES))
end

-- 3. download everything needed, checking each file
local contents = {}
for i, f in ipairs(needed) do
  io.write(string.format("  [%2d/%d] %s ... ", i, #needed, f[1]))
  local body, err = fetch(BASE .. f[1])
  if not body then
    print("FAILED")
    fail(f[1] .. ": " .. tostring(err) .. "\nnothing was changed")
  end
  if #body ~= f[3] or checksum(body) ~= f[4] then
    print("FAILED")
    fail(f[1] .. ": does not match the manifest (GitHub may still be serving a cached"
      .. " copy right after an update -- try again in a few minutes)\nnothing was changed")
  end
  contents[i] = body
  print(string.format("%d bytes", #body))
end

-- 4. write
for i, f in ipairs(needed) do
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

-- 5. drop cached modules so the next run loads the new code (OpenOS keeps
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

if #needed > 0 then
  print("ocui: installed to /lib/ocui and /usr/bin")
end
print("      boot into the desktop: `ocsession on` (then reboot); undo: `ocsession off`")

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

if #needed > 0 then
  print("\nIf a background pool is running (ocpool -b), restart it to load the new code:")
  print("  ocpool quit && ocpool -b")
  print("Your settings in /etc/ocui are kept; older hud.cfg files are converted on first start.")
end
