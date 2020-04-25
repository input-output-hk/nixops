{ system ? builtins.currentSystem
, nixpkgs ? if flakeUri != null then "${flakeNetwork.nixpkgs}" else <nixpkgs>
, pkgs    ? import nixpkgs { inherit system; }
, nixops  ? pkgs.nixops
, networkExprs
, flakeUri ? null
, flake ? builtins.getFlake flakeUri
, flakeNetwork ? (call flake.outputs.nixopsConfigurations.default) // { _file = "<${flakeUri}>"; }
, checkConfigurationOptions ? true
, uuid
, deploymentName
, args
, evalFile ? false
, pluginNixExprs ?
  with pkgs; with lib; pipe nixops.propagatedBuildInputs [
    (filter ({ name, ... }: hasPrefix "nixops" name))
    (map (plugin: plugin + "/share/nix/${getName plugin}"))
  ]
  , call ? e: (rec {
    lambda = e args;
    set    = e;
    path   = string;
    string = {
      _file = e;
      imports = [ (call (import e)) ];
    };
  }.${builtins.typeOf e})
}:

with pkgs;
with lib;

let
  expressions =
rec {
  inherit pluginNixExprs networkExprs;

  importedPluginNixExprs          = map (expr: import expr) pluginNixExprs;
  pluginResources                 = map (e: e.resources) importedPluginNixExprs;
  pluginOptions                   = { imports = (foldl (a: e: a ++ e.options) [] importedPluginNixExprs); };
  pluginDeploymentConfigExporters = (foldl (a: e: a ++ (e.config_exporters { inherit optionalAttrs pkgs; })) [] importedPluginNixExprs);

  network = let
    baseModules = import (pkgs.path + "/nixos/modules/module-list.nix");

  in (evalModules {
    modules = [
      ./network.nix
      {
        _module.args = {
          inherit args pkgs baseModules pluginOptions pluginResources deploymentName uuid pluginDeploymentConfigExporters;
        } // args;
      }
    ] ++ (map call networkExprs)
      ++ (optional (flakeUri != null) (removeAttrs flakeNetwork [ "nixpkgs" ]));
  }).config;

  inherit (network) defaults nodes resources;

  # Phase 1: evaluate only the deployment attributes.
  info =
    let
      network' = network;
      resources' = resources;
    in rec {

    machines =
      flip mapAttrs nodes (n: v': let v = scrubOptionValue v'; in
      foldr (a: b: a // b)
        { inherit (v.deployment) targetEnv targetPort targetHost alwaysActivate owners keys hasFastConnection;
          nixosRelease = v.system.nixos.release or v.system.nixosRelease or (removeSuffix v.system.nixosVersionSuffix v.system.nixosVersion);
          publicIPv4 = v.networking.publicIPv4;
        } (map (f: f v) pluginDeploymentConfigExporters));

    inherit (network') network;

    resources =
    let
      resource_referenced = list: check: recurse:
          any id (map (value: (check value) ||
                              ((isAttrs value) && (!(value ? _type) || recurse)
                                               && (resource_referenced (attrValues value) check false)))
                      list);

      flatten_resources = resources: flatten ( map attrValues (attrValues resources) );

      resource_used = res_set: resource:
          resource_referenced
              (flatten_resources res_set)
              (value: value == resource )
              true;

      resources_without_defaults = res_class: defaults: res_set:
        let
          missing = filter (res: !(resource_used (removeAttrs res_set [res_class])
                                                  res_set."${res_class}"."${res}"))
                           (attrNames defaults);
        in
        res_set // { "${res_class}" = ( removeAttrs res_set."${res_class}" missing ); };

    in (removeAttrs resources' [ "machines" ]);
  };

  # Phase 2: build complete machine configurations.
  machines = { names }: let
    nodes' = filterAttrs (n: v: elem n names) nodes;

  in runCommand "nixops-machines" {
    preferLocalBuild = true;
  } ''
    mkdir -p $out
    ${toString (attrValues (mapAttrs (n: v: ''
      ln -s ${v.system.build.toplevel} $out/${n}
    '') nodes'))}
  '';


  # Function needed to calculate the nixops arguments. This should work even when arguments
  # are not set yet, so we fake arguments to be able to evaluate the require attribute of
  # the nixops network expressions.

  dummyArgs = f: builtins.listToAttrs (map (a: lib.nameValuePair a false) (builtins.attrNames (builtins.functionArgs f)));

  getNixOpsExprs = l: lib.unique (lib.flatten (map getRequires l));

  getRequires = f:
    let
      nixopsExpr = import f;
      requires =
        if builtins.isFunction nixopsExpr then
          ((nixopsExpr (dummyArgs nixopsExpr)).require or [])
        else
          (nixopsExpr.require or []);
    in
      [ f ] ++ map getRequires requires;

  fileToArgs = f:
    let
      nixopsExpr = import f;
    in
      if builtins.isFunction nixopsExpr then
        map (a: { "${a}" = builtins.toString f; } ) (builtins.attrNames (builtins.functionArgs nixopsExpr))
      else [];

  getNixOpsArgs = fs: lib.zipAttrs (lib.unique (lib.concatMap fileToArgs (getNixOpsExprs fs)));

  nixopsArguments = getNixOpsArgs networkExprs;
};
in
  if evalFile != false
  then (import evalFile) expressions
  else expressions
