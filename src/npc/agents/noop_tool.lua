-- src/npc/agents/noop_tool.lua
-- Phase 7 D-06 (Approach A — schema-as-tool): handler shared by vote_tool,
-- night_pick_tool, side_chat_tool. The handler is intentionally a noop —
-- the LLM's structured arguments arrive at response.tool_calls[1].arguments
-- after runner:step returns. The agent framework's tool-execution machinery
-- still calls this handler, so it must exist and return a value.

local function handler(args)
    -- args is the table the LLM provided, validated against meta.input_schema.
    -- We do nothing with it here; the calling turn handler reads it from the
    -- runner response directly. Returning an empty table satisfies the agent
    -- runner's expectation of a tool result.
    return {}
end

return { handler = handler }
