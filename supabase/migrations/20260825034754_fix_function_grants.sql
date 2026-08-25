-- 집 가 — 함수 실행 권한 수정
--
-- 원인: 이 프로젝트는 `postgres` 롤에 대해 `alter default privileges ... grant execute on
-- functions to anon, authenticated, service_role`이 설정되어 있어, 마이그레이션으로 새
-- 함수를 만들 때마다 anon·authenticated에 EXECUTE가 명시적으로 자동 부여된다.
-- 이전 마이그레이션(20260825033431_rls.sql, 20260825033432_rpc.sql)의
-- `revoke execute ... from public`은 PUBLIC 경유 권한만 지울 뿐, 이 명시적 grant는
-- 지우지 못했다. anon·authenticated를 이름으로 지정해 다시 회수한다.
--
-- ⚠️ 앞으로 함수를 새로 추가할 때도 기본적으로 anon·authenticated에 EXECUTE가 자동
-- 부여된다는 점을 기억할 것. 내부 헬퍼는 매번 명시적으로 회수해야 한다.

-- 내부 헬퍼 3개: 클라이언트가 직접 호출할 이유가 없다.
revoke execute on function public.gen_room_code()          from public, anon, authenticated;
revoke execute on function public._ensure_host(uuid)        from public, anon, authenticated;
revoke execute on function public._remove_player(uuid)      from public, anon, authenticated;

-- RLS 정책이 참조하는 헬퍼: anon은 차단, authenticated만 유지.
revoke execute on function public.current_player_room() from public, anon;
grant  execute on function public.current_player_room() to authenticated;

-- 공개 RPC 8개: anon(비로그인)은 차단, authenticated만 호출 가능.
revoke execute on function public.create_room(text)                                   from public, anon;
revoke execute on function public.join_room(text, text)                               from public, anon;
revoke execute on function public.rejoin_room(text)                                    from public, anon;
revoke execute on function public.start_session()                                      from public, anon;
revoke execute on function public.submit_score(uuid, int, numeric, int, int, boolean)  from public, anon;
revoke execute on function public.end_session(uuid)                                    from public, anon;
revoke execute on function public.leave_room()                                         from public, anon;
revoke execute on function public.set_session_period(int)                              from public, anon;

grant execute on function public.create_room(text)                                   to authenticated;
grant execute on function public.join_room(text, text)                               to authenticated;
grant execute on function public.rejoin_room(text)                                    to authenticated;
grant execute on function public.start_session()                                      to authenticated;
grant execute on function public.submit_score(uuid, int, numeric, int, int, boolean)  to authenticated;
grant execute on function public.end_session(uuid)                                    to authenticated;
grant execute on function public.leave_room()                                         to authenticated;
grant execute on function public.set_session_period(int)                              to authenticated;
