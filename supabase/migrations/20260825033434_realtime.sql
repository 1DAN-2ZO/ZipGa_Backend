-- 집 가 — Realtime publication
-- 명세: mdfile/백엔드_Supabase명세.md §7
--
-- Presence(로비 참가자 목록)는 채널 구독만으로 동작하며 publication 설정이 필요 없다.
-- Postgres Changes로 전달할 테이블만 publication에 추가한다:
--   sessions INSERT/UPDATE(ended_at) — 세션 시작 신호 · 종료/벌칙 결과
--   scores   INSERT               — 점수 제출 현황
--   players  INSERT/UPDATE        — 입장 · 퇴장
-- rooms는 Postgres Changes 대상이 아니므로 publication에 넣지 않는다.

alter publication supabase_realtime add table sessions, scores, players;
