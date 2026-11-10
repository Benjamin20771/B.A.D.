#!/usr/bin/env python3
"""
snapshot-limit.py  -  keep student VM snapshots under control, cluster-wide.

Run on ONE node (pve10). It reads every VM config from /etc/pve (instant,
read-only) and deletes extra snapshots through the Proxmox API, so it works
on VMs on every node.

Policy (edit the CONFIG block):
  - Only student VMs: VMID >= MIN_VMID, not a template, name not GW-*,
    no "keep-snapshots" tag, not locked.
  - Snapshots named in PROTECT (the deployment "Base") are never touched.
  - Of the remaining snapshots, keep the newest KEEP_NEWEST, delete the rest
    (oldest first).
  - Built to run often from cron: when there's nothing to delete it exits
    without writing anything, so the log only shows real work.

Starts in DRY RUN mode: it prints what it would delete and changes nothing.
Set DRY_RUN = False (or run with --apply) only after checking the output.
"""
import glob, json, os, re, subprocess, sys, time

# ============================== CONFIG ==============================
DRY_RUN       = "--apply" not in sys.argv   # dry run unless --apply is given
MIN_VMID      = 100000000      # student course VMs are 9-digit IDs (e.g. 125501097)
KEEP_NEWEST   = 1              # non-protected snapshots to keep per VM
PROTECT       = {"base"}       # snapshot names never deleted (case-insensitive)
SKIP_TAG      = "keep-snapshots"
SKIP_NAME_RE  = re.compile(r"^GW-", re.I)
MAX_DELETES   = 300            # safety cap per run
PAUSE_SECONDS = 3              # gap between deletes, to go easy on NFS
TASK_TIMEOUT  = 900            # seconds to wait for one snapshot delete
# ====================================================================


def log(msg):
    print(time.strftime("%Y-%m-%d %H:%M:%S"), msg, flush=True)


def parse_conf(path):
    """Return (top_section_dict, {snapname: section_dict}) from a qemu-server .conf."""
    top, snaps = {}, {}
    target = top                      # lines before the first [section] belong to the VM itself
    with open(path) as f:
        for line in f:
            line = line.rstrip("\n")
            m = re.match(r"^\[(.+)\]$", line)
            if m:
                name = m.group(1)
                # skip non-snapshot sections like [PENDING] and [special:cloudinit]
                target = None if (name == "PENDING" or name.startswith("special:")) else snaps.setdefault(name, {})
                continue
            if target is None or ":" not in line or line.startswith("#"):
                continue
            k, v = line.split(":", 1)
            target[k.strip()] = v.strip()
    return top, snaps


def pvesh(*args):
    r = subprocess.run(["pvesh", *args, "--output-format", "json"],
                       capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip() or r.stdout.strip())
    out = r.stdout.strip()
    return json.loads(out) if out else None


def wait_task(node, upid):
    t0 = time.time()
    while time.time() - t0 < TASK_TIMEOUT:
        st = pvesh("get", f"/nodes/{node}/tasks/{upid}/status")
        if st and st.get("status") == "stopped":
            return st.get("exitstatus", "unknown")
        time.sleep(3)
    return "timeout"


def main():
    plan = []   # (node, vmid, vmname, snapname, has_ram, reason)
    skipped = []

    for path in sorted(glob.glob("/etc/pve/nodes/*/qemu-server/*.conf")):
        node = path.split("/")[4]
        vmid = int(os.path.basename(path)[:-5])
        if vmid < MIN_VMID:
            continue
        try:
            top, snaps = parse_conf(path)
        except OSError:
            continue
        name = top.get("name", "")
        if "." not in name:          # student VMs are named vm-first.last
            continue
        if top.get("template") == "1" or SKIP_NAME_RE.match(name):
            continue
        if SKIP_TAG in top.get("tags", "").split(";"):
            continue
        if top.get("lock"):
            skipped.append(f"skip {vmid} {name}: locked ({top['lock']})")
            continue

        cand = [(int(s.get("snaptime", 0)), sn, "vmstate" in s)
                for sn, s in snaps.items() if sn.lower() not in PROTECT
                and "deployment default" not in s.get("description", "").replace("%20", " ").lower()]
        cand.sort(reverse=True)                      # newest first
        keep, extra = cand[:KEEP_NEWEST], cand[KEEP_NEWEST:]
        for _, sn, ram in reversed(extra):           # oldest first
            plan.append((node, vmid, name, sn, ram, "over limit"))

    if not plan and not DRY_RUN:
        return                                       # nothing to do: stay quiet in cron
    log(f"=== snapshot-limit start ({'DRY RUN' if DRY_RUN else 'APPLY'}) keep={KEEP_NEWEST} ===")
    for s in skipped:
        log(s)
    log(f"{len(plan)} snapshot(s) to delete "
        f"({sum(1 for p in plan if p[4])} include RAM)")
    if len(plan) > MAX_DELETES:
        log(f"capping this run at {MAX_DELETES}; the rest go next run")
        plan = plan[:MAX_DELETES]

    ok = fail = 0
    for node, vmid, name, sn, ram, why in plan:
        tag = " [RAM]" if ram else ""
        if DRY_RUN:
            log(f"WOULD DELETE {vmid} {name} :: {sn}{tag} ({why})")
            continue
        try:
            upid = pvesh("delete", f"/nodes/{node}/qemu/{vmid}/snapshot/{sn}")
            status = wait_task(node, upid) if isinstance(upid, str) and upid.startswith("UPID") else "OK"
            if status == "OK":
                ok += 1
                log(f"deleted {vmid} {name} :: {sn}{tag} ({why})")
            else:
                fail += 1
                log(f"FAILED  {vmid} {name} :: {sn}{tag}: task {status}")
        except Exception as e:
            fail += 1
            log(f"FAILED  {vmid} {name} :: {sn}{tag}: {e}")
        time.sleep(PAUSE_SECONDS)

    log(f"=== done: {ok} deleted, {fail} failed{' (dry run, nothing changed)' if DRY_RUN else ''} ===")


if __name__ == "__main__":
    main()
