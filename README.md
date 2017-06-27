# bpi-r1-setup
script to setup the BPI-R1 Banana PI as a router bridging the four port switch and access point to be on the same network

# Howto:
1. Download the lastest bananian from here: https://www.bananian.org/download
2. Insert your SD card into the card reader.
3. Identify your SD card device using 'dmesg' and 'umount' it.
4. Write the Bananian Linux image to the SD card using the following dd command:
```
dd if=bananian-1604.img of=/dev/<your-sd-card> bs=1M && sync
```
5. mount the root partition of the sd card and copy the script (bpi-r1-setup.bash) from this repo in /root/
6. unmount any sd card partitions
7. place the sd card in the BPI-R1 router and start up
8. default credentials: root/pi
9. change to the bash shell:
```
bash
```
10. run the script:
```
./bpi-r1-setup.bash
```


