{
  description = "ssloy/tinyrenderer implemented in zig.";

  inputs = {
    nixpkgs.url = "nixpkgs/nixos-23.05";
    flake-utils.url = "github:numtide/flake-utils";
    zig.url = "github:mitchellh/zig-overlay";
    zig.inputs.nixpkgs.follows = "nixpkgs";
    zig.inputs.flake-utils.follows = "flake-utils";
  };

  outputs =
    { self
    , nixpkgs
    , zig
    , flake-utils
    , ...
    }:
    flake-utils.lib.eachSystem (builtins.attrNames zig.packages) (system:
    let
      pkgs = import nixpkgs {
        inherit system;
        overlays = [ zig.overlays.default ];
      };
    in
    rec {
      devShells.default = pkgs.mkShell {
        nativeBuildInputs = [ pkgs.zigpkgs.master pkgs.zls ];
      };

      formatter = pkgs.nixpkgs-fmt;
    });
}
