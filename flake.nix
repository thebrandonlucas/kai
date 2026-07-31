{
  description = "Kai development environment & packages";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Intel macOS is no longer supported by nixos-unstable.
    nixpkgs-x86-darwin.url = "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";

    # Track the overlay's latest Roc nightly.
    roc-overlay = {
      url = "github:thebrandonlucas/roc-overlay";
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

      version = "0.0.1";

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

      rocFor = pkgs: pkgs.rocpkgs.nightly;

      basicCliName = "4rAQg8kUYZ3Vksr4qMQHpaFYNiHSn9GgS7gVxghd1XYV";
      basicCliUrl =
        "https://github.com/roc-lang/basic-cli/releases/download/0.21.0/" + "${basicCliName}.tar.zst";

      rocHttpName = "6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS";
      rocHttpUrl = "https://github.com/roc-lang/http/releases/download/1.0.0/" + "${rocHttpName}.tar.zst";

      mkKaiBinary =
        pkgs: rocTarget:
        let
          roc = rocFor pkgs;

          basicCli = pkgs.fetchurl {
            url = basicCliUrl;
            hash = "sha256-I8IzZGbT7NNtUzhfZJRvyy7U+8wwvjPvB2tLYCMXdQk=";
          };

          rocHttp = pkgs.fetchurl {
            url = rocHttpUrl;
            hash = "sha256-6e+qlQ5y9vds326vAEJFcvppsEumEnMjV6wEU2ePArQ=";
          };

        in
        pkgs.stdenvNoCC.mkDerivation {
          pname = "kai-${rocTarget}";
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

            cp cli/main.roc cli/main-local.roc

            substituteInPlace cli/main-local.roc \
              --replace-fail \
              "${basicCliUrl}" \
              "$PWD/${basicCliName}/main.roc"

            roc build \
              cli/main-local.roc \
              --opt=speed \
              --target=${rocTarget} \
              --output=kai

            llvm-strip kai

            runHook postBuild
          '';

          installPhase = ''

            runHook preInstall

            install -Dm755 kai "$out/bin/kai"

            runHook postInstall
          '';

        };

      mkKaiPackage =
        pkgs: binary:
        pkgs.runCommand "kai-${version}"
          {
            nativeBuildInputs = [ pkgs.makeWrapper ];

          }
          ''

            mkdir -p "$out/bin"

            makeWrapper ${binary}/bin/kai "$out/bin/kai" \
             --prefix PATH : ${
               lib.makeBinPath [
                 (rocFor pkgs)
                 pkgs.nix
               ]
             }
          '';

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

      mkPlatformBundle =
        pkgs:
        pkgs.stdenvNoCC.mkDerivation {
          pname = "kai-platform";
          inherit version;

          src = self;

          nativeBuildInputs = [
            pkgs.bash
            pkgs.coreutils
            pkgs.findutils
            (rocFor pkgs)
            pkgs.zig_0_16
          ];

          dontConfigure = true;

          postPatch = ''
            patchShebangs scripts/bundle-platform.sh
          '';

          buildPhase = ''

            runHook preBuild 

            export HOME="$TMPDIR"

            zig build bundle -Doptimize=ReleaseSafe

            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall 

            mkdir -p "$out"

            cp dist/*tar.zst "$out/"

            runHook postInstall
          '';
        };

      packagesFor =
        system:
        let
          pkgs = pkgsFor system;

          nativeBinary = mkKaiBinary pkgs rocTargetFor.${system};
          kai = mkKaiPackage pkgs nativeBinary;

          common = {
            inherit kai;
            default = kai;
            platform-bundle = mkPlatformBundle pkgs;
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
          app = {
            type = "app";
            program = "${kai}/bin/kai";
          };
        in
        {
          kai = app;
          default = app;
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
            test "$(${kai}/bin/kai version)" = "kai version ${version}"
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
