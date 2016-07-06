# warewulf-bootstrap

[![CircleCI](https://circleci.com/gh/warewulf/warewulf-bootstrap.svg?style=svg)](https://circleci.com/gh/warewulf/warewulf-bootstrap)

## Testing as a container with systemd-nspawn 

```
sudo systemd-nspawn --register=false --network-veth -bD initramfs/.install/
```
