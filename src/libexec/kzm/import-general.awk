function clear_lines(    i) {
    for (i in lines) {
        delete lines[i]
    }
    line_count = 0
}

function rewrite_path(line) {
    gsub(/\r$/, "", line)
    gsub("/opt/zapret/ipset/zapret-hosts-user-exclude.txt", exclude_file, line)
    gsub("/opt/zapret/ipset/zapret-hosts-google.txt", youtube_file, line)
    gsub("/opt/zapret/files/fake/4pda.bin", fake_dir "/tls_clienthello_4pda_to.bin", line)
    gsub("/opt/zapret/files/fake/", fake_dir "/", line)
    return line
}

function flush_block(    i, file, has_discord, has_game, block_name, voice_started) {
    if (line_count == 0) {
        clear_lines()
        pending_name = ""
        return
    }

    has_discord = 0
    has_game = 0
    for (i = 1; i <= line_count; i++) {
        if (lines[i] == "--filter-l7=discord,stun") {
            has_discord = 1
        }
        if (lines[i] == "--filter-udp=1024-65535") {
            has_game = 1
        }
    }

    if (pending_name ~ /^v[0-9][0-9]*$/) {
        block_name = pending_name
        file = general_dir "/" block_name ".strategy"
    } else if (has_discord) {
        block_name = "discord-voice"
        file = extras_dir "/discord-voice.strategy"
    } else if (has_game) {
        block_name = "game"
        file = extras_dir "/game.strategy"
    } else {
        clear_lines()
        pending_name = ""
        return
    }

    print "# source=StressOzz/Zapret-Manager profile=" block_name > file
    voice_started = 0
    for (i = 1; i <= line_count; i++) {
        if (has_discord && lines[i] == "--new") {
            if (voice_started) {
                break
            }
            continue
        }
        if (has_discord) {
            voice_started = 1
        }
        print rewrite_path(lines[i]) >> file
    }
    close(file)
    clear_lines()
    pending_name = ""
}

BEGIN {
    in_fence = 0
    pending_name = ""
    clear_lines()
}

{
    sub(/\r$/, "")
}

/^# v[0-9][0-9]*[[:space:]]*$/ {
    pending_name = $0
    sub(/^# /, "", pending_name)
    sub(/[[:space:]]*$/, "", pending_name)
    next
}

/^```/ {
    if (in_fence) {
        flush_block()
        in_fence = 0
    } else {
        clear_lines()
        in_fence = 1
    }
    next
}

in_fence && /^--/ {
    line_count++
    lines[line_count] = $0
}

END {
    if (in_fence && line_count > 0) {
        flush_block()
    }
}
