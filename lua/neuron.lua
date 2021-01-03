local Job = require("plenary/job")
local uv = vim.loop
local pickers = require('telescope.pickers')
local api = vim.api
local finders = require('telescope.finders')
local previewers = require('telescope.previewers')
local conf = require('telescope.config').values
local actions = require('telescope.actions')
local utils = require("neuron/utils")
local cmd = require("neuron/cmd")

local M = {}

local ns

function M.rib(opts)
  assert(not NeuronJob, "you already started a neuron server")

  opts = opts or {}
  opts.address = opts.address or "127.0.0.1:8080"

  NeuronJob = Job:new {
    command = "neuron",
    cwd = vim.g.neuron_directory or "~/neuron",
    args = {"rib", "-w", "-s", opts.address},
    on_stderr = utils.on_stderr_factory("neuron rib"),
  }
  NeuronJob.address = opts.address
  NeuronJob:start()

  vim.cmd [[augroup NeuronJobStop]]
  vim.cmd [[au!]]
  vim.cmd [[au VimLeave * lua require'neuron'.stop()]]
  vim.cmd [[augroup END]]

  if opts.verbose then
    print("Started neuron server at", opts.address)
  end
end

function M.stop()
  if NeuronJob ~= nil then
    uv.kill(NeuronJob.pid, 15) -- sigterm
    NeuronJob = nil
  end
end

function M.open(opts)
  opts = opts or {}

  Job:new {
    command = "neuron",
    args = {"open"},
    cwd = vim.g.neuron_directory or "~/neuron",
    on_stderr = utils.on_stderr_factory("neuron open"),
    on_exit = utils.on_exit_factory("neuron open"),
  }:start()
end

function M.new(opts)
  opts = opts or {}

  Job:new {
    command = "neuron",
    args = {"new"},
    cwd = M.config.neuron_dir,
    on_stderr = utils.on_stderr_factory("neuron new"),
    on_stdout = vim.schedule_wrap(function(error, data)
      assert(not error, error)

      vim.cmd("edit " .. data)
      utils.feedkeys("Go<CR>#<space>", 'n')
    end),
    on_exit = utils.on_exit_factory("neuron new"),
  }:start()
end

local function gen_from_zettels(entry)
  local value = string.format("%s/%s", M.config.neuron_dir, entry.zettelPath)
  local display = entry.zettelTitle
  return {
    display = display,
    value = value,
    ordinal = display
  }
end

--- Backlinks or uplinks
local function gen_from_links(entry)
  local not_folgezettal = entry[2]
  return gen_from_zettels(not_folgezettal)
end

local function _find_zettels(opts)
  opts = opts or {}

  local json = vim.fn.json_decode(opts.json).result
  local entry_maker = gen_from_zettels

  pickers.new(opts, {
    prompt_title = 'Find Zettels',
    finder = finders.new_table {
      results = json,
      entry_maker = opts.entry_maker or entry_maker,
    },
    previewer = opts.previewer or previewers.vim_buffer_cat.new(opts),
    sorter = conf.generic_sorter(opts),
  }):find()
end

function M.get_current_id()
  local path = vim.fn.expand("%:t")
  return path:sub(1, -4)
end

function M.find_zettels(opts)
  opts = opts or {}

  Job:new {
    command = "neuron",
    args = {"query", "--cached"},
    cwd = opts.cwd or M.config.neuron_dir,
    on_stderr = utils.on_stderr_factory("neuron query"),
    on_stdout = vim.schedule_wrap(function(error, data)
      assert(not error, error)

      _find_zettels {json = data}
    end)
  }:start()
end

function M.find_links(opts)
  opts = opts or {}

  local args = {"query"}

  opts.back = opts.back or true
  if opts.back then
    table.insert(args, "--backlinks-of")
  else
    table.insert(args, "--uplinks-of")
  end

  table.insert(args, opts.id or M.get_current_id())

  if opts.cached ~= false then
    table.insert(args, "--cached")
  end

  Job:new {
    command = "neuron",
    -- args = {"query", "--backlinks-of", opts.id or M.get_current_id(), "--cached"},
    args = args,
    cwd = opts.cwd or M.config.neuron_dir,
    on_stderr = utils.on_stderr_factory("neuron query --backlinks-of"),
    on_stdout = vim.schedule_wrap(function(error, data)
      assert(not error, error)

      _find_zettels {
        json = data,
        entry_maker = gen_from_links
      }
    end)
  }:start()
end

function M.enter_link()
  local word = vim.fn.expand("<cWORD>")

  local id = utils.match_link(word)

  if id == nil then
    error("There is no link under the cursor")
  end

  cmd.query_id(id, M.config.neuron_dir, function(json)
    vim.cmd("edit " .. json.result.zettelPath)
  end)
end

function M.add_all_virtual_titles(buf)
  for ln, line in ipairs(api.nvim_buf_get_lines(buf, 0, -1, true)) do
    M.add_virtual_title_current_line(buf, ln, line)
  end
end

function M.add_virtual_title_current_line(buf, ln, line)
  if line ~= nil or line ~= "" then
    local start_col, end_col = utils.match_link_idx(line)
    local id = utils.match_link(line)
    if id ~= nil then
      cmd.query_id(id, M.config.neuron_dir, function(json)
        if json == nil then
          return
        end

        if json.error then
          return
        end

        local title = json.result.zettelTitle
        -- lua is one indexed
        -- api.nvim_buf_set_virtual_text(buf, ns, ln - 1, {{title, "TabLineFill"}}, {})
        api.nvim_buf_set_extmark(buf, ns, ln - 1, start_col - 1, {
            end_col = end_col - 1,
            virt_text = {{title, "TabLineFill"}},
          })
      end)
    else
      -- need because the user might do `norm! x` from a valid link
      -- the link then becomes invalid so we need to remove it
      utils.delete_range_extmark(buf, ns, ln - 1, ln) -- minus one to convert from 1 based index to api zero based index

      -- this also should work
      -- api.nvim_buf_clear_namespace(buf, ns, ln - 1, ln)
    end
  end
end

function M.update_virtual_titles(buf)
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  M.add_all_virtual_titles()
end

do
  local function on_lines(params)
    -- local params = {...}
    local buf = params[2]
    -- local changedtick = params[3]
    local firstline = params[4]
    -- local lastline = params[5]
    local new_lastline = params[6]

    local lines = api.nvim_buf_get_lines(buf, firstline, new_lastline, false)

    if #lines == 0 then
      utils.delete_range_extmark(buf, ns, firstline, new_lastline)
      -- local extmarks = api.nvim_buf_get_extmarks(0, ns, {firstline, 0}, {new_lastline, 0}, {})
      -- for _, v in ipairs(extmarks) do
      --   api.nvim_buf_del_extmark(buf, ns, v[1])
      -- end
    else
      for i = firstline, new_lastline - 1 do -- minus one because in lua loop range is inclusive
        M.add_virtual_title_current_line(buf, i + 1, lines[i - firstline + 1])
      end
    end
  end

  local task

  function M.attach_buffer_fast()
    api.nvim_buf_attach(0, true, {
        on_lines = vim.schedule_wrap(function(...)
          local empty = task == nil

          task = {...}

          if empty then
            vim.defer_fn(function()
              on_lines(task)
              task = nil
            end, 150)
          end
        end)
      })
  end
end

do
  local lock = false

  function M.attach_buffer()
    api.nvim_buf_attach(0, true, {
        on_lines = vim.schedule_wrap(function(...)
          local params = {...}

          if lock == false then
            vim.defer_fn(function()
              M.update_virtual_titles(params[2])

              -- done
              lock = false
            end, 200)

            lock = true
          end
        end)
      })
  end
end

do
  local default_config = {
    neuron_dir = os.getenv("HOME") .. "/" .. "neuron",
  }

  local function setup_autocmds()
    local pattern = string.format("%s/*.md", M.config.neuron_dir)

    vim.cmd [[augroup NeuronVirtualText]]
    vim.cmd [[au!]]
    -- vim.cmd(string.format("au BufRead %s lua require'neuron'.update_virtual_titles()", pattern))
    -- vim.cmd(string.format("au BufRead %s lua require'neuron'.attach_buffer()", pattern))
    vim.cmd(string.format("au BufRead %s lua require'neuron'.add_all_virtual_titles()", pattern))
    vim.cmd(string.format("au BufRead %s lua require'neuron'.attach_buffer_fast()", pattern))
    vim.cmd [[augroup END]]
  end

  function M.setup(user_config)
    user_config = user_config or {}
    M.config = vim.tbl_extend("keep", user_config, default_config)
    ns = api.nvim_create_namespace("neuron.nvim")

    setup_autocmds()
  end
end

function M.next_link_idx() -- returns (1, 0 based index)
  local tuple = api.nvim_win_get_cursor(0) -- (1, 0) based index

  local current_ln = tuple[1] - 1
  local current_col = tuple[2]

  local line_end = api.nvim_buf_line_count(0) - 1

  local current = true
  for ln = current_ln, line_end do -- ln is 0 based
    local line = api.nvim_buf_get_lines(0, ln, ln + 1, true)[1]

    local col_lua_idx = current_col + 1 -- convert to lua idx

    local sub
    if current then
      sub = string.sub(line, col_lua_idx)
    else
      sub = line
    end

    local matched = utils.match_link_idx(sub)

    if matched ~= nil then
      if current then
        return {ln + 1, matched + col_lua_idx} -- returns (1, 0) based index
      else
        return {ln + 1, matched + 1}
      end
    end

    current = false
  end
end

function M.goto_next_link()
  local tuple = M.next_link_idx()
  if tuple ~= nil then
    api.nvim_win_set_cursor(0, tuple)
  else
    error("No more next links")
  end
end

return M
