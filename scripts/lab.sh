#!/usr/bin/env bash
# Day-to-day control of the CML lab instance, driven by CloudFormation outputs.
set -euo pipefail

STACK="${CML_STACK:-CmlLabStack}"

# Region comes from the same place the CDK app reads it, so this works even when
# the shell's AWS_REGION points somewhere else entirely.
context_region() {
  local ctx="$(dirname "$0")/../cdk.context.json"
  [ -f "$ctx" ] || return 0
  python3 -c "import json,sys; print(json.load(open('$ctx')).get('region',''))" 2>/dev/null
}
REGION="${CML_REGION:-$(context_region)}"
REGION="${REGION:-${AWS_REGION:-us-east-1}}"

output() {
  aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text
}

require_stack() {
  if ! aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK" \
      >/dev/null 2>&1; then
    echo "Stack '$STACK' not found in $REGION. Deploy it first (npm run deploy)." >&2
    exit 1
  fi
}

case "${1:-}" in
  start)
    require_stack
    ID=$(output InstanceId)
    aws ec2 start-instances --region "$REGION" --instance-ids "$ID" \
      --query 'StartingInstances[0].{Instance:InstanceId,From:PreviousState.Name,To:CurrentState.Name}' \
      --output table
    echo "CML will answer on $(output CmlUrl) once it finishes booting (~3-4 min)."
    ;;
  stop)
    require_stack
    ID=$(output InstanceId)
    aws ec2 stop-instances --region "$REGION" --instance-ids "$ID" \
      --query 'StoppingInstances[0].{Instance:InstanceId,From:PreviousState.Name,To:CurrentState.Name}' \
      --output table
    echo "Stopped. You still pay for the EBS volume and Elastic IP, not the instance."
    ;;
  status)
    require_stack
    ID=$(output InstanceId)
    aws ec2 describe-instances --region "$REGION" --instance-ids "$ID" \
      --query 'Reservations[].Instances[].{State:State.Name,Type:InstanceType,Lifecycle:InstanceLifecycle,PublicIp:PublicIpAddress,NestedVirt:CpuOptions.NestedVirtualization}' \
      --output table
    URL=$(output CmlUrl)
    if curl -sk --max-time 8 "$URL/api/v0/system_information" >/dev/null 2>&1; then
      echo "CML API: reachable at $URL"
    else
      echo "CML API: not answering at $URL (still booting, or your IP is not in allowedCidrs)"
    fi
    ;;
  url)
    require_stack
    output CmlUrl
    ;;
  fix-network)
    require_stack
    ID=$(output InstanceId)
    exec python3 "$(dirname "$0")/fix-bridge-mac.py" --instance-id "$ID" --region "$REGION"
    ;;
  *)
    cat <<USAGE
Usage: $(basename "$0") {start|stop|status|url|fix-network}

  start        Start the lab instance
  stop         Stop it (keeps the Elastic IP and disk)
  status       Instance state plus a CML API reachability probe
  url          Print the CML web UI URL
  fix-network  One-time bridge MAC alignment for a freshly created instance

Environment: CML_STACK (default CmlLabStack), AWS_REGION (default us-east-1)
USAGE
    exit 1
    ;;
esac
