local M = {}

local util = require("lspconfig.util")

local health = vim.health
local function check_executable(name)
  if vim.fn.executable(name) == 1 then
    health.ok(string.format("'%s' executable found in PATH", name))
    return true
  else
    health.error(string.format("'%s' executable not found in PATH", name))
    return false
  end
end

local function check_plugin(plugin)
  local ok, _ = pcall(require, plugin)
  if ok then
    health.ok(string.format("'%s' plugin is installed", plugin))
    return true
  else
    health.error(string.format("'%s' plugin is required but not installed", plugin))
    return false
  end
end

local function check_lsp_client()
  local yaml_client = util.get_active_client_by_name(vim.api.nvim_get_current_buf(), "yamlls")

  if yaml_client ~= nil then
    health.ok("yaml-language-server is running")
  else
    health.warn("yaml-language-server is not running. Make sure it's properly configured in your LSP setup")
  end
end

local function check_kubernetes()
  if check_executable("kubectl") then
    -- Check cluster connectivity via kubectl version exit code
    local output = vim.system({ "kubectl", "version" }, { stdout = false, stderr = false }):wait()

    if output.code == 0 then
      health.ok("Kubernetes cluster is accessible")

      -- Check RBAC permissions for CRDs
      local crd_output = vim.system({ "kubectl", "get", "crds" }, { stdout = false, stderr = false }):wait()
      if crd_output.code == 0 then
        health.ok("Has permissions to read all CRDs")
      else
        health.warn("No permissions to read all CRDs. Schema detection for custom resources may not work")
      end
    else
      health.warn("Kubernetes cluster not accessible. Some CRD schema features may not work")
    end
  end
end

function M.check()
  health.start("yaml-schema-detect.nvim report")

  -- Check required plugins
  local required_plugins = {
    "plenary",
    "lspconfig",
  }
  for _, plugin in ipairs(required_plugins) do
    check_plugin(plugin)
  end

  -- Check required executables
  local required_executables = {
    "yaml-language-server",
    "bash",
    "jq",
  }
  for _, executable in ipairs(required_executables) do
    check_executable(executable)
  end

  -- Check LSP client
  check_lsp_client()

  -- Check Kubernetes setup (optional but recommended)
  check_kubernetes()
end

return M
