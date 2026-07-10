{
  description = "moonbit-community/flate — DEFLATE (RFC 1951) engine plus gzip/zlib wrappers for MoonBit";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    moonbit-overlay.url = "github:moonbit-community/moonbit-overlay";
  };

  outputs =
    {
      self,
      nixpkgs,
      moonbit-overlay,
      ...
    }:
    let
      # Upstream MoonBit publishes toolchains for Linux x86_64 and Darwin
      # aarch64. Do not advertise dev shells whose toolchain evaluation is
      # guaranteed to fail in moonbit-overlay.
      systems = [
        "x86_64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f (pkgsFor system));
      cCompilerFor = pkgs: if pkgs.stdenv.isLinux then pkgs.gcc else pkgs.clang;
      toolchainFor = pkgs: [
        pkgs.moonbit-bin.moonbit.latest
        (cCompilerFor pkgs)
        pkgs.nodejs
      ];
      pkgsFor =
        system:
        import nixpkgs {
          inherit system;
          overlays = [ moonbit-overlay.overlays.default ];
        };
    in
    {
      devShells = forAllSystems (pkgs: {
        # `nix develop` -> MoonBit plus every runtime/compiler needed by the
        # repository's cross-backend test matrix. Keep the platform C compiler
        # explicit so the native backend does not fall back to bundled TinyCC.
        default = pkgs.mkShell {
          packages = toolchainFor pkgs;
        };
      });

      checks = forAllSystems (pkgs: {
        default = pkgs.runCommand "flate-check" { nativeBuildInputs = toolchainFor pkgs; } ''
          export HOME="$TMPDIR/home"
          mkdir -p "$HOME"
          cp -R ${self} source
          chmod -R u+w source
          cd source
          moon check --target all --warn-list +73 --deny-warn
          moon fmt --check
          moon test --target native --warn-list +73 --deny-warn
          touch "$out"
        '';
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt);
    };
}
