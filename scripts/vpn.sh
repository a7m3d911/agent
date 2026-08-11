#!/bin/bash
# One interface over Tailscale and NetBird, so the rest of the provisioning
# never mentions either by name. Drop a provider later by deleting its branch.
#
#   VPN_PROVIDER = tailscale | netbird   (default tailscale)
#
# Provides: $VPN_IFACE, vpn_install, vpn_up <hostname>, vpn_ip

VPN_PROVIDER="${VPN_PROVIDER:-tailscale}"

case "$VPN_PROVIDER" in
  tailscale) VPN_IFACE=tailscale0 ;;
  netbird)   VPN_IFACE=wt0 ;;
  *) echo "Unknown VPN_PROVIDER '$VPN_PROVIDER' (want tailscale|netbird)" >&2; return 2 2>/dev/null || exit 2 ;;
esac

vpn_install() {
  case "$VPN_PROVIDER" in
    tailscale) curl -fsSL https://tailscale.com/install.sh | sh ;;
    netbird)   curl -fsSL https://pkgs.netbird.io/install.sh | sh ;;
  esac
}

# vpn_up <hostname> — must be unique per box; two live clusters sharing a name
# get silently renamed by the coordinator and discovery stops matching.
vpn_up() {
  local hostname="$1"
  case "$VPN_PROVIDER" in
    tailscale)
      [[ -n "$TAILSCALE_AUTH_KEY" ]] || { echo "TAILSCALE_AUTH_KEY unset" >&2; return 2; }
      sudo tailscale up --authkey="$TAILSCALE_AUTH_KEY" --ssh --hostname="$hostname" --advertise-exit-node
      ;;
    netbird)
      [[ -n "$NETBIRD_MANAGEMENT_URL" && -n "$NETBIRD_SETUP_KEY" ]] || {
        echo "NETBIRD_MANAGEMENT_URL / NETBIRD_SETUP_KEY unset" >&2; return 2; }
      sudo netbird up --management-url "$NETBIRD_MANAGEMENT_URL" \
        --setup-key "$NETBIRD_SETUP_KEY" --hostname "$hostname" \
        --allow-server-ssh --enable-ssh-root
      ;;
  esac
}

# vpn_ip — the mesh IP, retried because both daemons report it a beat after `up`.
vpn_ip() {
  local ip i
  for i in $(seq 1 30); do
    case "$VPN_PROVIDER" in
      tailscale) ip=$(tailscale ip -4 2>/dev/null | head -1) ;;
      netbird)   ip=$(sudo netbird status --json 2>/dev/null | jq -r '.netbirdIp // empty' | cut -d/ -f1) ;;
    esac
    [[ -n "$ip" ]] && { echo "$ip"; return 0; }
    sleep 2
  done
  return 1
}
