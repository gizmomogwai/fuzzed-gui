{
  description = "Standalone fuzzed graphical picker with GLFW and OpenGL";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { nixpkgs, ... }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
    in {
      devShells = nixpkgs.lib.genAttrs systems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          graphicsPackages = [ pkgs.glfw ]
            ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [
              pkgs.libx11 pkgs.libglvnd pkgs.mesa
            ];
        in {
          default = pkgs.mkShell {
            packages = [ pkgs.ldc pkgs.dub ] ++ graphicsPackages;
            shellHook = if pkgs.stdenv.hostPlatform.isDarwin then ''
              export DYLD_LIBRARY_PATH="${pkgs.glfw}/lib''${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
            '' else ''
              export LD_LIBRARY_PATH="${pkgs.lib.makeLibraryPath graphicsPackages}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
            '';
          };
        });
    };
}
