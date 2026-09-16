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
step_watchdog_check() {
  # The watchdog itself is installed by cloud-init, because cost protection
  # must not depend on this repository having been cloned. Its schedule is
  # checked here as well, so a broken one can be repaired by re-running this
  # script rather than only by rebuilding the instance.
  if ! systemctl is-enabled idle-shutdown.timer >/dev/null 2>&1; then
    echo 'idle watchdog timer is not enabled, enabling'
    systemctl enable --now idle-shutdown.timer
  fi

  # `systemctl ... | grep -q` 를 쓰지 않는다. grep -q 는 매치하자마자 파이프를
  # 닫고, 그러면 앞 명령이 SIGPIPE 로 죽어 pipefail 아래에서 141 이 된다.
  # 멀쩡히 동작하는 워치독이 실패로 보고된다.
  #
  # 그리고 is-enabled 는 확인하려던 것이 아니다. 멈춘 타이머도 enabled 로
  # 보인다. 다음 실행 시각이 잡혀 있는지가 진짜 질문이다.
  local next
  next=$(systemctl show idle-shutdown.timer -p NextElapseUSecRealtime --value)
  [ -n "$next" ] && [ "$next" != "0" ] && [ "$next" != "n/a" ]
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
  echo 'setup complete'
  exit 0
fi
echo "setup finished with failed steps: ${FAILED[*]}"
exit 1
