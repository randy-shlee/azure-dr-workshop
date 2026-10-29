# Azure DR 워크숍 — 간단 과정

**같은 full 환경을 브라우저 중심으로 배우는 참가자 과정**입니다.
명령은 강사/지정 오퍼레이터 한 명만 실행하며 참가자 PC에는 Docker/CLI가 필요 없습니다.
코드·관리 평면을 더 자세히 보려면 [고급 과정](../workshop/README.md)을 사용합니다.

역할 구분 없이 진행하는 포털 경로는 [고객용 Step-by-Step](../Portal_DeployToAzure_lab/workshop/README.md)을 사용합니다.
기존 로컬 원클릭 경로는 유지합니다.

## 먼저 아키텍처 보기

![공식 Azure 아이콘으로 표현한 현재 배포 구성](../workshop/assets/architecture.svg)

[큰 그림과 서비스별 DR 설명](../workshop/architecture.md)을 먼저 읽습니다.
Storage는 계정 하나, EH는 metadata-only, Search는 독립 인덱스입니다.
두 앱이 살아 있어도 **99:1 라우팅은 아니며 TM Priority**입니다.

## 현재 기준과 배포 방법

- **로컬 v1.0.7 단일 명령**이 기본입니다. 공개 Deploy to Azure 버튼이 아닙니다.
- `drws1028c`에서 인프라 → 사설 이미지 → 양 앱 → 자동 10 GB 샘플/복제/읽기 →
  서비스 smoke → `Complete`까지 성공했습니다.
- 실제 Storage/PG/EH 전환·원복은 아직 실행하지 않았습니다.
  배포 성공과 DR 성공을 구별합니다. [실증 보고서](../workshop/releases/v1.0.7-validation.md)
- 공개 v1.0.3 버튼, 과거 Draft, cloud Automation 완료 화면을 현재 배포 기준으로 쓰지 않습니다.

## 진행 순서

| 순서 | 실습 | 참가자가 확인할 결과 |
|---|---|---|
| 00 | [시작하기](00-start.md) | 구독·prefix·허용 IP·비용·담당자·실습 범위 |
| 01 | [원클릭 배포](01-deploy.md) | 강사의 단일 명령과 `phase=Complete` |
| 02 | [준비 확인](02-ready.md) | 양 앱/같은 이미지, TM Enabled/Online, KRC/KRC |
| 03 | [앱·10 GB 테스트](03-test.md) | UUID 쓰기/읽기, 정확한 샘플·실제 보조 읽기·복제 fence |
| 04 | [DR 전환과 원복](04-dr.md) | 별도 승인 후 KRS 전환, KRC 앱 원복, EH KRS 유지 |
| 05 | [정리](05-cleanup.md) | 실제 삭제 또는 기한·비용이 명시된 보관 승인 |

배포/복제는 전날 준비를 권장합니다. 새 환경 실증은 약 49분이었지만 소요 시간 보장은 아닙니다.
Storage planned 전환·원복은 각각 수 시간도 허용하므로 수업 내 완료를 보장하지 않습니다.
사전 준비 환경은 **재배포하지 말고 완료 이력과 실제 상태를 관찰**합니다.

## 반드시 구별할 것

| 항목 | 의미 |
|---|---|
| 업로드 버튼 | 서버 생성 샘플 업로드/재개. PC 파일 선택 아님. 최대 decimal 10 GB |
| 샘플 데이터 확인 | 훈련 전 복제 probe. 자동 조회가 아니며 목록은 300초 캐시 |
| 앱 두 배지 | 응답 서버 리전 / Pod가 조회한 TM 안내 리전. backend primary 판정 아님 |
| EH 앱 읽기 | sequence metadata. 이벤트 본문 소비/replay 증거 아님 |
| KRC 앱 원복 | Storage/PG/TM 복귀. EH alias는 KRS 유지 |
| expiry | 태그. 자동 삭제/과금 중지 아님 |

테스트 전용 HTTP·승인 CIDR 안에서만 사용합니다. 운영 데이터/암호는 금지합니다.
full 환경의 알려진 비용 소계는 **약 USD 1,615.41/월**이고 사용량/임시 빌드 등은 별도입니다.
실제 장애 주입·성능·SLA/RTO/RPO 인증은 하지 않습니다.
강사는 [운영 안내](instructor.md), 실패 시 [문제 해결](../workshop/troubleshooting.md)을 사용합니다.
