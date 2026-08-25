-- 집 가 — join_room에 남아있던 동일한 컬럼/변수 충돌 수정
-- joined_seq 계산 쿼리의 `where room_id = v_room.id`가 여전히 비한정 참조였다.

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

  select coalesce(max(p.joined_seq), 0) + 1 into v_seq
    from players p where p.room_id = v_room.id;

  insert into players (room_id, auth_uid, nickname, joined_seq)
  values (v_room.id, auth.uid(), p_nickname, v_seq)
  returning id into v_player_id;

  update rooms set expires_at = now() + interval '2 hours' where id = v_room.id;

  return query select v_room.id, v_player_id;
end $$;

revoke execute on function public.join_room(text, text) from public, anon;
grant  execute on function public.join_room(text, text) to authenticated;
