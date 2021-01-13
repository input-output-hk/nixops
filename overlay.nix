{ self, system, pkgs }:
final: prev: {
  nixops_1_6_1-preplugin = self.inputs.nixpkgs-pin.legacyPackages.${system}.nixops_1_6_1;
  nixops_1_7-preplugin = self.inputs.nixpkgs-pin.legacyPackages.${system}.nixops;
  nixops_1_7-preplugin-unstable = self.inputs.nixpkgs-pin.legacyPackages.${system}.nixopsUnstable;
  nixops_1_7-iohk-unstable = pkgs.callPackage ./pkgs/nixops_1-unstable.nix { inherit self system pkgs; nixopsCore = "core-iohk"; coreVersion = "1_7"; };
  nixops_1_8-nixos-unstable = pkgs.callPackage ./pkgs/nixops_1-unstable.nix { inherit self system pkgs; nixopsCore = "core-nixos"; coreVersion = "1_8"; };
  nixops_2_0-2020-07-unstable = pkgs.callPackage ./pkgs/nixops_2-2020-07-unstable.nix { inherit self system pkgs; };
  nixops_2_0-2021-01-unstable = pkgs.callPackage ./pkgs/nixops_2-2021-01-unstable.nix { inherit self system pkgs; };
}