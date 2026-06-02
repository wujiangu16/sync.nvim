# sync.nvim

`sync.nvim` syncs the current Neovim working directory to remote machines with
`rsync`.

It reads hosts from your local SSH config, usually:

```text
~/.ssh/config
```

It does not use Git and no longer needs `~/.config/sync/.config`.

## Features

- Read `Host` entries from local `~/.ssh/config`.
- Sync the current working directory with `rsync`.
- Default remote path mirrors the local path under home.
- Support direct sync with `dest`.
- Support multi-destination sync with `dest,dest`.
- Support proxy sync with `proxy-dest`.
- Use built-in default exclude patterns.
- Support per-folder `.sync_nvim.lua` overrides when needed.
- Ask before loading a new local Lua config file.
- Support dry-run command previews.

## Remote Path

The remote directory defaults to the same home-relative path as the local
directory.

Examples:

```text
~/code/my_project -> ~/code/my_project
~/.config/nvim    -> ~/.config/nvim
```

If the local directory is outside your home directory, the plugin falls back to
`~/<current-folder-name>`.

## Default Excludes

The default excludes are defined inside the plugin:

```lua
{ "*.swp", "*.swo", "*.swx", "*__pycache__" }
```

You can override them in a local `.sync_nvim.lua`.

## Installation

With lazy.nvim:

```lua
{
  "wujiangu16/sync.nvim",
  name = "sync_nvim",
  lazy = false,
  opts = {},
}
```

## Commands

| Command | What it does |
| --- | --- |
| `:SyncNvim` | Prompt for a host choice and rsync the current folder. |
| `:SyncNvimDelete` | Same as `:SyncNvim`, but adds `--delete`. |
| `:SyncNvimDryRun` | Print the commands that would run without syncing. |
| `:SyncNvimPlan` | Alias for `:SyncNvimDryRun`. |
| `:SyncNvimHosts` | Print SSH config hosts. |
| `:SyncNvimConfig` | Open `~/.ssh/config`. |
| `:SyncNvimTrust` | Trust the local `.sync_nvim.lua` in the current folder. |

## Usage

Open Neovim in a project folder, or run:

```vim
:cd ~/code/my_project
```

Then sync directly to one host:

```vim
:SyncNvim
```

When prompted:

```text
Enter your choice(dest, dest,dest, or proxy-dest): 2
```

This runs the equivalent of:

```sh
rsync -av --exclude='*.swp' --exclude='*.swo' --exclude='*.swx' --exclude='*__pycache__' ~/code/my_project/ remote-host:~/code/my_project/
```

You can also pass the host choice directly:

```vim
:SyncNvim 2
:SyncNvim 2,5
:SyncNvim 2-5
```

Preview the commands without running them:

```vim
:SyncNvimDryRun 2-5
```

Sync local to multiple hosts:

```text
Enter your choice(dest, dest,dest, or proxy-dest): 2,5
```

This syncs local -> host 2 and local -> host 5.

Proxy sync:

```text
Enter your choice(dest, dest,dest, or proxy-dest): 2-5
```

This first syncs local -> host 2, then SSHs into host 2 and runs rsync from
host 2 -> host 5.

Sync with remote deletes:

```vim
:SyncNvimDelete
```

## Configuration

```lua
require("sync_nvim").setup({
  ssh_config_path = "~/.ssh/config",
  rsync = "rsync",
  ssh = "ssh",
  rsync_args = { "-av" },
  excludes = { "*.swp", "*.swo", "*.swx", "*__pycache__" },
  remote_home = "~",
  remote_dir = nil,
  hosts = {},
  timeout = 0,
  notify = true,
  use_local_config = true,
  local_config_trust = "prompt",
  local_config_trust_file = nil,
  local_config_names = { ".sync_nvim.lua", ".sync-nvim.lua" },
})
```

`timeout = 0` omits rsync's `--timeout` option entirely. Set a positive
number to add `--timeout=<seconds>`.

## Per-Folder Overrides

In any project folder, add `.sync_nvim.lua`:

```lua
return {
  timeout = 0,
  excludes = { "*.swp", "*.swo", "__pycache__", ".git" },
}
```

Override the remote destination directory for one folder:

```lua
return {
  remote_dir = "~/scratch/my_project",
}
```

Use different settings for different SSH hosts:

```lua
return {
  timeout = 0,
  excludes = { "*.swp", "*.swo", "__pycache__", ".git" },

  hosts = {
    server_a = {
      remote_dir = "~/scratch/project-a",
      excludes = { "*.swp", "*.swo", "__pycache__", ".git", "data" },
    },
    server_b = {
      remote_dir = "~/work/project-b",
      timeout = 120,
    },
  },
}
```

Keys under `hosts` are SSH `Host` aliases from `~/.ssh/config`. Global settings
apply first, then the matching host settings override them.

If `.sync_nvim.lua` exists in the current working directory, it is merged into
the global config for that command. If it does not exist, defaults are used.

Because `.sync_nvim.lua` is a Lua file, it can execute code. By default,
`sync.nvim` asks before loading a new local config and stores trust by file
path plus file content hash. If the file changes, you will be asked again.

You can skip the prompt for your own machines:

```lua
require("sync_nvim").setup({
  local_config_trust = "always",
})
```

Or disable local configs entirely:

```lua
require("sync_nvim").setup({
  use_local_config = false,
})
```
