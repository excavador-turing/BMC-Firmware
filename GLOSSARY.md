# BMC firmware

Words for the firmware image on a Turing Pi 2 BMC, and for checking that image.

## Language

**Flashed hive image**:
The BMC firmware that is already running, before the display, rootfs, and node-MSD changes.
_Avoid_: current image, golden image

**Hygiene image**:
The one firmware build that contains the display shutdown, `rootfstype=erofs`, and the node-MSD links.
_Avoid_: new image, test image

**hw-validate**:
The check that reports pass or fail for a flashed hive image or a hygiene image.
_Avoid_: harness, validator, the script

**Node MSD**:
The mass-storage device a node presents to the BMC, named `/dev/disk/by-tpi/nodeN` once the link exists.
_Avoid_: node disk, USB disk, sdX
