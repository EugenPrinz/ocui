-- ocui.storage
-- Tiny file I/O facade so config/log code can be tested without a real
-- disk: in-game it uses OpenOS io + filesystem; the test harness swaps in
-- an in-memory backend with M.use(backend).
--
-- backend = {
--   read(path)          -> string or nil
--   write(path, text)   -> true or nil, err   (replaces the file)
--   append(path, text)  -> true or nil, err
--   ensureDir(path)     -> creates the directory (and parents) if missing
--   exists(path)        -> boolean
-- }

local M = {}

local function dirname(path)
  return path:match("^(.*)/[^/]*$") or ""
end

local openos = {}

function openos.read(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local text = f:read("*a")
  f:close()
  return text
end

local function writeMode(path, text, mode)
  local f, err = io.open(path, mode)
  if not f then return nil, err end
  f:write(text)
  f:close()
  return true
end

function openos.write(path, text) return writeMode(path, text, "w") end
function openos.append(path, text) return writeMode(path, text, "a") end

function openos.ensureDir(path)
  local fs = require("filesystem")
  if path ~= "" and not fs.exists(path) then
    fs.makeDirectory(path)
  end
end

function openos.exists(path)
  return require("filesystem").exists(path)
end

M.backend = openos

function M.use(backend)
  M.backend = backend or openos
end

function M.read(path) return M.backend.read(path) end
function M.exists(path) return M.backend.exists(path) end

function M.write(path, text)
  M.backend.ensureDir(dirname(path))
  return M.backend.write(path, text)
end

function M.append(path, text)
  M.backend.ensureDir(dirname(path))
  return M.backend.append(path, text)
end

return M
