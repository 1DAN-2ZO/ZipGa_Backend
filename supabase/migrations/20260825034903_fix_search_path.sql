-- 집 가 — gen_room_code의 mutable search_path 경고 수정
-- advisor(security)가 검출: public.gen_room_code에 search_path가 고정되어 있지 않음.
-- 이 함수는 테이블을 참조하지 않지만(순수 문자열 생성), 관례상 다른 함수들과 동일하게 고정한다.

create or replace function public.gen_room_code()
returns text language plpgsql set search_path = public as $$
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

revoke execute on function public.gen_room_code() from public, anon, authenticated;
