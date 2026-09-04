import * as cdk from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import { Construct } from 'constructs';

/**
 * Runs a pre-baked Cisco Modeling Labs AMI on an EC2 instance with nested
 * virtualization enabled, so CML's own hypervisor can boot lab nodes.
 */
export class CmlLabStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    const ctx = <T,>(key: string, fallback?: T): T => {
      const value = this.node.tryGetContext(key);
      if (value === undefined || value === '') {
        if (fallback === undefined) {
          throw new Error(
            `Missing required context "${key}". Set it in cdk.context.json or pass -c ${key}=<value>.`
          );
        }
        return fallback;
      }
      return value as T;
    };

    const cmlAmiId: string = ctx('cmlAmiId');

    // Accepts a single CIDR (allowedCidr) or several (allowedCidrs), so extra
    // operator locations survive a redeploy instead of being revoked.
    const cidrList: string[] = (() => {
      const many = this.node.tryGetContext('allowedCidrs');
      if (Array.isArray(many) && many.length > 0) return many as string[];
      if (typeof many === 'string' && many.trim() !== '') {
        return many.split(',').map((c) => c.trim());
      }
      return [ctx<string>('allowedCidr')];
    })();
    const instanceTypeName: string = ctx('instanceType', 'm8i.xlarge');
    const volumeSizeGiB: number = Number(ctx('volumeSizeGiB', 64));
    const keyName: string | undefined = this.node.tryGetContext('keyName') || undefined;

    // Spot is the default: with a persistent request that stops (rather than
    // terminates) on interruption, the lab survives reclaim and stop/start.
    const useSpotCtx = this.node.tryGetContext('useSpot');
    const useSpot = useSpotCtx !== false && useSpotCtx !== 'false';

    // Bring-your-own network is optional; by default the stack creates a
    // minimal public-subnet VPC so a first deploy needs no prior setup.
    const vpcId: string | undefined = this.node.tryGetContext('vpcId') || undefined;
    let vpc: ec2.IVpc;
    let vpcSubnets: ec2.SubnetSelection;

    if (vpcId) {
      vpc = ec2.Vpc.fromLookup(this, 'Vpc', { vpcId });
      const subnetId: string = ctx('subnetId');
      // ec2.Instance needs the AZ, which cannot be derived from a subnet ID.
      const availabilityZone: string = ctx('subnetAz');
      vpcSubnets = {
        subnets: [
          ec2.Subnet.fromSubnetAttributes(this, 'ImportedSubnet', {
            subnetId,
            availabilityZone,
          }),
        ],
      };
    } else {
      vpc = new ec2.Vpc(this, 'Vpc', {
        maxAzs: 1,
        natGateways: 0,
        ipAddresses: ec2.IpAddresses.cidr('10.20.0.0/16'),
        subnetConfiguration: [
          { name: 'public', subnetType: ec2.SubnetType.PUBLIC, cidrMask: 24 },
        ],
      });
      vpcSubnets = { subnetType: ec2.SubnetType.PUBLIC };
    }

    const sg = new ec2.SecurityGroup(this, 'CmlSg', {
      vpc,
      // Do not reword: changing a security group's description forces a
      // replacement of the group, which can replace the instance with it.
      description: 'CML lab - HTTPS and SSH from my IP only',
      allowAllOutbound: true,
    });
    for (const cidr of cidrList) {
      sg.addIngressRule(ec2.Peer.ipv4(cidr), ec2.Port.tcp(443), 'CML web UI');
      sg.addIngressRule(ec2.Peer.ipv4(cidr), ec2.Port.tcp(22), 'SSH');
    }

    // CloudFormation's AWS::EC2::Instance supports neither
    // CpuOptions.NestedVirtualization nor InstanceMarketOptions, so both are
    // set on a launch template that the instance references.
    const launchTemplate = new ec2.LaunchTemplate(this, 'CmlLt', {
      requireImdsv2: true,
      spotOptions: useSpot
        ? {
            requestType: ec2.SpotRequestType.PERSISTENT,
            interruptionBehavior: ec2.SpotInstanceInterruption.STOP,
          }
        : undefined,
    });
    (launchTemplate.node.defaultChild as ec2.CfnLaunchTemplate).addPropertyOverride(
      'LaunchTemplateData.CpuOptions.NestedVirtualization',
      'enabled'
    );

    const instance = new ec2.Instance(this, 'CmlInstance', {
      vpc,
      vpcSubnets,
      instanceType: new ec2.InstanceType(instanceTypeName),
      machineImage: ec2.MachineImage.genericLinux({ [this.region]: cmlAmiId }),
      securityGroup: sg,
      keyPair: keyName
        ? ec2.KeyPair.fromKeyPairName(this, 'KeyPair', keyName)
        : undefined,
      blockDevices: [
        {
          deviceName: '/dev/sda1',
          volume: ec2.BlockDeviceVolume.ebs(volumeSizeGiB, {
            volumeType: ec2.EbsDeviceVolumeType.GP3,
            encrypted: true,
            deleteOnTermination: true,
          }),
        },
      ],
    });

    const cfnInstance = instance.node.defaultChild as ec2.CfnInstance;
    cfnInstance.launchTemplate = {
      launchTemplateId: launchTemplate.launchTemplateId,
      version: launchTemplate.latestVersionNumber,
    };

    // An Elastic IP keeps the CML URL stable across stop/start.
    const eip = new ec2.CfnEIP(this, 'CmlEip', { domain: 'vpc' });
    new ec2.CfnEIPAssociation(this, 'CmlEipAssoc', {
      instanceId: instance.instanceId,
      allocationId: eip.attrAllocationId,
    });

    cdk.Tags.of(this).add('Project', 'cml-lab');

    new cdk.CfnOutput(this, 'InstanceId', {
      value: instance.instanceId,
      description: 'EC2 instance ID (used by the start/stop/status scripts)',
    });
    new cdk.CfnOutput(this, 'PublicIp', {
      value: eip.attrPublicIp,
      description: 'Elastic IP, stable across stop/start',
    });
    new cdk.CfnOutput(this, 'CmlUrl', {
      value: `https://${eip.attrPublicIp}`,
      description: 'CML web UI',
    });
    new cdk.CfnOutput(this, 'Lifecycle', {
      value: useSpot ? 'spot (persistent, stop on interruption)' : 'on-demand',
      description: 'Purchasing option in effect',
    });
  }
}
