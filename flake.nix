# Kai's release binaries, for `nix run github:thebrandonlucas/kai` and
# `nix profile install github:thebrandonlucas/kai`. Kai's own development
# environment is Kaifile.roc. Release preparation records the release's
# SHA256SUMS in RELEASE_SHA256SUMS, next to VERSION.
{
  description = "Kai, a friendly frontend for determinate computing";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;
      version = lib.trim (builtins.readFile ./VERSION);
      releases = "https://github.com/thebrandonlucas/kai/releases/download";

      # The sha256 of each system's archive, from the lines of SHA256SUMS
      # naming kai-VERSION-SYSTEM.tar.gz.
      archives = lib.listToAttrs (
        lib.concatMap (
          line:
          let
            match = builtins.match "([0-9a-f]{64})  kai-${lib.escapeRegex version}-(.+)\\.tar\\.gz" line;
          in
          lib.optional (match != null) (lib.nameValuePair (lib.elemAt match 1) (lib.elemAt match 0))
        ) (lib.splitString "\n" (builtins.readFile ./RELEASE_SHA256SUMS))
      );

      package =
        system: sha256:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        pkgs.stdenvNoCC.mkDerivation {
          pname = "kai";
          inherit version;
          src = pkgs.fetchurl {
            url = "${releases}/v${version}/kai-${version}-${system}.tar.gz";
            inherit sha256;
          };
          sourceRoot = ".";
          dontConfigure = true;
          dontBuild = true;
          installPhase = ''
            runHook preInstall
            install -Dm755 kai "$out/bin/kai"
            runHook postInstall
          '';
          meta = {
            description = "A friendly frontend for determinate computing";
            homepage = "https://github.com/thebrandonlucas/kai";
            license = lib.licenses.upl;
            mainProgram = "kai";
            platforms = [ system ];
            sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
          };
        };
    in
    {
      packages = lib.mapAttrs (system: sha256: {
        default = package system sha256;
      }) archives;

      apps = lib.mapAttrs (system: _: {
        default = {
          type = "app";
          program = lib.getExe self.packages.${system}.default;
          meta.description = "Run kai";
        };
      }) archives;
    };
}
