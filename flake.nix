{
  description = "Kai development environment & packages";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Intel macOS is no longer supported by nixos-unstable.
    nixpkgs-x86-darwin.url = "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";

    # Keep the Roc compiler compatible with basic-cli 0.22.0.
    roc-overlay = {
      url = "github:thebrandonlucas/roc-overlay/628d8dcfd18f8a5c8a6b7c589573e9dd43a9d303";
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

      version = builtins.readFile ./xkai/VERSION;

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

      basicCliName = "F1JVZPYfWP71s8vk6tHcV1Qx1Ef6CZkwswGoCn8VHZmL";
      basicCliUrl =
        "https://github.com/roc-lang/basic-cli/releases/download/0.22.0/" + "${basicCliName}.tar.zst";

      rocHttpName = "6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS";
      rocHttpUrl = "https://github.com/roc-lang/http/releases/download/1.0.0/" + "${rocHttpName}.tar.zst";

      mkRocBinary =
        pkgs: rocTarget:
        {
          pname,
          source,
          localSource,
          binaryName,
          buildBinaryName ? binaryName,
        }:
        let
          roc = rocFor pkgs;

          basicCli = pkgs.fetchurl {
            url = basicCliUrl;
            hash = "sha256-04xUSXYJU4IHIf9/kjbfTghdgokYBFvZDfuTLWUg7kc=";
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
          source = "xkai/stock-cli.roc";
          localSource = "xkai/stock-cli-local.roc";
          binaryName = "kai";
        };

      mkXkaiBinary =
        pkgs: rocTarget:
        mkRocBinary pkgs rocTarget {
          pname = "xkai";
          source = "xkai/main.roc";
          localSource = "xkai/main-local.roc";
          binaryName = "xkai";
          buildBinaryName = "xkai-dev";
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
              pkgs.coreutils
              pkgs.git
              pkgs.jujutsu
              pkgs.gnutar
              pkgs.gzip
              pkgs.llvmPackages.bintools
              pkgs.file
            ];
          };
        }
      );
    };
}
