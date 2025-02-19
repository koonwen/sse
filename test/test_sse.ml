open Sse.Event_source

(* Testing the parser *)
let test_inputs =
  [
    (* Single event with data *)
    "data: Hello, World!\n\n";
    (* Event with multiple data lines *)
    "data: This is the first line\ndata: This is the second line\n\n";
    (* Event with ID and data *)
    "id: 1\ndata: Event data\n\n";
    (* Event with type, ID, and data *)
    "event: message\nid: 42\ndata: Hello, SSE!\n\n";
    (* Event with comments *)
    ": This is a comment\ndata: Comment test\n\n";
    (* Multiple events in a stream *)
    "id: 1\ndata: Event 1\n\nid: 2\nevent: update\ndata: Event 2\n\n";
    (* Event with Unicode characters *)
    "data: Привет, мир!\nid: 3\n\n";
    (* Event with trailing space after colon *)
    "data: \n\n";
    (* Event with BOM *)
    "\xFEFFdata: Includes BOM\n\n";
    (* Empty event *)
    "\n";
  ]

let () = List.iter Parse.parse_string_debug test_inputs
let test_sse_url = "https://sse.dev/test?interval=1"

let () =
  Lwt_main.run
  @@
  let t =
    Sse.Event_source.make ~url:test_sse_url (fun s -> Printf.printf "%s\n%!" s)
  in
  let%lwt () = Lwt_unix.sleep 10.0 in
  Sse.Event_source.close t;
  Lwt.return_unit
