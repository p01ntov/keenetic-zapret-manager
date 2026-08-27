# Parse the pretty-printed JSON returned by GitHub's releases API.
# Output: tag|asset name|sha256 digest|download URL

function json_value(line, value) {
    value = line
    sub(/^[^:]*:[[:space:]]*"/, "", value)
    sub(/",?[[:space:]]*$/, "", value)
    return value
}

function emit_asset() {
    if (tag != "" && asset != "" && url != "") {
        print tag "|" asset "|" digest "|" url
    }
    asset = ""
    digest = ""
    url = ""
}

/"tag_name"[[:space:]]*:/ {
    emit_asset()
    tag = json_value($0)
    in_assets = 0
    next
}

/"assets"[[:space:]]*:[[:space:]]*\[/ {
    in_assets = 1
    next
}

/"name"[[:space:]]*:/ {
    if (tag != "" && in_assets) {
        emit_asset()
        asset = json_value($0)
    }
    next
}

/"digest"[[:space:]]*:/ {
    if (asset != "") {
        digest = json_value($0)
    }
    next
}

/"browser_download_url"[[:space:]]*:/ {
    if (tag != "" && asset != "") {
        url = json_value($0)
    }
}

END {
    emit_asset()
}
