System.cmd("epmd", ["-daemon"])
ExUnit.start(capture_log: true)
