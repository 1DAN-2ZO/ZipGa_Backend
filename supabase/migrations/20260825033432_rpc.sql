-- 집 가 — RPC 함수 8개 + 내부 헬퍼 3개
-- 명세: mdfile/백엔드_Supabase명세.md §5
--
-- 내부 헬퍼(gen_room_code, _ensure_host, _remove_player)는 공개 RPC가 이미 인증/권한을
-- 확인한 뒤에만 호출한다. 파일 끝에서 이 세 함수의 EXECUTE 권한을 PUBLIC에서 회수해
-- 클라이언트가 직접 호출(예: _remove_player로 임의 유저 강퇴)하지 못하게 막는다.

-- ============================================================
-- 5.1 내부 헬퍼
-- ============================================================

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

-- ============================================================
-- 5.2 create_room(nickname) — 방 만들기
-- ============================================================
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

-- ============================================================
-- 5.3 join_room(code, nickname) — QR 스캔 입장
-- ============================================================
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

-- ============================================================
-- 5.4 rejoin_room(code) — "아직 안 갈래"
-- ============================================================
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

-- ⚠️ 재입장은 같은 기기에서만 된다. 익명 세션의 auth.uid()로 원래 player 행을 찾기 때문이다.

-- ============================================================
-- 5.5 start_session() — 방장이 시작
-- ============================================================
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

-- ============================================================
-- 5.6 submit_score(...) — 판 결과 제출
-- ============================================================
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

-- do nothing이라 첫 제출만 인정된다. 점수를 다시 올려 갈아치우는 경로가 막힌다.

-- ============================================================
-- 5.7 end_session(session_id) — 종합 판정
-- 판정과 강퇴를 한 트랜잭션에서 처리한다.
-- ============================================================
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

-- avg()가 아니라 sum() / 3인 이유: avg()는 없는 행을 무시하므로 한 판 미제출자가
-- 나머지 두 판 평균으로 계산되어 유리해진다. sum() / 3이어야 미제출 판이 0점으로 흡수된다.
-- 호출자를 방장으로 제한하지 않는다 — 방 멤버 누구나 호출 가능하고,
-- ended_at is null 조건 때문에 먼저 도착한 한 번만 실행된다.

-- ============================================================
-- 5.8 leave_room() — "집에 갈래"
-- ============================================================
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

-- ============================================================
-- 5.9 set_session_period(minutes) — 방장의 주기 설정
-- ============================================================
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

-- ============================================================
-- 실행 권한 정리
-- ============================================================

-- 내부 헬퍼: PUBLIC(anon·authenticated 포함)에서 회수한다.
-- 같은 오너가 소유한 다른 security definer 함수 내부 호출은 계속 동작한다
-- (security definer 컨텍스트에서는 함수 오너 권한으로 실행되므로).
revoke execute on function public.gen_room_code()          from public;
revoke execute on function public._ensure_host(uuid)        from public;
revoke execute on function public._remove_player(uuid)      from public;

-- 공개 RPC 8개: anon(비로그인)에는 필요 없다 — 이 앱은 익명 로그인 후 authenticated로만 호출한다.
revoke execute on function public.create_room(text)                                   from public;
revoke execute on function public.join_room(text, text)                               from public;
revoke execute on function public.rejoin_room(text)                                    from public;
revoke execute on function public.start_session()                                      from public;
revoke execute on function public.submit_score(uuid, int, numeric, int, int, boolean)  from public;
revoke execute on function public.end_session(uuid)                                    from public;
revoke execute on function public.leave_room()                                         from public;
revoke execute on function public.set_session_period(int)                              from public;

grant execute on function public.create_room(text)                                   to authenticated;
grant execute on function public.join_room(text, text)                               to authenticated;
grant execute on function public.rejoin_room(text)                                    to authenticated;
grant execute on function public.start_session()                                      to authenticated;
grant execute on function public.submit_score(uuid, int, numeric, int, int, boolean)  to authenticated;
grant execute on function public.end_session(uuid)                                    to authenticated;
grant execute on function public.leave_room()                                         to authenticated;
grant execute on function public.set_session_period(int)                              to authenticated;
