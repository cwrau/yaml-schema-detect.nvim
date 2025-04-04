local Job = require("plenary.job")
local util = require("lspconfig.util")

local M = {
  ---@type table<string, table<string, string>>
  schemas = {},
  ---@type table<integer, string>
  buffers = {},
  ---@type string|nil
  tmpFile = nil,
}

---@return vim.lsp.Client|nil
local function get_client()
  -- this is to ignore helm files
  if vim.bo.filetype ~= "yaml" then
    return nil
  end
  return util.get_active_client_by_name(vim.api.nvim_get_current_buf(), "yamlls")
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
            if existingSelector == currentBufferSelector or string.find(existingSelector, "*") then
              table.remove(previous_settings.yaml.schemas[existingSchemaURI], idx)
            end
          end
        elseif existingSelectors == currentBufferSelector or string.find(existingSelectors, "*") then
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
    client.notify("workspace/didChangeConfiguration", { settings = client.settings })
    vim.notify("YAML schema has been updated", vim.log.levels.INFO)
  else
    vim.notify("YAML schema is already up-to-date", vim.log.levels.INFO)
  end
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

---@class Type
---@field apiVersion string
---@field kind string

---@class TypeOverride
---@field override string

---@param lines string[]
---@return (Type|TypeOverride)[]
local function getTypes(lines)
  ---@type (Type|TypeOverride)[]
  local documentTypes = { {} }
  local documentIndex = 1
  for _, value in ipairs(lines) do
    if value == "---" then
      documentIndex = documentIndex + 1
      documentTypes[documentIndex] = {}
    else
      local schema = documentTypes[documentIndex]
      if schema["override"] == nil and (schema["apiVersion"] == nil or schema["kind"] == nil) then
        if schema["apiVersion"] == nil and value:find("^apiVersion: ") then
          schema.apiVersion = value:sub(13)
        elseif schema["kind"] == nil and value:find("^kind: ") then
          schema.kind = value:sub(7)
        elseif schema["override"] == nil and value:find("^# yaml%-language%-server: %$schema=") then
          schema = { override = value:sub(33) }
        end
        documentTypes[documentIndex] = schema
      end
    end
  end
  return documentTypes
end

---@param type Type|TypeOverride
---@param callback fun(schemaURI: string|nil)
local function getSchema(type, callback)
  if type.override then
    callback(type.override)
  elseif type.apiVersion and type.kind then
    if type.apiVersion == "v1" and type.kind == "List" then
      -- TODO: implement List schema
      callback(nil)
    elseif M.schemas[type.apiVersion] and M.schemas[type.apiVersion][type.kind] then
      callback(M.schemas[type.apiVersion][type.kind])
    else
      ---@type string|nil
      local apiVersion = type.apiVersion
      if apiVersion then
        ---@type string
        local apiGroup
        if apiVersion:find("/") then
          apiGroup = apiVersion:match("(.+)/.+")
          apiVersion = apiVersion:match(".+/(.+)")
        else
          apiGroup = apiVersion
          apiVersion = nil
        end
        local crdSelectors = {
          [[ .spec.names.singular == "]] .. type.kind:lower() .. [[" ]],
          [[ .spec.group == "]] .. apiGroup:lower() .. [[" ]],
        }
        local versionFilter
        if apiVersion then
          versionFilter = [[ .spec.versions[] | select(.name == "]] .. apiVersion .. [[") ]]
        else
          versionFilter = [[ .spec.versions[0] ]]
        end
        M.tmpFile = os.tmpname()
        Job:new({
          command = "bash",
          args = {
            "-e",
            "-o",
            "pipefail",
            "-c",
            [[kubectl get crd -A -o json | jq -e '.items[] | select( ]]
              .. table.concat(crdSelectors, " and ")
              .. [[) | ]]
              .. versionFilter
              .. [[ | .schema.openAPIV3Schema' > ]]
              .. M.tmpFile,
          },
          enable_recording = true,
          on_exit = function(j, crdExitCode, _)
            if crdExitCode == 0 then
              callback("file://" .. M.tmpFile)
            else
              os.remove(M.tmpFile)
              M.tmpFile = nil
              Job
                :new({
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
                    callback(
                      "https://raw.githubusercontent.com/yannh/kubernetes-json-schema/master/"
                        .. kubeVersion
                        .. "-standalone-strict/"
                        .. type.kind:lower()
                        .. "-"
                        .. type.apiVersion:gsub("/", "-"):gsub(".authorization.k8s.io", ""):gsub(".k8s.io", "")
                        .. ".json"
                    )
                  end,
                })
                :start()
            end
          end,
        }):start()
      end
    end
  else
    callback(nil)
  end
end

---@param lines string[]
---@param callback fun(schemaURIs: (string|nil)[])
local function getSchemas(lines, callback)
  ---@type fun(types: (Type|TypeOverride)[], schemas: (string|nil)[])
  local listCallback
  listCallback = function(types, schemas)
    local type = types[1]
    getSchema(type, function(schemaURI)
      if type.apiVersion and type.kind then
        M.schemas[type.apiVersion] = M.schemas[type.apiVersion] or {}
        if M.schemas[type.apiVersion][type.kind] ~= schemaURI then
          M.schemas[type.apiVersion][type.kind] = schemaURI
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
    listCallback(types, {})
  else
    callback({})
  end
end

---@param client vim.lsp.Client|nil
function M.refreshSchema(client)
  local bufnr = vim.api.nvim_get_current_buf()
  local fileName = vim.api.nvim_buf_get_name(bufnr)
  if fileName:find("values.yaml$") then
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
    local schemaJson
    if #schemaURIs == 0 then
      return
    elseif #schemaURIs == 1 then
      schemaJson = vim.json.encode({ ["$ref"] = schemaURIs[1] })
    else
      local schema = {
        schemaSequence = {},
      }
      for _, documentSchemaURI in ipairs(schemaURIs) do
        table.insert(schema.schemaSequence, { ["$ref"] = documentSchemaURI })
      end
      schemaJson = vim.json.encode(schema)
    end
    M.tmpFile = M.buffers[bufnr] or os.tmpname()
    local file = io.open(M.tmpFile, "w")
    if file then
      file:write(schemaJson)
      file:close()
      if M.buffers[bufnr] ~= M.tempFile then
        M.buffers[bufnr] = M.tempFile
      end
      local schemaURI = "file://" .. M.tmpFile
      M.tmpFile = nil
      vim.schedule(function()
        change_settings(schemaURI, client)
      end)
    end
  end)
end

local function cleanup()
  for _, kinds in pairs(M.schemas) do
    for _, schemaURI in pairs(kinds) do
      if schemaURI:find("^file://") then
        pcall(os.remove, schemaURI:sub(8))
      end
    end
  end
  for _, schemaURI in pairs(M.buffers) do
    pcall(os.remove, schemaURI:sub(8))
  end
  if M.tmpFile then
    pcall(os.remove, M.tmpFile)
  end
end

function M.setup()
  local requiredTools = { "kubectl", "jq" }
  for _, tool in ipairs(requiredTools) do
    if vim.fn.executable(tool) ~= 1 then
      vim.notify(tool .. " is not installed", vim.log.levels.ERROR)
    end
  end
  require("lspconfig").yamlls.setup({
    on_attach = M.refreshSchema,
  })
  require("which-key").add({ {
    "<leader>xr",
    M.refreshSchema,
    desc = "Refresh YAML schema",
  } })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    desc = "yaml: auto-k8s-schema-detect: cleanup temporary file",
    callback = cleanup,
  })
end

return M
