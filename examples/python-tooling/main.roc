package
	[workspace]
	{
		blueprint: "https://github.com/lukewilliamboswell/roc-blueprint/releases/download/0.0.3-blueprint/HmTRQhvSpRQsj78WCR7j5y3anhqMVB4zuMejydrdAGeV.tar.zst",
	}

import blueprint.Blueprint
import blueprint.Environment
import blueprint.Requirement
import blueprint.Target

python3 : Requirement
python3 = Requirement.new({ id: "python3", display_name: "Python" })

git : Requirement
git = Requirement.new({ id: "git", display_name: "Git" })

workspace : Blueprint.Draft
workspace = Blueprint.workspace(
	{
		name: "python-tooling",
		target_systems: [Target.X86_64Linux, Target.Aarch64Darwin],
		envs: [Environment.new({ name: "default", requirements: [python3, git] })],
	},
)
