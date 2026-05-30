This is still a work in progress.

This was written for use with Ubuntu 26.04.
Netmaker control plane is behind a Cloudflare Tunnel. No direct, inbound ports on the host.

Script collects the variables from user, then generates credentials, installs dependencies and starts the services. If CF allows connection, initial user is set up automatically, with credentials printed to the console and written to the installation dir.

When creating the tunnel, initially, only one hostname can be added. Additional hostnames can be added when revisiting the connector settings.
If CF gives you errors, check the container logs, with `docker stats` and `docker logs <container name>`.

```sh
curl -fsSL https://raw.githubusercontent.com/ilgmars/netmaker-cloudflared/main/install.sh | sh
```

> Don't pipe scripts from the internet straight into a shell. There is no telling what they can do without your knowledge.
> Download `install.sh`, read it, then run it if you find it safe.
