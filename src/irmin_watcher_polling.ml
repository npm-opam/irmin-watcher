(*---------------------------------------------------------------------------
   Copyright (c) 2016 Thomas Gazagnaire. All rights reserved.
   Distributed under the ISC license, see terms at the end of the file.
   irmin-watcher 0.2.0
  ---------------------------------------------------------------------------*)

open Lwt.Infix
open Astring
module Digests = Irmin_watcher_core.Digests

let (/) = Filename.concat

let src = Logs.Src.create "irw-polling" ~doc:"Irmin watcher using using polling"
module Log = (val Logs.src_log src : Logs.LOG)

let list_files kind dir =
  if Sys.file_exists dir && Sys.is_directory dir then
    let d = Sys.readdir dir in
    let d = Array.to_list d in
    let d = List.map (Filename.concat dir) d in
    let d = List.filter kind d in
    let d = List.sort String.compare d in
    Lwt.return d
  else
  Lwt.return_nil

let directories dir =
  list_files (fun f ->
      try Sys.is_directory f with Sys_error _ -> false
    ) dir

let files dir =
  list_files (fun f ->
      try not (Sys.is_directory f) with Sys_error _ -> false
    ) dir

let rec_files dir =
  let rec aux accu dir =
    directories dir >>= fun ds ->
    files dir       >>= fun fs ->
    Lwt_list.fold_left_s aux (fs @ accu) ds
  in
  aux [] dir

let read_file ~prefix f =
  if not (Sys.file_exists f) || Sys.is_directory f then None
  else
  let r = String.with_range ~first:(String.length prefix) f in
  Some (r, Digest.file f)

let read_files dir =
  rec_files dir >|= fun new_files ->
  let prefix = dir / "" in
  List.fold_left (fun acc f ->
      match read_file ~prefix f with
      | None   -> acc
      | Some d -> Digests.add d acc
    ) Digests.empty new_files

type event = [ `Unknown | `File of string ]

let rec poll ~callback ~wait_for_changes dir files (event:event) =
  ( match event with
  | `Unknown -> read_files dir
  | `File f  ->
      let prefix = dir / "" in
      let short_f = String.with_range ~first:(String.length prefix) f in
      let files = Digests.filter (fun (x, _) -> x <> short_f) files in
      match read_file ~prefix f with
      | None   -> Lwt.return files
      | Some d -> Lwt.return (Digests.add d files)
  ) >>= fun new_files ->
  let diff = Digests.sdiff files new_files in
  let process () =
    if Digests.is_empty diff then Lwt.return_unit
    else (
      Log.debug (fun f -> f "polling %s: diff:%a" dir Digests.pp diff);
      let files = Digests.files diff in
      Lwt_list.iter_p callback files)
  in
  process () >>= fun () ->
  wait_for_changes () >>= fun event ->
  poll ~callback ~wait_for_changes dir new_files event

let listen ~wait_for_changes ~dir callback =
  read_files dir >|= fun files ->
  Irmin_watcher_core.stoppable
    (fun () -> poll ~callback ~wait_for_changes dir files `Unknown)

let default_polling_time = ref 1.

let v delay =
  Log.info (fun l -> l "Polling mode");
  let wait_for_changes () = Lwt_unix.sleep delay >|= fun () -> `Unknown in
  Irmin_watcher_core.create (fun dir -> listen ~wait_for_changes ~dir)

(*---------------------------------------------------------------------------
   Copyright (c) 2016 Thomas Gazagnaire

   Permission to use, copy, modify, and/or distribute this software for any
   purpose with or without fee is hereby granted, provided that the above
   copyright notice and this permission notice appear in all copies.

   THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
   WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
   MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
   ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
   WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
   ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
   OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
  ---------------------------------------------------------------------------*)
