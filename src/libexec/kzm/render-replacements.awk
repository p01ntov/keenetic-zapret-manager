function add_port(proto, value,    count, parts, i, port, key) {
    count = split(value, parts, ",")
    for (i = 1; i <= count; i++) {
        port = parts[i]
        gsub(/-/, ":", port)
        if (port == "") {
            continue
        }
        key = proto SUBSEP port
        if (!(key in seen_port)) {
            seen_port[key] = 1
            if (proto == "tcp") {
                tcp_ports = tcp_ports (tcp_ports == "" ? "" : ",") port
            } else {
                udp_ports = udp_ports (udp_ports == "" ? "" : ",") port
            }
        }
    }
}
function join_range(first, last,    i, result) {
    result = ""
    for (i = first; i <= last; i++) {
        if (lines[i] == "") {
            continue
        }
        result = result (result == "" ? "" : " ") lines[i]
    }
    return result
}

{
    line = $0
    sub(/\r$/, "", line)
    if (line == "") {
        next
    }
    line_count++
    lines[line_count] = line
    if (line == "--new") {
        last_new = line_count
    }
    if (line ~ /^--filter-tcp=/) {
        value = line
        sub(/^--filter-tcp=/, "", value)
        add_port("tcp", value)
    } else if (line ~ /^--filter-tcp[[:space:]]+/) {
        value = line
        sub(/^--filter-tcp[[:space:]]+/, "", value)
        add_port("tcp", value)
    }
    if (line ~ /^--filter-udp=/) {
        value = line
        sub(/^--filter-udp=/, "", value)
        add_port("udp", value)
    } else if (line ~ /^--filter-udp[[:space:]]+/) {
        value = line
        sub(/^--filter-udp[[:space:]]+/, "", value)
        add_port("udp", value)
    }
}

END {
    if (line_count == 0) {
        exit 2
    }
    if (last_new == 0) {
        custom = ""
        main = join_range(1, line_count)
    } else {
        custom = join_range(1, last_new - 1)
        main = join_range(last_new + 1, line_count)
    }

    print "NFQWS_ARGS\t" main
    print "NFQWS_ARGS_QUIC\t"
    print "NFQWS_ARGS_UDP\t"
    print "NFQWS_EXTRA_ARGS\t"
    print "NFQWS_ARGS_IPSET\t"
    print "NFQWS_ARGS_CUSTOM\t" custom
    print "TCP_PORTS\t" tcp_ports
    print "UDP_PORTS\t" udp_ports
}
