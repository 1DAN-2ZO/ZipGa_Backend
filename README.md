# 집 가 — Backend (Supabase)

술자리 인원이 QR로 한 방에 모여 미니게임으로 순위를 가리고, 파장 때 카카오T로 이어주는 모바일 앱의 백엔드.

- 서버 언어 없음 — 전부 **SQL / PL-pgSQL** (Supabase Postgres + RLS + RPC)
- Edge Function **0개**
- 게임 진행 중 네트워크 통신 없음 — 각 폰이 독립 실행, 판이 끝날 때 점수만 서버로 제출

설계 배경은 [`mdfile/집가_설계정리.md`](mdfile/집가_설계정리.md), [`mdfile/2026-08-25-파장흐름-design.md`](mdfile/2026-08-25-파장흐름-design.md) 참고. 백엔드 스펙 원문은 [`mdfile/백엔드_Supabase명세.md`](mdfile/백엔드_Supabase명세.md).

## 스키마

| 테이블 | 역할 |
|---|---|
| `rooms` | 술자리 하나. QR 코드, TTL(2시간), 세션 주기 |
| `players` | 방 참가자. `left_at`으로 soft delete, `joined_seq`로 방장 승계 판정 |
| `sessions` | 미니게임 3판 묶음. 서버가 발급한 `seed`로 게임 선정과 문제를 파생 |
| `scores` | 판별 점수. `(session_id, player_id, round_index)` PK로 재제출 차단 |

RLS: 클라이언트는 **자기가 속한 방만 읽기** 가능. 쓰기는 전부 `security definer` RPC를 거친다.

## RPC

| 함수 | 용도 |
|---|---|
| `create_room(nickname)` | 방 만들기 |
| `join_room(code, nickname)` | QR 스캔 입장 |
| `rejoin_room(code)` | "아직 안 갈래" 재입장 |
| `start_session()` | 방장이 세션 시작 (시드 발급) |
| `submit_score(...)` | 판 결과 제출 |
| `end_session(session_id)` | 종합 판정 — 평균 `normalizedScore < 40`인 인원을 같은 트랜잭션에서 강퇴 |
| `leave_room()` | "집에 갈래" 자발적 귀가 |
| `set_session_period(minutes)` | 방장의 세션 주기 설정 (30/45/60) |
| `server_now()` | 서버 시각 반환 — 클라이언트가 폰 시계와의 오차를 보정할 때 접속 시 1회 호출 |

내부 헬퍼(`gen_room_code`, `_ensure_host`, `_remove_player`)는 클라이언트가 직접 호출할 수 없도록 `EXECUTE` 권한을 차단해뒀다.

## 마이그레이션

`supabase/migrations/` — 순서대로 적용된다.

1. `init_schema` — §3 스키마
2. `rls` — §4 RLS 정책
3. `rpc` — §5 RPC 8개 + 내부 헬퍼 3개
4. `realtime` — §7 Realtime publication
5~8. 검증 과정에서 발견한 버그 수정 (함수 실행 권한 누락, `search_path` 미고정, `RETURNS TABLE` 출력 컬럼명과 본문 변수명 충돌)
9. `add_server_now` — 클라이언트 시계 보정용 `server_now()` 추가

### 로컬 개발 환경 세팅

```bash
supabase login
supabase link --project-ref <project-ref>
supabase db push        # 마이그레이션 적용
supabase db push --dry-run   # 미리보기만
```

새 마이그레이션을 추가할 땐 반드시 `supabase migration new <설명>`으로 파일을 만들고, **대시보드에서 직접 스키마를 바꾸지 않는다.**

## 프론트엔드 연동 (supabase-js)

```ts
import { createClient } from '@supabase/supabase-js'

const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY)

// 앱 최초 실행 시 1회 — 익명 로그인 (이후 모든 RPC는 이 세션으로 호출된다)
await supabase.auth.signInAnonymously()

// 접속 시 1회 — 서버-폰 시계 오차 보정
const { data: serverNow } = await supabase.rpc('server_now')
const clockOffsetMs = new Date(serverNow).getTime() - Date.now()

// 방 만들기
const { data: room } = await supabase.rpc('create_room', { p_nickname: '덕현' })
// room[0] → { room_id, room_code, player_id }

// QR 스캔 입장
const { data: joined } = await supabase.rpc('join_room', {
  p_code: room[0].room_code,
  p_nickname: '철수',
})
// joined[0] → { room_id, player_id }

// 방장이 세션 시작
const { data: session, error } = await supabase.rpc('start_session')
if (error) {
  // error.message가 'NOT_HOST'처럼 코드 그대로 온다 (Postgres 접두사 P0001: 은 없음)
  handleRpcError(error.message)
}
// session[0] → { session_id, seed, starts_at }
// seed에서 게임 3개 + 각 판 시드를 클라이언트가 직접 파생시킨다 (서버는 추가로 보내지 않음)

// 점수 제출
await supabase.rpc('submit_score', {
  p_session_id: session[0].session_id,
  p_round_index: 0,
  p_normalized: 87.5,
  p_raw_score: 18,
  p_tiebreak_ms: 24310,
  p_finished: true,
})

// 종합 판정 — 방 멤버 누구나 호출 가능, 먼저 도착한 한 번만 실제로 실행된다
const { data: result } = await supabase.rpc('end_session', {
  p_session_id: session[0].session_id,
})
// result → [{ player_id, nickname, avg_score, penalized }, ...]
// penalized === true인 사람은 이 호출 안에서 이미 방에서 제거된 상태다

// 집에 갈래 — 응답을 받은 뒤에 카카오T 딥링크를 연다 (순서를 지킬 것, §6.2)
await supabase.rpc('leave_room')
```

### Realtime 구독

입장 직후부터 자기 방의 변경만 받는다 (RLS가 Postgres Changes에도 그대로 적용됨).

```ts
supabase
  .channel(`room:${roomCode}`)
  .on('postgres_changes',
    { event: 'INSERT', schema: 'public', table: 'sessions', filter: `room_id=eq.${roomId}` },
    ({ new: s }) => { /* 세션 시작 신호 — s.starts_at까지 카운트다운 */ }
  )
  .on('postgres_changes',
    { event: 'UPDATE', schema: 'public', table: 'sessions', filter: `room_id=eq.${roomId}` },
    ({ new: s }) => { /* s.ended_at이 채워짐 — end_session 결과를 화면에 반영 */ }
  )
  .on('postgres_changes',
    { event: '*', schema: 'public', table: 'players', filter: `room_id=eq.${roomId}` },
    ({ new: p }) => { /* 입장/퇴장 — p.left_at 변화로 판정 */ }
  )
  .on('postgres_changes',
    { event: 'INSERT', schema: 'public', table: 'scores', filter: `session_id=eq.${sessionId}` },
    ({ new: s }) => { /* 다른 플레이어의 점수 제출 현황 */ }
  )
  .subscribe()
```

로비 참가자 목록은 별도 **Presence** 채널로 관리한다. Presence는 절전·순단에 취약하므로 **방의 생사 판정에는 쓰지 않는다** — 그 기준은 오직 `rooms.expires_at`이다 (§7).

에러 코드 전체 목록은 [`mdfile/백엔드_Supabase명세.md`](mdfile/백엔드_Supabase명세.md) §9 참고.

## 알려진 제약

- `join_room` / `rejoin_room`의 만료 방 지연 삭제는 예외 발생 시 트랜잭션이 롤백돼 실제로 삭제가 커밋되지 않는다. 설계상 허용된 트레이드오프(§6.2)이며, 필요해지면 `pg_cron`으로 별도 정리한다.
- 재입장은 같은 기기(같은 익명 `auth.uid()`)에서만 가능하다.
