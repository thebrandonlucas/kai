{
  description = "Kai development environment & packages";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    roc-overlay = {
      url = "github:thebrandonlucas/roc-overlay/75e0d3ae5c9a4d99eb14d2b13cac5a0e22fcd89d";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # No basic-cli release supports the pinned Roc yet (0.23.0-rc1 predates
    # nightly-2026-09-23), so build PR #499 from source; main (e416ec0) has the
    # same tree. Switch to the first release made for these nightlies.
    basic-cli-src = {
      url = "github:roc-lang/basic-cli/473caa2cc4f3fe9ce4e4682158bb80ebc2e19169";
      flake = false;
    };

    rust-overlay = {
      url = "github:oxalica/rust-overlay/fb058ecf6d14837ea152a3d5225ce7f88ee5cde1";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      roc-overlay,
      basic-cli-src,
      rust-overlay,
      ...
    }:
    let
      inherit (nixpkgs) lib;

      version = builtins.readFile ./VERSION;

      rocVersion = lib.trim (builtins.readFile ./.roc-version);

      # Only Linux hosts are built and tested; basic-cli comes from source.
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = lib.genAttrs supportedSystems;
      pkgsFor =
        system:
        import nixpkgs {
          inherit system;
          overlays = [ rust-overlay.overlays.default ];
        };

      rocTargetFor = {
        x86_64-linux = "x64musl";
        aarch64-linux = "arm64musl";
      };

      rustTargetFor = {
        x64musl = "x86_64-unknown-linux-musl";
        arm64musl = "aarch64-unknown-linux-musl";
      };

      rocFor = pkgs: roc-overlay.packages.${pkgs.stdenv.hostPlatform.system}.${rocVersion};

      # The basic-cli platform with hosts for every supported Roc target.
      basicCliFor =
        pkgs:
        let
          rustToolchain = pkgs.rust-bin.fromRustupToolchain {
            channel =
              (builtins.fromTOML (builtins.readFile "${basic-cli-src}/rust-toolchain.toml")).toolchain.channel;
            components = [ "llvm-tools-preview" ];
            targets = lib.attrValues rustTargetFor;
          };
          rustPlatform = pkgs.makeRustPlatform {
            cargo = rustToolchain;
            rustc = rustToolchain;
          };
          buildTarget = rocTarget: rustTarget: ''
            python3 scripts/build.py --target ${rocTarget}
            # Keep the unstripped host; Kai strips its final executables.
            cp target/${rustTarget}/release/libhost.a platform/targets/${rocTarget}/libhost.a
          '';
        in
        rustPlatform.buildRustPackage {
          pname = "basic-cli-platform";
          version = "0.23.0-pr499";
          src = basic-cli-src;
          cargoLock.lockFile = "${basic-cli-src}/Cargo.lock";
          nativeBuildInputs = [
            pkgs.python3
            pkgs.zig_0_16
          ];
          postPatch = ''
            patchShebangs ci scripts
          '';
          buildPhase = ''
            runHook preBuild
            export CARGO_NET_OFFLINE=true
            export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
            ${lib.concatStrings (lib.mapAttrsToList buildTarget rustTargetFor)}
            runHook postBuild
          '';
          # Roc supplies the host's unresolved symbols when linking an app.
          doCheck = false;
          dontStrip = true;
          installPhase = ''
            runHook preInstall
            mkdir -p "$out"
            cp -R platform/. "$out/"
            runHook postInstall
          '';
        };

      # The Kaifile platform as a Roc package bundle, <hash>.tar.zst, which a
      # release publishes for Kaifile.roc headers to reference by URL; also
      # unpacked as <hash>/ for kai to seed Roc's package cache with.
      kaifilePlatformFor =
        pkgs:
        pkgs.stdenvNoCC.mkDerivation {
          name = "kaifile-platform";
          src = lib.fileset.toSource {
            root = ./.;
            fileset = lib.fileset.unions [
              ./kaifile/ir
              ./kaifile/platform
            ];
          };
          nativeBuildInputs = [
            (rocFor pkgs)
            pkgs.zig_0_16
            pkgs.zstd
          ];
          dontConfigure = true;
          dontFixup = true;
          buildPhase = ''
            runHook preBuild
            export HOME="$TMPDIR" XDG_CACHE_HOME="$TMPDIR/cache" ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
            (cd kaifile/platform && zig build --release)
            (cd kaifile/platform/targets && sha256sum --quiet -c x64musl.sha256 arm64musl.sha256)

            # roc bundle packs only files below main.roc's directory, so the
            # ir package moves inside the platform.
            mkdir -p stage/ir stage/targets bundle
            cp kaifile/platform/*.roc stage/
            cp kaifile/ir/*.roc stage/ir/
            cp -R kaifile/platform/targets/{x64musl,arm64musl} stage/targets/
            substituteInPlace stage/main.roc --replace-fail '"../ir/main.roc"' '"ir/main.roc"'
            (cd stage && roc bundle main.roc $(find . -type f ! -path ./main.roc | LC_ALL=C sort) --output-dir ../bundle)
            runHook postBuild
          '';
          installPhase = ''
            runHook preInstall
            mkdir -p "$out"
            cp bundle/*.tar.zst "$out/"
            name="$(basename "$out"/*.tar.zst .tar.zst)"
            mkdir "$out/$name"
            zstd -dc "$out/$name.tar.zst" | tar -x -C "$out/$name"
            runHook postInstall
          '';
        };

      # Packages the apps import (basic-cli imports http; kai imports Weaver,
      # which imports ansi and path); unpacked where Roc looks for downloads.
      # http stays at 1.0.0, which basic-cli names; 2.0.0 is the same archive.
      rocPackages = [
        {
          name = "6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS";
          release = "roc-lang/http/releases/download/1.0.0";
          hash = "sha256-6e+qlQ5y9vds326vAEJFcvppsEumEnMjV6wEU2ePArQ=";
        }
        {
          name = "7j6KBFBEZ8pNMLQHkx9xiwyZ2PmwQPgKNDPUih6gKe77";
          release = "lukewilliamboswell/weaver/releases/download/0.9.0";
          hash = "sha256-GjWtVaxW7tYwwcd8ZNTogTmyKshRC4YE8IksP6ty+Wg=";
        }
        {
          name = "JXLM47L6CzrLXB5HBfqc27VnU6CD4jMm5Mk6dgbbovL";
          release = "lukewilliamboswell/roc-ansi/releases/download/0.13.0";
          hash = "sha256-g1Um8JrYgyBSP+3TWkdXVp3hSN29ENPxtXnev5f8vqQ=";
        }
        {
          name = "7YfABZPwJAXtLBY2vm8FqMyGAtNxncCJ65HdNKHFGNnE";
          release = "roc-lang/path/releases/download/4.0.0";
          hash = "sha256-Q1SZx/+081fSlW47soAqgSZPby9QyJbJkT+4b3vHUrs=";
        }
      ];

      mkRocBinary =
        pkgs: rocTarget:
        {
          pname,
          src,
          source,
          binaryName,
        }:
        let
          roc = rocFor pkgs;

          unpackRocPackage =
            {
              name,
              release,
              hash,
            }:
            let
              archive = pkgs.fetchurl {
                url = "https://github.com/${release}/${name}.tar.zst";
                inherit hash;
              };
            in
            ''
              mkdir -p "$XDG_CACHE_HOME/roc/packages/${name}"
              zstd -dc ${archive} | tar -x -C "$XDG_CACHE_HOME/roc/packages/${name}"
            '';

        in
        pkgs.stdenvNoCC.mkDerivation {
          pname = "${pname}-${rocTarget}";
          inherit version;

          inherit src;

          nativeBuildInputs = [
            roc
            pkgs.llvmPackages.bintools
            pkgs.zstd
          ];
          dontConfigure = true;
          dontFixup = true;

          buildPhase = ''

            runHook preBuild

            export HOME="$TMPDIR" XDG_CACHE_HOME="$TMPDIR/cache"

            ${lib.concatMapStrings unpackRocPackage rocPackages}

            # Roc apps import the platform from the ignored .basic-cli link.
            ln -s ${basicCliFor pkgs} .basic-cli

            roc build \
              ${source} \
              --opt=size \
              --target=${rocTarget} \
              --output=${binaryName}

            llvm-strip ${binaryName}

            runHook postBuild
          '';

          installPhase = ''

            runHook preInstall

            install -Dm755 ${binaryName} "$out/bin/${binaryName}"

            runHook postInstall
          '';

        };

      mkKaiBinary =
        pkgs: rocTarget:
        mkRocBinary pkgs rocTarget {
          pname = "kai";
          # Only what the CLI compiles or embeds, so other edits keep the build.
          src = lib.fileset.toSource {
            root = ./.;
            fileset = lib.fileset.unions [
              ./cli
              ./kaifile
              ./VERSION
              ./.roc-version
            ];
          };
          source = "cli/main.roc";
          binaryName = "kai";
        };

      mkWrappedPackage =
        pkgs:
        {
          pname,
          binary,
          runtimeInputs,
          wrapperArgs ? "",
        }:
        pkgs.runCommand "${pname}-${version}"
          {
            nativeBuildInputs = [ pkgs.makeWrapper ];
            # The bare binary, as a release archive ships it.
            passthru.unwrapped = binary;
          }
          ''

            mkdir -p "$out/bin"

            makeWrapper ${binary}/bin/${pname} "$out/bin/${pname}" \
              --prefix PATH : ${lib.makeBinPath runtimeInputs} \
              ${wrapperArgs}
          '';

      # Kai evaluates Kaifile.roc with the pinned compiler unless ROC is set,
      # and seeds Roc's package cache with this Kai's unpacked platform bundle,
      # <hash>/, so a Kaifile.roc pinned to it loads offline. GNU coreutils
      # only back up the host's, so tasks keep the user's tools.
      mkKaiPackage =
        pkgs: binary:
        let
          platform = kaifilePlatformFor pkgs;
        in
        mkWrappedPackage pkgs {
          pname = "kai";
          inherit binary;
          runtimeInputs = [ pkgs.nix ];
          wrapperArgs = lib.concatStringsSep " " [
            "--suffix PATH : ${lib.makeBinPath [ pkgs.coreutils ]}"
            "--set-default ROC ${rocFor pkgs}/bin/roc"
            "--set-default KAI_PLATFORM_BUNDLE \"${platform}/$(basename ${platform}/*.tar.zst .tar.zst)\""
          ];
        };

      # Release archives contain only Kai; their runtime environment must provide
      # Nix and the pinned Roc compiler (on PATH or as ROC) to load Kaifile.roc.
      mkReleaseArchive =
        pkgs: binary: targetSystem:
        pkgs.runCommand "kai-${version}-${targetSystem}.tar.gz"
          {
            nativeBuildInputs = [
              pkgs.gnutar
              pkgs.gzip
            ];
          }
          ''

            mkdir staging
            cp ${binary}/bin/kai staging/kai 
            chmod 0755 staging/kai 

            tar \
              --sort=name \
              --mtime='UTC 1970-01-01' \
              --owner=0 \
              --group=0 \
              --numeric-owner \
              -czf "$out" \
              -C staging \
              kai
          '';

      packagesFor =
        system:
        let
          pkgs = pkgsFor system;

          nativeKaiBinary = mkKaiBinary pkgs rocTargetFor.${system};
          kai = mkKaiPackage pkgs nativeKaiBinary;

          common = {
            inherit kai;
            default = kai;
            kaifile-platform = kaifilePlatformFor pkgs;
          };

          releaseArchives = {
            release-x86_64-linux = mkReleaseArchive pkgs (mkKaiBinary pkgs "x64musl") "x86_64-linux";

            release-aarch64-linux = mkReleaseArchive pkgs (mkKaiBinary pkgs "arm64musl") "aarch64-linux";
          };
        in
        common // releaseArchives;
    in
    {
      packages = forAllSystems packagesFor;

      apps = forAllSystems (
        system:
        let
          kai = self.packages.${system}.kai;
          kaiApp = {
            type = "app";
            program = "${kai}/bin/kai";
          };
        in
        {
          kai = kaiApp;
          default = kaiApp;
        }
      );

      checks = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          kai = self.packages.${system}.kai;
        in
        {
          package = kai;

          version = pkgs.runCommand "kai-version-check" { } ''
            # Expected output: "${version}"
            test "$(${kai}/bin/kai --version)" = "${version}"
            touch "$out"
          '';
        }
      );

      formatter = forAllSystems (system: (pkgsFor system).nixfmt);

      devShells = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          default = pkgs.mkShell {
            packages = [
              (rocFor pkgs)
              pkgs.zig_0_16

              pkgs.actionlint
              pkgs.coreutils
              pkgs.git
              pkgs.jujutsu
              pkgs.gnutar
              pkgs.gzip
              pkgs.llvmPackages.bintools
              pkgs.file
              pkgs.sops
            ];
            # Roc apps in this repository import the platform through .basic-cli.
            shellHook = ''
              if [ -f flake.nix ] && [ -d kaifile ]; then
                ln -sfn ${basicCliFor pkgs} .basic-cli
              fi
            '';
          };
        }
      );
    };
}
