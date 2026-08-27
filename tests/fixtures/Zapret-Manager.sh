#!/bin/sh
Dv1=$'--filter-tcp=2053,2083,2087,2096,8443\n--hostlist-domains=discord.media\n--dpi-desync=multisplit\n--dpi-desync-split-seqovl=652\n--dpi-desync-split-pos=2\n--dpi-desync-split-seqovl-pattern=/opt/zapret/files/fake/tls_clienthello_www_google_com.bin'
Dv2=$'--filter-tcp=2053,2083,2087,2096,8443\n--hostlist-domains=discord.media\n--dpi-desync=fake,multisplit\n--dpi-desync-split-seqovl=681\n--dpi-desync-split-pos=1\n--dpi-desync-fooling=ts\n--dpi-desync-repeats=8\n--dpi-desync-split-seqovl-pattern=/opt/zapret/files/fake/tls_clienthello_www_google_com.bin'
