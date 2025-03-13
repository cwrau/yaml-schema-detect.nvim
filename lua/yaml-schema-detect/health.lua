local M = {}

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
  local active_clients = vim.lsp.get_active_clients()
  local yaml_client_found = false

  for _, client in ipairs(active_clients) do
    if client.name == "yamlls" then
      yaml_client_found = true
      break
    end
  end

  if yaml_client_found then
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
