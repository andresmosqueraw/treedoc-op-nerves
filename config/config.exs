# This file is responsible for configuring your application and its
# dependencies.
#
# This configuration file is loaded before any dependency and is restricted to
# this project.
import Config

# Enable the Nerves integration with Mix
Application.start(:nerves_bootstrap)

# Customize non-Elixir parts of the firmware. See
# https://nerves.hexdocs.pm/advanced-configuration.html for details.

# The project path contains spaces/accents ("Proyecto Distribución") and the Nerves
# firmware scripts split paths on spaces: copy the overlay to a safe path first.
overlay = Path.expand("../rootfs_overlay", __DIR__)

overlay =
  if String.contains?(overlay, " ") do
    safe = Path.join(System.get_env("MIX_BUILD_ROOT", System.tmp_dir!()), "rootfs_overlay_copy")
    File.rm_rf!(safe)
    File.mkdir_p!(Path.dirname(safe))
    File.cp_r!(overlay, safe)
    safe
  else
    overlay
  end

config :nerves, :firmware, rootfs_overlay: overlay

# Set the SOURCE_DATE_EPOCH date for reproducible builds.
# See https://reproducible-builds.org/docs/source-date-epoch/ for more information

config :nerves, source_date_epoch: "1795281895"

# ---- opdoc (p_dist, op-based) ---------------------------------------------------
# Contract of the op-based groups (INTEGRATION.md): cookie cpd2026, process
# Crdt.Replica, UDP multicast discovery. Node name: <hostname>@IP by default.
config :opdoc,
  autostart: true,
  cookie: "cpd2026",
  # explicit connection (P5): comma separated IPs or node names, e.g. "172.20.10.3,172.20.10.4"
  nodes: "",
  discovery_interval: 5_000,
  mdns_wait: 1_500,
  mdns: Doc.Mdns.Lite,
  # distribution ports of the contract (firewall: open 4369 and this range)
  dist_ports: {4218, 4228},
  # random epoch in the node name, kept next to the log (survives reboots,
  # changes on reflash so operation numbers are never reused)
  epoch: true,
  # UDP multicast announcement of the op-based groups (233.252.1.32:45892)
  multicast: true,
  # try doc@<ip> for every address of the local subnet (on by default on the Pi)
  scan: false,
  scan_interval: 10_000

if Mix.target() == :host do
  import_config "host.exs"
else
  import_config "target.exs"
end
