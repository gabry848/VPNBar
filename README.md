# VPNBar

A native macOS app built with Swift and SwiftUI for managing OpenVPN profiles through Tunnelblick from the menu bar. It includes traffic statistics, DNS tools, local domains, a CLI, and local service sharing through Cloudflare Tunnel.

## Features

- Connect, disconnect, and choose servers from a popover, without a Dock icon.
- Search by country, check your public IP and ping, view a traffic chart, and run a speed test with `networkQuality`.
- Use AdGuard, Quad9, or Cloudflare DNS presets, or enter custom addresses.
- Map `.test` domains to IPv4 or IPv6 addresses in `/etc/hosts`.
- Use the `vpnbar` CLI and three Shortcuts to connect, disconnect, and copy your IP address.
- Share localhost through a temporary HTTPS link or your own Cloudflare tunnel.

## Requirements

- macOS 14 or later.
- Swift 6 or later, provided by a compatible version of Xcode or the Command Line Tools.
- [Tunnelblick](https://tunnelblick.net/downloads.html) installed and configured for VPN features.
- OpenVPN profiles and credentials from your VPN provider. The interface includes countries from Proton's server catalog.
- An internet connection to download `cloudflared` and use online services.

There are no external Swift dependencies. `cloudflared` is only needed for sharing local services.

The app and bundled Shortcuts currently use Italian labels. This guide quotes those labels exactly so you can find the corresponding controls.

## Setup and build

### 1. Prepare the tools and clone the repository

If the Command Line Tools are missing, install them with `xcode-select --install`. Check that the selected Swift compiler is version 6 or later:

```sh
swift --version
xcrun --find swift
```

Clone the repository:

```sh
git clone https://github.com/gabry848/VPNBar.git
cd VPNBar
```

### 2. Download the sharing component

```sh
zsh scripts/fetch-cloudflared.sh
```

The script downloads the version pinned by this project (`2026.9.3`) from Cloudflare's official GitHub release assets, selects the Apple Silicon or Intel binary, and verifies its SHA-256 checksum before extraction. The resulting `Resources/bin/cloudflared` file is excluded from Git. You can skip this step if you do not use **Condividi** (Share).

### 3. Build and install

```sh
zsh scripts/build.sh
```

The script creates `build/VPNBar.app` with the CLI and helper executables included. It uses `.build/` for build caches and signs the app locally with an ad hoc signature.

Move `build/VPNBar.app` to `/Applications` and open it. The app appears in the menu bar. Installation at `/Applications/VPNBar.app` is required by the paths used in the bundled Shortcuts.

The locally built app is not notarized. The build script does not install the app or change network settings.

### 4. Configure Tunnelblick and VPN profiles

1. Install Tunnelblick from its official website and launch it.
2. Download your provider's OpenVPN profiles into a private folder. For Proton, follow the [profile download guide](https://protonvpn.com/support/vpn-config-download) and select macOS and your preferred protocol.
3. Before importing each file, name it `VPNBar-<COUNTRY>-<SERVER>.ovpn`, for example `VPNBar-NL-SERVER01.ovpn`.
4. Drag the files onto the Tunnelblick icon to import them, and check that the installed configurations keep those names. See the [Tunnelblick configuration guide](https://tunnelblick.net/cConfigT.html) for details.
5. Test a connection directly in Tunnelblick and enter your OpenVPN credentials. Proton's OpenVPN credentials differ from your account password; see the [Proton guide for Tunnelblick](https://protonvpn.com/support/mac-vpn-setup). Save them in Keychain through Tunnelblick.
6. Open VPNBar and click **Abilita controllo VPN** (Enable VPN control). Allow automation of Tunnelblick when macOS asks.

If you previously denied access, check **System Settings → Privacy & Security → Automation**.

The app recognizes the country codes `CA`, `CH`, `JP`, `MX`, `NL`, `NO`, `PL`, `RO`, `SG`, and `US`. A country is available only when at least one recognized profile is installed; server availability depends on your provider and plan. VPNBar does not manage profiles with other names. If an unrelated Tunnelblick configuration is active, VPNBar cannot switch servers.

## CLI and Shortcuts

From the panel opened by the terminal icon, you can create a link at `~/.local/bin/vpnbar`. If needed, add `~/.local/bin` to the `PATH` in your `~/.zshrc`:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

Alternatively, run `/Applications/VPNBar.app/Contents/Helpers/vpnbar` directly.

```sh
vpnbar --help
vpnbar status --json
vpnbar connect NL
vpnbar disconnect
vpnbar ip
vpnbar copy-ip
vpnbar dns adguard
vpnbar dns custom 1.1.1.1,1.0.0.1
vpnbar dns system
vpnbar domain add api.project.test 127.0.0.1
vpnbar domains --json
vpnbar domain remove api.project.test
vpnbar share http://localhost:3000
vpnbar share status
vpnbar share stop
```

The CLI communicates with the running app. VPN control must be enabled before connecting. DNS and domain changes require macOS administrator approval.

You can import the files in `Resources/Shortcuts/` into Shortcuts, including from the app panel: **Connetti VPN** (Connect VPN), **Disconnetti VPN** (Disconnect VPN), and **Copia IP VPN** (Copy VPN IP). The connection Shortcut uses `NL`; you can edit that value in the Shortcut. If prompted, allow scripts to run in Shortcuts' advanced settings.

## DNS, domains, and sharing

**DNS:** Choose a preset and click **Applica DNS** (Apply DNS). Changes affect enabled network services and persist after the app closes. Use **DNS originali → Ripristina DNS originali** (Original DNS → Restore original DNS), or `vpnbar dns system`, to restore the saved settings. The backup is stored at `/Library/Application Support/VPNBarNetwork/dns-backup.json`. Presets use traditional DNS; DNS filtering does not block every advertisement.

**Domains:** Map a name such as `api.project.test` to `127.0.0.1`, then open, for example, `http://api.project.test:3000`. Changes are limited to VPNBar's managed block in `/etc/hosts` and persist without a VPN connection. This feature does not support wildcards, ports, or HTTPS certificates.

**Sharing:** Start your local service, enter `http://localhost:3000`, and click **Condividi** (Share). A [Quick Tunnel](https://developers.cloudflare.com/tunnel/get-started/quick-tunnels/) creates a temporary public URL without a Cloudflare account. Anyone with the link can access the service, so use it only for content you intend to share. **Interrompi** (Stop) or quitting VPNBar ends the tunnel.

**Custom domain:** This requires an existing Cloudflare tunnel, a domain routed to that tunnel, its UUID, and the corresponding JSON credentials file. Enter these details under **Usa il mio dominio** (Use my domain). Keep the credentials file outside the repository. VPNBar does not create accounts, tunnels, or DNS records.

## Tests and project structure

```sh
zsh scripts/test.sh
```

The core tests cover validation, `/etc/hosts` management, DNS transactions and rollback, and the control protocol. They use a simulated DNS backend and do not change your Mac's network settings.

| Path | Contents |
| --- | --- |
| `Sources/VPNBar/` | Menu bar app and interface |
| `Sources/VPNBarCore/` | Validation, settings, and shared logic |
| `Sources/VPNBarCLI/` | `vpnbar` command |
| `Sources/VPNBarNetwork/` | Helper for DNS and local domains |
| `Sources/VPNBarShareAgent/` | Sharing supervisor |
| `Resources/` | App metadata, Shortcuts, and the cloudflared license |
| `Tests/` | Core tests |
| `scripts/` | cloudflared download, build, and test scripts |

## Limitations and local data

VPNBar relies on Tunnelblick for the tunnel and credentials. It does not implement a kill switch. During a disconnection or server switch, traffic may use your regular network. A connected status alone does not guarantee protection from DNS or IPv6 leaks.

The public IP check contacts `api.ipify.org`, ping uses `1.1.1.1`, and the speed test generates traffic with `networkQuality`. These services can see the IP address used by your connection.

App settings, CLI requests, and temporary sharing configurations are stored in `~/Library/Application Support/VPNBar/`. If you set `VPNBAR_DATA_DIR`, use a private directory outside the repository.

## GitHub repository

The source code is published at [gabry848/VPNBar](https://github.com/gabry848/VPNBar). The repository includes the source code, tests, scripts, and resources needed to build the app. `.gitignore` excludes VPN profiles, personal keys and certificates, credentials, runtime data, builds, logs, verification screenshots, and local editor and agent state. The cloudflared binary is downloaded during setup; its [Apache 2.0 license](Resources/cloudflared-LICENSE.txt) is included.

Keep profiles and credentials outside the repository. The ignore rules cannot recognize every possible private filename or remove data already present in Git history.
