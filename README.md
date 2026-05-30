This is still a work in progress.

This was written for use with Ubuntu 26.04.
Netmaker control plane is behind a Cloudflare Tunnel. No direct, inbound ports on the host.

```sh
curl -fsSL https://raw.githubusercontent.com/ilgmars/netmaker-cloudflared/main/install.sh | sh
```

> Don't pipe scripts from the internet straight into a shell. There is no telling what they can do without your knowledge.
> Download `install.sh`, read it, then run it if you find it safe.
