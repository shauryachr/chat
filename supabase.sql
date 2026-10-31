-- ============================================================
-- Connapp – Supabase schema (full)
-- Run in SQL Editor
-- ============================================================

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text unique not null,
  full_name text,
  avatar_url text,
  bio text,
  gender text,
  dob date,
  created_at timestamptz default now() not null,
  updated_at timestamptz default now() not null
);

alter table public.profiles drop constraint if exists username_format;
alter table public.profiles
  add constraint username_format check (username ~ '^[a-z0-9_]{3,30}$');

create index if not exists profiles_username_idx on public.profiles (username);

create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  sender_id uuid not null references public.profiles(id) on delete cascade,
  receiver_id uuid not null references public.profiles(id) on delete cascade,
  content text not null check (char_length(content) > 0 and char_length(content) <= 4000),
  created_at timestamptz default now() not null,
  edited_at timestamptz,
  deleted_at timestamptz
);

create index if not exists messages_pair_idx
  on public.messages (least(sender_id, receiver_id), greatest(sender_id, receiver_id), created_at);
create index if not exists messages_receiver_idx on public.messages (receiver_id, created_at desc);

-- Blocks
create table if not exists public.blocks (
  blocker_id uuid not null references public.profiles(id) on delete cascade,
  blocked_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz default now() not null,
  primary key (blocker_id, blocked_id),
  check (blocker_id <> blocked_id)
);

-- Hidden chats (per user)
create table if not exists public.hidden_chats (
  user_id uuid not null references public.profiles(id) on delete cascade,
  peer_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz default now() not null,
  primary key (user_id, peer_id),
  check (user_id <> peer_id)
);

-- Auto profile on signup
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, username, full_name)
  values (
    new.id,
    lower(coalesce(new.raw_user_meta_data->>'username', 'user_' || substr(new.id::text, 1, 8))),
    coalesce(new.raw_user_meta_data->>'full_name', '')
  );
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users for each row execute procedure public.handle_new_user();

create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end;
$$;

drop trigger if exists profiles_updated_at on public.profiles;
create trigger profiles_updated_at
  before update on public.profiles for each row execute procedure public.set_updated_at();

-- RLS
alter table public.profiles enable row level security;
alter table public.messages enable row level security;
alter table public.blocks enable row level security;
alter table public.hidden_chats enable row level security;

drop policy if exists "Public profiles are viewable by everyone" on public.profiles;
create policy "Public profiles are viewable by everyone" on public.profiles for select using (true);

drop policy if exists "Users can update own profile" on public.profiles;
create policy "Users can update own profile" on public.profiles for update using (auth.uid() = id);

drop policy if exists "Users can insert own profile" on public.profiles;
create policy "Users can insert own profile" on public.profiles for insert with check (auth.uid() = id);

drop policy if exists "Users can read their own messages" on public.messages;
create policy "Users can read their own messages" on public.messages for select
  using (auth.uid() = sender_id or auth.uid() = receiver_id);

drop policy if exists "Users can send messages" on public.messages;
create policy "Users can send messages" on public.messages for insert
  with check (auth.uid() = sender_id);

drop policy if exists "Users can update own messages" on public.messages;
create policy "Users can update own messages" on public.messages for update
  using (auth.uid() = sender_id);

drop policy if exists "Users can delete own messages" on public.messages;
create policy "Users can delete own messages" on public.messages for delete
  using (auth.uid() = sender_id);

drop policy if exists "Users manage own blocks" on public.blocks;
create policy "Users manage own blocks" on public.blocks for all
  using (auth.uid() = blocker_id) with check (auth.uid() = blocker_id);

drop policy if exists "Users manage own hidden chats" on public.hidden_chats;
create policy "Users manage own hidden chats" on public.hidden_chats for all
  using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- Realtime
alter table public.messages replica identity full;
alter publication supabase_realtime add table public.messages;

-- Migration helpers if tables already exist
do $$ begin
  alter table public.messages add column if not exists edited_at timestamptz;
  alter table public.messages add column if not exists deleted_at timestamptz;
exception when others then null;
end $$;
