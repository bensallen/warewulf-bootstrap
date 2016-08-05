# warewulf-bootstrap

[![CircleCI](https://circleci.com/gh/warewulf/warewulf-bootstrap.svg?style=svg)](https://circleci.com/gh/warewulf/warewulf-bootstrap)

## Testing as a container with systemd-nspawn 

```
sudo systemd-nspawn --register=false --network-veth -bD initramfs/.install/
```

## Testing as a VM with qemu

```
qemu-system-x86_64 -serial stdio -initrd initramfs.gz -kernel vmlinuz -append "console=ttyS0"
```
