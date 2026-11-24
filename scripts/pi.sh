#!/usr/bin/env bash
# Encuentra la Pi en el wifi actual, demuestra que es ELLA (y no este PC) la que
# está conectada a los demás, levanta un nodo en este PC y prueba PC <-> Pi.
#   scripts/pi.sh                     # busca la Pi sola
#   scripts/pi.sh <IP_PI>             # si ya sabes su IP (si falla, busca igual)
#   MSG="Hola, soy X" scripts/pi.sh   # mensaje de conexión que deja la Pi (no se borra)
# Todo queda también en ../pi-log-<fecha>.txt, para pasárselo a Claude.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG="$ROOT/../pi-log-$(date +%Y%m%d-%H%M%S).txt"
exec > >(tee "$LOG") 2>&1
IFACE=${IFACE:-wlan0}
KEY="$HOME/.ssh/id_ed25519"
SSH=(ssh -i "$KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5)
PI_HINT=${PI_HINT:-nerves-9155}   # comienzo del nombre de nodo de nuestra Pi (hostname nerves-9155)

say()  { printf '\n==================== %s\n' "$*"; }
pc()   { printf '  %s [PC] %s\n' "$(date +%H:%M:%S)" "$*"; }   # algo que hace ESTE PC
pi()   { printf '  %s [PI] %s\n' "$(date +%H:%M:%S)" "$*"; }   # algo que responde LA PI
info() { printf '         %s\n' "$*"; }

# Código que se ejecuta DENTRO de la Pi (por ssh, nerves_ssh lo evalúa como Elixir)
PI_INFO=$(cat <<'EOF'
model = case File.read("/proc/device-tree/model") do {:ok, m} -> String.trim_trailing(m, <<0>>); _ -> "?" end
{:ok, host} = :inet.gethostname()
{:ok, ifs} = :inet.getifaddrs()
ips = for {ifn, o} <- ifs, {:addr, {a, b, c, d}} <- o, {a, b, c, d} != {127, 0, 0, 1}, do: "#{ifn}=#{a}.#{b}.#{c}.#{d}"
plat = try do Nerves.Runtime.KV.get_active("nerves_fw_platform") rescue _ -> "-" end
fw = try do Nerves.Runtime.KV.get_active("nerves_fw_uuid") rescue _ -> "-" end
{up, _} = :erlang.statistics(:wall_clock)
t = try do Doc.text() catch _, _ -> "" end
m = Base.decode64!("__MSG64__")
# todo en UN solo write y una pausa: nerves_ssh puede cerrar el canal antes de
# mandar varias líneas sueltas
lines = [
  "PI_NODE=#{node()}", "PI_HOST=#{host}", "PI_ARCH=#{:erlang.system_info(:system_architecture)}",
  "PI_MODEL=#{model}", "PI_PLATFORM=#{plat}", "PI_FW=#{fw}", "PI_IPS=#{Enum.join(ips, " ")}",
  "PI_UPTIME=#{div(up, 1000)} s", "PI_TICKTIME=#{:net_kernel.get_net_ticktime()}",
  "PI_CHARS=#{String.length(t)}", "PI_HASMSG=#{m != "" and String.contains?(t, m)}",
  "PI_PEERS=#{Enum.join(Node.list(), " ")}", "PI_END=1"
]
IO.write(Enum.join(lines, "\n") <> "\n")
Process.sleep(300)
EOF
)
# ejecuta PI_INFO en la Pi; deja cada campo en una variable PI_*
pi_info() {
  local out raw code
  # todos los campos vacíos de entrada: si la Pi no manda alguno, el script no se cae
  for k in NODE HOST ARCH MODEL PLATFORM FW IPS UPTIME TICKTIME CHARS HASMSG PEERS END; do printf -v "PI_$k" '%s' ""; done
  # el mensaje viaja en base64, para no tener problemas de comillas
  code=${PI_INFO//__MSG64__/$(printf '%s' "${X:-}" | base64 -w0)}
  raw=$("${SSH[@]}" "$1" "$code" 2>&1 | tr -d '\r')
  out=$(echo "$raw" | grep -E '^PI_[A-Z]+=')
  [ -z "$out" ] && { info "respuesta de la Pi (sin campos):"; echo "$raw" | sed 's/^/           | /'; return 1; }
  while IFS='=' read -r k v; do printf -v "$k" '%s' "$v"; done <<< "$out"
  if [ -z "$PI_END" ]; then
    info "AVISO: la respuesta de la Pi llegó incompleta; esto fue lo que llegó:"
    echo "$raw" | sed 's/^/           | /'
  fi
}

# =============================================================================
say "1/6 ESTE PC: quién es y en qué red está"
CIDR=$(ip -o -4 addr show "$IFACE" | awk '{print $4}' | head -1)
MYIP=${CIDR%/*}
SSID=$(iw dev "$IFACE" link 2>/dev/null | awk -F': ' '/SSID/{print $2}')
PC_HOST=$(cat /etc/hostname 2>/dev/null || hostname)
PC_ARCH=$(uname -m)
PC_MODEL=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo "?")
pc "hostname: $PC_HOST   arquitectura: $PC_ARCH   modelo: $PC_MODEL"
pc "interfaz $IFACE, wifi \"${SSID:-?}\", IP ${MYIP:-ninguna} ($CIDR)"
[ -z "$MYIP" ] && { pc "FAIL: $IFACE no tiene IPv4. Conéctate al wifi cpd2026."; exit 1; }
[ -n "$SSID" ] && [ "$SSID" != "cpd2026" ] && pc "AVISO: no estás en cpd2026; la Pi solo se une a cpd2026."
LOCAL_NODES=$(epmd -names 2>/dev/null | awk '/^name/{print $2}' | paste -sd' ')
pc "nodos Erlang corriendo AHORA en este PC: ${LOCAL_NODES:-ninguno}"
[ -n "$LOCAL_NODES" ] && info "(si hay alguno, ciérralo para que la prueba de identidad sea limpia)"

# =============================================================================
say "2/6 buscar la Pi en la red"
PREFIX=${CIDR#*/}; [ "$PREFIX" -lt 24 ] && CIDR="$MYIP/24"   # como mucho un /24, para que sea rápido

# una IP es nuestra Pi si acepta nuestra clave ssh y ejecuta Elixir
try_ip() {
  local ip=$1 out err
  ssh-keygen -R "$ip" >/dev/null 2>&1   # una Pi reflasheada trae otra clave de host
  err=$(mktemp)
  pc "ssh $ip  ->  le pido que imprima node() ..."
  out=$("${SSH[@]}" "$ip" 'IO.puts("NODE=#{node()}")' 2>"$err" | tr -d '\r' | sed -n 's/^NODE=//p' | head -1)
  if [ -n "$out" ]; then PI=$ip; PI_NODE=$out; pi "$ip responde: soy $out"; rm -f "$err"; return 0; fi
  case "$(cat "$err")" in
    *"Permission denied"*) info "$ip: ssh no acepta nuestra clave (es la Pi de otro grupo)";;
    *"Connection refused"*) info "$ip: no tiene ssh";;
    *"timed out"*|*"No route"*|*"unreachable"*) info "$ip: no responde (apagada, o ahora tiene otra IP)";;
    *) info "$ip: no es nuestra Pi ($(head -1 "$err"))";;
  esac
  rm -f "$err"; return 1
}

PI=""
[ $# -ge 1 ] && { try_ip "$1" || info "-> $1 ya no es la Pi; busco en $CIDR"; }

if [ -z "$PI" ]; then
  pc "nmap $CIDR: equipos con ssh (22) y epmd (4369), y los nombres de nodo Erlang de cada uno ..."
  SCAN=$(nmap -n -p 22,4369 --open --script epmd-info "$CIDR" 2>/dev/null)
  NODES_BY_IP=$(echo "$SCAN" | awk '/^Nmap scan report for/{ip=$5} /^\|_? +[^ ]+: [0-9]+$/ && $2 != "epmd_port:" {sub(":","",$2); printf "%s %s\n", ip, $2}')
  pc "nodos Erlang en esta red (IP  nombre):"
  echo "$NODES_BY_IP" | while read -r ip n; do
    [ -z "$ip" ] && continue
    tag=""; [ "$ip" = "$MYIP" ] && tag="  <- ESTE PC"; [ "${n#$PI_HINT}" != "$n" ] && tag="  <- parece NUESTRA PI"
    info "$ip  $n$tag"
  done
  FIRST=$(echo "$NODES_BY_IP" | awk -v h="$PI_HINT" 'index($2,h)==1{print $1}' | sort -u)
  REST=$(echo "$SCAN" | awk '/^Nmap scan report for/{ip=$5} /^22\/tcp +open/{print ip}' | grep -vx "$MYIP")
  for ip in $FIRST $REST; do
    [ "$ip" = "${1:-}" ] && continue
    try_ip "$ip" && break
  done
fi

if [ -z "$PI" ]; then
  pc "FAIL: nuestra Pi (nodo $PI_HINT-...) no está en $CIDR."
  info "- Si su nombre sale en la lista pero ssh falla: pásale este log a Claude."
  info "- Si no sale: desconecta y conecta la energía de la Pi, espera 60 s y vuelve a correr."
  info "- En el celular o el router, busca 'nerves-9155' y usa su IP: scripts/pi.sh <IP>"
  exit 1
fi

# =============================================================================
say "3/6 PRUEBA DE IDENTIDAD: ¿quién está conectado a los demás, la Pi o este PC?"
pc "ssh $PI  ->  ejecuto DENTRO de la Pi: modelo de placa, arquitectura, IPs, Node.list() ..."
if ! X="${MSG:-}" pi_info "$PI"; then pc "FAIL: la Pi no respondió al ssh"; exit 1; fi
printf '\n  %-14s %-34s %s\n' "" "ESTE PC" "LA RASPBERRY PI (respondido por ella)"
printf '  %-14s %-34s %s\n' "hostname" "$PC_HOST" "$PI_HOST"
printf '  %-14s %-34s %s\n' "arquitectura" "$PC_ARCH" "$PI_ARCH"
printf '  %-14s %-34s %s\n' "modelo" "${PC_MODEL:0:33}" "$PI_MODEL"
printf '  %-14s %-34s %s\n' "plataforma" "-" "nerves $PI_PLATFORM (firmware $PI_FW)"
printf '  %-14s %-34s %s\n' "IP" "$MYIP" "$PI_IPS"
printf '  %-14s %-34s %s\n' "nodo Erlang" "${LOCAL_NODES:-ninguno todavía}" "$PI_NODE"
printf '  %-14s %-34s %s\n' "encendida" "-" "hace $PI_UPTIME"
printf '  %-14s %-34s %s\n' "documento" "-" "$PI_CHARS caracteres, net_ticktime $PI_TICKTIME"
echo
N=0
pi "Node.list() visto DESDE LA PI (a quién está conectada ella):"
for n in $PI_PEERS; do
  N=$((N + 1)); tag=""; [ "${n#*@}" = "$MYIP" ] && tag="  <- es ESTE PC"
  info "$n$tag"
done
[ "$N" -eq 0 ] && info "(nadie todavía)"
if [ "$N" -gt 0 ] && [ -z "$LOCAL_NODES" ]; then
  echo
  info ">>> La Pi está conectada a $N nodos y en ESTE PC no corre ningún nodo Erlang:"
  info ">>> la que se conecta es LA PI. (Su arquitectura es $PI_ARCH; la de este PC, $PC_ARCH.)"
fi
echo
info "NOTA: cpd2026 es la red de la clase. Las pruebas escriben marcas cortas en el documento"
info "      compartido y borran exactamente esas marcas; no se toca texto de nadie más."
info "      Al final la Pi deja UN mensaje que se queda: \"${MSG:-Me conecté desde $PI_NODE}\"."

# =============================================================================
say "4/6 levantar un nodo en ESTE PC y probar PC <-> Pi (unos 2 minutos)"
cd "$ROOT" && source ./env.sh
pc "mix compile ..."
mix compile >/dev/null 2>&1 || { pc "FAIL: mix compile"; exit 1; }
pc "arranco el nodo del PC: OPDOC_IP=$MYIP OPDOC_NODES=$PI OPDOC_NAME=laptop"
MSG="${MSG:-}" OPDOC_IP="$MYIP" OPDOC_NODES="$PI" OPDOC_NAME=laptop PI_IP="$PI" PI_NODE="$PI_NODE" \
  mix run --no-compile scripts/pi_check.exs
rc=$?
pc "el nodo del PC terminó (código $rc); ya NO corre ningún nodo en este PC"

# =============================================================================
say "5/6 la Pi SIN este PC: ¿sigue conectada a los demás y tiene el mensaje?"
sleep 3
pc "ssh $PI  ->  vuelvo a preguntarle a la Pi ..."
if X="${MSG:-Me conecté desde $PI_NODE}" pi_info "$PI"; then
  N=0; for n in $PI_PEERS; do
    N=$((N + 1)); tag=""; [ "${n#*@}" = "$MYIP" ] && tag="  <- ESTE PC (todavía cerrando)"
    pi "conectada a $n$tag"
  done
  [ "$N" -eq 0 ] && pi "no está conectada a nadie (¿no hay más nodos en la red?)"
  pi "documento: $PI_CHARS caracteres; contiene el mensaje de conexión: $PI_HASMSG"
  [ "$N" -gt 0 ] && info ">>> Con el nodo del PC apagado, la Pi sigue conectada a $N nodos: es ELLA la que se conecta."
else
  pc "la Pi no respondió esta vez al ssh"
fi

# =============================================================================
say "6/6 listo"
info "Log guardado en: $LOG"
info "Para seguir a mano:"
info "  Pi (IEx dentro de la Pi):  ssh $PI"
info "  PC:  cd \"$ROOT\" && source env.sh && OPDOC_IP=$MYIP OPDOC_NODES=$PI iex -S mix"
info "Prueba física: desconecta la energía de la Pi; en los demás nodos, Node.list() deja de mostrar $PI_NODE."
exit $rc
