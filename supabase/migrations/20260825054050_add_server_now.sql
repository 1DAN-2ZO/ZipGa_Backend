-- 집 가 — server_now(): 클라이언트가 서버-폰 시계 오차를 보정하기 위한 함수
-- 명세: mdfile/백엔드_전달사항.md §1 (백엔드_Supabase명세.md §5.9 자리)
--
-- 방장이 아닌 참가자는 start_session()의 응답을 받지 못하고 Realtime으로만 세션 시작을
-- 알게 되므로, 각자 접속 시 이 함수를 한 번 호출해 폰 시계와 서버 시계의 차이를 구해야
-- starts_at까지 카운트다운을 정확히 맞출 수 있다.
--
-- 테이블을 전혀 참조하지 않으므로 anon(로그인 전)도 호출할 수 있게 열어둔다 — 데이터
-- 노출 위험이 없다.

create or replace function public.server_now()
returns timestamptz
language sql stable set search_path = public
as $$ select now() $$;

grant execute on function public.server_now() to anon, authenticated;
