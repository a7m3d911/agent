@echo off
tailscale status >Nul 2>&1 && goto check || echo "Tailscale is not running. Update TAILSCALE_AUTH_KEY in Settings > Secrets > Repository secrets then run workflow again. Your current workflow will end shortly." & ping 127.0.0.1 >Nul & exit
:check
ping 127.0.0.1 > nul
cls
goto check
