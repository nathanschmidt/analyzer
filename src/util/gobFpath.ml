type t = Fpath.t

let pretty () p = Pretty.text (Fpath.to_string p)

let of_string_exn s =
  match Fpath.of_string s with
  | Ok p -> p
  | Error (`Msg m) ->
    invalid_arg ("GobFpath.of_string_exn: " ^ m)

let to_yojson p = `String (Fpath.to_string p)

let of_yojson = function
  | `String s ->
    Fpath.of_string s
    |> Result.map_error (fun (`Msg m) ->
        "GobFpath.of_yojson: " ^ m
      )
  | _ ->
    Error "GobFpath.of_yojson: not string"

let cwd () =
  of_string_exn (Unix.getcwd ())

let cwd_append p =
  Fpath.append (cwd ()) p (* eta-expanded to get cwd at use time, not define time *)

let rem_find_prefix p1 p2 =
  (* TODO: don't use get? *)
  let prefix = Option.get (Fpath.find_prefix p1 p2) in
  Option.get (Fpath.rem_prefix prefix p2)

