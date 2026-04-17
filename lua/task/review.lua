local M = {}

local function run(cmd)
  local out = vim.fn.system(cmd)
  local ok = vim.v.shell_error == 0
  return out, ok
end

-- run_review: walk through pending tasks one by one.
-- open_fn: callback(filter_str) to open a task buffer (M.open from init)
function M.run(open_fn)
  local out, ok = run(
    "task rc.bulk=0 rc.confirmation=off rc.json.array=on status:pending export")
  if not ok or not out or out == "" then
    vim.notify("task.nvim: failed to export tasks", vim.log.levels.ERROR)
    return
  end
  local js = out
  local s = js:find("%[")
  if s and s > 1 then js = js:sub(s) end
  local parsed_ok, tasks = pcall(vim.fn.json_decode, js)
  if not parsed_ok or type(tasks) ~= "table" or #tasks == 0 then
    vim.notify("task.nvim: no pending tasks", vim.log.levels.INFO)
    return
  end
  -- Sort by urgency desc for review order
  table.sort(tasks, function(a, b) return (a.urgency or 0) > (b.urgency or 0) end)

  local idx = 1
  local function step()
    if idx > #tasks then
      vim.notify(string.format("task.nvim: review complete (%d tasks)", #tasks))
      return
    end
    local t = tasks[idx]
    local short = t.uuid and t.uuid:sub(1, 8) or ""
    local lines = {
      string.format("[%d/%d]  %s", idx, #tasks, t.description or ""),
      string.format("project:%s  urgency:%.1f", t.project or "(none)", t.urgency or 0),
    }
    if t.due then table.insert(lines, string.format("due:%s", t.due)) end
    if t.tags and #t.tags > 0 then table.insert(lines, "tags:" .. table.concat(t.tags, ",")) end
    local header = table.concat(lines, "\n") .. "\n"
    local choices = {
      "k  Keep (next)",
      "d  Defer (set wait:tomorrow)",
      "x  Done",
      "m  Modify (prompt)",
      "g  Go to task buffer",
      "q  Quit review",
    }
    vim.ui.select(choices, {
      prompt = header .. "Action:",
      format_item = function(i) return i end,
    }, function(choice)
      if not choice then return end
      local key = choice:sub(1, 1)
      if key == "k" then
        idx = idx + 1; step()
      elseif key == "d" then
        run(string.format("task rc.bulk=0 rc.confirmation=off %s modify wait:tomorrow", short))
        idx = idx + 1; step()
      elseif key == "x" then
        run(string.format("task rc.bulk=0 rc.confirmation=off %s done", short))
        idx = idx + 1; step()
      elseif key == "m" then
        vim.ui.input({ prompt = "Modify " .. short .. ": " }, function(input)
          if input and input ~= "" then
            local esc = input:gsub("'", "'\\''")
            run(string.format("task rc.bulk=0 rc.confirmation=off %s modify '%s'", short, esc))
          end
          idx = idx + 1; step()
        end)
      elseif key == "g" then
        open_fn("uuid:" .. short)
      elseif key == "q" then
        vim.notify(string.format("task.nvim: review paused at %d/%d", idx, #tasks))
      end
    end)
  end
  step()
end

return M
