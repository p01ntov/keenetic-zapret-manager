@echo off
start "zapret" winws.exe ^
--filter-tcp=80,443 --hostlist="%LISTS%list-general.txt" --dpi-desync=unsupported --new ^
