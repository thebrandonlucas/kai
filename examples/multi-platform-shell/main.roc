package
	[workspace]
	{
		blueprint: "https://github.com/lukewilliamboswell/roc-blueprint/releases/download/0.0.3-blueprint/HmTRQhvSpRQsj78WCR7j5y3anhqMVB4zuMejydrdAGeV.tar.zst",
	}

import blueprint.Blueprint
import blueprint.Environment
import blueprint.Requirement
import blueprint.Target

git : Requirement
git = Requirement.new({ id: "git", display_name: "Shell tools" })

workspace : Blueprint.Draft
workspace = Blueprint.workspace(
	{
		name: "multi-platform-shell",
		target_systems: [Target.X86_64Linux, Target.Aarch64Linux, Target.X86_64Darwin, Target.Aarch64Darwin],
		envs: [Environment.new({ name: "default", requirements: [git] })],
	},
)
