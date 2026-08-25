-- 집 가 — 초기 스키마 (rooms, players, sessions, scores)
-- 명세: mdfile/백엔드_Supabase명세.md §3

create extension if not exists "pgcrypto";

create table rooms (
  id                  uuid primary key default gen_random_uuid(),
  code                text unique not null,          -- QR·직접입력용 6자리
  host_player_id      uuid,                          -- 현재 방장
  session_period_min  int  not null default 30,      -- 30 / 45 / 60
  expires_at          timestamptz not null,          -- TTL. 활동 시 now()+2h
  created_at          timestamptz not null default now()
);

create table players (
  id          uuid primary key default gen_random_uuid(),
  room_id     uuid not null references rooms(id) on delete cascade,
  auth_uid    uuid not null,                         -- 익명 로그인 uid
  nickname    text not null,
  joined_seq  int  not null,                         -- 입장 순서. 방장 승계 기준
  left_at     timestamptz,                           -- null이면 방에 있음
  created_at  timestamptz not null default now()
);

create table sessions (
  id          uuid primary key default gen_random_uuid(),
  room_id     uuid not null references rooms(id) on delete cascade,
  seed        int  not null,                         -- 게임 3개 + 각 판 시드가 여기서 파생
  starts_at   timestamptz not null,                  -- 서버 지정 시작 시각
  ended_at    timestamptz,
  created_at  timestamptz not null default now()
);

create table scores (
  session_id   uuid not null references sessions(id) on delete cascade,
  player_id    uuid not null references players(id)  on delete cascade,
  round_index  int  not null check (round_index between 0 and 2),
  normalized   numeric(5,2) not null check (normalized between 0 and 100),
  raw_score    int  not null,                        -- 표시 전용
  tiebreak_ms  int  not null,
  finished     boolean not null,
  created_at   timestamptz not null default now(),
  primary key (session_id, player_id, round_index)
);

create index on rooms   (code);
create index on rooms   (expires_at);
create index on players (room_id) where left_at is null;
create index on players (auth_uid);
create index on sessions(room_id) where ended_at is null;
