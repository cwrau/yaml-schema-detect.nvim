# yaml-schema-detect.nvim

A Neovim plugin that automatically detects and applies YAML schemas for your YAML files using yaml-language-server (yamlls). It can automatically fetch and apply Custom Resource Definition (CRD) schemas from your current Kubernetes cluster.

## Features

- Automatic YAML schema detection for your files
- Seamless integration with yaml-language-server
- Dynamic schema switching based on file content
- Support for multiple YAML schemas
- Buffer-specific schema management
- Automatic fetching of Kubernetes CRD schemas from your current cluster
- Real-time schema validation against your cluster's CRDs
- Load schema from file

## Prerequisites

- Neovim > 0.11.0
- [yaml-language-server](https://github.com/redhat-developer/yaml-language-server)
- [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)

## Installation

Using [packer.nvim](https://github.com/wbthomason/packer.nvim):

```lua
use {
  'ChristofferNissen/yaml-schema-detect.nvim',
  requires = {
    'nvim-lua/plenary.nvim',
  }
}
```

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
<<<<<<< HEAD
  'cwrau/yaml-schema-detect.nvim',
  ---@module "yaml-schema-detect"
  ---@type YamlSchemaDetectOptions
  opts = {}, -- use default options
=======
  'ChristofferNissen/yaml-schema-detect.nvim',
  config = true,
>>>>>>> 9848976 (refactor)
  dependencies = {
    'nvim-lua/plenary.nvim',
  },
  ft = { "yaml" },
}
```

## Configuration

Plugin ships with some sensible defaults which you can tweak in your own way.

```lua
{
  disable_keymap = false,
  keymap = {
    refresh = "<leader>xr",
    cleanup = "<leader>xyc",
    info = "<leader>xyi",
  },
}
```

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

Disable default keybindings entirely:

```lua
{
  'cwrau/yaml-schema-detect.nvim',
  ---@module "yaml-schema-detect"
  ---@type YamlSchemaDetectOptions
  opts = {
    disable_keymap = true,
  },
  dependencies = {
    'nvim-lua/plenary.nvim',
  },
  ft = { "yaml" },
}
```

Change and toggle default keybindings:

```lua
{
  'cwrau/yaml-schema-detect.nvim',
  ---@module "yaml-schema-detect"
  ---@type YamlSchemaDetectOptions
  opts = {
    keymap = {
      refresh = "<leader>yr",
      cleanup = "<leader>yc",
      info = false,
    },
  },
  dependencies = {
    'nvim-lua/plenary.nvim',
  },
  ft = { "yaml" },
}
```

## Usage

The plugin works automatically once installed and configured. It will:

1. Detect the appropriate YAML schema for your files
2. Update yaml-language-server settings accordingly
3. Provide schema-aware completions and validations

## How It Works

The plugin analyses your YAML files and dynamically updates the yaml-language-server configuration to use the most appropriate schema based on the file content and context. For Kubernetes Custom Resources, it automatically connects to your current cluster to fetch the corresponding CRD schemas, ensuring your YAML files are validated against the actual CRD definitions in your cluster.
