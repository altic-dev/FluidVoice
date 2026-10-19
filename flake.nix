{
  description = "Open source voice-to-text dictation app for macOS with on-device AI enhancement";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    # Pin x86_64-darwin to the last nixpkgs release that supports it.
    # nixpkgs-unstable dropped x86_64-darwin in 26.11, so Intel Macs
    # evaluate against the 26.05-darwin branch instead.
    nixpkgs-darwin-legacy.url = "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";
  };

  outputs = { self, nixpkgs, nixpkgs-darwin-legacy }:
    let
      version = "1.6.11";

      # FluidVoice is macOS-only by design (CoreAudio/AppKit, .macOS("15.0")),
      # so the flake targets only darwin systems. The release ships a single
      # universal (x86_64 + arm64) zip, so both systems share the same asset.
      assets = {
        "x86_64-darwin" = {
          file = "Fluid-oss-1.6.11.zip";
          sha256 = "sha256-/AiOhFdMHcPc0Tovs+goxBfbQ3P4h3uyZzM/sl05SdI=";
        };
        "aarch64-darwin" = {
          file = "Fluid-oss-1.6.11.zip";
          sha256 = "sha256-/AiOhFdMHcPc0Tovs+goxBfbQ3P4h3uyZzM/sl05SdI=";
        };
      };

      systems = builtins.attrNames assets;
      forAllSystems = f: nixpkgs.lib.genAttrs systems f;

      pkgsFor = system:
        if system == "x86_64-darwin"
        then nixpkgs-darwin-legacy.legacyPackages.${system}
        else nixpkgs.legacyPackages.${system};

      fluidvoiceFor = system:
        let
          pkgs = pkgsFor system;
          asset = assets.${system};
        in
        pkgs.stdenv.mkDerivation {
          pname = "fluidvoice";
          inherit version;

          src = pkgs.fetchurl {
            url = "https://github.com/altic-dev/FluidVoice/releases/download/v${version}/${asset.file}";
            inherit (asset) sha256;
          };

          nativeBuildInputs = [ pkgs.unzip ];
          sourceRoot = ".";

          dontConfigure = true;
          dontBuild = true;
          # Preserve the Developer-ID-signed, notarized .app byte-for-byte;
          # strip/patchShebangs would invalidate the code signature.
          dontFixup = true;

          installPhase = ''
            runHook preInstall
            mkdir -p "$out/Applications" "$out/bin"
            cp -R FluidVoice.app "$out/Applications/"
            ln -s "$out/Applications/FluidVoice.app/Contents/MacOS/FluidVoice" "$out/bin/fluidvoice"
            runHook postInstall
          '';

          meta = with pkgs.lib; {
            description = "Open source voice-to-text dictation app for macOS with on-device AI enhancement";
            homepage = "https://github.com/altic-dev/FluidVoice";
            downloadPage = "https://github.com/altic-dev/FluidVoice/releases";
            license = licenses.gpl3Only;
            mainProgram = "fluidvoice";
            platforms = systems;
            sourceProvenance = [ sourceTypes.binaryNativeCode ];
          };
        };
    in
    {
      packages = forAllSystems (system: rec {
        fluidvoice = fluidvoiceFor system;
        prebuilt = fluidvoice;
        default = prebuilt;
      });

      apps = forAllSystems (system:
        let
          pkg = fluidvoiceFor system;
        in
        {
          fluidvoice = {
            type = "app";
            program = "${pkg}/bin/fluidvoice";
          };
          prebuilt = {
            type = "app";
            program = "${pkg}/bin/fluidvoice";
          };
          default = {
            type = "app";
            program = "${pkg}/bin/fluidvoice";
          };
        });

      checks = forAllSystems (system: {
        prebuilt = fluidvoiceFor system;
      });
    };
}
