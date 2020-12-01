{ runCommandNoCC
, symlinkJoin
, poetry2nix
, openssh
, rsync
, lib
, pkgs }:

let
  overrides = import ./overrides.nix { inherit pkgs; };

  # Wrap the buildEnv derivation in an outer derivation that omits interpreters & other binaries
  mkPluginDrv = {
    finalDrv
    , interpreter
    , plugins
    , givenPlugins
  }: let

    # The complete buildEnv drv
    buildEnvDrv = interpreter.buildEnv.override {
      extraLibs = builtins.map (p: interpreter.pkgs.toPythonModule p) plugins;
      ignoreCollisions = true;
    };

    # Create a separate environment aggregating the share directory
    # This is done because we only want /share for the actual plugins
    # and not for e.g. the python interpreter and other dependencies.
    manEnv = symlinkJoin {
      name = "${finalDrv.pname}-with-plugins-share-${finalDrv.version}";
      preferLocalBuild = true;
      allowSubstitutes = false;
      paths = plugins;
      postBuild = ''
        if test -e $out/share; then
          mv $out out
          mv out/share $out
        else
          rm -r $out
          mkdir $out
        fi
      '';
    };

  in runCommandNoCC "${finalDrv.pname}-with-plugins-${finalDrv.version}" {
    inherit (finalDrv) meta;
    passthru = {
      eval-machine-info = import ./nix/eval-machine-info.nix;
      evalMachineInfo = import ./nix/eval-machine-info.nix;
      propagatedBuildInputs = givenPlugins;
    } // finalDrv.passthru;
  } ''
    mkdir -p $out/bin

    for bindir in ${lib.concatStringsSep " " (map (d: "${lib.getBin d}/bin") plugins)}; do
      for bin in $bindir/*; do
        ln -s ${buildEnvDrv}/bin/$(basename $bin) $out/bin/
      done
    done

    ln -s ${manEnv} $out/share
  '';

  # Make a python derivation pluginable
  #
  # This adds a `withPlugins` function that works much like `withPackages`
  # except it only links binaries from the explicit derivation /share
  # from any plugins
  toPluginAble = {
    drv
    , interpreter
    , finalDrv
    , self
    , super
  }: drv.overridePythonAttrs(old: {
    passthru = old.passthru // {
      withPlugins = pluginFn: mkPluginDrv {
        plugins = [ finalDrv ] ++ pluginFn self;
        givenPlugins = pluginFn self;
        inherit finalDrv;
        inherit interpreter;
      };
    };
  });

  nixops = poetry2nix.mkPoetryApplication {

    projectDir = ./.;

    propagatedBuildInputs = [
      openssh
      rsync
    ];

    overrides = [
      poetry2nix.defaultPoetryOverrides
      overrides
      (self: super: {
        nixops = nixops;
      })
      (self: super: {
        nixops = toPluginAble {
          drv = super.nixops;
          finalDrv = self.nixops;
          interpreter = self.python;
          inherit self super;
        };
      })
    ];

    passthru = {
      eval-machine-info = import ./nix/eval-machine-info.nix;
      evalMachineInfo = import ./nix/eval-machine-info.nix;
    };

    # TODO: Manual build should be included via pyproject.toml
    postInstall = ''
      mkdir -p $out/share/nix/nixops
      cp -av nix/* $_
    '';

  };

in nixops.python.pkgs.nixops.withPlugins(_: [])
