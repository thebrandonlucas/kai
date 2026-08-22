import kai.Plugin
import backends.Nix as NixBackend
import commands.Compose as ComposeCommand

ComposeNix := [].{
	implementation : Plugin.Implementation
	implementation = Plugin.Implementation.{
		actions: [],
		backend: NixBackend.backend.name,
		command: ComposeCommand.command.name,
		renderer: ComposeNix.renderer,
		validator: NoValidation,
	}

	renderer : Plugin.Renderer
	renderer = |context| {
		name = match context.args {
			[selected_name] => Ok(selected_name)
			_ => Err({ byte_offset: None, message: "compose requires exactly one machine name" })
		}?
		requests = [{ args: ["image", name], status: "compose: image ${name}" }]
		if context.dependencies_resolved {
			image = ComposeNix.find_image(context.dependency_artifacts, name)?
			schema : U64
			schema = 1
			path = ".kai/compositions/${name}.json"
			manifest = Json.to_str({ artifact: image, schema })
			Ok(
				Plugin.RenderResult.{
					actions: [WriteUtf8({ content: manifest, path })],
					artifacts: [
						{
							attributes: [
								{ key: "source.kind", value: image.kind },
								{ key: "source.path", value: image.path },
							],
							kind: "kai.composition/v1",
							name,
							path,
						},
					],
					outputs: [],
					requests,
					requested_packages: [],
				},
			)
		} else {
			Ok(
				Plugin.RenderResult.{
					actions: [],
					artifacts: [],
					outputs: [],
					requests,
					requested_packages: [],
				},
			)
		}
	}

	find_image : List(Plugin.Artifact), Str -> Try(Plugin.Artifact, Plugin.RendererDiagnostic)
	find_image = |artifacts, name|
		match artifacts.keep_if(|artifact| artifact.kind == "kai.machine.image/v1" and artifact.name == name) {
			[image] => Ok(image)
			[] => Err({ byte_offset: None, message: "image '${name}' did not produce a kai.machine.image/v1 artifact" })
			_ => Err({ byte_offset: None, message: "image '${name}' produced multiple kai.machine.image/v1 artifacts" })
		}
}
