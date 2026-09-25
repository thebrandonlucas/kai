{
  description = "Kai development environment & packages";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    roc-overlay = {
      url = "github:roc-lang/roc-overlay/06198bdac7c2a171c93d0a6f0ddeea562867ee1e";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # No basic-cli release supports the pinned Roc yet; build PR #499 from source.
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

      version = builtins.readFile ./xkai/VERSION;

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

      # basic-cli imports this package; unpack it where Roc looks for downloads.
      rocHttpName = "6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS";
      rocHttpUrl = "https://github.com/roc-lang/http/releases/download/1.0.0/" + "${rocHttpName}.tar.zst";

      mkRocBinary =
        pkgs: rocTarget:
        {
          pname,
          source,
          binaryName,
          buildBinaryName ? binaryName,
          prepareXkai ? false,
        }:
        let
          roc = rocFor pkgs;

          rocHttp = pkgs.fetchurl {
            url = rocHttpUrl;
            hash = "sha256-6e+qlQ5y9vds326vAEJFcvppsEumEnMjV6wEU2ePArQ=";
          };

        in
        pkgs.stdenvNoCC.mkDerivation {
          pname = "${pname}-${rocTarget}";
          inherit version;

          src = self;

          nativeBuildInputs = [
            roc
            pkgs.llvmPackages.bintools
            pkgs.zstd
          ]
          ++ lib.optionals prepareXkai [ pkgs.zig_0_16 ];
          dontConfigure = true;
          dontFixup = true;

          buildPhase = ''

            runHook preBuild

            export HOME="$TMPDIR" XDG_CACHE_HOME="$TMPDIR/cache"

            mkdir -p "$XDG_CACHE_HOME/roc/packages/${rocHttpName}"
            zstd -dc ${rocHttp} | tar -x -C "$XDG_CACHE_HOME/roc/packages/${rocHttpName}"

            # Roc apps import the platform from the ignored .basic-cli link.
            ln -s ${basicCliFor pkgs} .basic-cli

            ${lib.optionalString prepareXkai ''
              zig build prepare-xkai --prefix "$TMPDIR/prepared-xkai"
              cp -R "$TMPDIR/prepared-xkai/xkai-source" generated-xkai
              ln -s ${basicCliFor pkgs} generated-xkai/.basic-cli
            ''}

            roc build \
              ${source} \
              --opt=size \
              --target=${rocTarget} \
              --output=${buildBinaryName}

            llvm-strip ${buildBinaryName}

            runHook postBuild
          '';

          installPhase = ''

            runHook preInstall

            install -Dm755 ${buildBinaryName} "$out/bin/${binaryName}"

            runHook postInstall
          '';

        };

      mkKaiBinary =
        pkgs: rocTarget:
        mkRocBinary pkgs rocTarget {
          pname = "kai";
          source = "xkai/standard-cli.roc";
          binaryName = "kai";
        };

      mkXkaiBinary =
        pkgs: rocTarget:
        mkRocBinary pkgs rocTarget {
          pname = "xkai";
          source = "generated-xkai/xkai/main.roc";
          binaryName = "xkai";
          buildBinaryName = "xkai-dev";
          prepareXkai = true;
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
          }
          ''

            mkdir -p "$out/bin"

            makeWrapper ${binary}/bin/${pname} "$out/bin/${pname}" \
              --prefix PATH : ${lib.makeBinPath runtimeInputs} \
              ${wrapperArgs}
          '';

      mkKaiPackage =
        pkgs: binary:
        mkWrappedPackage pkgs {
          pname = "kai";
          inherit binary;
          runtimeInputs = [
            pkgs.nix
            pkgs.sops
          ];
        };

      mkXkaiPackage =
        pkgs: binary:
        mkWrappedPackage pkgs {
          pname = "xkai";
          inherit binary;
          runtimeInputs = [
            (rocFor pkgs)
            pkgs.llvmPackages.bintools
          ];
          # Generated apps import the platform that xkai was built against.
          wrapperArgs = "--set-default XKAI_PLATFORM ${basicCliFor pkgs}/main.roc";
        };

      # Release archives contain only Kai; their runtime environment must provide
      # Nix and sops. Secret staging diagnoses a missing sops executable.
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
          nativeXkaiBinary = mkXkaiBinary pkgs rocTargetFor.${system};
          kai = mkKaiPackage pkgs nativeKaiBinary;
          xkai = mkXkaiPackage pkgs nativeXkaiBinary;

          common = {
            inherit kai xkai;
            default = kai;
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
          xkai = self.packages.${system}.xkai;
          kaiApp = {
            type = "app";
            program = "${kai}/bin/kai";
          };
        in
        {
          kai = kaiApp;
          default = kaiApp;
          xkai = {
            type = "app";
            program = "${xkai}/bin/xkai";
          };
        }
      );

      checks = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          kai = self.packages.${system}.kai;
          xkai = self.packages.${system}.xkai;
        in
        {
          package = kai;
          xkai-package = xkai;

          version = pkgs.runCommand "kai-version-check" { } ''
            # Expected output: "kai version ${version}"
            test "$(${kai}/bin/kai version)" = "kai version ${version}"
            touch "$out"
          '';

          xkai-version = pkgs.runCommand "xkai-version-check" { } ''
            # Expected output: "xkai version ${version}"
            test "$(${xkai}/bin/xkai version)" = "xkai version ${version}"
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
              if [ -f flake.nix ] && [ -d xkai ]; then
                ln -sfn ${basicCliFor pkgs} .basic-cli
              fi
            '';
          };
        }
      );
    };
}
