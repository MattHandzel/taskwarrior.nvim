-- taskwarrior/report.lua — named reports (:TaskReport next / active / ...).
--
-- Each report bundles a filter, sort, and (optionally) group. The names mirror
-- Taskwarrior's own `task <report>` namespace so CLI muscle memory transfers.

local M = {}

M.reports = {
  -- `task next` — the work queue most CLI users live in: pending, highest
  -- urgency, recent first.
  ["next"]      = { filter = "status:pending",           sort = "urgency-"                 },
  active        = { filter = "+ACTIVE",                  sort = "urgency-"                 },
  overdue       = { filter = "status:pending +OVERDUE",  sort = "due+"                      },
  recurring     = { filter = "status:recurring",         sort = "due+"                      },
  waiting       = { filter = "status:waiting",           sort = "wait+"                     },
  unblocked     = { filter = "status:pending -BLOCKED",  sort = "urgency-"                  },
  ready         = { filter = "status:pending -BLOCKED -WAITING", sort = "urgency-"          },
  blocked       = { filter = "status:pending +BLOCKED",  sort = "urgency-"                  },
  completed     = { filter = "status:completed",         sort = "end-"                      },
  today         = { filter = "status:pending due.before:tomorrow", sort = "due+"             },
  week          = { filter = "status:pending due.before:eow",      sort = "due+"             },
  noproject     = { filter = "status:pending project:",            sort = "urgency-"         },
}

-- Return the sorted list of report names for command completion.
function M.names()
  local out = {}
  for k in pairs(M.reports) do table.insert(out, k) end
  table.sort(out)
  return out
end

-- Open a report. `name` must be one of the keys in M.reports; unknown names
-- fall through with a warning. `open_fn(filter_str)` is the :Task callback
-- threaded from init.lua (so we don't introduce a circular require).
function M.open(name, open_fn)
  if not name or name == "" then
    vim.ui.select(M.names(), { prompt = "Report:" }, function(choice)
      if choice then M.open(choice, open_fn) end
    end)
    return
  end
  local report = M.reports[name]
  if not report then
    require("taskwarrior.notify")("warn",
      string.format("taskwarrior.nvim: unknown report %q", name),
      vim.log.levels.WARN)
    return
  end
  open_fn(report.filter)
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.b[bufnr].task_filter ~= nil then
    if report.sort and report.sort ~= "" then vim.b[bufnr].task_sort = report.sort end
    if report.group then vim.b[bufnr].task_group = report.group end
    require("taskwarrior.buffer").refresh_buf(bufnr)
  end
end

return M
