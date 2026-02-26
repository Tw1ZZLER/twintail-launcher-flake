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

    # TwintailLauncher source – override with a specific rev/branch if needed
    twintail-launcher-src = {
      url = "github:TwintailTeam/TwintailLauncher";
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

          # System-tray support
          libayatana-appindicator
        ];

        # ── 5. Pre-built binary from GitHub Releases (.deb) ──────────────
        # Mirrors how the COPR RPM spec extracts the .deb — no compilation
        # needed. Much faster than building from source.

        debSrc = pkgs.fetchurl {
          url = "https://github.com/TwintailTeam/TwintailLauncher/releases/download/ttl-v${version}/twintaillauncher_${version}_amd64.deb";
          hash = "sha256-ZJg0BbKWcocY8xUErE0aDgA7TOk8pnBfQJLHFCH86rA=";
        };

        twintaillauncher-bin = pkgs.stdenv.mkDerivation {
          pname = "twintaillauncher-bin";
          inherit version;
          src = debSrc;

          nativeBuildInputs = with pkgs; [
            autoPatchelfHook
            wrapGAppsHook3
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
            install -Dm755 usr/bin/twintaillauncher $out/bin/twintaillauncher

            # Resources (hpatchz, reaper, hkrpg_patch.dll)
            mkdir -p $out/lib/twintaillauncher/resources
            cp -a usr/lib/twintaillauncher/resources/* $out/lib/twintaillauncher/resources/

            # Desktop entry
            install -Dm644 usr/share/applications/twintaillauncher.desktop \
              $out/share/applications/twintaillauncher.desktop

            # Icons
            for icondir in usr/share/icons/hicolor/*/apps; do
              size=$(basename "$(dirname "$icondir")")
              install -Dm644 "$icondir/twintaillauncher.png" \
                "$out/share/icons/hicolor/$size/apps/twintaillauncher.png"
            done

            runHook postInstall
          '';

          preFixup = ''
            gappsWrapperArgs+=(
              --prefix LD_LIBRARY_PATH : "${
                lib.makeLibraryPath [
                  pkgs.vulkan-loader
                  pkgs.libayatana-appindicator
                ]
              }"
            )
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
      {
        packages = {
          twintaillauncher = craneLib.buildPackage {
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
              wrapGAppsHook3
              autoPatchelfHook # patches bundled hpatchz & reaper ELF binaries
            ];

            buildInputs =
              runtimeDeps
              ++ (with pkgs; [
                stdenv.cc.cc.lib # libstdc++ (for autoPatchelfHook)
              ]);

            # Use system OpenSSL via pkg-config instead of vendoring
            OPENSSL_NO_VENDOR = "1";

            # Extend the GApps wrapper with Vulkan lib path.
            # wrapGAppsHook3 handles wrapping automatically during fixup.
            preFixup = ''
              gappsWrapperArgs+=(
                --prefix LD_LIBRARY_PATH : "${
                  lib.makeLibraryPath [
                    pkgs.vulkan-loader
                    pkgs.libayatana-appindicator
                  ]
                }"
              )
            '';

            postInstall = ''
              # ── Resources ──
              # Tauri resolves resources at {exe_dir}/../lib/{identifier}/
              mkdir -p $out/lib/twintaillauncher
              install -Dm755 ${fullSrc}/src-tauri/resources/hpatchz \
                $out/lib/twintaillauncher/hpatchz
              install -Dm755 ${fullSrc}/src-tauri/resources/reaper \
                $out/lib/twintaillauncher/reaper

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

          default = self.packages.${system}.twintaillauncher-bin;
          inherit twintaillauncher-bin;
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
