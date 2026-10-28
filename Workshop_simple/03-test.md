# 03. 앱 버튼으로 테스트

[이전](02-ready.md) · [목차](README.md) · [다음: 전환과 원복](04-dr.md)

## 목표

앱 생존 상태뿐 아니라 실제 서비스 쓰기·읽기와 Storage 보조 읽기를 확인합니다.

## 할 일

1. TM 주소의 앱에서 **지금 새로고침**을 누릅니다. 평시 두 배지는 KRC이고
   **10초 자동 새로고침**은 켜 둡니다. 서비스 카드의 정상/실패/disabled를 확인합니다.
2. **쓰기 테스트**를 한 번 누르고 UUID·UTC와 서비스별 결과를 기록합니다.
3. **읽기 테스트**를 누르고 실제 반환값을 확인합니다.
4. **샘플 데이터 확인**을 누르고 다음을 확인합니다.
5. 결과와 두 배지가 보이도록 스크린샷을 저장합니다. 암호·키는 포함하지 않습니다.

| 확인 대상 | 정상 기준 / 해석 |
|---|---|
| PG/Redis/Blob/Search 쓰기·읽기 | 활성 서비스별 실제 성공. partial/error는 전체 성공 아님 |
| Event Hubs 읽기 | 파티션별 sequence number. 같은 메시지 본문을 소비/대조했다는 뜻 아님 |
| Search count | 비동기 반영 가능. 양 리전 인덱스는 독립적 |
| 샘플 파일/용량 | 기본 large 8개, small 2,000개, 약 9.953GiB |
| Last Sync Time / Manifest 종료 / 복제 완료 | null/pending이 아니며 완료 근거를 강사가 확인 |
| secondary 1MiB 실제 읽기 | 성공. 파일 목록만 있는 것을 읽기 성공으로 간주하지 않음 |

샘플 목록은 **300초 캐시**되며 자동 새로고침으로 반복 조회하지 않습니다.
업로드 직후 값이 같지 않으면 5분 뒤 샘플 버튼을 다시 누릅니다.
실제 배포 설정이 기본과 다르면 Outputs의 sampleData 값을 기준으로 합니다.

## 정상 상태

활성 서비스의 쓰기/읽기가 성공하고, 샘플 복제와 secondary 실제 읽기가 확인됩니다.
lite의 EH/Redis/Search는 disabled가 정상이며 해당 서비스 검증은 제외로 적습니다.

| 서비스 | 이번 실습의 DR 의미 |
|---|---|
| PostgreSQL / Event Hubs geo | 이후 planned switchover / promotion |
| Storage | KRC primary 유지, KRS secondary 읽기. 계정 failover 아님 |
| Redis | active geo. PG와 같은 primary 승격 절차 아님 |
| AI Search | 양 리전 독립 인덱스. 자동 geo 복제를 가정하지 않음 |

## 안 되면 멈추기

쓰기 실패를 해결하려고 버튼을 계속 누르지 않습니다. 쓰기는 분산 트랜잭션이 아니며
부분 성공과 EH 재시도 중복이 있을 수 있습니다. UI 오류·서비스명·UTC만 강사에게 전달합니다.
샘플 미완료면 DR 단계는 보류합니다. 개인 PC의 Storage Browser를 위해 public access를 열지 않습니다.

## 완료 체크

- [ ] 활성 서비스별 쓰기/읽기 결과와 UUID/UTC 기록
- [ ] 샘플 수·용량·복제와 secondary 실제 읽기 확인
- [ ] disabled/partial/error를 구별하고 평시 증거 보관
