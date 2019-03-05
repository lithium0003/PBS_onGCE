# PBS_onGCE
Script to create a cluster of PBS Professional on Google Compute Engine(GCE)

## Discription
This script can create a master node and computation nodes with PBS Pro job control system (https://github.com/pbspro/pbspro) on Google Compute Engine (https://cloud.google.com/compute/).

## How to use
Open a Google Cloud Shell.
```bash
git clone https://github.com/lithium0003/PBS_onGCE.git
cd PBS_onGCE
./master.sh
```
Change parameters in header of script for your environments. 

## Requirements
By default, total CPU counts of each region on GCE is limted up to 24. If you need more cores, you should request to grow the limitation.
