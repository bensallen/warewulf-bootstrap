# warewulf-bootstrap

## Testing as a container with systemd-nspawn 

```
sudo systemd-nspawn --register=false --network-veth -bD initramfs/.install/
```
