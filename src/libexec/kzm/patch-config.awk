BEGIN {
    while ((getline line < replacements_file) > 0) {
        tab = index(line, "\t")
        if (tab == 0) {
            continue
        }
        key = substr(line, 1, tab - 1)
        value = substr(line, tab + 1)
        replacements[key] = value
        order[++replacement_count] = key
    }
    close(replacements_file)
}
{
    matched = 0
    for (i = 1; i <= replacement_count; i++) {
        key = order[i]
        if ($0 ~ "^" key "=") {
            if (!(key in emitted)) {
                print key "=\"" replacements[key] "\""
                emitted[key] = 1
            }
            matched = 1
            break
        }
    }
    if (!matched) {
        print
    }
}

END {
    for (i = 1; i <= replacement_count; i++) {
        key = order[i]
        if (!(key in emitted)) {
            print key "=\"" replacements[key] "\""
        }
    }
}
