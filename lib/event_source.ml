type ready_state = Connecting | Open | Closed

type t = {
  url : Uri.t; (* The URL that provides the event stream *)
  request : Curl.t;
  mutable reconnection_time : int; (* in miliseconds *)
  event : Buffer.t;
  data : Buffer.t;
  last_event_id : Buffer.t;
  mutable ready_state : ready_state;
}

module Parse = struct
  open Angstrom

  type event = Comment of string | Field of (string * string)
  [@@deriving show { with_path = false }]

  let char_list_to_string char_list =
    let len = List.length char_list in
    let bytes = Bytes.create len in
    List.iteri (Bytes.set bytes) char_list;
    Bytes.unsafe_to_string bytes

  (* Characters *)
  let lf' = '\x0A'
  let cr' = '\x0D'
  let colon' = ':'
  let space' = ' '

  (* Helper range checkers *)
  let is_any_char c = List.for_all (fun n -> not @@ Char.equal c n) [ lf'; cr' ]

  let is_name_char c =
    List.for_all (fun n -> not @@ Char.equal c n) [ lf'; cr'; colon' ]

  (* tokens *)
  let lf = char lf'
  let cr = char cr'
  let colon = char colon'
  let space = char space'
  let bom = string "\xFEFF"
  let any_char = satisfy is_any_char
  let name_char = satisfy is_name_char

  (* Rules *)
  let end_of_line =
    choice [ both cr lf *> return (); cr *> return (); lf *> return () ]

  let comment =
    lift3
      (fun _ comment _ -> Comment (char_list_to_string comment))
      colon (many any_char) end_of_line
    <?> "comment"

  let field =
    lift3
      (fun name value _ ->
        Field (char_list_to_string name, char_list_to_string value))
      (many1 name_char)
      (option [] (colon *> option space' space *> many any_char))
      end_of_line
    <?> "field"

  let event =
    many
      (choice ~failure_msg:"Couln't parse comment or field" [ field; comment ])
    <* end_of_line <?> "event"

  let stream = option "" bom *> map (many event) ~f:List.flatten <?> "stream"

  (* Parse *)
  let parse_string = Angstrom.parse_string ~consume:Prefix stream

  let parse_string_debug s =
    match parse_string s with
    | Ok result ->
        let pp_event_list ppf =
          Format.(pp_print_list ~pp_sep:pp_print_cut pp_event ppf)
        in
        Format.printf "@[Parsed successfully: @[<v>%a@]@]@." pp_event_list
          result
    | Error msg -> Printf.printf "Parsing failed: %s\n" msg

  let interpret_event t callback = function
    | Comment s -> print_endline s
    | Field (field, data) -> (
        match field with
        | "event" ->
            Buffer.reset t.event;
            Buffer.add_string t.event data
        | "data" ->
            Buffer.add_string t.data data;
            callback data
        | "id" ->
            if data.[0] = '\x00' then ()
            else Buffer.add_string t.last_event_id data
        | "retry" -> t.reconnection_time <- int_of_string data
        | f -> Printf.eprintf "Got unknown field \"%s\", ignoring\n" f)
end

let make ?(headers = []) ~url callback =
  let t =
    {
      url = Uri.of_string url;
      request = Curl.init ();
      reconnection_time = 3000;
      event = Buffer.create 10;
      data = Buffer.create 4096;
      last_event_id = Buffer.create 30;
      ready_state = Connecting;
    }
  in
  let max_retries = 3 in
  Curl.setopt t.request (CURLOPT_MAXREDIRS max_retries);
  Curl.set_httpheader t.request ("Accept" :: "text/event-stream" :: headers);
  Curl.set_url t.request url;
  Curl.set_writefunction t.request (fun chunk ->
      (match Angstrom.parse_string ~consume:Prefix Parse.stream chunk with
      | Ok data -> List.iter (Parse.interpret_event t callback) data
      | Error e -> Printf.eprintf "Parse error: %s" e);
      String.length chunk);

  (* Reconnection logic *)
  let rec perform_with_reconnect n =
    let%lwt curlCode = Curl_lwt.perform t.request in
    let code = Curl.int_of_curlCode curlCode in
    match code / 100 with
    | 2 ->
        t.ready_state <- Closed;
        Lwt.return_unit
    | _ ->
        Printf.eprintf "Connection broken: %d" code;
        if n <= 0 then (
          Printf.eprintf
            "Exceeded maximum connection retries, closing connection...";
          Lwt.return_unit)
        else (
          Printf.eprintf "Attempting to reconnect after %d ms"
            t.reconnection_time;
          let%lwt () =
            Lwt_unix.sleep (float_of_int (t.reconnection_time / 1000))
          in
          (* convert to seconds *)
          perform_with_reconnect (n - 1))
  in
  Lwt.async (fun () -> perform_with_reconnect max_retries);
  t

let close t =
  Curl.cleanup t.request;
  t.ready_state <- Closed
