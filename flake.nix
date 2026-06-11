{
  description = "moonbit-community/flate — DEFLATE (RFC 1951) engine plus gzip/zlib wrappers for MoonBit";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    moonbit-overlay.url = "github:moonbit-community/moonbit-overlay";
  };

  outputs =
    { nixpkgs, moonbit-overlay, ... }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
        "x86_64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f (pkgsFor system));
      pkgsFor =
        system:
        import nixpkgs {
          inherit system;
          overlays = [ moonbit-overlay.overlays.default ];
        };
    in
    {
      devShells = forAllSystems (pkgs: {
        # `nix develop` -> nightly MoonBit toolchain (moon, moonc, moonfmt, moon-lsp).
        default = pkgs.mkShell {
          packages = [ pkgs.moonbit-bin.moonbit.nightly ];
        };
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt-rfc-style);
    };
}
