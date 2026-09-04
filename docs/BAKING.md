# Baking the CML AMI

These are the steps that produced a working, EC2-validated CML-Free AMI. Budget **60–75
minutes**, most of it waiting. Everything is scripted except the CML first-boot wizard,
which is interactive by design (~5 minutes of keystrokes, ~10 minutes of image copying).

The bake host is a throwaway nested-virt instance. It boots the CML installer in KVM, with a
**second EBS volume as the installer's target disk** — that volume becomes the AMI.

## Prerequisites

- Both CML zips in S3 (see the README's download section): `cml-iso.zip`, `refplat-iso.zip`.
- EC2 serial console enabled for the account (`aws ec2 get-serial-console-access-status`).
- An SSM-capable IAM instance profile for the bake host, with read access to that bucket.

```bash
export AWS_REGION=us-east-1
export BUCKET=my-cml-isos-<acct>

aws iam create-role --role-name cml-bake-role \
  --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
    "Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
aws iam attach-role-policy --role-name cml-bake-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
aws iam put-role-policy --role-name cml-bake-role --policy-name s3-iso-read \
  --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",
    \"Action\":[\"s3:GetObject\",\"s3:ListBucket\"],
    \"Resource\":[\"arn:aws:s3:::$BUCKET\",\"arn:aws:s3:::$BUCKET/*\"]}]}"
aws iam create-instance-profile --instance-profile-name cml-bake-profile
aws iam add-role-to-instance-profile --instance-profile-name cml-bake-profile \
  --role-name cml-bake-role
```

## 1. Launch the bake host

Ubuntu 24.04, nested virt on, 24 GiB root + **64 GiB target volume** (`/dev/sdf`), no inbound
ports (all access is via SSM):

```bash
UBUNTU=$(aws ssm get-parameter --name \
  /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id \
  --query 'Parameter.Value' --output text)

aws ec2 run-instances \
  --image-id "$UBUNTU" --instance-type m8i.xlarge \
  --cpu-options 'NestedVirtualization=enabled' \
  --iam-instance-profile Name=cml-bake-profile \
  --metadata-options 'HttpTokens=required' \
  --block-device-mappings '[
    {"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":24,"VolumeType":"gp3","DeleteOnTermination":true}},
    {"DeviceName":"/dev/sdf","Ebs":{"VolumeSize":64,"VolumeType":"gp3","DeleteOnTermination":false}}]' \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=cml-ami-bake}]' \
  --query 'Instances[0].{Id:InstanceId,Cpu:CpuOptions}'
```

Confirm the response echoes `"NestedVirtualization": "enabled"`, then wait for SSM:

```bash
export BAKE=i-0123456789abcdef0
aws ssm describe-instance-information \
  --filters Key=InstanceIds,Values=$BAKE --query 'InstanceInformationList[0].PingStatus'
```

> **If apt hangs:** some VPCs allow 443 but not 80 outbound, and Ubuntu's default mirrors are
> HTTP. Switch them to HTTPS before stage 1:
> ```bash
> aws ssm send-command --instance-ids $BAKE --document-name AWS-RunShellScript \
>   --parameters 'commands=["sed -i -E \"s|http://[a-z0-9.-]*archive.ubuntu.com/ubuntu|https://archive.ubuntu.com/ubuntu|g; s|http://security.ubuntu.com/ubuntu|https://security.ubuntu.com/ubuntu|g\" /etc/apt/sources.list.d/ubuntu.sources"]'
> ```

## 2. Stage 1 — install CML into the target volume

```bash
B64=$(base64 -i scripts/bake/01-install-cml.sh | tr -d '\n')
aws ssm send-command --instance-ids $BAKE --document-name AWS-RunShellScript \
  --timeout-seconds 3600 \
  --parameters "commands=[
    \"echo $B64 | base64 -d > /root/01.sh\",
    \"export S3_BUCKET=$BUCKET CML_ISO_KEY=cml-iso.zip AWS_REGION=$AWS_REGION\",
    \"bash /root/01.sh\"
  ],executionTimeout=[3600]"
```

Progress lives in `/var/log/cml-bake.log` on the host. The installer is non-interactive: it
selects the 64 GiB disk, installs, ejects the ISO and powers the VM off (~10 minutes). Wait
for `virsh domstate cmlbake` to report `shut off`.

## 3. Attach the refplat ISO and boot CML

```bash
aws ssm send-command --instance-ids $BAKE --document-name AWS-RunShellScript \
  --parameters 'commands=[
    "aws s3 cp s3://'"$BUCKET"'/refplat-iso.zip /opt/cml/refplat.zip --only-show-errors",
    "cd /opt/cml && unzip -o -q refplat.zip && rm -f refplat.zip",
    "ISO=$(find /opt/cml -iname \"refplat*.iso\" | head -1); echo $ISO",
    "virsh change-media cmlbake sda --source $ISO --insert --config || virsh attach-disk cmlbake $ISO sda --type cdrom --mode readonly --config",
    "virsh start cmlbake"
  ]'
```

## 4. The one interactive part: the first-boot wizard

Drive the VM's VNC console with `vncdo` (installed by stage 1). Capture a screenshot, send
keys, repeat:

```bash
SHOT='/opt/vnctool/bin/vncdo -s 127.0.0.1::5900 capture /tmp/c.png && aws s3 cp /tmp/c.png s3://'"$BUCKET"'/bake/c.png --only-show-errors'
aws ssm send-command --instance-ids $BAKE --document-name AWS-RunShellScript \
  --parameters "commands=[\"$SHOT\"]"
aws s3 cp "s3://$BUCKET/bake/c.png" /tmp/c.png && open /tmp/c.png
```

Send keys with `/opt/vnctool/bin/vncdo -s 127.0.0.1::5900 key <k>` or `type <text>`.
The sequence, in order:

| Screen | Keys |
|---|---|
| CML banner | `enter` (Continue) |
| EULA | `end`, `tab`, `enter` (Accept EULA) |
| "First Deployment Configuration" | `enter` |
| Brief Help | `enter` |
| "standalone all-in-one" notice | `enter` |
| Hostname (`cml-controller`) | `enter` |
| **sysadmin** user + password | `down`, type password, `down`, type it again, `enter` |
| **admin** (web UI) user + password | `down`, type password, `down`, type it again, `enter` |
| IPv4 config | `enter` (DHCP is preselected — correct for EC2) |
| Optional services | `space` (OpenSSH), `down`, `space` (PATty), `enter` |
| Confirmation — check it says `Platform ISO/CD-ROM: attached` | `enter` (Confirm) |
| "Reference Platform images will now be copied" | `enter`, then wait ~10 min |

Two traps here:

- Inside the account dialogs, **arrow keys move between fields**; `tab` jumps to the buttons
  and you'll get "Password can't be empty!".
- Passwords need an uppercase letter, a digit **and** punctuation, or you get a
  "continue anyway?" prompt. Avoid `!` in shell-typed strings.

The wizard is done when the console shows a login prompt and
`Access the CML UI from https://<vm-ip>/`. Verify from the bake host:

```bash
curl -sk https://<vm-ip>/api/v0/system_information   # {"version":"...","ready":true,...}
```

> Wizard complains about CPU count? It requires ≥4 CPUs. Stage 1 sets 4; if you lowered it,
> `virsh setvcpus cmlbake 4 --config --maximum && virsh setvcpus cmlbake 4 --config`.

## 5. Stage 2 — adapt the image for EC2

```bash
B64=$(base64 -i scripts/bake/02-finalize-image.sh | tr -d '\n')
aws ssm send-command --instance-ids $BAKE --document-name AWS-RunShellScript \
  --timeout-seconds 900 \
  --parameters "commands=[\"echo $B64 | base64 -d > /root/02.sh\",\"bash /root/02.sh\"]"
```

This powers the VM off and applies the EFI fallback, the ENA rename rule, the MAC un-pinning
and the serial getty. See the README's gotcha list for why each is needed.

## 6. Snapshot and register the AMI

```bash
VOL=$(aws ec2 describe-instances --instance-ids $BAKE \
  --query 'Reservations[0].Instances[0].BlockDeviceMappings[?DeviceName==`/dev/sdf`].Ebs.VolumeId' \
  --output text)
SNAP=$(aws ec2 create-snapshot --volume-id $VOL \
  --description "CML-Free system disk" --query SnapshotId --output text)

# 64 GiB takes >10 min, so poll rather than using `aws ec2 wait`
until aws ec2 describe-snapshots --snapshot-ids $SNAP \
        --query 'Snapshots[0].State' --output text | grep -q completed; do sleep 30; done

aws ec2 register-image --name "cml-free-$(date +%Y%m%d)" \
  --description "Cisco Modeling Labs Free with refplat images, EC2-ready" \
  --architecture x86_64 --virtualization-type hvm --ena-support --boot-mode uefi \
  --root-device-name /dev/sda1 \
  --block-device-mappings "DeviceName=/dev/sda1,Ebs={SnapshotId=$SNAP,VolumeSize=64,VolumeType=gp3,DeleteOnTermination=true}" \
  --query ImageId --output text
```

`--boot-mode uefi` and `--ena-support` are both required; the image will not boot without the
first and will not get a fast NIC without the second.

## 7. Smoke-test, then clean up

Put the AMI id in `cdk.context.json`, `npm run deploy`, `npm run fix-network`, and confirm
`npm run status` reports the API reachable. Only then throw the bake host away:

```bash
aws ec2 terminate-instances --instance-ids $BAKE
aws ec2 delete-volume --volume-id $VOL      # after the instance is terminated
aws s3 rm "s3://$BUCKET/bake/" --recursive
aws iam remove-role-from-instance-profile --instance-profile-name cml-bake-profile --role-name cml-bake-role
aws iam delete-instance-profile --instance-profile-name cml-bake-profile
aws iam delete-role-policy --role-name cml-bake-role --policy-name s3-iso-read
aws iam detach-role-policy --role-name cml-bake-role --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
aws iam delete-role --role-name cml-bake-role
```

Keep the ISO zips in S3 (~$0.17/month) so a rebake doesn't mean re-downloading 7 GiB.
