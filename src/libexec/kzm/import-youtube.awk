function rewrite_path(line) {
    gsub(/\r$/, "", line)
    gsub("/opt/zapret/ipset/zapret-hosts-google.txt", youtube_file, line)
    gsub("/opt/zapret/files/fake/4pda.bin", fake_dir "/tls_clienthello_4pda_to.bin", line)
    gsub("/opt/zapret/files/fake/", fake_dir "/", line)
    return line
}
function close_profile() {
    if (file != "") {
        close(file)
    }
    file = ""
    name = ""
}

{
    sub(/\r$/, "")
}

/^#Yv[0-9][0-9]*[[:space:]]*$/ {
    close_profile()
    name = $0
    sub(/^#/, "", name)
    sub(/[[:space:]]*$/, "", name)
    file = youtube_dir "/" name ".strategy"
    print "# source=StressOzz/Zapret-Manager profile=" name > file
    next
}

file != "" && /^--/ {
    print rewrite_path($0) >> file
}

END {
    close_profile()
}
