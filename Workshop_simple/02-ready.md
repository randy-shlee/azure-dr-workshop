# 02. 준비 확인

[이전](01-deploy.md) · [목차](README.md) · [다음: 앱 테스트](03-test.md)

## 목표

자동 배포 완료, 현재 앱 정상, 실제 샘플 복제 완료를 각각 확인합니다.

## 할 일

1. **해당 로컬 작업의 config**에서 다음 주소를 확인합니다.

   | config 값 | 사용 |
   |---|---|
   | `trafficManager.fqdn` | 참가자가 계속 열어 둘 TM 주소 |
   | `primary.publicIp.fqdn` | KRC 직접 앱 |
   | `secondary.publicIp.fqdn` | KRS 직접 앱 |

2. 주소는 `http://`로 엽니다. 지역 앱에서 각각 응답 KRC/KRS를 확인합니다.
3. 포털 TM Endpoints에서 **KRC priority 1, KRS priority 2, 양쪽 Enabled/Online**을 봅니다.
4. TM 탭에서 **응답 리전 KRC / TM 안내 KRC**, 서비스 카드의 실제 FQDN/IP를 확인합니다.
5. 강사가 양 AKS Pod Ready·정확한 같은 이미지·고정 Service IP를
   [고급 Lab 04](../workshop/labs/04-application.md)로 확인합니다.
6. 다음 Lab에서 샘플을 조회합니다. `Complete`라도 `skip=false`와 실제 복제를 함께 확인합니다.

검증 예시 환경: <http://drws1028c-dr.trafficmanager.net/>.
내 팀의 주소는 반드시 해당 config를 사용하며 공유 환경을 허가 없이 전환하지 않습니다.

## 정상 상태

양 앱 Ready, 양 TM Online, TM 화면 KRC/KRC입니다.
private AKS의 일반 Kubernetes 화면을 참가자 PC에서 직접 열 수 있다고 가정하지 않습니다.
강사 조회는 AKS command invoke를 사용합니다.

## 안 되면 멈추기

앱 timeout이면 실제 브라우저 출구 IP와 허용 CIDR, HTTP/주소를 확인합니다.
`CheckingEndpoint`/`Degraded`/`Failed`는 준비 완료가 아닙니다.
현재 로컬 경로에서 없는 Automation/부트스트랩 ConfigMap을 만들거나 찾아다니지 않습니다.
PaaS public access를 열어 해결하지 않습니다.

## 완료 체크

- [ ] 지역 앱 KRC/KRS, TM KRC/KRC 확인
- [ ] 양 앱 같은 이미지·Ready·고정 IP, TM 양 Enabled/Online
- [ ] 실제 config와 샘플 게이트를 인프라 완료와 구별
