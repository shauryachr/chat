-- ============================================================
-- Connapp – Extra features (run AFTER supabase.sql)
-- Delete / edit messages · Block users · Hide chats
-- ============================================================

-- 1. Message edit + soft-delete
alter table public.messages
  add column if not exists edited_at timestamptz,
  add column if not exists deleted_at timestamptz;

-- Allow soft-delete to empty content constraint when deleted
alter table public.messages drop constraint if exists messages_content_check;
alter table public.messages
  add constraint messages_content_check
  check (
    (deleted_at is not null)
    or (char_length(content) > 0 and char_length(content) <= 4000)
  );

-- Owner can update own messages (edit / soft-delete)
drop policy if exists "Users can update own messages" on public.messages;
create policy "Users can update own messages"
  on public.messages for update
  using (auth.uid() = sender_id)
  with check (auth.uid() = sender_id);

-- 2. Blocks
create table if not exists public.blocks (
  blocker_id uuid not null references public.profiles(id) on delete cascade,
  blocked_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz default now() not null,
  primary key (blocker_id, blocked_id),
  check (blocker_id <> blocked_id)
);

create index if not exists blocks_blocked_idx on public.blocks (blocked_id);

alter table public.blocks enable row level security;

drop policy if exists "Users manage own blocks" on public.blocks;
create policy "Users manage own blocks"
  on public.blocks for all
  using (auth.uid() = blocker_id)
  with check (auth.uid() = blocker_id);

-- See if someone blocked you (optional, for UI)
drop policy if exists "Users see blocks involving them" on public.blocks;
create policy "Users see blocks involving them"
  on public.blocks for select
  using (auth.uid() = blocker_id or auth.uid() = blocked_id);

-- 3. Hidden chats (per-user hide of a conversation with a peer)
create table if not exists public.hidden_chats (
  user_id uuid not null references public.profiles(id) on delete cascade,
  peer_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz default now() not null,
  primary key (user_id, peer_id),
  check (user_id <> peer_id)
);

alter table public.hidden_chats enable row level security;

drop policy if exists "Users manage own hidden chats" on public.hidden_chats;
create policy "Users manage own hidden chats"
  on public.hidden_chats for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

-- 4. Prevent messaging blocked users (trigger)
create or replace function public.block_message_check()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  if exists (
    select 1 from public.blocks
    where (blocker_id = new.sender_id and blocked_id = new.receiver_id)
       or (blocker_id = new.receiver_id and blocked_id = new.sender_id)
  ) then
    raise exception 'Cannot message this user (blocked).';
  end if;
  return new;
end;
$$;

drop trigger if exists messages_block_check on public.messages;
create trigger messages_block_check
  before insert on public.messages
  for each row execute procedure public.block_message_check();

-- Realtime: include updates for edit/delete
-- (messages already in publication; REPLICA IDENTITY FULL already set)
