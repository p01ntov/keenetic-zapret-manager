function rewrite_path(line) {
    gsub("/opt/zapret/files/fake/4pda.bin", fake_dir "/tls_clienthello_4pda_to.bin", line)
    gsub("/opt/zapret/files/fake/", fake_dir "/", line)
    return line
}
/^Dv[0-9][0-9]*=\$\047/ {
    source_line = $0
    sub(/\r$/, "", source_line)

    name = source_line
    sub(/=.*/, "", name)
    if (name !~ /^Dv[0-9][0-9]*$/) {
        next
    }

    body = source_line
    sub(/^[^=]*=\$\047/, "", body)
    sub(/\047[[:space:]]*$/, "", body)
    part_count = split(body, parts, /\\n/)
    file = discord_dir "/" name ".strategy"
    print "# source=StressOzz/Zapret-Manager profile=" name > file
    for (i = 1; i <= part_count; i++) {
        if (parts[i] ~ /^--/) {
            print rewrite_path(parts[i]) >> file
        }
    }
    close(file)
}
