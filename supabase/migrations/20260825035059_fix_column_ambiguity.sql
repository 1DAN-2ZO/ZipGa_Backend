-- 집 가 — RETURNS TABLE 출력 컬럼명과 본문 컬럼 참조의 이름 충돌 수정
--
-- `returns table (room_id uuid, player_id uuid)`처럼 선언하면 PL/pgSQL이 함수 본문 안에
-- room_id/player_id라는 이름의 변수를 자동으로 만든다. 본문에서 테이블 별칭 없이
-- `where room_id = ...`라고 쓰면 "이게 그 변수냐, players.room_id 컬럼이냐" 충돌이 나서
-- 호출 시점에 42702(ambiguous column reference) 에러가 난다. CREATE FUNCTION 자체는
-- 통과하고 실제로 호출해야 드러나는 문제라 마이그레이션 적용만으로는 못 잡았다 — 트랜잭션
-- 테스트 호출에서 발견했다.
--
-- 대상: join_room(2곳), rejoin_room(1곳), end_session(1곳). 나머지 함수는 전수 검토 결과
-- 문제 없음(전부 v_ 접두 지역변수를 쓰거나 이미 테이블 별칭으로 한정돼 있음).

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

  select p.id into v_player_id from players p     -- 이미 이 방에 있으면 그대로
   where p.room_id = v_room.id and p.auth_uid = auth.uid() and p.left_at is null;
  if v_player_id is not null then
    return query select v_room.id, v_player_id;
    return;
  end if;

  update players set left_at = now()             -- 다른 방에 있었다면 정리
   where auth_uid = auth.uid() and left_at is null and players.room_id <> v_room.id;

  select coalesce(max(joined_seq), 0) + 1 into v_seq
    from players where room_id = v_room.id;

  insert into players (room_id, auth_uid, nickname, joined_seq)
  values (v_room.id, auth.uid(), p_nickname, v_seq)
  returning id into v_player_id;

  update rooms set expires_at = now() + interval '2 hours' where id = v_room.id;

  return query select v_room.id, v_player_id;
end $$;

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

  select p.id into v_player_id from players p    -- 원래 순번을 그대로 되찾음
   where p.room_id = v_room.id and p.auth_uid = auth.uid()
   order by p.joined_seq
   limit 1;
  if v_player_id is null then raise exception 'PLAYER_NOT_FOUND'; end if;

  update players set left_at = null where id = v_player_id;
  update rooms set expires_at = now() + interval '2 hours' where id = v_room.id;
  perform _ensure_host(v_room.id);

  return query select v_room.id, v_player_id;
end $$;

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

  for r in select * from _graded g where g.avg_score < c_threshold loop
    perform _remove_player(r.player_id);
  end loop;

  return query
    select g.player_id, g.nickname, g.avg_score,
           (g.avg_score < c_threshold) as penalized
      from _graded g
     order by g.avg_score desc;
end $$;

-- create or replace는 기존 EXECUTE 권한(ACL)을 보존하지만, 안전하게 명시적으로 재확인한다.
revoke execute on function public.join_room(text, text) from public, anon;
revoke execute on function public.rejoin_room(text)      from public, anon;
revoke execute on function public.end_session(uuid)      from public, anon;
grant  execute on function public.join_room(text, text) to authenticated;
grant  execute on function public.rejoin_room(text)      to authenticated;
grant  execute on function public.end_session(uuid)      to authenticated;
