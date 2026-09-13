# Data-driven test for building a declared NixOS service.
import std.StdPlugin
import util.PlanCheck

ServiceNixTest := [].{}

# A service renders its module and expression, then publishes the artifact.
expect {
	kaifile =
		\\environment server {
		\\  packages: []
		\\}
		\\
		\\build app {
		\\  environment: server
		\\  run: ["touch", "app"]
		\\  output: "app"
		\\}
		\\
		\\service web {
		\\  artifact: "app"
		\\  secrets: []
		\\  restart: on-failure
		\\}
	nix_module = \\${"$"}{./module.nix}
	nix_artifact = \\${"$"}{./artifact}
	copy_artifact = \\  cp --recursive --no-dereference --preserve=mode
	expected_module =
		\\{ ... }:
		\\{
		\\  systemd.services."web" = {
		\\    wantedBy = [ "multi-user.target" ];
		\\    serviceConfig = {
		\\      Type = "exec";
		\\      ExecStart = "${nix_artifact}";
		\\      Restart = "on-failure";
		\\      DynamicUser = true;
		\\      NoNewPrivileges = true;
		\\      PrivateDevices = true;
		\\      PrivateTmp = true;
		\\      ProtectControlGroups = true;
		\\      ProtectHome = true;
		\\      ProtectKernelModules = true;
		\\      ProtectKernelTunables = true;
		\\      ProtectSystem = "strict";
		\\      RestrictSUIDSGID = true;
		\\      UMask = "0077";
		\\      LoadCredential = [
		\\      ];
		\\    };
		\\  };
		\\}
	expected_expression =
		\\let
		\\  flake = builtins.getFlake (toString ../../../.kai/builds/app);
		\\  pkgs = builtins.getAttr "x86_64-linux" flake.legacyPackages;
		\\in
		\\pkgs.runCommand "kai-service-web" {} ''
		\\  mkdir -p "$out"
		\\  cp -- ${nix_module} "$out/default.nix"
		\\${copy_artifact} ${nix_artifact} "$out/artifact"
		\\  if [ ! -f "$out/artifact" ] || [ ! -x "$out/artifact" ]; then
		\\    echo "Kai service artifact must be an executable file" >&2
		\\    exit 1
		\\  fi
		\\''

	PlanCheck.plan(
		{
			definitions: [StdPlugin.plugin],
			host: { arch: X64, os: LINUX },
			kaifile,
			workspace_root: ".kai",
		},
		["service", "web"],
		Succeeds([
			WritesExactly({
				contents: expected_module,
				path: ".kai/services/web/module.nix",
			}),
			WritesExactly({
				contents: expected_expression,
				path: ".kai/services/web/default.nix",
			}),
			ContainsArtifact({
				attributes: [
					{ key: "backend", value: "nix" },
					{ key: "build", value: "app" },
					{ key: "target.system", value: "x86_64-linux" },
				],
				kind: "kai.nixos.service/v1",
				name: "web",
				path: ".kai/artifacts/.services/web",
			}),
			ContainsStep(
				RunProgram({
					arguments: [
						"build",
						"--file",
						".kai/services/web/default.nix",
						"--out-link",
						".kai/artifacts/.services/web",
					],
					program: "nix",
				}),
			),
		]),
	)
}

# A service resolves a sops secret into artifact metadata and credentials.
expect {
	kaifile =
		\\environment server {
		\\  packages: []
		\\}
		\\
		\\build app {
		\\  environment: server
		\\  run: ["touch", "app"]
		\\  output: "app"
		\\}
		\\
		\\secret api-key {
		\\  provider: sops
		\\  file: "secrets/api-key.json"
		\\}
		\\
		\\service web {
		\\  artifact: "app"
		\\  secrets: ["api-key"]
		\\  restart: on-failure
		\\}
	nix_artifact = \\${"$"}{./artifact}
	sops_path = \\${"$"}{config.sops.secrets."api-key".path}
	expected_module =
		\\{ config, ... }:
		\\{
		\\  sops.secrets."api-key".restartUnits = [ "web.service" ];
		\\  systemd.services."web" = {
		\\    wantedBy = [ "multi-user.target" ];
		\\    serviceConfig = {
		\\      Type = "exec";
		\\      ExecStart = "${nix_artifact}";
		\\      Restart = "on-failure";
		\\      DynamicUser = true;
		\\      NoNewPrivileges = true;
		\\      PrivateDevices = true;
		\\      PrivateTmp = true;
		\\      ProtectControlGroups = true;
		\\      ProtectHome = true;
		\\      ProtectKernelModules = true;
		\\      ProtectKernelTunables = true;
		\\      ProtectSystem = "strict";
		\\      RestrictSUIDSGID = true;
		\\      UMask = "0077";
		\\      LoadCredential = [
		\\        "api-key:${sops_path}"
		\\      ];
		\\    };
		\\  };
		\\}

	PlanCheck.plan(
		{
			definitions: [StdPlugin.plugin],
			host: { arch: X64, os: LINUX },
			kaifile,
			workspace_root: ".kai",
		},
		["service", "web"],
		Succeeds([
			WritesExactly({
				contents: expected_module,
				path: ".kai/services/web/module.nix",
			}),
			ContainsArtifact({
				attributes: [
					{ key: "backend", value: "nix" },
					{ key: "build", value: "app" },
					{ key: "target.system", value: "x86_64-linux" },
					{
						key: "secret.api-key.file",
						value: "secrets/api-key.json",
					},
				],
				kind: "kai.nixos.service/v1",
				name: "web",
				path: ".kai/artifacts/.services/web",
			}),
		]),
	)
}
