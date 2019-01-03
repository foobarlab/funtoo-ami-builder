#!/bin/bash

CONFIG_REGION="eu-central-1"

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

echo "Got private key:"
cat $BUILD_KEY_NAME
