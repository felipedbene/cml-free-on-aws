#!/usr/bin/env node
import * as cdk from 'aws-cdk-lib';
import { CmlLabStack } from '../lib/cml-lab-stack';

const app = new cdk.App();

// Region resolution order: context -> standard AWS env vars -> us-east-1.
const region =
  app.node.tryGetContext('region') ||
  process.env.CDK_DEPLOY_REGION ||
  process.env.AWS_REGION ||
  process.env.CDK_DEFAULT_REGION ||
  'us-east-1';

new CmlLabStack(app, app.node.tryGetContext('stackName') || 'CmlLabStack', {
  env: {
    account: process.env.CDK_DEPLOY_ACCOUNT || process.env.CDK_DEFAULT_ACCOUNT,
    region,
  },
  description:
    'Cisco Modeling Labs on EC2 with nested virtualization (spot + Elastic IP)',
});
