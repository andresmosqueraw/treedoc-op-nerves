import Config

# Add configuration that is only needed when running on the host here.

config :nerves_runtime,
  kv_backend:
    {Nerves.Runtime.KVBackend.InMemory,
     contents: %{
       # The KV store on Nerves systems is typically read from UBoot-env, but
       # this allows us to use a pre-populated InMemory store when running on
       # host for development and testing.
       #
       # https://nerves-runtime.hexdocs.pm/readme.html#using-nerves_runtime-in-tests
       # https://nerves-runtime.hexdocs.pm/readme.html#nerves-system-and-firmware-metadata

       "nerves_fw_active" => "a",
       "a.nerves_fw_architecture" => "generic",
       "a.nerves_fw_description" => "N/A",
       "a.nerves_fw_platform" => "host",
       "a.nerves_fw_version" => "0.0.0"
     }}

config :mdns_lite,
  if_monitor: MdnsLite.InetMonitor,
  excluded_ifnames: ["lo", "lo0", "docker0", "virbr0"],
  hosts: [:hostname],
  ttl: 120,
  services: []

config :opdoc,
  data_dir: "data",
  net: Doc.Net.Inet

if Mix.env() == :test do
  config :opdoc, autostart: false, mdns: Doc.Mdns.Static, multicast: false
end
