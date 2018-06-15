# Artillery-Container-AutoConfig
Sets up a docker container running Binary Defense's Artillery and handles port forwarding of honeyports.

Note: This project needs a bit of love.  It's not quite perfect yet, but I wanted to put it out here because it has been proven effective catching attackers in more than one instance.  Plus, it REALLY frustrated a red teamer during testing, so it of course needs to be expanded for more blue team wins. ;)

## Process

1. Enable required Windows Features for Docker installation
2. Install Docker
3. Build Artillery image
4. Spin up Artillery container instance
5. Port forward connections into container
6. Create firewall rule to permit connections to honeyports
7. Set up audit policy to log connection attempts - these need to be monitored! 

## TLC Opportunities

- [ ] Fix dockerfile to properly install/configure Artillery (it is a bit of a hack job right now)
- [ ] Extend banning of offending hosts to push firewall rules back onto the host instead of the container
- [ ] Set up logging module to handle alerting in case log aggregation solution is not in place
