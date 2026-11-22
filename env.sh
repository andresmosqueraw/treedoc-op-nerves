# Source this before any mix command:   source env.sh
#
# 1) The project path contains a space ("Proyecto Distribución"), which breaks the
#    Makefiles of native deps (nerves_logging, ...). deps/ and _build/ live outside.
export MIX_DEPS_PATH="$HOME/.cache/cpd/opdoc/deps"
export MIX_BUILD_ROOT="$HOME/.cache/cpd/opdoc/_build"
#
# 2) Arch splits Erlang into packages: nerves_ssh and the release need
#    erlang-ssh and erlang-sasl ->  sudo pacman -S erlang-ssh erlang-sasl
#
# 3) fwup >= 1.12 is required by nerves_system_rpi4 2.2.2; 1.17.1 is in ~/.local/bin.
