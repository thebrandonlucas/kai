; Provider-native names stay intact through encoding, with no translation.
((format ((major 2) (minor 0))) (name "guix")
 (systems ("x86_64-linux"))
 (sources (((name "default") (provider (GuixPackages "current")))))
 (environments (((name "dev") (parents ()) (overlays ())
   (tools (((source "default") (name "python@3.12:out"))
     ((source "default") (name "gcc-toolchain")))))))
 (shells (((name "default") (environment "dev")))))
