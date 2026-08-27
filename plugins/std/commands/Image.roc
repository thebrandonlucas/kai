# Shared `command` interface for building machine images.
# ? I feel like command could / should be refactored so that
# it is self documenting i.e. i should be able to tell what
# it will look like as a newcomer just from looking at it?

# A potential shape could more like typescript definitions?
#
#
# ```roc
# command_spec = {
#   name: "image",
#
# }
#
# command = {
#   environment:
# }
# ```

# Build a generic QCOW2 image from the same machine definition.
# environment server {
#   packages: ["curl"]
# }
#
# machine agent {
#   environment: server
#   system: "x86_64-linux"
#   users: ["agent"]
#   services: ["openssh"]
# }

import kai.Plugin
import Machine

Image := [].{
	command : Plugin.Command
	command = Plugin.Command.{
		call: Plugin.call("image", [Plugin.required_argument("machine")]),
		# ? what is a named config and how does "related" change it
		config: NamedWithRelatedConfig({
			# What does QualifiedThenUnqualified mean?
			lookup: QualifiedThenUnqualified,
			# ? what actual effect do related blocks have?
			# ? The "related" can probably all go in one block instead of having
			# three?
			related: Machine.environment_block,
			related_field: "environment",
		}),
		config_block: RequiredConfigBlock(Machine.block),
	}
}
