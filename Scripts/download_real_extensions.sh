#!/bin/zsh
set -euo pipefail

output="${1:-Benchmarks/real-extensions/packages}"
mkdir -p "$output"

typeset -A extensions=(
  ublock-origin-lite ddkjiahejlhfcafbddmgiahcphecmpfh
  dark-reader eimadpbcbfnmbkopoojfekhnkhdbieeh
  bitwarden nngceckbapebfimnlniiiahkandclblb
  ublock-origin cjpalhdlnbpafiamejdnhcphjbkeiagm
  adguard bgnkhhnnamicmpeenaelnjfhikgbkllg
  privacy-badger pkehgijcmpdhfbdbbnkijodmdjhbjlgp
  grammarly kbfnbcaeplbcioakkpcpgfkobkghlhen
  honey bmnlcjabgnpnenekpadlanbbkooimhnj
  lastpass hdokiejnpimakedhajhdlcegeplioahd
  onepassword aeblfdkhhhdcdjpifhhbdiojplfjncoa
  metamask nkbihfbeogaeaoehlefnkodbefgpgknn
  react-devtools fmkadmapgofadopljbjfkapdkoienihi
  redux-devtools lmhkpmbekcpmknklioeibfkpmmfibljd
  sponsorblock mnjggcdmjocbbbhaepdhchncahnbgone
  return-youtube-dislike gebbhagfogifgggkldgodflihgfeippi
  vimium dbepggeogbaibhgnhhndojpepiihcmeb
  google-translate aapbdbdomjkkjkaonfhkkikfgjllcleb
  json-viewer gbmdgpbipfallnflgajpaliibnhdgobh
  todoist jldhpllghnbhlbpcmnajkpdmadaolakh
  momentum laookkfknpbbblfpciffpaejjkokdgca
)

for name id in ${(kv)extensions}; do
  target="$output/$name.crx"
  if [[ -f "$target" ]] && [[ "$(dd if="$target" bs=1 count=4 2>/dev/null)" == "Cr24" ]]; then
    continue
  fi
  url="https://clients2.google.com/service/update2/crx?response=redirect&prodversion=140.0.0.0&acceptformat=crx2,crx3&x=id%3D${id}%26uc"
  curl --fail --location --silent --show-error --retry 2 "$url" --output "$target"
  magic=$(dd if="$target" bs=1 count=4 2>/dev/null)
  [[ "$magic" == "Cr24" ]] || { print -u2 "Invalid CRX: $name"; exit 1; }
done

shasum -a 256 "$output"/*.crx > "$output/SHA256SUMS"
