{
  description = "Nix flake for TwintailLauncher – A multi-platform launcher for your anime games";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    crane.url = "github:ipetkov/crane";

    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    flake-utils.url = "github:numtide/flake-utils";

    # TwintailLauncher source – building from stable branch
    twintail-launcher-src = {
      url = "github:TwintailTeam/TwintailLauncher/stable";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      crane,
      rust-overlay,
      flake-utils,
      twintail-launcher-src,
    }:
    flake-utils.lib.eachSystem [ "x86_64-linux" ] (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ rust-overlay.overlays.default ];
        };
        inherit (pkgs) lib;

        # Rust edition 2024 requires Rust >= 1.85
        rustToolchain = pkgs.rust-bin.stable.latest.default;
        craneLib = (crane.mkLib pkgs).overrideToolchain rustToolchain;

        version = "1.1.15";

        # ── 1. Build the Vite / React / TypeScript frontend ──────────────

        frontend = pkgs.buildNpmPackage {
          pname = "twintaillauncher-frontend";
          inherit version;
          src = twintail-launcher-src;

          npmDepsHash = "sha256-lL8vUa83r+oJS86k6hDPcGjUdHVeRV0ohTZjcQVg8Y4=";

          # package.json "build" script: tsc && vite build --mode stable
          npmBuildScript = "build";

          installPhase = ''
            runHook preInstall
            cp -r dist $out
            runHook postInstall
          '';
        };

        # ── 2. Prepare combined source tree ──────────────────────────────
        # Tauri's build.rs expects the built frontend at "../dist" relative
        # to src-tauri/, i.e. at the repository root.

        fullSrc = pkgs.runCommand "twintaillauncher-src" { } ''
          cp -r ${twintail-launcher-src} $out
          chmod -R u+w $out
          cp -r ${frontend} $out/dist
        '';

        # ── 3. Vendor Cargo dependencies ─────────────────────────────────
        # Cargo.lock lives in src-tauri/, not at the repo root, so we
        # point crane at it explicitly.

        cargoVendorDir = craneLib.vendorCargoDeps {
          cargoLock = twintail-launcher-src + "/src-tauri/Cargo.lock";
          outputHashes = {
            # Git dependencies require explicit hashes for the Nix sandbox.
            # Keys must be the full `source` field from Cargo.lock.
            # If these become stale after a Cargo.lock update, rebuild once —
            # the error message will print the correct new hashes.
            "git+https://github.com/TwintailTeam/fischl-rs.git?branch=master#56cbe16798b5749fe0cc739bcec96b0b52c4e3aa" =
              "sha256-ZnZSb/KrVOMU7+xHHW8otDqW6SGFrQZ8pyuB5+0yoT8=";
            "git+https://github.com/TwintailTeam/hdiffpatch-rs.git?branch=master#63c6fad33294afa12110b8d3c84481efe4e30834" =
              "sha256-da/6JTGfnhYcJFsF3Oqs4iSY+RYrJ9Hjk3X6yc2lVPk=";
          };
        };

        # ── 4. Shared native dependencies ────────────────────────────────

        runtimeDeps = with pkgs; [
          # Tauri v2 core — WebKitGTK 4.1 + libsoup 3
          gtk3
          glib
          cairo
          pango
          gdk-pixbuf
          harfbuzz
          webkitgtk_4_1
          libsoup_3
          openssl

          # wgpu / Vulkan (GPU detection)
          vulkan-loader

          # GIO TLS backend — required by WebKitGTK / libsoup 3 for HTTPS
          glib-networking

          # System-tray support
          libayatana-appindicator
        ];

        # Script sourced by non-interactive bash (bash -c "...") to strip
        # GIO_EXTRA_MODULES before it leaks into pressure-vessel, which
        # uses Steam Runtime's glib and can't load NixOS-built GIO modules.
        bashEnvScript = pkgs.writeText "twintaillauncher-bash-env" ''
          unset GIO_EXTRA_MODULES
          unset BASH_ENV
        '';

      in
      {
        packages = {

          # ── 5. Build package directly from source ──────────────
          # Not recommended most of the time, but if you are developing with Nix,
          # then this can be useful, or if you just want the latest development
          # version of Twintail.

          twintaillauncher = let unwrapped = craneLib.buildPackage {
            pname = "twintaillauncher";
            inherit version;
            src = fullSrc;
            inherit cargoVendorDir;

            # The Cargo workspace lives in the src-tauri/ subdirectory.
            # Shift the source root there so crane (and cargo) find the
            # Cargo.lock, Cargo.toml, and src/ in the expected locations.
            # Tauri's tauri.conf.json references frontendDist = "../dist"
            # which still resolves correctly to the repo-root dist/.
            postUnpack = ''
              cd $sourceRoot/src-tauri
              sourceRoot="."
            '';
            cargoLock = twintail-launcher-src + "/src-tauri/Cargo.lock";

            nativeBuildInputs = with pkgs; [
              pkg-config
              cmake # needed by libgit2-sys (vendored C build)
              autoPatchelfHook # patches bundled hpatchz & reaper ELF binaries
            ];

            buildInputs =
              runtimeDeps
              ++ (with pkgs; [
                stdenv.cc.cc.lib # libstdc++ (for autoPatchelfHook)
              ]);

            # The Tauri CLI normally injects --features tauri/custom-protocol
            # automatically.  Since crane bypasses the CLI, we must add it
            # ourselves — without it Tauri falls back to devUrl (localhost)
            # instead of embedding the frontend assets.
            cargoExtraArgs = "--locked --features tauri/custom-protocol";

            # Use system OpenSSL via pkg-config instead of vendoring
            OPENSSL_NO_VENDOR = "1";

            # Wrap the binary with a shell script that chmods copied
            # resource files first.
            # Nix store files are read-only (0555); std::fs::copy preserves
            # those permissions to the data dir, blocking overwrites on
            # subsequent launches.
            postFixup = ''
                            if [ -f $out/bin/twintaillauncher ]; then
                              mv $out/bin/twintaillauncher $out/bin/.twintaillauncher-launcher
                              cat > $out/bin/twintaillauncher << 'WRAPPER'
              #!/bin/sh
              data="''${XDG_DATA_HOME:-$HOME/.local/share}/twintaillauncher"
              chmod -f u+w "$data/hpatchz" "$data/hpatchz.exe" 2>/dev/null || true
              exec "$(dirname "$0")/.twintaillauncher-launcher" "$@"
              WRAPPER
                              chmod +x $out/bin/twintaillauncher
                            fi
            '';

            postInstall = ''
              # ── Resources ──
              # Tauri resolves resources at {exe_dir}/../lib/{identifier}/
              # The app then looks for {resource_dir}/resources/{file}
              mkdir -p $out/lib/twintaillauncher/resources
              install -Dm755 ${fullSrc}/src-tauri/resources/hpatchz \
                $out/lib/twintaillauncher/resources/hpatchz
              install -Dm755 ${fullSrc}/src-tauri/resources/reaper \
                $out/lib/twintaillauncher/resources/reaper

              # ── Desktop entry ──
              install -Dm644 ${fullSrc}/twintaillauncher.desktop \
                $out/share/applications/twintaillauncher.desktop

              # ── Icons ──
              install -Dm644 ${fullSrc}/src-tauri/icons/32x32.png \
                $out/share/icons/hicolor/32x32/apps/twintaillauncher.png
              install -Dm644 ${fullSrc}/src-tauri/icons/128x128.png \
                $out/share/icons/hicolor/128x128/apps/twintaillauncher.png
              install -Dm644 ${fullSrc}/src-tauri/icons/128x128@2x.png \
                $out/share/icons/hicolor/256x256/apps/twintaillauncher.png
            '';
          };
          in
          pkgs.buildFHSEnv {
            name = "twintaillauncher";
            targetPkgs =
              _:
              runtimeDeps
              ++ (with pkgs; [
                coreutils
                bash
                # 32-bit support: pressure-vessel ships i386 ELF helpers
                # (e.g. i386-linux-gnu-capsule-capture-libs) that need the
                # 32-bit dynamic linker and libstdc++.
                pkgsi686Linux.glibc
                pkgsi686Linux.gcc-unwrapped.lib
              ]);
            profile = ''
              # WebKitGTK / libsoup 3 needs glib-networking for HTTPS (TLS).
              export GIO_EXTRA_MODULES=/usr/lib64/gio/modules
              export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
              # Prevent GIO_EXTRA_MODULES from leaking into pressure-vessel.
              # TwintailLauncher launches games via bash -c "..." which
              # sources BASH_ENV (non-interactive bash). The script unsets
              # GIO_EXTRA_MODULES so pressure-vessel's Steam Runtime glib
              # won't try to load NixOS-built GIO modules (ABI mismatch).
              export BASH_ENV=${bashEnvScript}
            '';
            runScript = "${unwrapped}/bin/twintaillauncher";
            extraInstallCommands = ''
              mkdir -p $out/share
              ln -s ${unwrapped}/share/applications $out/share/applications 2>/dev/null || true
              ln -s ${unwrapped}/share/icons $out/share/icons 2>/dev/null || true
            '';
            meta = {
              description = "A multi-platform launcher for your anime games";
              homepage = "https://github.com/TwintailTeam/TwintailLauncher";
              license = lib.licenses.gpl3Only;
              platforms = [ "x86_64-linux" ];
              mainProgram = "twintaillauncher";
            };
          };

          # ── 6. Pre-built binary from GitHub Releases (.deb) ──────────────
          # Mirrors how the COPR RPM spec extracts the .deb — no compilation
          # needed. Much faster than building from source.

          twintaillauncher-bin = let unwrapped = pkgs.stdenv.mkDerivation {
            pname = "twintaillauncher-bin";
            inherit version;
            src = pkgs.fetchurl {
              url = "https://github.com/TwintailTeam/TwintailLauncher/releases/download/ttl-v${version}/twintaillauncher_${version}_amd64.deb";
              hash = "sha256-ZJg0BbKWcocY8xUErE0aDgA7TOk8pnBfQJLHFCH86rA=";
            };

            nativeBuildInputs = with pkgs; [
              autoPatchelfHook
              dpkg
            ];

            buildInputs =
              runtimeDeps
              ++ (with pkgs; [
                stdenv.cc.cc.lib # libstdc++ for autoPatchelfHook
              ]);

            unpackPhase = ''
              dpkg-deb -x $src .
            '';

            installPhase = ''
              runHook preInstall

              # Binary
              install -Dm755 usr/bin/twintaillauncher -t "$out/bin"

              # Resources (hpatchz, reaper, hkrpg_patch.dll)
              install -Dm755 usr/lib/twintaillauncher/resources/hpatchz -t "$out/lib/twintaillauncher/resources"
              install -Dm755 usr/lib/twintaillauncher/resources/reaper -t "$out/lib/twintaillauncher/resources"
              install -Dm644 usr/lib/twintaillauncher/resources/hkrpg_patch.dll -t "$out/lib/twintaillauncher/resources"

              # Desktop entry
              install -Dm644 usr/share/applications/twintaillauncher.desktop -t "$out/share/applications"

              # Icons
              install -Dm644 usr/share/icons/hicolor/32x32/apps/twintaillauncher.png "$out/share/icons/hicolor/32x32/apps/$_pkgname.png"
              install -Dm644 usr/share/icons/hicolor/128x128/apps/twintaillauncher.png "$out/share/icons/hicolor/128x128/apps/$_pkgname.png"
              install -Dm644 usr/share/icons/hicolor/256x256@2/apps/twintaillauncher.png "$out/share/icons/hicolor/256x256@2/apps/$_pkgname.png"

              runHook postInstall
            '';

            postFixup = ''
              mv $out/bin/twintaillauncher $out/bin/.twintaillauncher-launcher
              cat > $out/bin/twintaillauncher << 'WRAPPER'
              #!/bin/sh
              data="''${XDG_DATA_HOME:-$HOME/.local/share}/twintaillauncher"
              chmod -f u+w "$data/hpatchz" "$data/hpatchz.exe" 2>/dev/null || true
              exec "$(dirname "$0")/.twintaillauncher-launcher" "$@"
              WRAPPER
              chmod +x $out/bin/twintaillauncher
            '';

            meta = {
              description = "A multi-platform launcher for your anime games (pre-built binary)";
              homepage = "https://github.com/TwintailTeam/TwintailLauncher";
              license = lib.licenses.gpl3Only;
              platforms = [ "x86_64-linux" ];
              mainProgram = "twintaillauncher";
            };
          };
          in
          pkgs.buildFHSEnv {
            name = "twintaillauncher";
            targetPkgs =
              _:
              runtimeDeps
              ++ (with pkgs; [
                coreutils
                bash
                pkgsi686Linux.glibc
                pkgsi686Linux.gcc-unwrapped.lib
              ]);
            profile = ''
              export GIO_EXTRA_MODULES=/usr/lib64/gio/modules
              export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
              export BASH_ENV=${bashEnvScript}
            '';
            runScript = "${unwrapped}/bin/twintaillauncher";
            extraInstallCommands = ''
              mkdir -p $out/share
              ln -s ${unwrapped}/share/applications $out/share/applications 2>/dev/null || true
              ln -s ${unwrapped}/share/icons $out/share/icons 2>/dev/null || true
            '';
            meta = {
              description = "A multi-platform launcher for your anime games (pre-built binary)";
              homepage = "https://github.com/TwintailTeam/TwintailLauncher";
              license = lib.licenses.gpl3Only;
              platforms = [ "x86_64-linux" ];
              mainProgram = "twintaillauncher";
            };
          };

          default = self.packages.${system}.twintaillauncher-bin;
        };

        # Development shell for hacking on TwintailLauncher
        devShells.default = craneLib.devShell {
          inputsFrom = [ self.packages.${system}.twintaillauncher ];
          packages = with pkgs; [
            rustc
            nodejs
            pnpm
            protobuf
            cargo-tauri
            cargo-xwin
          ];
        };
      }
    );
}
