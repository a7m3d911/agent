@echo off
diskperf -Y >nul
sc start audiosrv >nul
echo All done! Connect your VM using RDP.
echo IP:
tailscale status >Nul 2>&1 && tailscale ip -4 || echo Tailscale is not running
