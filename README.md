# IRL Streaming Server Workspace

This workspace provides a unified, native development environment for the **SRT Live Server (SLS)**, a **patched SRT library (belabox)**, and the **SRTLA bonding utilities**.

All components are managed via **Nix Flakes**, ensuring reproducible builds and easy dependency management without Docker.

---

## 1. Environment Setup

To enter the development environment with all necessary build tools (cmake, gcc, openssl, etc.):
```bash
nix develop
```

## 2. Building

Build the server and bonding tools from the root directory:

```bash
# Build the SRT Live Server
nix build .#sls -o sls-bin

# Build the SRTLA utilities (receiver/sender)
nix build .#srtla -o srtla-bin

# Build the Patched SRT Library (to inspect headers/libs)
nix build .#libsrt-belabox -o srt-lib
```

These commands create `sls-bin`, `srtla-bin`, and `srt-lib` symlinks in the root.

## 3. Running

### On-Demand (Quick Run)
Run the components instantly using the flake without manual builds:
```bash
# Start Server
nix run .#sls -- -c ./sls/src/sls.conf

# Start SRTLA
nix run .#srtla -- --srtla_port 5000 --srt_port 4002
```

### Persistent Services (NixOS Only)
The most robust way to run these on NixOS is using the provided **NixOS Module**. This ensures they start on boot and auto-restart if they crash.

1.  **Add to your system's `flake.nix` inputs**:
    ```nix
    {
      inputs.irl-srt-server.url = "github:your-username/irl-srt-server";
      # Or local path: "path:/home/vtor/projects/irl-srt-server"

      outputs = { self, nixpkgs, irl-srt-server, ... }: {
        nixosConfigurations.your-host = nixpkgs.lib.nixosSystem {
          modules = [
            irl-srt-server.nixosModules.default
            ./configuration.nix
          ];
        };
      };
    }
    ```

2.  **Enable the service**:
    ```nix
    services.irl-srt-server = {
      enable = true;
      srtla.enable = true; # Enabled by default
    };
    ```
    *This automatically opens firewall ports (4000-4002, 5000, 8181) and sets up systemd.*

---

## 4. Connection Guide

### Publishing (Encoders)

| Type | Protocol | URL Example |
| :--- | :--- | :--- |
| **Direct SRT** (OBS, FFmpeg) | `srt://` | `srt://<IP>:4001?streamid=publish/live/mystream` |
| **Bonded** (BELABOX, Larix) | `srtla://` | `srtla://<IP>:5000` |

> [!IMPORTANT]  
> When using SRTLA, the encoder connects to port **5000**. The proxy then forwards traffic to the internal SLS port.

### Playback & Monitoring
- **Playback URL:** `srt://<IP>:4000?streamid=play/live/mystream`
- **Stats Dashboard:** `http://<IP>:8181/stats`

---

## 5. Maintenance

### Updating Code
Pull updates from upstream while keeping Nix fixes:
```bash
cd srtla && git pull origin main
# The flake.nix automatically applies build-time patches via postPatch
```

### Updating Dependencies
Update the Nixpkgs (compiler, libraries) versions:
```bash
nix flake update
```

---

## Workspace Structure
- `sls/`: SRT Live Server (Submodule).
- `srt/`: Patched `libsrt` (Submodule, `belabox` branch).
- `srtla/`: SRTLA utilities (Submodule).
- `flake.nix`: Unified Nix configuration with build-time patching logic.
