{
  description = "IRL Streaming Server Workspace (SLS + Patched SRT + SRTLA)";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    # Component Sources
    sls-src = { url = "github:irlserver/irl-srt-server"; flake = false; };
    srt-src = { url = "github:irlserver/srt/belabox"; flake = false; };
    srtla-src = { url = "github:irlserver/srtla"; flake = false; };

    # SLS Submodule Alternatives (to fix recursive fetch issues)
    spdlog-src = { url = "github:irlserver/spdlog/1.9.2"; flake = false; };
    json-src = { url = "github:nlohmann/json"; flake = false; };
    thread-pool-src = { url = "github:bshoshany/thread-pool"; flake = false; };
    httplib-src = { url = "github:yhirose/cpp-httplib"; flake = false; };
    cxxurl-src = { url = "github:chmike/CxxUrl"; flake = false; };
    
    # SRTLA Submodule Alternatives
    argparse-src = { url = "github:p-ranav/argparse"; flake = false; };
  };

  outputs = { self, nixpkgs, sls-src, srt-src, srtla-src, spdlog-src, json-src, thread-pool-src, httplib-src, cxxurl-src, argparse-src }:
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
          libsrt-belabox = pkgs.stdenv.mkDerivation {
            pname = "libsrt-belabox";
            version = "unstable";
            src = srt-src;
            nativeBuildInputs = [ pkgs.cmake pkgs.tcl pkgs.pkg-config ];
            buildInputs = [ pkgs.openssl pkgs.zlib ];
            cmakeFlags = [
              "-DENABLE_APPS=OFF"
              "-DENABLE_SHARED=ON"
              "-DENABLE_STATIC=OFF"
              "-DCMAKE_POLICY_VERSION_MINIMUM=3.5"
            ];
            postInstall = ''
              find $out -name "*.pc" -exec sed -i "s|//|/|g" {} +
            '';
          };

          srtla = pkgs.stdenv.mkDerivation {
            pname = "srtla";
            version = "unstable";
            src = srtla-src;
            nativeBuildInputs = [ pkgs.cmake pkgs.pkg-config ];
            buildInputs = [ libsrt-belabox pkgs.openssl ];
            
            postPatch = ''
              # Assemble dependencies into the locations CMake expects
              rm -rf deps/argparse deps/spdlog
              mkdir -p deps/argparse deps/spdlog
              cp -r ${argparse-src}/* deps/argparse/
              cp -r ${spdlog-src}/* deps/spdlog/
              chmod -R +w deps/
            '';

            # Force CMake to use our manually assembled deps instead of fetching
            cmakeFlags = [ 
              "-DSPDLOG_BUILD_SHARED=OFF" 
              "-DFETCHCONTENT_SOURCE_DIR_SPDLOG=../deps/spdlog"
              "-DFETCHCONTENT_FULLY_DISCONNECTED=ON"
            ];
            installPhase = ''
              mkdir -p $out/bin
              cp srtla_rec srtla_send $out/bin/
            '';
          };

          sls = pkgs.stdenv.mkDerivation {
            pname = "srt-live-server";
            version = "unstable";
            src = sls-src;
            nativeBuildInputs = [ pkgs.cmake pkgs.pkg-config ];
            buildInputs = [ libsrt-belabox pkgs.openssl pkgs.zlib ];

            postPatch = ''
              # Assemble dependencies
              rm -rf lib/spdlog lib/json lib/thread-pool lib/cpp-httplib lib/CxxUrl
              mkdir -p lib/spdlog lib/json lib/thread-pool lib/cpp-httplib lib/CxxUrl
              cp -r ${spdlog-src}/* lib/spdlog/
              cp -r ${json-src}/* lib/json/
              cp -r ${thread-pool-src}/* lib/thread-pool/
              cp -r ${httplib-src}/* lib/cpp-httplib/
              cp -r ${cxxurl-src}/* lib/CxxUrl/
              chmod -R +w lib/

              # Fix log file path in default config and ensure Unix line endings
              tr -d '\r' < src/sls.conf > src/sls.conf.tmp
              mv src/sls.conf.tmp src/sls.conf
              substituteInPlace src/sls.conf \
                --replace-fail "log_file logs/srt_server.log;" "log_file /var/log/sls/srt_server.log;"
            '';

            cmakeFlags = [
              "-DSRT_INCLUDE_DIR=${libsrt-belabox}/include"
              "-DSRT_LIBRARY=${libsrt-belabox}/lib/libsrt.so"
            ];

            installPhase = ''
              mkdir -p $out/bin $out/etc
              cp bin/* $out/bin/
              cp src/sls.conf $out/etc/sls.conf
            '';
          };

          default = sls;
        });

      apps = forAllSystems (system: {
        sls = { type = "app"; program = "${self.packages.${system}.sls}/bin/srt_server"; };
        srtla = { type = "app"; program = "${self.packages.${system}.srtla}/bin/srtla_rec"; };
      });

      nixosModules.default = { config, lib, pkgs, ... }:
        let
          cfg = config.services.irl-srt-server;
          system = pkgs.stdenv.hostPlatform.system;
          flakePkgs = self.packages.${system};
        in
        {
          options.services.irl-srt-server = {
            enable = lib.mkEnableOption "IRL Streaming Server (SLS)";
            package = lib.mkOption { type = lib.types.package; default = flakePkgs.sls; };
            configPath = lib.mkOption { 
              type = lib.types.path; 
              default = "${flakePkgs.sls}/etc/sls.conf"; 
            };
            srtla = {
              enable = lib.mkOption { type = lib.types.bool; default = true; };
              package = lib.mkOption { type = lib.types.package; default = flakePkgs.srtla; };
              port = lib.mkOption { type = lib.types.port; default = 5000; };
              forwardPort = lib.mkOption { type = lib.types.port; default = 4002; };
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
                LogsDirectory = "sls";
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

            networking.firewall.allowedUDPPorts = [ 4000 4001 4002 ] ++ (if cfg.srtla.enable then [ cfg.srtla.port ] else []);
            networking.firewall.allowedTCPPorts = [ 8181 ];
          };
        };
    };
}
