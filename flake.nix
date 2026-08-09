{
  description = "Kai development environment & packages";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Intel macOS is no longer supported by nixos-unstable.
    nixpkgs-x86-darwin.url = "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";

    # Keep the Roc compiler compatible with basic-cli 0.21.0-rc4.
    roc-overlay = {
      url = "github:thebrandonlucas/roc-overlay/a9afdcfed9bf90c53e6b4b1443e00676a939e971";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.nixpkgs-darwin.follows = "nixpkgs-x86-darwin";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-x86-darwin,
      roc-overlay,
      ...
    }:
    let
      inherit (nixpkgs) lib;

      version = builtins.readFile ./xkai-bin/VERSION;

      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = lib.genAttrs supportedSystems;
      pkgsFor =
        system:
        import (if system == "x86_64-darwin" then nixpkgs-x86-darwin else nixpkgs) {
          inherit system;
          overlays = [ roc-overlay.overlays.default ];
        };

      rocTargetFor = {
        x86_64-linux = "x64musl";
        aarch64-linux = "arm64musl";
        x86_64-darwin = "x64mac";
        aarch64-darwin = "arm64mac";
      };

      # Roc's macOS linker needs the minimal Darwin sysroot shipped beside its binary.
      # The pinned overlay currently omits that directory during installation.
      rocFor =
        pkgs:
        let
          roc = pkgs.rocpkgs.nightly;
        in
        if pkgs.stdenv.hostPlatform.isDarwin then
          roc.overrideAttrs (oldAttrs: {
            postInstall = (oldAttrs.postInstall or "") + ''
              cp -R darwin "$out/bin/darwin"
            '';
          })
        else
          roc;

      basicCliName = "FvCh4vdqm3nBY6DWEfZ8RuGCVfjuMY43HA8KSNk9qVDn";
      basicCliUrl =
        "https://github.com/roc-lang/basic-cli/releases/download/0.21.0-rc4/" + "${basicCliName}.tar.zst";

      rocHttpName = "6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS";
      rocHttpUrl = "https://github.com/roc-lang/http/releases/download/1.0.0/" + "${rocHttpName}.tar.zst";

      mkRocBinary =
        pkgs: rocTarget:
        {
          pname,
          source,
          localSource,
          binaryName,
        }:
        let
          roc = rocFor pkgs;

          basicCli = pkgs.fetchurl {
            url = basicCliUrl;
            hash = "sha256-t1xR+m4aYyBsWhhB+KPHWNQIA2Aqq3LPV+wlcDOrzh0=";
          };

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
          ];
          dontConfigure = true;
          dontFixup = true;

          buildPhase = ''

            runHook preBuild

            export HOME="$TMPDIR"

            cp ${basicCli} ${basicCliName}.tar.zst
            cp ${rocHttp} ${rocHttpName}.tar.zst

            roc unbundle ${basicCliName}.tar.zst
            roc unbundle ${rocHttpName}.tar.zst

            substituteInPlace ${basicCliName}/main.roc \
              --replace-fail \
              "${rocHttpUrl}" \
              "$PWD/${rocHttpName}/main.roc"

            cp ${source} ${localSource}

            substituteInPlace ${localSource} \
              --replace-fail \
              "${basicCliUrl}" \
              "$PWD/${basicCliName}/main.roc"

            roc build \
              ${localSource} \
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
          source = "xkai-bin/stock-cli.roc";
          localSource = "xkai-bin/stock-cli-local.roc";
          binaryName = "kai";
        };

      mkXkaiBinary =
        pkgs: rocTarget:
        mkRocBinary pkgs rocTarget {
          pname = "xkai";
          source = "xkai-bin/main.roc";
          localSource = "xkai-bin/main-local.roc";
          binaryName = "xkai";
        };

      mkWrappedPackage =
        pkgs:
        {
          pname,
          binary,
          runtimeInputs,
        }:
        pkgs.runCommand "${pname}-${version}"
          {
            nativeBuildInputs = [ pkgs.makeWrapper ];
          }
          ''

            mkdir -p "$out/bin"

            makeWrapper ${binary}/bin/${pname} "$out/bin/${pname}" \
              --prefix PATH : ${lib.makeBinPath runtimeInputs}
          '';

      mkKaiPackage =
        pkgs: binary:
        mkWrappedPackage pkgs {
          pname = "kai";
          inherit binary;
          runtimeInputs = [ pkgs.nix ];
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
        };

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

          releaseArchives =
            if lib.hasSuffix "-linux" system then
              {
                release-x86_64-linux = mkReleaseArchive pkgs (mkKaiBinary pkgs "x64musl") "x86_64-linux";

                release-aarch64-linux = mkReleaseArchive pkgs (mkKaiBinary pkgs "arm64musl") "aarch64-linux";

              }
            else
              {
                release-x86_64-darwin = mkReleaseArchive pkgs (mkKaiBinary pkgs "x64mac") "x86_64-darwin";

                release-aarch64-darwin = mkReleaseArchive pkgs (mkKaiBinary pkgs "arm64mac") "aarch64-darwin";
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
              pkgs.bash
              pkgs.coreutils
              pkgs.diffutils
              pkgs.findutils
              pkgs.gawk
              pkgs.gnused
              pkgs.gnutar
              pkgs.gzip
              pkgs.llvmPackages.bintools
              pkgs.shfmt
              pkgs.shellcheck
              pkgs.curl
              pkgs.file
            ];
          };
        }
      );
    };
}
