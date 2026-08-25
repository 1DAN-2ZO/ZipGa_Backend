# 집 가 — 백엔드 (Supabase) 명세

> 백엔드 담당자에게 넘기는 구현 문서. 스키마와 RPC를 그대로 옮겨 쓸 수 있게 쓴다.
>
> 작성일: 2026-08-25 · Supabase (Postgres + Realtime + Auth)
>
> 설계 배경은 [설계 정리](집가_설계정리.md)와 [파장 흐름 설계](../docs/superpowers/specs/2026-08-25-파장흐름-design.md)를 본다.
> 화면 쪽은 [프론트엔드 화면 명세](프론트엔드_화면명세.md)와 짝을 이룬다.

---

## 0. 먼저 알아야 할 것 네 가지

**1. 별도 서버 언어가 없다.** Node도 Python도 Go도 쓰지 않는다. 작업의 대부분이 **SQL / PL-pgSQL**이다. 서버 프로세스가 없으니 배포·재시작·모니터링도 없다.

**2. Edge Function을 쓰지 않는다.** Edge Function은 외부 API 호출이나 시크릿 은닉이 필요할 때 쓰는데 이 앱엔 둘 다 없다. 카카오T는 클라이언트가 직접 여는 딥링크다. **Edge Function 0개로 출시 가능하다.**

**3. 서버에 타이머가 없다.** cron도 스케줄러도 백그라운드 워커도 없다. 이유는 §6에 있다.

**4. 게임 중에는 서버로 아무것도 오지 않는다.** 각 폰이 독립 실행하고 판이 끝날 때 점수만 올린다.

---

## 1. 언어와 구성 요소

| 무엇 | 언어 | 이 프로젝트에서 |
|---|---|---|
| 테이블 스키마 · 권한(RLS) | **SQL** | 필수 |
| 비즈니스 로직 (RPC) | **PL/pgSQL** | 필수 — 여기가 실질적 백엔드 |
| Realtime (Presence · 구독) | 코드 없음 | 클라이언트 SDK 설정만 |
| Auth (익명 로그인) | 코드 없음 | 대시보드 토글 |
| Edge Functions | TypeScript (Deno) | **사용 안 함** |

## 2. 서버가 반드시 맡아야 하는 일

원칙은 하나다 — **클라이언트를 믿을 수 없는 것만 서버로 보낸다.**

| 일 | 왜 서버여야 하나 |
|---|---|
| 세션 시드 발급 | 클라이언트가 만들면 방장이 유리한 문제를 뽑을 수 있음 |
| 시작 시각 지정 | 폰 시계는 제각각. 서버가 박아야 출발선이 맞음 |
| 벌칙 판정 (평균 < 40) | 본인 폰이 계산하면 미달인데 통과했다고 우길 수 있음 |
| 방장 승계 | 판정 기준(최초 입장자)을 서버만 알고 있음 |
| TTL 연장 · 만료 | 시간의 기준이 서버여야 함 |

반대로 **게임 3개 추첨은 서버가 하지 않는다.** 시드에서 파생되므로 모든 클라이언트가 같은 결과를 계산한다. 서버는 시드 하나만 준다.

---

## 3. 데이터 모델

### 3.1 스키마

```sql
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
```

### 3.2 설계 노트

**`players.left_at`을 쓰는 이유 — soft delete여야 한다.**
강퇴를 `DELETE`로 처리하면 재입장 시 `joined_seq`가 사라져 방장 승계 순서가 무너진다. 그리고 "아직 안 갈래"로 돌아온 사람이 원래 순번을 유지해야 한다.

**`seed`가 `int`인 이유.**
32비트 정수여야 클라이언트의 시드 PRNG(mulberry32, xorshift32 등)에 그대로 넣을 수 있다. `bigint`로 하면 JS에서 정밀도 문제가 생긴다.

**`scores`의 복합 PK.**
`(session_id, player_id, round_index)`가 PK라 같은 판에 두 번 제출할 수 없다. 점수를 갈아치우는 재제출이 구조적으로 막힌다.

**`normalized`가 판정에 쓰이는 유일한 값.**
`raw_score`는 화면에 "18/20문제"로 보여주기 위한 값일 뿐 계산에 쓰이지 않는다.

---

## 4. 권한 (RLS)

### 4.1 방침

- 클라이언트는 **읽기만** 할 수 있다. 쓰기는 전부 RPC(`security definer`)를 거친다
- 읽기 범위는 **자기가 속한 방**으로 제한한다

### 4.2 재귀를 피하는 헬퍼

`players` 정책이 `players`를 참조하면 RLS가 무한 재귀한다. `security definer` 함수로 우회한다.

```sql
create or replace function public.current_player_room()
returns uuid
language sql stable security definer set search_path = public
as $$
  select room_id from players
   where auth_uid = auth.uid() and left_at is null
   limit 1
$$;
```

### 4.3 정책

```sql
alter table rooms    enable row level security;
alter table players  enable row level security;
alter table sessions enable row level security;
alter table scores   enable row level security;

create policy room_read on rooms for select
  using (id = current_player_room());

create policy player_read on players for select
  using (room_id = current_player_room());

create policy session_read on sessions for select
  using (room_id = current_player_room());

create policy score_read on scores for select
  using (session_id in (
    select id from sessions where room_id = current_player_room()
  ));

-- 클라이언트 직접 쓰기 차단
revoke insert, update, delete on rooms, players, sessions, scores
  from anon, authenticated;
```

> RLS는 Realtime의 Postgres Changes에도 적용된다. 구독자는 **자기 방의 변경만** 받는다.

---

## 5. RPC 함수

공개 함수 8개 + 내부 헬퍼 3개. 이게 백엔드 작업의 전부다.

### 5.1 내부 헬퍼

```sql
-- 방 코드 생성. 0/O/1/I 제외 (취한 사람이 받아적을 수 있게)
create or replace function public.gen_room_code()
returns text language plpgsql as $$
declare
  chars  text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  result text := '';
  i int;
begin
  for i in 1..6 loop
    result := result || substr(chars, floor(random() * length(chars))::int + 1, 1);
  end loop;
  return result;
end $$;

-- 방장이 비었으면 남은 사람 중 최초 입장자에게 승계
create or replace function public._ensure_host(p_room_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_new_host uuid;
begin
  if exists (
    select 1 from rooms r join players p on p.id = r.host_player_id
     where r.id = p_room_id and p.left_at is null
  ) then
    return;                                   -- 현 방장이 아직 있음
  end if;

  select id into v_new_host from players
   where room_id = p_room_id and left_at is null
   order by joined_seq
   limit 1;

  update rooms set host_player_id = v_new_host where id = p_room_id;
end $$;

-- 방에서 제거. 방장 승계와 빈 방 삭제까지 한 번에
create or replace function public._remove_player(p_player_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_room_id uuid; v_remaining int;
begin
  update players set left_at = now()
   where id = p_player_id and left_at is null
   returning room_id into v_room_id;

  if v_room_id is null then return; end if;   -- 이미 나간 사람

  select count(*) into v_remaining
    from players where room_id = v_room_id and left_at is null;

  if v_remaining = 0 then
    delete from rooms where id = v_room_id;   -- cascade로 전부 정리
  else
    perform _ensure_host(v_room_id);
  end if;
end $$;
```

### 5.2 `create_room(nickname)` — 방 만들기

```sql
create or replace function public.create_room(p_nickname text)
returns table (room_id uuid, room_code text, player_id uuid)
language plpgsql security definer set search_path = public as $$
declare v_room_id uuid; v_code text; v_player_id uuid;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;

  update players set left_at = now()             -- 다른 방에 있었다면 정리
   where auth_uid = auth.uid() and left_at is null;

  loop
    v_code := gen_room_code();
    exit when not exists (select 1 from rooms where code = v_code);
  end loop;

  insert into rooms (code, expires_at)
  values (v_code, now() + interval '2 hours')
  returning id into v_room_id;

  insert into players (room_id, auth_uid, nickname, joined_seq)
  values (v_room_id, auth.uid(), p_nickname, 1)
  returning id into v_player_id;

  update rooms set host_player_id = v_player_id where id = v_room_id;

  return query select v_room_id, v_code, v_player_id;
end $$;
```

### 5.3 `join_room(code, nickname)` — QR 스캔 입장

```sql
create or replace function public.join_room(p_code text, p_nickname text)
returns table (room_id uuid, player_id uuid)
language plpgsql security definer set search_path = public as $$
declare v_room rooms%rowtype; v_player_id uuid; v_seq int;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;

  select * into v_room from rooms where code = upper(p_code);
  if not found then raise exception 'ROOM_NOT_FOUND'; end if;

  if v_room.expires_at < now() then
    delete from rooms where id = v_room.id;      -- 지연 정리 (§6.2)
    raise exception 'ROOM_EXPIRED';
  end if;

  select id into v_player_id from players        -- 이미 이 방에 있으면 그대로
   where room_id = v_room.id and auth_uid = auth.uid() and left_at is null;
  if v_player_id is not null then
    return query select v_room.id, v_player_id;
    return;
  end if;

  update players set left_at = now()             -- 다른 방에 있었다면 정리
   where auth_uid = auth.uid() and left_at is null and room_id <> v_room.id;

  select coalesce(max(joined_seq), 0) + 1 into v_seq
    from players where room_id = v_room.id;

  insert into players (room_id, auth_uid, nickname, joined_seq)
  values (v_room.id, auth.uid(), p_nickname, v_seq)
  returning id into v_player_id;

  update rooms set expires_at = now() + interval '2 hours' where id = v_room.id;

  return query select v_room.id, v_player_id;
end $$;
```

### 5.4 `rejoin_room(code)` — "아직 안 갈래"

```sql
create or replace function public.rejoin_room(p_code text)
returns table (room_id uuid, player_id uuid)
language plpgsql security definer set search_path = public as $$
declare v_room rooms%rowtype; v_player_id uuid;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;

  select * into v_room from rooms where code = upper(p_code);
  if not found then raise exception 'ROOM_NOT_FOUND'; end if;

  if v_room.expires_at < now() then
    delete from rooms where id = v_room.id;
    raise exception 'ROOM_EXPIRED';
  end if;

  select id into v_player_id from players        -- 원래 순번을 그대로 되찾음
   where room_id = v_room.id and auth_uid = auth.uid()
   order by joined_seq
   limit 1;
  if v_player_id is null then raise exception 'PLAYER_NOT_FOUND'; end if;

  update players set left_at = null where id = v_player_id;
  update rooms set expires_at = now() + interval '2 hours' where id = v_room.id;
  perform _ensure_host(v_room.id);

  return query select v_room.id, v_player_id;
end $$;
```

> ⚠️ **재입장은 같은 기기에서만 된다.** 익명 세션의 `auth.uid()`로 원래 `player` 행을 찾기 때문이다. 앱을 재설치하면 uid가 바뀌어 재입장이 안 되고 QR을 다시 찍어야 한다. 실사용에서 문제되지 않는다고 판단했다.

### 5.5 `start_session()` — 방장이 시작

```sql
create or replace function public.start_session()
returns table (session_id uuid, seed int, starts_at timestamptz)
language plpgsql security definer set search_path = public as $$
declare
  v_player players%rowtype;
  v_room   rooms%rowtype;
  v_active int;
  v_session_id uuid;
  v_seed int;
  v_starts timestamptz;
  c_lead_sec    constant int := 5;   -- 카운트다운 여유
  c_min_players constant int := 2;   -- ※ 미확정. 설계 §5.2 참고
begin
  select * into v_player from players
   where auth_uid = auth.uid() and left_at is null limit 1;
  if not found then raise exception 'NOT_IN_ROOM'; end if;

  select * into v_room from rooms where id = v_player.room_id;
  if v_room.expires_at < now() then raise exception 'ROOM_EXPIRED'; end if;
  if v_room.host_player_id <> v_player.id then raise exception 'NOT_HOST'; end if;

  if exists (select 1 from sessions
              where room_id = v_room.id and ended_at is null) then
    raise exception 'SESSION_IN_PROGRESS';
  end if;

  select count(*) into v_active
    from players where room_id = v_room.id and left_at is null;
  if v_active < c_min_players then raise exception 'NOT_ENOUGH_PLAYERS'; end if;

  v_seed   := floor(random() * 2147483646)::int + 1;
  v_starts := now() + make_interval(secs => c_lead_sec);

  insert into sessions (room_id, seed, starts_at)
  values (v_room.id, v_seed, v_starts)
  returning id into v_session_id;

  return query select v_session_id, v_seed, v_starts;
end $$;
```

### 5.6 `submit_score(...)` — 판 결과 제출

```sql
create or replace function public.submit_score(
  p_session_id  uuid,
  p_round_index int,
  p_normalized  numeric,
  p_raw_score   int,
  p_tiebreak_ms int,
  p_finished    boolean
) returns void
language plpgsql security definer set search_path = public as $$
declare v_room_id uuid; v_player_id uuid;
begin
  select room_id into v_room_id from sessions
   where id = p_session_id and ended_at is null;
  if v_room_id is null then raise exception 'SESSION_NOT_ACTIVE'; end if;

  select id into v_player_id from players
   where room_id = v_room_id and auth_uid = auth.uid() and left_at is null;
  if v_player_id is null then raise exception 'NOT_IN_ROOM'; end if;

  insert into scores (session_id, player_id, round_index,
                      normalized, raw_score, tiebreak_ms, finished)
  values (p_session_id, v_player_id, p_round_index,
          least(greatest(p_normalized, 0), 100),   -- clamp
          p_raw_score, greatest(p_tiebreak_ms, 0), p_finished)
  on conflict (session_id, player_id, round_index) do nothing;
end $$;
```

`do nothing`이라 **첫 제출만 인정된다.** 점수를 다시 올려 갈아치우는 경로가 막힌다.

### 5.7 `end_session(session_id)` — 종합 판정

이 함수가 백엔드에서 가장 중요하다. **판정과 강퇴를 한 트랜잭션에서 처리한다.**

```sql
create or replace function public.end_session(p_session_id uuid)
returns table (player_id uuid, nickname text, avg_score numeric, penalized boolean)
language plpgsql security definer set search_path = public as $$
declare
  v_room_id uuid;
  v_caller  uuid;
  c_rounds    constant int     := 3;
  c_threshold constant numeric := 40;
  r record;
begin
  select room_id into v_room_id from sessions
   where id = p_session_id and ended_at is null;
  if v_room_id is null then raise exception 'SESSION_NOT_ACTIVE'; end if;

  select id into v_caller from players
   where room_id = v_room_id and auth_uid = auth.uid() and left_at is null;
  if v_caller is null then raise exception 'NOT_IN_ROOM'; end if;

  update sessions set ended_at = now() where id = p_session_id;
  update rooms set expires_at = now() + interval '2 hours' where id = v_room_id;

  -- 강퇴 전 상태로 결과를 먼저 확정한다
  create temp table _graded on commit drop as
  select p.id as player_id,
         p.nickname,
         round(coalesce(sum(s.normalized), 0) / c_rounds, 2) as avg_score
    from players p
    left join scores s
      on s.player_id = p.id and s.session_id = p_session_id
   where p.room_id = v_room_id and p.left_at is null
   group by p.id, p.nickname;

  for r in select * from _graded where avg_score < c_threshold loop
    perform _remove_player(r.player_id);
  end loop;

  return query
    select g.player_id, g.nickname, g.avg_score,
           (g.avg_score < c_threshold) as penalized
      from _graded g
     order by g.avg_score desc;
end $$;
```

**`avg()`가 아니라 `sum() / 3`인 이유.** `avg()`는 없는 행을 무시하므로, 한 판을 미제출한 사람이 나머지 두 판 평균으로 계산되어 유리해진다. `sum() / 3`이어야 미제출 판이 0점으로 흡수된다 — 설계 §4.9의 이탈자 처리가 이 한 줄에 걸려 있다.

**호출자를 방장으로 제한하지 않는다.** 방장 폰이 느리거나 백그라운드에 있을 수 있다. 방 멤버 누구나 호출할 수 있고, `ended_at is null` 조건 때문에 **먼저 도착한 한 번만 실행된다.**

### 5.8 `leave_room()` — "집에 갈래"

```sql
create or replace function public.leave_room()
returns void
language plpgsql security definer set search_path = public as $$
declare v_player_id uuid;
begin
  select id into v_player_id from players
   where auth_uid = auth.uid() and left_at is null limit 1;
  if v_player_id is null then return; end if;
  perform _remove_player(v_player_id);
end $$;
```

### 5.9 `set_session_period(minutes)` — 방장의 주기 설정

```sql
create or replace function public.set_session_period(p_minutes int)
returns void
language plpgsql security definer set search_path = public as $$
declare v_player players%rowtype;
begin
  if p_minutes not in (30, 45, 60) then raise exception 'BAD_PERIOD'; end if;

  select * into v_player from players
   where auth_uid = auth.uid() and left_at is null limit 1;
  if not found then raise exception 'NOT_IN_ROOM'; end if;

  update rooms set session_period_min = p_minutes
   where id = v_player.room_id and host_player_id = v_player.id;

  if not found then raise exception 'NOT_HOST'; end if;
end $$;
```

---

## 6. 서버에 타이머가 없다

이 설계에서 가장 중요한 성질이라 따로 적는다.

### 6.1 시간 판정은 전부 클라이언트가 한다

`start_session`이 `starts_at`을 **미래 시각으로** 발급하기 때문에, 알림이 몇백 ms 늦게 도착해도 출발선이 어긋나지 않는다. 각 폰은 그 시각까지 카운트다운하면 된다.

| 시간 | 기준 | 누가 계산 |
|---|---|---|
| 판 시작 | `sessions.starts_at` | 클라이언트 |
| 제한시간 | `starts_at + timeLimitSec` | 클라이언트 |
| 다음 세션까지 | 마지막 `ended_at + session_period_min` | 클라이언트 |
| 방 만료 | `rooms.expires_at` | 클라이언트가 표시, 서버가 검증 |

**클라이언트는 폰 시계가 아니라 서버 시각을 기준으로 삼아야 한다.** 접속 시 서버 시각과의 오차를 한 번 재서 보정한다.

### 6.2 만료된 방은 지연 정리한다

별도 배치를 두지 않는다. `join_room` / `rejoin_room`이 `expires_at`을 확인해서 지났으면 그 자리에서 삭제한다. 만료된 방이 DB에 잠깐 남는 것은 아무 문제가 되지 않는다.

cron을 안 붙이는 만큼 관리 대상이 줄어든다. 설계 §3.3의 "서버 관리 인력 불필요"가 실제로 이 모양이다.

> 방이 무한정 쌓이는 게 신경 쓰이면 나중에 `pg_cron`으로 하루 한 번 `delete from rooms where expires_at < now() - interval '1 day'`를 돌려도 된다. **처음부터 넣을 필요는 없다.**

---

## 7. Realtime

| 무엇 | 방식 | 대상 |
|---|---|---|
| 로비 참가자 목록 | **Presence** | 채널 `room:{code}` |
| 세션 시작 신호 | **Postgres Changes** | `sessions` INSERT |
| 점수 제출 현황 | **Postgres Changes** | `scores` INSERT |
| 세션 종료 · 벌칙 결과 | **Postgres Changes** | `sessions` UPDATE (`ended_at`) |
| 입장 · 퇴장 | **Postgres Changes** | `players` INSERT / UPDATE |

```sql
alter publication supabase_realtime add table sessions, scores, players;
```

**Broadcast 대신 Postgres Changes를 쓴다.** DB가 진실의 원천이라 메시지를 놓쳐도 다시 읽으면 복구된다. 술집 LTE에서 순단이 잦은 환경에서는 이 성질이 중요하다.

**Presence는 방의 생사 판정에 쓰지 않는다.** 폰이 절전으로 들어가면 Presence는 그 사람을 나간 것으로 본다. 방의 수명은 오직 `expires_at`이 정한다. Presence는 로비에 얼굴을 띄우는 용도뿐이다.

---

## 8. 클라이언트 호출 예시

```ts
// 익명 로그인 — 앱 최초 실행 시 1회
await supabase.auth.signInAnonymously()

// 방 만들기
const { data } = await supabase.rpc('create_room', { p_nickname: '덕현' })
// → [{ room_id, room_code, player_id }]

// 세션 시작 (방장)
const { data: s } = await supabase.rpc('start_session')
// → [{ session_id, seed, starts_at }]
//   seed에서 게임 3개와 각 판 시드를 클라이언트가 파생시킨다

// 점수 제출
await supabase.rpc('submit_score', {
  p_session_id: s.session_id,
  p_round_index: 0,
  p_normalized: 87.5,
  p_raw_score: 18,
  p_tiebreak_ms: 24310,
  p_finished: true,
})

// 종합 판정
const { data: result } = await supabase.rpc('end_session', {
  p_session_id: s.session_id,
})
// → [{ player_id, nickname, avg_score, penalized }, ...]
//   penalized인 사람은 이미 방에서 제거된 상태다
```

---

## 9. 에러 코드

RPC가 던지는 예외를 클라이언트가 분기해야 한다.

| 코드 | 의미 | 클라이언트 처리 |
|---|---|---|
| `AUTH_REQUIRED` | 익명 로그인 안 됨 | 재로그인 후 재시도 |
| `ROOM_NOT_FOUND` | 코드가 틀림 | "방을 찾을 수 없어요" |
| `ROOM_EXPIRED` | TTL 만료 | "방이 사라졌어요" + 로컬 코드 삭제 |
| `PLAYER_NOT_FOUND` | 재입장 대상 없음 | QR 재스캔 유도 |
| `NOT_IN_ROOM` | 방 멤버가 아님 | 홈으로 |
| `NOT_HOST` | 방장 전용 동작 | 버튼 숨김 (도달하면 버그) |
| `SESSION_IN_PROGRESS` | 이미 세션 진행 중 | 진행 중 화면으로 |
| `SESSION_NOT_ACTIVE` | 세션이 없거나 이미 종료 | 로비로 |
| `NOT_ENOUGH_PLAYERS` | 인원 부족 | "2명부터 할 수 있어요" |
| `BAD_PERIOD` | 주기 값이 30/45/60이 아님 | (도달하면 버그) |

---

## 10. 작업 순서

- [ ] Supabase 프로젝트 생성
- [ ] **Auth → Anonymous sign-in 활성화** (로그인 없이 `auth.uid()`를 얻기 위함)
- [ ] Supabase CLI 설치 → `supabase init`
- [ ] `supabase migration new init_schema` → §3 스키마 작성
- [ ] `supabase migration new rls` → §4 정책 작성
- [ ] `supabase migration new rpc` → §5 함수 작성
- [ ] Realtime publication 추가 (§7)
- [ ] `supabase db push`
- [ ] RN에서 `@supabase/supabase-js` 연결

> **마이그레이션은 반드시 파일로 관리하고 git에 넣는다.** 대시보드에서 손으로 만들면 나중에 재현이 안 되고, 팀원이 로컬에서 같은 DB를 못 세운다.

---

## 11. 규모 감각

테이블 4개, 공개 함수 8개, 내부 헬퍼 3개, Edge Function 0개.

**SQL에 익숙한 사람이면 2~3일, 처음이면 일주일 정도**의 분량이다. 풀타임 백엔드 담당자를 배정할 크기는 아니다. 프론트 담당 중 하나가 겸하거나, 초반에 한 명이 몰아서 끝내고 이후엔 손대지 않는 쪽이 맞다.

---

## 12. 아직 안 정해진 것

- **Supabase 최종 확정 여부** — 설계 §3.3에서 아직 권장 상태
- **세션당 판수** — 현재 3판. `end_session`의 `c_rounds` 상수. 하드코딩 대신 `rooms` 컬럼으로 뺄지 검토
- **세션 최소 인원** — 2명으로 제안, 미확정. `start_session`의 `c_min_players`
- **닉네임 중복 처리** — 현재 허용. 같은 이름 둘이면 화면에서 헷갈릴 수 있음
- **누적 통계 / 역대 랭킹** — 현 설계에서는 방이 삭제되면 `scores`도 cascade로 사라진다. 기록을 남기려면 별도 테이블과 보관 정책이 필요
