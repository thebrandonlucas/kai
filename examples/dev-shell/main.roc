package
	[workspace]
	{
		blueprint: "https://github.com/lukewilliamboswell/roc-blueprint/releases/download/0.0.3-blueprint/HmTRQhvSpRQsj78WCR7j5y3anhqMVB4zuMejydrdAGeV.tar.zst",
	}

import blueprint.Blueprint
import blueprint.Environment
import blueprint.Requirement
import blueprint.Target

rustc : Requirement
rustc = Requirement.new({ id: "rustc", display_name: "Rust compiler" })

cargo : Requirement
cargo = Requirement.new({ id: "cargo", display_name: "Cargo" })

git : Requirement
git = Requirement.new({ id: "git", display_name: "Git" })

workspace : Blueprint.Draft
workspace = Blueprint.workspace(
	{
		name: "dev-shell",
		target_systems: [Target.X86_64Linux, Target.Aarch64Darwin],
		envs: [Environment.new({ name: "default", requirements: [rustc, cargo, git] })],
	},
)
