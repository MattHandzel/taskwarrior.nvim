-- taskwarrior/inbox.lua — :TaskInbox. Triage tasks added in the last N hours
-- that have no project, no due date, and no tags. Walks them one by one,
-- prompting the user to defer, set project, schedule, drop, or skip.
--
-- This is distinct from :TaskReview (which walks all pending tasks by
-- urgency) — :TaskInbox specifically targets "stuff I dumped in and haven't
-- organized yet".

local M = {}

local function run(cmd)
  local out = vim.fn.system(cmd)
  return out, vim.v.shell_error == 0
end

-- Accept hours as a single optional integer (default 24).
function M.run(hours)
  hours = tonumber(hours) or 24
  local cutoff = os.time() - hours * 3600
  -- Taskwarrior's entry.after: expects an ISO-like date. `now-Nh` is simpler.
  local filter = string.format(
    "status:pending entry.after:now-%dh project: -TAGGED", hours)
  local cmd = string.format(
    "task rc.bulk=0 rc.confirmation=off rc.json.array=on %s export", filter)
  local out, ok = run(cmd)
  if not ok then
    require("taskwarrior.notify")("error",
      "taskwarrior.nvim: failed to fetch inbox", vim.log.levels.ERROR)
    return
  end
  local js = out:find("%[")
  if js and js > 1 then out = out:sub(js) end
  local parsed_ok, tasks = pcall(vim.fn.json_decode, out)
  if not parsed_ok or type(tasks) ~= "table" then tasks = {} end

  -- Guard: also filter client-side, because TW's `project:` (empty) filter
  -- can be finicky across TW versions.
  local filtered = {}
  for _, t in ipairs(tasks) do
    local has_tags = t.tags and #t.tags > 0
    local has_project = t.project and t.project ~= ""
    local has_due = t.due and t.due ~= ""
    local entry_epoch = 0
    if t.entry then
      local y, mo, d, H, Mi, S = t.entry:match("^(%d%d%d%d)(%d%d)(%d%d)T(%d%d)(%d%d)(%d%d)")
      if y then
        entry_epoch = os.time({
          year = tonumber(y), month = tonumber(mo), day = tonumber(d),
          hour = tonumber(H), min = tonumber(Mi), sec = tonumber(S),
        })
      end
    end
    if not has_project and not has_due and not has_tags and entry_epoch >= cutoff then
      table.insert(filtered, t)
    end
  end

  if #filtered == 0 then
    require("taskwarrior.notify")("review",
      string.format("taskwarrior.nvim: inbox empty (last %dh)", hours))
    return
  end

  local idx = 1
  local function walk()
    if idx > #filtered then
      require("taskwarrior.notify")("review",
        "taskwarrior.nvim: inbox processed")
      return
    end
    local t = filtered[idx]
    local short = t.uuid:sub(1, 8)
    local choices = {
      "set project",
      "schedule",
      "tag",
      "defer (wait 1d)",
      "drop",
      "skip",
      "quit",
    }
    vim.ui.select(choices, {
      prompt = string.format("[%d/%d] %s", idx, #filtered, t.description or ""),
    }, function(choice)
      if not choice or choice == "quit" then return end
      if choice == "skip" then
        idx = idx + 1
        return walk()
      end
      local action
      if choice == "drop" then
        action = function(cb)
          run(string.format("task rc.bulk=0 rc.confirmation=off %s delete", short))
          cb()
        end
      elseif choice == "defer (wait 1d)" then
        action = function(cb)
          run(string.format("task rc.bulk=0 rc.confirmation=off %s modify wait:1d", short))
          cb()
        end
      elseif choice == "set project" then
        action = function(cb)
          vim.ui.input({ prompt = "Project: " }, function(v)
            if v and v ~= "" then
              run(string.format("task rc.bulk=0 rc.confirmation=off %s modify project:%s",
                short, v))
            end
            cb()
          end)
        end
      elseif choice == "schedule" then
        action = function(cb)
          vim.ui.input({ prompt = "Due (e.g. tomorrow, eow): " }, function(v)
            if v and v ~= "" then
              run(string.format("task rc.bulk=0 rc.confirmation=off %s modify due:%s",
                short, v))
            end
            cb()
          end)
        end
      elseif choice == "tag" then
        action = function(cb)
          vim.ui.input({ prompt = "Tag (no +): " }, function(v)
            if v and v ~= "" then
              run(string.format("task rc.bulk=0 rc.confirmation=off %s modify +%s",
                short, v))
            end
            cb()
          end)
        end
      end
      action(function()
        idx = idx + 1
        vim.schedule(walk)
      end)
    end)
  end
  walk()
end

return M
