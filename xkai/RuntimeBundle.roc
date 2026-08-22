import "Executor.roc" as executor_source : Str
import "package.roc" as package_source : Str
import "parser/Body.roc" as body_source : Str
import "parser/Bytes.roc" as bytes_source : Str
import "parser/Config.roc" as config_source : Str
import "parser/main.roc" as parser_package_source : Str
import "Plugin.roc" as plugin_source : Str
import "VERSION" as version_source : Str

RuntimeBundle := [].{
	platform_name = "F1JVZPYfWP71s8vk6tHcV1Qx1Ef6CZkwswGoCn8VHZmL"

	platform_url = "https://github.com/roc-lang/basic-cli/releases/download/0.22.0/${RuntimeBundle.platform_name}.tar.zst"

	source_bundle = {
		app_dependencies: [{ name: "kai", path: "./package.roc" }],
		app_imports: ["import Executor"],
		files: [
			{ destination: "Executor.roc", contents: executor_source },
			{ destination: "package.roc", contents: package_source },
			{ destination: "Plugin.roc", contents: plugin_source },
			{ destination: "VERSION", contents: version_source },
			{ destination: "parser/Body.roc", contents: body_source },
			{ destination: "parser/Bytes.roc", contents: bytes_source },
			{ destination: "parser/Config.roc", contents: config_source },
			{ destination: "parser/main.roc", contents: parser_package_source },
		],
	}

	custom_dependencies = {
		plugin: [
			{ name: "kai", path: "../package.roc" },
			{ name: "parser", path: "../parser/main.roc" },
		],
		commands: [
			{ name: "kai", path: "../../package.roc" },
			{ name: "parser", path: "../../parser/main.roc" },
		],
		backends: [{ name: "kai", path: "../../package.roc" }],
		implementations: [
			{ name: "kai", path: "../../package.roc" },
			{ name: "parser", path: "../../parser/main.roc" },
		],
	}
}
