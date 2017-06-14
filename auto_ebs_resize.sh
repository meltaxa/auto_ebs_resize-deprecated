#!/bin/bash
##################
#
# auto_ebs_resize.sh
#
# Automatically resizes a live Linux filesystem (AWS EBS) when capacity is
# over 90%.
#   - Adds 10% more capacity
#   - Modifies the AWS EBS Volume on the fly
#   - Issues a Linux resizefs command to uptake the resize AWS EBS Volume
#   - Does not infinitely resize. You should review the MAX_EBS_SIZE.
#   - All above values are defaults. See below to customise.
#
# Best practices:
#   - Cron daily because AWS EBS modifications are limited to every 6 hours.
#   - Run using the latest AWS CLI (currently Boto hasn't caught up yet).
#
##################

# Change these accordingly:
AWS_CLI=/usr/local/bin/aws
REGION=us-west-1
FS_USAGE=90
PERCENTAGE_INCREASE=10
MAX_EBS_SIZE=250

# Get the current Instance Id
INST_ID=$(curl --silent http://169.254.169.254/latest/meta-data/instance-id)
PID=$$
PID_FILE=/var/run/auto_ebs_resize

terminate() {
   echo $*
   sudo rm -f ${PID_FILE}_${VOL_ID}.pid
   exit 1
}
trap 'terminate "[ERROR] Something went wrong!"' ERR

wait_for() {
    MOD_STATE=$($AWS_CLI ec2 describe-volumes-modifications --region=$REGION \
                --volume-id $VOL_ID --output text | awk '{print $2'})
    if [ "$MOD_STATE" == "modifying" ]; then
        echo -n "[INFO] Waiting for Volume resizing to be ready. Sleeping"
        echo " for a few seconds."
        sleep 5
        wait_for $1
    fi
}

# List all FS devices
# Note: Any errors encountered will break out of the loop
df -h | grep xvd | while read LINE
do
  # Get FS usage percentage
  USE=$(echo $LINE | awk '{print $5}' | sed 's/%//')

  # Find FS over 90% (default) full
  if [ $USE -gt $FS_USAGE ]; then
    FS_NAME=$(echo $LINE | awk '{print $NF}')
    echo "[INFO] ${FS_NAME} is ${USE}% full"

    # Linux device names start with /dev/xvd*
    # and AWS device names are mapped to /dev/sd*
    FS_DEVICE=$(echo $LINE | awk '{print $1}')
    EBS_DEVICE=$(echo $FS_DEVICE | sed 's/xvd/sd/')

    # Find the EBS Volume ID of the FS
    VOL_ID=$($AWS_CLI ec2 describe-volumes --region $REGION \
             --filters Name=attachment.instance-id,Values=$INST_ID \
             --output text | grep $EBS_DEVICE | awk '{print $NF'})
    echo "[INFO] Found $FS_DEVICE ($EBS_DEVICE) as Volume ID $VOL_ID"

    if [ ! -f ${PID_FILE}_${VOL_ID}.pid ]; then
        sudo sh -c "echo $PID > ${PID_FILE}_${VOL_ID}.pid"

        CURRENT_SIZE=$($AWS_CLI ec2 describe-volumes --region $REGION \
                       --filters Name=attachment.instance-id,Values=$INST_ID \
                       --output text | grep $VOL_ID | grep VOLUMES \
                       | awk '{print $6}')

        # Always round up when calculating the new size
        MULTIPLIER=$(awk "BEGIN {printf \"%3f\n\", \
                     (100 + $PERCENTAGE_INCREASE)/100};")
        NEW_SIZE=$(awk "BEGIN {x=($CURRENT_SIZE * $MULTIPLIER); \
                   printf \"%.0f\n\", (x == int(x) ? x : int(x)+1)};")
        if [ $NEW_SIZE -gt $MAX_EBS_SIZE ]; then
            terminate "[ERROR] Reached size limit of $MAX_EBS_SIZE \
                       (see MAX_EBS_SIZE)"
        fi

        DEVICE=$(echo $FS_DEVICE | awk -F/ '{print $NF}')
        VOL_SIZE=$(lsblk -a | grep $DEVICE | awk '{print $4}' | sed 's/G//')
        if [ $VOL_SIZE -ne $NEW_SIZE ]; then
            echo "[INFO] Changing size (G) from $CURRENT_SIZE to $NEW_SIZE"
            $AWS_CLI ec2 modify-volume --region=$REGION --volume-id $VOL_ID \
            --size=$NEW_SIZE
            if [ $? -ne 0 ]; then
                terminate "[ERROR] aws ec2 modify-volume failed to run"
            fi
            sleep 1
        else
            echo "[WARN] Volume has already been resized previously."
        fi
        echo "[INFO] $VOL_ID is ready to be modified"
        wait_for $VOL_ID

        echo "[INFO] $FS_DEVICE is being resized"
        sudo sh -c "resize2fs $FS_DEVICE | tee /tmp/resize2fs.$PID"
        if [ "$(grep nothing /tmp/resize2fs.$PID)" ]; then
            terminate "[ERROR] The volume was resized, but the Linux resize \
                       may not take effect until a reboot."
        fi

        echo "[INFO] $FS_NAME has been resized"
        df -h $FS_DEVICE

        # Clean up
        sudo rm -f ${PID_FILE}_${VOL_ID}.pid
        sudo rm -f /tmp/resize2fs.$PID
    else
        echo "[WARN] Looks like auto expansion is in progress."
    fi
  fi
done
