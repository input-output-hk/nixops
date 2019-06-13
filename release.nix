{ nixopsSrc ? { outPath = ./.; revCount = 0; shortRev = "jalaws"; rev = "HEAD"; }
, officialRelease ? false
, nixpkgs ? <nixpkgs>
}:

let
  pkgs = import nixpkgs { };
  version = "1.7" + (if officialRelease then "" else "pre${toString nixopsSrc.revCount}_${nixopsSrc.shortRev}");
  vultr = import ../nixops-vultr/release.nix {};
in

rec {

  tarball = pkgs.releaseTools.sourceTarball {
    name = "nixops-tarball";

    src = nixopsSrc;

    inherit version;

    officialRelease = true; # hack

    buildInputs = [ pkgs.git pkgs.libxslt pkgs.docbook5_xsl ];

    postUnpack = ''
      # Clean up when building from a working tree.
      if [ -d $sourceRoot/.git ]; then
        (cd $sourceRoot && (git ls-files -o | xargs -r rm -v))
      fi
    '';

    distPhase =
      ''
        # Generate the manual and the man page.
        cp ${import ./doc/manual { revision = nixopsSrc.rev; inherit nixpkgs; }} doc/manual/machine-options.xml

        for i in scripts/nixops setup.py doc/manual/manual.xml; do
          substituteInPlace $i --subst-var-by version ${version}
        done

        make -C doc/manual install docdir=$out/manual mandir=$TMPDIR/man

        releaseName=nixops-$VERSION
        mkdir ../$releaseName
        cp -prd . ../$releaseName
        rm -rf ../$releaseName/.git
        mkdir $out/tarballs
        tar  cvfj $out/tarballs/$releaseName.tar.bz2 -C .. $releaseName

        echo "doc manual $out/manual manual.html" >> $out/nix-support/hydra-build-products
      '';
  };

  build = pkgs.lib.genAttrs [ "x86_64-linux" "i686-linux" "x86_64-darwin" ] (system:
    with import nixpkgs { inherit system; };

#    python2Packages.buildPythonApplication rec {
    python2Packages.buildPythonPackage rec {
      name = "nixops-${version}";

      src = "${tarball}/tarballs/*.tar.bz2";

      buildInputs = [ python2Packages.nose python2Packages.coverage ];

#      nativeBuildInputs = [ pkgs.mypy ];

      propagatedBuildInputs = with python2Packages;
        [ prettytable
          # Go back to sqlite once Python 2.7.13 is released
          pysqlite
          typing
          vultr.build."${system}"
          pluggy
        ];

      # For "nix-build --run-env".
      shellHook = ''
        export PYTHONPATH=$(pwd):$PYTHONPATH
        export PATH=$(pwd)/scripts:${openssh}/bin:$PATH
      '';

      doCheck = true;

      postCheck = ''
        # We have to unset PYTHONPATH here since it will pick enum34 which collides
        # with python3 own module. This can be removed when nixops is ported to python3.
        # PYTHONPATH= mypy --cache-dir=/dev/null nixops                                        # LOOK AT DISABLING myPy for just the hookspec syntax check

        # smoke test
        HOME=$TMPDIR $out/bin/nixops --version
      '';

      # Needed by libcloud during tests
#      SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";

      # Add openssh to nixops' PATH. On some platforms, e.g. CentOS and RHEL
      # the version of openssh is causing errors when have big networks (40+)
      makeWrapperArgs = ["--prefix" "PATH" ":" "${openssh}/bin" "--set" "PYTHONPATH" ":"];

      postInstall =
        ''
          # Backward compatibility symlink.
          ln -s nixops $out/bin/charon

          make -C doc/manual install \
            docdir=$out/share/doc/nixops mandir=$out/share/man

          mkdir -p $out/share/nix/nixops
          cp -av nix/* $out/share/nix/nixops
        '';

      meta.description = "Nix package for ${stdenv.system}";
    });

  tests.none_backend = (import ./tests/none-backend.nix {
    nixops = build.x86_64-linux;
    system = "x86_64-linux";
  }).test;
}
