local M = {}
local unpack = table.unpack or unpack

local function pack(...)
  return { n = select("#", ...), ... }
end

local defaults = {
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
}

local state = {
  config = vim.deepcopy(defaults),
  commands_created = false,
  active_config = nil,
  trusted_configs = nil,
}

local function config()
  return state.active_config or state.config
end

local function trim(value)
  local trimmed = (value or ""):gsub("^%s+", ""):gsub("%s+$", "")
  return trimmed
end

local function notify(message, level)
  if config().notify then
    vim.notify(message, level or vim.log.levels.INFO, { title = "sync.nvim" })
  end
end

local function normalize_dir(path)
  local expanded = vim.fn.expand(path)

  if vim.fs and vim.fs.normalize then
    expanded = vim.fs.normalize(expanded)
  else
    expanded = vim.fn.fnamemodify(expanded, ":p")
  end

  return expanded:gsub("[/\\]$", "")
end

local function current_dir()
  return normalize_dir(vim.fn.getcwd())
end

local function home_dir()
  return normalize_dir("~")
end

local function local_config_names(base_config)
  if type(base_config.local_config_names) == "string" then
    return { base_config.local_config_names }
  end

  return base_config.local_config_names or {}
end

local function normalize_path(path)
  return normalize_dir(path)
end

local function local_config_trust_file(base_config)
  if base_config.local_config_trust_file and trim(base_config.local_config_trust_file) ~= "" then
    return vim.fn.expand(base_config.local_config_trust_file)
  end

  return vim.fn.stdpath("data") .. "/sync_nvim/trusted_configs"
end

local function local_config_hash(path)
  local ok, lines = pcall(vim.fn.readfile, path, "b")
  if not ok then
    return nil, lines
  end

  return vim.fn.sha256(table.concat(lines, "\n"))
end

local function local_config_trust_key(path)
  local hash, hash_error = local_config_hash(path)
  if not hash then
    return nil, hash_error
  end

  return hash .. " " .. normalize_path(path)
end

local function load_trusted_configs(base_config)
  if state.trusted_configs then
    return state.trusted_configs
  end

  local trusted = {}
  local trust_file = local_config_trust_file(base_config)

  if vim.fn.filereadable(trust_file) == 1 then
    for _, line in ipairs(vim.fn.readfile(trust_file)) do
      line = trim(line)
      if line ~= "" then
        trusted[line] = true
      end
    end
  end

  state.trusted_configs = trusted
  return trusted
end

local function save_trusted_configs(base_config)
  local trust_file = local_config_trust_file(base_config)
  local trust_dir = vim.fn.fnamemodify(trust_file, ":h")
  vim.fn.mkdir(trust_dir, "p")

  local lines = {}
  for key in pairs(state.trusted_configs or {}) do
    table.insert(lines, key)
  end
  table.sort(lines)

  local ok, result = pcall(vim.fn.writefile, lines, trust_file)
  if not ok then
    return false, result
  end

  if result ~= 0 then
    return false, "writefile returned " .. tostring(result)
  end

  return true
end

local function trust_local_config(path, base_config)
  local key, key_error = local_config_trust_key(path)
  if not key then
    return false, key_error
  end

  local trusted = load_trusted_configs(base_config)
  trusted[key] = true

  local ok, write_error = save_trusted_configs(base_config)
  if not ok then
    trusted[key] = nil
    return false, write_error
  end

  return true
end

local function local_config_is_trusted(path, base_config)
  local key = local_config_trust_key(path)
  if not key then
    return false
  end

  return load_trusted_configs(base_config)[key] == true
end

local function find_local_config(base_config)
  if not base_config.use_local_config then
    return nil
  end

  local cwd = current_dir()
  for _, name in ipairs(local_config_names(base_config)) do
    local path = cwd .. "/" .. name
    if vim.fn.filereadable(path) == 1 then
      return path
    end
  end

  return nil
end

local function should_load_local_config(path, base_config, opts)
  opts = opts or {}
  local trust_mode = base_config.local_config_trust or "prompt"

  if trust_mode == true or trust_mode == "always" then
    return true
  end

  if trust_mode == false or trust_mode == "never" then
    notify("Skipped local sync.nvim config: " .. path, vim.log.levels.WARN)
    return false
  end

  if local_config_is_trusted(path, base_config) then
    return true
  end

  if opts.prompt_for_trust == false then
    return false
  end

  local choice = vim.fn.confirm(
    "Trust sync.nvim local config?\n\n"
      .. path
      .. "\n\nThis Lua file can execute code.",
    "&Trust\n&Skip",
    2
  )

  if choice == 1 then
    local ok, trust_error = trust_local_config(path, base_config)
    if ok then
      notify("Trusted local sync.nvim config: " .. path)
      return true
    end

    notify("Could not trust local sync.nvim config: " .. tostring(trust_error), vim.log.levels.ERROR)
    return false
  end

  notify("Skipped untrusted local sync.nvim config: " .. path, vim.log.levels.WARN)
  return false
end

local function load_local_config(path)
  local chunk, load_error = loadfile(path)
  if not chunk then
    return nil, load_error
  end

  local ok, result = pcall(chunk)
  if not ok then
    return nil, result
  end

  if type(result) ~= "table" then
    return nil, "local config must return a table"
  end

  return result, nil
end

local function resolve_config(opts)
  local resolved = vim.deepcopy(state.config)
  local path = find_local_config(resolved)

  if not path then
    return resolved
  end

  if not should_load_local_config(path, resolved, opts) then
    return resolved
  end

  local local_config, load_error = load_local_config(path)
  if not local_config then
    if resolved.notify then
      vim.notify(
        "Could not load sync.nvim local config " .. path .. ": " .. load_error,
        vim.log.levels.ERROR,
        { title = "sync.nvim" }
      )
    end
    return resolved
  end

  resolved = vim.tbl_deep_extend("force", resolved, local_config)
  resolved.local_config_path = path
  return resolved
end

local function with_current_config(fn, opts)
  if state.active_config then
    return fn()
  end

  local previous = state.active_config
  state.active_config = resolve_config(opts)

  local results = pack(pcall(fn))
  local ok = results[1]
  state.active_config = previous

  if not ok then
    error(results[2])
  end

  return unpack(results, 2, results.n)
end

local function ssh_config_path()
  return vim.fn.expand(config().ssh_config_path)
end

local function has_glob(value)
  return value:find("*", 1, true) or value:find("?", 1, true)
end

local function parse_ssh_config(path)
  if vim.fn.filereadable(path) == 0 then
    return nil, "No SSH config file found: " .. path
  end

  local hosts = {}
  local current_hosts = {}

  for _, raw_line in ipairs(vim.fn.readfile(path)) do
    local line = trim(raw_line:gsub("#.*$", ""))

    if line ~= "" then
      local key, value = line:match("^(%S+)%s+(.+)$")
      if key and value then
        key = key:lower()
        value = trim(value)

        if key == "host" then
          current_hosts = {}

          for alias in value:gmatch("%S+") do
            if not alias:match("^!") and not has_glob(alias) then
              local host = {
                name = alias,
                host_name = alias,
              }
              table.insert(hosts, host)
              table.insert(current_hosts, host)
            end
          end
        elseif key == "hostname" then
          for _, host in ipairs(current_hosts) do
            host.host_name = value
          end
        elseif key == "user" then
          for _, host in ipairs(current_hosts) do
            host.user = value
          end
        elseif key == "port" then
          for _, host in ipairs(current_hosts) do
            host.port = value
          end
        end
      end
    end
  end

  if #hosts == 0 then
    return nil, "No concrete Host entries found in " .. path
  end

  return hosts, nil
end

local function read_hosts()
  local hosts, err = parse_ssh_config(ssh_config_path())
  if not hosts then
    notify(err, vim.log.levels.ERROR)
    return nil
  end

  return hosts
end

local function display_hosts(hosts)
  print "Remote hosts:"
  for i, host in ipairs(hosts) do
    print(i .. ". " .. host.name)
  end
end

local function choice_token(value)
  value = trim(value):gsub("%s+", "")

  if value:match("^%d+$") or value:match("^%d+%-%d+$") then
    return true
  end

  if not value:find(",", 1, true) then
    return false
  end

  for part in value:gmatch("[^,]+") do
    if not part:match("^%d+$") then
      return false
    end
  end

  return value:sub(1, 1) ~= "," and value:sub(-1) ~= ","
end

local function parse_command_args(args)
  args = trim(args)
  if args == "" then
    return "", nil
  end

  local first, rest = args:match("^(%S+)%s*(.*)$")
  if first and choice_token(first) then
    return trim(rest), first
  end

  return args, nil
end

local function valid_host_index(index, host_count)
  return index and index >= 1 and index <= host_count
end

local function parse_choice(input, host_count)
  input = trim(input)

  if input == "" then
    return nil, "Invalid choice."
  end

  local proxy, destination = input:match("^(%d+)%s*%-%s*(%d+)$")
  if proxy then
    proxy = tonumber(proxy)
    destination = tonumber(destination)

    if not valid_host_index(proxy, host_count) or not valid_host_index(destination, host_count) then
      return nil, "Invalid choice."
    end

    return {
      mode = "proxy",
      proxy = proxy,
      destination = destination,
    }
  end

  if input:find("-", 1, true) then
    return nil, "Invalid choice."
  end

  local destinations = {}
  for part in input:gmatch("[^,]+") do
    local destination_choice = tonumber(trim(part))
    if not valid_host_index(destination_choice, host_count) then
      return nil, "Invalid choice."
    end

    table.insert(destinations, destination_choice)
  end

  if #destinations == 0 then
    return nil, "Invalid choice."
  end

  return {
    mode = "direct",
    destinations = destinations,
  }
end

local function relative_to_home(path)
  local home = home_dir()

  if path == home then
    return ""
  end

  local prefix = home .. "/"
  if path:sub(1, #prefix) == prefix then
    return path:sub(#prefix + 1)
  end

  return nil
end

local function host_config(host)
  local overrides = config().hosts or {}
  local host_override = overrides[host.name] or overrides[host.host_name] or {}

  if type(host_override) ~= "table" then
    return config()
  end

  return vim.tbl_deep_extend("force", config(), host_override)
end

local function remote_path_parts(host_cfg)
  host_cfg = host_cfg or config()

  local explicit = trim(host_cfg.remote_dir)
  if explicit ~= "" then
    explicit = explicit:gsub("[/\\]$", "")

    if explicit == "~" then
      return "~", "."
    end

    local home_relative = explicit:match("^~/(.+)$")
    if home_relative then
      return "~", home_relative
    end

    return nil, explicit
  end

  local relative = relative_to_home(current_dir())
  if not relative then
    relative = vim.fn.fnamemodify(current_dir(), ":t")
  end

  local remote_home = trim(host_cfg.remote_home)
  if remote_home == "" then
    remote_home = "~"
  end

  remote_home = remote_home:gsub("[/\\]$", "")
  relative = relative:gsub("\\", "/"):gsub("^/", "")

  if relative == "" then
    return remote_home, "."
  end

  return remote_home, relative
end

local function remote_sync_dir(host_cfg)
  local base, path = remote_path_parts(host_cfg)

  if not base or base == "" then
    return path
  end

  if path == "." then
    return base
  end

  return base:gsub("[/\\]$", "") .. "/" .. path:gsub("^/", "")
end

local function remote_cd_command(base)
  if not base or base == "" then
    return nil
  end

  if base == "~" then
    return "cd ~"
  end

  return "cd " .. vim.fn.shellescape(base)
end

local function ensure_trailing_slash(path)
  return path:gsub("[/\\]?$", "/")
end

local function shell_join(parts)
  local out = {}
  for _, part in ipairs(parts) do
    if part and part ~= "" then
      table.insert(out, part)
    end
  end
  return table.concat(out, " ")
end

local function exclude_args(host_cfg)
  host_cfg = host_cfg or config()

  if type(host_cfg.exclude) == "string" and trim(host_cfg.exclude) ~= "" then
    return trim(host_cfg.exclude)
  end

  local excludes = host_cfg.excludes
  if type(excludes) == "string" then
    return trim(excludes)
  end

  if type(excludes) ~= "table" then
    return ""
  end

  local parts = {}
  for _, pattern in ipairs(excludes) do
    table.insert(parts, "--exclude=" .. vim.fn.shellescape(pattern))
  end

  return table.concat(parts, " ")
end

local function rsync_flags(extra_args, host_cfg)
  host_cfg = host_cfg or config()

  return shell_join({
    host_cfg.rsync or config().rsync,
    table.concat(host_cfg.rsync_args or {}, " "),
    trim(extra_args),
    exclude_args(host_cfg),
  })
end

local function timeout_arg(host_cfg)
  local timeout = tonumber((host_cfg or config()).timeout)

  if not timeout or timeout <= 0 then
    return nil
  end

  return "--timeout=" .. tostring(timeout)
end

local function direct_target(host)
  return host.name
end

local function raw_target(host)
  local target = host.host_name or host.name

  if host.user and host.user ~= "" then
    target = host.user .. "@" .. target
  end

  return target
end

local function remote_shell_arg(host)
  if not host.port or host.port == "" then
    return nil
  end

  return "-e " .. vim.fn.shellescape("ssh -p " .. host.port)
end

local function build_direct_command(host, extra_args)
  local host_cfg = host_config(host)
  local source = current_dir() .. "/"
  local destination = direct_target(host) .. ":" .. ensure_trailing_slash(remote_sync_dir(host_cfg))

  return shell_join({
    rsync_flags(extra_args, host_cfg),
    vim.fn.shellescape(source),
    vim.fn.shellescape(destination),
    timeout_arg(host_cfg),
  }),
    source,
    destination
end

local function build_proxy_command(proxy, destination_host, extra_args)
  local proxy_cfg = host_config(proxy)
  local destination_cfg = host_config(destination_host)
  local source_base, source_path = remote_path_parts(proxy_cfg)
  local source = ensure_trailing_slash(source_path)
  local destination = raw_target(destination_host) .. ":" .. ensure_trailing_slash(remote_sync_dir(destination_cfg))

  local remote_rsync_command = shell_join({
    remote_cd_command(source_base),
    source_base and "&&" or nil,
    rsync_flags(extra_args, destination_cfg),
    remote_shell_arg(destination_host),
    vim.fn.shellescape(source),
    vim.fn.shellescape(destination),
    timeout_arg(destination_cfg),
  })

  return shell_join({
    config().ssh,
    vim.fn.shellescape(proxy.name),
    vim.fn.shellescape(remote_rsync_command),
  }),
    source,
    destination
end

local function run_shell_command(command)
  local ok, command_error = pcall(vim.cmd, "!" .. command)
  if not ok then
    notify("Sync command failed: " .. tostring(command_error), vim.log.levels.ERROR)
    return false, command_error
  end

  local exit_code = vim.v.shell_error
  if exit_code ~= 0 then
    notify("Sync command failed with exit code " .. exit_code, vim.log.levels.ERROR)
    return false, exit_code
  end

  return true, 0
end

local function build_plan_from_selection(hosts, selection, extra_args)
  local commands = {}

  if selection.mode == "proxy" then
    local proxy_host = hosts[selection.proxy]
    local direct_command, direct_source, direct_destination = build_direct_command(proxy_host, extra_args or "")
    table.insert(commands, {
      command = direct_command,
      source = direct_source,
      destination = direct_destination,
    })

    local proxy_command, proxy_source, proxy_destination =
      build_proxy_command(proxy_host, hosts[selection.destination], extra_args or "")
    table.insert(commands, {
      command = proxy_command,
      source = proxy_source,
      destination = proxy_destination,
    })

    return commands
  end

  for _, destination_choice in ipairs(selection.destinations) do
    local direct_command, direct_source, direct_destination =
      build_direct_command(hosts[destination_choice], extra_args or "")
    table.insert(commands, {
      command = direct_command,
      source = direct_source,
      destination = direct_destination,
    })
  end

  return commands
end

local function build_plan_from_choice(hosts, choice, extra_args)
  local selection, choice_error = parse_choice(choice, #hosts)
  if choice_error then
    return nil, choice_error
  end

  return build_plan_from_selection(hosts, selection, extra_args), nil, selection
end

local function print_plan(commands)
  print "sync.nvim dry run:"
  for index, item in ipairs(commands) do
    print(index .. ". " .. item.command)
  end
end

local function sync_with_choice(hosts, choice, extra_args)
  local commands, choice_error, selection = build_plan_from_choice(hosts, choice, extra_args)
  if choice_error then
    notify(choice_error, vim.log.levels.ERROR)
    return false
  end

  if selection.mode == "proxy" then
    print "sync with proxy"

    for _, item in ipairs(commands) do
      local ok = run_shell_command(item.command)
      if not ok then
        print("sync from " .. item.source .. " to " .. item.destination .. " failed.")
        return false
      end

      print("sync from " .. item.source .. " to " .. item.destination .. " complete.")
    end

    return true
  end

  if #selection.destinations > 1 then
    print "sync directly to dest hosts"
  else
    print "sync directly to dest host"
  end

  for _, item in ipairs(commands) do
    local ok = run_shell_command(item.command)
    if not ok then
      print("sync from " .. item.source .. " to " .. item.destination .. " failed.")
      return false
    end

    print("sync from " .. item.source .. " to " .. item.destination .. " complete.")
  end

  return true
end

local function sync(extra_args, choice)
  return with_current_config(function()
    local hosts = read_hosts()
    if not hosts then
      return false
    end

    display_hosts(hosts)

    choice = choice or vim.fn.input "Enter your choice(dest, dest,dest, or proxy-dest): "
    return sync_with_choice(hosts, choice, extra_args)
  end)
end

local function dry_run(extra_args, choice)
  return with_current_config(function()
    local hosts = read_hosts()
    if not hosts then
      return false
    end

    display_hosts(hosts)

    choice = choice or vim.fn.input "Enter your choice(dest, dest,dest, or proxy-dest): "
    local commands, choice_error = build_plan_from_choice(hosts, choice, extra_args)
    if choice_error then
      notify(choice_error, vim.log.levels.ERROR)
      return false
    end

    print_plan(commands)
    return true
  end)
end

local function edit_config()
  vim.cmd.edit(vim.fn.fnameescape(ssh_config_path()))
end

local function set_global_sync()
  _G.Sync = function(extra_args)
    return M.sync(extra_args or "")
  end
end

local function set_legacy_module()
  package.loaded["sync.sync"] = {
    Sync = function(extra_args)
      return M.sync(extra_args or "")
    end,
  }
end

function M.setup(opts)
  state.config = vim.tbl_deep_extend("force", state.config, opts or {})
  state.trusted_configs = nil

  set_global_sync()
  set_legacy_module()
  vim.schedule(set_global_sync)

  if state.commands_created then
    return
  end

  state.commands_created = true

  vim.api.nvim_create_user_command("SyncNvim", function(opts_)
    local extra_args, choice = parse_command_args(opts_.args)
    M.sync(extra_args, choice)
  end, { nargs = "*" })

  vim.api.nvim_create_user_command("SyncNvimDelete", function(opts_)
    local extra_args, choice = parse_command_args(opts_.args)
    M.sync(shell_join({ "--delete", extra_args }), choice)
  end, { nargs = "*" })

  vim.api.nvim_create_user_command("SyncNvimDryRun", function(opts_)
    local extra_args, choice = parse_command_args(opts_.args)
    M.dry_run(extra_args, choice)
  end, { nargs = "*" })

  vim.api.nvim_create_user_command("SyncNvimPlan", function(opts_)
    local extra_args, choice = parse_command_args(opts_.args)
    M.dry_run(extra_args, choice)
  end, { nargs = "*" })

  vim.api.nvim_create_user_command("SyncNvimHosts", function()
    M.hosts()
  end, {})

  vim.api.nvim_create_user_command("SyncNvimConfig", function()
    M.edit_config()
  end, {})

  vim.api.nvim_create_user_command("SyncNvimTrust", function()
    M.trust()
  end, {})
end

function M.hosts()
  return with_current_config(function()
    local hosts = read_hosts()
    if not hosts then
      return false
    end

    display_hosts(hosts)
    return true
  end, { prompt_for_trust = false })
end

function M.edit_config()
  return with_current_config(function()
    edit_config()
    return true
  end, { prompt_for_trust = false })
end

function M.sync(extra_args, choice)
  return sync(extra_args or "", choice)
end

function M.dry_run(extra_args, choice)
  return dry_run(extra_args or "", choice)
end

function M.trust()
  local path = find_local_config(state.config)
  if not path then
    notify "No local sync.nvim config found in the current directory."
    return false
  end

  local ok, trust_error = trust_local_config(path, state.config)
  if not ok then
    notify("Could not trust local sync.nvim config: " .. tostring(trust_error), vim.log.levels.ERROR)
    return false
  end

  notify("Trusted local sync.nvim config: " .. path)
  return true
end

function M.read_hosts()
  return with_current_config(read_hosts)
end

function M.build_plan(choice, extra_args)
  return with_current_config(function()
    local hosts = read_hosts()
    if not hosts then
      return nil
    end

    local commands, choice_error = build_plan_from_choice(hosts, choice, extra_args or "")
    if choice_error then
      return nil, choice_error
    end

    return commands
  end)
end

return M
