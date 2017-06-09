# auto_ebs_resize

Automatically resizes a live Linux filesystem (AWS EBS volume) when capacity is over 90%.
  - Adds 10% more capacity
  - Modifies the AWS EBS Volume on the fly
  - Issues a Linux resizefs command to uptake the resized AWS EBS Volume
  - Does not infinitely resize. You should review the MAX_EBS_SIZE.
  - All above values are defaults. See below to customise.

Best practices:
  - Cron daily because AWS EBS modifications are limited to every 6 hours.
  - Run using the latest AWS CLI (currently Boto hasn't caught up yet).
