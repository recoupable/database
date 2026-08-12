-- Migration: Drop the chats.model_id column default (model provenance, chat#1956)
--
-- chats.model_id defaulted to 'anthropic/claude-haiku-4.5', which FABRICATED
-- model provenance: any writer that omitted the field got a plausible-looking
-- real model id instead of an honest NULL. Reproduced 2026-08-12 — four
-- POST /api/chat/runs calls with four different explicit models (sonnet-5,
-- kimi-k3, grok-4.6, deepseek-v4-pro) all produced chat rows reading
-- 'anthropic/claude-haiku-4.5' while usage_events billed the real models.
-- Full evidence table: recoupable/chat#1956.
--
-- Sequencing (hard dependency): merges only AFTER recoupable/api#830, which
-- makes every chats writer set model_id explicitly (headless runs write the
-- resolved model; interactive session/chat creation writes the default).
-- Dropping the default first would leave interactive chats with NULL while
-- the UI still expects a value. After api#830, this default has zero
-- remaining writers and exists only as a trap.
--
-- No backfill, deliberately: historical headless rows (fabricated) are
-- indistinguishable from genuinely-defaulted interactive rows, so rewriting
-- either way would fabricate provenance in the other direction. Fence by
-- date instead: rows created before api#830's deploy are untrustworthy;
-- usage_events remains the historical record for completed runs.
--
-- The read path is already NULL-safe: handleChatWorkflowStream falls back
-- via `chat.model_id ?? DEFAULT_MODEL_ID` (api lib/chat/handleChatWorkflowStream.ts).

alter table public.chats
  alter column model_id drop default;

comment on column public.chats.model_id is
  'Model recorded at provision time by the writer (chat#1956). NULL means "not recorded" — never defaulted at the database layer, so a value present is a value some writer chose.';
