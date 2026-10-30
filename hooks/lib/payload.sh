# Hook payload access (sourced by the guild hooks; POSIX sh).
# The harness sends one compact JSON object on stdin. Fields are located by name with sed
# and never parsed as code: the payload is untrusted data, only ever matched against fixed
# patterns. The search is by name, so nested objects are fine; the first occurrence wins.
set -u

PAYLOAD=''
# Placeholder bytes: raw control characters cannot occur inside a valid JSON string.
_PAYLOAD_MARK=$(printf '\037')
_PAYLOAD_QUOTE=$(printf '\036')
_PAYLOAD_TAB=$(printf '\t')
# The Claude Directory validator cannot read quote juggling or a backslash next to a quote in a
# sed program, so those characters are built once here. In a sed program a backslash is written
# as two, and a newline in a replacement as a backslash before it.
_PAYLOAD_DOUBLE_QUOTE=$(printf '\042')
_PAYLOAD_BACKSLASH=$(printf '\134')
_PAYLOAD_SED_BACKSLASH="$_PAYLOAD_BACKSLASH$_PAYLOAD_BACKSLASH"
_PAYLOAD_SED_NEWLINE="$_PAYLOAD_BACKSLASH
"

# Reads all of stdin into PAYLOAD; empty stdin leaves it empty.
payload_read() {
  PAYLOAD=$(cat 2>/dev/null) || PAYLOAD=''
}

# Prints the decoded string value of the first "NAME":"..." in PAYLOAD.
# Returns 1 (printing nothing) when the field is absent or its value is not a string.
payload_field() {
  _payload_is_name "$1" || return 1
  _payload_value=$(printf '%s\n' "$PAYLOAD" | _payload_extract "$1") || return 1
  [ -n "$_payload_value" ] || return 1
  printf '%s' "${_payload_value#=}"
}

# Returns 0 when "NAME":true occurs in PAYLOAD.
payload_bool() {
  _payload_flag=$_PAYLOAD_DOUBLE_QUOTE$1$_PAYLOAD_DOUBLE_QUOTE
  printf '%s\n' "$PAYLOAD" | LC_ALL=C grep -q -F -e "$_payload_flag:true" -e "$_payload_flag: true"
}

# Prints the first line of TEXT that is not blank, trimmed of surrounding whitespace.
payload_first_line() {
  printf '%s\n' "$1" | LC_ALL=C sed -n -e '/[^[:space:]]/{' -e 's/^[[:space:]]*//' \
    -e 's/[[:space:]]*$//' -e 'p' -e 'q' -e '}'
}

# Succeeds when NAME is not empty and holds only [A-Za-z0-9_].
_payload_is_name() {
  [ -n "$1" ] || return 1
  [ "${1%%[!A-Za-z0-9_]*}" = "$1" ]
}

# sed filter: prints "=" + the decoded value of the first "NAME":"..." on stdin, else nothing.
# After the opening quote, escaped backslashes and then escaped quotes are parked on
# placeholders, so the first raw quote left is the closing one (no closing quote: absent).
# Parking `\\` first keeps `\\n` or a Windows path such as `C:\\tests` a backslash instead of
# a newline or a tab. Every step is a plain substitution, linear in the payload size, so a
# large subagent message stays fast. \uXXXX is left untouched.
_payload_extract() {
  _payload_open="s/$_PAYLOAD_DOUBLE_QUOTE$1$_PAYLOAD_DOUBLE_QUOTE[[:space:]]*:[[:space:]]*$_PAYLOAD_DOUBLE_QUOTE/$_PAYLOAD_MARK/"
  LC_ALL=C sed -n -e "$_payload_open" -e 't found' -e 'd' \
    -e ':found' -e "s/^[^$_PAYLOAD_MARK]*$_PAYLOAD_MARK//" \
    -e "s/$_PAYLOAD_SED_BACKSLASH$_PAYLOAD_SED_BACKSLASH/$_PAYLOAD_MARK/g" \
    -e "s/$_PAYLOAD_SED_BACKSLASH$_PAYLOAD_DOUBLE_QUOTE/$_PAYLOAD_QUOTE/g" \
    -e "/$_PAYLOAD_DOUBLE_QUOTE/!q" -e "s/$_PAYLOAD_DOUBLE_QUOTE.*//" \
    -e "s/$_PAYLOAD_QUOTE/$_PAYLOAD_DOUBLE_QUOTE/g" -e "s|$_PAYLOAD_SED_BACKSLASH/|/|g" \
    -e "s/${_PAYLOAD_SED_BACKSLASH}n/$_PAYLOAD_SED_NEWLINE/g" -e "s/${_PAYLOAD_SED_BACKSLASH}t/$_PAYLOAD_TAB/g" \
    -e "s/${_PAYLOAD_SED_BACKSLASH}r//g" -e "s/$_PAYLOAD_MARK/$_PAYLOAD_SED_BACKSLASH/g" -e 's/^/=/' -e 'p' -e 'q'
}
