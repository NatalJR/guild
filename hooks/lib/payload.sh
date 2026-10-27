# Hook payload access (sourced by the guild hooks; POSIX sh).
# The harness sends one compact JSON object on stdin. Fields are located by key name with sed
# and never parsed as code: the payload is untrusted data, only ever matched against fixed
# patterns. The search is by key, so nested objects are fine; the first occurrence wins.
set -u

PAYLOAD=''
# Placeholder bytes: raw control characters cannot occur inside a valid JSON string.
_PAYLOAD_MARK=$(printf '\037')
_PAYLOAD_QUOTE=$(printf '\036')
_PAYLOAD_TAB=$(printf '\t')

# Reads all of stdin into PAYLOAD; empty stdin leaves it empty.
payload_read() {
  PAYLOAD=$(cat 2>/dev/null) || PAYLOAD=''
}

# Prints the decoded string value of the first "NAME":"..." in PAYLOAD.
# Returns 1 (printing nothing) when the key is absent or its value is not a string.
payload_field() {
  case "$1" in '' | *[!A-Za-z0-9_]*) return 1 ;; esac
  _payload_value=$(printf '%s\n' "$PAYLOAD" | _payload_extract "$1") || return 1
  [ -n "$_payload_value" ] || return 1
  printf '%s' "${_payload_value#=}"
}

# Returns 0 when "NAME":true occurs in PAYLOAD.
payload_bool() {
  case "$PAYLOAD" in
    *"\"$1\":true"* | *"\"$1\": true"*) return 0 ;;
  esac
  return 1
}

# Prints the first line of TEXT that is not blank, trimmed of surrounding whitespace.
payload_first_line() {
  printf '%s\n' "$1" | LC_ALL=C sed -n -e '/[^[:space:]]/{' -e 's/^[[:space:]]*//' \
    -e 's/[[:space:]]*$//' -e 'p' -e 'q' -e '}'
}

# sed filter: prints "=" + the decoded value of the first "NAME":"..." on stdin, else nothing.
# After the opening quote, escaped backslashes and then escaped quotes are parked on
# placeholders, so the first raw quote left is the closing one (no closing quote: absent).
# Parking `\\` first keeps `\\n` or a Windows path such as `C:\\tests` a backslash instead of
# a newline or a tab. Every step is a plain substitution, linear in the payload size, so a
# large subagent message stays fast. \uXXXX is left untouched.
_payload_extract() {
  LC_ALL=C sed -n \
    -e 's/"'"$1"'"[[:space:]]*:[[:space:]]*"/'"$_PAYLOAD_MARK"'/' -e 't found' -e 'd' \
    -e ':found' -e 's/^[^'"$_PAYLOAD_MARK"']*'"$_PAYLOAD_MARK"'//' \
    -e 's/\\\\/'"$_PAYLOAD_MARK"'/g' -e 's/\\"/'"$_PAYLOAD_QUOTE"'/g' \
    -e '/"/!q' -e 's/".*$//' \
    -e 's/'"$_PAYLOAD_QUOTE"'/"/g' -e 's|\\/|/|g' -e 's/\\n/\
/g' -e 's/\\t/'"$_PAYLOAD_TAB"'/g' -e 's/\\r//g' -e 's/'"$_PAYLOAD_MARK"'/\\/g' \
    -e 's/^/=/' -e 'p' -e 'q'
}
