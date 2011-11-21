(*
 * Copyright (C) Citrix Systems Inc.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published
 * by the Free Software Foundation; version 2.1 only. with the special
 * exception on linking described in file LICENSE.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *)

(** A multiplexing xenstore protocol client over a byte-level transport *)

open Lwt
open Xs_packet

module type TRANSPORT = sig
  type t
  val create: unit -> t Lwt.t
  val destroy: t -> unit Lwt.t
  val read: t -> string -> int -> int -> int Lwt.t
  val write: t -> string -> int -> int -> int Lwt.t
end

let ( |> ) a b = b a
let ( ++ ) f g x = f (g x)

module StringSet = Set.Make(struct type t = string let compare = compare end)

module Watcher = struct

  (** Someone who is watching paths is represented by one of these: *)
  type t = {
    mutable paths: StringSet.t; (* we never care about events or ordering, only paths *)
    mutable cancelling: bool; (* we need to stop watching and clean up *)
    c: unit Lwt_condition.t;
    m: Lwt_mutex.t;
  }

  let make () = {
    paths = StringSet.empty;
    cancelling = false;
    c = Lwt_condition.create ();
    m = Lwt_mutex.create ();
  }

  (** Register that a watched path has been changed *)
  let put (x: t) path =
    Lwt_mutex.with_lock x.m
      (fun () ->
	x.paths <- StringSet.add path x.paths;
	Lwt_condition.signal x.c ();
	return ();
      )

  (** Return a set of modified paths, or an empty set if we're cancelling *)
  let get (x: t) =
    Lwt_mutex.with_lock x.m
      (fun () ->
        while_lwt x.paths = StringSet.empty && not x.cancelling do
          Lwt_condition.wait ~mutex:x.m x.c
        done >>
        let results = x.paths in
        x.paths <- StringSet.empty;
	return results
      )

  (** Called to shutdown the watcher and trigger an orderly cleanup *)
  let cancel (x: t) =
    let (_: unit Lwt.t) =
      Lwt_mutex.with_lock x.m
	(fun () ->
	  x.cancelling <- true;
	  Lwt_condition.signal x.c ();
	  return ()
	) in
    ()
end

module Client = functor(T: TRANSPORT) -> struct

  (* Represents a single acive connection to a server *)
  type client = {
    transport: T.t;
    mutable incoming_pkt: Parser.parse; (* incrementally parses the next packet *)
    outgoing_mutex: Lwt_mutex.t;        (* held to serialise outgoing packets *)
    rid_to_wakeup: (int32, Xs_packet.t Lwt.u) Hashtbl.t;
    mutable dispatcher_thread: unit Lwt.t;
    mutable dispatcher_shutting_down: bool;
    watchevents: (Token.t, Watcher.t) Hashtbl.t;
  }

  exception Unknown_xenstore_operation of int32
  exception Response_parser_failed
  exception Malformed_watch_event
  exception Unexpected_rid of int32
  exception Dispatcher_failed

  (* [recv_one client] returns a single Packet, or fails *)
  let rec recv_one t =
    let open Parser in match Parser.state t.incoming_pkt with
    | Packet pkt ->
      t.incoming_pkt <- start ();
      return pkt
    | Need_more_data x ->
      let buf = String.make x '\000' in
      lwt n = T.read t.transport buf 0 x in
      let fragment = String.sub buf 0 n in
      t.incoming_pkt <- input t.incoming_pkt fragment;
      recv_one t
    | Unknown_operation x -> raise_lwt (Unknown_xenstore_operation x)
    | Parser_failed -> raise_lwt Response_parser_failed

  (* [send_one client pkt] sends [pkt] and returns (), or fails *)
  let send_one t request =
    let req = to_string request in
    lwt n = Lwt_mutex.with_lock t.outgoing_mutex
        (fun () -> T.write t.transport req 0 (String.length req)) in
    return ()

  let rec dispatcher t =
    try_lwt
      lwt pkt = recv_one t in
      begin match get_ty pkt with
        | Op.Watchevent  ->
          lwt () = begin match Unmarshal.list pkt with
            | Some [path; token] ->
              let token = Token.of_string token in
              (* We may get old watches: silently drop these *)
              if Hashtbl.mem t.watchevents token
	      then Watcher.put (Hashtbl.find t.watchevents token) path >> dispatcher t
              else dispatcher t
	    | _ ->
              raise_lwt Malformed_watch_event
          end in
          dispatcher t
        | _ ->
          let rid = get_rid pkt in
          if not(Hashtbl.mem t.rid_to_wakeup rid)
	  then raise_lwt (Unexpected_rid rid)
	  else begin
            Lwt.wakeup (Hashtbl.find t.rid_to_wakeup rid) pkt;
            dispatcher t
	  end
      end
   with e ->
     t.dispatcher_shutting_down <- true; (* no more hashtable entries after this *)
     (* all blocking threads are failed with our exception *)
     Hashtbl.iter (fun _ u -> Lwt.wakeup_later_exn u e) t.rid_to_wakeup;
     raise_lwt e

  let make () =
    lwt transport = T.create () in
    let t = {
      transport = transport;
      incoming_pkt = Parser.start ();
      outgoing_mutex = Lwt_mutex.create ();
      rid_to_wakeup = Hashtbl.create 10;
      dispatcher_thread = return ();
      dispatcher_shutting_down = false;
      watchevents = Hashtbl.create 10;
    } in
    t.dispatcher_thread <- dispatcher t;
    return t

  module Handle = struct
    (** A 'handle' is a sub-connection used for a particular purpose.
        The handle is a convenient place to store sub-connection state *)
    type t = {
      client: client;
      tid: int32; (** transaction id in use (0 means no transaction) *)
      mutable accessed_paths: StringSet.t option; (** paths read or written to *)
      mutable watched_paths: StringSet.t; (** paths being watched *)
    }

    let make client = {
      client = client;
      tid = 0l;                       (* no transaction *)
      accessed_paths = None;          (* not recording accesses *)
      watched_paths = StringSet.empty (* no paths watched *)
    }

    (** Handle used for 'immediate' non-transactional read/writes *)
    let no_transaction client = make client

    (** Handle used for transactional read/writes *)
    let transaction client tid = { (make client) with tid = tid }

    (** Handle used to store watch-related information *)
    let watching client = { (make client) with accessed_paths = Some StringSet.empty }

    (** Get the list of recorded path accesses *)
    let accessed_path h path = match h.accessed_paths with
      | None -> h
      | Some ps -> h.accessed_paths <- Some (StringSet.add path ps); h

    (** Get the list of paths we have accessed *)
    let get_accessed_paths h = match h.accessed_paths with
      | None -> StringSet.empty
      | Some xs -> xs

    (** Declare that we are watching a path *)
    let watch h path = h.watched_paths <- StringSet.add path h.watched_paths; h

    (** Declare that we are nolonger watching a path *)
    let unwatch h path = h.watched_paths <- StringSet.remove path h.watched_paths; h

    (** Get the list of paths we're currently watching *)
    let get_watched_paths h = h.watched_paths
  end

  let rpc hint h request unmarshal =
    let open Handle in
    let request = match request h.tid with Some x -> x | None -> failwith "bad request" in
    let rid = get_rid request in
    let t, u = wait () in
    if h.client.dispatcher_shutting_down
    then raise_lwt Dispatcher_failed
    else begin
      Hashtbl.add h.client.rid_to_wakeup rid u;
      lwt () = send_one h.client request in
      lwt res = t in
      Hashtbl.remove h.client.rid_to_wakeup rid;
      try_lwt
        return (response hint request res unmarshal)
 end

  let directory h path = rpc "directory" (Handle.accessed_path h path) (Request.directory path) Unmarshal.list
  let read h path = rpc "read" (Handle.accessed_path h path) (Request.read path) Unmarshal.string
  let write h path data = rpc "write" (Handle.accessed_path h path) (Request.write path data) Unmarshal.ok
  let watch h path token = rpc "watch" (Handle.watch h path) (fun _ -> Request.watch path token) Unmarshal.ok
  let unwatch h path token = rpc "unwatch" (Handle.watch h path) (fun _ -> Request.unwatch path token) Unmarshal.ok

  let with_xs client f = f (Handle.no_transaction client)

  let wait client f =
    let open StringSet in
    let token = Token.of_user_string "xs_client.wait" in
    (* When we register the 'watcher', the dispatcher thread will signal us when
       watches arrive. *)
    let watcher = Watcher.make () in
    Hashtbl.add client.watchevents token watcher;

    (* We signal the caller via this cancellable task: *)
    let result, wakener = Lwt.task () in
    on_cancel result
      (fun () ->
        (* Trigger an orderly cleanup in the background: *)
	Watcher.cancel watcher
      );
    let h = Handle.watching client in
    (* Adjust the paths we're watching (if necessary) and block (if possible) *)
    let adjust_paths () =
      let current_paths = Handle.get_watched_paths h in
      (* Paths which weren't read don't need to be watched: *)
      let old_paths = diff current_paths (Handle.get_accessed_paths h) in
      lwt () = Lwt_list.iter_s (fun p -> unwatch h p token) (elements old_paths) in
      (* Paths which were read do need to be watched: *)
      let new_paths = diff (Handle.get_accessed_paths h) current_paths in
      lwt () = Lwt_list.iter_s (fun p -> watch h p token) (elements new_paths) in
      (* If we're watching the correct set of paths already then just block *)
      if old_paths = empty && (new_paths = empty)
      then begin
        lwt results = Watcher.get watcher in
        (* an empty results set means we've been cancelled: trigger cleanup *)
        if results = empty
        then fail (Failure "goodnight")
        else return ()
      end else return () in
    (* Main client loop: *)
    let rec loop () =
      lwt finished =
        try_lwt
          lwt result = f h in
          wakeup wakener result;
          return true
        with Eagain ->
          return false in
      if finished
      then return ()
      else adjust_paths () >> loop ()
    in
    let (_: unit Lwt.t) =
      try_lwt
        loop ()
      finally
        let current_paths = Handle.get_watched_paths h in
        lwt () = Lwt_list.iter_s (fun p -> unwatch h p token) (elements current_paths) in
        Hashtbl.remove client.watchevents token;
        return () in
    result

  let rec with_xst client f =
    lwt tid = rpc "transaction_start" (Handle.no_transaction client) (fun _ -> Request.transaction_start ()) Unmarshal.int32 in
    let h = Handle.transaction client tid in
    lwt result = f h in
    try_lwt
      lwt res' = rpc "transaction_end" h (Request.transaction_end true) Unmarshal.string in
      if res' = "OK" then return result else raise_lwt (Error (Printf.sprintf "Unexpected transaction result: %s" res'))
    with Eagain ->
      with_xst client f
end

