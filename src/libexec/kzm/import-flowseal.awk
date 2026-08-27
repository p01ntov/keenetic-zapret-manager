# Extract only the general TCP block from one Flowseal general*.bat profile.
# YouTube, Discord, QUIC and game blocks are composed separately by KZM.

function fail(message) {
    print message > "/dev/stderr"
    bad = 1
}

function emit_option(option) {
    if (option == "" || option == "^" || option == "--new") {
        return
    }
    if (option ~ /^--hostlist=%LISTS%list-general(-user)?\.txt$/) {
        return
    }
    if (option ~ /^--hostlist-exclude=/ || option ~ /^--ipset-exclude=/) {
        return
    }
    if (option ~ /^--ipset=%LISTS%ipset-all\.txt$/) {
        return
    }
    if (option ~ /%[A-Za-z]/ || option ~ /[\042\047\\]/ || option ~ /\^/) {
        fail("unsupported Flowseal placeholder or quoting in: " option)
        return
    }
    print option >> output_file
}

BEGIN {
    found = 0
    bad = 0
}

{
    line = $0
    sub(/\r$/, "", line)
    if (line !~ /^--filter-tcp=80,443[[:space:]]+--hostlist=\042%LISTS%list-general\.txt\042/) {
        next
    }
    if (found) {
        next
    }
    found = 1

    gsub(/\042/, "", line)
    gsub(/\^!/, fake_dir "/tls_clienthello_www_google_com.bin", line)
    gsub(/%BIN%/, fake_dir "/", line)

    print "# source=Flowseal/zapret-discord-youtube profile=" profile_label > output_file
    print "--filter-tcp=80,443" >> output_file
    print "--hostlist-exclude=" exclude_file >> output_file

    count = split(line, options, /[[:space:]]+/)
    for (i = 1; i <= count; i++) {
        if (options[i] == "--filter-tcp=80,443") {
            continue
        }
        emit_option(options[i])
    }
    close(output_file)
}

END {
    if (!found) {
        print "general TCP block was not found in " profile_label > "/dev/stderr"
        exit 2
    }
    if (bad) {
        exit 3
    }
}
