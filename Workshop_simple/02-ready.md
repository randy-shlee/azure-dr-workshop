# 02. 준비 확인

[이전](01-deploy.md) · [목차](README.md) · [다음: 앱 테스트](03-test.md)

## 목표

배포 성공, 양쪽 앱 준비, 샘플 복제 완료를 구별합니다.

## 할 일

1. 구독 **Deployments → 실제 배포 → Outputs → config**에서 다음 값을 찾습니다.

   | 값 | 사용할 곳 |
   |---|---|
   | trafficManager.fqdn | 참가자 앱: `http://<FQDN>/` |
   | primary.publicIp.fqdn / secondary.publicIp.fqdn | KRC/KRS 앱 각각 확인 |
   | bootstrap.accountName / bootstrap.jobId | Automation 계정과 실행 Job 확인 |

2. **Resource groups → rg-팀prefix-global → 해당 Automation 계정 → Jobs**에서
   위 jobId를 찾습니다. Status, Output, Errors를 확인합니다. 재실행하지 않습니다.
3. **Traffic Manager 프로필 → Endpoints**에서 양 endpoint가 Enabled/Online인지 확인합니다.
   KRC priority 1, KRS priority 2가 평시 구성입니다.
4. KRC/KRS 개별 앱을 새 탭으로 열어 응답 리전이 각각 KRC/KRS인지 확인합니다.
   그다음 TM 주소를 열고 이후 실습에 사용할 탭으로 남겨 둡니다.
5. 강사에게 샘플 완료 상태를 확인받습니다. 필요할 때만 KRC AKS **Run command**에서
   다음 짧은 조회를 실행합니다. 해당 기능/권한이 없으면 강사에게 조회를 맡깁니다.

```bash
kubectl -n drtest get configmap workshop-bootstrap-status -o yaml
```

| 확인값 | 의미 |
|---|---|
| Automation Completed | 양 앱 Ready·고정 IP·TM 상태를 자동화가 확인. 샘플은 대기 가능 |
| status의 phase: ApplicationReady | 앱 준비 완료. 샘플 완료 아님 |
| status의 phase: Complete | 샘플을 skip했거나 복제/실제 읽기까지 확인 |

이 과정은 **skipSampleData=false**이므로 강사가 skip 여부와 bootstrap Job 완료도 확인합니다.
Complete만 보고 샘플을 생략한 환경을 복제 성공이라고 기록하지 않습니다.

## 정상 상태

TM 탭에서 **응답한 서버 리전 KRC / Traffic Manager 안내 리전 KRC**가 보입니다.
KRC는 파란색, KRS는 주황색입니다. 샘플은 다음 Lab의 버튼으로 다시 확인합니다.

## 안 되면 멈추기

Failed/Suspended/timeout/오류는 준비 완료가 아닙니다. ConfigMap NotFound도 완료가 아닙니다.
앱이 열리지 않으면 주소의 **http**, 현재 브라우저 공인 IP와 허용 CIDR을 강사가 확인합니다.
공개 PaaS 접근을 열거나 Job을 중복 실행하지 마세요. private AKS의 일반 리소스 화면에
PC가 직접 접속할 수 있다고 가정하지 않습니다.

## 완료 체크

- [ ] Automation Completed, 양 앱 응답, TM 양 endpoint Enabled/Online
- [ ] TM 탭에서 KRC/KRC 확인
- [ ] 샘플 진행/완료 상태를 앱 준비와 구별해 기록
