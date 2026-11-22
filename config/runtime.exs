import Config

Application.ensure_all_started(:logger_backends)
LoggerBackends.add(RingLogger)

# Host only (these variables do not exist on the device):
#   OPDOC_IP=192.168.1.23 OPDOC_NODES=192.168.1.40 iex -S mix
for {env, key} <- [
      {"OPDOC_IP", :ip},
      {"OPDOC_IFNAME", :ifname},
      {"OPDOC_NODES", :nodes},
      {"OPDOC_COOKIE", :cookie},
      {"OPDOC_DATA_DIR", :data_dir},
      {"OPDOC_NAME", :name}
    ],
    value = System.get_env(env),
    value not in [nil, ""] do
  config :opdoc, [{key, value}]
end

# OPDOC_MULTICAST=off: no UDP multicast announcement
if System.get_env("OPDOC_MULTICAST") == "off", do: config(:opdoc, multicast: false)

# OPDOC_MDNS=off: no dynamic discovery, only explicit connections (OPDOC_NODES / Doc.connect/1)
if System.get_env("OPDOC_MDNS") == "off", do: config(:opdoc, mdns: Doc.Mdns.Static)

# OPDOC_SCAN=on: also try doc@<ip> on every address of the local subnet
if System.get_env("OPDOC_SCAN") == "on", do: config(:opdoc, scan: true)
