# Funtoo AMI builder

This is a experimental development space for creating a Funtoo AMI on Amazon AWS.

## Build steps ##

To make the AMI build process comfortable and desireable fully automatic there are some
build steps which need to be called in order. The concept is as follows:

 * Using Amazon AWS requires an account as access is given by auth token and a
   secret key. The commandline utility 'aws' from package dev-python/awscli
   is responsible to hold these credentials.
 * An AWS environment does include its own Virtual Private Cloud (VPC) which
   can be used to execute all steps to build the AMI.
 * If no AWS environment is given, a new temporary AWS environment will be set up,
   otherwise the given environment will be taken.
 * It is necessary to startup a helper Funtoo instance from an existing AMI.
   The helper instance will run the bootstrap scripts and prepare a snapshot image.
 * Once a snapshot image is created it will be used to generate a new AMI image.
 * Eventually all traces created during the procedure are cleaned if the automatic
   build procedure was chosen, otherwise all resources are left as is.

### Configuration ###

All steps can be configured to be either automatic or use dedicated resources
from an existing AWS environment. The default is to do an automatic procedure where
a temporary VPC is setup, the helper instance does bootstrap a new hdd image, and
eventually a new AMI image is build from the snapshot of that image.
In case of an automatic install all temporary created resources will be cleaned up at the end.

### Ensure a proper AWS environment exists ###

The minimal requirements for the AWS environment are as follows:

 * VPC with its own subnet, routing and gateway
 * Permission to create EC2 instances and Snapshots
 * A ssh key for connecting and transferring data to an EC2 instance

### Create a new Funtoo helper instance ###

The helper instance is actually a Funtoo system created from an existing Funtoo AMI build.
It holds two hdd volumes, of which one is the helper system and the other is the hdd
which works as initial volume for a new AMI.

Once the instance is created it can usually being accessed via SSH. It therefore needs SSH keys
and a public IP address. Other ways would be connecting through a dedicated VPN which is skipped
atm in favor of simplicity.

### Upload data to AWS ###

The helper instance serves primary as temporary stage to prepare an initial hdd image.
Therefore a few files have to be copied over and some commands need to run.

The following steps need to be taken to generate this image:

 * Get a recent Funtoo Stage3 tarball
 * Configure the system to include everything needed (hostname, networking, drivers, init scripts)
 * Install and configure grub
 
After running these steps the helper instance can be shutdown and trashed as it is no more needed.

### Build AMI ###

What remains after the previous steps is an EBS volume which is snapshotted. A new AMI can be created
from this snapshot.

### Cleanup AWS environment ###

In case the automatic build procedure was chosen there are a few things in the AWS environment which
should be cleaned properly. These include:

 * The temporary created VPC with all its components (subnets, routing, gateway)
 * The helper instance
 * The snapshot image

Optionally it might be useful if the publishing and cleanup of existing AMI's is automated aswell
(not yet included).

## Useful Links ##

Some resources found during development of this script:

#### Amazon AWS cli ####

 * [AWS Commandline Interface User Guide](https://docs.aws.amazon.com/en_us/cli/latest/userguide/cli-chap-welcome.html)

#### Gentoo ####

 * [gentoo-aws-builder](https://github.com/sormy/gentoo-ami-builder)
 * [Gentoo on AWS](https://www.artembutusov.com/gentoo-on-aws/)
