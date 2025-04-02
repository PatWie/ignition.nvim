# 🔥 ignition.nvim

A minimal command launcher for Neovim with Telescope, Fidget, and nvim-notify integration.

ignition.nvim lets you define and run custom commands — such as builds, tests,
linters, formatters, or anything else — from a user-friendly Telescope picker.
It streams live output to a Fidget status window and shows a final summary via
nvim-notify.

- Flexible command picker with Telescope
- Live output streaming via Fidget for real-time feedback
- Success/failure notifications powered by nvim-notify
- Dynamic arguments and cwd — supports extracting context from the open file (e.g. Zig exercises, language workspaces)
- Per-project or per-language targets — define your own command sets
- Built-in support for Rust, Go, Zig, Brazil, and more

### 🚀 Installation (with lazy.nvim)
```lua

return {
  dir = "patwie/ignition.nvim",
  dependencies = {
    "nvim-lua/plenary.nvim",
    "rcarriga/nvim-notify",
    "j-hui/fidget.nvim",
  },
  config = function()
    local function find_project_root(marker)
      local path = vim.fn.expand("%:p")
      local dir = vim.loop.fs_realpath(vim.fn.fnamemodify(path, ":h"))
      while dir do
        if vim.fn.filereadable(dir .. "/" .. marker) == 1 then return dir end
        local parent = vim.fn.fnamemodify(dir, ":h")
        if parent == dir then break end
        dir = parent
      end
      return nil
    end

    require("ignition").setup({
      targets = {
        {
          display = "cargo build --release",
          value = {
            command = "cargo",
            args = { "build", "--release" },
            cwd = function()
              return find_project_root("Cargo.toml")
            end,
          },
          enabled = (find_project_root("Cargo.toml") ~= nil),
        },
        {
          display = "cargo test",
          value = {
            command = "cargo",
            args = { "test" },
            cwd = function() return find_project_root("Cargo.toml") end,
          },
          enabled = (find_project_root("Cargo.toml") ~= nil),
        },
        {
          display = "make",
          value = {
            command = "make",
            args = {}, -- default target
            cwd = function() return find_project_root("Makefile") end,
          },
          enabled = (find_project_root("Makefile") ~= nil),
        },
        {
          display = "npm run build",
          value = {
            command = "npm",
            args = { "run", "build" },
            cwd = function() return find_project_root("package.json") end,
          },
          enabled = (find_project_root("package.json") ~= nil),
        },
        {
          display = "go build",
          value = {
            command = "go",
            args = { "build" },
            cwd = function()
              return find_project_root("go.mod")
            end,
          },
          enabled = (find_project_root("go.mod") ~= nil),
        },
        {
          display = "zig exercise build",
          value = {
            command = "zig",
            -- 'args' is a function so we can extract the exercise number from the current file
            args = function()
              local filename = vim.fn.expand("%:t") -- e.g. "004_arrays.zig"
              -- Extract a leading number (the exercise number)
              local exercise = filename:match("^(%d+)")
              if exercise then
                return { "build", "-Dn=" .. exercise }
              else
                return { "build" }
              end
            end,
            cwd = function()
              -- Look up from the current file until the "exercises" folder is found.
              local path = vim.fn.expand("%:p")
              local exercises_dir = path:match("(.+/exercises)")
              if exercises_dir then
                return exercises_dir
              end
              return vim.fn.getcwd()
            end,
          },
          enabled = function()
            -- Enable only if a build.zig file is found from the current file upward.
            return find_project_root("build.zig") ~= nil
          end,
        }
      },
    })
    vim.keymap.set("n", "<leader>b", require("ignition").select_build_target, { desc = "Select and Build Target" })
  end,
}

