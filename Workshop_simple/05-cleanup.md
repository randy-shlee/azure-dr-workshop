# 05. 정리와 보관

[이전](04-dr.md) · [목차](README.md) · [강사 상세](../workshop/labs/07-cleanup.md)

## 목표

실제 삭제 또는 명시적인 유료 보관 승인까지 책임을 인계합니다.
탭 닫기/배포 이력 삭제/expiry 태그는 리소스 정리가 아닙니다.

## 할 일

1. UUID·UTC·역할·이미지·관측 CSV/스크린샷을 승인된 팀 저장소에 보관합니다.
   암호/키/Secret YAML/인증서/토큰은 포함하지 않습니다.
2. 강사가 데이터 원복과 프로브 복구, **EH KRS 유지** 여부와 미완료 사항을 기록합니다.
3. **보관한다면** 환경·소유자·기한·추가 비용·종료 담당자를 적습니다.
   검증 환경 `drws1028c`는 요청대로 보관 중이므로 참가자가 임의 삭제하지 않습니다.
4. **폐기 승인한 환경만** 구독과 정확한 세 RG, 두 AKS managed RG, 보호할 이벤트를 확인합니다.
5. EH가 아직 paired이면 양 namespace가 모두 폐기 대상인지 확인한 뒤 현재 Primary의
   **Geo-recovery → alias → Break pairing**을 실행합니다.
   남은 alias도 삭제하고 양 namespace에서 alias가 사라졌는지 확인합니다.
   이미 fail-forward로 연결이 끊겼다면 역전환하지 않습니다.
   공유/보관할 상대가 연결되어 있으면 중단합니다.
6. 포털에서 승인한 정확한 RG를 삭제하거나 강사가 상세 정리 스크립트를 실행합니다.
   스크립트는 별도 EH 폐기 확인 후 pairing 해제·alias 삭제를 검증하고 RG 삭제를 시작합니다.
   삭제가 끝난 뒤 managed RG까지 없어졌는지 확인합니다.

현재 로컬 배포는 cloud Automation/custom bootstrap role/구독 예산을 만들지 않습니다.
다른 배포 경로의 잔여물이 **실제로 있는 경우에만** 별도로 확인하며 없는 역할을 만들지 않습니다.

## 안 되면 멈추기

`MetadataDRCannotDeleteWhenAliasPresentConflict`이면 EH alias가 남아 있는지 확인합니다.
승인된 양 대상의 pairing 해제와 남은 alias 삭제를 확인한 후 실패한 RG 삭제만 재시도합니다.
권한/잠금/정책 오류나 목록을 못 보는 상태를 삭제 완료라고 쓰지 않습니다.
AKS/PG만 중지해도 Redis/Search/EH/ACR/Storage/PE/IP 등은 계속 과금됩니다.

## 완료 체크

- [ ] 증거 보관, 비밀 값 제외
- [ ] 실제 RG/managed RG 삭제 또는 소유자·기한·비용이 명시된 보관
- [ ] 남은 오류와 다음 날 비용 확인 책임 인계
