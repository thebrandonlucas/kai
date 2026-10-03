## The platform's API modules as a package, for Roc code that cannot import a
## platform: kai itself and std's model and backend packages. Both roots share
## these files, so a platform value is also a value of the package's type.
package
	[
		Backend,
		Command,
		Implementation,
		Kaifile,
		Layout,
		LockFile,
		LockJson,
		Plan,
		Plugin,
		Protocol,
		Sexpr,
	]
	{}
