# Convert Hyperion suite.v2.json objects to KZM's label|url format.
# The upstream file is intentionally parsed narrowly: only safe id/host values
# are accepted, and malformed objects are ignored.

function json_string(line, key,    marker, tail, pos, value) {
    marker = "\042" key "\042"
    pos = index(line, marker)
    if (!pos) return ""
    tail = substr(line, pos + length(marker))
    pos = index(tail, ":")
    if (!pos) return ""
    tail = substr(tail, pos + 1)
    sub(/^[[:space:]]*\042/, "", tail)
    value = tail
    sub(/\042.*/, "", value)
    return value
}

{
    sub(/\r$/, "")
    rest = $0
    while (index(rest, "\042id\042")) {
        id = json_string(rest, "id")
        host = json_string(rest, "host")
        if (id ~ /^[A-Za-z0-9][A-Za-z0-9_.-]*$/ &&
            host ~ /^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$/ &&
            host ~ /\./ && host !~ /\.\./ && !seen[id]++) {
            print id "|https://" host "/"
        }
        host_marker = index(rest, "\042host\042")
        if (!host_marker) break
        rest = substr(rest, host_marker + 6)
    }
}
