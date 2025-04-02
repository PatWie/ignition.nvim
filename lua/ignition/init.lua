local M = {}

-- Required modules
local Job = require("plenary.job")
local notify = require("notify")
local telescope_pickers = require("telescope.pickers")
local finders = require("telescope.finders")
local conf = require("telescope.config").values
local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")
local themes = require("telescope.themes")
local handle = require("fidget.progress.handle")
local deepcopy = vim.deepcopy -- Utility for config handling

-- --- Default Configuration ---
-- Users can override these values in their setup() call.
M.default_config = {
  -- Build targets definition. MUST be provided by the user.
  targets = {},

  -- Options for the command runner
  runner = {
    -- Number of output lines to show in the failure notification
    tail_lines = 10,
  },

  -- Options for notifications (using nvim-notify)
  notifications = {
    success_title = "Build Complete",
    error_title = "Build Failed",
    success_timeout = 1000, -- Milliseconds
    error_timeout = 7000,   -- Milliseconds
    info_level = vim.log.levels.INFO,
    error_level = vim.log.levels.ERROR,
  },

  -- Options for progress display (using fidget.nvim)
  fidget = {
    -- Prefix added to the target's display name for the Fidget title
    title_prefix = "Build: ",
    start_message = "Starting...",
    success_message = "Build finished successfully!",
    -- %s will be replaced with the exit code in the error message
    error_message_template = "Build failed with code %s",
  },

  -- Options for the Telescope picker
  telescope = {
    -- Options passed directly to themes.get_dropdown() or your chosen theme
    theme_opts = {
      -- Example: theme_opts = { layout_config = { width = 0.6, height = 0.4 } }
    },
    prompt_title = "Select Build Target",
    -- You could add options for sorter, entry_maker customization here if needed
  },
}

-- Active configuration, initialized with defaults
M.config = deepcopy(M.default_config)

-- --- Core Functions ---

---@class BuildTargetValue
---@field command string The main command to execute.
---@field args string[]|fun():string[] Arguments for the command. Can be a list of strings or a function returning a list.
---@field cwd string|fun():string The working directory for the command. Can be a string or a function returning a string.

---@class BuildTargetEntry
---@field display string Name shown in the Telescope picker.
---@field value BuildTargetValue The actual command details.
---@field enabled boolean|fun():boolean Whether the target is currently available. Can be a boolean or a function returning a boolean.

--- Internal function to run a command with progress and notifications.
--- Relies on M.config for messages, timeouts, etc.
--- @param cmd_list table List where the first element is the command and subsequent elements are arguments. e.g., {"make", "all", "-j", "8"}
--- @param cwd string The current working directory for the job.
--- @param title string The title for the Fidget handle and notifications (usually the target's display name).
local function run_command_with_popup(cmd_list, cwd, title)
  local cfg = M.config -- Use active config

  -- Separate command and args
  local command = cmd_list[1]
  local args = vim.list_slice(cmd_list, 2) or {} -- Ensure args is a table even if empty

  -- Note: plenary.job handles argument quoting correctly if passed as a list.
  -- The previous splitting logic is removed as it might incorrectly split args with spaces.
  -- If an arg needs splitting (e.g., "-j 8"), it should be passed as {"-j", "8"} in the target definition.
  -- Or handle it in a dynamic args function.

  local full_command = command .. " " .. table.concat(args, " ")
  local output_lines = {}

  -- Create Fidget handle using configured prefix and start message
  local h = handle.create({
    title = cfg.fidget.title_prefix .. title,
    message = cfg.fidget.start_message,
  })

  Job:new({
    command = command,
    args = args,
    cwd = cwd,
    enable_recording = false, -- Keep false unless you need the full output later for something else
    on_stdout = function(_, line)
      if line and line ~= "" then
        table.insert(output_lines, line)
        -- Update Fidget with the latest line (scheduled to run on main thread)
        vim.schedule(function()
          h:report({ message = line })
        end)
      end
    end,
    on_stderr = function(_, line)
      if line and line ~= "" then
        -- Prepend [stderr] for clarity
        local err_line = "[stderr] " .. line
        table.insert(output_lines, err_line)
        vim.schedule(function()
          h:report({ message = err_line })
        end)
      end
    end,
    on_exit = function(_, code)
      -- Schedule final notification and Fidget update
      vim.schedule(function()
        if code == 0 then
          -- Success
          h:finish({ message = cfg.fidget.success_message })
          notify(
            "Success: " .. full_command,
            cfg.notifications.info_level,
            {
              title = cfg.notifications.success_title,
              timeout = cfg.notifications.success_timeout,
            }
          )
        else
          -- Failure
          -- Get tail N lines from output for the notification
          local tail_lines = {}
          local count = #output_lines
          local start = math.max(1, count - cfg.runner.tail_lines + 1) -- Calculate start index for tail
          for i = start, count do
            table.insert(tail_lines, output_lines[i])
          end
          local final_output = table.concat(tail_lines, "\n")

          local error_message = string.format(cfg.fidget.error_message_template, code)
          h:finish({ message = error_message })

          notify(
            "Failed: " .. full_command .. "\n\nOutput Tail:\n" .. final_output,
            cfg.notifications.error_level,
            {
              title = cfg.notifications.error_title,
              timeout = cfg.notifications.error_timeout,
            }
          )
        end
      end)
    end,
  }):start()
end


--- Opens a Telescope picker to select and run a build target.
function M.select_build_target()
  local cfg = M.config
  local targets = cfg.targets or {} -- Use configured targets

  -- Helper to filter targets based on their 'enabled' status
  local function get_enabled_targets()
    local enabled = {}
    for _, entry in ipairs(targets) do
      local is_enabled = true -- Default to enabled if key is missing
      if entry.enabled ~= nil then
        if type(entry.enabled) == "function" then
          is_enabled = entry.enabled() -- Call function if it's a function
        else
          is_enabled = entry.enabled   -- Use boolean value directly
        end
      end

      if is_enabled then
        table.insert(enabled, entry)
      end
    end
    return enabled
  end

  local enabled_targets = get_enabled_targets()

  if vim.tbl_isempty(enabled_targets) then
    notify("No build targets available or enabled.", vim.log.levels.WARN, { title = "Build Plugin" })
    return
  end

  -- Create and open the Telescope picker
  telescope_pickers.new(themes.get_dropdown(cfg.telescope.theme_opts or {}), {
    -- Use configured prompt title
    prompt_title = cfg.telescope.prompt_title,
    finder = finders.new_table {
      results = enabled_targets,
      -- Simple entry maker, assuming 'display' and 'value' exist
      entry_maker = function(entry)
        return {
          value = entry.value,     -- Store the command details
          display = entry.display, -- Show the name
          ordinal = entry.display, -- Used for sorting
        }
      end,
    },
    -- Use Telescope's default sorter (usually fzf or similar)
    sorter = conf.generic_sorter(),
    attach_mappings = function(prompt_bufnr, map)
      actions.select_default:replace(function()
        actions.close(prompt_bufnr)      -- Close the picker first
        local selection = action_state.get_selected_entry()
        if not selection then return end -- Exit if no selection somehow

        local val = selection.value      -- This is the BuildTargetValue table
        local display_name = selection.display

        -- Resolve command, args, and cwd (handling functions if provided)
        local command = val.command
        local resolved_args = type(val.args) == "function" and val.args() or val.args
        local resolved_cwd = type(val.cwd) == "function" and val.cwd() or val.cwd or
        vim.fn.getcwd()                                                                              -- Default to cwd if not specified

        -- Construct the command list for run_command_with_popup
        local cmd_list = { command }
        if resolved_args then
          for _, arg in ipairs(resolved_args) do
            table.insert(cmd_list, arg)
          end
        end

        -- Run the command
        run_command_with_popup(cmd_list, resolved_cwd, display_name)
      end)
      return true -- Mappings attached
    end,
  }):find()       -- Open the picker
end

-- --- Setup Function ---

--- Configures the build plugin.
--- Merges user options deeply with the default configuration.
--- @param user_opts table|nil User configuration options.
function M.setup(user_opts)
  -- Deeply merge user options into the default config
  -- The 'force' mode ensures tables within tables are merged, not just replaced.
  M.config = vim.tbl_deep_extend("force", deepcopy(M.default_config), user_opts or {})

  -- Optional: Add validation here
  -- e.g., check if required plugins like notify, fidget, telescope are available
  -- local ok_notify, _ = pcall(require, "notify")
  -- if not ok_notify then vim.notify("Build plugin requires nvim-notify", vim.log.levels.ERROR) end
  -- ... similar checks for fidget, telescope, plenary ...

  -- e.g., Check if user actually provided targets
  if not user_opts or not user_opts.targets or vim.tbl_isempty(user_opts.targets) then
    vim.notify("Build plugin: No 'targets' provided in setup()", vim.log.levels.WARN)
  end
end

return M
