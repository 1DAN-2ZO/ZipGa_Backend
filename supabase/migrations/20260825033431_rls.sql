-- 집 가 — RLS 정책
-- 명세: mdfile/백엔드_Supabase명세.md §4
--
-- 방침: 클라이언트는 읽기만 한다 (자기가 속한 방으로 범위 제한). 쓰기는 전부 RPC(security definer)를 거친다.
--
-- 보안 강화 (명세 대비 추가):
--   - 익명 로그인 사용자도 Postgres 상으로는 `authenticated` 롤이다 (anon 롤은 JWT가 아예 없는 요청).
--     이 앱은 모든 RPC 호출 전 익명 로그인을 강제하므로, anon 롤에는 테이블/함수 접근을 아예 주지 않는다.
--   - 정책에 `to authenticated`를 명시해 auth.role() 의존을 피한다 (deprecated, anonymous sign-in과 상호작용 시 오동작).

-- 재귀를 피하는 헬퍼: players 정책이 players를 참조하면 RLS가 무한 재귀한다.
create or replace function public.current_player_room()
returns uuid
language sql stable security definer set search_path = public
as $$
  select room_id from players
   where auth_uid = auth.uid() and left_at is null
   limit 1
$$;

-- RLS 정책 평가 시 authenticated 롤이 이 함수를 호출할 수 있어야 한다.
revoke execute on function public.current_player_room() from public;
grant  execute on function public.current_player_room() to authenticated;

alter table rooms    enable row level security;
alter table players  enable row level security;
alter table sessions enable row level security;
alter table scores   enable row level security;

create policy room_read on rooms for select
  to authenticated
  using (id = current_player_room());

create policy player_read on players for select
  to authenticated
  using (room_id = current_player_room());

create policy session_read on sessions for select
  to authenticated
  using (room_id = current_player_room());

create policy score_read on scores for select
  to authenticated
  using (session_id in (
    select id from sessions where room_id = current_player_room()
  ));

-- 클라이언트 직접 쓰기 차단
revoke insert, update, delete on rooms, players, sessions, scores
  from anon, authenticated;

-- anon(비로그인) 롤은 이 앱을 쓸 일이 없다 — 모든 접근은 익명 로그인(=authenticated 롤) 이후에만 일어난다.
revoke all on rooms, players, sessions, scores from anon;

-- RLS는 Realtime의 Postgres Changes에도 적용된다. 구독자는 자기 방의 변경만 받는다.
