#!/bin/bash
sudo launchctl kickstart -k system/com.ntfsmagic.ntfsmagicd
sleep 1
sudo 3rdparty/ntfs-3g_ntfsprogs-2022.5.17/ntfsprogs/mkntfs -f -F -L 256GB /dev/disk4s1
