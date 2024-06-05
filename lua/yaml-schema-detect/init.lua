local util = require("lspconfig").util

local M = {}

---@return table|nil
local function get_client()
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.bo.filetype ~= "yaml" then
    return nil
  end
  return util.get_active_client_by_name(bufnr, "yamlls")
end

---@param schema string
local function change_settings(schema)
  local client = get_client()
  if client == nil then
    return
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local uri = vim.uri_from_bufnr(bufnr)
  client.config.settings = vim.tbl_deep_extend("force", client.config.settings, {
    yaml = {
      schemas = {
        [schema] = uri,
      },
    },
  })
  client.notify("workspace/didChangeConfiguration")
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

function M.refreshSchema()
  local fileName = vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())
  if fileName:find("values.yaml$") then
    local schemaPath
    if fileName:find("/ci/") then
      schemaPath = fileName:gsub("/ci/[^/]-.yaml", "/values.schema.json")
    else
      schemaPath = fileName:gsub("/[^/]-.yaml", "/values.schema.json")
    end

    if file_exists(schemaPath) then
      change_settings("file://" .. schemaPath)
      return
    end
  end

  local yaml = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, -1, false), "\n")
  ---@type string|nil
  local schemaOverride = yaml:match("\n?# yaml%-language%-server: $schema=(.-)%s")
  if schemaOverride then
    vim.notify("Using schema override")
    change_settings(schemaOverride)
  else
    ---@type string|nil
    local apiVersion = yaml:match("\n?apiVersion: (.-)%s")
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
      ---@type string|nil
      local kind = yaml:match("\n?kind: (.-)%s") or yaml:match("\n?kind: (.-)$")
      if kind then
        local crdSelectors = {
          [[ .spec.names.singular == "]] .. kind:lower() .. [[" ]],
          [[ .spec.group == "]] .. apiGroup:lower() .. [[" ]],
        }
        local versionFilter
        if apiVersion then
          versionFilter = [[ .spec.versions[] | select(.name == "]] .. apiVersion .. [[") ]]
        else
          versionFilter = [[ .spec.versions[0] ]]
        end

        local schemaFile = os.tmpname()
        vim.api.nvim_create_autocmd("VimLeavePre", {
          desc = "yaml: auto-k8s-schema-detect: cleanup temporary file",
          callback = function()
            os.remove(schemaFile)
          end,
        })
        require("plenary.job")
          :new({
            command = "bash",
            args = {
              "-e",
              "-o",
              "pipefail",
              "-c",
              [[timeout 10 kubectl get crd -A -o json | jq -e '.items[] | select( ]] .. table.concat(
                crdSelectors,
                " and "
              ) .. [[) | ]] .. versionFilter .. [[ | .schema.openAPIV3Schema' > ]] .. schemaFile,
            },
            enable_recording = true,
            on_exit = function(_, exitCode, _)
              vim.schedule(function()
                if exitCode == 0 then
                  vim.notify("Using schema from cluster-CRD.")
                  change_settings("file://" .. schemaFile)
                else
                  vim.notify("Trying schema from github.")
                  -- https://raw.githubusercontent.com/instrumenta/kubernetes-json-schema/master/v1.18.0-standalone-strict/all.json
                  -- also use the server version for the schema
                  change_settings(
                    "https://raw.githubusercontent.com/yannh/kubernetes-json-schema/master/master-standalone-strict/"
                      .. kind:lower()
                      .. ".json"
                  )
                end
              end)
            end,
          })
          :start()
        return
      end
    end
  end
end

function M.setup()
  require("lspconfig").yamlls.setup({
    on_attach = function()
      M.refreshSchema()
    end,
  })
  require("which-key").register({
    x = {
      r = {
        M.refreshSchema,
        "Refresh YAML schema",
      },
    },
  }, { prefix = "<leader>" })
end

return M
