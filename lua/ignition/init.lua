local M = {}

-- Required modules
local Job = require("plenary.job")
local notify = require("notify")
local telescope = require("telescope.pickers")
local finders = require("telescope.finders")
local conf = require("telescope.config").values
local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")
local themes = require("telescope.themes")
local handle = require("fidget.progress.handle")


-- Run a command using plenary.job, stream output to fidget, then update with notify.
local function run_command_with_popup(cmd, cwd, title)
  local raw_args = vim.list_slice(cmd, 2)
  local args = {}
  for _, a in ipairs(raw_args) do
    for _, part in ipairs(vim.split(a, "%s+")) do
      table.insert(args, part)
    end
  end
  local command = cmd[1]
  local full_command = command .. " " .. table.concat(args, " ")
  local output_lines = {}
  local h = handle.create({
    title = title,
    message = "Starting...",
  })

  Job:new({
    command = command,
    args = args,
    cwd = cwd,
    enable_recording = false,
    on_stdout = function(_, line)
      if line and line ~= "" then
        table.insert(output_lines, line)
        vim.schedule(function()
          h:report({ message = line })
        end)
      end
    end,
    on_stderr = function(_, line)
      if line and line ~= "" then
        table.insert(output_lines, "[stderr] " .. line)
        vim.schedule(function()
          h:report({ message = "[stderr] " .. line })
        end)
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        local tail_lines = {}
        local count = #output_lines
        local start = math.max(1, count - 9)
        for i = start, count do
          table.insert(tail_lines, output_lines[i])
        end
        local final_output = table.concat(tail_lines, "\n")
        if code == 0 then
          h:finish({ message = "Build complete!" })
          notify("Build succeeded: " .. full_command, vim.log.levels.INFO, {
            title = "Build Complete",
            timeout = 2000,
          })
        else
          h:finish({ message = "Build failed with code " .. code })
          notify("Build failed: " .. full_command .. "\n\n" .. final_output, vim.log.levels.ERROR, {
            title = "Build Failed",
            timeout = 5000,
          })
        end
      end)
    end,
  }):start()
end

-- Default build target entries.
-- (Users can override these via the setup options.)
M.config = {
  targets = {
  },
}

-- Telescope picker for selecting build targets.
function M.select_build_target()
  local targets = M.config.targets or {}
  local function get_enabled_targets()
    local enabled = {}
    for _, entry in ipairs(targets) do
      local is_enabled
      if type(entry.enabled) == "function" then
        is_enabled = entry.enabled()
      else
        is_enabled = entry.enabled
      end
      if is_enabled then
        table.insert(enabled, entry)
      end
    end
    return enabled
  end

  telescope.new(themes.get_dropdown({
    prompt_title = "Select Build Target",
    finder = finders.new_table {
      results = get_enabled_targets(),
      entry_maker = function(entry)
        return {
          value = entry.value,
          display = entry.display,
          ordinal = entry.display,
        }
      end,
    },
    sorter = conf.generic_sorter(),
    attach_mappings = function(prompt_bufnr, map)
      actions.select_default:replace(function()
        actions.close(prompt_bufnr)
        local selection = action_state.get_selected_entry()
        local val = selection.value
        local resolved_args = type(val.args) == "function" and val.args() or val.args
        local resolved_cwd = type(val.cwd) == "function" and val.cwd() or val.cwd
        run_command_with_popup({ val.command, unpack(resolved_args) }, resolved_cwd, selection.display)
      end)
      return true
    end,
  })):find()
end

-- Setup function for the plugin.
function M.setup(user_opts)
  M.config = vim.tbl_deep_extend("force", M.config, user_opts or {})
end

return M
