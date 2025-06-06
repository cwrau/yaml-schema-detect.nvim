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

---@param client vim.lsp.Client|nil
function M.refreshSchema(client)
  local bufnr = vim.api.nvim_get_current_buf()
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

function M.setup()
  require("lspconfig").yamlls.setup({
    on_attach = M.refreshSchema,
  })
  require("which-key").add({ {
    "<leader>xr",
    M.refreshSchema,
    desc = "Refresh YAML schema",
  } })
  require("which-key").add({ {
    "<leader>xyc",
    cleanup,
    desc = "Clean YAML schema files",
  } })
  require("which-key").add({
    {
      "<leader>xyi",
      function()
        vim.notify(vim.inspect(M))
      end,
      desc = "Show YAML schema info",
    },
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    desc = "yaml: auto-k8s-schema-detect: cleanup temporary file",
    callback = cleanup,
  })
end

return M
