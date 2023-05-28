# General Unix shell scripts

**Common to most -**

Environment variables:

​	`DBG=1` -> trace sh

**Scripts**

`boilerplate.sh`

​	Template for new scripts

------

`cockpit-certs.sh`

​	Uses Let's Encrypts `certbot` tool to update existing cockpit certificate

​	-- expects certificate name to match `$HOSTNAME`

------

`join-AD.sh`

​	Join a remote Fedora host to Active Directory.  Requires "Domain Admin" privilege to preset the Computer account in AD with OTP for join on target.  Separate short lived KRB5 ticket created for `<AD Administrator>` is also transferred to target.  If  `<remote account>` is not root then the account must be allowed sudo access.

​	Arguments [optional] ...

​	`[-v|--verbose]`

​	`[-d|--dry-run]`

​	`[-i|--ip=<addr>]`

​	`[l|--login=<remote account>]`

​	`-A|--admin=<AD Administrator>` 

​	`-h|--hostname=<target host>` 

​	`realm-name`

------

`add-cockpit-cert.sh`

​	Get a LetsEncrypt certificate for cockpit on a remote Fedora host.  AWS credentials for "cerbot" are transferred to target.  If  `<remote account>` is not root then the account must be allowed sudo access.

​	Arguments [optional] ...

​	`[-v|--verbose]`

​	`[-d|--dry-run]`

​	`[l|--login=<remote account>]`

​	`[m|--mail=<email address>]`

​	`-h|--hostname=<target host>` 
