#!/bin/sh
# End-to-end test of `port.sh -i`: a user sets up the local repository, installs Salaat First from it,
# the daily job later builds a new release, and the user upgrades. Runs in rootless podman with systemd.
# Usage: test/e2e.sh deb|rpm|pacman [MSIX]   (MSIX: seeds -i, so the first build downloads almost nothing)
# There is rarely a newer Store release to test with, so the first build is stamped 0.1 and the
# "new release" is the real one, with two of its jars changed in the job's saved copy.
# Isolation: rootless podman runs everything in your user namespace, so the container can't reach your
# ttys, kernel settings or binfmt; SYS_ADMIN only applies inside it and lets systemd sandbox the job.
# Never use --privileged here: systemd then starts gettys on the host's ttys.
set -eu
fmt=$1 msix=${2:+$(readlink -f "$2")}
src=$(cd "$(dirname "$0")/.." && pwd) c=sfe2e-$fmt
case $fmt in
  deb) base=docker.io/library/debian:trixie
    inst='apt-get update && apt-get install -y --no-install-recommends systemd systemd-sysv curl ca-certificates python3 openssl sudo && rm -rf /var/lib/apt/lists/*'
    install='sudo apt-get update && sudo apt-get install -y salaat-first'
    upgrade='sudo apt-get update && sudo apt-get upgrade -y'
    version='dpkg-query -W -f "\${Version}" salaat-first' ;;
  rpm) base=docker.io/library/fedora:latest
    inst='dnf -y install systemd rpm-build createrepo_c curl python3 openssl sudo shadow-utils util-linux && dnf clean all'
    install='sudo dnf install -y salaat-first'
    upgrade='sudo dnf upgrade -y'
    version='rpm -q --qf "%{VERSION}" salaat-first' ;;
  pacman) base=docker.io/library/archlinux:latest
    inst='pacman -Syu --noconfirm --needed base-devel python openssl curl && pacman -Scc --noconfirm'
    install='sudo pacman -Sy --noconfirm salaat-first'
    upgrade='sudo pacman -Syu --noconfirm'
    version='pacman -Q salaat-first | cut -d" " -f2 | cut -d- -f1' ;;
  *) sed -n '2,8p' "$0"; exit 2 ;;
esac
step() { printf '\n===== %s\n' "$*"; }
x() { podman exec "$c" sh -c "$1"; }      # as root: the test harness
u() { podman exec "$c" su - u -c "$1"; }  # as the user
check() { [ "$1" = "$2" ] && echo "PASS: $3 ($1)" || { echo "FAIL: $3: got '$1', want '$2'"; exit 1; }; }

step "image $c"
mask='getty@.service console-getty.service serial-getty@.service systemd-logind.service systemd-binfmt.service
  proc-sys-fs-binfmt_misc.automount systemd-sysctl.service systemd-modules-load.service systemd-udevd.service
  systemd-udev-trigger.service systemd-firstboot.service systemd-networkd.service systemd-resolved.service systemd-timesyncd.service'
ctx=$(mktemp -d); trap 'rmdir "$ctx"' EXIT
printf 'FROM %s\nRUN %s\nRUN useradd -m u && echo "u ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/u && chmod 440 /etc/sudoers.d/u\nRUN systemctl mask %s\n' \
  "$base" "$inst" "$(echo $mask)" | podman build -q --network host -t "$c" -f - "$ctx" | tail -1
podman rm -f "$c" >/dev/null 2>&1 || true
# Host network: this machine has no pasta or slirp4netns for podman's own.
podman run -d --name "$c" --network host --cap-add SYS_ADMIN -v "$src:/src:ro" ${msix:+-v "$msix:/msix/x64.msix:ro"} \
  "$c" /usr/lib/systemd/systemd >/dev/null
for i in $(seq 30); do x 'systemctl is-system-running' 2>/dev/null | grep -qE 'running|degraded' && break; sleep 1; done

step "harness: stamp the first build 0.1, as the previous release"
x 'cp -r /src /tmp/prev && sed -i "/^ver=\$(grep/a ver=0.1" /tmp/prev/port.sh && grep -n "^ver=" /tmp/prev/port.sh'

step "user: sudo port.sh -i ${msix:+/msix/x64.msix}"
u "cd ~ && sudo /tmp/prev/port.sh -i ${msix:+/msix/x64.msix}" 2>&1 | grep -v '#'
check "$(x 'systemctl is-enabled salaat-first-update.timer')" enabled "timer enabled"
x 'systemctl list-timers --no-pager salaat-first-update.timer | head -2'

step "user: install from the local repository"
u "$install" 2>&1 | tail -4
check "$(x "$version")" 0.1 "installed version"

step "harness: a new release appears (the real version; two of its jars changed)"
x 'cp /src/port.sh /var/lib/salaat-first/port/port.sh && rm /var/lib/salaat-first/last
   cd /var/lib/salaat-first/msix && set -- $(find app -name "*.jar" -size +100k | sort | head -2)
   printf XXXX | dd of="$1" bs=1 seek=70000 conv=notrunc 2>/dev/null && rm "$2"'
# The job may only write its own directory and its private /tmp, and can't see /home.
x 'mkdir -p /srv/probe /etc/systemd/system/salaat-first-update.service.d && chown salaat-first /srv/probe
   printf "[Service]\nExecStartPre=-/bin/sh -c \"touch /srv/probe/w /var/tmp/sf-probe; ls -A /home > /var/lib/salaat-first/probe\"\n" \
     > /etc/systemd/system/salaat-first-update.service.d/probe.conf && systemctl daemon-reload'

step "systemd runs the daily job (what the timer starts)"
x 'systemctl start salaat-first-update.service; journalctl -o cat -u salaat-first-update.service --no-pager | grep -vE "#|^$" | tail -8'
check "$(x 'systemctl show -p Result --value salaat-first-update.service')" success "job result"
check "$(x 'test -f /var/lib/salaat-first/probe && echo ran; ls /srv/probe; ls /var/tmp/sf-probe 2>/dev/null; cat /var/lib/salaat-first/probe')" ran \
  "sandbox: /srv read-only, private /var/tmp, /home hidden"
x 'rm -r /etc/systemd/system/salaat-first-update.service.d /var/lib/salaat-first/probe && systemctl daemon-reload; ls /var/lib/salaat-first/repo'

step "user, later: update and upgrade"
u "$upgrade" 2>&1 | tail -4
check "$(x "$version")" "$(x 'grep -o "app.version=[0-9.]*" /opt/salaat-first/salaat-first | cut -d= -f2')" "upgraded to the app's version"
check "$(x 'cd /opt/salaat-first && while read -r j; do [ -f "app/$j" ] || echo "missing $j"; done < classpath.txt
  jre/bin/java -version >/dev/null 2>&1 && echo ok')" ok "every classpath jar present, bundled Java runs"

step "the job again: nothing new"
x 'systemctl start salaat-first-update.service; journalctl -o cat -u salaat-first-update.service --no-pager | tail -1'
u "$upgrade" 2>&1 | tail -2
podman rm -f "$c" >/dev/null
echo "DONE $fmt"
