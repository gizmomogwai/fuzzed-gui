{
  description = "Standalone fuzzed graphical picker with GLFW and OpenGL";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # The dub path dependencies ../14-fuzzed and ../dimgui. For local work on them use
    # --override-input fuzzed path:../14-fuzzed --override-input dimgui path:../dimgui.
    fuzzed = {
      url = "github:gizmomogwai/fuzzed";
      flake = false;
    };
    dimgui = {
      url = "github:gizmomogwai/dimgui";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, fuzzed, dimgui }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
      forAllSystems = function:
        nixpkgs.lib.genAttrs systems (system: function nixpkgs.legacyPackages.${system});
      # GLFW is loaded at runtime by bindbc, and loads X11 and OpenGL itself.
      graphicsPackages = pkgs:
        [ pkgs.glfw ] ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [
          pkgs.libx11 pkgs.libglvnd pkgs.mesa
        ];
      libraryPathVariable = pkgs:
        if pkgs.stdenv.hostPlatform.isDarwin then "DYLD_LIBRARY_PATH" else "LD_LIBRARY_PATH";
    in {
      packages = forAllSystems (pkgs: {
        default = pkgs.buildDubPackage {
          pname = "fuzzed-gui";
          version = self.shortRev or self.dirtyShortRev or "dirty";
          src = self;
          dubLock = ./dub-lock.json;
          nativeBuildInputs = [ pkgs.makeWrapper ];
          # dub.sdl expects its path dependencies next to the source root.
          postUnpack = ''
            cp -r --no-preserve=mode ${fuzzed} 14-fuzzed
            cp -r --no-preserve=mode ${dimgui} dimgui
          '';
          # The picker loads DroidSans.ttf from the directory of its executable.
          installPhase = ''
            runHook preInstall
            install -D out/fuzzed-gui $out/libexec/fuzzed-gui/fuzzed-gui
            install -D --mode=644 out/DroidSans.ttf $out/libexec/fuzzed-gui/DroidSans.ttf
            makeWrapper $out/libexec/fuzzed-gui/fuzzed-gui $out/bin/fuzzed-gui \
              --prefix ${libraryPathVariable pkgs} : ${pkgs.lib.makeLibraryPath (graphicsPackages pkgs)}
            runHook postInstall
          '';
          meta = {
            description = "Graphical fuzzy finder: reads lines on stdin, prints the chosen one";
            homepage = "https://github.com/gizmomogwai/fuzzed-gui";
            license = pkgs.lib.licenses.mit;
            mainProgram = "fuzzed-gui";
          };
        };
      });

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [ pkgs.ldc pkgs.dub ] ++ graphicsPackages pkgs;
          shellHook = if pkgs.stdenv.hostPlatform.isDarwin then ''
            export DYLD_LIBRARY_PATH="${pkgs.glfw}/lib''${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
          '' else ''
            export LD_LIBRARY_PATH="${pkgs.lib.makeLibraryPath (graphicsPackages pkgs)}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
          '';
        };
      });
    };
}
