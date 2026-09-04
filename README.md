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

4. Bake the AMI with the companion tool — one command, ~60 minutes, unattended:

   ```bash
   git clone https://github.com/felipedbene/cml-free-ami-baker
   cd cml-free-ami-baker
   export CML_BAKE_PASSWORD='YourStrong.Pass1'
   ./bake.sh --bucket my-cml-isos-<acct> --region us-east-1
   ```

   👉 **[felipedbene/cml-free-ami-baker](https://github.com/felipedbene/cml-free-ami-baker)** —
   installs CML under KVM on a throwaway host, lets CML configure itself with no keystrokes,
   applies the EC2 fixes, and registers the AMI. It also documents the manual/interactive path
   and a troubleshooting guide.

**CML-Free limits:** up to **5 nodes** running simultaneously (unmanaged switches and
external connectors don't count), single user, and telemetry cannot be disabled. The bundled
VM images are licensed for use *inside* CML only.

---

## Quickstart

```bash
# 0. Bake the AMI once (~60 min, unattended) with the companion tool:
#    https://github.com/felipedbene/cml-free-ami-baker

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
| `instanceType` | | `m8i.xlarge` | Any nested-virt type with **≥4 vCPU** — see [right-sizing](#right-sizing-for-the-5-node-cap) |
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
| `c7i.xlarge` (4 vCPU, 8 GiB) — cheapest supported | $0.179/h | ~$0.070/h |
| **`m8i.xlarge` (4 vCPU, 16 GiB)** — default, validated | **$0.212/h** | **~$0.098/h** ($0.084–0.112) |
| `m8i.2xlarge` (8 vCPU, 32 GiB) | $0.423/h | ~$0.205/h |
| `i3en.metal` — the old bare-metal way | $10.848/h | — |

### Right-sizing for the 5-node cap

CML-Free runs at most 5 nodes, so there's no point paying for a big instance — but there is a
hard floor: **CML's setup refuses to start with fewer than 4 vCPUs** (*"This system does not have
the minimum number of CPUs required (4)"*), so every `.large` (2 vCPU) type is out, however cheap.

Memory is the dimension worth tuning. Observed on a running 5-node IOL lab (MPLS L3VPN: 2 CE,
2 PE, 1 P): **~13% of 16 GiB, about 2 GiB, at 1.25% CPU.** IOL nodes are remarkably light.

| Your labs | RAM | Cheapest 4-vCPU options (us-east-1) |
|---|---|---|
| IOL / IOL-L2 only | 8 GiB is plenty | `c7i.xlarge` $0.179 OD / ~$0.070 spot · `c7i-flex.xlarge` $0.170 OD |
| ASAv, Ubuntu or desktop nodes (2–4 GiB each) | 16 GiB | `m7i-flex.xlarge` $0.192 OD / ~$0.078 spot · `m7i.xlarge` $0.202 OD · `m8i.xlarge` $0.212 OD |
| Five heavy nodes, or a paid CML tier with 20–40 nodes | 32 GiB | `r8i-flex.xlarge` $0.264 OD / ~$0.125 spot · `r7i.xlarge` $0.265 OD · `r8i.xlarge` $0.278 OD |

The `r` family (`r7i`, `r7iz`, `r8i`, `r8i-flex`, `r8id`) does support nested virtualization and
gives 32 GiB at 4 vCPU — the best memory *per dollar* of the lot (`r8i-flex` at ~$0.0039 per
GiB-hour on spot, versus ~$0.0087 for `c7i`). It is still the wrong choice for CML-Free: with the
5-node cap keeping actual usage near 2 GiB, you'd pay ~80% more per hour for RAM you cannot use.
It becomes the right answer only if you move to a paid tier (20–40 nodes) *and* run memory-hungry
node types — 20 IOL nodes extrapolate to roughly 9 GiB, which 16 GiB already covers.

Sticking to IOL labs on `c7i.xlarge` spot costs roughly **29% less** than the default. Two caveats:

- **`-flex` types** are built for an average CPU utilization around 40% with bursting. An idle lab
  fits that profile nicely, but sustained full load can be throttled.
- **Spot prices don't track on-demand.** `m8i-flex.xlarge` was *more* expensive on spot than
  `m8i.xlarge` while these numbers were collected. Check your own AZ:
  ```bash
  aws ec2 describe-spot-price-history --instance-types c7i.xlarge m7i-flex.xlarge \
    --product-descriptions Linux/UNIX --start-time "$(date -u -v-2H +%Y-%m-%dT%H:%M:%SZ)" \
    --query 'SpotPriceHistory[].[InstanceType,AvailabilityZone,SpotPrice]' --output table
  ```

Only `m8i.xlarge` has been validated end to end here; the rest are priced from the API and meet
the documented requirements.

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

## Is this enough for certification study?

Worth being straight about, since that's why most people want a cheap CML.

**Written exams (e.g. ENCOR 350-401): yes, comfortably.** What CML-Free covers well:

- **All the pure routing and switching** — OSPF, EIGRP, BGP, MPLS, DMVPN, VRFs, QoS, multicast.
  IOL-XE handles these properly, and they're the bulk of the technologies list.
- **Automation** — Python, RESTCONF, NETCONF and YANG against a real IOS-XE box all work on IOL-XE.

**Lab exams: partially — and the 5-node cap isn't the only gap.**

- **Scale.** Lab-style scenarios run 15–25 devices, and much of the difficulty is troubleshooting
  interactions across a large topology under time pressure. You can't rehearse that at 5 nodes.
  That's what [CML-Personal](https://developer.cisco.com/modeling-labs/) ($199, 20 nodes) or
  Personal Plus ($349, 40 nodes) is for.
- **SD-WAN and Catalyst Center.** On the blueprint, impossible on CML-Free, and even on a paid tier
  you'd need vManage/vBond/vSmart images that require an entitled Cisco account. Most candidates
  use Cisco dCloud sandboxes or DevNet reservations for these instead.
- **Cat8000v/9000v versus IOL.** The exams use Cat8000v/9000v-flavoured IOS-XE. Some SD-Access,
  EVPN and platform-specific behaviour differs or is missing in IOL — fine for learning concepts,
  not for final-weeks muscle memory.

**Practical path:** CML-Free on this stack gets you through the written material and most lab
*technologies* at 1–5 nodes. Upgrade when you're doing full mock scenarios, not before — and note
that a paid tier needs no bigger instance: 20 IOL nodes extrapolate to roughly 9 GiB, so a 4 vCPU
/ 16 GiB instance still carries it.

Blueprints and CML's image lineup both change, so verify the current exam topology list on Cisco's
site before committing to a study plan.

## Known EC2 gotchas (all handled, but worth understanding)

The CML installer targets bare metal, so the image needs three adaptations, applied at bake
time by the [baker](https://github.com/felipedbene/cml-free-ami-baker); the fourth is
per-instance and the fifth is a lab-design constraint.

1. **NIC naming.** CML's config hardcodes `enp1s0` (its KVM name). A systemd `.link` rule
   renames the ENA interface to `enp1s0` so the baked config keeps working.
2. **Bridge MAC pinning.** CML builds `bridge0` over the primary NIC and pins that NIC's MAC
   into NetworkManager. EC2 drops frames sourced from a MAC that isn't the ENI's, so a
   fresh instance gets no DHCP reply at all.
3. **Bridge MTU.** AWS DHCP hands `bridge0` an MTU of 9001 while the bridge *port* stays at
   1500. The failure is nasty: TCP handshakes succeed and payload packets vanish, so the
   port looks open while nothing loads. The port MTU is set to 9001 to match.
4. **The MAC fix again, per instance.** CML re-pins the MAC whenever its setup runs, so a
   *newly created* instance needs `npm run fix-network` once. It survives stop/start, because
   the ENI keeps its MAC.
5. **Lab connectivity.** Because of the same MAC filtering, **bridged** external connectors
   can't work on EC2 — use **NAT** connectors in your labs.

The AMI is UEFI-only, so it must be registered with `--boot-mode uefi`. (Cisco's installer does
write the `\EFI\BOOT\BOOTX64.EFI` fallback loader EC2 looks for, so that part needs no fixing.)

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
```

## License and trademarks

MIT for the code in this repository — see [LICENSE](LICENSE).

Not affiliated with or endorsed by Cisco or AWS. Cisco Modeling Labs is Cisco software
subject to Cisco's own license; you download and run it under your own agreement. No Cisco
images, ISOs, or AMIs are distributed here.
