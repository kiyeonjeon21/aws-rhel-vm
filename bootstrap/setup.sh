#!/usr/bin/env bash
#
# Development environment for the RHEL VM.
#
# Run once automatically at first boot by cloud-init, and safe to run again by
# hand after pulling a change:
#
#     cd /opt/setup && git pull && ./bootstrap/setup.sh
#
# Every step is idempotent. Nothing here may fail in a way that costs SSH
# access, which is why SSH and the idle watchdog live in cloud-init and not in
# this file.

set -uo pipefail

TARGET_USER="${TARGET_USER:-ec2-user}"
TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORKSPACE="$TARGET_HOME/work"

# Edit this list, commit, and either rebuild the VM or re-run this script.
PACKAGES=(
  git
  tar
  gzip
  unzip
  jq
  tmux
  vim-enhanced
  bash-completion
  ripgrep
  fzf
  podman
  make
  gcc
  python3-pip
)

FAILED=()

# 부트스트랩 상태를 Parameter Store 에 남긴다. `vm status` 가 이것을 읽는다.
#
# 손으로 다시 돌렸을 때도 갱신해야 한다. 그러지 않으면 첫 부팅의 실패가
# 계속 남아, 이미 고친 문제를 고치지 않은 것처럼 보인다. 오래된 정보를
# 보여주는 상태 필드는 없느니만 못하다.
publish_status() {
  command -v aws >/dev/null 2>&1 || return 0
  # IMDSv2 를 강제해 두었으므로 토큰 없이 메타데이터를 읽을 수 없다.
  # 토큰을 먼저 받는다. 이 한 줄이 빠지면 리전을 못 구해 상태가 조용히
  # 발행되지 않는다.
  local token region
  token=$(curl -s --max-time 2 -X PUT http://169.254.169.254/latest/api/token \
    -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' 2>/dev/null || true)
  region=$(curl -s --max-time 2 -H "X-aws-ec2-metadata-token: $token" \
    http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null || true)
  [ -n "$region" ] || return 0
  aws ssm put-parameter --name "/${VM_NAME:-rhelvm}/bootstrap-status" \
    --type String --value "$1" --overwrite --region "$region" >/dev/null 2>&1 || true
}

step() {
  local name="$1"; shift
  echo ""
  echo "=== $name ==="
  if "$@"; then
    echo "--- $name ok"
  else
    echo "--- $name FAILED (exit $?)"
    FAILED+=("$name")
  fi
}

# ---------------------------------------------------------------------------
step_workspace() {
  install -d -o "$TARGET_USER" -g "$TARGET_USER" "$WORKSPACE"
}

# ---------------------------------------------------------------------------
step_packages() {
  # RHEL on AWS reaches Red Hat's RHUI mirrors without a subscription, because
  # the Hourly AMI carries the licence. `dnf` therefore works out of the box,
  # unlike a RHEL box you install yourself.
  #
  # EPEL is where ripgrep and fzf live. Enabling it here rather than assuming
  # it, because a customer RHEL box very often does not have it.
  dnf install -y "https://dl.fedoraproject.org/pub/epel/epel-release-latest-$(rpm -E %rhel).noarch.rpm" || true
  dnf install -y "${PACKAGES[@]}"
}

# ---------------------------------------------------------------------------
step_git_defaults() {
  git config --system init.defaultBranch main
  git config --system pull.rebase true
  # --replace-all, not --add. With --add this appends a duplicate on every run
  # and after a handful of runs the config is mostly this one line repeated.
  git config --system --replace-all safe.directory '*'
}

# ---------------------------------------------------------------------------
step_shell_profile() {
  cat > /etc/profile.d/rhelvm.sh <<'PROFILE'
# Installed by bootstrap/setup.sh.

export EDITOR=vim

alias ll='ls -alF'
alias g=git

idle-state() {
  local f=/var/lib/rhelvm/idle-minutes
  if [ -r "$f" ]; then
    echo "$(cat "$f") idle minutes counted"
  else
    echo 'watchdog has not counted an idle period yet'
  fi
}

watchdog-status() {
  systemctl list-timers idle-shutdown.timer --no-pager
}
PROFILE
  chmod 0644 /etc/profile.d/rhelvm.sh
}

# ---------------------------------------------------------------------------
# 다음 실행이 실제로 잡혀 있는지 확인한다.
#
# systemctl is-enabled 로는 부족하다. 멈춘 타이머도 enabled 로 보인다.
# Windows 쪽에서 정확히 그 이유로 인스턴스가 37 시간을 돌았다.
#
# `systemctl ... | grep -q` 도 쓰지 않는다. grep -q 는 매치하자마자 파이프를
# 닫고, 앞 명령이 SIGPIPE 로 죽어 pipefail 아래에서 141 이 된다. 멀쩡한
# 워치독이 실패로 보고된다.
#
# 시계가 둘이라는 것도 함정이다. OnBootSec 로 걸린 타이머는 단조 시계를 쓰므로
# NextElapseUSecRealtime 이 비어 있다. 한쪽만 보면 정상인데도 실패한다.
timer_has_next_run() {
  local prop value
  for prop in NextElapseUSecMonotonic NextElapseUSecRealtime; do
    value=$(systemctl show idle-shutdown.timer -p "$prop" --value)
    case "$value" in
      ''|0|n/a|infinity) continue ;;
      *) return 0 ;;
    esac
  done
  return 1
}

step_watchdog_check() {
  # The watchdog itself is installed by cloud-init, because cost protection
  # must not depend on this repository having been cloned. Its schedule is
  # checked here as well, so a broken one can be repaired by re-running this
  # script rather than only by rebuilding the instance.
  if ! systemctl is-enabled idle-shutdown.timer >/dev/null 2>&1; then
    echo 'idle watchdog timer is not enabled, enabling'
    systemctl enable --now idle-shutdown.timer
  fi

  timer_has_next_run
}

# ---------------------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
  echo "이 스크립트는 root 로 실행해야 한다: sudo $0" >&2
  exit 1
fi

step 'workspace'      step_workspace
step 'packages'       step_packages
step 'git-defaults'   step_git_defaults
step 'shell-profile'  step_shell_profile
step 'watchdog-check' step_watchdog_check

echo ""
if [ ${#FAILED[@]} -eq 0 ]; then
  publish_status 'complete'
  echo 'setup complete'
  exit 0
fi
joined=$(IFS=,; echo "${FAILED[*]}")
publish_status "complete-with-failures:$joined"
echo "setup finished with failed steps: ${FAILED[*]}"
exit 1
