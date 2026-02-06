# IRL Streaming Server Workspace Guide

This workspace contains the SRT Live Server (SLS), a patched SRT library for bonding support, and the SRTLA utilities. All components are managed via a Nix Flake for native, reproducible builds.

## 1. Environment Setup

This project uses **Nix Flakes**. Ensure you have Nix installed with flakes enabled.

To enter the development environment with all tools (cmake, gcc, etc.) available:
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

### On-Demand (Quick Run)
Instead of manual builds, you can run the components instantly using the flake:
```bash
# Start Server
nix run .#sls -- -c ./sls/src/sls.conf

# Start SRTLA
nix run .#srtla -- --srtla_port 5000 --srt_port 4002
```

### Persistent Services (NixOS Only)
The most "native" way to run these on NixOS is using the provided **NixOS Module**. This ensures they stay alive after disconnect and restart on boot.

1.  **Import the module** in your `flake.nix` (or `configuration.nix`):
    ```nix
    {
      inputs.irl-server.url = "path/to/this/workspace";
      outputs = { self, nixpkgs, irl-server }: {
        nixosConfigurations.your-host = nixpkgs.lib.nixosSystem {
          modules = [
            irl-server.nixosModules.default
            ./configuration.nix
          ];
        };
      };
    }
    ```

2.  **Enable the service** in your `configuration.nix`:
    ```nix
    services.irl-srt-server = {
      enable = true;
      srtla.enable = true; # Enabled by default
    };
    ```
    *This automatically opens the firewall ports (4000, 4001, 4002, 5000) and sets up systemd.*

---

## 4. Connection Guide (User Instructions)

### Publishing (Encoders)

| Type | Protocol | URL Example |
| :--- | :--- | :--- |
| **Direct SRT** (OBS, FFmpeg) | `srt://` | `srt://<IP>:4001?streamid=publish/live/mystream` |
| **Bonded** (BELABOX, Larix) | `srtla://` | `srtla://<IP>:5000` |

> [!IMPORTANT]  
> When using SRTLA, the encoder connects to port **5000** (default). `srtla_rec` then handles the handshake and forwards to the SLS server.

### Playback (Viewers)

- **URL:** `srt://<IP>:4000?streamid=play/live/mystream`

### Monitoring
- **Stats Dashboard:** `http://<IP>:8181/stats`

---

## 5. Updating the Code

To pull updates from the upstream repositories while keeping the Nix fixes:

1.  **Pull Updates**:
    ```bash
    cd srtla && git pull origin main
    # or sls, srt, etc.
    ```
2.  **The Fixes are Automatic**: You don't need to manually patch the files after pulling. The `flake.nix` contains a `postPatch` hook that automatically removes the network-dependent `FetchContent` calls every time you build.

3.  **Update Dependencies**: If you want to update the Nixpkgs (compiler, libraries) versions:
    ```bash
    nix flake update
    ```

4.  **Rebuild**:
    ```bash
    nix build .#sls -o sls-bin
    nix build .#srtla -o srtla-bin
    ```

---

## Workspace Structure
- `sls/`: SRT Live Server source code and configuration.
- `srt/`: Patched `libsrt` (belabox branch) required for bonding support.
- `srtla/`: SRTLA receiver and sender source code.
- `flake.nix`: Unified Nix build configuration. Handles local patches programmatically to keep source repos clean for easy updates.
