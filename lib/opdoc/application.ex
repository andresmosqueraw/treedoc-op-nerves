defmodule Doc.Application do
  @moduledoc false
  use Application

  # Doc.Supervisor (one_for_one)
  #   ├─ Doc.Replica      always on: editing works offline (CAP: available)
  #   └─ Doc.NetSup       (rest_for_one)
  #        ├─ Doc.Net     watches the IP, (re)starts/stops Doc.Stack
  #        └─ Doc.Stack   Doc.Dist (doc@IP, cookie) → Doc.Discovery (mDNS + explicit)
  @impl true
  def start(_type, _args) do
    children =
      if Application.get_env(:opdoc, :autostart, true) do
        [
          Doc.Replica,
          %{
            id: Doc.NetSup,
            type: :supervisor,
            start:
              {Supervisor, :start_link, [[Doc.Net], [strategy: :rest_for_one, name: Doc.NetSup]]}
          }
        ]
      else
        []
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: Doc.Supervisor)
  end
end
