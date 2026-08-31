# TODO: comment
import "Executor.roc" as executor_source : Str
import "Kaifile.roc" as kaifile_source : Str
import "package.roc" as package_source : Str
import "parser/Fields.roc" as body_source : Str
import "parser/Blocks.roc" as blocks_source : Str
import "parser/main.roc" as parser_package_source : Str
import "Plugin.roc" as plugin_source : Str
import "VERSION" as version_source : Str

RuntimeBundle := [].{
	platform_name = "F1JVZPYfWP71s8vk6tHcV1Qx1Ef6CZkwswGoCn8VHZmL"

	platform_url = Str.join_with(
		[
			"https://github.com/roc-lang/basic-cli/releases/download/0.22.0",
			"${RuntimeBundle.platform_name}.tar.zst",
		],
		"/",
	)

	source_bundle = {
		app_dependencies: [{ name: "kai", path: "./package.roc" }],
		app_imports: ["import Executor"],
		files: [
			{ destination: "Executor.roc", contents: executor_source },
			{ destination: "Kaifile.roc", contents: kaifile_source },
			{ destination: "package.roc", contents: package_source },
			{ destination: "Plugin.roc", contents: plugin_source },
			{ destination: "VERSION", contents: version_source },
			{ destination: "parser/Fields.roc", contents: body_source },
			{ destination: "parser/Blocks.roc", contents: blocks_source },
			{ destination: "parser/main.roc", contents: parser_package_source },
		],
	}
}
