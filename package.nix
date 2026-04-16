{
  lib,
  stdenv,
  makeWrapper,
  shellcheck,
  bash,
  systemd,
  coreutils,
  gawk,
  util-linux,
}:

stdenv.mkDerivation {
  pname = "nmtrust";
  version = "0.1.0";
  src = lib.fileset.toSource {
    root = ./.;
    fileset = ./nmtrust.sh;
  };
  nativeBuildInputs = [ makeWrapper ];
  nativeCheckInputs = [ shellcheck ];
  doCheck = true;
  checkPhase = ''
    runHook preCheck
    shellcheck nmtrust.sh
    runHook postCheck
  '';
  installPhase = ''
    runHook preInstall
    install -Dm755 nmtrust.sh $out/bin/nmtrust
    wrapProgram $out/bin/nmtrust \
      --prefix PATH : ${
        lib.makeBinPath [
          bash
          systemd
          coreutils
          gawk
          util-linux
        ]
      }
    runHook postInstall
  '';
}
