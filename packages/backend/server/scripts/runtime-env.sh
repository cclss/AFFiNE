#!/bin/sh
# Platform variables, translated into the server's own.
#
#   PORT       -> AFFINE_SERVER_PORT
#   REDIS_URL  -> REDIS_SERVER_HOST / _PORT / _USERNAME / _PASSWORD
#
# Sourced by scripts/self-host-entrypoint.sh, ahead of its branch on where the
# data lives; never executed on its own. Everything it decides, it decides by
# exporting a variable into the process that later becomes the server — which
# is also why a `REDIS_URL` reaches that branch as a filled REDIS_SERVER_HOST
# and selects the cache outside this image, with no second copy of that
# decision here.
#
# A host that starts a container names two things in its own vocabulary: the
# port the process must listen on, and the cache it provisioned. This server
# names the same two in its own. Translating in one place keeps that dialect
# out of the configuration layer, out of the Dockerfile, and out of the compose
# files — none of which should have to learn a second name for a port.
#
# Precedence, both times: the server's own variable wins. It is the more
# specific of the two, an operator who set it meant it, and every deployment
# that predates this file keeps behaving exactly as it did. The platform
# variable is then reported as unread rather than dropped in silence.
#
# Empty counts as unset, as it does in the branch downstream: `docker run -e
# PORT` with no value is not a request to listen on nothing.
#
# Branch behaviour is covered by scripts/self-host-entrypoint.test.sh.

# ---------------------------------------------------------------------------
# Output.
#
# Notices follow the cli-target-notice component's startup-target extension,
# the same one the entrypoint's own notices follow: one line per decision, the
# deciding variable named in it, and how to decide the other way on the same
# line. They come from the caller so that every line of this startup carries
# one prefix and reads as one voice.
#
# A URL that names a cache also carries its password, so no line below ever
# prints REDIS_URL — not even the ones that reject it. Host and port are not
# secrets and are printed, because a notice that names no value tells an
# operator nothing.
# ---------------------------------------------------------------------------
if ! command -v notice >/dev/null 2>&1 || ! command -v fail >/dev/null 2>&1; then
  printf '[entrypoint] scripts/runtime-env.sh was sourced before `notice` and `fail` were defined; it reports every decision through them.\n' >&2
  exit 1
fi

# The port a `redis://` URL means when it names none.
REDIS_URL_DEFAULT_PORT='6379'

# ---------------------------------------------------------------------------
# Helpers.
# ---------------------------------------------------------------------------

# True for a decimal port number in range. Checked as text before it is checked
# as a number: `test` on a 30-digit string is an error message on stderr in most
# shells, and the caller wants its own sentence there instead.
is_port() {
  case ${1:-} in
    '' | *[!0-9]*) return 1 ;;
  esac

  [ "${#1}" -le 5 ] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

# Percent-decoding, per RFC 3986. The userinfo of a URL cannot carry `@`, `/`
# or `:` literally, so a generated password containing any of them arrives as
# %40, %2F or %3A and would authenticate as the wrong string if handed over
# as-is. Text between escapes is copied in one go rather than character by
# character, so the common password costs no subshell at all.
url_decode() {
  decode_rest=${1:-}
  decode_out=''

  while [ -n "$decode_rest" ]; do
    case $decode_rest in
      %[0-9A-Fa-f][0-9A-Fa-f]*)
        decode_tail=${decode_rest#???}
        decode_hex=${decode_rest#%}
        decode_hex=${decode_hex%"$decode_tail"}
        # Through arithmetic expansion, which POSIX requires to read a C
        # hexadecimal constant, rather than through printf's own numeric
        # argument, which not every shell reads the same way.
        decode_out="${decode_out}$(printf "\\$(printf '%03o' "$((0x${decode_hex}))")")"
        decode_rest=$decode_tail
        ;;
      *)
        # Up to the next %, or the whole remainder when there is none. Empty
        # only when the remainder opens with a % that is not an escape, which
        # is a literal % and is taken as one.
        decode_chunk=${decode_rest%%%*}
        [ -n "$decode_chunk" ] || decode_chunk='%'
        decode_out="${decode_out}${decode_chunk}"
        decode_rest=${decode_rest#"$decode_chunk"}
        ;;
    esac
  done

  printf '%s' "$decode_out"
}

# ---------------------------------------------------------------------------
# The port.
# ---------------------------------------------------------------------------
if [ -n "${PORT:-}" ] && [ -n "${AFFINE_SERVER_PORT:-}" ]; then
  notice '`AFFINE_SERVER_PORT` is set — the server listens on the port it names, and `PORT` is left unread; unset it to follow `PORT`.'
elif [ -n "${PORT:-}" ]; then
  # Rejected rather than rounded, clamped or ignored: a server that listens on
  # a port nobody routes to is indistinguishable from one that never started,
  # and it is the platform's contract that is wrong here, not the operator's
  # patience.
  if ! is_port "$PORT"; then
    fail "\`PORT\` is set to '${PORT}', which is not a port number between 1 and 65535."
  fi

  AFFINE_SERVER_PORT=$PORT
  export AFFINE_SERVER_PORT
  notice "\`PORT\` is set — the server will listen on port ${PORT}; set \`AFFINE_SERVER_PORT\` to choose the port yourself."
else
  notice '`PORT` is empty — the server listens on the port it is configured with; set it to the port this host expects.'
fi

# ---------------------------------------------------------------------------
# The cache.
# ---------------------------------------------------------------------------
if [ -n "${REDIS_URL:-}" ] && [ -n "${REDIS_SERVER_HOST:-}" ]; then
  notice '`REDIS_SERVER_HOST` is set — the cache is the one it names, and `REDIS_URL` is left unread; unset it to follow `REDIS_URL`.'
elif [ -n "${REDIS_URL:-}" ]; then
  case $REDIS_URL in
    redis://*)
      redis_authority=${REDIS_URL#redis://}
      ;;
    rediss://*)
      # The client's TLS options live in the `redis.ioredis` configuration,
      # which no environment variable reaches. Connecting anyway would send the
      # password in the URL across the network in the clear, so the connection
      # is refused instead.
      fail 'the `REDIS_URL` given is a `rediss://` URL, and TLS to the cache cannot be configured through the environment; it is refused rather than connected to in the clear.'
      ;;
    *)
      fail 'the `REDIS_URL` given is not a `redis://host[:port]` URL; its value is not repeated here because it may carry a password.'
      ;;
  esac

  # Whatever follows the host, split off before the host is read. `/0` is the
  # database index the server already uses, so it changes nothing and passes;
  # anything else would change something this file does not translate, and
  # passing it would mean quietly using a different cache than the URL names.
  redis_extra=''
  case $redis_authority in
    */*)
      redis_extra=/${redis_authority#*/}
      redis_authority=${redis_authority%%/*}
      ;;
    *\?*)
      redis_extra=\?${redis_authority#*\?}
      redis_authority=${redis_authority%%\?*}
      ;;
  esac

  case $redis_extra in
    '' | / | /0) ;;
    *)
      fail "the \`REDIS_URL\` given carries '${redis_extra}' after the host, which this image does not translate; set \`REDIS_SERVER_DATABASE\` to choose a database index."
      ;;
  esac

  # userinfo, then host and port. Both splits take the last separator: a host
  # holds no `@`, and an IPv6 literal holds colons of its own, which is what
  # the bracket case below is for.
  redis_username=''
  redis_password=''
  case $redis_authority in
    *@*)
      redis_userinfo=${redis_authority%@*}
      redis_hostport=${redis_authority##*@}
      case $redis_userinfo in
        *:*)
          redis_username=${redis_userinfo%%:*}
          redis_password=${redis_userinfo#*:}
          ;;
        *)
          redis_username=$redis_userinfo
          ;;
      esac
      ;;
    *)
      redis_hostport=$redis_authority
      ;;
  esac

  case $redis_hostport in
    \[*)
      redis_host=${redis_hostport%%\]*}
      redis_host=${redis_host#\[}
      redis_port=${redis_hostport##*\]}
      redis_port=${redis_port#:}
      ;;
    *:*)
      redis_host=${redis_hostport%%:*}
      redis_port=${redis_hostport#*:}
      ;;
    *)
      redis_host=$redis_hostport
      redis_port=''
      ;;
  esac

  if [ -z "$redis_host" ]; then
    fail 'the `REDIS_URL` given names no host; its value is not repeated here because it may carry a password.'
  fi

  if [ -z "$redis_port" ]; then
    redis_port=$REDIS_URL_DEFAULT_PORT
  elif ! is_port "$redis_port"; then
    fail "the \`REDIS_URL\` given names port '${redis_port}', which is not a port number between 1 and 65535."
  fi

  # All four are written, including the credentials the URL leaves out. One URL
  # describes one cache completely, so merging it with the leftovers of another
  # would produce a connection neither of them asked for — the same reason the
  # embedded cache overwrites rather than merges.
  REDIS_SERVER_HOST=$redis_host
  REDIS_SERVER_PORT=$redis_port
  REDIS_SERVER_USERNAME=$(url_decode "$redis_username")
  REDIS_SERVER_PASSWORD=$(url_decode "$redis_password")
  export REDIS_SERVER_HOST REDIS_SERVER_PORT REDIS_SERVER_USERNAME REDIS_SERVER_PASSWORD

  notice "\`REDIS_URL\` is set — using the cache at ${redis_host}:${redis_port}; unset it to start the cache inside this image."
else
  notice '`REDIS_URL` is empty — the cache is chosen by `REDIS_SERVER_HOST`; set it to name host, port and credentials in one variable.'
fi
