Notes on the whether to put backend-specific code in `backend` or `implementation`:

 Use reason for change as the metric:

 │ If it changes because Nix changed, it belongs in Nix.roc.
 │ If it changes because a Kai command’s behavior changed, it belongs in that implementation.

 Two supporting tests:

 1. Command knowledge test: If code knows about builds, services, machines, images, artifact kinds, or command-specific .kai paths, it belongs in the implementation.
 2. Reuse test: If multiple Nix implementations can use it unchanged, or it is required to safely emit Nix, it belongs in Nix.roc.

e.g. specific `backend` features which respond directly to `nix build` should be put in the implementation, but generic things like string interpolation belong in `Nix.roc`
