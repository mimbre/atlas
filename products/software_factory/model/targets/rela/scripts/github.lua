-- GitHub ↔ rela (IS-Atlas-115, IS-Atlas-22): rela's own sync of pull requests, run by
-- rela's scheduler (schedules.yaml) as integration:github. Hand-written, like
-- data-entry.yaml.
--
-- For every issue with a pull request (pr_url) that is not merged yet, it reads the pull,
-- and while it is open the combined check status of its head and whether it merges into
-- its base: pr_state, pr_checks (pending, success, failure), when CI failed
-- pr_checks_failure (the failing checks and the failing lines of their logs, IS-Atlas-124), and
-- pr_mergeable (clean, behind, conflicting, or unknown while GitHub works it out), all
-- with the head commit they were read for, pr_checks_head, in one write. For every pull
-- request fact that is not merged yet: its title, state and draft. Only what differs is
-- written.
--
-- The head (IS-Atlas-120, IS-Atlas-122): Flow records the head Code pushed (pr_head), and
-- its CI gate acts only while pr_checks_head is that head, so what this sync read of an
-- earlier head, written after Code's push, is never taken for the current one. The sync
-- takes the pull's head as pr_head itself when none is recorded (a pull opened before Code
-- answered with its head) or when someone else pushed onto the pull: the recorded head is
-- among the pull's commits, so the pull's head is ahead of it. A head GitHub answers before
-- it caught up with Code's push (the recorded head not among the pull's commits yet) is
-- never taken, nor one whose commits GitHub does not list.
--
-- Merged is final. Closed is not: a closed pull can be reopened. A pull recorded closed is
-- read again when GitHub lists it among its repository's open pulls (one list per
-- repository and run), so a reopened pull's state, mergeability and checks are synced
-- again. The pull of an issue closed in Atlas (gate_result close) is left closed.
--
-- rela → GitHub: only what this rela's own data records as to close is closed, each with
-- a comment saying why (IS-Atlas-130, IS-Atlas-133):
--
--   * the open pull request of an issue closed in Atlas (gate_result close); a close
--     GitHub refuses is written to the issue's pr_close_failure;
--   * an open pull request fact with a close_reason: the pull an issue left behind when a
--     run replaced its pr_url (superseded by <the new url>) or when it was removed in
--     Atlas (issue removed), recorded before the issue went. Its repository need not be
--     one any remaining issue names. A close GitHub refuses is written to its
--     close_failure. Once closed it is not read again: reopened by a person, it stays so.
--
-- A pull is never closed because of its branch name (an open atlas/TK-… pull with no record
-- is left alone), nor because its issue is missing: a test rela reads the same
-- repositories with other data. A refused close is logged; the next run tries again.
--
-- Secrets (.rela/secrets.yaml, which rela-run.sh writes on Fly): github_api, GitHub's API
-- (https://api.github.com); github_token, a token that reads pull requests, checks and job
-- logs (optional: without it GitHub is read anonymously, which its rate limit allows for
-- a few pulls, and job logs are not readable, so a failure names its checks only);
-- github_write, "true" only in the environment allowed to write to GitHub (prod): without
-- it nothing is closed. Without github_api or github_token (a rela on a Mac, a test) it
-- does nothing.

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
local EXCERPT_LINES = 100
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
  -- Only an environment whose rela is told to (github_write: "true", prod only) writes to
  -- GitHub: a test rela reads the same repositories and must never close their pulls.
  if rela.secrets.github_write ~= "true" then return "github_write is not set: nothing is written to GitHub" end
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

-- The failing lines of a GitHub Actions job's log (IS-Atlas-124): only what failed, never
-- the output of tests that passed, whose captured stack traces (`** (RuntimeError) …`,
-- `FAIL` in a message) look like failures but are none. Kept are:
--
--   * each of ExUnit's numbered failures (`  1) test …`) with the lines under it, which
--     ExUnit indents deeper than its number, up to the next test: the first line that is
--     not indented deeper (the next failure, a passing test, the summary);
--   * compiler errors: `error: …` with its diagnostic (`│`, `└─` lines, or lines indented
--     deeper), and `== Compilation error … ==` with the line after it; warnings only when
--     they failed the step (`--warnings-as-errors`);
--   * the end of the step that failed, the lines before `##[error]`: at most 12, and from
--     ExUnit's summary (`Finished in …`) when it is among them, so what a passing test
--     printed just before it is not.
--
-- Of those, the last EXCERPT_LINES. Logger output (`12:00:00.000 [warning] …`) and blank
-- lines are left out. GitHub answers the log with a redirect to storage that takes no token.
local FAILURE_LINES = 40
local TAIL_LINES = 12

local function indent(line) return #line:match("^%s*") end

local function numbered(line) return line:match("^%s*%d+%) ") ~= nil end

local function diagnostic(line)
  return line:match("^[%s%d]*│") ~= nil or line:match("^[%s%d]*└") ~= nil
end

-- The indices of the failing lines among `lines`, in order.
local function failing(lines)
  local strict = false
  for _, line in ipairs(lines) do
    if line:find("warnings-as-errors", 1, true) or line:find("due to warnings", 1, true) then
      strict = true
      break
    end
  end
  local keep = {}
  local i = 1
  while i <= #lines do
    local line = lines[i]
    local l = line:lower()
    local j = i + 1
    if numbered(line) then
      -- An ExUnit failure, up to the next test.
      local base = indent(line)
      while j <= #lines and j - i <= FAILURE_LINES and not numbered(lines[j]) and
            indent(lines[j]) > base do
        j = j + 1
      end
      for k = i, j - 1 do keep[k] = true end
    elseif l:match("^%s*error[:%[]") or (strict and l:match("^%s*warning:")) then
      -- A compiler error (or a warning that failed the step) and its diagnostic.
      local base = indent(line)
      while j <= #lines and j - i <= 12 and
            (diagnostic(lines[j]) or (indent(lines[j]) > base and not numbered(lines[j]))) do
        j = j + 1
      end
      for k = i, j - 1 do keep[k] = true end
    elseif line:match("^%s*== Compilation error") then
      for k = i, math.min(i + 1, #lines) do keep[k] = true end
      j = math.min(i + 2, #lines + 1)
    elseif line:find("##[error]", 1, true) then
      local from = math.max(1, i - TAIL_LINES)
      for k = i - 1, from, -1 do
        if lines[k]:match("^%s*Finished in ") then from = k; break end
      end
      for k = from, i do keep[k] = true end
    end
    i = j
  end
  local picked = {}
  for k = 1, #lines do if keep[k] then table.insert(picked, k) end end
  return picked
end

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
  local picked = {}
  for _, k in ipairs(failing(lines)) do table.insert(picked, lines[k]) end
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

-- Whether the commit `recorded` is among the commits of pull `number` (GitHub lists 250 at
-- most). Pull requests: read is all it takes.
local function among(repo, number, recorded)
  local page = 1
  while true do
    local path = "/repos/" .. repo .. "/pulls/" .. number .. "/commits?per_page=100&page=" .. page
    local commits, err = json(path)
    if not commits then
      print("github sync: " .. repo .. "#" .. number .. ": commits: " .. tostring(err))
      return false
    end
    for _, commit in ipairs(commits) do
      if commit.sha == recorded then return true end
    end
    if #commits < 100 then return false end
    page = page + 1
  end
end

-- Whether the pull's head `sha` is taken as the issue's head (pr_head): none is recorded, or
-- the pull's head is ahead of the recorded one. See the head, above.
local function adopted(repo, number, recorded, sha)
  if type(recorded) ~= "string" or recorded == "" then return true end
  if recorded == sha then return false end
  return among(repo, number, recorded)
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

-- Pulls recorded closed that GitHub lists open again: repository → set of open numbers,
-- read once per run. A repository whose list GitHub does not give has none this run.
local open_pulls = {}

local function reopened(repo, number)
  if open_pulls[repo] == nil then
    local numbers = {}
    local page = 1
    while true do
      local pulls, err = json("/repos/" .. repo .. "/pulls?state=open&per_page=100&page=" .. page)
      if not pulls then
        print("github sync: " .. repo .. ": open pulls: " .. tostring(err))
        break
      end
      for _, pull in ipairs(pulls) do numbers[tostring(pull.number)] = true end
      if #pulls < 100 then break end
      page = page + 1
    end
    open_pulls[repo] = numbers
  end
  return open_pulls[repo][number] == true
end

-- Whether a pull recorded in this state (merged, closed, open or not read yet) is read.
local function read(state, repo, number)
  if state == "merged" then return false end
  if state == "closed" then return reopened(repo, number) end
  return true
end

for _, issue in ipairs(rela.list_entities("issue")) do
  local p = issue.properties
  local repo, number = slug(p.pr_url)
  if repo and not (p.pr_state == "closed" and p.gate_result == "close") and read(p.pr_state, repo, number) then
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
        local state, failed = checks(repo, sha)
        if state then
          -- One write: the status, the mergeability and the head they were read for.
          after.pr_checks_head = sha
          after.pr_mergeable = mergeable(pull)
          if adopted(repo, number, p.pr_head, sha) then after.pr_head = sha end
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

-- Whether a recorded reason to close a pull request is there.
local function to_close(reason) return type(reason) == "string" and reason ~= "" end

for _, pr in ipairs(rela.list_entities("pull_request")) do
  local p = pr.properties
  local repo, number = slug(p.url)
  local closing = to_close(p.close_reason)
  -- A recorded pull Atlas closed is final: reopened by a person, it is not closed again.
  if repo and not (closing and p.state == "closed") and read(p.state, repo, number) then
    local pull, err = json("/repos/" .. repo .. "/pulls/" .. number)
    if pull then
      local after = {title = pull.title, state = pull_state(pull), draft = pull.draft == true}
      if closing and after.state == "open" then
        local failed = close(repo, number, "Closed by Atlas: " .. p.close_reason .. ".")
        if failed then
          print("github sync: " .. pr.id .. ": close: " .. failed)
          after.close_failure = failed
        else
          after.state = "closed"
          after.close_failure = EMPTY
        end
      end
      write(pr.id, p, after)
    else
      print("github sync: " .. pr.id .. ": " .. tostring(err))
    end
  end
end
