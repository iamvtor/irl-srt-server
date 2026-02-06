{
  description = "IRL Streaming Server Workspace (SLS + Patched SRT + SRTLA)";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
      pkgsFor = system: import nixpkgs { inherit system; };
    in
    {
      packages = forAllSystems (system:
        let
          pkgs = pkgsFor system;
        in
        rec {
          # 1. Patched SRT Library (belabox branch)
          libsrt-belabox = pkgs.stdenv.mkDerivation {
            pname = "libsrt-belabox";
            version = "unstable";
            src = ./srt;
            nativeBuildInputs = [ pkgs.cmake pkgs.tcl pkgs.pkg-config ];
            buildInputs = [ pkgs.openssl pkgs.zlib ];
            cmakeFlags = [
              "-DENABLE_APPS=OFF"
              "-DENABLE_SHARED=ON"
              "-DENABLE_STATIC=OFF"
              "-DCMAKE_POLICY_VERSION_MINIMUM=3.5"
            ];
            # Fix malformed .pc files (double slashes / incorrect prefixing)
            postInstall = ''
              find $out -name "*.pc" -exec sed -i "s|//|/|g" {} +
              find $out -name "*.pc" -exec sed -i "s|libdir=.*|libdir=$out/lib|g" {} +
              find $out -name "*.pc" -exec sed -i "s|includedir=.*|includedir=$out/include|g" {} +
            '';
          };

          # 2. SRTLA Utilities
          srtla = pkgs.stdenv.mkDerivation {
            pname = "srtla";
            version = "unstable";
            src = ./srtla;
            nativeBuildInputs = [ pkgs.cmake pkgs.pkg-config ];
            buildInputs = [ libsrt-belabox pkgs.openssl pkgs.spdlog pkgs.argparse ];
            
            # Patch CMake to use system libraries instead of FetchContent
            # This keeps srtla/ folder clean for 'git pull'
            postPatch = ''
              substituteInPlace CMakeLists.txt \
                --replace-fail "include(FetchContent)" "find_package(spdlog REQUIRED)" \
                --replace-fail '"deps/argparse/include"' ""
              
              # Remove the multi-line FetchContent_Declare block
              sed -i '/FetchContent_Declare/,/)/d' CMakeLists.txt
              # Remove FetchContent_MakeAvailable line
              sed -i '/FetchContent_MakeAvailable/d' CMakeLists.txt
            '';

            cmakeFlags = [
              "-DFETCHCONTENT_FULLY_DISCONNECTED=ON"
              "-DSPDLOG_BUILD_SHARED=ON"
            ];
            installPhase = ''
              mkdir -p $out/bin
              cp srtla_rec srtla_send $out/bin/
            '';
          };

          # 3. SRT Live Server (SLS)
          sls = pkgs.stdenv.mkDerivation {
            pname = "srt-live-server";
            version = "unstable";
            src = ./sls;
            nativeBuildInputs = [ pkgs.cmake pkgs.pkg-config ];
            buildInputs = [
              libsrt-belabox
              pkgs.openssl
              pkgs.zlib
            ];
            # Point CMake to the libsrt we just built
            cmakeFlags = [
              "-DSRT_INCLUDE_DIR=${libsrt-belabox}/include"
              "-DSRT_LIBRARY=${libsrt-belabox}/lib/libsrt.so"
            ];

            installPhase = ''
              mkdir -p $out/bin
              cp bin/* $out/bin/
            '';
          };

          default = sls;
        });

      apps = forAllSystems (system: {
        sls = {
          type = "app";
          program = "${self.packages.${system}.sls}/bin/srt_server";
        };
        srtla = {
          type = "app";
          program = "${self.packages.${system}.srtla}/bin/srtla_rec";
        };
      });

      nixosModules.default = { config, lib, pkgs, ... }:
        let
          cfg = config.services.irl-srt-server;
          system = pkgs.stdenv.hostPlatform.system;
          # Access the packages from the flake's outputs for the current system
          flakePkgs = self.packages.${system};
        in
        {
          options.services.irl-srt-server = {
            enable = lib.mkEnableOption "IRL Streaming Server (SLS)";
            
            package = lib.mkOption {
              type = lib.types.package;
              default = flakePkgs.sls;
              description = "The SLS server package to use.";
            };

            configPath = lib.mkOption {
              type = lib.types.path;
              default = ./sls/src/sls.conf;
              description = "Path to the sls.conf file.";
            };

            srtla = {
              enable = lib.mkOption {
                type = lib.types.bool;
                default = true;
                description = "Whether to enable the SRTLA receiver proxy.";
              };

              package = lib.mkOption {
                type = lib.types.package;
                default = flakePkgs.srtla;
                description = "The SRTLA package to use.";
              };

              port = lib.mkOption {
                type = lib.types.port;
                default = 5000;
                description = "Port to bind the SRTLA socket to.";
              };

              forwardPort = lib.mkOption {
                type = lib.types.port;
                default = 4002;
                description = "The SLS port to forward bonded traffic to.";
              };
            };
          };

          config = lib.mkIf cfg.enable {
            systemd.services.srt-server = {
              description = "SRT Live Server (SLS)";
              after = [ "network.target" ];
              wantedBy = [ "multi-user.target" ];
              serviceConfig = {
                ExecStart = "${cfg.package}/bin/srt_server -c ${cfg.configPath}";
                Restart = "always";
                DynamicUser = true;
                StateDirectory = "sls";
                WorkingDirectory = "/var/lib/sls";
              };
            };

            systemd.services.srtla-rec = lib.mkIf cfg.srtla.enable {
              description = "SRTLA Receiver Proxy";
              after = [ "srt-server.service" ];
              wantedBy = [ "multi-user.target" ];
              serviceConfig = {
                ExecStart = "${cfg.srtla.package}/bin/srtla_rec --srtla_port ${toString cfg.srtla.port} --srt_port ${toString cfg.srtla.forwardPort}";
                Restart = "always";
                DynamicUser = true;
              };
            };

            # Open default ports in the firewall
            networking.firewall.allowedUDPPorts = [ 4000 4001 4002 ] ++ (if cfg.srtla.enable then [ cfg.srtla.port ] else []);
            networking.firewall.allowedTCPPorts = [ 8181 ];
          };
        };

      devShells = forAllSystems (system:
        let
          pkgs = pkgsFor system;
          libs = self.packages.${system};
        in
        {
          default = pkgs.mkShell {
            buildInputs = with pkgs; [
              cmake
              gcc
              pkg-config
              openssl
              zlib
              tcl
              libs.libsrt-belabox
              libs.srtla
              libs.sls
            ];

            shellHook = ''
              export LD_LIBRARY_PATH="${self.packages.${system}.libsrt-belabox}/lib:$LD_LIBRARY_PATH"
              echo "IRL Streaming Workspace Loaded"
              echo "Packages available: srt_server, srt_client, srtla_rec"
            '';
          };
        });
    };
}
