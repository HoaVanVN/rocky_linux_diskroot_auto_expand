#!/usr/bin/env bash
# =============================================================================
#  setup-disk-expand.sh — Self-contained installer for disk-expand service
#  Rocky Linux 9 / RHEL 9 — LVM + XFS layout (VG "rl": root, swap, home)
#
#  Run as root — ONE command installs everything:
#    sudo bash setup-disk-expand.sh
#
#  What this does:
#    1. Installs required packages (cloud-utils-growpart, lvm2, xfsprogs)
#    2. Writes /usr/local/bin/disk-expand.sh
#    3. Writes /etc/disk-expand.conf
#    4. Writes /etc/systemd/system/disk-expand.service
#    5. Enables the service (runs on every boot)
#    6. Runs a dry-run to verify everything works
# =============================================================================

set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[✓]${NC} $*"; }
info() { echo -e "${CYAN}[i]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
die()  { echo -e "${RED}[✗] ERROR: $*${NC}" >&2; exit 1; }
hdr()  { echo -e "\n${BOLD}${CYAN}══ $* ══${NC}"; }

# ── Must be root ──────────────────────────────────────────────────────────────
[[ "$EUID" -eq 0 ]] || die "Must run as root:  sudo bash $0"

# ── OS check ─────────────────────────────────────────────────────────────────
if ! grep -qiE 'rocky|rhel|centos|almalinux' /etc/os-release 2>/dev/null; then
  warn "This script is tested on Rocky/RHEL 9. Proceeding anyway..."
fi

# ═════════════════════════════════════════════════════════════════════════════
hdr "Step 1: Install required packages"
# ═════════════════════════════════════════════════════════════════════════════

PKGS=()
command -v growpart   &>/dev/null || PKGS+=(cloud-utils-growpart)
command -v pvresize   &>/dev/null || PKGS+=(lvm2)
command -v xfs_growfs &>/dev/null || PKGS+=(xfsprogs)
command -v resize2fs  &>/dev/null || PKGS+=(e2fsprogs)

if [[ ${#PKGS[@]} -gt 0 ]]; then
  info "Installing: ${PKGS[*]}"
  dnf install -y "${PKGS[@]}" -q || die "dnf install failed"
  ok "Packages installed"
else
  ok "All required packages already present"
fi

# ═════════════════════════════════════════════════════════════════════════════
hdr "Step 2: Write /usr/local/bin/disk-expand.sh"
# ═════════════════════════════════════════════════════════════════════════════

cat > /usr/local/bin/disk-expand.sh << 'MAIN_SCRIPT'
#!/usr/bin/env bash
# =============================================================================
#  disk-expand.sh v2 — Auto-expand disk on Rocky Linux 9 (LVM + XFS/EXT4)
#  Runs at every boot via systemd. Safe to run multiple times (idempotent).
#
#  Tested layout (Rocky 9 default):
#    sda3 → VG "rl" → rl-root (/), rl-swap ([SWAP]), rl-home (/home)
#
#  Key behaviors:
#    - growpart & pvresize run ONCE per physical disk/PV (not per LV)
#    - SWAP LVs are NEVER resized
#    - Free VG space is distributed proportionally among mounted LVs
#    - Config file /etc/disk-expand.conf overrides default behavior
#
#  Usage:
#    Automatic : managed by systemd (disk-expand.service)
#    Manual    : sudo /usr/local/bin/disk-expand.sh [--dry-run] [--verbose]
# =============================================================================

set -euo pipefail

# ── Constants ─────────────────────────────────────────────────────────────────
LOGFILE="/var/log/disk-expand.log"
LOCK="/var/run/disk-expand.lock"
CONF="/etc/disk-expand.conf"
DRY_RUN=false
VERBOSE=false

# ── Parse args ────────────────────────────────────────────────────────────────
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true  ;;
    --verbose) VERBOSE=true  ;;
    --help)
      echo "Usage: $0 [--dry-run] [--verbose]"
      echo "  --dry-run   Show what would be done, no changes made"
      echo "  --verbose   Extra debug output"
      echo ""
      echo "Config file: $CONF"
      exit 0 ;;
  esac
done

# ── Logging ───────────────────────────────────────────────────────────────────
log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO]  $*" | tee -a "$LOGFILE"; }
warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN]  $*" | tee -a "$LOGFILE" >&2; }
err()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*" | tee -a "$LOGFILE" >&2; }
dbg()  { $VERBOSE && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG] $*" | tee -a "$LOGFILE" || true; }

run() {
  local desc="$1"; shift
  if $DRY_RUN; then
    log "[DRY-RUN] $desc: $*"
    return 0
  fi
  log "Running: $desc → $*"
  if ! "$@" >> "$LOGFILE" 2>&1; then
    warn "Command returned non-zero (non-fatal): $*"
    return 1
  fi
  return 0
}

# ── Lock ──────────────────────────────────────────────────────────────────────
acquire_lock() {
  if [ -f "$LOCK" ]; then
    local pid
    pid=$(cat "$LOCK" 2>/dev/null || echo "")
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      err "Another instance is running (PID $pid). Exiting."
      exit 1
    fi
    warn "Stale lock found, removing."
    rm -f "$LOCK"
  fi
  echo $$ > "$LOCK"
  trap 'rm -f "$LOCK"' EXIT
}

# ── Dependency check ──────────────────────────────────────────────────────────
check_deps() {
  local missing=()
  for cmd in growpart pvresize lvextend lvs vgs pvs lsblk findmnt; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    err "Missing required tools: ${missing[*]}"
    err "Install: dnf install -y cloud-utils-growpart lvm2 xfsprogs e2fsprogs"
    exit 1
  fi
}

# ── Load config ───────────────────────────────────────────────────────────────
EXPAND_ROOT=true
EXPAND_HOME=true
SKIP_SWAP=true
ROOT_FREE_PERCENT=60
HOME_FREE_PERCENT=40

load_config() {
  if [ -f "$CONF" ]; then
    log "Loading config from $CONF"
    # shellcheck source=/dev/null
    source "$CONF"
    dbg "Config: ROOT=$EXPAND_ROOT HOME=$EXPAND_HOME ROOT_PCT=$ROOT_FREE_PERCENT HOME_PCT=$HOME_FREE_PERCENT"
  else
    dbg "No config file at $CONF — using defaults."
  fi

  local total=$(( ROOT_FREE_PERCENT + HOME_FREE_PERCENT ))
  if [ "$total" -gt 100 ]; then
    warn "ROOT_FREE_PERCENT+HOME_FREE_PERCENT=$total > 100 — resetting to 60/40"
    ROOT_FREE_PERCENT=60
    HOME_FREE_PERCENT=40
  fi
}

# ── Resolve device → disk + partition + pv ───────────────────────────────────
# Handles: /dev/mapper/rl-root, /dev/dm-0, /dev/sda3, /dev/nvme0n1p3
#
# Strategy (3-tier fallback):
#   1. LVM-native: lvs → get VG name → pvs → get PV path  [most reliable]
#   2. dmsetup deps: parse block device from dm dependency  [fallback for dm]
#   3. Direct: device is already a partition (non-LVM)      [non-LVM case]
resolve_partition() {
  local device="$1"
  local pv_dev disk part_num

  dbg "resolve_partition: input=$device"

  # ── Tier 1: LVM path — use pvs to get PV directly from VG ────────────────
  # Works for any /dev/mapper/* or /dev/dm-* or /dev/VG/LV path
  # lvs accepts /dev/mapper/rl-root without needing readlink
  local vg_name
  vg_name=$(lvs --noheadings -o vg_name "$device" 2>/dev/null | tr -d ' ' || true)

  if [ -n "$vg_name" ]; then
    # Get first PV of this VG — this is the underlying physical partition
    pv_dev=$(pvs --noheadings -o pv_name --select "vg_name=$vg_name" 2>/dev/null \
             | tr -d ' ' | head -1 || true)
    dbg "LVM path: $device → VG=$vg_name → PV=$pv_dev"
  fi

  # ── Tier 2: dmsetup deps — for dm devices where lvs might not work ────────
  if [ -z "${pv_dev:-}" ]; then
    # dmsetup deps /dev/mapper/rl-root → "1 dependencies  : (8, 3)"
    # major=8, minor=3 → lsblk to convert to /dev/sda3
    local deps dep_major dep_minor kname
    deps=$(dmsetup deps "$device" 2>/dev/null || true)
    if [[ "$deps" =~ \(([0-9]+),\ *([0-9]+)\) ]]; then
      dep_major="${BASH_REMATCH[1]}"
      dep_minor="${BASH_REMATCH[2]}"
      # Find device name from major:minor
      kname=$(lsblk -no NAME,MAJ:MIN 2>/dev/null \
              | awk -v mm="${dep_major}:${dep_minor}" '$2==mm {print $1}' | head -1 || true)
      if [ -n "$kname" ]; then
        pv_dev="/dev/$kname"
        dbg "dmsetup path: $device → major=$dep_major minor=$dep_minor → PV=$pv_dev"
      fi
    fi
  fi

  # ── Tier 3: device is already a partition (non-LVM) ──────────────────────
  if [ -z "${pv_dev:-}" ]; then
    local dev_type
    dev_type=$(lsblk -no TYPE "$device" 2>/dev/null | head -1 | tr -d ' ' || true)
    if [[ "$dev_type" == "part" || "$dev_type" == "disk" ]]; then
      pv_dev="$device"
      dbg "Direct partition: $pv_dev (type=$dev_type)"
    fi
  fi

  # ── Failed to resolve ─────────────────────────────────────────────────────
  if [ -z "${pv_dev:-}" ]; then
    err "Cannot resolve PV for device: $device"
    err "Debug: run 'lvs $device' and 'pvs' manually to inspect LVM state"
    return 1
  fi

  dbg "PV resolved: $pv_dev"

  # ── Parse disk + partition number ─────────────────────────────────────────
  # /dev/sda3        → disk=/dev/sda    part=3
  # /dev/vda2        → disk=/dev/vda    part=2
  # /dev/xvda1       → disk=/dev/xvda   part=1
  # /dev/nvme0n1p3   → disk=/dev/nvme0n1  part=3
  if [[ "$pv_dev" =~ ^(/dev/[a-z]+)([0-9]+)$ ]]; then
    disk="${BASH_REMATCH[1]}"
    part_num="${BASH_REMATCH[2]}"
  elif [[ "$pv_dev" =~ ^(/dev/nvme[0-9]+n[0-9]+)p([0-9]+)$ ]]; then
    disk="${BASH_REMATCH[1]}"
    part_num="${BASH_REMATCH[2]}"
  else
    err "Cannot parse disk/partition number from: $pv_dev"
    err "Expected format: /dev/sda3 or /dev/nvme0n1p3"
    return 1
  fi

  echo "$disk $part_num $pv_dev"
}

# ── Grow partition + PV — once per unique disk ────────────────────────────────
declare -A PROCESSED_DISKS=()
declare -A PROCESSED_PVS=()
PV_GREW=false

grow_partition_and_pv() {
  local disk="$1" part_num="$2" pv_dev="$3"
  local disk_key="${disk}:${part_num}"

  if [[ -n "${PROCESSED_DISKS[$disk_key]+x}" ]]; then
    dbg "Partition $disk_key already handled — skipping."
    return 0
  fi
  PROCESSED_DISKS["$disk_key"]=1

  if growpart --dry-run "$disk" "$part_num" &>/dev/null; then
    log "► Partition ${disk}${part_num} has free space — growing..."
    run "growpart" growpart "$disk" "$part_num"
    run "partprobe" partprobe "$disk" || true
    sleep 1
    PV_GREW=true
  else
    log "  Partition ${disk}${part_num} already at maximum — no grow needed."
  fi

  if [[ -n "${PROCESSED_PVS[$pv_dev]+x}" ]]; then
    dbg "PV $pv_dev already handled — skipping."
    return 0
  fi
  PROCESSED_PVS["$pv_dev"]=1

  if pvs "$pv_dev" &>/dev/null 2>&1; then
    log "► Resizing PV $pv_dev..."
    run "pvresize" pvresize "$pv_dev"
  fi
}

# ── Get VG free extents ───────────────────────────────────────────────────────
vg_free_extents() {
  vgs --noheadings -o vg_free_count "$1" 2>/dev/null | tr -d ' ' || echo "0"
}

# ── Grow one LV + its filesystem ──────────────────────────────────────────────
grow_lv() {
  local lv_path="$1" extents="$2" mountpoint="$3" fstype="$4"

  if [ "$extents" -le 0 ]; then
    log "  No extents to allocate to $lv_path"
    return 0
  fi

  log "► Extending $lv_path by +${extents} extents..."
  run "lvextend" lvextend -l "+${extents}" "$lv_path"

  case "$fstype" in
    xfs)        run "xfs_growfs"  xfs_growfs "$mountpoint" ;;
    ext4|ext3|ext2) run "resize2fs" resize2fs "$lv_path" ;;
    btrfs)      run "btrfs resize" btrfs filesystem resize max "$mountpoint" ;;
    *)          warn "Unknown fstype '$fstype' on $mountpoint — skipping fs resize." ;;
  esac
}

# ── Process VG: distribute free extents to root + home ───────────────────────
declare -A PROCESSED_VGS=()

process_vg() {
  local vg="$1"

  if [[ -n "${PROCESSED_VGS[$vg]+x}" ]]; then
    dbg "VG $vg already processed — skipping."
    return 0
  fi
  PROCESSED_VGS["$vg"]=1

  local free_ext
  free_ext=$(vg_free_extents "$vg")
  dbg "VG $vg free extents: $free_ext"

  if [[ "$free_ext" -le 0 ]] 2>/dev/null; then
    log "  VG $vg has no free extents — nothing to distribute."
    return 0
  fi
  log "► VG $vg has $free_ext free extents to distribute."

  # Root LV info — use mapper path directly (not readlink, /dev/dm-N breaks lvs)
  local root_device root_vg root_lv root_lv_path root_fstype
  root_device=$(findmnt -n -o SOURCE / 2>/dev/null)
  root_vg=$(lvs  --noheadings -o vg_name "$root_device" 2>/dev/null | tr -d ' ')
  root_lv=$(lvs  --noheadings -o lv_name "$root_device" 2>/dev/null | tr -d ' ')
  root_fstype=$(findmnt -n -o FSTYPE / 2>/dev/null)
  root_lv_path="/dev/$root_vg/$root_lv"

  # Home LV info (optional)
  local home_exists=false home_lv_path home_fstype home_vg home_lv home_device
  if findmnt /home &>/dev/null 2>&1; then
    home_device=$(findmnt -n -o SOURCE /home 2>/dev/null)
    home_vg=$(lvs --noheadings -o vg_name "$home_device" 2>/dev/null | tr -d ' ' || true)
    if [ "$home_vg" = "$vg" ]; then
      home_lv=$(lvs --noheadings -o lv_name "$home_device" 2>/dev/null | tr -d ' ')
      home_fstype=$(findmnt -n -o FSTYPE /home 2>/dev/null)
      home_lv_path="/dev/$home_vg/$home_lv"
      home_exists=true
    fi
  fi

  # Calculate extents per LV
  local root_ext=0 home_ext=0

  if $EXPAND_ROOT && [ "$root_vg" = "$vg" ]; then
    if $home_exists && $EXPAND_HOME; then
      root_ext=$(( free_ext * ROOT_FREE_PERCENT / 100 ))
      home_ext=$(( free_ext - root_ext ))
      log "  Split: root +${root_ext} (${ROOT_FREE_PERCENT}%)  home +${home_ext} ($(( 100 - ROOT_FREE_PERCENT ))%)"
    else
      root_ext="$free_ext"
      log "  Split: root +${root_ext} (100% — /home not in same VG or disabled)"
    fi
  elif $home_exists && $EXPAND_HOME && [ "$home_vg" = "$vg" ]; then
    home_ext="$free_ext"
    log "  Split: home +${home_ext} (100%)"
  fi

  $EXPAND_ROOT && [ "$root_ext" -gt 0 ] && [ "$root_vg" = "$vg" ] && \
    grow_lv "$root_lv_path" "$root_ext" "/" "$root_fstype"

  $home_exists && $EXPAND_HOME && [ "$home_ext" -gt 0 ] && \
    grow_lv "$home_lv_path" "$home_ext" "/home" "$home_fstype"
}

# ── Report ────────────────────────────────────────────────────────────────────
report_status() {
  log "========== Disk status after expand =========="
  {
    echo ""
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS 2>/dev/null \
      || lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT
    echo ""
    df -h -x tmpfs -x devtmpfs -x efivarfs 2>/dev/null || df -h
    echo ""
    pvs 2>/dev/null || true
    vgs 2>/dev/null || true
    lvs 2>/dev/null || true
    echo ""
  } | tee -a "$LOGFILE"
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  touch "$LOGFILE" 2>/dev/null || { echo "Cannot write to $LOGFILE"; exit 1; }
  chmod 640 "$LOGFILE"

  log "============================================================"
  log "disk-expand.sh v2  (dry=$DRY_RUN verbose=$VERBOSE)"
  log "Host: $(hostname -s 2>/dev/null)  Kernel: $(uname -r)"
  log "============================================================"

  acquire_lock
  check_deps
  load_config

  # Step 1: resolve root → disk/partition/PV
  # Use mapper path directly (/dev/mapper/rl-root), NOT readlink (/dev/dm-0 breaks lvs)
  local root_device info disk part_num pv_dev
  root_device=$(findmnt -n -o SOURCE / 2>/dev/null)
  log "Root device: $root_device"

  info=$(resolve_partition "$root_device") || {
    err "Cannot resolve root partition. Aborting."
    exit 1
  }
  read -r disk part_num pv_dev <<< "$info"
  log "Disk=$disk  Partition=$part_num  PV=$pv_dev"

  # Step 2: grow partition + PV (once)
  grow_partition_and_pv "$disk" "$part_num" "$pv_dev"

  # Step 3: distribute VG free extents
  local vg_name
  vg_name=$(lvs --noheadings -o vg_name "$root_device" 2>/dev/null | tr -d ' ')
  log "VG: $vg_name"
  process_vg "$vg_name"

  # Step 4: handle extra VGs (for multi-disk setups)
  while IFS= read -r mp; do
    [[ "$mp" == "/" || "$mp" == "/home" ]] && continue
    [[ "$mp" =~ ^/(proc|sys|dev|run) ]]    && continue

    local extra_dev extra_vg extra_info e_disk e_partnum e_pv
    extra_dev=$(findmnt -n -o SOURCE "$mp" 2>/dev/null || true)
    [ -z "$extra_dev" ] && continue
    extra_vg=$(lvs --noheadings -o vg_name "$extra_dev" 2>/dev/null | tr -d ' ' || true)
    [ -z "$extra_vg" ] && continue
    [ "$extra_vg" = "$vg_name" ] && continue

    dbg "Extra VG: $extra_vg at $mp"
    extra_info=$(resolve_partition "$extra_dev") || continue
    read -r e_disk e_partnum e_pv <<< "$extra_info"
    grow_partition_and_pv "$e_disk" "$e_partnum" "$e_pv"
    process_vg "$extra_vg"

  done < <(findmnt -n -o TARGET -t xfs,ext4,ext3,ext2,btrfs 2>/dev/null | sort)

  report_status
  log "✅ disk-expand.sh completed."
}

main "$@"
MAIN_SCRIPT

chmod 750 /usr/local/bin/disk-expand.sh
chown root:root /usr/local/bin/disk-expand.sh
ok "Wrote /usr/local/bin/disk-expand.sh"

# ═════════════════════════════════════════════════════════════════════════════
hdr "Step 3: Write /etc/disk-expand.conf"
# ═════════════════════════════════════════════════════════════════════════════

# Only write config if it doesn't exist (preserve user customizations)
if [ ! -f /etc/disk-expand.conf ]; then
  cat > /etc/disk-expand.conf << 'CONF'
# =============================================================================
#  /etc/disk-expand.conf — Configuration for disk-expand.sh
#  Edit to customize. Changes take effect on next boot or manual run.
# =============================================================================

# Which LVs to expand
EXPAND_ROOT=true          # Expand / (rl-root)
EXPAND_HOME=true          # Expand /home (rl-home) if present in same VG
SKIP_SWAP=true            # Never resize swap (always leave true)

# How to split VG free space between root and home (must sum to 100)
# Rocky 9 default layout: root ~61%, home ~30% of total
# → giving root 60% and home 40% of *new* free space is balanced
ROOT_FREE_PERCENT=60
HOME_FREE_PERCENT=40

# ── Common overrides ──────────────────────────────────────────────────────────
# No /home LV (single root layout):
#   EXPAND_HOME=false
#
# Root takes everything:
#   EXPAND_HOME=false
#
# Equal split:
#   ROOT_FREE_PERCENT=50
#   HOME_FREE_PERCENT=50
CONF
  ok "Wrote /etc/disk-expand.conf"
else
  warn "/etc/disk-expand.conf already exists — keeping your config (not overwritten)"
fi

# ═════════════════════════════════════════════════════════════════════════════
hdr "Step 4: Write /etc/systemd/system/disk-expand.service"
# ═════════════════════════════════════════════════════════════════════════════

cat > /etc/systemd/system/disk-expand.service << 'SERVICE'
[Unit]
Description=Auto-expand disk partitions, LVM volumes, and filesystems on boot
Documentation=file:///usr/local/bin/disk-expand.sh
After=local-fs.target
After=systemd-udev-settle.service
Before=network.target
Before=cloud-init.service
ConditionPathExists=/usr/local/bin/disk-expand.sh

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/disk-expand.sh
TimeoutStartSec=120
StandardOutput=journal+console
StandardError=journal+console
User=root
Restart=no

[Install]
WantedBy=multi-user.target
SERVICE

chmod 644 /etc/systemd/system/disk-expand.service
chown root:root /etc/systemd/system/disk-expand.service
ok "Wrote /etc/systemd/system/disk-expand.service"

# ═════════════════════════════════════════════════════════════════════════════
hdr "Step 5: Enable service"
# ═════════════════════════════════════════════════════════════════════════════

systemctl daemon-reload
systemctl enable disk-expand.service
ok "Service enabled — will run automatically on every boot"

# ═════════════════════════════════════════════════════════════════════════════
hdr "Step 6: Dry-run verification"
# ═════════════════════════════════════════════════════════════════════════════

echo ""
info "Running dry-run to verify script works on this system..."
echo "──────────────────────────────────────────────────────"
bash /usr/local/bin/disk-expand.sh --dry-run --verbose
echo "──────────────────────────────────────────────────────"

# ═════════════════════════════════════════════════════════════════════════════
hdr "Installation complete"
# ═════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${BOLD}Files installed:${NC}"
echo "  /usr/local/bin/disk-expand.sh          — main expand script"
echo "  /etc/disk-expand.conf                  — configuration"
echo "  /etc/systemd/system/disk-expand.service — systemd unit"
echo ""
echo -e "${BOLD}Useful commands:${NC}"
echo "  Check service status   :  systemctl status disk-expand"
echo "  View log               :  tail -f /var/log/disk-expand.log"
echo "  Run manually           :  sudo /usr/local/bin/disk-expand.sh"
echo "  Dry-run + verbose      :  sudo /usr/local/bin/disk-expand.sh --dry-run --verbose"
echo "  Edit config            :  vi /etc/disk-expand.conf"
echo "  Disable service        :  systemctl disable disk-expand"
echo ""
echo -e "${BOLD}Test procedure:${NC}"
echo "  1. Expand disk on vSphere (e.g. 100G → 150G)"
echo "  2. Reboot VM:  sudo reboot"
echo "  3. After boot: lsblk && df -h /"
echo "                 (/ and /home should reflect new size)"
echo ""
echo -e "${GREEN}${BOLD}Done.${NC}"
