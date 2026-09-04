# CML Free on AWS — with nested virtualization

Run [Cisco Modeling Labs](https://developer.cisco.com/docs/modeling-labs/) (CML-Free) on a
**normal EC2 instance** instead of bare metal, using EC2's nested virtualization support.

CML is itself a hypervisor: it boots each lab node as a VM. That used to mean renting a
bare-metal instance — `i3en.metal` costs **$10.85/hour** in us-east-1. On a nested-virt
instance type, the same 5-node CML-Free lab runs on an **`m8i.xlarge` at ~$0.10/hour on
spot**. Same labs, ~110× cheaper per hour.

This repo is the CDK stack, the AMI bake scripts, and the EC2-specific fixes that make it
actually work.

```
        your IP ──443──▶ Elastic IP ──▶ EC2 m8i.xlarge (CpuOptions.NestedVirtualization=enabled)
                                          │
                                          └── CML controller (Ubuntu + libvirt/KVM)
                                                └── bridge0 ── lab nodes: IOL, IOL-L2, ASAv, Linux…
```

---

## ⚠️ The caveat: nested virtualization instance types

Nested virtualization is **not** available on every instance type. It is exposed on recent
Intel families only. As of this writing, `describe-instance-types` reports 166 supported
types across these families:

```
c7i  c7i-flex  c8i  c8i-flex  c8id   i7i  i7ie
m7i  m7i-flex  m8i  m8i-flex  m8id
r7i  r7iz     r8i  r8i-flex  r8id   x8i
```

Check availability in *your* region before deploying — support varies by region:

```bash
aws ec2 describe-instance-types --region "$AWS_REGION" \
  --filters Name=processor-info.supported-features,Values=nested-virtualization \
  --query 'InstanceTypes[].InstanceType' --output text | tr '\t' '\n' | sort
```

Two more constraints worth knowing up front:

- **CloudFormation gap.** `AWS::EC2::Instance` accepts neither
  `CpuOptions.NestedVirtualization` nor `InstanceMarketOptions`. This stack therefore puts
  both on an `AWS::EC2::LaunchTemplate` that the instance references. If you write your own
  CDK/CFN, this is the part that will bite you.
- **Recent AWS CLI.** `--cpu-options NestedVirtualization=enabled` is a recent API addition;
  CLI 2.27 rejects it, 2.36 accepts it. Upgrade if you plan to launch instances by hand.

---

## Getting the CML images (you must download these yourself)

This repo contains **no Cisco software**. CML-Free is free of charge but licensed by Cisco,
and neither the ISOs nor a baked AMI may be redistributed — you download them with your own
account and bake your own image.

1. Create a free Cisco account at <https://id.cisco.com/> (a complete CCO profile with
   company details and a recognizable email domain is required).
2. Download CML-Free from Cisco Software Central (<https://software.cisco.com>, search
   "Cisco Modeling Labs Free"). You need two files:

   | File | What it is | Approx. size |
   |---|---|---|
   | `cml2_f_<version>_amd64-*-iso.zip` | Controller ISO — the installer | ~4.0 GiB |
   | `refplat-<date>-free-iso.zip` | Reference platform images (IOL, IOL-L2, ASAv, Ubuntu, Alpine) | ~3.0 GiB |

3. Upload both to an S3 bucket in the region you will bake in:

   ```bash
   aws s3 mb "s3://my-cml-isos-$(aws sts get-caller-identity --query Account --output text)"
   aws s3 cp cml2_f_*-iso.zip  s3://my-cml-isos-<acct>/cml-iso.zip
   aws s3 cp refplat-*-iso.zip s3://my-cml-isos-<acct>/refplat-iso.zip
   ```

**CML-Free limits:** up to **5 nodes** running simultaneously (unmanaged switches and
external connectors don't count), single user, and telemetry cannot be disabled. The bundled
VM images are licensed for use *inside* CML only.

---

## Quickstart

```bash
# 0. Bake the AMI once (~60-75 min, mostly unattended) — see docs/BAKING.md
#    Produces an AMI id you plug in below.

# 1. Configure
npm install
cp cdk.context.json.example cdk.context.json
$EDITOR cdk.context.json          # cmlAmiId + allowedCidrs are the only required keys

# 2. Deploy
npx cdk bootstrap                 # once per account/region
npm run deploy

# 3. First boot of a brand-new instance needs a one-time network fix (see below)
npm run fix-network

# 4. Go
npm run url                       # https://<elastic-ip>
```

### Configuration keys (`cdk.context.json`)

| Key | Required | Default | Notes |
|---|---|---|---|
| `cmlAmiId` | ✅ | — | AMI you baked |
| `allowedCidrs` | ✅ | — | Array of CIDRs allowed on 443 and 22. Use `["1.2.3.4/32"]`, never `0.0.0.0/0` |
| `keyName` | | none | Existing EC2 key pair. Optional — the serial console works without it |
| `instanceType` | | `m8i.xlarge` | Any nested-virt type; `m8i.large` is cheaper but tight for 5 nodes |
| `volumeSizeGiB` | | `64` | Root volume; must be ≥ the AMI's snapshot |
| `useSpot` | | `true` | Persistent spot request that **stops** (not terminates) on interruption |
| `region` | | `us-east-1` | Also honors `AWS_REGION` |
| `vpcId` + `subnetId` + `subnetAz` | | — | Omit all three and the stack creates its own VPC with a public subnet |

`cdk.context.json` is gitignored: it holds your account-specific IDs and your home IP.

---

## Day-to-day

```bash
npm run status    # instance state, lifecycle, nested-virt flag + CML API probe
npm run stop      # between study sessions — you stop paying for compute
npm run start     # same Elastic IP, so the same URL and bookmarks
npm run url
npm run destroy
```

Spot + `SpotInstanceType: persistent` + `InstanceInterruptionBehavior: stop` is what makes
manual stop/start work on a spot instance, and lets the lab survive a reclaim.

---

## Cost (ballpark, us-east-1, prices observed at time of writing)

Per-hour compute:

| Instance | On-demand | Spot (observed) |
|---|---|---|
| `m8i.large` (2 vCPU, 8 GiB) | $0.106/h | ~$0.05/h |
| **`m8i.xlarge` (4 vCPU, 16 GiB)** — default | **$0.212/h** | **~$0.098/h** ($0.084–0.112) |
| `m8i.2xlarge` (8 vCPU, 32 GiB) | $0.423/h | ~$0.205/h |
| `i3en.metal` — the old bare-metal way | $10.848/h | — |

Fixed monthly costs that apply **even while stopped**:

| Item | Cost |
|---|---|
| 64 GiB gp3 root volume | ~$5.12/mo |
| Public IPv4 / Elastic IP | ~$3.65/mo ($0.005/h, charged in-use or idle) |
| AMI snapshot (billed on used blocks) | ~$0.50–1.50/mo |
| **Fixed subtotal** | **~$9–10/mo** |

Realistic totals on spot `m8i.xlarge`:

| Usage | Compute | + fixed | **Total** |
|---|---|---|---|
| 20 h/month (a few evenings) | ~$2 | ~$9.50 | **~$12/mo** |
| 40 h/month | ~$4 | ~$9.50 | **~$14/mo** |
| Left running 24/7 | ~$72 | ~$9.50 | **~$81/mo** |
| 24/7 on-demand instead of spot | ~$155 | ~$9.50 | **~$164/mo** |

For contrast, 24/7 on `i3en.metal` would be about **$7,900/month**; even 20 hours would cost
~$217 — more than a year of the setup above.

One-off bake cost: ~1.5 h of a nested-virt instance plus temporary volumes, well under **$1**.

Prices change and vary by region — treat these as orientation, not a quote, and check the
[AWS pricing pages](https://aws.amazon.com/ec2/pricing/) for your region.

---

## Known EC2 gotchas (all handled, but worth understanding)

The CML installer targets bare metal, so the image needs four adaptations. `02-finalize-image.sh`
applies the first four; the fifth is per-instance.

1. **EFI fallback path.** EC2 boots `\EFI\BOOT\BOOTX64.EFI`; the CML installer only writes
   `\EFI\ubuntu\`. Without the copy the instance drops to an initramfs prompt.
2. **NIC naming.** CML's config hardcodes `enp1s0` (its KVM name). A systemd `.link` rule
   renames the ENA interface to `enp1s0` so the baked config keeps working.
3. **Bridge MAC pinning.** CML builds `bridge0` over the primary NIC and pins that NIC's MAC
   into NetworkManager. EC2 drops frames sourced from a MAC that isn't the ENI's, so a
   fresh instance gets no DHCP reply at all. `npm run fix-network` points `bridge0` at the
   instance's real MAC over the serial console. **This is one-time per instance** — it
   survives stop/start, because the ENI keeps its MAC.
4. **Bridge MTU.** AWS DHCP hands `bridge0` an MTU of 9001 while the bridge *port* stays at
   1500. The failure is nasty: TCP handshakes succeed and payload packets vanish, so the
   port looks open while nothing loads. The port MTU is set to 9001 to match.
5. **Lab connectivity.** Because of the same MAC filtering, **bridged** external connectors
   can't work on EC2 — use **NAT** connectors in your labs.

Debugging aid: the EC2 **serial console** is enabled in the image (login `sysadmin`), which
is how you recover an instance with no working network.

---

## Security notes

- The stack opens **only** 443 and 22, and only to the CIDRs you list. Keep it that way.
- **Change the passwords you set during the bake** on first login (CML web UI user and the
  `sysadmin` system user). The AMI you build embeds whatever you chose.
- CML serves a **self-signed certificate**, so expect a browser warning on first visit.
- Cockpit (host admin) listens on **9090** and CML's SSH on **1122**; neither is exposed by
  this security group. Open them deliberately if you want them.
- Don't share the baked AMI or make its snapshot public: it contains Cisco software and your
  credentials.

---

## Repository layout

```
bin/cml-lab.ts              CDK app entry
lib/cml-lab-stack.ts        VPC/SG/launch template/instance/EIP
scripts/lab.sh              start | stop | status | url | fix-network
scripts/fix-bridge-mac.py   serial-console bridge MAC + MTU fix
scripts/bake/               AMI bake stages (run on the bake host)
docs/BAKING.md              how the AMI is built, step by step
```

## License and trademarks

MIT for the code in this repository — see [LICENSE](LICENSE).

Not affiliated with or endorsed by Cisco or AWS. Cisco Modeling Labs is Cisco software
subject to Cisco's own license; you download and run it under your own agreement. No Cisco
images, ISOs, or AMIs are distributed here.
