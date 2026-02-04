module Config = Watsup.Config
module Io = Watsup.Io
module Main_logic = Watsup.Main_logic

let () =
  let config_path = Config.default_path () in
  Main_logic.run ~io:Io.stdio ~config_path
