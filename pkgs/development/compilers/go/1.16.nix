{
  lib,
  stdenv,
  fetchurl,
  tzdata,
  substituteAll,
  iana-etc,
  xcbuild,
  mailcap,
  buildPackages,
  pkgsBuildTarget,
  threadsCross,
  testers,
  skopeo,
  buildGo116Module,
}:

let
  goBootstrap = buildPackages.callPackage ./bootstrap121.nix { };

  skopeoTest = skopeo.override { buildGoModule = buildGo116Module; };

  goarch =
    platform:
    {
      "aarch64" = "arm64";
      "arm" = "arm";
      "armv5tel" = "arm";
      "armv6l" = "arm";
      "armv7l" = "arm";
      "i686" = "386";
      "mips" = "mips";
      "mips64el" = "mips64le";
      "mipsel" = "mipsle";
      "powerpc64" = "ppc64";
      "powerpc64le" = "ppc64le";
      "riscv64" = "riscv64";
      "s390x" = "s390x";
      "x86_64" = "amd64";
      "wasm32" = "wasm";
    }
    .${platform.parsed.cpu.name} or (throw "Unsupported system: ${platform.parsed.cpu.name}");

  # We need a target compiler which is still runnable at build time,
  # to handle the cross-building case where build != host == target
  targetCC = pkgsBuildTarget.targetPackages.stdenv.cc;

  isCross = stdenv.buildPlatform != stdenv.targetPlatform;
in
stdenv.mkDerivation (finalAttrs: {
  pname = "go";
  version = "1.16.15";

  src = fetchurl {
    url = "https://go.dev/dl/go${finalAttrs.version}.src.tar.gz";
    hash = "sha256-kKCMaJJ54184ZbpRCZjDOmMlXDYImz7CBskS/AVow9M=";
  };

  strictDeps = true;
  buildInputs =
    [ ]
    ++ lib.optionals stdenv.hostPlatform.isLinux [ stdenv.cc.libc.out ]
    ++ lib.optionals (stdenv.hostPlatform.libc == "glibc") [ stdenv.cc.libc.static ];

  depsTargetTargetPropagated = lib.optionals stdenv.targetPlatform.isDarwin [
    xcbuild
  ];

  depsBuildTarget = lib.optional isCross targetCC;

  depsTargetTarget = lib.optional stdenv.targetPlatform.isWindows threadsCross.package;

  postPatch = ''
    patchShebangs .
  '';

  GOOS = if stdenv.targetPlatform.isWasi then "wasip1" else stdenv.targetPlatform.parsed.kernel.name;
  GOARCH = goarch stdenv.targetPlatform;
  # GOHOSTOS/GOHOSTARCH must match the building system, not the host system.
  # Go will nevertheless build a for host system that we will copy over in
  # the install phase.
  GOHOSTOS = stdenv.buildPlatform.parsed.kernel.name;
  GOHOSTARCH = goarch stdenv.buildPlatform;

  # {CC,CXX}_FOR_TARGET must be only set for cross compilation case as go expect those
  # to be different from CC/CXX
  CC_FOR_TARGET = if isCross then "${targetCC}/bin/${targetCC.targetPrefix}cc" else null;
  CXX_FOR_TARGET = if isCross then "${targetCC}/bin/${targetCC.targetPrefix}c++" else null;

  GOARM = toString (
    lib.intersectLists [ (stdenv.hostPlatform.parsed.cpu.version or "") ] [ "5" "6" "7" ]
  );
  GO386 = "softfloat"; # from Arch: don't assume sse2 on i686
  # Wasi does not support CGO
  CGO_ENABLED = if stdenv.targetPlatform.isWasi then 0 else 1;

  GOROOT_BOOTSTRAP = "${goBootstrap}/share/go";

  buildPhase = ''
    runHook preBuild
    export GOCACHE=$TMPDIR/go-cache
    # this is compiled into the binary
    export GOROOT_FINAL=$out/share/go

    export PATH=$(pwd)/bin:$PATH

    ${lib.optionalString isCross ''
      # Independent from host/target, CC should produce code for the building system.
      # We only set it when cross-compiling.
      export CC=${buildPackages.stdenv.cc}/bin/cc
    ''}
    ulimit -a

    pushd src
    ./make.bash
    popd
    runHook postBuild
  '';

  preInstall =
    ''
      # Contains the wrong perl shebang when cross compiling,
      # since it is not used for anything we can deleted as well.
      rm src/regexp/syntax/make_perl_groups.pl
    ''
    + (
      if (stdenv.buildPlatform.system != stdenv.hostPlatform.system) then
        ''
          mv bin/*_*/* bin
          rmdir bin/*_*
          ${lib.optionalString
            (!(finalAttrs.GOHOSTARCH == finalAttrs.GOARCH && finalAttrs.GOOS == finalAttrs.GOHOSTOS))
            ''
              rm -rf pkg/${finalAttrs.GOHOSTOS}_${finalAttrs.GOHOSTARCH} pkg/tool/${finalAttrs.GOHOSTOS}_${finalAttrs.GOHOSTARCH}
            ''
          }
        ''
      else
        lib.optionalString (stdenv.hostPlatform.system != stdenv.targetPlatform.system) ''
          rm -rf bin/*_*
          ${lib.optionalString
            (!(finalAttrs.GOHOSTARCH == finalAttrs.GOARCH && finalAttrs.GOOS == finalAttrs.GOHOSTOS))
            ''
              rm -rf pkg/${finalAttrs.GOOS}_${finalAttrs.GOARCH} pkg/tool/${finalAttrs.GOOS}_${finalAttrs.GOARCH}
            ''
          }
        ''
    );

  installPhase = ''
    runHook preInstall
    mkdir -p $GOROOT_FINAL
    cp -a bin pkg src lib misc api doc $GOROOT_FINAL
    mkdir -p $out/bin
    ln -s $GOROOT_FINAL/bin/* $out/bin
    runHook postInstall
  '';

  disallowedReferences = [ goBootstrap ];

  passthru = {
    inherit goBootstrap skopeoTest;
    tests = {
      skopeo = testers.testVersion { package = skopeoTest; };
      version = testers.testVersion {
        package = finalAttrs.finalPackage;
        command = "go version";
        version = "go${finalAttrs.version}";
      };
    };
  };

})
