# OpenFortiVPN for Omarchy

An [Omarchy](https://omarchy.org/) bar widget for FortiGate VPNs that log in with SAML through
[openfortivpn](https://github.com/adrienverge/openfortivpn). The widget shows the tunnel state and switches between
profiles. While a login is in progress, it opens the SAML login link. When a connection fails, it shows the log.
The `fortivpn` CLI does the same from a terminal, including over SSH.

Each profile runs as its own instance of the packaged systemd unit, `openfortivpn@<profile>.service`. The tunnel
therefore survives a shell restart or logout, and its log goes to the journal.

## Install

```bash
omarchy plugin add https://github.com/sergey-frv/omarchy-openfortivpn.git --yes
~/.config/omarchy/plugins/sergey-frv.openfortivpn/install.sh
```

The first command clones the plugin into `~/.config/omarchy/plugins/sergey-frv.openfortivpn`. The second installs the
system part and adds the widget to the right section of the bar. It asks for the sudo password and does the
following:

1. Installs the `openfortivpn` package.
2. Writes `/etc/openfortivpn/<profile>.conf` for every profile listed in `~/.config/openfortivpn-profiles.conf`.
3. Installs the drop-in `/etc/systemd/system/openfortivpn@.service.d/saml.conf`, which adds `--saml-login` to the
   unit.
4. Installs the polkit rule `/etc/polkit-1/rules.d/50-openfortivpn.rules`, which lets members of `wheel` start and
   stop `openfortivpn@*.service` without a password.
5. Links `~/.local/bin/fortivpn` to `bin/fortivpn` of the plugin.

Rerun `install.sh` after you edit the profile file. Profiles removed from the file lose their generated config.
`install.sh` never overwrites a config in `/etc/openfortivpn` that it did not generate.

## Profiles

`~/.config/openfortivpn-profiles.conf` has one profile per line:

```
# name | host:port[/realm] |
work     | vpn.example.com:443 |
work-old | vpn-old.example.com:10443/staff |
```

- **name**: letters, digits, `_` and `-`. It becomes the instance name `openfortivpn@<name>.service`.
- **host:port/realm**: the FortiGate address. The port and the realm are optional.
- **third column**: kept for compatibility. Extra arguments are ignored with a warning, because the service
  passes only the host, the port and the realm.

## Use

- **Bar widget**: a click opens the panel. The panel shows the tunnel state, lists the profiles, and connects or
  disconnects them. While the tunnel is up, the header shows its address and how long it has been up; a click on
  the address, or the `c` key, copies it to the clipboard. Below the header, the panel shows the public IP: the
  address the internet sees you from while the tunnel is up, which a click copies as well. While the SAML login
  is in progress, the panel offers the login link. After a failure, it offers the log. The shield icon is dimmed
  while the tunnel is down, pulses while it connects, and turns red when the connection fails.
- **Public IP**: the widget asks Cloudflare's `https://www.cloudflare.com/cdn-cgi/trace` once when the tunnel
  comes up or switches profile, and again when the panel opens if the last answer is older than a minute. The
  lookup goes by name, like an ordinary site: a network may send traffic to the `1.1.1.1` resolver out of another
  exit, which would show an address other websites do not see. That request shows your address to Cloudflare. To
  switch the lookup off, set `publicIpLookup` to `false` in the widget's settings
  (`omarchy bar set sergey-frv.openfortivpn publicIpLookup false`); the row disappears and no request is made.
- **Notifications**: the widget notifies when the tunnel comes up, when a connection fails, and when the tunnel
  drops without a disconnect from you. The notification about the tunnel coming up can be switched off in the
  widget's settings (`notifyOnConnect`).
- **CLI**:

  ```bash
  fortivpn up [profile]      # connect; asks for the profile when there are several
  fortivpn down              # disconnect
  fortivpn status [--json]   # down | connecting | up | failed; the address and start time when up
  fortivpn profiles [--json]
  fortivpn log [profile]     # journal of the last connection attempt
  ```

  `fortivpn status --json` prints
  `{"profile", "state", "url", "message", "ip", "since"}`: `url` is the SAML login link while connecting,
  `message` the reason of a failure, `ip` the tunnel's IPv4 address and `since` the Unix time it came up.

### Login over SSH

openfortivpn waits for the result of the SAML login on `127.0.0.1:8020` of the machine that runs the tunnel. To
connect a remote machine, forward that port, run `fortivpn up` there and open the printed link in your local
browser:

```bash
ssh -L 8020:127.0.0.1:8020 <host>
```

In an SSH session, `fortivpn up` also copies the link to the local clipboard with OSC 52, if your terminal
supports it.

## Uninstall

```bash
~/.config/omarchy/plugins/sergey-frv.openfortivpn/uninstall.sh
```

The script disconnects the tunnel. It removes the generated profile configs, the drop-in, the polkit rule, the
`fortivpn` link, the `openfortivpn` package and the plugin. The profile file `~/.config/openfortivpn-profiles.conf`
stays.

`omarchy plugin remove sergey-frv.openfortivpn` removes only the widget and leaves the system part in place.

## Development

The plugin logic lives in `Model.js`, which runs without Qt. Its tests use the Node.js test runner:

```bash
node --test tests/
```

The shell reloads a plugin when its files change in `~/.config/omarchy/plugins/sergey-frv.openfortivpn`. A copy that lives
elsewhere and is linked into that folder is not reloaded, so run `omarchy restart shell` after every edit. Plugin
validation also rejects symlinks inside the plugin folder.

## License

MIT
