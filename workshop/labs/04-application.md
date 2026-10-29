# Lab 04. 양 앱·같은 이미지·MI·사설 경로

[이전](03-build.md) · [목차](../README.md) · [다음: baseline](05-baseline.md)

현재 기본 경로는 앱까지 자동 배포합니다. 정상 환경에 수동 Secret/manifest를
다시 적용하지 않습니다. [환경 복원](01-infrastructure.md#새-터미널에서-복원) 후 조회합니다.

<a id="4-4-기본-경로-ready와-실제-이미지-확인"></a>

## 4-1. Ready와 정확한 이미지

```bash
for key in primary secondary; do
  aks_run "$key" 'kubectl -n drtest rollout status deployment/drtest-app --timeout=90s'
  aks_run "$key" 'kubectl -n drtest get pods -l app=drtest-app -o json' \
    | jq '{pods:[.items[] | {name:.metadata.name,image:.spec.containers[0].image,
        containers:[.status.containerStatuses[] | {ready,restartCount,imageID}]}]}'
  aks_run "$key" 'kubectl -n drtest get service drtest-app -o json' \
    | jq '{type:.spec.type,ip:.status.loadBalancer.ingress,ports:.spec.ports}'
done
tm_assert_online
```

양 Pod Ready, 같은 private ACR 이미지와 `release-<archive SHA256>` 태그,
실제 imageID, Service 공인 IP와 config의 지역 publicIp.address 일치를 확인합니다.
태그만 같고 imageID가 다른 상태를 동일 이미지로 제출하지 않습니다.
앱은 8000, Service/브라우저는 HTTP 80이며 NSG가 승인 CIDR/Traffic Manager probe를 허용합니다.
private AKS API를 public으로 열거나 금지된 Service annotation 조합을 추가하지 않습니다.

## 4-2. 연결 계약

지역 앱 `/api/info`와 화면의 FQDN/IP를 비교합니다.

| 서비스 | 두 앱의 설정 |
|---|---|
| Blob | 같은 계정 primary hostname, `STORAGE_READ_MODE=primary` |
| PG | 같은 writer alias, 기본 postgres DB |
| EH | 같은 Geo-DR alias. 활성화했는데 직접 namespace fallback은 오류 |
| Redis / Search | 각 앱 지역의 인스턴스/인덱스 |
| ACR | KRC 단일 private registry, 양 kubelet AcrPull |

`pe_region`/10.10.*·10.20.*는 **접근 PE의 위치**이며 backend primary의 실제 리전이 아닙니다.
관리 역할은 ARM/서비스 조회로 별도 확인합니다.
양 VNet 각각에서 양 EH namespace 접근이 가능해야 EH KRS 유지 + 앱 KRC 원복이 가능합니다.

## 4-3. 인증과 코드 읽기

- [Deployment](../../k8s/base/deployment.yaml)/[ServiceAccount](../../k8s/base/serviceaccount.yaml):
  WI label/ServiceAccount와 주입된 identity 사용. 토큰/전체 env를 출력하지 않음.
- [설정 생성](../../scripts/gen-app-config.sh): 비밀 없는 지역 설정, 동일한 안정 hostname.
- [앱 적용](../../scripts/app-apply.sh)/[자동 적용](../../scripts/apply-packaged-app.sh):
  테스트 PG/Redis Secret 전달. 운영용 비밀 관리 패턴을 주장하지 않음.
- [앱](../../app/main.py): PG/Redis TLS 검증, 실제 서비스 오류를 숨기지 않음.
- 이미지 pull은 앱 MI가 아니라 kubelet MI. 앱/샘플의 데이터 권한과 구별.

Secret YAML, `env`/`printenv`, Redis 키, projected token, kubeconfig 전체를 제출하지 않습니다.
로그도 공유 전 민감 정보를 검토합니다.

## 4-4. 업데이트/복구는 예외

실패한 실제 단계와 원인을 확인한 뒤 강사만 새 검증 패키지를
`deploy-local-package.ps1 -InfrastructureConfigPath <정확한-config>`로 앱 업데이트할 수 있습니다.
이 모드는 PG/Redis 전체 재배포가 아닙니다. 샘플을 명시적으로 생략했다면 그 검증은 제외합니다.
배포 중/DR 중 살아 있는 Job를 임의 삭제하거나 수동 manifest와 자동화를 동시에 실행하지 않습니다.

## 완료 게이트

- [ ] 양 Ready/실제 imageID·같은 이미지·고정 IP·TM 양 Online
- [ ] WI/AcrPull/테스트 Secret, 안정 hostname과 PE 위치 구별
- [ ] 다음 Lab에서 실제 데이터 확인. health만으로 정상 판정하지 않음
