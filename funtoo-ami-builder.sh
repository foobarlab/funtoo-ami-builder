#!/bin/bash

CONFIG_REGION="eu-central-1"

SSH_OPTS="-o ConnectTimeout=5
          -o KbdInteractiveAuthentication=no
          -o ChallengeResponseAuthentication=no
          -o UserKnownHostsFile=/dev/null
          -o StrictHostKeyChecking=no
          -o LogLevel=error"

echo "Funtoo AMI Builder"

for required_command in aws jq scp ssh
do
    command -v $required_command >/dev/null 2>&1 || { echo "Command '$required_command' required but it's not available." >&2; exit 1; }
done

if [ -d ~/.aws ]; then
    echo "AWS commandline configuration found in '~/.aws'."
else
    echo "No AWS commandline configuration found."
    echo "Creating a new configuration ..."
    echo
    mkdir -p ~/.aws
    cat > ~/.aws/config <<EOF
[default]
region = CONFIG_REGION
output = json
EOF
    sed -i 's/CONFIG_REGION/'"$CONFIG_REGION"'/g' ~/.aws/config
    echo "The following configuration was written to ~/.aws/config:"
    echo
    cat ~/.aws/config
    echo
    echo "Please enter your credentials:"
    echo
    aws configure
fi

BUILD_UUID=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1)
echo "Created UUID '$BUILD_UUID'"

BUILD_REGION=$( aws configure get region )
echo "Using region '$BUILD_REGION' found in 'awscli' configuration."
[ "$BUILD_REGION" = "$CONFIG_REGION" ] || exit 1 "Configured region '$CONFIG_REGION' does not match region from awscli!"

echo "Creating temporary VPC ..."
BUILD_VPC_ID=`aws ec2 create-vpc --cidr-block 10.0.0.0/28 --query 'Vpc.VpcId' --output text` 
echo "Created VPC with VpcId '$BUILD_VPC_ID'"

echo "Configuring VPC ..."
echo "Enable DNS support and hostnames ..."
aws ec2 modify-vpc-attribute --vpc-id $BUILD_VPC_ID --enable-dns-support "{\"Value\":true}"
aws ec2 modify-vpc-attribute --vpc-id $BUILD_VPC_ID --enable-dns-hostnames "{\"Value\":true}"
echo "Attach Internet Gateway ..."
BUILD_INTERNET_GATEWAY_ID=`aws ec2 create-internet-gateway --query 'InternetGateway.InternetGatewayId' --output text`
aws ec2 attach-internet-gateway --internet-gateway-id $BUILD_INTERNET_GATEWAY_ID --vpc-id $BUILD_VPC_ID
echo "Create Subnet ..."
BUILD_SUBNET_ID=`aws ec2 create-subnet --vpc-id $BUILD_VPC_ID --cidr-block 10.0.0.0/28 --query 'Subnet.SubnetId' --output text`
echo "Modify Subnet to map public IP on launch ..."
aws ec2 modify-subnet-attribute --subnet-id $BUILD_SUBNET_ID --map-public-ip-on-launch "{\"Value\":true}"
echo "Setup routing ..."
BUILD_ROOT_TABLE_ID=`aws ec2 create-route-table --vpc-id $BUILD_VPC_ID --query 'RouteTable.RouteTableId' --output text`
aws ec2 associate-route-table --route-table-id $BUILD_ROOT_TABLE_ID --subnet-id $BUILD_SUBNET_ID
aws ec2 create-route --route-table-id $BUILD_ROOT_TABLE_ID --destination-cidr-block 0.0.0.0/0 --gateway-id $BUILD_INTERNET_GATEWAY_ID
echo "VPC configured:"
aws ec2 describe-vpcs --vpc-id $BUILD_VPC_ID

BUILD_SECURITY_GROUP_NAME="temp_funtoo_ami_builder_sg_$BUILD_UUID"
echo "Trying to create temporary Security group '$BUILD_SECURITY_GROUP_NAME' ..."
BUILD_SECURITY_GROUP_ID=`aws ec2 create-security-group --vpc-id $BUILD_VPC_ID --group-name $BUILD_SECURITY_GROUP_NAME --description "Temporary Funtoo bootstrap Security group" --query 'GroupId' --output text`
echo "Security group ID is $BUILD_SECURITY_GROUP_ID"

echo "Enabling SSH for Security group ..."
aws ec2 authorize-security-group-ingress --group-id "$BUILD_SECURITY_GROUP_ID" --protocol tcp --port 22 --cidr 0.0.0.0/0 --region "$BUILD_REGION"

BUILD_KEY_NAME="temp_key_$BUILD_UUID"
echo "Try to create temporary key-pair ..."
aws ec2 create-key-pair --region "$BUILD_REGION" --key-name "$BUILD_KEY_NAME" --query "KeyMaterial" | tr -d '"' | sed 's/\\n/\n/g'  > $BUILD_KEY_NAME
chmod 400 $BUILD_KEY_NAME

#echo "Got private key:"
#cat $BUILD_KEY_NAME

#BUILD_KEY_FINGERPRINT=$( openssl pkcs8 -in $BUILD_KEY_NAME -inform PEM -outform DER -topk8 -nocrypt | openssl sha1 -c | sed -E 's/\(stdin\)= //' )
#echo "Private key fingerprint in Amazon Format is: '$BUILD_KEY_FINGERPRINT'"

# FIXME the selected AMI is "Funtoo 1.2 (t2 optimized)" not the AMD Ryzen one ... this could be made selectable (see top of script)
echo "Searching for latest Funtoo AMI capable for bootstrapping .."
# TODO can use owners 'aws-marketplace' instead of '679593333241'
# TESTING: aws ec2 describe-images --owners aws-marketplace --filters 'Name=name,Values=Ubuntu*' 'Name=state,Values=available' --query 'sort_by(Images, &CreationDate)[].ImageId' => only take last one ...
# TESTING: aws ec2 describe-images --owners aws-marketplace --filters 'Name=name,Values=Ubuntu*' 'Name=state,Values=available' --query 'sort_by(Images, &CreationDate)[].[CreationDate,ImageId,Name]' --output text
# TESTING: aws ec2 describe-images --owners aws-marketplace --filters 'Name=name,Values=Ubuntu*' 'Name=state,Values=available' --query 'sort_by(Images, &CreationDate)[].[CreationDate,ImageId,Name]' --output text | tail -n1 | gawk '{print $2}'
#BUILD_SEED_AMI_ID=$( aws ec2 describe-images --owners aws-marketplace --filters 'Name=name,Values=Funtoo*' 'Name=state,Values=available' \
#    | jq -r '.Images | sort_by(.CreationDate) | last(.[]).ImageId' )
BUILD_SEED_AMI_ID=`aws ec2 describe-images --owners aws-marketplace --filters 'Name=name,Values=Funtoo*' 'Name=state,Values=available' --query 'sort_by(Images, &CreationDate)[].[ImageId]' --output text | tail -n1`
echo "Found AMI '$BUILD_SEED_AMI_ID'"
#aws ec2 describe-images --image-id "$BUILD_SEED_AMI_ID"
aws ec2 describe-images --image-id $BUILD_SEED_AMI_ID --output table

#echo "Creating and starting a helper instance ..."
#BUILD_HELPER_INSTANCE_ID=$( aws ec2 run-instances \
#    --image-id $BUILD_SEED_AMI_ID \
#    --count 1 \
#    --instance-type "t2.micro" \
#    --instance-initiated-shutdown-behavior "terminate" \
#    --key-name "$BUILD_KEY_NAME" \
#    --security-group-ids "$BUILD_SECURITY_GROUP_ID" \
#    --subnet-id "$BUILD_SUBNET_ID" \
#    --region "$BUILD_REGION" \
#    | jq '.Instances[].InstanceId' | tr -d '"' )

#echo "BUILD_SEED_AMI_ID=$BUILD_SEED_AMI_ID"
#echo "BUILD_KEY_NAME=$BUILD_KEY_NAME"
#echo "BUILD_SECURITY_GROUP_ID=$BUILD_SECURITY_GROUP_ID"
#echo "BUILD_SUBNET_ID=$BUILD_SUBNET_ID"
#echo "BUILD_REGION=$BUILD_REGION"

BUILD_HELPER_INSTANCE_ID=`aws ec2 run-instances \
    --image-id $BUILD_SEED_AMI_ID \
    --count 1 \
    --instance-type t2.micro \
    --instance-initiated-shutdown-behavior terminate \
    --key-name $BUILD_KEY_NAME \
    --security-group-ids $BUILD_SECURITY_GROUP_ID \
    --subnet-id $BUILD_SUBNET_ID \
    --region $BUILD_REGION \
    --query 'Instances[*].InstanceId' \
    --output text`

echo "Created helper instance: '$BUILD_HELPER_INSTANCE_ID'"

# FIXME ugly solution here, better do some polling and continue when instance state is 'running' -> pollAndWait()
echo "Waiting a few seconds to let the helper instance startup process settle ..."
COUNTER=30
while [  $COUNTER -gt 1 ]; do
    sleep 1
    let COUNTER=$COUNTER-1
    echo $COUNTER
done

echo "Helper instance details:"
aws ec2 describe-instances --instance-id $BUILD_HELPER_INSTANCE_ID
aws ec2 describe-instances --instance-id $BUILD_HELPER_INSTANCE_ID --output table

echo "Getting Availability Zone for helper instance ..."
#BUILD_AVAILABILITY_ZONE=$( aws ec2 describe-instances \
#    --instance-id $BUILD_HELPER_INSTANCE_ID \
#    | jq '.Reservations[].Instances[].Placement.AvailabilityZone' | tr -d '"' )
BUILD_AVAILABILITY_ZONE=`aws ec2 describe-instances --instance-id $BUILD_HELPER_INSTANCE_ID --query 'Reservations[].Instances[].Placement.AvailabilityZone' --output text`
echo "Got Availability Zone '$BUILD_AVAILABILITY_ZONE'"

echo "Creating a secondary volume where our bootstrapped system will reside ..."
#BUILD_SECONDARY_VOLUME_ID=$( aws ec2 create-volume \
#    --volume-type "gp2" \
#    --size 8 \
#    --region "$BUILD_REGION" \
#    --availability-zone "$BUILD_AVAILABILITY_ZONE" \
#    | jq .VolumeId | tr -d '"' )
BUILD_SECONDARY_VOLUME_ID=`aws ec2 create-volume --volume-type "gp2" --size 8 --region "$BUILD_REGION" --availability-zone "$BUILD_AVAILABILITY_ZONE" --query 'VolumeId' --output text`
echo "Created secondary volume with VolumeId '$BUILD_SECONDARY_VOLUME_ID'"

# FIXME ugly solution here, better do some polling and continue when volume is 'available' -> pollAndWait()
echo "Waiting a few seconds to let the volume creation process settle ..."
COUNTER=30
while [  $COUNTER -gt 1 ]; do
    sleep 1
    let COUNTER=$COUNTER-1
    echo $COUNTER
done

echo "Attaching secondary volume ..."
aws ec2 attach-volume \
    --device "xvdb" \
    --instance-id "$BUILD_HELPER_INSTANCE_ID" \
    --volume-id "$BUILD_SECONDARY_VOLUME_ID"

echo "Getting public DNS name for helper instance ..."
BUILD_HELPER_INSTANCE_PUBLIC_DNS=$( aws ec2 describe-instances \
    --instance-id $BUILD_HELPER_INSTANCE_ID \
    | jq '.Reservations[].Instances[].PublicDnsName' | tr -d '"' )
echo "Got helper instance public DNS '$BUILD_HELPER_INSTANCE_PUBLIC_DNS'"

echo "Trying to upload boostrap.sh script:"
echo "This may take a while, please be patient and confirm the authenticity of host when asked ..."
# FIXME for security reasons there is no good way to avoid the user interaction here -- any ideas?
#echo "scp -i $BUILD_KEY_NAME bootstrap.sh ec2-user@$BUILD_HELPER_INSTANCE_PUBLIC_DNS:/home/ec2-user/"
scp $SSH_OPTS -i "$BUILD_KEY_NAME" bootstrap.sh ec2-user@$BUILD_HELPER_INSTANCE_PUBLIC_DNS:/home/ec2-user/

echo "Excuting bootstrap script ..."
ssh $SSH_OPTS -i "$BUILD_KEY_NAME" ec2-user@$BUILD_HELPER_INSTANCE_PUBLIC_DNS "sudo /home/ec2-user/bootstrap.sh"
echo "Completed bootstrapping! :)"

sleep 10

echo "Detaching secondary volume ..."
aws ec2 detach-volume --volume-id $BUILD_SECONDARY_VOLUME_ID

sleep 10

echo "Terminate helper instance ..."
aws ec2 terminate-instances --instance-id $BUILD_HELPER_INSTANCE_ID

# FIXME should wait here until instance is terminated ...

sleep 10

echo "Creating snapshot of secondary volume ..."
BUILD_SNAPSHOT_ID=$( aws ec2 create-snapshot \
    --volume-id $BUILD_SECONDARY_VOLUME_ID \
    --description "funtoo AMI snapshot" \
    | jq '.SnapshotId' | tr -d '"' )
echo "Created snapshot with SnapshotId '$BUILD_SNAPSHOT_ID'"

# FIXME waitAndPoll() here? snapshot needs to complete
echo "Waiting for snapshot to complete ..."
COUNTER=150
while [  $COUNTER -gt 1 ]; do
    sleep 1
    let COUNTER=$COUNTER-1
    echo $COUNTER
done

# FIXME deregister if image with same name exists
echo "Registering Snapshot as AMI ..."
aws ec2 register-image \
    --block-device-mappings DeviceName="/dev/xvda,Ebs={SnapshotId=$BUILD_SNAPSHOT_ID}" \
    --architecture x86_64 \
    --ena-support \
    --name funtoo-t2-hvm-broadwell \
    --root-device-name /dev/xvda \
    --virtualization-type hvm \
    --region $BUILD_REGION

# FIXME pollAndWait() here? AMI might be complete quite fast
echo "Waiting for AMI to complete ..."
COUNTER=150
while [  $COUNTER -gt 1 ]; do
    sleep 1
    let COUNTER=$COUNTER-1
    echo $COUNTER
done

# FIXME ensure it is safe & possible to delete
echo "Cleanup Snapshot ..."
aws ec2 delete-snapshot --snapshot-id $BUILD_SNAPSHOT_ID

# FIXME ensure it is safe & possible to delete
# FIXME An error occurred (DependencyViolation) when calling the DeleteVpc operation: The vpc 'vpc-0eb836bf5c089b807' has dependencies and cannot be deleted.
echo "Cleanup VPC ..."
aws ec2 delete-vpc --vpc-id $BUILD_VPC_ID

# FIXME ensure it is safe & possible to delete
echo "Cleanup secondary volume ..."
aws ec2 delete-volume --volume-id $BUILD_SECONDARY_VOLUME_ID

echo "Cleanup Security group ..."
aws ec2 delete-security-group --group-id $BUILD_SECURITY_GROUP_ID

echo "Cleanup keys ..."
aws ec2 delete-key-pair --key-name $BUILD_KEY_NAME
rm -f "$BUILD_KEY_NAME"

echo "Done! :)"

