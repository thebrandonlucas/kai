package
	[workspace]
	{
		blueprint: "https://github.com/lukewilliamboswell/roc-blueprint/releases/download/0.0.3-blueprint/HmTRQhvSpRQsj78WCR7j5y3anhqMVB4zuMejydrdAGeV.tar.zst",
	}

import blueprint.Blueprint
import blueprint.Environment
import blueprint.Requirement
import blueprint.Target

hello : Requirement
hello = Requirement.new({ id: "hello", display_name: "Hello" })

workspace : Blueprint.Draft
workspace = Blueprint.workspace(
	{
		name: "hello-shell",
		target_systems: [Target.X86_64Linux, Target.Aarch64Darwin],
		envs: [Environment.new({ name: "default", requirements: [hello] })],
	},
)
