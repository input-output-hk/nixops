{ pkgs
, deploymentName
, uuid
, args
, pluginResources
, pluginOptions
, pluginDeploymentConfigExporters
, baseModules
, lib
, options
, config
, ... }: with lib; let

  deploymentInfoModule = rec {
    _file = "module at ${__curPos.file}:${toString __curPos.line}";
    key   = _file;

    deployment = {
      name      = deploymentName;
      arguments = args;
      inherit uuid;
    };
  };

  nodeArgsModule = rec {
    _file = "module at ${__curPos.file}:${toString __curPos.line}";
    key   = _file;

    _module.args = {
      inherit (config) resources nodes;
      inherit uuid baseModules;
    };
  };

  resourceArgsModule = rec {
    _file = "module at ${__curPos.file}:${toString __curPos.line}";
    key   = _file;

    _module.args = {
      inherit (config) resources;
      inherit pkgs uuid;

      nodes =
        flip mapAttrs config.nodes (n: v': let
          v = scrubOptionValue v';

        in foldr (a: b: a // b) {
          inherit (v.deployment) targetEnv targetPort targetHost storeKeysOnMachine alwaysActivate owners keys hasFastConnection;
          nixosRelease = v.system.nixos.release or v.system.nixosRelease or (removeSuffix v.system.nixosVersionSuffix v.system.nixosVersion);
          publicIPv4 = v.networking.publicIPv4;
        } (map (f: f v) pluginDeploymentConfigExporters));
    };
  };

  nixopsNode = types.submoduleWith ({
    modules = baseModules ++ [
      nodeArgsModule
      deploymentInfoModule
      ({ name, ... }: rec {
        _file = "module at ${__curPos.file}:${toString __curPos.line}";
        key   = _file;
        # Make NixOps's deployment.* options available.
        imports = [ ./options.nix ./resource.nix pluginOptions ];
        # Provide a default hostname and deployment target equal
        # to the attribute name of the machine in the model.
        networking.hostName   = mkOverride 900 name;
        deployment.targetHost = mkOverride 900 name;
        # Must be set for nixops to work on darwin
        nixpkgs.localSystem.system = "x86_64-linux";
        documentation.nixos.enable = mkDefault false;
        _module.args = { inherit pkgs; };
      })
    ];
  });

in {
  options = with types; {
    defaults = mkOption {
      type    = nixopsNode;
      default = {};
    };

    nodes = mkOption {
      type = attrsOf (submodule (options.defaults.type.functor.payload.modules ++ options.defaults.definitions));
      default = {};
    };

    network = mkOption {
      type    = attrsOf str;
      default = {};
    };

    resources = let
      evalResources = resourceModule: _: mkOption {
        type = attrsOf (submoduleWith {
          modules = let modules' = ([
            resourceModule
            resourceArgsModule
            deploymentInfoModule
            ./resource.nix
          ]); in modules';
        });
        default = {};
        apply = x: mapAttrs (_: v: if !(v ? _type) then v // { _type = "machine"; } else removeAttrs v [ "_module" ]) x;
      };
    in foldl (a: b: a // (b {
      inherit evalResources;
      zipAttrs = null;
      resourcesByType = null;
    })) {
      sshKeyPairs   = evalResources ./ssh-keypair.nix null;
      commandOutput = evalResources ./command-output.nix null;
      machines      = mapAttrs (_: v: removeAttrs v [ "_type" ]) config.nodes;
    } pluginResources;

    # `require` is special to NixOS modules
    # so we have to use `requires` and switch just before
    # yielding back to nixops
    requires = mkOption {
      type    = listOf (either str path);
      default = [];
    };
  };
}
