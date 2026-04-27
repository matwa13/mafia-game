-- src/npc/errors.lua
-- D-05 (Phase 6): LLM error classification + persistence + retry.
-- Non-negotiable: bounded-retry-no-supervisor-restart — LLM errors are return values,
-- never unhandled Lua errors. 2 retries, exp backoff (1s, 3s). Retryable: RATE_LIMIT /
-- SERVER_ERROR / TIMEOUT / NETWORK_ERROR. Final fallback always persisted to SQL errors table.
-- Phase 1 D-07: every retry attempt + final fallback each write one row to errors table.
-- extract_generate_text lives here (Phase 6 Step B Decision): shared by turn_chat +
-- turn_last_words; semantic neighbor of error classification.

local logger = require("logger"):named("errors")
local time   = require("time")
local sql    = require("sql")

local MAX_RETRIES = 2
local BACKOFFS    = { "1s", "3s" }

--- Classify an LLM error. Retryable for RATE_LIMIT/SERVER_ERROR/TIMEOUT/
--- NETWORK_ERROR; everything else is a one-shot fallback. Accepts both
--- table errors and string errors (npc_test.lua:52-68 verbatim pattern).
local function classify(err)
    if not err then return { retryable = false, reason = "ok" } end
    local err_str = tostring(err)
    local s = err_str:lower()
    if s:find("rate_limit") then return { retryable = true, reason = "rate_limit" } end
    if s:find("server_error") then return { retryable = true, reason = "server_error" } end
    if s:find("timeout") then return { retryable = true, reason = "timeout" } end
    if s:find("network") then return { retryable = true, reason = "network_error" } end
    if type(err) == "table" then
        local t = nil
        for k, v in pairs(err) do
            if k == "type" then t = v end
        end
        if t == "RATE_LIMIT" or t == "SERVER_ERROR"
            or t == "TIMEOUT" or t == "NETWORK_ERROR" then
            return { retryable = true, reason = tostring(t):lower() }
        end
        return { retryable = false, reason = tostring(t or "unknown"):lower() }
    end
    return { retryable = false, reason = "string_error" }
end

--- Persist one error row to app:db.errors. D-07 mandates every retry attempt
--- plus the final fallback each write a row. Acquire/release per-write.
local function persist_error(npc_id, call_type, err, retry_count)
    local err_type, err_http, err_msg
    if type(err) == "string" then
        err_type, err_http, err_msg = "string", "", err
    elseif type(err) == "table" then
        err_type = tostring(err.type or "")
        err_http = tostring(err.http_code or "")
        err_msg  = tostring(err.message or "")
    else
        err_type, err_http, err_msg = tostring(err), "", ""
    end
    logger:warn(string.format("[npc] LLM error call=%s retry=%d type=%s msg=%s",
        call_type, retry_count, err_type, err_msg))
    local db, db_err = sql.get("app:db")
    if db_err or not db then
        logger:error("[npc] sql.get failed in persist_error", { err = tostring(db_err) })
        return
    end
    db:execute(
        "INSERT INTO errors (ts, npc_id, call_type, http_code, message, retry_count) "
        .. "VALUES (?, ?, ?, ?, ?, ?)",
        { os.time(), npc_id, call_type, err_http, err_msg, retry_count }
    )
    db:release()
end

--- with_retry(npc_id, call_type, fn) — fn() returns (value, err). Retries up to
--- MAX_RETRIES on retryable errors. Every attempt writes to errors table.
local function with_retry(npc_id, call_type, fn)
    local attempt = 0
    while true do
        local value, err = fn()
        if not err then return value, nil end
        persist_error(npc_id, call_type, err, attempt)
        local c = classify(err)
        if not c.retryable or attempt >= MAX_RETRIES then
            return nil, err
        end
        local backoff = BACKOFFS[attempt + 1] or "3s"
        if type(err) == "table" and err.retry_after and err.retry_after > 0 then
            backoff = tostring(err.retry_after) .. "s"
        end
        time.sleep(backoff)
        attempt = attempt + 1
    end
end

local function extract_generate_text(res)
    -- Authoritative Wippy shape (from vendor/wippy/llm/llm.lua normalize_response):
    --   { result = <string>, tokens, finish_reason, metadata, tool_calls }
    -- where `result` is the generated text itself as a STRING.
    -- Fallbacks below cover plain-string returns and tables that may carry
    -- `content`/`text` at the top level or nested — only used if `result`
    -- is missing.
    if type(res) == "string" then return res end
    if type(res) ~= "table" then return "" end
    -- Canonical case: result is a string.
    local r = nil
    for k, v in pairs(res) do
        if k == "result" then r = v end
    end
    if type(r) == "string" then return r end
    -- Defensive fallbacks (in case provider emits a non-canonical shape).
    if type(r) == "table" then
        for k2, v2 in pairs(r) do
            if (k2 == "content" or k2 == "text") and type(v2) == "string" then
                return v2
            end
        end
    end
    for k, v in pairs(res) do
        if (k == "content" or k == "text") and type(v) == "string" then
            return v
        end
    end
    return ""
end

return {
    classify              = classify,
    persist_error         = persist_error,
    with_retry            = with_retry,
    extract_generate_text = extract_generate_text,
}
