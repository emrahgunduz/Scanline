# Sourced by the build scripts: decides how Scanline is signed.
#
#   SCANLINE_SIGN_IDENTITY=-        ad-hoc (no Apple Developer account; today's default)
#   SCANLINE_SIGN_IDENTITY=<id>     a SHA-1 hash or the full "Developer ID Application: … (TEAMID)" name
#   unset                           the first "Developer ID Application" identity in the keychain,
#                                   or ad-hoc when there is none
#
# Prints the identity to use ("-" for ad-hoc).
resolve_identity() {
  if [[ -n ${SCANLINE_SIGN_IDENTITY:-} ]]; then
    print -r -- "$SCANLINE_SIGN_IDENTITY"
    return
  fi
  local hash
  hash=$(security find-identity -v -p codesigning 2>/dev/null \
    | awk '/"Developer ID Application: / { print $2; exit }')
  print -r -- "${hash:--}"
}

# True when the identity is a real (Developer ID) signature rather than ad-hoc.
is_developer_id() {
  [[ ${1:--} != - ]]
}
