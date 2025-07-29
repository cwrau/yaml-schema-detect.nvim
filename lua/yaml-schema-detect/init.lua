local Job = require("plenary.job")

local M = {
  ---@type table<string, table<string, string>>
  schemas = {},
  ---@type table<integer, string>
  buffers = {},
  ---@type string[]
  tmpFiles = {},
}

---@return vim.lsp.Client|nil
local function get_client()
  -- this is to ignore helm files
  if vim.bo.filetype ~= "yaml" then
    return nil
  end
  return vim.lsp.get_clients({ bufnr = vim.api.nvim_get_current_buf(), name = "yamlls" })[1]
end

---@param schemaURI string
---@param client vim.lsp.Client|nil
local function change_settings(schemaURI, client)
  client = client or get_client()
  if client == nil then
    return
  end
  local currentBufferSelector = vim.uri_from_bufnr(vim.api.nvim_get_current_buf())
  if
    client.settings == nil
    or client.settings.yaml == nil
    or client.settings.yaml.schemas == nil
    or client.settings.yaml.schemas[schemaURI] ~= currentBufferSelector
  then
    local previous_settings = client.settings
    if previous_settings and previous_settings.yaml and previous_settings.yaml.schemas then
      for existingSchemaURI, existingSelectors in pairs(previous_settings.yaml.schemas) do
        if vim.islist(existingSelectors) then
          for idx, existingSelector in pairs(existingSelectors) do
            if existingSelector == currentBufferSelector or existingSelector:find("*") then
              table.remove(previous_settings.yaml.schemas[existingSchemaURI], idx)
            end
          end
        elseif existingSelectors == currentBufferSelector or existingSelectors:find("*") then
          previous_settings.yaml.schemas[existingSchemaURI] = nil
        end
      end
    end
    client.settings = vim.tbl_deep_extend("force", previous_settings or {}, {
      yaml = {
        schemas = {
          [schemaURI] = currentBufferSelector,
        },
      },
    })
    vim.notify("YAML schema has been updated", vim.log.levels.INFO)
  else
    vim.notify("YAML schema is already up-to-date", vim.log.levels.INFO)
  end
  client:notify("workspace/didChangeConfiguration", { settings = client.settings })
end

---@param path string
---@return boolean
local function file_exists(path)
  local file = io.open(path, "r")
  if file == nil then
    return false
  else
    io.close(file)
    return true
  end
end

---@class ApiVersion
---@field group? string
---@field version string
local ApiVersion = {}

---@param group? string
---@param version string
---@return ApiVersion
function ApiVersion:new(group, version)
  local o = {
    group = group,
    version = version,
  }
  setmetatable(o, self)
  self.__index = self
  return o
end

---@param delimiter? string "/" if not set
---@return string
function ApiVersion:joinedString(delimiter)
  if self.group then
    return self.group .. (delimiter or "/") .. self.version
  else
    return self.version
  end
end

---@class Type
---@field apiVersion ApiVersion
---@field kind string

---@class TypeOverride
---@field override string

---@param lines string[]
---@return (Type|TypeOverride)[]
local function getTypes(lines)
  ---@type ApiVersion[]
  local apiVersions = {}
  ---@type string[]
  local kinds = {}
  ---@type TypeOverride[]
  local overrides = {}
  local documentIndex = 1
  for _, value in ipairs(lines) do
    if value == "---" then
      documentIndex = documentIndex + 1
    else
      ---@type TypeOverride|nil
      local override = overrides[documentIndex]
      ---@type ApiVersion|nil
      local apiVersion = apiVersions[documentIndex]
      ---@type string|nil
      local kind = kinds[documentIndex]
      if override == nil and (apiVersion == nil or kind == nil) then
        if apiVersion == nil and value:find("^apiVersion: ") then
          value = value:sub(13)
          local splittedValues = vim.split(value, "/")
          if #splittedValues == 2 then
            apiVersions[documentIndex] = ApiVersion:new(splittedValues[1], splittedValues[2])
          else
            apiVersions[documentIndex] = ApiVersion:new(nil, splittedValues[1])
          end
        elseif kind == nil and value:find("^kind: ") then
          kinds[documentIndex] = value:sub(7)
        elseif override == nil and value:find("^# yaml%-language%-server: %$schema=") then
          overrides[documentIndex] = { override = value:sub(33) }
        end
      end
    end
  end
  ---@type (Type|TypeOverride)[]
  local documentTypes = {}
  for i = 1, documentIndex do
    local apiVersion = apiVersions[i]
    local kind = kinds[i]
    local override = overrides[i]
    if override then
      table.insert(documentTypes, override)
    elseif apiVersion and kind then
      table.insert(documentTypes, { apiVersion = apiVersion, kind = kind })
    end
  end
  return documentTypes
end

---@param type Type
---@param callback fun(schemaURI: string)
local function getSchemaFromCatalogues(type, callback)
  ---@diagnostic disable-next-line: missing-fields
  return Job:new({
    command = "bash",
    args = {
      "-e",
      "-o",
      "pipefail",
      "-c",
      [[ kubectl version -o json | jq -er '.serverVersion | "v\(.major).\(.minor).0"' ]],
    },
    enable_recording = true,
    on_exit = function(job, kubeVersionExitCode, _)
      ---@type string
      local kubeVersion
      if kubeVersionExitCode == 0 then
        kubeVersion = job:result()[1]
      else
        kubeVersion = "master"
      end
      ---@type string[]
      local possibleURLs = {
        "https://raw.githubusercontent.com/yannh/kubernetes-json-schema/master/"
          .. kubeVersion
          .. "-standalone-strict/"
          .. type.kind:lower()
          .. "-"
          .. type.apiVersion:joinedString("-"):gsub(".authorization.k8s.io", ""):gsub(".k8s.io", "")
          .. ".json",
      }
      if type.apiVersion.group then
        table.insert(
          possibleURLs,
          "https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/"
            .. type.apiVersion.group
            .. "/"
            .. type.kind:lower()
            .. "_"
            .. type.apiVersion.version
            .. ".json"
        )
      end
      ---@type fun(urls: string[])
      local listCallback
      listCallback = function(urls)
        ---@diagnostic disable-next-line: missing-fields
        return Job:new({ "curl", "-IfsSL", urls[1] })
          :after(function(_, exitCode, _)
            if exitCode == 0 then
              return callback(urls[1])
            elseif #urls > 1 then
              return listCallback({ unpack(urls, 2) })
            else
              return callback("")
            end
          end)
          :start()
      end
      return listCallback(possibleURLs)
    end,
  }):start()
end

---@param type Type|TypeOverride
---@param callback fun(schemaURI: string)
local function getSchema(type, callback)
  if type.override then
    return callback(type.override)
  elseif type.apiVersion and type.kind then
    if type.apiVersion.group == nil and type.apiVersion.version == "v1" and type.kind == "List" then
      -- TODO: implement List schema
      return callback("")
    else
      if M.schemas[type.apiVersion:joinedString()] then
        local schemaFile = M.schemas[type.apiVersion:joinedString()][type.kind]
        ---@type string
        local schemaURI
        if schemaFile then
          if schemaFile:find("^file://") then
            if file_exists(schemaFile:sub(8)) then
              schemaURI = schemaFile
            end
          elseif schemaFile:find("^https://") then
            schemaURI = schemaFile
          end
        end
        if schemaURI then
          return callback(schemaURI)
        end
      end
      if type.apiVersion then
        local crdSelectors = {
          [[ .spec.names.singular == "]] .. type.kind:lower() .. [[" ]],
          [[ .spec.group == "]] .. (type.apiVersion.group or ""):lower() .. [[" ]],
        }
        ---@type string
        local versionFilter
        if type.apiVersion.version then
          versionFilter = [[ .spec.versions[] | select(.name == "]] .. type.apiVersion.version .. [[") ]]
        else
          versionFilter = [[ .spec.versions[0] ]]
        end

        ---@diagnostic disable-next-line: missing-fields
        return Job:new({
          command = "bash",
          args = {
            "-e",
            "-o",
            "pipefail",
            "-c",
            [[kubectl get crd -A -o json | jq -ce '.items[] | select( ]]
              .. table.concat(crdSelectors, " and ")
              .. [[) | ]]
              .. versionFilter
              .. [[ | .schema.openAPIV3Schema' ]],
          },
          enable_recording = true,
          on_exit = function(job, crdExitCode, _)
            if crdExitCode == 0 then
              local tmpFile = os.tmpname()
              table.insert(M.tmpFiles, tmpFile)
              local file = io.open(tmpFile, "w")
              if file then
                file:setvbuf("no")
                local _, error = file:write(table.concat(job:result(), ""))
                file:close()
                if error then
                  vim.schedule(function()
                    vim.notify("Error writing schema to temporary file: " .. error)
                  end)
                  return callback("")
                end
                return callback("file://" .. tmpFile)
              else
                return callback("")
              end
            else
              ---@cast type Type
              return getSchemaFromCatalogues(type, callback)
            end
          end,
        }):start()
      end
    end
    return callback("")
  end
end

---@param lines string[]
---@param callback fun(schemaURIs: string[])
local function getSchemas(lines, callback)
  ---@type fun(types: (Type|TypeOverride)[], schemas: string[])
  local listCallback
  listCallback = function(types, schemas)
    local type = types[1]
    getSchema(type, function(schemaURI)
      if schemaURI == "" then
        vim.schedule(function()
          vim.notify("Couldn't find schema for " .. type.apiVersion:joinedString() .. "/" .. type.kind)
        end)
      end
      if type.apiVersion and type.kind then
        M.schemas[type.apiVersion:joinedString()] = M.schemas[type.apiVersion:joinedString()] or {}
        if M.schemas[type.apiVersion:joinedString()][type.kind] ~= schemaURI then
          M.schemas[type.apiVersion:joinedString()][type.kind] = schemaURI
        end
      end
      table.insert(schemas, schemaURI)
      if #types > 1 then
        listCallback({ unpack(types, 2) }, schemas)
      else
        callback(schemas)
      end
    end)
  end
  local types = getTypes(lines)
  if #types > 0 then
    return listCallback(types, {})
  else
    return callback({})
  end
end

local function iter_parents(start, stop)
  local dirs = {}
  local current = vim.loop.fs_realpath(start)
  stop = vim.loop.fs_realpath(stop)
  while current and current:sub(1, #stop) == stop and current ~= stop do
    table.insert(dirs, current)
    local parent = vim.fn.fnamemodify(current, ":h")
    if parent == current then
      break
    end
    current = parent
  end
  table.insert(dirs, stop)
  return dirs
end

local function find_vscode_schema(bufnr)
  local candidates = {
    ".vscode/schema.json",
    ".vscode/schema.yaml",
    "schema.json",
    "schema.yaml",
  }
  local buf_path = vim.api.nvim_buf_get_name(bufnr or 0)
  if not buf_path or buf_path == "" then
    return nil
  end
  local file_dir = vim.fn.fnamemodify(buf_path, ":h")
  local root = vim.loop.fs_realpath(vim.fn.getcwd())

  for _, dir in ipairs(iter_parents(file_dir, root)) do
    for _, candidate in ipairs(candidates) do
      local path = dir .. "/" .. candidate
      local file = io.open(path, "r")
      if file then
        file:close()
        return path
      end
    end
  end

  -- Fallback: (optional) check global or workspace schema locations here

  return nil
end

---@param client vim.lsp.Client|nil
function M.refreshSchema(client, opts)
  -- Handle Neovim LSP on_attach(client, bufnr) signature
  if type(opts) == "number" then
    opts = {} -- or you can allow passing bufnr explicitly if needed
  elseif opts == nil then
    opts = {}
  end
  local bufnr = vim.api.nvim_get_current_buf()

  -- Try VSCode-style schema auto-load first
  -- VSCode auto-load only if not ignored
  if not opts.ignore_vscode then
    local schema_path = find_vscode_schema(bufnr)
    if schema_path then
      local schemaURI = "file://" .. schema_path
      client = client or vim.lsp.get_clients({ bufnr = bufnr, name = "yamlls" })[1]
      if client then
        local currentBufferSelector = vim.uri_from_bufnr(bufnr)
        client.settings = vim.tbl_deep_extend("force", client.settings or {}, {
          yaml = {
            schemas = {
              [schemaURI] = currentBufferSelector,
            },
          },
        })
        client:notify("workspace/didChangeConfiguration", { settings = client.settings })
        vim.notify("Auto-loaded YAML schema from: " .. schema_path, vim.log.levels.INFO)
        return
      end
    end
  end

  local fileName = vim.api.nvim_buf_get_name(bufnr)
  if fileName:find("values.yaml$") then
    ---@type string
    local schemaPath
    if fileName:find("/ci/") then
      schemaPath = fileName:gsub("/ci/[^/]-.yaml", "/values.schema.json")
    else
      schemaPath = fileName:gsub("/[^/]-.yaml", "/values.schema.json")
    end

    if file_exists(schemaPath) then
      return change_settings("file://" .. schemaPath, client)
    end
  end

  getSchemas(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), function(schemaURIs)
    ---@type string
    local schemaURI
    if #schemaURIs == 0 then
      return
    elseif #schemaURIs == 1 then
      schemaURI = schemaURIs[1]
    else
      local schema = {
        schemaSequence = {},
      }
      for _, documentSchemaURI in ipairs(schemaURIs) do
        if documentSchemaURI ~= "" then
          table.insert(schema.schemaSequence, { ["$ref"] = documentSchemaURI })
        else
          table.insert(schema.schemaSequence, {})
        end
      end
      M.buffers[bufnr] = M.buffers[bufnr] or os.tmpname()
      local file = io.open(M.buffers[bufnr], "w")
      if file then
        file:write(vim.json.encode(schema))
        file:close()
        schemaURI = "file://" .. M.buffers[bufnr]
      end
    end
    if schemaURI then
      --- switch to main context for UI call
      vim.schedule(function()
        change_settings(schemaURI, client)
      end)
    end
  end)
end

local function cleanup()
  for _, versions in pairs(M.schemas) do
    for kind, schemaURI in pairs(versions) do
      if schemaURI:find("^file://") then
        pcall(os.remove, schemaURI:sub(8))
        versions[kind] = nil
      end
    end
  end

  for _, file in pairs(M.buffers) do
    pcall(os.remove, file)
  end
  M.buffers = {}

  for _, tmpFile in pairs(M.tmpFiles) do
    if tmpFile then
      pcall(os.remove, tmpFile)
    end
  end
  M.tmpFiles = {}
end

function M.load_schema_with_picker()
  local function apply_schema(path)
    if not path or path == "" then
      vim.notify("No schema selected.", vim.log.levels.WARN)
      return
    end
    local schemaURI = "file://" .. path
    local client = vim.lsp.get_clients({ bufnr = vim.api.nvim_get_current_buf(), name = "yamlls" })[1]
    if client then
      local currentBufferSelector = vim.uri_from_bufnr(vim.api.nvim_get_current_buf())
      client.settings = vim.tbl_deep_extend("force", client.settings or {}, {
        yaml = {
          schemas = {
            [schemaURI] = currentBufferSelector,
          },
        },
      })
      client:notify("workspace/didChangeConfiguration", { settings = client.settings })
      vim.notify("Loaded YAML schema from: " .. path, vim.log.levels.INFO)
    else
      vim.notify("yamlls LSP client not found", vim.log.levels.ERROR)
    end
  end

  local buf_path = vim.api.nvim_buf_get_name(0)
  local dir = vim.fn.fnamemodify(buf_path, ":h")

  -- Try Telescope, else fall back to vim.ui.select
  local ok, telescope = pcall(require, "telescope.builtin")
  if ok then
    telescope.find_files({
      prompt_title = "Select any file as schema",
      cwd = dir,
      -- No filtering on extension
      attach_mappings = function(prompt_bufnr, map)
        local actions = require("telescope.actions")
        local action_state = require("telescope.actions.state")
        actions.select_default:replace(function()
          actions.close(prompt_bufnr)
          local selection = action_state.get_selected_entry()
          if selection and (selection.path or selection.filename) then
            local path = selection.path or (dir .. "/" .. selection.filename)
            apply_schema(path)
          end
        end)
        return true
      end,
    })
    return
  end

  -- Fallback: build a list of all files (no extension filtering) and use vim.ui.select
  local files = {}
  local handle = vim.loop.fs_scandir(dir)
  if handle then
    while true do
      local name, type = vim.loop.fs_scandir_next(handle)
      if not name then
        break
      end
      if type == "file" then
        table.insert(files, dir .. "/" .. name)
      end
    end
  end

  if #files == 0 then
    vim.notify("No files found in: " .. dir, vim.log.levels.WARN)
    return
  end

  vim.ui.select(files, { prompt = "Select any file to load as schema" }, apply_schema)
end

function M.setup()
  vim.lsp.config("yamlls", {
    on_attach = M.refreshSchema,
  })
  require("which-key").add({
    {
      "<leader>zr",
      M.refreshSchema,
      desc = "Refresh YAML schema",
    },
  })
  require("which-key").add({
    {
      "<leader>zR",
      function()
        require("yaml-schema-detect").refreshSchema(nil, { ignore_vscode = true })
      end,
      desc = "Refresh YAML schema (ignore VSCode auto-load)",
    },
  })
  require("which-key").add({ {
    "<leader>zyc",
    cleanup,
    desc = "Clean YAML schema files",
  } })
  require("which-key").add({
    {
      "<leader>zyi",
      function()
        vim.notify(vim.inspect(M))
      end,
      desc = "Show YAML schema info",
    },
  })
  require("which-key").add({
    {
      "<leader>zyp",
      require("yaml-schema-detect").load_schema_with_picker,
      desc = "Pick and load YAML schema from file",
    },
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    desc = "yaml: auto-k8s-schema-detect: cleanup temporary file",
    callback = cleanup,
  })
end

return M
