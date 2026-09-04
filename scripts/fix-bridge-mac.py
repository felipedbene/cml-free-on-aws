#!/usr/bin/env python3
"""Align CML's bridge0 MAC with the instance ENI, over the EC2 serial console.

Why this is needed: CML builds a Linux bridge (bridge0) over the primary NIC and
pins the NIC's MAC into the NetworkManager profile. An AMI therefore carries the
MAC of the machine it was baked on. EC2 drops frames whose source MAC does not
belong to the ENI, so on a *newly created* instance bridge0's DHCP request never
gets a reply and CML comes up with no IPv4 address.

This is a one-time fix per instance: it persists across stop/start because the
ENI keeps its MAC. Requires pexpect (pip install pexpect) and EC2 serial console
access enabled for the account.
"""
from __future__ import annotations

import argparse
import getpass
import os
import subprocess
import sys
import tempfile
import time

try:
    import pexpect
except ImportError:
    sys.exit("pexpect is required: pip install pexpect")

PROMPT = r"\$ $"


def run(cmd: list[str]) -> str:
    return subprocess.run(cmd, check=True, capture_output=True, text=True).stdout.strip()


def push_key(instance_id: str, region: str, pubkey_path: str) -> None:
    run([
        "aws", "ec2-instance-connect", "send-serial-console-ssh-public-key",
        "--region", region, "--instance-id", instance_id, "--serial-port", "0",
        "--ssh-public-key", f"file://{pubkey_path}",
    ])


def login(child: "pexpect.spawn", user: str, password: str) -> bool:
    for _ in range(8):
        child.send("\r")
        idx = child.expect(
            ["login: $", PROMPT, "# $", "Password: $", pexpect.TIMEOUT], timeout=15
        )
        if idx == 0:
            child.sendline(user)
            child.expect("Password:", timeout=20)
            child.sendline(password)
        elif idx == 3:
            child.sendline(password)
        elif idx in (1, 2):
            return True
    return False


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--instance-id", required=True)
    ap.add_argument("--region", default=os.environ.get("AWS_REGION", "us-east-1"))
    ap.add_argument("--user", default="sysadmin", help="CML system user (default: sysadmin)")
    ap.add_argument("--mtu", default="9001", help="MTU for the bridge port (default: 9001)")
    args = ap.parse_args()

    password = os.environ.get("CML_SYSADMIN_PASSWORD") or getpass.getpass(
        f"CML password for {args.user} (not echoed): "
    )
    if not password:
        return 2

    with tempfile.TemporaryDirectory() as tmp:
        key = os.path.join(tmp, "serialkey")
        subprocess.run(
            ["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", key], check=True
        )
        push_key(args.instance_id, args.region, key + ".pub")

        host = (
            f"{args.instance_id}.port0@serial-console."
            f"ec2-instance-connect.{args.region}.aws"
        )
        child = pexpect.spawn(
            f"ssh -i {key} -o StrictHostKeyChecking=no "
            f"-o UserKnownHostsFile=/dev/null {host}",
            encoding="utf-8",
            timeout=120,
            codec_errors="replace",
        )
        child.logfile_read = sys.stdout

        if not login(child, args.user, password):
            print("\nCould not reach a shell prompt on the serial console.", file=sys.stderr)
            return 1

        # Point bridge0 at this instance's real MAC, clear the stale DHCP client
        # id derived from the old MAC, and make the port MTU match the bridge
        # (AWS hands out 9001; a 1500-MTU port silently drops large frames).
        remote = (
            "MAC=$(cat /sys/class/net/enp1s0/address); "
            "nmcli connection modify bridge0 "
            '802-3-ethernet.cloned-mac-address "$MAC" ipv4.dhcp-client-id ""; '
            f"nmcli connection modify bridge0-p1 802-3-ethernet.mtu {args.mtu}; "
            "nmcli connection down bridge0 >/dev/null; "
            "nmcli connection up bridge0 >/dev/null; "
            "nmcli connection up bridge0-p1 >/dev/null; "
            "sleep 10; ip -br addr show bridge0"
        )
        child.sendline(f"sudo -S -p 'SUDOPW:' bash -c '{remote}'; echo FIX-RC=$?")
        while True:
            idx = child.expect(["SUDOPW:", r"FIX-RC=\d+", pexpect.TIMEOUT], timeout=180)
            if idx == 0:
                child.sendline(password)
            else:
                break

        child.expect(PROMPT, timeout=20)
        child.sendline("exit")
        time.sleep(1)
        child.close()

    print("\nDone. Check reachability with: npm run status")
    return 0


if __name__ == "__main__":
    sys.exit(main())
