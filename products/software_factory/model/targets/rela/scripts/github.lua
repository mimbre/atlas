-- GitHub ↔ rela (IS-Atlas-115, IS-Atlas-22): rela's own sync of pull requests, run by
-- rela's scheduler (schedules.yaml) as integration:github. Hand-written, like
-- data-entry.yaml.
--
-- For every issue with a pull request (pr_url) that is not merged or closed yet, it reads
-- the pull, and while it is open the combined check status of its head and whether it
-- merges into its base: pr_state, pr_checks (pending, success, failure), when CI failed
-- pr_checks_failure (the failing checks and the failing lines of their logs), and
-- pr_mergeable (clean, behind, conflicting, or unknown while GitHub works it out). For
-- every pull request fact that is not merged or closed yet: its title, state and draft.
-- Only what differs is written.
--
-- rela → GitHub: an open pull request of an issue closed in Atlas (gate_result close) is
-- closed on GitHub with a comment; so is an open pull request Code opened for an issue
-- (its branch atlas/TK-<issue>-<n>) that is no longer in Atlas (removed). A close GitHub
-- refuses is logged and, for an issue still there, written to pr_close_failure; the next
-- run tries again.
--
-- Secrets (.rela/secrets.yaml, which rela-run.sh writes on Fly): github_api, GitHub's API
-- (https://api.github.com); github_token, a token that reads pull requests, checks and job
-- logs, and writes pull requests to close them (optional: without it GitHub is read
-- anonymously, which its rate limit allows for a few pulls, job logs are not readable, so
-- a failure names its checks only, and nothing is closed). Without either (a rela on a
-- Mac, a test) it does nothing.

local token = rela.secrets.github_token
local api = rela.secrets.github_api
if token == "" then token = nil end
if api == nil or api == "" then
  if token == nil then return end
  api = "https://api.github.com"
end

local FAILED = {failure = true, cancelled = true, timed_out = true, action_required = true,
                stale = true, startup_failure = true}
local PASSED = {success = true, neutral = true, skipped = true}
local EXCERPT_LINES = 60
local EXCERPT_CHARS = 12000

local function get(path)
  local headers = {
    Accept = "application/vnd.github+json",
    ["X-GitHub-Api-Version"] = "2022-11-28",
    ["User-Agent"] = "atlas-rela-sync",
  }
  if token then headers.Authorization = "Bearer " .. token end
  local resp, err = http.get(api .. path, {headers = headers, timeout = 20})
  if not resp then return nil, err.kind .. ": " .. err.message end
  return resp
end

-- GitHub's rate limit (403, 429) ends this run: the next one tries again.
local limited = false

local function json(path)
  if limited then return nil, "rate limited" end
  local resp, err = get(path)
  if not resp then return nil, err end
  if resp.status_code == 403 or resp.status_code == 429 then limited = true end
  if resp.status_code ~= 200 then return nil, path .. " answered " .. resp.status_code end
  return rela.json.decode(resp.body)
end

-- A write to GitHub: nil, or why it failed.
local function send(method, path, body)
  if not token then return "no github_token: nothing is written to GitHub" end
  local resp, err = http.request({
    url = api .. path,
    method = method,
    headers = {
      Accept = "application/vnd.github+json",
      ["Content-Type"] = "application/json",
      ["X-GitHub-Api-Version"] = "2022-11-28",
      ["User-Agent"] = "atlas-rela-sync",
      Authorization = "Bearer " .. token,
    },
    body = rela.json.encode(body),
    timeout = 20,
  })
  if not resp then return err.kind .. ": " .. err.message end
  if resp.status_code < 200 or resp.status_code > 299 then
    return method .. " " .. path .. " answered " .. resp.status_code
  end
  return nil
end

-- Closes the pull, then says why in a comment: nil, or why the close failed.
local function close(repo, number, why)
  local err = send("PATCH", "/repos/" .. repo .. "/pulls/" .. number, {state = "closed"})
  if err then return err end
  local err2 = send("POST", "/repos/" .. repo .. "/issues/" .. number .. "/comments", {body = why})
  if err2 then print("github sync: closed " .. repo .. "#" .. number .. ", no comment: " .. err2) end
  return nil
end

-- Whether the pull merges into its base, from GitHub's mergeable and mergeable_state.
local function mergeable(pull)
  if pull.mergeable == false or pull.mergeable_state == "dirty" then return "conflicting" end
  if pull.mergeable_state == "behind" then return "behind" end
  if pull.mergeable == true then return "clean" end
  return "unknown"
end

-- "https://github.com/<owner>/<repo>/pull/<n>" → "<owner>/<repo>", "<n>"
local function slug(url)
  if type(url) ~= "string" then return nil end
  return url:match("^https://github%.com/([%w_.%-]+/[%w_.%-]+)/pull/(%d+)$")
end

local function pull_state(pull)
  if pull.merged then return "merged" end
  return pull.state
end

-- What CI says of a commit, as Code's integrate reads it: failure when one check failed,
-- success when every check and status passed, else pending. The names of those that failed.
local function checks(repo, sha)
  local runs, err = json("/repos/" .. repo .. "/commits/" .. sha .. "/check-runs?per_page=100")
  if not runs then return nil, err end
  local status, err2 = json("/repos/" .. repo .. "/commits/" .. sha .. "/status?per_page=100")
  if not status then return nil, err2 end
  local failed, all_passed = {}, true
  for _, r in ipairs(runs.check_runs or {}) do
    if r.status == "completed" and FAILED[r.conclusion] then
      table.insert(failed, r)
    elseif not (r.status == "completed" and PASSED[r.conclusion]) then
      all_passed = false
    end
  end
  for _, s in ipairs(status.statuses or {}) do
    if s.state == "failure" or s.state == "error" then
      table.insert(failed, {name = s.context, html_url = s.target_url})
    elseif s.state ~= "success" then
      all_passed = false
    end
  end
  if #failed > 0 then return "failure", failed end
  local complete = runs.total_count == #(runs.check_runs or {}) and
                   status.total_count == #(status.statuses or {})
  if complete and all_passed and (#(runs.check_runs or {}) + #(status.statuses or {})) > 0 then
    return "success", {}
  end
  return "pending", {}
end

-- How many lines after a line of each kind tell what failed; nil: not a line that does.
local function after(line)
  local l = line:lower()
  if line:match("^%s*%d+%) ") then return 15 end                  -- an ExUnit failure
  if line:find("%*%* %(") then return 5 end                       -- an Elixir exception
  if l:match("^%s*error[:%[]") or l:match("^%s*warning:") then return 5 end  -- the compiler
  if l:find("not ok ", 1, true) or line:find("FAIL", 1, true) or line:find("✖", 1, true) then
    return 3                                                       -- node, others
  end
  return nil
end

-- The failing lines of a GitHub Actions job's log: failures with the lines that explain
-- them, and the end of the step that failed (before `##[error]`); the last EXCERPT_LINES
-- of them. Logger output (`12:00:00.000 [warning] …`) is left out. GitHub answers the log
-- with a redirect to storage that takes no token.
local function excerpt(repo, run)
  if not run.id or not token then return nil end
  local resp = get("/repos/" .. repo .. "/actions/jobs/" .. run.id .. "/logs")
  if not resp then return nil end
  if resp.status_code == 302 and resp.headers.location then
    resp = http.get(resp.headers.location, {timeout = 25})
  end
  if not resp or resp.status_code ~= 200 then return nil end
  local lines = {}
  for line in resp.body:gmatch("[^\r\n]+") do
    line = line:gsub("^%d%d%d%d%-%d%d%-%d%dT[%d:.]+Z ", "")
    if not line:match("^%d%d:%d%d:%d%d%.%d+ %[%a+%]") and not line:match("^%s*$") then
      table.insert(lines, line)
    end
  end
  local keep, picked = {}, {}
  for i, line in ipairs(lines) do
    local n = after(line)
    if n then
      for j = i, math.min(i + n, #lines) do keep[j] = true end
    elseif line:find("##[error]", 1, true) then
      for j = math.max(1, i - 12), i do keep[j] = true end
    end
  end
  for i = 1, #lines do if keep[i] then table.insert(picked, lines[i]) end end
  local from = math.max(1, #picked - EXCERPT_LINES + 1)
  return table.concat(picked, "\n", from)
end

local function failure_text(repo, sha, failed)
  local names = {}
  for _, r in ipairs(failed) do table.insert(names, r.name) end
  local parts = {"Failing checks on " .. sha:sub(1, 7) .. ": " .. table.concat(names, ", ")}
  for _, r in ipairs(failed) do
    local text = "## " .. r.name
    if r.html_url then text = text .. "\n" .. r.html_url end
    local lines = excerpt(repo, r)
    if lines and lines ~= "" then text = text .. "\n\n```\n" .. lines .. "\n```" end
    table.insert(parts, text)
  end
  local all = table.concat(parts, "\n\n")
  if #all > EXCERPT_CHARS then all = all:sub(1, EXCERPT_CHARS) .. "\n…" end
  return all
end

local EMPTY = rela.sync and rela.sync.EMPTY or ""

local function write(id, before, after)
  local changed = {}
  local any = false
  for k, v in pairs(after) do
    local old = before[k]
    if v == EMPTY then
      if old ~= nil and old ~= "" then changed[k] = v; any = true end
    elseif old ~= v then
      changed[k] = v; any = true
    end
  end
  if any then rela.update_entity(id, changed) end
end

local DONE = {merged = true, closed = true}
local repos = {}
local listed = {}

for _, issue in ipairs(rela.list_entities("issue")) do
  local p = issue.properties
  local repo, number = slug(p.pr_url)
  listed[issue.id] = true
  if repo then repos[repo] = true end
  if repo and not DONE[p.pr_state] then
    local pull, err = json("/repos/" .. repo .. "/pulls/" .. number)
    if pull then
      local after = {pr_state = pull_state(pull)}
      if after.pr_state == "open" and p.gate_result == "close" then
        -- Closed in Atlas: its pull request is closed on GitHub too.
        local failed = close(repo, number, "Closed by Atlas: its issue " .. issue.id ..
                             " was closed there.")
        if failed then
          print("github sync: " .. issue.id .. ": close: " .. failed)
          after.pr_close_failure = failed
        else
          after.pr_state = "closed"
          after.pr_close_failure = EMPTY
        end
      elseif after.pr_state == "open" and pull.head and pull.head.sha then
        local sha = pull.head.sha
        after.pr_mergeable = mergeable(pull)
        local state, failed = checks(repo, sha)
        if state then
          after.pr_checks = state
          if state == "failure" then
            -- The log excerpt is read once per head.
            local known = p.pr_checks == "failure" and type(p.pr_checks_failure) == "string" and
                          p.pr_checks_failure:find("Failing checks on " .. sha:sub(1, 7), 1, true) == 1
            if not known then after.pr_checks_failure = failure_text(repo, sha, failed) end
          else
            after.pr_checks_failure = EMPTY
          end
        end
      end
      write(issue.id, p, after)
    else
      print("github sync: " .. issue.id .. ": " .. tostring(err))
    end
  end
end

-- Removed in Atlas: an open pull request Code opened for an issue (its branch
-- atlas/TK-<issue>-<n>, the task that made it) that rela no longer holds is closed.
for repo in pairs(repos) do
  local pulls, err = json("/repos/" .. repo .. "/pulls?state=open&per_page=100")
  if not pulls then print("github sync: " .. repo .. ": " .. tostring(err)) end
  for _, pull in ipairs(pulls or {}) do
    local id = pull.head and type(pull.head.ref) == "string" and
               pull.head.ref:match("^atlas/TK%-(IS%-.+)%-%d+$")
    if id and not listed[id] then
      local ok, held = pcall(rela.get_entity, id)
      if ok and held == nil then
        local failed = close(repo, pull.number, "Closed by Atlas: its issue " .. id ..
                             " was removed there.")
        if failed then print("github sync: removed " .. id .. ": close: " .. failed) end
      end
    end
  end
end

for _, pr in ipairs(rela.list_entities("pull_request")) do
  local p = pr.properties
  local repo, number = slug(p.url)
  if repo and not DONE[p.state] then
    local pull = json("/repos/" .. repo .. "/pulls/" .. number)
    if pull then
      write(pr.id, p, {title = pull.title, state = pull_state(pull), draft = pull.draft == true})
    end
  end
end
