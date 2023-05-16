# General Unix shell scripts

**Common to most -**

Environment variables:

​	`DBG=1` -> trace sh

**Scripts**

`boilerplate.sh`

​	Template for new scripts

`cockpit-certs.sh`

​	Uses Let's Encrypts `certbot` tool to update existing cockpit certificate

​	-- expects certificate name to match `$HOSTNAME`
