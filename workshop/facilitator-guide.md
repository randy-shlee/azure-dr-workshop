# 강사 일정과 개입 게이트

[고급 과정](README.md) · [단일 오퍼레이터 준비](../Workshop_simple/instructor.md) · [문제 해결](troubleshooting.md)

## 수업 설계

2~4명/팀, 환경 하나당 오퍼레이터 한 명을 권장합니다.
full 환경은 팀 수만큼 별도 과금하므로 참가자 수만큼 무조건 복제하지 않습니다.
간단 과정과 고급 과정은 같은 환경을 설명 깊이만 다르게 사용합니다.

## D-7: 범위 승인

- [ ] 구독/리전 용량·정책, prefix, 주소 대역, 브라우저 실제 출구 CIDR
- [ ] 비용(알려진 소계 약 USD 1,615.41/월/환경), 보관/삭제 담당자와 기한
- [ ] full 기본. lite/skip이면 제외한 검증을 명시
- [ ] 테스트 전용 HTTP, 운영 데이터/암호 미사용
- [ ] 임시 mTLS Docker 2376 및 정리, AKS command invoke/역할 할당 권한
- [ ] 별도 DR 승인, 수 시간 가능한 Storage planned 전환, EH fail-forward와 원래 이벤트 보존/replay
- [ ] 실제 장애 주입/99:1/SLA/RTO/RPO 인증이 아님

## D-1: 최종 전달본으로 리허설

1. [아키텍처](architecture.md)와 [검증 보고서](releases/v1.0.7-validation.md)를 설명합니다.
   실증 환경의 성공과 이번 팀 환경의 성공을 구별합니다.
2. 공개 repo clone 대신 전달한 수정본 `source`와 원본 `deployment-tools.zip`을 준비합니다.
3. [로컬 배포](local-package.md) 한 명령, 보호된 암호, 새 prefix를 사용합니다.
   기존 PG/Redis 전체 템플릿 덮어쓰기는 하지 않습니다.
4. `Complete` 이후 양 앱의 이미지/IP/Online, 10 GB/실제 읽기/fence, 데이터 쓰기/읽기를 재확인합니다.
5. DR를 실제 리허설했다면 이 환경의 EH alias는 KRS에 남습니다.
   첫 KRC baseline 환경인 것처럼 다음 수업에 재사용하지 않습니다.
6. 임시 엔진/네트워크/새 grant/인증서 정리를 확인하고 문서와 실제 outputs를 대조합니다.

새 전체 배포 한 번은 약 49분이었지만 지역 용량/복제/정책에 따라 더 오래 걸립니다.
인프라·복제·Storage 전환 대기를 수업 시간표에 고정된 몇 분으로 넣지 않습니다.

## 당일

| 게이트 | 확인 | 실패 시 |
|---|---|---|
| 배포 | 대상/해시/승인, 실제 작업 단계 | 재배포하지 말고 실패 단계 진단 |
| 앱 | 두 Ready/정확한 같은 이미지/IP/TM Online | CIDR/Private Link/권한/로그 |
| 샘플 | 2,008개/10 GB/읽기/Last Sync Time fence | DR 보류, 필요 시 캐시 300초 대기 |
| 첫 DR | Storage Live/Planned, PG pair, EH synchronized KRC, TM baseline | 시작 금지 |
| KRS 전환 | Storage → EH → PG → TM, 실제 역할과 데이터 | CSV/현재 역할 확인, 무작정 반대 실행 금지 |
| KRC 앱 원복 | Storage → PG → EH active 확인 → TM, EH KRS 유지 | 부분 복구를 전체 원복으로 기록 금지 |
| 종료 | 프로브 기본값 + 삭제/유료 보관 책임 | 종료 미완료로 인계 |

동일 UUID를 비교하는 동안 다른 사용자가 쓰기 버튼을 누르지 않도록 조율합니다.
브라우저 로그는 해당 탭의 최근 20건이며 UTC를 CSV에 따로 남깁니다.
TM 안내/응답 리전의 차이는 DNS 캐시만의 정밀 지연이 아닙니다.

## 평가와 종료

배포 성공, 평시 확인, DR 실제 수행, 관찰만 수행을 각각 표시합니다.
UI의 EH read는 metadata이지 payload 소비가 아닙니다. Search count는 정확한 문서 대조가 아닙니다.
실증 보고서에 있는 강한 검증을 이번 수업에서 재실행했다고 꾸미지 않습니다.

[Lab 07](labs/07-cleanup.md)의 paired EH 사전 해제와 RG/managed RG 확인을 따릅니다.
`drws1028c`는 승인된 보관 환경이며 무단 삭제하지 않습니다.
남은 오류·기한·소유자·비용 담당자와 다음 날 실제 비용 확인까지 인계합니다.
