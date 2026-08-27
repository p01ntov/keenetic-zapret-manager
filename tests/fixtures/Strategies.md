# v1
```
--filter-tcp=443
--hostlist-exclude=/opt/zapret/ipset/zapret-hosts-user-exclude.txt
--dpi-desync=split2
--dpi-desync-split-seqovl=681
--dpi-desync-split-seqovl-pattern=/opt/zapret/files/fake/stun.bin
```
# v7
```
--filter-tcp=443
--hostlist-exclude=/opt/zapret/ipset/zapret-hosts-user-exclude.txt
--dpi-desync=fake,multisplit
--dpi-desync-split-pos=1
--dpi-desync-fooling=badseq,badsum
--dpi-desync-fake-tls=/opt/zapret/files/fake/stun.bin
```

# Strategy for games
```
--new
--filter-udp=1024-65535
--dpi-desync=fake
--dpi-desync-cutoff=d2
--dpi-desync-any-protocol=1
--dpi-desync-fake-unknown-udp=/opt/zapret/files/fake/stun.bin
```

# Strategy for Discord
```
--new
--filter-udp=19294-19344,50000-50100
--filter-l7=discord,stun
--dpi-desync=fake
--dpi-desync-fake-discord=/opt/zapret/files/fake/stun.bin
--dpi-desync-fake-stun=/opt/zapret/files/fake/stun.bin
--dpi-desync-repeats=6
--new
--filter-tcp=2053,2083,2087,2096,8443
--hostlist-domains=discord.media
--dpi-desync=multisplit
--dpi-desync-split-pos=2
```
