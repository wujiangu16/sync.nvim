local sync = require("sync_nvim")

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or "assertion failed") .. "\nexpected: " .. vim.inspect(expected) .. "\nactual: " .. vim.inspect(actual))
  end
end

local function assert_contains(value, needle, message)
  if not value:find(needle, 1, true) then
    error((message or "expected string to contain value") .. "\nneedle: " .. needle .. "\nvalue: " .. value)
  end
end

local function assert_not_contains(value, needle, message)
  if value:find(needle, 1, true) then
    error((message or "expected string not to contain value") .. "\nneedle: " .. needle .. "\nvalue: " .. value)
  end
end

local root = vim.fn.getcwd()
local temp = vim.fn.tempname()
vim.fn.mkdir(temp, "p")
local project = temp .. "/project"
vim.fn.mkdir(project, "p")

local ssh_config = temp .. "/ssh_config"
vim.fn.writefile({
  "Host alpha",
  "  HostName 10.0.0.1",
  "  User user_a",
  "",
  "Host beta",
  "  HostName 10.0.0.2",
  "  User user_b",
  "  Port 2222",
}, ssh_config)

vim.fn.writefile({
  "return {",
  "  timeout = 120,",
  "  remote_dir = '~/scratch/root',",
  "  excludes = { '*.swp', '.git' },",
  "  hosts = {",
  "    beta = {",
  "      timeout = 0,",
  "      remote_dir = '~/scratch/beta',",
  "      excludes = { 'node_modules' },",
  "    },",
  "  },",
  "}",
}, project .. "/.sync_nvim.lua")

vim.cmd("cd " .. vim.fn.fnameescape(project))

sync.setup({
  ssh_config_path = ssh_config,
  local_config_trust = "always",
  timeout = 0,
  excludes = { "*.swp" },
})

local hosts = sync.read_hosts()
assert_eq(#hosts, 2, "reads concrete ssh hosts")
assert_eq(hosts[1].name, "alpha", "keeps first host alias")
assert_eq(hosts[2].port, "2222", "reads host port")

local direct_plan = sync.build_plan("1,2")
assert_eq(#direct_plan, 2, "builds two direct commands")
assert_eq(direct_plan[1].destination, "alpha:~/scratch/root/", "uses local config remote_dir")
assert_contains(direct_plan[1].command, "--timeout=120", "uses local config timeout")
assert_contains(direct_plan[1].command, "--exclude='.git'", "uses local config excludes")

assert_eq(direct_plan[2].destination, "beta:~/scratch/beta/", "uses per-host remote_dir")
assert_not_contains(direct_plan[2].command, "--timeout=", "per-host timeout=0 disables timeout")
assert_contains(direct_plan[2].command, "--exclude='node_modules'", "uses per-host excludes")

local proxy_plan = sync.build_plan("1-2")
assert_eq(#proxy_plan, 2, "proxy sync has two steps")
assert_eq(proxy_plan[1].destination, "alpha:~/scratch/root/", "proxy first step syncs local to proxy")
assert_contains(proxy_plan[2].command, "ssh 'alpha'", "proxy second step runs through proxy")
assert_contains(proxy_plan[2].command, "user_b@10.0.0.2:~/scratch/beta/", "proxy second step targets destination")
assert_contains(proxy_plan[2].command, "ssh -p 2222", "proxy second step preserves destination port")

vim.cmd("SyncNvimDryRun 1")
vim.cmd("SyncNvimPlan 1-2")

sync.setup({
  local_config_trust = "prompt",
  local_config_trust_file = temp .. "/trusted_configs",
})
vim.cmd("SyncNvimHosts")

vim.cmd("cd " .. vim.fn.fnameescape(root))
vim.fn.delete(temp, "rf")
print("sync.nvim headless tests passed")
