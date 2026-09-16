# aws-rhel-vm

AWS 에 RHEL 개발 VM 을 띄우는 Terraform 과, 그것을 켜고 끄고 붙는 CLI.

[`aws-windows-vm`](../aws-windows-vm) 의 Linux 짝이다.
용도는 [`airgapped-windows-workstation`](../airgapped-windows-workstation) 의 Linux 판을 만드는 빌드 머신이다.
고객 폐쇄망이 RHEL 이면, 반입할 번들을 만들고 설치 절차를 리허설할 자리가 필요하다.

## 왜 Rocky 나 Alma 가 아니라 RHEL 인가

라이선스 요금을 시간당 0.0576 달러 더 낸다.
그만큼을 내는 이유는 리허설의 값어치가 **고객 환경과 얼마나 같은가**에 달려 있기 때문이다.

Rocky 와 Alma 는 바이너리 호환이지만 `subscription-manager` 가 없고, 리포 구성이 다르고, SELinux 정책 패키지의 버전도 어긋난다.
폐쇄망 반입에서 걸리는 문제는 대개 그런 자리에서 나온다.
바이너리 호환은 우리가 만든 것이 도는지를 보장하지만, 절차가 도는지는 보장하지 않는다.

리허설이 아니라 그냥 Linux 개발 박스가 필요한 것이라면 이 저장소는 과하다.
Rocky 를 쓰거나 [`aws-windows-vm`](../aws-windows-vm) 의 구성을 Amazon Linux 로 바꾸는 편이 싸다.

## 비용

AWS Pricing API 로 확인한 `c6i.xlarge`, `us-east-1` 기준이다.

| | 시간당 | 24시간 | 6h × 22일 |
|---|---|---|---|
| RHEL | USD 0.2276 | USD 166 / 월 | USD 30 / 월 |
| 일반 Linux | USD 0.1700 | USD 124 / 월 | USD 22 / 월 |
| (참고) Windows | USD 0.3540 | USD 258 / 월 | USD 47 / 월 |

차액 0.0576 이 RHEL 라이선스다.
정지해 두면 디스크와 Elastic IP 만 남아 월 12 달러 남짓이다.

## 무엇이 만들어지는가

| | |
|---|---|
| 인스턴스 | `c6i.xlarge`, 4 vCPU / 8 GiB, RHEL 9.8 |
| 디스크 | 100 GiB gp3, 암호화 |
| 접속 | 키 기반 SSH, `ec2-user` |
| 예비 접속 | SSM Session Manager. 22 번 포트도 허용 IP 도 타지 않는다 |
| 네트워크 | 전용 VPC, 지정한 주소에서만 SSH |
| 비용 통제 | 유휴 워치독, CloudWatch 백스톱, 예산 알림 |

## 비용 통제를 세 겹으로 두는 이유

Windows 쪽에서 값을 치르고 배운 것이다.

게스트 안의 워치독이 **조용히 멈춘 적이 있다**.
작업은 등록되어 있었고 상태도 정상이었는데 다음 실행 예정만 비어 있었다.
그 사이 인스턴스가 37 시간을 돌아 14 달러가 나갔다.

그래서 세 겹이다.

**유휴 워치독** (systemd timer, 5 분마다)
SSH 세션, Session Manager 세션, 코어당 부하를 본다.
셋 다 조용하면 분을 세고, `idle_shutdown_minutes` 에 닿으면 정지시킨다.
부하를 보는 것은 SSH 로 시작한 긴 빌드가 연결이 끊겼다고 죽지 않게 하기 위해서다.
부팅 후 15 분은 유예한다.

**CloudWatch 백스톱** (기본 2 시간)
CPU 가 계속 낮으면 게스트와 무관하게 정지시킨다.
게스트 밖에 있으므로 안에서 무슨 일이 나든 동작한다.
평소에는 워치독이 먼저 움직여서 이건 발동하지 않는다.

**예산 알림**
위 둘이 다 놓쳐도 사람이 알게 된다.
`budget_alert_email` 을 비워 두면 만들지 않는다.

지출을 제한하는 장치가 제한 대상 안에 단일 장애점을 두면 안 된다.

## 만들기

```sh
cd terraform
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars          # 공개키, 내 주소, 저장소 URL
terraform init
terraform apply
```

명명된 프로필을 쓴다면 먼저 내보낸다. `vm` CLI 도 같은 값을 본다.

```sh
export AWS_PROFILE=your-profile
```

첫 부팅은 5 분 안팎이다.
SSH 는 1 분 안에 열린다. 패키지 설치가 끝나기 한참 전이다.

```sh
export PATH="$PWD/../bin:$PATH"
vm status          # bootstrap 항목이 complete 가 되는 것을 본다
vm ssh
```

### AMI 가 생각보다 낮은 버전으로 잡힐 때

`rhel_version = "9"` 은 **가장 최근 발행된** RHEL 9 이미지를 고른다.
발행일 기준이지 버전 기준이 아니다.
Red Hat 은 구버전 점 릴리스를 재빌드하므로, 9.8 이 있는데도 9.6 이 잡히는 일이 실제로 있다.

점 릴리스까지 지정하는 편이 낫다.

```hcl
rhel_version = "9.8"
```

무엇이 잡혔는지는 `ami_name` 출력으로 확인한다.

## 매일 쓰기

```sh
vm up          # 켜고 주소 출력
vm ssh         # 꺼져 있으면 켜고 접속
vm down        # 정지
vm status      # 상태, 주소, 부트스트랩 진행, 허용 대역
vm allow-ip    # 지금 붙어 있는 망을 허용
vm console     # Session Manager 셸. SSH 가 안 될 때
vm logs        # 첫 부팅 로그
```

`vm` 은 Terraform 상태가 아니라 `Name` 태그로 인스턴스를 찾는다.
그래서 체크아웃도 상태 파일도 없는 장비에서 자격증명만 있으면 동작한다.

```sh
ln -s "$PWD/bin/vm" ~/.local/bin/vm
```

## 구성 고치기

`bootstrap/cloud-init.yaml.tftpl` 은 **첫 부팅에만** 돈다.
여기 넣는 것은 SSH 와 유휴 워치독처럼 저장소를 못 받아와도 살아 있어야 하는 것들뿐이다.
고치면 다음 재생성부터 반영된다.

나머지는 `bootstrap/setup.sh` 에 있다.
패키지 목록, git 기본값, 셸 프로필이 여기다.
멱등이라 다시 실행해도 된다.

```sh
cd /opt/setup && git pull && sudo ./bootstrap/setup.sh
```

`git pull` 의 출력을 읽는다.
로컬에서 고친 파일이 있으면 pull 이 중단되는데, 그 뒤의 setup 은 옛 체크아웃으로 멀쩡히 성공하므로 반영된 것처럼 보인다.

## 유휴 워치독 확인

```sh
watchdog-status    # systemd 타이머의 다음 실행 시각
idle-state         # 지금까지 센 유휴 분
```

`systemctl is-enabled` 가 아니라 **다음 실행 시각**을 본다.
멈춘 타이머도 enabled 로 보인다.

끄려면 `idle_shutdown_minutes = 0`.

## 정리

```sh
cd terraform
terraform destroy
aws ssm delete-parameter --name /rhelvm/bootstrap-status --region us-east-1
```

Parameter Store 항목은 Terraform 이 아니라 인스턴스가 만든 것이라 `destroy` 로 지워지지 않는다.
