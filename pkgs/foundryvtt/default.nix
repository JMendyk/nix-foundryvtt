{ lib
, buildPackages
, unzip
, requireFile
, openssl
, makeWrapper
, gzip
, zstd
, brotli
, pngout
, stdenv
, writeScript
, nodejs
, usePngout ? true
}:

let
  foundry-version-hashes = version:
    (lib.importJSON ./versions.json).${version} or (
      builtins.abort "Unknown foundryvtt version: '${version}'. Please run the update script."
    );

  # Needed to make `buildNpmPackage` work with how the FoundryVTT zip is structured.
  buildNpmPackage = buildPackages.buildNpmPackage.override { inherit fetchNpmDeps; };

  fetchNpmDeps = args: buildPackages.fetchNpmDeps (args // {
    buildInputs = [ unzip ];
    setSourceRoot = ''
      if [[ "$curSrc" =~ FoundryVTT-.*.zip$ ]]; then
        sourceRoot=$(pwd)/resources/app
      fi
    '';
  });

  foundryPkg = finalAttrs:
    let
      shortVersion = "${finalAttrs.majorVersion}.${finalAttrs.build}";
    in
    buildNpmPackage {
      inherit (finalAttrs) pname version;

      src = requireFile {
        name = "FoundryVTT-${shortVersion}.zip";
        inherit (foundry-version-hashes shortVersion) hash;
        url = "https://foundryvtt.com";
      };

      postPatch = ''
        install -m644 "${./deps/package-lock-${shortVersion}.json}" "$sourceRoot/package-lock.json"
      '';

      outputs = [ "out" "gzip" "zstd" "brotli" ];

      buildInputs = [ openssl ];
      nativeBuildInputs = [ makeWrapper unzip gzip zstd brotli ];

      setSourceRoot = "sourceRoot=$(pwd)/resources/app";

      makeCacheWritable = true;
      inherit (foundry-version-hashes shortVersion) npmDepsHash;

      dontNpmBuild = true;

      postInstall =''
        foundryvtt=$out/lib/node_modules/foundryvtt

        mkdir -p "$out/bin" "$out/libexec"

        ln -s "$foundryvtt/main.js" "$out/libexec/foundryvtt"
        chmod a+x "$out/libexec/foundryvtt"

        makeWrapper "$out/libexec/foundryvtt" "$out/bin/foundryvtt" \
          --prefix PATH : "${lib.getBin openssl}/bin"

        ln -s "$foundryvtt/public" "$out/public"

        # Run PNG images through `pngout` if it’s available.
        ${if usePngout then ''
          find $foundryvtt/public -name '*.png' -exec ${pngout}/bin/pngout {} -k1 -y \;
        '' else ""}

        # Precompress assets for use with e.g., Caddy
        for method in gzip zstd brotli; do
          mkdir -p ''${!method}
          cp -R "$foundryvtt/public/"* ''${!method}
          find ''${!method} -name '*.png' -delete -or -name '*.jpg' -delete \
            -or -name '*.webp' -delete -or -name '*.wav' -delete -or -name '*.ico' -delete \
            -or -name '*.icns' -delete
        done

        find "$gzip" -type f -exec gzip -9 {} +
        find "$zstd" -type f -exec zstd -19 --rm {} +
        find "$brotli" -type f -exec brotli -9 --rm {} +
      '';
    };
in
stdenv.mkDerivation (finalAttrs: {
  pname = "foundryvtt";
  version = "11.0.0+307";

  majorVersion = lib.versions.major finalAttrs.version;
  minorVersion = lib.versions.minor finalAttrs.version;
  patchVersion = lib.versions.patch finalAttrs.version;
  build = lib.last (lib.versions.splitVersion finalAttrs.version);

  dontUnpack = true;
  dontFixup = true;

  outputs = [ "out" "gzip" "zstd" "brotli" ];

  installPhase =
    let
      foundryvtt = foundryPkg finalAttrs;
    in ''
      ln -s "${foundryvtt.outPath}" "$out"
      ln -s "${foundryvtt.gzip}" "$gzip"
      ln -s "${foundryvtt.zstd}" "$zstd"
      ln -s "${foundryvtt.brotli}" "$brotli"
    '';

  meta = {
    homepage = "https://foundryvtt.com";
    description = "A self-hosted, modern, and developer-friendly roleplaying platform.";
    #license = lib.licenses.unfree;
    platforms = lib.lists.intersectLists nodejs.meta.platforms openssl.meta.platforms;
  };
})
