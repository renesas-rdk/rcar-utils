#!/bin/bash
#
# rcar-deploy.sh - back up, rsync a fresh build to a running Sparrow Hawk, reboot,
#             and verify the board came back on the new kernel.
#
# The board is reached over ssh with password auth (sshpass), because the
# stock image ships ubuntu/ubuntu and has no key installed yet.
#
# Order matters and every step is guarded: nothing is copied before the local
# build verifies, nothing is overwritten before it is backed up, and the reboot
# only happens once the transfer succeeded.
#
# Usage:
#   ./rcar-deploy.sh --host 192.168.1.50
#   ./rcar-deploy.sh --host 192.168.1.50 --user ubuntu --password ubuntu
#   ./rcar-deploy.sh --host 192.168.1.50 --dry-run
#   ./rcar-deploy.sh --host 192.168.1.50 --no-reboot
#
# Password precedence: --password, then $RCAR_DEPLOY_PASSWORD, then a prompt.
# Prefer the env var or the prompt: an argument is visible in ps.
#
set -uo pipefail

DRIVER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# scripts/ -> repo root
RCAR_UTILS_DIR="$(cd "${DRIVER_DIR}/.." && pwd)"

KERNEL_DIR="${KERNEL_DIR:-${RCAR_UTILS_DIR}/linux-sh}"
WORKSPACE_DIR="${WORKSPACE_DIR:-${RCAR_UTILS_DIR}/workspace}"
FIT_OUTPUT_DIR="${FIT_OUTPUT_DIR:-${WORKSPACE_DIR}/fitimage}"
KERNEL_MODULES_OUTPUT_DIR="${KERNEL_MODULES_OUTPUT_DIR:-${WORKSPACE_DIR}/kernel-modules}"

HOST=""
USER_NAME="ubuntu"
PASSWORD=""
PORT=22
PREFIX=""
DRY_RUN=0
DO_REBOOT=1
DO_BACKUP=1
SKIP_VERIFY=0
REBOOT_WAIT=180

PASS=0
FAIL=0
ok()   { printf '  \033[32mok\033[0m    %s\n' "$*"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAIL=$((FAIL + 1)); }
note() { printf '        %s\n' "$*"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$*"; }
die()  { printf '\n\033[31mAborted:\033[0m %s\n' "$*" >&2; exit 1; }

usage() { sed -n '3,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

while [ $# -gt 0 ]; do
	case "$1" in
		--host)     HOST="${2:-}"; shift 2 ;;
		--user)     USER_NAME="${2:-}"; shift 2 ;;
		--password) PASSWORD="${2:-}"; shift 2 ;;
		--port)     PORT="${2:-}"; shift 2 ;;
		--prefix)   PREFIX="${2:-}"; shift 2 ;;
		--reboot-wait) REBOOT_WAIT="${2:-}"; shift 2 ;;
		--dry-run)  DRY_RUN=1; shift ;;
		--no-reboot) DO_REBOOT=0; shift ;;
		--no-backup) DO_BACKUP=0; shift ;;
		--skip-verify) SKIP_VERIFY=1; shift ;;
		-h|--help)  usage ;;
		*) echo "unknown option: $1" >&2; usage ;;
	esac
done

[ -n "$HOST" ] || { echo "--host is required" >&2; usage; }

if [ -z "$PASSWORD" ]; then
	PASSWORD="${RCAR_DEPLOY_PASSWORD:-}"
fi
if [ -z "$PASSWORD" ]; then
	read -r -s -p "Password for ${USER_NAME}@${HOST}: " PASSWORD
	echo
fi
[ -n "$PASSWORD" ] || die "no password given"

command -v sshpass >/dev/null 2>&1 || die "sshpass not installed (sudo apt-get install -y sshpass)"
command -v rsync   >/dev/null 2>&1 || die "rsync not installed"

# The board's host key changes when the image is reflashed, and this is a
# lab-network deploy tool, so host key checking would only ever produce a
# false alarm here. Keep the known_hosts file out of the way too.
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o LogLevel=ERROR -o ConnectTimeout=10 -p "${PORT}")

sshb() { sshpass -p "$PASSWORD" ssh "${SSH_OPTS[@]}" "${USER_NAME}@${HOST}" "$@"; }

# Run a command as root on the board. The stock user is a sudoer with a
# password, so feed it on stdin; -S makes sudo read it there. Falls through
# cleanly when the account is already root.
#
# The command is base64'd on the way over and decoded into "sh -c" on the far
# side. Passing it to sudo verbatim breaks on anything compound - "sudo if
# [ ... ]; then" is a syntax error, because sudo wants a program name, not a
# shell construct - and it also survives quotes in the payload.
sudob() {
	local b64
	b64=$(printf '%s' "$1" | base64 | tr -d '\n')
	sshb "CMD=\$(echo ${b64} | base64 -d); if [ \"\$(id -u)\" = 0 ]; then sh -c \"\$CMD\"; else echo '$PASSWORD' | sudo -S -p '' sh -c \"\$CMD\"; fi"
}

RSYNC_RSH="sshpass -p ${PASSWORD} ssh ${SSH_OPTS[*]}"

# Everything is rsynced into a staging directory under the login user's home,
# then moved into place by one privileged step.
#
# Going straight to /boot with --rsync-path="sudo rsync" does not work with a
# password sudo: rsync's stdin IS the protocol stream, so there is nowhere to
# feed the password without corrupting it. Staging first needs no privilege at
# all, and it keeps the window in which system files are half-updated down to
# a single local copy.
STAGE=".rcar-deploy-staging"

rsync_to() {
	local src="$1" dst="$2"
	if [ "$DRY_RUN" = 1 ]; then
		note "DRY-RUN rsync $src -> staging/${dst}"
		return 0
	fi
	rsync -az -e "$RSYNC_RSH" "$src" "${USER_NAME}@${HOST}:${STAGE}/${dst}"
}

#-----------------------------------------------------------------------------
head_ "Target"
printf '  %s@%s:%s\n' "${USER_NAME}" "${HOST}" "${PORT}"
[ -n "$PREFIX" ] && printf '  prefix: %s\n' "$PREFIX"
[ "$DRY_RUN" = 1 ] && printf '  \033[33mdry run - nothing will be written\033[0m\n'

#-----------------------------------------------------------------------------
# 1. Local build must be sound before anything leaves this machine.
#-----------------------------------------------------------------------------
REL=""
[ -f "${KERNEL_DIR}/include/config/kernel.release" ] &&
	REL=$(cat "${KERNEL_DIR}/include/config/kernel.release")
[ -n "$REL" ] || die "no kernel.release in ${KERNEL_DIR} - build the kernel first"

head_ "Local build"
ok "kernel release ${REL}"

if [ "$SKIP_VERIFY" = 0 ]; then
	if "${RCAR_UTILS_DIR}/scripts/rcar-driver.sh" verify >/tmp/rcar-verify.$$ 2>&1; then
		ok "rcar-driver.sh verify passed"
	else
		bad "rcar-driver.sh verify FAILED - not deploying"
		sed -n '/FAIL/p' /tmp/rcar-verify.$$ | head -10
		note "full output: /tmp/rcar-verify.$$"
		note "override with --skip-verify only if you know why it fails"
		exit 1
	fi
	rm -f /tmp/rcar-verify.$$
else
	note "verify skipped (--skip-verify)"
fi

FIT="${FIT_OUTPUT_DIR}/fitImage"
MODDIR="${KERNEL_MODULES_OUTPUT_DIR}/usr/lib/modules/${REL}"
[ -f "$FIT" ]    || die "no fitImage at ${FIT}"
[ -d "$MODDIR" ] || die "no module tree for ${REL} at ${MODDIR}"
ok "fitImage $(stat -c%s "$FIT") bytes"
ok "module tree ${REL}"

FIT_SUM=$(sha256sum "$FIT" | cut -d' ' -f1)

#-----------------------------------------------------------------------------
# 2. Reach the board.
#-----------------------------------------------------------------------------
head_ "Connect"
if ! sshb true 2>/tmp/rcar-ssh.$$; then
	bad "cannot ssh to ${USER_NAME}@${HOST}:${PORT}"
	note "$(head -3 /tmp/rcar-ssh.$$)"
	rm -f /tmp/rcar-ssh.$$
	exit 1
fi
rm -f /tmp/rcar-ssh.$$
ok "ssh ok"

RUNNING=$(sshb "uname -r" 2>/dev/null | tr -d '\r')
ok "board is running ${RUNNING:-unknown}"

if ! sudob "true" >/dev/null 2>&1; then
	bad "no root on the board (sudo failed for ${USER_NAME})"
	exit 1
fi
ok "root available"

#-----------------------------------------------------------------------------
# 3. Back up what we are about to overwrite.
#-----------------------------------------------------------------------------
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP="${PREFIX}/var/backups/rcar-deploy/${STAMP}"

if [ "$DO_BACKUP" = 1 ]; then
	head_ "Backup"
	if [ "$DRY_RUN" = 1 ]; then
		note "DRY-RUN would back up to ${BACKUP}"
	else
		# Only the fitImage and the module tree for this release are ever
		# overwritten, so those are what is worth keeping.
		sudob "mkdir -p '${BACKUP}'" || die "cannot create ${BACKUP}"
		sudob "if [ -f '${PREFIX}/boot/fitImage' ]; then cp -a '${PREFIX}/boot/fitImage' '${BACKUP}/fitImage'; fi" \
			|| die "backing up fitImage failed"
		sudob "if [ -d '${PREFIX}/usr/lib/modules/${REL}' ]; then tar czf '${BACKUP}/modules-${REL}.tar.gz' -C '${PREFIX}/usr/lib/modules' '${REL}'; fi" \
			|| die "backing up the module tree failed"
		sudob "uname -r > '${BACKUP}/previous-kernel-release'" >/dev/null 2>&1
		ok "backed up to ${BACKUP}"
		note "restore: sudo cp ${BACKUP}/fitImage /boot/fitImage && sudo reboot"
	fi
else
	head_ "Backup"
	note "skipped (--no-backup)"
fi

#-----------------------------------------------------------------------------
# 4. Transfer.
#-----------------------------------------------------------------------------
head_ "Transfer"
KM="${KERNEL_MODULES_OUTPUT_DIR}/usr/lib"

if [ "$DRY_RUN" = 0 ]; then
	sshb "mkdir -p ${STAGE}/boot ${STAGE}/modules ${STAGE}/firmware ${STAGE}/modules-load.d ${STAGE}/modprobe.d" \
		|| die "cannot create the staging directory on the board"
fi

# Trailing slashes are load-bearing: "$MODDIR" (no slash) copies the directory
# itself, "firmware/" copies its contents. Only the tree for THIS release is
# sent - syncing the modules/ parent would ship every stale release the
# workspace has accumulated.
rsync_to "$FIT" "boot/" || die "fitImage transfer failed"
ok "fitImage staged"

for f in "${FIT_OUTPUT_DIR}"/*.dtb "${FIT_OUTPUT_DIR}"/*.dtbo; do
	[ -e "$f" ] || continue
	rsync_to "$f" "boot/" || die "device tree transfer failed"
done
ok "device trees staged"

rsync_to "$MODDIR" "modules/" || die "module transfer failed"
ok "modules ${REL} staged"

for d in firmware modules-load.d modprobe.d; do
	[ -d "${KM}/${d}" ] || continue
	rsync_to "${KM}/${d}/" "${d}/" || die "${d} transfer failed"
	ok "${d} staged"
done

if [ "$DRY_RUN" = 1 ]; then
	head_ "Result"
	echo "  dry run complete - nothing was written."
	exit 0
fi

#-----------------------------------------------------------------------------
# 4b. Install from staging, as root.
#-----------------------------------------------------------------------------
head_ "Install"
# The module tree is merged, never replaced wholesale: when the board is
# already running this release, deleting the directory first would pull the
# modules out from under the running kernel. fitImage goes down as a temp file
# and is renamed, so an interrupted write cannot leave an unbootable stub.
INSTALL_CMD="set -e
mkdir -p '${PREFIX}/boot' '${PREFIX}/usr/lib/modules/${REL}' '${PREFIX}/usr/lib/firmware' '${PREFIX}/usr/lib/modules-load.d' '${PREFIX}/usr/lib/modprobe.d'
cp -a ~${USER_NAME}/${STAGE}/boot/fitImage '${PREFIX}/boot/.fitImage.new'
mv -f '${PREFIX}/boot/.fitImage.new' '${PREFIX}/boot/fitImage'
for f in ~${USER_NAME}/${STAGE}/boot/*.dtb ~${USER_NAME}/${STAGE}/boot/*.dtbo; do
  [ -e \"\$f\" ] && cp -a \"\$f\" '${PREFIX}/boot/'
done
cp -a ~${USER_NAME}/${STAGE}/modules/${REL}/. '${PREFIX}/usr/lib/modules/${REL}/'
cp -a ~${USER_NAME}/${STAGE}/firmware/. '${PREFIX}/usr/lib/firmware/'
cp -a ~${USER_NAME}/${STAGE}/modules-load.d/. '${PREFIX}/usr/lib/modules-load.d/'
cp -a ~${USER_NAME}/${STAGE}/modprobe.d/. '${PREFIX}/usr/lib/modprobe.d/'
sync"

if sudob "$INSTALL_CMD"; then
	ok "installed into ${PREFIX:-/}"
	# ~27 MB of it, and a stale copy would be misleading next time.
	# Only on success: on failure it is evidence.
	sshb "rm -rf ${STAGE}" >/dev/null 2>&1 && ok "staging cleaned"
else
	bad "install from staging failed"
	note "staging left at ~/${STAGE} on the board for inspection"
	exit 1
fi

#-----------------------------------------------------------------------------
# 5. Dependency list, natively on the board.
#-----------------------------------------------------------------------------
head_ "depmod"
# Native depmod on the board: no cross-architecture concerns, and no chance of
# a host/target path mismatch. Plain "depmod <rel>" searches /lib/modules,
# which is /usr/lib/modules on this usrmerged rootfs. Only a --prefix run needs
# -b, and that is a staging/test layout, not a board.
if sudob "depmod ${PREFIX:+-b '${PREFIX}'} ${REL}"; then
	ok "depmod ${REL}"
else
	bad "depmod failed on the board"
	note "modules will not resolve; fix before rebooting"
	exit 1
fi
sudob "sync" >/dev/null 2>&1

# Confirm the bytes that landed are the bytes we sent, before trusting a reboot.
REMOTE_SUM=$(sudob "sha256sum '${PREFIX}/boot/fitImage'" 2>/dev/null | awk '{print $1}' | tr -d '\r')
if [ "$REMOTE_SUM" = "$FIT_SUM" ]; then
	ok "fitImage checksum matches"
else
	bad "fitImage checksum mismatch (local ${FIT_SUM:0:12}, remote ${REMOTE_SUM:0:12})"
	note "do NOT reboot; re-run the transfer"
	exit 1
fi

#-----------------------------------------------------------------------------
# 6. Reboot and wait.
#-----------------------------------------------------------------------------
if [ "$DO_REBOOT" = 0 ]; then
	head_ "Result"
	echo "  transferred, not rebooted (--no-reboot)."
	echo "  the board still runs ${RUNNING} until it reboots."
	exit 0
fi

head_ "Reboot"
sudob "( sleep 1; reboot ) >/dev/null 2>&1 &" >/dev/null 2>&1
ok "reboot issued"

# Wait for the port to go away first, so a fast check does not see the
# pre-reboot sshd and declare success immediately.
port_open() { timeout 3 bash -c "echo > /dev/tcp/${HOST}/${PORT}" 2>/dev/null; }

i=0
while [ $i -lt 30 ]; do
	port_open || break
	sleep 1; i=$((i + 1))
done
note "board went down after ${i}s"

i=0
back=0
while [ $i -lt "$REBOOT_WAIT" ]; do
	if port_open && sshb true >/dev/null 2>&1; then back=1; break; fi
	sleep 3; i=$((i + 3))
done

if [ "$back" = 1 ]; then
	ok "board back after ~${i}s"
else
	bad "board did not come back within ${REBOOT_WAIT}s"
	note "check the serial console; restore with the backup at ${BACKUP}"
	exit 1
fi

#-----------------------------------------------------------------------------
# 7. Verify what actually booted.
#-----------------------------------------------------------------------------
head_ "Post-reboot verification"

NOW_REL=$(sshb "uname -r" 2>/dev/null | tr -d '\r')
if [ "$NOW_REL" = "$REL" ]; then
	ok "running ${NOW_REL}"
else
	bad "running ${NOW_REL}, expected ${REL}"
	note "U-Boot may have loaded a fitImage from a different partition or path"
fi

if sshb "test -s ${PREFIX}/usr/lib/modules/${REL}/modules.dep" 2>/dev/null; then
	ok "modules.dep present"
else
	bad "modules.dep missing for ${REL}"
fi

if sshb "test -f ${PREFIX}/usr/lib/firmware/rcar_gen4_pcie.bin" 2>/dev/null; then
	ok "PCIe PHY firmware present"
else
	bad "PCIe PHY firmware missing"
fi

TREES=$(sshb "ls -1 ${PREFIX}/usr/lib/modules 2>/dev/null | wc -l" 2>/dev/null | tr -d '\r')
if [ "${TREES:-0}" = "1" ]; then
	ok "one module tree on the board"
else
	note "${TREES} module trees on the board (older releases still installed)"
fi

# Not fatal: an overlay may legitimately not be selected on this board.
LOADED=$(sshb "lsmod 2>/dev/null | awk '{print \$1}' | tr '\n' ' '" 2>/dev/null | tr -d '\r')
[ -n "$LOADED" ] && note "loaded modules: ${LOADED}"

head_ "Result"
printf '  %d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -eq 0 ]; then
	printf '  backup kept at %s\n\n' "${BACKUP}"
else
	printf '  restore: sudo cp %s/fitImage /boot/fitImage && sudo reboot\n\n' "${BACKUP}"
fi
[ "$FAIL" -eq 0 ]
