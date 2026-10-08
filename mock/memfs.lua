-- mock/memfs.lua
-- In-memory stand-in for OpenOS's `filesystem` library (the subset ocui
-- uses), over a `files` table of path -> content shared with the mock
-- ocui.storage backend, so config files and files created through this
-- API are the same thing.

local M = {}

local function segments(path)
  local parts = {}
  for part in tostring(path):gmatch("[^/]+") do
    if part == ".." then
      if #parts > 0 then table.remove(parts) end
    elseif part ~= "." then
      parts[#parts + 1] = part
    end
  end
  return parts
end

local function canonical(path)
  return "/" .. table.concat(segments(path), "/")
end

-- files: path -> content (strings); returns the filesystem module.
function M.new(files, clock)
  files = files or {}
  local dirs = { ["/"] = true }
  local mtime = {}
  local fs = {}

  local function now() return math.floor((clock and clock() or 0) * 1000) end

  local function parentOf(path)
    local parts = segments(path)
    table.remove(parts)
    return "/" .. table.concat(parts, "/")
  end

  local function ensureParents(path)
    local p = parentOf(path)
    while p ~= "/" and not dirs[p] do
      dirs[p] = true
      p = parentOf(p)
    end
  end

  local function isDir(path)
    path = canonical(path)
    if dirs[path] then return true end
    local prefix = path == "/" and "/" or path .. "/"
    for f in pairs(files) do
      if f:sub(1, #prefix) == prefix then return true end
    end
    return false
  end

  fs.canonical = canonical
  fs.segments = segments
  function fs.concat(...)
    return canonical(table.concat({ ... }, "/"))
  end
  function fs.name(path)
    local parts = segments(path)
    return parts[#parts]
  end
  function fs.path(path)
    local p = parentOf(path)
    return p == "/" and "/" or p .. "/"
  end

  function fs.exists(path)
    path = canonical(path)
    return files[path] ~= nil or isDir(path)
  end
  fs.isDirectory = isDir

  function fs.size(path)
    local content = files[canonical(path)]
    return content and #content or 0
  end

  function fs.lastModified(path)
    return mtime[canonical(path)] or 0
  end

  function fs.makeDirectory(path)
    path = canonical(path)
    if files[path] then return nil, "file exists" end
    dirs[path] = true
    ensureParents(path)
    return true
  end

  -- Iterator of names in a directory; directories end in "/".
  function fs.list(path)
    path = canonical(path)
    if not isDir(path) then return nil, "no such file or directory" end
    local prefix = path == "/" and "/" or path .. "/"
    local seen, names = {}, {}
    local function addFrom(p, isFile)
      if p:sub(1, #prefix) == prefix and #p > #prefix then
        local rest = p:sub(#prefix + 1)
        local first, more = rest:match("^([^/]+)(/?.*)$")
        local name = (more ~= "" or not isFile) and (first .. "/") or first
        if not seen[name] then
          seen[name] = true
          names[#names + 1] = name
        end
      end
    end
    for f in pairs(files) do addFrom(f, true) end
    for d in pairs(dirs) do addFrom(d, false) end
    table.sort(names)
    local i = 0
    return function()
      i = i + 1
      return names[i]
    end
  end

  function fs.remove(path)
    path = canonical(path)
    local removed = false
    if files[path] then files[path] = nil; removed = true end
    local prefix = path .. "/"
    for f in pairs(files) do
      if f:sub(1, #prefix) == prefix then files[f] = nil; removed = true end
    end
    for d in pairs(dirs) do
      if d == path or d:sub(1, #prefix) == prefix then dirs[d] = nil; removed = true end
    end
    if not removed then return nil, "no such file or directory" end
    return true
  end

  function fs.copy(from, to)
    from, to = canonical(from), canonical(to)
    if files[from] == nil then return nil, "no such file" end
    files[to] = files[from]
    mtime[to] = now()
    ensureParents(to)
    return true
  end

  function fs.rename(from, to)
    from, to = canonical(from), canonical(to)
    if fs.exists(to) then return nil, "target exists" end
    if files[from] ~= nil then
      files[to] = files[from]
      files[from] = nil
      ensureParents(to)
      return true
    end
    if not isDir(from) then return nil, "no such file or directory" end
    local prefix = from .. "/"
    local moves = {}
    for f, content in pairs(files) do
      if f:sub(1, #prefix) == prefix then moves[#moves + 1] = { f, content } end
    end
    for _, m in ipairs(moves) do
      files[m[1]] = nil
      files[to .. m[1]:sub(#from + 1)] = m[2]
    end
    local dmoves = {}
    for d in pairs(dirs) do
      if d == from or d:sub(1, #prefix) == prefix then dmoves[#dmoves + 1] = d end
    end
    for _, d in ipairs(dmoves) do
      dirs[d] = nil
      dirs[to .. d:sub(#from + 1)] = true
    end
    ensureParents(to)
    return true
  end

  -- Handle with :read(n | "*a"), :write(s), :seek(whence, offset), :close().
  function fs.open(path, mode)
    path = canonical(path)
    mode = mode or "r"
    local writing = mode:find("[wa]") ~= nil
    if not writing and files[path] == nil then return nil, path end
    if writing and isDir(path) then return nil, "is a directory" end
    local buffer = ""
    if mode:find("a") or not writing then buffer = files[path] or "" end
    local pos = mode:find("a") and #buffer or 0
    local h = {}
    function h:read(n)
      if pos >= #buffer then return nil end
      local count = (n == "*a" or n == "a" or n == nil) and #buffer or n
      local chunk = buffer:sub(pos + 1, pos + count)
      pos = pos + #chunk
      return chunk
    end
    function h:write(s)
      s = tostring(s)
      buffer = buffer:sub(1, pos) .. s .. buffer:sub(pos + #s + 1)
      pos = pos + #s
      files[path] = buffer
      mtime[path] = now()
      return true
    end
    function h:seek(whence, offset)
      offset = offset or 0
      if whence == "set" then pos = offset
      elseif whence == "end" then pos = #buffer + offset
      else pos = pos + offset end
      return pos
    end
    function h:close() return true end
    if writing then
      files[path] = buffer
      mtime[path] = now()
      ensureParents(path)
    end
    return h
  end

  fs._files = files
  fs._dirs = dirs
  return fs
end

return M
