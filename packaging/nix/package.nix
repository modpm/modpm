# callPackage-style derivation, used by ../../flake.nix.
{
  lib,
  stdenv,
  ldc,
  dub,
  curl,
  less,
  makeWrapper,
  src,
  cmd,
  version,
}:

let
  cmdVersion = (builtins.fromJSON (builtins.readFile "${src}/dub.selections.json")).versions.cmd;
in
stdenv.mkDerivation {
  pname = "modpm";
  inherit version src;

  nativeBuildInputs = [
    ldc
    dub
    makeWrapper
  ];
  buildInputs = [ curl ];

  postPatch = ''
    # The app reads its version from this file at compile time.
    echo "${version}" > VERSION
  '';

  buildPhase = ''
    runHook preBuild

    # The sandbox has no network, so the `cmd` library comes from the flake input.
    export DUB_HOME="$TMPDIR/dub"
    mkdir -p "$DUB_HOME"
    cp -r ${cmd} cmd-src
    chmod -R u+w cmd-src
    dub add-local cmd-src ${cmdVersion}

    dub build --skip-registry=all --compiler=ldc2 --build=release

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 modpm $out/bin/modpm
    runHook postInstall
  '';

  # `less` is the default pager. Append it to PATH so it is always available
  # without overriding a `less` or $PAGER the user already has.
  postFixup = ''
    wrapProgram $out/bin/modpm --suffix PATH : ${lib.makeBinPath [ less ]}
  '';

  meta = {
    description = "Package manager for Modrinth projects";
    homepage = "https://github.com/modpm/modpm";
    license = lib.licenses.gpl3Only;
    mainProgram = "modpm";
    platforms = lib.platforms.unix;
  };
}
